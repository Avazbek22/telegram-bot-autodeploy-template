#!/usr/bin/env bash
# End-to-end deployment test with real Docker, Compose, and Git. Run it as root
# on a disposable Linux host with Docker (GitHub Actions, or `make e2e`, which
# uses a Docker-in-Docker container). A fake Telegram API replaces
# api.telegram.org and systemd is skipped; everything else is the real thing,
# including a checkout owned by a regular user.
set -Eeuo pipefail

SOURCE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORK="$(mktemp -d)"
DEVELOPER="e2e-developer"
SLUG="e2e-bot"
TOKEN="123456789:e2eTokenUsedOnlyByTheseTests"
API_PORT=18081
ORIGIN="$WORK/origin.git"
DEV="$WORK/dev"
SERVER="$WORK/server"
fake_pid=""

step() {
  printf '\n=== %s\n' "$*"
}

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

cleanup() {
  local code=$?
  if ((code != 0)); then
    printf '\n--- deploy log\n' >&2
    tail -n 60 "$SERVER"/logs/"$SLUG"-deploy-*.log >&2 2>/dev/null || true
    printf '\n--- bot container\n' >&2
    docker compose -p "$SLUG" -f "$SERVER/docker-compose.yml" logs --tail=40 >&2 2>/dev/null || true
  fi
  if [[ -f "$SERVER/docker-compose.yml" ]]; then
    docker compose -p "$SLUG" -f "$SERVER/docker-compose.yml" down --remove-orphans \
      >/dev/null 2>&1 || true
  fi
  docker image ls --format '{{.Repository}}:{{.Tag}}' "$SLUG" |
    xargs -r docker image rm >/dev/null 2>&1 || true
  [[ -z "$fake_pid" ]] || kill "$fake_pid" 2>/dev/null || true
  rm -rf -- "$WORK"
  exit "$code"
}
trap cleanup EXIT

as_developer() {
  runuser -u "$DEVELOPER" -- env HOME="$WORK/home" "$@"
}

dev_git() {
  as_developer git -C "$DEV" -c user.name=Developer -c user.email=dev@example.invalid "$@"
}

push_change() { # push_change MESSAGE; edits must already be made in $DEV
  dev_git add -A
  dev_git commit -q -m "$1"
  dev_git push -q origin main
  dev_git rev-parse HEAD
}

run_script() {
  env SYSTEMD_DIR="$WORK/systemd" SYSTEMCTL=true INSTALL_SKIP_PREREQUISITES=1 \
    LOCK_FILE="$WORK/deploy.lock" "$@"
}

state() {
  awk -F= -v key="$2" '$1 == key { print substr($0, length(key) + 2) }' \
    "$SERVER/.deploy/$1" 2>/dev/null || true
}

container() {
  docker compose -p "$SLUG" -f "$SERVER/docker-compose.yml" ps -a -q bot | head -n 1
}

container_field() {
  docker inspect --format "$1" "$(container)"
}

expect() {
  [[ "$1" == "$2" ]] || fail "$3 (expected '$2', got '$1')"
}

expect_healthy_release() {
  expect "$(container_field '{{.State.Health.Status}}')" "healthy" "$1: health"
  expect "$(container_field '{{.Image}}')" "$(state current image)" "$1: running image"
  # As root, git refuses the developer's checkout (dubious ownership).
  expect "$(as_developer git -C "$SERVER" rev-parse HEAD)" "$(state current commit)" \
    "$1: checkout"
}

telegram_calls() {
  python3 -c 'import json, sys; print(json.load(open(sys.argv[1])).get(sys.argv[2], 0))' \
    "$WORK/telegram.json" "$1"
}

[[ "$(id -u)" == "0" ]] || fail "run the end-to-end test as root"
docker compose version >/dev/null || fail "Docker Compose is required"

step "Prepare a developer account, a fake Telegram API, and the repositories"
chmod 0755 "$WORK"
mkdir -p "$WORK/home"
if ! id "$DEVELOPER" >/dev/null 2>&1; then
  if command -v useradd >/dev/null 2>&1; then
    useradd --no-create-home "$DEVELOPER"
  else
    adduser -D -H "$DEVELOPER"
  fi
fi
chown "$DEVELOPER" "$WORK/home"

gateway="$(ip -4 -o addr show docker0 2>/dev/null | awk '{ print $4 }' | cut -d/ -f1)"
gateway="${gateway:-172.17.0.1}"
python3 "$SOURCE_ROOT/tests/e2e/fake_telegram.py" --port "$API_PORT" \
  --stats "$WORK/telegram.json" &
fake_pid=$!

mkdir -p "$DEV" "$ORIGIN" "$SERVER"
(
  cd "$SOURCE_ROOT"
  tar --exclude=./.git --exclude=./.venv --exclude=./.deploy \
    --exclude=./.pytest_cache --exclude=./.ruff_cache --exclude='__pycache__' -cf - .
) | tar -xf - -C "$DEV"
chown -R "$DEVELOPER" "$DEV" "$ORIGIN" "$SERVER"
as_developer git init -q --bare -b main "$ORIGIN"
dev_git init -q -b main
dev_git remote add origin "$ORIGIN"
first_commit="$(push_change "Initial bot")"
as_developer git clone -q "$ORIGIN" "$SERVER"
as_developer tee "$SERVER/.env" >/dev/null <<ENV
BOT_TOKEN=$TOKEN
APP_NAME=E2E Bot
TELEGRAM_API_URL=http://$gateway:$API_PORT
POLLING_TIMEOUT_SECONDS=10
LONG_POLLING_TIMEOUT_SECONDS=5
HEALTH_MAX_AGE_SECONDS=45
ENV

step "Install from a checkout owned by a regular user"
run_script bash "$SERVER/install.sh"
expect_healthy_release "install"
expect "$(state current commit)" "$first_commit" "installed commit"
grep -q "^APP_SLUG=$SLUG\$" "$SERVER/.env" || fail "APP_SLUG was not pinned"
[[ "$(telegram_calls getMe)" -ge 2 ]] || fail "smoke test and bot did not call getMe"
foreign="$(find "$SERVER" \( -path "$SERVER/.deploy" -o -path "$SERVER/data" \
  -o -path "$SERVER/logs" \) -prune -o ! -user "$DEVELOPER" -print)"
[[ -z "$foreign" ]] || fail "root-owned files in the developer's checkout: $foreign"
as_developer git -C "$SERVER" status --porcelain >/dev/null ||
  fail "the developer can no longer use git in the checkout"

step "Deploy a new commit"
sed -i 's/Hello! I am ready./Hello from version 2!/' "$DEV/app/handlers/common.py"
second_commit="$(push_change "Friendlier greeting")"
first_image="$(state current image)"
run_script bash "$SERVER/scripts/deploy.sh"
expect_healthy_release "new commit"
expect "$(state current commit)" "$second_commit" "deployed commit"
expect "$(state previous image)" "$first_image" "previous image"
second_image="$(state current image)"
[[ "$second_image" != "$first_image" ]] || fail "the new commit did not produce a new image"

step "A documentation-only commit does not restart the bot"
container_before="$(container)"
printf '\nDeployment test note.\n' >>"$DEV/README.md"
docs_commit="$(push_change "Document the test")"
run_script bash "$SERVER/scripts/deploy.sh"
expect "$(container)" "$container_before" "container kept"
expect "$(state current commit)" "$docs_commit" "docs commit recorded"

step "Manual rollback, then deploy again with --retry"
run_script bash "$SERVER/scripts/rollback.sh" --yes
expect_healthy_release "rollback"
expect "$(state current image)" "$first_image" "rolled back image"
run_script bash "$SERVER/scripts/deploy.sh"
expect "$(state current image)" "$first_image" "the timer keeps a manual rollback"
run_script bash "$SERVER/scripts/deploy.sh" --retry
expect_healthy_release "retry"
expect "$(state current image)" "$second_image" "retried image"
expect "$(state current commit)" "$docs_commit" "retried commit"

step "A release that crashes on start is rolled back"
sed -i 's/^def main() -> int:/def main() -> int:\n    raise SystemExit(3)/' "$DEV/main.py"
crash_commit="$(push_change "Crash on start")"
if run_script bash "$SERVER/scripts/deploy.sh"; then
  fail "a crashing release was accepted"
fi
expect_healthy_release "after crash"
expect "$(state current image)" "$second_image" "image after crash"
expect "$(tr -d '[:space:]' <"$SERVER/.deploy/failed-commit")" "$crash_commit" "crash commit skipped"

step "A release that stops receiving updates is rolled back by the watch window"
sed -i '/raise SystemExit(3)/d' "$DEV/main.py"
sed -i 's#f"{api_url}/bot{{0}}/{{1}}"#f"{api_url}/conflict/bot{{0}}/{{1}}"#' \
  "$DEV/app/application.py"
conflict_commit="$(push_change "Poll through a conflicting instance")"
run_script bash "$SERVER/scripts/deploy.sh"
expect "$(state current commit)" "$conflict_commit" "the release starts healthy"
for _ in $(seq 1 60); do
  [[ "$(container_field '{{.State.Health.Status}}')" != "unhealthy" ]] || break
  sleep 5
done
expect "$(container_field '{{.State.Health.Status}}')" "unhealthy" \
  "a bot whose getUpdates fails turns unhealthy"
[[ "$(telegram_calls conflict:getUpdates)" -ge 1 ]] || fail "the conflict was not exercised"
run_script bash "$SERVER/scripts/deploy.sh"
expect_healthy_release "watch window"
expect "$(state current image)" "$second_image" "image after the watch window"
expect "$(tr -d '[:space:]' <"$SERVER/.deploy/failed-commit")" "$conflict_commit" \
  "conflicting commit skipped"

step "A scheduled rebuild with nothing new keeps the bot running"
container_before="$(container)"
run_script bash "$SERVER/scripts/deploy.sh" --rebuild
expect "$(container)" "$container_before" "container kept after rebuild"

step "Status report and housekeeping"
status_output="$(run_script bash "$SERVER/scripts/status.sh")"
grep -q "Running:   ${docs_commit:0:7}" <<<"$status_output" ||
  fail "status does not show the running release: $status_output"
[[ -z "$(docker image ls -q --filter dangling=true)" ]] || fail "dangling images were left behind"
releases="$(docker image ls --format '{{.Tag}}' "$SLUG" | grep -c '^r-' || true)"
((releases <= 4)) || fail "too many release images kept: $releases"
if grep -rqF "$TOKEN" "$SERVER/logs"; then
  fail "the bot token appeared in a log file"
fi

printf '\nEnd-to-end deployment test passed.\n'
