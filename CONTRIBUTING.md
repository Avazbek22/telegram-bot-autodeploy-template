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
shellcheck install.sh scripts/*.sh tests/shell/*.sh tests/e2e/*.sh
bash tests/shell/test-deploy.sh
ENV_FILE=.env-example APP_SLUG=compose-check docker compose config --quiet
bash tests/e2e/in-docker.sh
```

Production shell changes should include a case in `tests/shell/test-deploy.sh`
for the success and failure paths, and deployment behavior that depends on real
Docker belongs in `tests/e2e/run.sh`. The Compose check must not create `.env`.
Never use a real Telegram token in tests or issue reports.

Open a focused pull request and explain deployment or rollback implications.
By contributing, you agree that your contribution is licensed under the MIT
License.
