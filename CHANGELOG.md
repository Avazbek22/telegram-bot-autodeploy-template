# Changelog

All notable changes to this project are documented here.

## [Unreleased]

### Added

- CI gate: the VPS deploys a commit only after its GitHub checks pass, or after
  `CI_WAIT_MINUTES` if CI never starts. No deploy branch is needed.
- Ten-minute watch window that rolls a fresh release back when it turns
  unhealthy or restarts.
- Releases recorded as commit plus exact image, with an `r-<time>-<commit>` tag
  per release, pruning beyond `KEEP_RELEASES`, and manual rollback that can be
  undone by running it again.
- Weekly scheduled rebuild for base-image security fixes, with optional nightly
  rebuilds that restart only when `REBUILD_VERSION_CMD` reports a new version.
- `deploy.conf` for per-bot deployment settings and `scripts/status.sh`.
- Recovery of deployments interrupted by a reboot or a killed process.
- Optional `TELEGRAM_API_URL` for a self-hosted Bot API server.
- Real-Git shell tests and a real-Docker end-to-end test in CI.

### Changed

- The health marker is refreshed only by successful `getUpdates` calls, so a
  revoked token, a network outage, or HTTP 409 makes the bot unhealthy.
  `HEALTH_HEARTBEAT_SECONDS` is no longer used.
- Commits that do not change the image are deployed without a restart, instead
  of relying on a list of documentation paths.
- `install.sh` runs through `sudo`, deploys the checked-out commit instead of
  pulling, pins `APP_SLUG` in `.env`, and adopts an already running container.
- Git runs as the owner of the checkout, which fixes automatic deployment for
  checkouts cloned by a regular user and keeps them usable for that user.
- Deployment state moved from `data/` to `.deploy/`; the timer logs only
  events, not every quiet check.
- `stop_grace_period` is 45 seconds, longer than one long-polling cycle.
- Compose validation can use `.env-example` explicitly without creating `.env`.
- Installer and manual rollback fake-command regression coverage now includes
  successful, repeated, and transactional failure paths.
- GitHub Actions are pinned to reviewed commit SHAs.
- Candidate image smoke tests no longer use the unsupported Compose
  `run --no-build` flag, preserving compatibility with older Docker Compose v2.

## [0.1.0] - 2026-07-24

### Added

- Import-safe example bot with `/start`, `/help`, and text echo handlers.
- Docker Compose hardening and `/tmp` heartbeat healthcheck.
- Idempotent Ubuntu installer with project-specific systemd timer.
- Fast-forward deployment, candidate smoke tests, strict health stabilization,
  failed-SHA suppression, and automatic rollback.
- Manual rollback command, CI, Python tests, and fake production shell tests.
