## Summary

Describe the user-visible or production change.

## Verification

- [ ] `python -m ruff check .`
- [ ] `python -m ruff format --check .`
- [ ] `python -m pytest`
- [ ] `shellcheck install.sh scripts/*.sh tests/shell/*.sh`
- [ ] Deployment/rollback impact was considered
- [ ] No secrets, `.env`, runtime data, or logs were committed
