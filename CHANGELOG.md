# Changelog

All notable changes to this project are documented here.

## [Unreleased]

### Changed

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
