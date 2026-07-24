#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="${ROOT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib-production.sh
source "$SCRIPT_DIR/lib-production.sh"

DEPLOY_BRANCH="main"
old_commit=""
target_commit=""
deployment_started=0
replacement_attempted=0
previous_running=0
units_changed=0

restore_container_state() {
  if [[ "$replacement_attempted" != "1" ]]; then
    return 0
  fi
  if [[ "$previous_running" == "1" ]]; then
    compose -p "$COMPOSE_PROJECT" -f "$ROOT_DIR/docker-compose.yml" \
      up -d --no-deps --force-recreate "$SERVICE_KEY"
    wait_until_stable
  else
    compose -p "$COMPOSE_PROJECT" -f "$ROOT_DIR/docker-compose.yml" \
      stop "$SERVICE_KEY"
  fi
}

rollback_deployment() {
  local exit_code="${1:-1}"
  trap - ERR INT TERM
  if [[ "$deployment_started" == "1" ]]; then
    log "Deployment failed; restoring commit=$old_commit"
    if docker_command image inspect "$ROLLBACK_IMAGE" >/dev/null 2>&1; then
      if ! docker_command image tag "$ROLLBACK_IMAGE" "$IMAGE_NAME"; then
        log "Rollback warning: previous image tag could not be restored"
      fi
    fi
    if ! git -C "$ROOT_DIR" checkout -q -B "$DEPLOY_BRANCH" "$old_commit"; then
      log "Rollback warning: Git checkout could not be restored"
    fi
    if [[ "$units_changed" == "1" ]]; then
      if ! restore_systemd_units; then
        log "Rollback warning: systemd units could not be restored"
      fi
    fi
    if ! restore_container_state; then
      log "Rollback warning: previous container state could not be restored"
    fi
    if [[ -n "$target_commit" ]]; then
      printf '%s\n' "$target_commit" >"$FAILED_SHA_FILE"
    fi
    cleanup_systemd_backup
  fi
  exit "$exit_code"
}

validate_checkout() {
  [[ -d "$ROOT_DIR/.git" ]] || die "Not a Git checkout: $ROOT_DIR"
  [[ -f "$ROOT_DIR/.env" ]] || die "Missing $ROOT_DIR/.env; run install.sh"
  if [[ -n "$(git -C "$ROOT_DIR" status --porcelain --untracked-files=no)" ]]; then
    die "Tracked local changes detected; deployment refused"
  fi
  local branch
  branch="$(git -C "$ROOT_DIR" branch --show-current)"
  [[ "$branch" == "$DEPLOY_BRANCH" ]] ||
    die "Production checkout must stay on branch $DEPLOY_BRANCH"
}

requires_container_update() {
  local path
  while IFS= read -r path; do
    case "$path" in
      README.md | docs/* | LICENSE | CONTRIBUTING.md | SECURITY.md | CHANGELOG.md | \
        .github/* | tests/* | requirements-dev.txt | pyproject.toml | .gitattributes)
        ;;
      *)
        return 0
        ;;
    esac
  done < <(
    git -C "$ROOT_DIR" diff --name-only --diff-filter=ACDMRTUXB \
      "$old_commit" "$target_commit"
  )
  return 1
}

systemd_templates_changed() {
  git -C "$ROOT_DIR" diff --name-only "$old_commit" "$target_commit" -- \
    scripts/systemd |
    grep -q '^scripts/systemd/'
}

main() {
  mkdir -p "$ROOT_DIR/logs" "$ROOT_DIR/data"
  resolve_app_slug
  mkdir -p "$(dirname "$LOCK_FILE")"
  find "$ROOT_DIR/logs" -maxdepth 1 -type f \
    -name "$APP_SLUG-deploy-*.log" -mtime +60 -delete
  exec >>"$ROOT_DIR/logs/$APP_SLUG-deploy-$(date -u '+%Y-%m-%d').log" 2>&1

  command_exists flock || die "flock is required"
  exec 9>"$LOCK_FILE"
  if ! flock -n 9; then
    log "Another deployment is active; skipping"
    return 0
  fi

  detect_docker_access
  validate_checkout
  git -C "$ROOT_DIR" fetch -q origin \
    "+refs/heads/$DEPLOY_BRANCH:refs/remotes/origin/$DEPLOY_BRANCH"
  old_commit="$(git -C "$ROOT_DIR" rev-parse HEAD)"
  target_commit="$(git -C "$ROOT_DIR" rev-parse "refs/remotes/origin/$DEPLOY_BRANCH")"

  if [[ "$old_commit" == "$target_commit" ]]; then
    log "No update: origin/main is already deployed"
    return 0
  fi
  if [[ "${FORCE_DEPLOY:-0}" != "1" && -f "$FAILED_SHA_FILE" ]] &&
    [[ "$(tr -d '[:space:]' <"$FAILED_SHA_FILE")" == "$target_commit" ]]; then
    log "Commit=$target_commit previously failed; waiting for a newer SHA"
    return 0
  fi
  git -C "$ROOT_DIR" merge-base --is-ancestor "$old_commit" "$target_commit" ||
    die "origin/main is not a fast-forward from commit=$old_commit"

  if ! requires_container_update; then
    git -C "$ROOT_DIR" checkout -q -B "$DEPLOY_BRANCH" "$target_commit"
    rm -f "$FAILED_SHA_FILE"
    log "Docs-only deployment commit=$target_commit; container rebuild skipped"
    return 0
  fi

  docker_command image inspect "$IMAGE_NAME" >/dev/null 2>&1 ||
    die "Current image $IMAGE_NAME is unavailable"
  docker_command image tag "$IMAGE_NAME" "$ROLLBACK_IMAGE"
  if container_is_running; then
    previous_running=1
  fi
  if systemd_templates_changed; then
    units_changed=1
    backup_systemd_units
  fi

  deployment_started=1
  trap 'rollback_deployment $?' ERR INT TERM
  git -C "$ROOT_DIR" checkout -q -B "$DEPLOY_BRANCH" "$target_commit"
  if [[ "$units_changed" == "1" ]]; then
    install_systemd_units enable
  fi
  compose -p "$COMPOSE_PROJECT" -f "$ROOT_DIR/docker-compose.yml" \
    build --pull "$SERVICE_KEY"
  smoke_test_image
  replacement_attempted=1
  compose -p "$COMPOSE_PROJECT" -f "$ROOT_DIR/docker-compose.yml" \
    up -d --no-deps --force-recreate "$SERVICE_KEY"
  wait_until_stable

  printf '%s\n' "$old_commit" >"$ROLLBACK_COMMIT_FILE"
  rm -f "$FAILED_SHA_FILE"
  deployment_started=0
  trap - ERR INT TERM
  cleanup_systemd_backup
  log "Deployment successful commit=$target_commit"
}

main "$@"
