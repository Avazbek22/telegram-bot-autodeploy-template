<div align="center">

# 🤖 Telegram Bot Autodeploy Template

**Write handlers. Run one installer. Ship every update with `git push`.**

A small, production-minded Python template for Telegram bots running on one
Ubuntu VPS — with Docker, health checks, automatic deploys, and rollback already
wired together.

[Русская версия](docs/README.ru.md) ·
[VPS acceptance checklist](docs/VPS_ACCEPTANCE.md) ·
[Contributing](CONTRIBUTING.md)

</div>

---

Most Telegram bot examples stop at “it works on my laptop.” This template takes
care of the less exciting part too: getting a small bot onto a VPS, keeping it
healthy, and updating it safely.

You focus on handlers. The template handles the container.

## Why use it?

- **Start with a real bot, not an empty scaffold.** `/start`, `/help`, and text
  echo are ready to run and easy to replace.
- **Deploy once.** Run `install.sh` on your VPS and get a dedicated Docker
  service plus a systemd deployment timer.
- **Update with normal Git.** Push or merge to `main`; the VPS notices the new
  commit in about two minutes.
- **Fail safely.** A broken build, failed smoke test, or unhealthy container
  restores the previous commit, image, and running bot.
- **Share one VPS.** Every generated project gets its own image, container,
  lock, logs, and systemd units.
- **Keep the stack small.** No database, Redis, webhook server, reverse proxy,
  Kubernetes, or control panel unless your bot truly needs one.

> One VPS. One container. No deployment platform to babysit.

## Is this a good fit?

| Great fit | Look for a larger platform if you need |
| --- | --- |
| Personal bots and small community bots | Multiple application servers |
| Internal tools and simple automations | Zero-downtime multi-host failover |
| Long polling on one Ubuntu VPS | Webhooks or HTTP ingress |
| A straightforward Git-based release flow | Databases, workers, or distributed queues |

## Start here

### 1. Create your repository

Mark this repository as **Settings → Template repository**, then click
**Use this template**. Clone the generated repository — keep the placeholders
below when maintaining the template itself:

```bash
git clone https://github.com/YOUR_ACCOUNT/YOUR_REPOSITORY.git
cd YOUR_REPOSITORY
```

Creating a repository from the template does not install anything on a server.
Each generated project needs its own one-time VPS installation.

### 2. Run the example bot locally

```bash
python -m venv .venv
source .venv/bin/activate
python -m pip install -r requirements-dev.txt
cp .env-example .env
```

Add the token from BotFather to `.env`, then start the bot:

```bash
python main.py
```

Try `/start`, `/help`, and a regular text message.

### 3. Add your handlers

The friendly place to begin is
[`app/handlers/common.py`](app/handlers/common.py):

```python
@bot.message_handler(commands=["ping"])
def handle_ping(message: Message) -> None:
    bot.reply_to(message, "pong")
```

Keep registration inside `register_handlers(bot)`. Imports stay safe: simply
running `python -c "import main"` never needs a token, contacts Telegram, starts
threads, registers handlers, or creates files.

### 4. Install it on an Ubuntu VPS

Clone your generated repository on Ubuntu 22.04 or 24.04 and run:

```bash
git clone https://github.com/YOUR_ACCOUNT/YOUR_REPOSITORY.git
cd YOUR_REPOSITORY
./install.sh
```

The installer:

1. installs Git, Docker, Compose, `flock`, and CA certificates when needed;
2. creates `.env` only if it does not exist;
3. asks for an empty `BOT_TOKEN` without displaying it;
4. builds and smoke-tests the image;
5. starts the bot and waits for stable health;
6. enables a project-specific deployment timer.

Existing `.env`, `data/`, and `logs/` survive repeated installer runs.

### 5. From now on, just push

```bash
git add .
git commit -m "feat: add my bot feature"
git push origin main
```

The VPS checks `origin/main` approximately every two minutes. GitHub Actions
does not SSH into the server and needs no VPS secrets. Feature branches run CI
but are not deployed.

## What happens after a push?

1. The project-specific systemd timer fetches `origin/main`.
2. A fast-forward and clean checkout are required.
3. Runtime changes build a candidate Docker image.
4. The candidate checks imports, Python 3.12, settings, and Telegram `getMe`.
5. Only a valid candidate replaces the current bot.
6. Several consecutive `running=true`, restart count `0`, and
   `health=healthy` observations are required.

If any step fails, the previous Git commit, image, systemd units, and container
state are restored. The failed SHA is remembered so the timer does not retry the
same broken release forever.

Documentation-only changes update the checkout without rebuilding or
restarting the bot.

## A few useful commands

Replace `my-telegram-bot` with the application slug printed by `install.sh`.

```bash
# Is it running?
APP_SLUG=my-telegram-bot docker compose ps

# Follow bot logs
APP_SLUG=my-telegram-bot docker compose logs -f --tail=200 bot

# Check the deployment timer
sudo systemctl status my-telegram-bot-deploy.timer

# Ask for an update immediately
sudo APP_SLUG=my-telegram-bot ./scripts/deploy.sh

# Return to the previous healthy release
sudo APP_SLUG=my-telegram-bot ./scripts/rollback.sh
```

## Configuration without surprises

`.env` is the real local and production configuration. It is ignored by Git,
excluded from the Docker image, preserved during deployment, and should stay
mode `0600`.

| Variable | Default | What it controls |
| --- | --- | --- |
| `BOT_TOKEN` | empty | Required only when the bot actually starts |
| `APP_NAME` | repository directory | Unique project name on the VPS |
| `LOG_LEVEL` | `INFO` | Python log level |
| `DATA_DIR` | `data` | Persistent bot data |
| `LOGS_DIR` | `logs` | Rotated application logs |
| `POLLING_TIMEOUT_SECONDS` | `20` | Telegram polling timeout |
| `LONG_POLLING_TIMEOUT_SECONDS` | `30` | Telegram long-poll timeout |
| `HEALTH_HEARTBEAT_SECONDS` | `25` | Health marker refresh interval |
| `HEALTH_MAX_AGE_SECONDS` | `120` | Maximum healthy marker age |

`APP_NAME` becomes a safe lowercase slug and separates generated projects on
the same VPS.

`.env-example` is a sample, not a production fallback. CI uses
`ENV_FILE=.env-example docker compose config` only to validate Compose without
creating a real `.env`. Normal Docker and production deployment still require
`.env`.

<details>
<summary><strong>Local checks before pushing</strong></summary>

```bash
python -m ruff check .
python -m ruff format --check .
python -m pytest
shellcheck install.sh scripts/*.sh tests/shell/*.sh
bash tests/shell/test-deploy.sh
ENV_FILE=.env-example APP_SLUG=compose-check docker compose config --quiet
```

The shell deployment tests use fake `git`, `docker`, `systemctl`, and `flock`
commands. They do not call Telegram or modify the host.

</details>

<details>
<summary><strong>Manual Docker setup</strong></summary>

If you intentionally do not want the installer or automatic deployment:

```bash
cp .env-example .env
# Set BOT_TOKEN and APP_NAME in .env.
mkdir -p data logs
sudo chown -R 10001:10001 data logs
export APP_SLUG=my-telegram-bot
docker compose build bot
bash scripts/smoke-test.sh
docker compose up -d --no-deps bot
```

</details>

<details>
<summary><strong>When something goes wrong</strong></summary>

**Invalid `BOT_TOKEN`**

Correct `.env` and run the manual deploy again. Candidate validation calls
`getMe` before replacing the current container and redacts token-shaped output.

**Docker permission denied**

Use a sudo-capable account. The installer consistently selects direct Docker
access or `sudo docker`.

**Dirty Git checkout**

Commit and push tracked changes. Deployment refuses local edits because safely
restoring Git would otherwise be impossible.

**Container is unhealthy**

```bash
APP_SLUG=my-telegram-bot docker compose logs --tail=200 bot
sudo tail -n 200 logs/my-telegram-bot-deploy-$(date -u +%F).log
```

Also confirm that `data/` and `logs/` belong to UID/GID `10001`.

**Telegram error 409**

The same token is being polled elsewhere. One Telegram token must not run in two
bot processes or containers at the same time.

**A failed SHA is skipped**

Fix the release and push a newer commit. For a reviewed transient failure only:

```bash
sudo FORCE_DEPLOY=1 APP_SLUG=my-telegram-bot ./scripts/deploy.sh
```

**Timer is not loaded**

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now my-telegram-bot-deploy.timer
```

</details>

<details>
<summary><strong>Production safeguards</strong></summary>

- Python 3.12 slim production image; Python 3.11–3.13 tested in CI.
- Non-root UID/GID `10001`.
- Read-only root filesystem with writable mounts only for `data/` and `logs/`.
- All Linux capabilities dropped and `no-new-privileges` enabled.
- Ephemeral heartbeat marker at `/tmp/telegram-bot.healthy`.
- Daily UTC log rotation with 60 backups.
- Token redaction and no tracebacks in container stdout.
- Fast-forward-only deployment with a project-specific `flock`.
- Smoke testing before replacement and strict health stabilization afterward.
- Transactional Git, image, container, and systemd rollback.
- GitHub Actions pinned to reviewed commit SHAs.

Anyone who can merge to `main` can deploy code to the VPS. Enable branch
protection, require CI, review dependency changes, and keep Ubuntu and Docker
patched.

</details>

## Before calling it production

- [ ] Set a repository description and topics.
- [ ] Enable **Template repository** if this repository remains a template.
- [ ] Protect `main` and require the CI workflow.
- [ ] Replace the example messages and handlers.
- [ ] Add tests for your bot behavior.
- [ ] Set `APP_NAME` and `BOT_TOKEN` in the VPS `.env`.
- [ ] Run the [clean Ubuntu VPS acceptance checklist](docs/VPS_ACCEPTANCE.md).
- [ ] Test both automatic and manual rollback.

Suggested description:

> Production-ready Python Telegram bot template for a single VPS: Docker, CI,
> push-to-main auto-deploy, health checks and automatic rollback.

Suggested topics: `telegram-bot`, `telegram-bot-template`, `python`, `docker`,
`vps`, `auto-deploy`, `systemd`, `devops`, `self-hosted`.

## Honest limitations

- One bot process, one Docker container, and one Ubuntu VPS.
- Long polling only; no webhook mode.
- A short interruption is possible while Compose replaces the container.
- GitHub and Telegram must be reachable from the VPS.
- There is no multi-host failover, secret manager, or zero-downtime handoff.
- Image rollback cannot undo external side effects added by custom handlers.
- Automated tests do not replace acceptance testing on your actual VPS.

## Contributing

Issues and focused pull requests are welcome. Please read
[CONTRIBUTING.md](CONTRIBUTING.md) and never include bot tokens or unredacted
production logs.

## License

MIT — see [LICENSE](LICENSE).
