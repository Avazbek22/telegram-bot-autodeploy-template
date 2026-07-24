#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="${ROOT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib-production.sh
source "$SCRIPT_DIR/lib-production.sh"

assume_yes=0
if [[ "${1:-}" == "--yes" ]]; then
  assume_yes=1
elif [[ -n "${1:-}" ]]; then
  die "Usage: scripts/rollback.sh [--yes]"
  exit 2
fi

current_commit=""
rollback_commit=""
transaction_started=0
units_backed_up=0

restore_current() {
  local exit_code="${1:-1}"
  trap - ERR INT TERM
  if [[ "$transaction_started" == "1" ]]; then
    log "Manual rollback failed; restoring commit=$current_commit"
    if ! git -C "$ROOT_DIR" checkout -q -B main "$current_commit"; then
      log "Recovery warning: current Git commit could not be restored"
    fi
    if docker_command image inspect "$APP_SLUG:pre-manual-rollback" >/dev/null 2>&1; then
      if ! docker_command image tag "$APP_SLUG:pre-manual-rollback" "$IMAGE_NAME"; then
        log "Recovery warning: current image tag could not be restored"
      fi
    fi
    if [[ "$units_backed_up" == "1" ]]; then
      if ! restore_systemd_units; then
        log "Recovery warning: systemd units could not be restored"
      fi
    fi
    if ! compose -p "$COMPOSE_PROJECT" -f "$ROOT_DIR/docker-compose.yml" \
      up -d --no-deps --force-recreate "$SERVICE_KEY"; then
      log "Recovery warning: current container could not be recreated"
    elif ! wait_until_stable; then
      log "Recovery warning: current container did not stabilize"
    fi
    cleanup_systemd_backup
  fi
  exit "$exit_code"
}

main() {
  resolve_app_slug
  mkdir -p "$ROOT_DIR/logs" "$(dirname "$LOCK_FILE")"
  exec >> >(
    tee -a "$ROOT_DIR/logs/$APP_SLUG-deploy-$(date -u '+%Y-%m-%d').log"
  ) 2>&1
  detect_docker_access
  [[ -z "$(git -C "$ROOT_DIR" status --porcelain --untracked-files=no)" ]] ||
    die "Tracked local changes detected; rollback refused"
  [[ "$(git -C "$ROOT_DIR" branch --show-current)" == "main" ]] ||
    die "Production checkout must stay on branch main"

  exec 9>"$LOCK_FILE"
  if ! flock -n 9; then
    die "Another deployment or rollback is active"
    return 1
  fi
  [[ -f "$ROLLBACK_COMMIT_FILE" ]] ||
    die "No rollback commit is recorded"
  rollback_commit="$(tr -d '[:space:]' <"$ROLLBACK_COMMIT_FILE")"
  current_commit="$(git -C "$ROOT_DIR" rev-parse HEAD)"
  git -C "$ROOT_DIR" cat-file -e "$rollback_commit^{commit}"
  docker_command image inspect "$ROLLBACK_IMAGE" >/dev/null

  log "Current commit:  $current_commit"
  log "Rollback commit: $rollback_commit"
  log "Rollback image:  $ROLLBACK_IMAGE"
  if [[ "$assume_yes" != "1" ]]; then
    printf 'Type "rollback" to continue: '
    read -r confirmation
    [[ "$confirmation" == "rollback" ]] || {
      log "Rollback cancelled"
      return 1
    }
  fi

  docker_command image tag "$IMAGE_NAME" "$APP_SLUG:pre-manual-rollback"
  backup_systemd_units
  units_backed_up=1
  transaction_started=1
  trap 'restore_current $?' ERR INT TERM
  git -C "$ROOT_DIR" checkout -q -B main "$rollback_commit"
  docker_command image tag "$ROLLBACK_IMAGE" "$IMAGE_NAME"
  install_systemd_units enable
  compose -p "$COMPOSE_PROJECT" -f "$ROOT_DIR/docker-compose.yml" \
    up -d --no-deps --force-recreate "$SERVICE_KEY"
  wait_until_stable

  docker_command image tag "$APP_SLUG:pre-manual-rollback" "$ROLLBACK_IMAGE"
  printf '%s\n' "$current_commit" >"$ROLLBACK_COMMIT_FILE"
  printf '%s\n' "$current_commit" >"$FAILED_SHA_FILE"
  transaction_started=0
  trap - ERR INT TERM
  cleanup_systemd_backup
  log "Manual rollback successful commit=$rollback_commit"
}

main "$@"
