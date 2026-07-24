#!/usr/bin/env bash
set -Eeuo pipefail

REPOSITORY_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf -- "$TEST_ROOT"' EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

make_fake_commands() {
  local bin="$1"
  mkdir -p "$bin"
  cat >"$bin/git" <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail
printf 'git %s\n' "$*" >>"$FAKE_COMMAND_LOG"
args="$*"
case "$args" in
  *"status --porcelain --untracked-files=no"*) exit 0 ;;
  *"branch --show-current"*) printf '%s\n' "${FAKE_BRANCH:-main}" ;;
  *"remote get-url origin"*) printf '%s\n' 'https://example.invalid/repository.git' ;;
  *"rev-parse HEAD"*) cat "$FAKE_STATE_DIR/head" ;;
  *"rev-parse refs/remotes/origin/main"*) cat "$FAKE_STATE_DIR/target" ;;
  *"merge-base --is-ancestor"*)
    [[ "${FAKE_NON_FF:-0}" != "1" ]]
    ;;
  *"diff --name-only"*"scripts/systemd"*)
    grep '^scripts/systemd/' "$FAKE_STATE_DIR/changes" || :
    ;;
  *"diff --name-only"*) cat "$FAKE_STATE_DIR/changes" ;;
  *"checkout -q -B"*) printf '%s\n' "${!#}" >"$FAKE_STATE_DIR/head" ;;
  *"pull --ff-only origin main"*) cat "$FAKE_STATE_DIR/target" >"$FAKE_STATE_DIR/head" ;;
  *"cat-file -e"*) exit 0 ;;
  *"fetch"*) exit 0 ;;
esac
SH
  cat >"$bin/docker" <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail
printf 'docker %s\n' "$*" >>"$FAKE_COMMAND_LOG"
args="$*"
case "$args" in
  "info") exit 0 ;;
  "compose version") exit 0 ;;
  "image inspect "*)
    [[ "${FAKE_NO_IMAGE:-0}" != "1" ]]
    ;;
  "image tag "*) exit 0 ;;
  "inspect --format {{.State.Running}}"*) printf '%s\n' "${FAKE_RUNNING:-true}" ;;
  "inspect --format {{.RestartCount}}"*) printf '%s\n' "${FAKE_RESTARTS:-0}" ;;
  "inspect --format "*"State.Health"*)
    printf '%s\n' "${FAKE_HEALTH:-healthy}"
    ;;
  "compose "*" ps -q "*) printf '%s\n' fake-container ;;
  "compose "*" build "*)
    [[ "${FAKE_FAIL_BUILD:-0}" != "1" ]]
    ;;
  "compose "*" run "*)
    [[ "${FAKE_FAIL_SMOKE:-0}" != "1" ]]
    ;;
  "compose "*" up -d "*) exit 0 ;;
  "compose "*" stop "*) exit 0 ;;
  "compose "*)
    exit 0
    ;;
esac
SH
  cat >"$bin/systemctl" <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail
printf 'systemctl %s\n' "$*" >>"$FAKE_COMMAND_LOG"
[[ "${FAKE_FAIL_SYSTEMD:-0}" != "1" ]]
SH
  cat >"$bin/flock" <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail
[[ "${FAKE_LOCKED:-0}" != "1" ]]
SH
  cat >"$bin/sleep" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  cat >"$bin/id" <<'SH'
#!/usr/bin/env bash
if [[ "${1:-}" == "-u" ]]; then
  printf '0\n'
else
  /usr/bin/id "$@"
fi
SH
  cat >"$bin/chown" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod 0755 "$bin/"*
}

prepare_case() {
  local root="$1" app_name="${2:-Example Bot}"
  mkdir -p "$root/.git" "$root/data" "$root/logs" "$root/bin" \
    "$root/scripts/systemd" "$root/systemd" "$root/lock"
  cp "$REPOSITORY_ROOT/docker-compose.yml" "$root/docker-compose.yml"
  cp "$REPOSITORY_ROOT/.env-example" "$root/.env-example"
  cp "$REPOSITORY_ROOT/scripts/"*.sh "$root/scripts/"
  cp "$REPOSITORY_ROOT/scripts/systemd/"* "$root/scripts/systemd/"
  printf 'BOT_TOKEN=123456789:abcdefghijklmnopqrstuvwxyzABCDE\nAPP_NAME=%s\n' \
    "$app_name" >"$root/.env"
  printf 'old-commit\n' >"$root/head"
  printf 'new-commit\n' >"$root/target"
  printf 'main.py\n' >"$root/changes"
  : >"$root/commands.log"
  make_fake_commands "$root/bin"
}

run_deploy() {
  local root="$1"
  local app_slug
  app_slug="$(
    awk -F= '$1 == "APP_NAME" {print $2; exit}' "$root/.env" |
      tr '[:upper:]' '[:lower:]' |
      sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//'
  )"
  shift
  if ! env PATH="$root/bin:$PATH" ROOT_DIR="$root" \
    LOCK_FILE="$root/lock/$app_slug-deploy.lock" \
    SYSTEMD_DIR="$root/systemd" SYSTEMCTL=systemctl \
    FAKE_STATE_DIR="$root" FAKE_COMMAND_LOG="$root/commands.log" \
    HEALTH_ATTEMPTS=6 HEALTH_STABLE_COUNT=3 HEALTH_INTERVAL_SECONDS=0 \
    "$@" bash "$REPOSITORY_ROOT/scripts/deploy.sh"; then
    cat "$root/logs/"*-deploy-*.log >&2
    return 1
  fi
}

expect_failed() {
  if "$@"; then
    fail "command unexpectedly succeeded: $*"
  fi
}

success="$TEST_ROOT/success"
prepare_case "$success"
run_deploy "$success"
[[ "$(<"$success/head")" == "new-commit" ]] || fail "successful deploy did not advance Git"
grep -q 'Deployment successful commit=new-commit' "$success/logs/"*-deploy-*.log

noop="$TEST_ROOT/noop"
prepare_case "$noop"
printf 'old-commit\n' >"$noop/target"
run_deploy "$noop"
grep -q 'already deployed' "$noop/logs/"*-deploy-*.log
if grep -q ' build ' "$noop/commands.log"; then
  fail "no-op deployment built an image"
fi

docs="$TEST_ROOT/docs"
prepare_case "$docs"
printf 'README.md\ndocs/README.ru.md\n' >"$docs/changes"
run_deploy "$docs"
grep -q 'container rebuild skipped' "$docs/logs/"*-deploy-*.log
if grep -Eq ' build | up -d ' "$docs/commands.log"; then
  fail "docs-only deployment changed the container"
fi

build_failure="$TEST_ROOT/build-failure"
prepare_case "$build_failure"
expect_failed run_deploy "$build_failure" FAKE_FAIL_BUILD=1
[[ "$(<"$build_failure/head")" == "old-commit" ]] || fail "build failure did not restore Git"
[[ "$(<"$build_failure/data/.failed-deploy-sha")" == "new-commit" ]]
grep -q 'image tag example-bot:rollback example-bot:local' "$build_failure/commands.log"

smoke_failure="$TEST_ROOT/smoke-failure"
prepare_case "$smoke_failure"
expect_failed run_deploy "$smoke_failure" FAKE_FAIL_SMOKE=1
if grep -q ' up -d ' "$smoke_failure/commands.log"; then
  fail "failed smoke test replaced the container"
fi

invalid_token="$TEST_ROOT/invalid-token"
prepare_case "$invalid_token"
expect_failed run_deploy "$invalid_token" FAKE_FAIL_SMOKE=1
if grep -q ' up -d ' "$invalid_token/commands.log"; then
  fail "invalid Telegram token replaced the container"
fi

unhealthy="$TEST_ROOT/unhealthy"
prepare_case "$unhealthy"
expect_failed run_deploy "$unhealthy" FAKE_HEALTH=unhealthy
[[ "$(grep -c ' up -d ' "$unhealthy/commands.log")" -ge 2 ]] ||
  fail "unhealthy candidate did not recreate rollback container"

health_none="$TEST_ROOT/health-none"
prepare_case "$health_none"
expect_failed run_deploy "$health_none" FAKE_HEALTH=none
[[ "$(<"$health_none/head")" == "old-commit" ]] || fail "health=none was accepted"

failed_sha="$TEST_ROOT/failed-sha"
prepare_case "$failed_sha"
printf 'new-commit\n' >"$failed_sha/data/.failed-deploy-sha"
run_deploy "$failed_sha"
grep -q 'previously failed' "$failed_sha/logs/"*-deploy-*.log
if grep -q ' build ' "$failed_sha/commands.log"; then
  fail "failed SHA was retried"
fi

preserved="$TEST_ROOT/preserved"
prepare_case "$preserved"
printf 'CUSTOM_SETTING=keep\n' >>"$preserved/.env"
printf 'state\n' >"$preserved/data/keep"
printf 'log\n' >"$preserved/logs/keep"
expect_failed run_deploy "$preserved" FAKE_FAIL_BUILD=1
grep -q '^CUSTOM_SETTING=keep$' "$preserved/.env"
[[ -f "$preserved/data/keep" && -f "$preserved/logs/keep" ]] ||
  fail "persistent files were not preserved"

units="$TEST_ROOT/units"
prepare_case "$units"
printf 'scripts/systemd/telegram-bot-deploy.timer\n' >"$units/changes"
run_deploy "$units"
[[ -f "$units/systemd/example-bot-deploy.timer" ]] ||
  fail "unique systemd timer was not installed"
grep -q 'systemctl daemon-reload' "$units/commands.log"
grep -q 'systemctl enable example-bot-deploy.timer' "$units/commands.log"

units_failure="$TEST_ROOT/units-failure"
prepare_case "$units_failure"
printf 'previous timer\n' >"$units_failure/systemd/example-bot-deploy.timer"
printf 'scripts/systemd/telegram-bot-deploy.timer\n' >"$units_failure/changes"
expect_failed run_deploy "$units_failure" FAKE_FAIL_SYSTEMD=1
grep -q 'previous timer' "$units_failure/systemd/example-bot-deploy.timer"

non_ff="$TEST_ROOT/non-ff"
prepare_case "$non_ff"
expect_failed run_deploy "$non_ff" FAKE_NON_FF=1
if grep -q 'checkout -q -B main new-commit' "$non_ff/commands.log"; then
  fail "non-fast-forward target was checked out"
fi

names_a="$TEST_ROOT/names-a"
names_b="$TEST_ROOT/names-b"
prepare_case "$names_a" "First Project"
prepare_case "$names_b" "Second Project"
run_deploy "$names_a"
run_deploy "$names_b"
grep -q 'first-project:local' "$names_a/commands.log"
grep -q 'second-project:local' "$names_b/commands.log"
[[ -f "$names_a/lock/first-project-deploy.lock" ]]
[[ -f "$names_b/lock/second-project-deploy.lock" ]]

manual="$TEST_ROOT/manual"
prepare_case "$manual"
printf 'new-commit\n' >"$manual/head"
printf 'old-commit\n' >"$manual/data/.rollback-commit"
env PATH="$manual/bin:$PATH" ROOT_DIR="$manual" \
  LOCK_FILE="$manual/lock/example-bot-deploy.lock" \
  SYSTEMD_DIR="$manual/systemd" SYSTEMCTL=systemctl \
  FAKE_STATE_DIR="$manual" FAKE_COMMAND_LOG="$manual/commands.log" \
  HEALTH_ATTEMPTS=4 HEALTH_STABLE_COUNT=2 HEALTH_INTERVAL_SECONDS=0 \
  bash "$REPOSITORY_ROOT/scripts/rollback.sh" --yes
[[ "$(<"$manual/head")" == "old-commit" ]] || fail "manual rollback did not restore commit"
grep -q 'Manual rollback successful' "$manual/logs/"*-deploy-*.log

installer="$TEST_ROOT/installer"
prepare_case "$installer"
cp "$REPOSITORY_ROOT/install.sh" "$installer/install.sh"
cp "$REPOSITORY_ROOT/scripts/"*.sh "$installer/scripts/"
printf 'CUSTOM_SETTING=keep\n' >>"$installer/.env"
printf 'state\n' >"$installer/data/keep"
printf 'log\n' >"$installer/logs/keep"
expect_failed env PATH="$installer/bin:$PATH" INSTALL_DIR="$installer" \
  INSTALL_SKIP_PREREQUISITES=1 SYSTEMD_DIR="$installer/systemd" \
  LOCK_FILE="$installer/lock/example-bot-deploy.lock" \
  SYSTEMCTL=systemctl FAKE_STATE_DIR="$installer" \
  FAKE_COMMAND_LOG="$installer/commands.log" HEALTH_ATTEMPTS=4 \
  HEALTH_STABLE_COUNT=2 HEALTH_INTERVAL_SECONDS=0 FAKE_FAIL_BUILD=1 \
  bash "$installer/install.sh"
[[ "$(<"$installer/head")" == "old-commit" ]] || fail "installer did not restore commit"
grep -q '^CUSTOM_SETTING=keep$' "$installer/.env"
[[ -f "$installer/data/keep" && -f "$installer/logs/keep" ]] ||
  fail "installer removed persistent files"

# shellcheck disable=SC2016
if grep -REn -- 'rm[[:space:]]+-rf[[:space:]]+(/|"\$ROOT_DIR"|\$ROOT_DIR)' \
  "$REPOSITORY_ROOT/install.sh" "$REPOSITORY_ROOT/scripts"; then
  fail "destructive broad command found"
fi
if grep -Rqn -- 'git pull' "$REPOSITORY_ROOT/scripts/deploy.sh"; then
  fail "deploy.sh contains a blind git pull"
fi

printf 'Shell deployment tests passed.\n'
