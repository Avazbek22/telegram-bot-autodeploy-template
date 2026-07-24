#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="${INSTALL_DIR:-$SCRIPT_DIR}"
ROOT_DIR="$INSTALL_DIR"
LIBRARY="$SCRIPT_DIR/scripts/lib-production.sh"
[[ -f "$LIBRARY" ]] || {
  printf 'Run install.sh from a complete repository checkout.\n' >&2
  exit 1
}
# shellcheck source=scripts/lib-production.sh
source "$LIBRARY"

BRANCH="main"
previous_commit=""
previous_image=0
previous_running=0
replacement_attempted=0
transaction_started=0
units_backed_up=0
INSTALL_BACKUP_IMAGE=""

install_prerequisites() {
  if [[ "${INSTALL_SKIP_PREREQUISITES:-0}" == "1" ]]; then
    return 0
  fi
  [[ -r /etc/os-release ]] || die "Ubuntu 22.04 or 24.04 is required"
  # shellcheck disable=SC1091
  source /etc/os-release
  [[ "${ID:-}" == "ubuntu" ]] || die "Ubuntu 22.04 or 24.04 is required"
  case "${VERSION_ID:-}" in
    22.04 | 24.04) ;;
    *) die "Supported Ubuntu versions are 22.04 and 24.04" ;;
  esac

  local packages_missing=0
  if ! command_exists git || ! command_exists docker || ! command_exists flock; then
    packages_missing=1
  elif ! command_exists dpkg-query ||
    ! dpkg-query -W -f='${Status}' ca-certificates 2>/dev/null |
      grep -q 'ok installed'; then
    packages_missing=1
  fi
  if [[ "$packages_missing" == "1" ]]; then
    command_exists apt-get || die "apt-get is required"
    as_root apt-get update
    as_root apt-get install -y --no-install-recommends \
      ca-certificates git docker.io util-linux
  fi
  as_root systemctl enable --now docker
  detect_docker_access

  if ! docker_command compose version >/dev/null 2>&1 &&
    ! command_exists docker-compose; then
    if ! as_root apt-get install -y --no-install-recommends docker-compose-v2; then
      if ! as_root apt-get install -y --no-install-recommends docker-compose-plugin; then
        as_root apt-get install -y --no-install-recommends docker-compose
      fi
    fi
  fi
  compose version >/dev/null
}

write_token_to_env() {
  local token="$1" temporary
  temporary="$(mktemp "$ROOT_DIR/.env.XXXXXX")"
  awk -v token="$token" '
    BEGIN { replaced=0 }
    /^[[:space:]]*BOT_TOKEN[[:space:]]*=/ {
      if (!replaced) {
        print "BOT_TOKEN=" token
        replaced=1
      }
      next
    }
    { print }
    END {
      if (!replaced) print "BOT_TOKEN=" token
    }
  ' "$ROOT_DIR/.env" >"$temporary"
  chmod 600 "$temporary"
  mv "$temporary" "$ROOT_DIR/.env"
}

prepare_environment() {
  if [[ ! -f "$ROOT_DIR/.env" ]]; then
    cp "$ROOT_DIR/.env-example" "$ROOT_DIR/.env"
  fi
  local token
  token="$(env_value BOT_TOKEN "$ROOT_DIR/.env")"
  if [[ -z "$token" ]]; then
    token="${BOT_TOKEN:-}"
    if [[ -z "$token" ]]; then
      printf 'Telegram BOT_TOKEN: ' >&2
      read -r -s token
      printf '\n' >&2
    fi
    [[ "$token" =~ ^[0-9]{5,20}:[A-Za-z0-9_-]{20,128}$ ]] ||
      die "BOT_TOKEN has an invalid format"
    write_token_to_env "$token"
  elif [[ ! "$token" =~ ^[0-9]{5,20}:[A-Za-z0-9_-]{20,128}$ ]]; then
    die "BOT_TOKEN in .env has an invalid format"
  fi
  chmod 600 "$ROOT_DIR/.env"
  mkdir -p "$ROOT_DIR/data" "$ROOT_DIR/logs"
  as_root chown -R 10001:10001 "$ROOT_DIR/data" "$ROOT_DIR/logs"
}

acquire_install_lock() {
  command_exists flock || die "flock is required"
  as_root mkdir -p "$(dirname "$LOCK_FILE")"
  as_root touch "$LOCK_FILE"
  as_root chown "$(id -u):$(id -g)" "$LOCK_FILE"
  exec 9>"$LOCK_FILE"
  flock -n 9 || die "Another install, deployment, or rollback is active"
}

validate_repository() {
  [[ -d "$ROOT_DIR/.git" ]] ||
    die "Clone your generated repository before running install.sh"
  [[ -z "$(git -C "$ROOT_DIR" status --porcelain --untracked-files=no)" ]] ||
    die "Tracked local changes detected in $ROOT_DIR"
  git -C "$ROOT_DIR" remote get-url origin >/dev/null 2>&1 ||
    die "Git remote 'origin' is required for automatic deployment"
}

capture_previous_state() {
  previous_commit="$(git -C "$ROOT_DIR" rev-parse HEAD)"
  INSTALL_BACKUP_IMAGE="$APP_SLUG:install-rollback"
  if docker_command image inspect "$IMAGE_NAME" >/dev/null 2>&1; then
    docker_command image tag "$IMAGE_NAME" "$INSTALL_BACKUP_IMAGE"
    previous_image=1
  fi
  if container_is_running; then
    previous_running=1
  fi
  backup_systemd_units
  units_backed_up=1
  transaction_started=1
}

update_checkout() {
  local current_branch
  current_branch="$(git -C "$ROOT_DIR" branch --show-current)"
  [[ "$current_branch" == "$BRANCH" ]] ||
    die "Production checkout must be on branch $BRANCH"
  git -C "$ROOT_DIR" fetch origin "$BRANCH"
  git -C "$ROOT_DIR" pull --ff-only origin "$BRANCH"
}

restore_installation() {
  local exit_code="${1:-1}"
  trap - ERR INT TERM EXIT
  if [[ "$transaction_started" == "1" ]]; then
    log "Installer failed; restoring the previous deployment"
    if ! git -C "$ROOT_DIR" checkout -q -B "$BRANCH" "$previous_commit"; then
      log "Rollback warning: Git commit could not be restored"
    fi
    if [[ "$previous_image" == "1" ]]; then
      if ! docker_command image tag "$INSTALL_BACKUP_IMAGE" "$IMAGE_NAME"; then
        log "Rollback warning: Docker image could not be restored"
      fi
    fi
    if [[ "$units_backed_up" == "1" ]]; then
      if ! restore_systemd_units; then
        log "Rollback warning: systemd units could not be restored"
      fi
    fi
    if [[ "$replacement_attempted" == "1" ]]; then
      if [[ "$previous_running" == "1" && "$previous_image" == "1" ]]; then
        if ! compose -p "$COMPOSE_PROJECT" -f "$ROOT_DIR/docker-compose.yml" \
          up -d --no-deps --force-recreate "$SERVICE_KEY"; then
          log "Rollback warning: previous container could not be recreated"
        elif ! wait_until_stable; then
          log "Rollback warning: previous container did not stabilize"
        fi
      else
        if ! compose -p "$COMPOSE_PROJECT" -f "$ROOT_DIR/docker-compose.yml" \
          stop "$SERVICE_KEY"; then
          log "Rollback warning: candidate container could not be stopped"
        fi
      fi
    fi
    cleanup_systemd_backup
  fi
  exit "$exit_code"
}

build_and_start() {
  compose -p "$COMPOSE_PROJECT" -f "$ROOT_DIR/docker-compose.yml" \
    build --pull "$SERVICE_KEY"
  smoke_test_image
  replacement_attempted=1
  compose -p "$COMPOSE_PROJECT" -f "$ROOT_DIR/docker-compose.yml" \
    up -d --no-deps --force-recreate "$SERVICE_KEY"
  wait_until_stable
}

main() {
  install_prerequisites
  if [[ "${INSTALL_SKIP_PREREQUISITES:-0}" == "1" ]]; then
    detect_docker_access
  fi
  validate_repository
  prepare_environment
  resolve_app_slug
  acquire_install_lock
  capture_previous_state
  trap 'restore_installation $?' ERR INT TERM EXIT

  update_checkout
  chmod 0755 "$ROOT_DIR/install.sh" "$ROOT_DIR/scripts/"*.sh
  build_and_start
  install_systemd_units enable-now

  if [[ "$previous_image" == "1" ]]; then
    docker_command image tag "$INSTALL_BACKUP_IMAGE" "$ROLLBACK_IMAGE"
    printf '%s\n' "$previous_commit" >"$ROLLBACK_COMMIT_FILE"
  fi
  transaction_started=0
  trap - ERR INT TERM EXIT
  cleanup_systemd_backup

  log "Installation complete"
  log "Application slug: $APP_SLUG"
  log "Service: $(unit_name service)"
  log "Timer: $(unit_name timer)"
  log "Status: sudo systemctl status $(unit_name service)"
  log "Timer status: sudo systemctl status $(unit_name timer)"
}

main "$@"
