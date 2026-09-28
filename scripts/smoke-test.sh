#!/usr/bin/env bash
# Checks a candidate image before it replaces the running bot: Python version,
# imports, configuration, a real Telegram getMe with the token from .env, and
# SMOKE_COMMAND from deploy.conf. APP_IMAGE_TAG selects the image to check.
set -Eeuo pipefail

ROOT_DIR="${ROOT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib-production.sh
source "$SCRIPT_DIR/lib-production.sh"

resolve_app_slug
load_deploy_config

output_file="$(mktemp)"
trap 'rm -f "$output_file"' EXIT

run_in_image() {
  app_compose run --rm --no-deps -T "$SERVICE_KEY" sh -ec "$1" >>"$output_file" 2>&1
}

checks='
python -c "import sys; raise SystemExit(0 if sys.version_info[:2] == (3, 12) else 1)"
python -c "import main"
python -c "import app.application, app.healthcheck, app.logging_setup, app.settings"
python -c "from app.settings import load_settings; load_settings(require_token=True)"
python -m app.smoke
'

if ! run_in_image "$checks" ||
  { [[ -n "$SMOKE_COMMAND" ]] && ! run_in_image "$SMOKE_COMMAND"; }; then
  sed -E "s/$TOKEN_REGEX/<bot-token-redacted>/g" "$output_file" >&2
  log "Candidate image smoke test failed"
  exit 1
fi
if grep -Eq "$TOKEN_REGEX" "$output_file"; then
  log "Candidate image exposed a token in smoke-test output"
  exit 1
fi
log "Candidate image passed import, configuration, and Telegram getMe checks"
