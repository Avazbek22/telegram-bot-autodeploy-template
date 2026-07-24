#!/usr/bin/env bash
set -Eeuo pipefail

REPOSITORY_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf -- "$TEST_ROOT"' EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

test_compose_config_without_env() {
  local root="$TEST_ROOT/compose-config"
  local rendered
  mkdir -p "$root"
  cp "$REPOSITORY_ROOT/docker-compose.yml" "$root/docker-compose.yml"
  cp "$REPOSITORY_ROOT/.env-example" "$root/.env-example"
  printf 'COMPOSE_CHECK_SENTINEL=from-example\n' >>"$root/.env-example"

  ENV_FILE=.env-example APP_SLUG=compose-check \
    docker compose -f "$root/docker-compose.yml" config --quiet
  rendered="$(
    ENV_FILE=.env-example APP_SLUG=compose-check \
      docker compose -f "$root/docker-compose.yml" config
  )"
  grep -q 'COMPOSE_CHECK_SENTINEL: from-example' <<<"$rendered" ||
    fail "Compose check did not use the explicitly selected example file"
  [[ ! -e "$root/.env" ]] ||
    fail "Compose config created an unexpected .env"
  if APP_SLUG=compose-check docker compose \
    -f "$root/docker-compose.yml" config --quiet >/dev/null 2>&1; then
    fail "Production Compose default unexpectedly worked without .env"
  fi
  grep -Fq "\${ENV_FILE:-.env}" "$root/docker-compose.yml" ||
    fail "Production Compose default is no longer .env"
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
  *"status --porcelain --untracked-files=no"*)
    if [[ "${FAKE_DIRTY:-0}" == "1" ]]; then
      printf ' M main.py\n'
    fi
    ;;
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
  *"checkout -q -B"*)
    checkout_target="${!#}"
    if [[ "${FAKE_FAIL_CHECKOUT_ON:-}" == "$checkout_target" &&
      ! -f "$FAKE_STATE_DIR/checkout-failed-once" ]]; then
      : >"$FAKE_STATE_DIR/checkout-failed-once"
      exit 1
    fi
    printf '%s\n' "$checkout_target" >"$FAKE_STATE_DIR/head"
    ;;
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
    image_name="${args#image inspect }"
    if [[ "${FAKE_MISSING_ROLLBACK_IMAGE:-0}" == "1" &&
      "$image_name" == *":rollback" ]]; then
      exit 1
    fi
    if [[ "${FAKE_INITIAL_INSTALL:-0}" == "1" &&
      "$image_name" == *":local" &&
      ! -f "$FAKE_STATE_DIR/image-built" ]]; then
      exit 1
    fi
    [[ "${FAKE_NO_IMAGE:-0}" != "1" ]]
    ;;
  "image tag "*) exit 0 ;;
  "inspect --format {{.State.Running}}"*)
    if [[ "${FAKE_INITIAL_INSTALL:-0}" == "1" &&
      ! -f "$FAKE_STATE_DIR/up-count" ]]; then
      printf 'false\n'
    else
      printf '%s\n' "${FAKE_RUNNING:-true}"
    fi
    ;;
  "inspect --format {{.RestartCount}}"*) printf '%s\n' "${FAKE_RESTARTS:-0}" ;;
  "inspect --format "*"State.Health"*)
    up_count=0
    if [[ -f "$FAKE_STATE_DIR/up-count" ]]; then
      up_count="$(<"$FAKE_STATE_DIR/up-count")"
    fi
    if [[ -n "${FAKE_CANDIDATE_HEALTH:-}" && "$up_count" == "1" ]]; then
      printf '%s\n' "$FAKE_CANDIDATE_HEALTH"
    else
      printf '%s\n' "${FAKE_HEALTH:-healthy}"
    fi
    ;;
  "compose "*" ps -q "*) printf '%s\n' fake-container ;;
  "compose "*" build "*)
    [[ "${FAKE_FAIL_BUILD:-0}" != "1" ]]
    : >"$FAKE_STATE_DIR/image-built"
    ;;
  "compose "*" run "*)
    if [[ "$args" == *" --no-build "* ]]; then
      printf 'unknown flag: --no-build\n' >&2
      exit 2
    fi
    [[ "${FAKE_FAIL_SMOKE:-0}" != "1" ]]
    ;;
  "compose "*" up -d "*)
    up_count=0
    if [[ -f "$FAKE_STATE_DIR/up-count" ]]; then
      up_count="$(<"$FAKE_STATE_DIR/up-count")"
    fi
    printf '%s\n' "$((up_count + 1))" >"$FAKE_STATE_DIR/up-count"
    exit 0
    ;;
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
if [[ "${FAKE_FAIL_SYSTEMD_ONCE:-0}" == "1" &&
  ! -f "$FAKE_STATE_DIR/systemctl-failed-once" ]]; then
  : >"$FAKE_STATE_DIR/systemctl-failed-once"
  exit 1
fi
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

prepare_install_case() {
  local root="$1" app_name="${2:-Example Bot}"
  prepare_case "$root" "$app_name"
  cp "$REPOSITORY_ROOT/install.sh" "$root/install.sh"
  : >"$root/install-runs.log"
}

run_installer() {
  local root="$1"
  shift
  if ! env PATH="$root/bin:$PATH" INSTALL_DIR="$root" \
    INSTALL_SKIP_PREREQUISITES=1 SYSTEMD_DIR="$root/systemd" \
    LOCK_FILE="$root/lock/example-bot-deploy.lock" \
    SYSTEMCTL=systemctl FAKE_STATE_DIR="$root" \
    FAKE_COMMAND_LOG="$root/commands.log" HEALTH_ATTEMPTS=4 \
    HEALTH_STABLE_COUNT=2 HEALTH_INTERVAL_SECONDS=0 \
    "$@" bash "$root/install.sh" </dev/null >>"$root/install-runs.log" 2>&1; then
    cat "$root/install-runs.log" >&2
    return 1
  fi
}

prepare_manual_case() {
  local root="$1"
  prepare_case "$root"
  printf 'new-commit\n' >"$root/head"
  printf 'old-commit\n' >"$root/data/.rollback-commit"
  printf 'previous service\n' >"$root/systemd/example-bot-deploy.service"
  printf 'previous timer\n' >"$root/systemd/example-bot-deploy.timer"
  printf 'state\n' >"$root/data/keep"
  printf 'log\n' >"$root/logs/keep"
  printf 'CUSTOM_SETTING=keep\n' >>"$root/.env"
  : >"$root/manual-runs.log"
}

run_manual_rollback() {
  local root="$1"
  shift
  if ! env PATH="$root/bin:$PATH" ROOT_DIR="$root" \
    LOCK_FILE="$root/lock/example-bot-deploy.lock" \
    SYSTEMD_DIR="$root/systemd" SYSTEMCTL=systemctl \
    FAKE_STATE_DIR="$root" FAKE_COMMAND_LOG="$root/commands.log" \
    HEALTH_ATTEMPTS=4 HEALTH_STABLE_COUNT=2 HEALTH_INTERVAL_SECONDS=0 \
    "$@" bash "$REPOSITORY_ROOT/scripts/rollback.sh" --yes \
    </dev/null >>"$root/manual-runs.log" 2>&1; then
    cat "$root/manual-runs.log" >&2
    return 1
  fi
}

expect_failed() {
  if "$@"; then
    fail "command unexpectedly succeeded: $*"
  fi
}

test_compose_config_without_env

success="$TEST_ROOT/success"
prepare_case "$success"
run_deploy "$success"
[[ "$(<"$success/head")" == "new-commit" ]] || fail "successful deploy did not advance Git"
grep -q 'Deployment successful commit=new-commit' "$success/logs/"*-deploy-*.log
grep -Eq ' compose .* run --rm --no-deps [^ ]+ sh -ec ' \
  "$success/commands.log" ||
  fail "candidate image was not smoke-tested with the expected Compose options"
if grep -Fq -- '--no-build' "$success/commands.log"; then
  fail "smoke test used the unsupported Compose run --no-build flag"
fi
if ! awk '
  / compose .* run --rm --no-deps / { smoke_passed = 1 }
  / compose .* up -d / && !smoke_passed { exit 1 }
  END { if (!smoke_passed) exit 1 }
' "$success/commands.log"; then
  fail "container replacement started before the candidate image smoke test"
fi

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
prepare_manual_case "$manual"
run_manual_rollback "$manual"
[[ "$(<"$manual/head")" == "old-commit" ]] || fail "manual rollback did not restore commit"
grep -q 'Manual rollback successful' "$manual/logs/"*-deploy-*.log

manual_checkout_failure="$TEST_ROOT/manual-checkout-failure"
prepare_manual_case "$manual_checkout_failure"
expect_failed run_manual_rollback "$manual_checkout_failure" \
  FAKE_FAIL_CHECKOUT_ON=old-commit
[[ "$(<"$manual_checkout_failure/head")" == "new-commit" ]] ||
  fail "manual checkout failure did not restore the current commit"
grep -q 'image tag example-bot:pre-manual-rollback example-bot:local' \
  "$manual_checkout_failure/commands.log"
grep -q 'previous service' \
  "$manual_checkout_failure/systemd/example-bot-deploy.service"
grep -q ' up -d ' "$manual_checkout_failure/commands.log" ||
  fail "manual checkout failure did not recreate the original container"

manual_systemd_failure="$TEST_ROOT/manual-systemd-failure"
prepare_manual_case "$manual_systemd_failure"
expect_failed run_manual_rollback "$manual_systemd_failure" \
  FAKE_FAIL_SYSTEMD_ONCE=1
[[ "$(<"$manual_systemd_failure/head")" == "new-commit" ]] ||
  fail "manual systemd failure did not restore the current commit"
grep -q 'previous service' \
  "$manual_systemd_failure/systemd/example-bot-deploy.service"
grep -q 'previous timer' \
  "$manual_systemd_failure/systemd/example-bot-deploy.timer"
grep -q 'image tag example-bot:pre-manual-rollback example-bot:local' \
  "$manual_systemd_failure/commands.log"

manual_unhealthy="$TEST_ROOT/manual-unhealthy"
prepare_manual_case "$manual_unhealthy"
expect_failed run_manual_rollback "$manual_unhealthy" \
  FAKE_CANDIDATE_HEALTH=unhealthy
[[ "$(<"$manual_unhealthy/head")" == "new-commit" ]] ||
  fail "unhealthy manual rollback did not restore the current commit"
[[ "$(<"$manual_unhealthy/up-count")" == "2" ]] ||
  fail "unhealthy manual rollback did not restore the running container"
grep -q 'image tag example-bot:pre-manual-rollback example-bot:local' \
  "$manual_unhealthy/commands.log"
grep -q 'previous timer' "$manual_unhealthy/systemd/example-bot-deploy.timer"
grep -q '^CUSTOM_SETTING=keep$' "$manual_unhealthy/.env"
[[ -f "$manual_unhealthy/data/keep" && -f "$manual_unhealthy/logs/keep" ]] ||
  fail "manual rollback failure removed persistent files"

manual_locked="$TEST_ROOT/manual-locked"
prepare_manual_case "$manual_locked"
expect_failed run_manual_rollback "$manual_locked" FAKE_LOCKED=1
[[ "$(<"$manual_locked/head")" == "new-commit" ]] ||
  fail "locked manual rollback changed Git"
grep -q 'Another deployment or rollback is active' "$manual_locked/manual-runs.log"

manual_dirty="$TEST_ROOT/manual-dirty"
prepare_manual_case "$manual_dirty"
expect_failed run_manual_rollback "$manual_dirty" FAKE_DIRTY=1
[[ "$(<"$manual_dirty/head")" == "new-commit" ]] ||
  fail "dirty manual rollback changed Git"
grep -q 'Tracked local changes detected' "$manual_dirty/manual-runs.log"

manual_missing_commit="$TEST_ROOT/manual-missing-commit"
prepare_manual_case "$manual_missing_commit"
rm -f "$manual_missing_commit/data/.rollback-commit"
expect_failed run_manual_rollback "$manual_missing_commit"
grep -q 'No rollback commit is recorded' "$manual_missing_commit/manual-runs.log"

manual_missing_image="$TEST_ROOT/manual-missing-image"
prepare_manual_case "$manual_missing_image"
expect_failed run_manual_rollback "$manual_missing_image" \
  FAKE_MISSING_ROLLBACK_IMAGE=1
if grep -q 'checkout -q -B main old-commit' "$manual_missing_image/commands.log"; then
  fail "manual rollback changed Git without a rollback image"
fi

initial_install="$TEST_ROOT/initial-install"
prepare_install_case "$initial_install" "Initial Bot"
rm -f "$initial_install/.env"
run_installer "$initial_install" \
  BOT_TOKEN=123456789:abcdefghijklmnopqrstuvwxyzABCDE \
  FAKE_INITIAL_INSTALL=1
[[ "$(<"$initial_install/head")" == "new-commit" ]] ||
  fail "initial installer did not update the checkout"
grep -q '^BOT_TOKEN=123456789:abcdefghijklmnopqrstuvwxyzABCDE$' \
  "$initial_install/.env"
[[ -f "$initial_install/systemd/initial-install-deploy.service" ]]
[[ -f "$initial_install/systemd/initial-install-deploy.timer" ]]
grep -q 'systemctl enable --now initial-install-deploy.timer' \
  "$initial_install/commands.log"
if [[ -f "$initial_install/data/.rollback-commit" ]]; then
  fail "initial install recorded a nonexistent previous deployment"
fi

repeated_install="$TEST_ROOT/repeated-install"
prepare_install_case "$repeated_install"
printf 'CUSTOM_SETTING=keep\n' >>"$repeated_install/.env"
cp "$repeated_install/.env" "$repeated_install/env-before"
printf 'state\n' >"$repeated_install/data/keep"
printf 'log\n' >"$repeated_install/logs/keep"
run_installer "$repeated_install"
run_installer "$repeated_install"
cmp "$repeated_install/env-before" "$repeated_install/.env"
[[ -f "$repeated_install/data/keep" && -f "$repeated_install/logs/keep" ]] ||
  fail "repeated installer removed persistent files"
if grep -q 'Telegram BOT_TOKEN:' "$repeated_install/install-runs.log"; then
  fail "repeated installer prompted for an existing BOT_TOKEN"
fi
[[ "$(<"$repeated_install/up-count")" == "2" ]] ||
  fail "repeated installer did not complete both idempotent runs"
[[ "$(find "$repeated_install/systemd" -maxdepth 1 -type f \
  -name 'example-bot-deploy.*' | wc -l)" == "2" ]] ||
  fail "repeated installer created duplicate systemd units"
grep -q 'image tag example-bot:local example-bot:install-rollback' \
  "$repeated_install/commands.log"
grep -q 'image tag example-bot:install-rollback example-bot:rollback' \
  "$repeated_install/commands.log"
[[ "$(<"$repeated_install/data/.rollback-commit")" == "new-commit" ]] ||
  fail "repeated installer did not record the previous commit"

installer_build_failure="$TEST_ROOT/installer-build-failure"
prepare_install_case "$installer_build_failure"
printf 'CUSTOM_SETTING=keep\n' >>"$installer_build_failure/.env"
printf 'state\n' >"$installer_build_failure/data/keep"
printf 'log\n' >"$installer_build_failure/logs/keep"
expect_failed run_installer "$installer_build_failure" FAKE_FAIL_BUILD=1
[[ "$(<"$installer_build_failure/head")" == "old-commit" ]] ||
  fail "installer build failure did not restore Git"
grep -q 'image tag example-bot:install-rollback example-bot:local' \
  "$installer_build_failure/commands.log"
grep -q '^CUSTOM_SETTING=keep$' "$installer_build_failure/.env"
[[ -f "$installer_build_failure/data/keep" &&
  -f "$installer_build_failure/logs/keep" ]] ||
  fail "installer build failure removed persistent files"

installer_smoke_failure="$TEST_ROOT/installer-smoke-failure"
prepare_install_case "$installer_smoke_failure"
expect_failed run_installer "$installer_smoke_failure" FAKE_FAIL_SMOKE=1
[[ "$(<"$installer_smoke_failure/head")" == "old-commit" ]] ||
  fail "installer smoke failure did not restore Git"
if grep -q ' up -d ' "$installer_smoke_failure/commands.log"; then
  fail "installer smoke failure replaced the container"
fi

installer_unhealthy="$TEST_ROOT/installer-unhealthy"
prepare_install_case "$installer_unhealthy"
expect_failed run_installer "$installer_unhealthy" \
  FAKE_CANDIDATE_HEALTH=unhealthy
[[ "$(<"$installer_unhealthy/head")" == "old-commit" ]] ||
  fail "unhealthy installer did not restore Git"
[[ "$(<"$installer_unhealthy/up-count")" == "2" ]] ||
  fail "unhealthy installer did not restore the previous container"
grep -q 'image tag example-bot:install-rollback example-bot:local' \
  "$installer_unhealthy/commands.log"

installer_health_none="$TEST_ROOT/installer-health-none"
prepare_install_case "$installer_health_none"
expect_failed run_installer "$installer_health_none" FAKE_CANDIDATE_HEALTH=none
[[ "$(<"$installer_health_none/head")" == "old-commit" ]] ||
  fail "installer accepted health=none"

installer_systemd_failure="$TEST_ROOT/installer-systemd-failure"
prepare_install_case "$installer_systemd_failure"
printf 'previous service\n' \
  >"$installer_systemd_failure/systemd/example-bot-deploy.service"
printf 'previous timer\n' \
  >"$installer_systemd_failure/systemd/example-bot-deploy.timer"
expect_failed run_installer "$installer_systemd_failure" \
  FAKE_FAIL_SYSTEMD_ONCE=1
[[ "$(<"$installer_systemd_failure/head")" == "old-commit" ]] ||
  fail "installer systemd failure did not restore Git"
grep -q 'previous service' \
  "$installer_systemd_failure/systemd/example-bot-deploy.service"
grep -q 'previous timer' \
  "$installer_systemd_failure/systemd/example-bot-deploy.timer"
[[ "$(<"$installer_systemd_failure/up-count")" == "2" ]] ||
  fail "installer systemd failure did not restore the previous container"

# shellcheck disable=SC2016
if grep -REn -- 'rm[[:space:]]+-rf[[:space:]]+(/|"\$ROOT_DIR"|\$ROOT_DIR)' \
  "$REPOSITORY_ROOT/install.sh" "$REPOSITORY_ROOT/scripts"; then
  fail "destructive broad command found"
fi
if grep -Rqn -- 'git pull' "$REPOSITORY_ROOT/scripts/deploy.sh"; then
  fail "deploy.sh contains a blind git pull"
fi

printf 'Shell deployment tests passed.\n'
