#!/usr/bin/env bash

SERVICE_KEY="${SERVICE_KEY:-bot}"
DOCKER_WITH_SUDO="${DOCKER_WITH_SUDO:-0}"
SYSTEMD_DIR="${SYSTEMD_DIR:-/etc/systemd/system}"
SYSTEMCTL="${SYSTEMCTL:-systemctl}"

log() {
  printf '[%s] %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*"
}

die() {
  log "ERROR: $*" >&2
  return 1
}

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

as_root() {
  if [[ "$(id -u)" == "0" ]]; then
    "$@"
  else
    command_exists sudo || die "sudo is required"
    sudo "$@"
  fi
}

docker_command() {
  if [[ "$DOCKER_WITH_SUDO" == "1" ]]; then
    sudo docker "$@"
  else
    docker "$@"
  fi
}

compose() {
  if docker_command compose version >/dev/null 2>&1; then
    docker_command compose "$@"
  elif command_exists docker-compose; then
    if [[ "$DOCKER_WITH_SUDO" == "1" ]]; then
      sudo docker-compose "$@"
    else
      docker-compose "$@"
    fi
  else
    die "Docker Compose is unavailable"
  fi
}

detect_docker_access() {
  if docker info >/dev/null 2>&1; then
    DOCKER_WITH_SUDO=0
  elif command_exists sudo && sudo docker info >/dev/null 2>&1; then
    DOCKER_WITH_SUDO=1
  else
    die "Docker daemon is unavailable or permission was denied"
  fi
  export DOCKER_WITH_SUDO
}

env_value() {
  local name="$1" file="$2"
  [[ -f "$file" ]] || return 0
  awk -F= -v wanted="$name" '
    $0 !~ /^[[:space:]]*#/ && $1 ~ "^[[:space:]]*" wanted "[[:space:]]*$" {
      value=substr($0, index($0, "=") + 1)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
      if ((substr(value,1,1) == "\"" && substr(value,length(value),1) == "\"") ||
          (substr(value,1,1) == "\047" && substr(value,length(value),1) == "\047")) {
        value=substr(value,2,length(value)-2)
      }
      print value
      exit
    }
  ' "$file"
}

slugify() {
  printf '%s' "$1" |
    tr '[:upper:]' '[:lower:]' |
    sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//; s/-+/-/g'
}

resolve_app_slug() {
  local configured source
  configured="$(env_value APP_NAME "$ROOT_DIR/.env")"
  source="${configured:-$(basename "$ROOT_DIR")}"
  APP_SLUG="${APP_SLUG:-$(slugify "$source")}"
  if [[ ! "$APP_SLUG" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]]; then
    die "APP_SLUG must contain only lowercase letters, digits, and hyphens"
  fi
  if (( ${#APP_SLUG} < 3 || ${#APP_SLUG} > 63 )); then
    die "APP_SLUG length must be between 3 and 63 characters"
  fi
  COMPOSE_PROJECT="${COMPOSE_PROJECT:-$APP_SLUG}"
  IMAGE_NAME="${IMAGE_NAME:-$APP_SLUG:local}"
  ROLLBACK_IMAGE="${ROLLBACK_IMAGE:-$APP_SLUG:rollback}"
  LOCK_FILE="${LOCK_FILE:-/run/lock/$APP_SLUG-deploy.lock}"
  FAILED_SHA_FILE="${FAILED_SHA_FILE:-$ROOT_DIR/data/.failed-deploy-sha}"
  ROLLBACK_COMMIT_FILE="${ROLLBACK_COMMIT_FILE:-$ROOT_DIR/data/.rollback-commit}"
  export APP_SLUG COMPOSE_PROJECT IMAGE_NAME ROLLBACK_IMAGE
  export LOCK_FILE FAILED_SHA_FILE ROLLBACK_COMMIT_FILE
}

container_id() {
  compose -p "$COMPOSE_PROJECT" -f "$ROOT_DIR/docker-compose.yml" ps -q "$SERVICE_KEY"
}

container_is_running() {
  local id running
  id="$(container_id)"
  [[ -n "$id" ]] || return 1
  if ! running="$(docker_command inspect --format '{{.State.Running}}' "$id" 2>/dev/null)"; then
    return 1
  fi
  [[ "$running" == "true" ]]
}

wait_until_stable() {
  local id running restarts health
  local attempt stable=0
  local attempts="${HEALTH_ATTEMPTS:-45}"
  local required="${HEALTH_STABLE_COUNT:-5}"
  local interval="${HEALTH_INTERVAL_SECONDS:-2}"

  for ((attempt = 1; attempt <= attempts; attempt++)); do
    id="$(container_id)"
    running="unknown"
    restarts="unknown"
    health="unknown"
    if [[ -n "$id" ]]; then
      if ! running="$(docker_command inspect --format '{{.State.Running}}' "$id" 2>/dev/null)"; then
        running="unknown"
      fi
      if ! restarts="$(docker_command inspect --format '{{.RestartCount}}' "$id" 2>/dev/null)"; then
        restarts="unknown"
      fi
      if ! health="$(docker_command inspect \
        --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' \
        "$id" 2>/dev/null)"; then
        health="unknown"
      fi
    fi
    if [[ "$running" == "true" && "$restarts" == "0" && "$health" == "healthy" ]]; then
      stable=$((stable + 1))
      if (( stable >= required )); then
        return 0
      fi
    else
      stable=0
    fi
    sleep "$interval"
  done
  log "Container failed strict health stabilization"
  return 1
}

smoke_test_image() {
  APP_SLUG="$APP_SLUG" COMPOSE_PROJECT="$COMPOSE_PROJECT" \
    bash "$ROOT_DIR/scripts/smoke-test.sh"
}

unit_name() {
  printf '%s-deploy.%s' "$APP_SLUG" "$1"
}

render_systemd_unit() {
  local template="$1" destination="$2"
  local escaped_root escaped_slug escaped_project escaped_service
  escaped_root="${ROOT_DIR//\\/\\\\}"
  escaped_root="${escaped_root//&/\\&}"
  escaped_root="${escaped_root//|/\\|}"
  escaped_slug="${APP_SLUG//&/\\&}"
  escaped_project="${COMPOSE_PROJECT//&/\\&}"
  escaped_service="${SERVICE_KEY//&/\\&}"
  sed \
    -e "s|__INSTALL_DIR__|$escaped_root|g" \
    -e "s|__APP_SLUG__|$escaped_slug|g" \
    -e "s|__COMPOSE_PROJECT__|$escaped_project|g" \
    -e "s|__SERVICE_KEY__|$escaped_service|g" \
    "$template" >"$destination"
}

backup_systemd_units() {
  UNITS_BACKUP_DIR="$(mktemp -d)"
  local extension target
  for extension in service timer; do
    target="$SYSTEMD_DIR/$(unit_name "$extension")"
    if [[ -f "$target" ]]; then
      cp "$target" "$UNITS_BACKUP_DIR/$extension"
    else
      : >"$UNITS_BACKUP_DIR/$extension.absent"
    fi
  done
  export UNITS_BACKUP_DIR
}

install_systemd_units() {
  local mode="${1:-enable}"
  local extension template target temporary
  as_root mkdir -p "$SYSTEMD_DIR"
  for extension in service timer; do
    template="$ROOT_DIR/scripts/systemd/telegram-bot-deploy.$extension"
    target="$SYSTEMD_DIR/$(unit_name "$extension")"
    temporary="$(mktemp)"
    render_systemd_unit "$template" "$temporary"
    as_root install -m 0644 "$temporary" "$target"
    rm -f "$temporary"
  done
  as_root "$SYSTEMCTL" daemon-reload
  if [[ "$mode" == "enable-now" ]]; then
    as_root "$SYSTEMCTL" enable --now "$(unit_name timer)"
  else
    as_root "$SYSTEMCTL" enable "$(unit_name timer)"
  fi
}

restore_systemd_units() {
  local extension target
  [[ -n "${UNITS_BACKUP_DIR:-}" && -d "$UNITS_BACKUP_DIR" ]] ||
    die "Systemd backup is unavailable"
  for extension in service timer; do
    target="$SYSTEMD_DIR/$(unit_name "$extension")"
    if [[ -f "$UNITS_BACKUP_DIR/$extension.absent" ]]; then
      as_root rm -f "$target"
    else
      as_root install -m 0644 "$UNITS_BACKUP_DIR/$extension" "$target"
    fi
  done
  as_root "$SYSTEMCTL" daemon-reload
}

cleanup_systemd_backup() {
  if [[ -n "${UNITS_BACKUP_DIR:-}" && -d "$UNITS_BACKUP_DIR" ]]; then
    rm -f -- "$UNITS_BACKUP_DIR/service" "$UNITS_BACKUP_DIR/timer" \
      "$UNITS_BACKUP_DIR/service.absent" "$UNITS_BACKUP_DIR/timer.absent"
    rmdir -- "$UNITS_BACKUP_DIR"
    UNITS_BACKUP_DIR=""
  fi
}
