#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="${ROOT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib-production.sh
source "$SCRIPT_DIR/lib-production.sh"

resolve_app_slug

output_file="$(mktemp)"
trap 'rm -f "$output_file"' EXIT

if ! compose -p "$COMPOSE_PROJECT" -f "$ROOT_DIR/docker-compose.yml" \
  run --rm --no-deps "$SERVICE_KEY" sh -ec '
    python -c "import main"
    python -c "import app.application, app.healthcheck, app.logging_setup, app.settings"
    python -c "import sys; raise SystemExit(0 if sys.version_info[:2] == (3, 12) else 1)"
    python -c "from app.settings import load_settings; load_settings(require_token=True)"
    python -m app.smoke
  ' >"$output_file" 2>&1; then
  sed -E 's/[0-9]{5,20}:[A-Za-z0-9_-]{20,128}/<bot-token-redacted>/g' \
    "$output_file" >&2
  log "Candidate image smoke test failed"
  exit 1
fi

if grep -Eq '[0-9]{5,20}:[A-Za-z0-9_-]{20,128}' "$output_file"; then
  log "Candidate image exposed a token in smoke-test output"
  exit 1
fi
log "Candidate image passed import, Python, settings, and Telegram getMe checks"
