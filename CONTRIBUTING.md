# Contributing

Thank you for improving Telegram Bot Autodeploy Template.

Keep changes focused on simple Python bots running by long polling in one
container on one Ubuntu VPS. Optional databases, queues, reverse proxies, and
orchestrators belong in downstream projects rather than this minimal template.

## Development

Create a virtual environment, install `requirements-dev.txt`, and run:

```bash
python -m ruff check .
python -m ruff format --check .
python -m pytest
shellcheck install.sh scripts/*.sh tests/shell/*.sh
bash tests/shell/test-deploy.sh
```

Production shell changes should include a fake-command test for success and
failure paths. Never use a real Telegram token in tests or issue reports.

Open a focused pull request and explain deployment or rollback implications.
By contributing, you agree that your contribution is licensed under the MIT
License.
