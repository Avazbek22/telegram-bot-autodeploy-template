.PHONY: install lint format test shellcheck compose-check e2e check

install:
	python -m pip install -r requirements-dev.txt

lint:
	python -m ruff check .
	python -m ruff format --check .

format:
	python -m ruff check --fix .
	python -m ruff format .

test:
	python -m pytest

shellcheck:
	shellcheck install.sh scripts/*.sh tests/shell/*.sh tests/e2e/*.sh
	bash tests/shell/test-deploy.sh

compose-check:
	ENV_FILE=.env-example APP_SLUG=telegram-bot docker compose config --quiet

# Real Docker end to end, inside a throwaway Docker-in-Docker container.
e2e:
	bash tests/e2e/in-docker.sh

check: lint test shellcheck compose-check
