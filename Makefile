.PHONY: install lint format test shellcheck compose-check check

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
	shellcheck install.sh scripts/*.sh tests/shell/*.sh
	bash tests/shell/test-deploy.sh

compose-check:
	APP_SLUG=telegram-bot docker compose config --quiet

check: lint test shellcheck compose-check
