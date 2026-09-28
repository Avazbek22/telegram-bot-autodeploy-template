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
- **Update with normal Git.** Push or merge to `main`; the VPS deploys the new
  commit a few minutes later, as soon as its CI checks pass.
- **Fail safely.** A failed CI check, broken build, failed smoke test, crash, or
  a bot that stops receiving updates restores the previous commit, image, and
  running bot — including during the first ten minutes after a release.
- **Share one VPS.** Every generated project gets its own image, container,
  lock, logs, and systemd units, and knows nothing about the others.
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

Clone your generated repository on Ubuntu 22.04 or 24.04 — as any user and into
any directory — and run:

```bash
git clone https://github.com/YOUR_ACCOUNT/YOUR_REPOSITORY.git
cd YOUR_REPOSITORY
sudo bash install.sh
```

The installer:

1. installs Git, Docker, Compose, `flock`, `curl`, Python 3, and CA
   certificates when needed;
2. creates `.env` only if it does not exist and asks for an empty `BOT_TOKEN`
   without displaying it;
3. builds and smoke-tests the image of the checked-out commit;
4. starts the bot and waits for stable health;
5. enables this project's deployment timer and its weekly rebuild timer.

Existing `.env`, `data/`, and `logs/` survive repeated installer runs, so
running it again is also the way to repair an installation. Git keeps running
as the user who owns the checkout, so your own `git` commands keep working.

### 5. From now on, just push

```bash
git add .
git commit -m "feat: add my bot feature"
git push origin main
```

The VPS checks `origin/main` every two minutes and deploys a new commit once its
GitHub checks pass. There is no deploy branch to maintain and nothing to click.
GitHub Actions does not SSH into the server and needs no VPS secrets. Feature
branches run CI but are not deployed.

## What happens after a push?

1. The project's systemd timer fetches `origin/main`; a fast-forward and a
   clean checkout are required.
2. If the commit contains `.github/workflows`, the timer waits for its GitHub
   checks. A failed check is never deployed. If CI does not start within 30
   minutes (for example, Actions is disabled in a fork), the commit is deployed
   without it.
3. A candidate image is built. If it is identical to the running image — a
   README or test change — the checkout advances and the bot keeps running.
4. The candidate checks imports, Python 3.12, settings, and Telegram `getMe`.
5. Only a valid candidate replaces the current bot. It must run the expected
   image, report healthy, and not restart for several consecutive checks.
6. For the next ten minutes the timer keeps watching. If the new release turns
   unhealthy or restarts, the previous release comes back automatically.

"Healthy" means Telegram answered the bot's latest `getUpdates` request, so a
revoked token, a network outage, or a second instance polling the same token
(HTTP 409) all count as failures.

If any step fails, the previous Git commit, the exact image it ran, and the
container are restored. The failed commit is skipped until a newer one arrives.
A deployment interrupted by a reboot is rolled back and retried once.

Every release keeps its own image tag; the running release, the previous one,
and two older ones are kept for rollback and everything older is removed.

## A few useful commands

Run them from the project directory on the VPS.

```bash
# What runs now, what it can roll back to, what deployment is waiting for
sudo bash scripts/status.sh

# Follow bot logs
docker compose logs -f --tail=200 bot

# Deploy now instead of waiting for the timer (optional)
sudo bash scripts/deploy.sh

# Try again a commit that failed before
sudo bash scripts/deploy.sh --retry

# Deploy without waiting for CI
sudo bash scripts/deploy.sh --skip-ci

# Return to the previous release (run it again to undo)
sudo bash scripts/rollback.sh
```

After a manual rollback, the timer leaves the bot alone until the next push.

## Deployment settings

[`deploy.conf`](deploy.conf) holds the deployment settings of this bot. It is
part of the repository, so changing it is an ordinary commit.

| Setting | Default | What it controls |
| --- | --- | --- |
| `DEPLOY_BRANCH` | `main` | Branch whose commits are deployed |
| `REQUIRE_CI` | `auto` | Wait for GitHub checks: `auto`, `yes`, or `no` |
| `CI_WAIT_MINUTES` | `30` | Deploy without CI if it has not started by then |
| `REBUILD_SCHEDULE` | `Sun *-*-* 04:00:00` | Scheduled rebuild for base-image security fixes; empty disables it |
| `REBUILD_VERSION_CMD` | empty | Restart after a rebuild only when this command's output changes |
| `SMOKE_COMMAND` | empty | Extra check inside a new image before it goes live |
| `WATCH_MINUTES` | `10` | How long a fresh release is watched for automatic rollback |
| `KEEP_RELEASES` | `3` | Older releases kept for rollback |

A scheduled rebuild restarts the bot only when the image actually changed.
Bots built on a fast-moving library, such as yt-dlp, can rebuild nightly and
restart only when that library has a new version:

```dockerfile
# Dockerfile: everything after this line is rebuilt on every scheduled rebuild
ARG REBUILD_STAMP
RUN pip install --no-cache-dir --upgrade yt-dlp
```

```ini
# deploy.conf
REBUILD_SCHEDULE="*-*-* 03:30:00"
REBUILD_VERSION_CMD="python -m yt_dlp --version"
```

For a private repository, put a fine-grained GitHub token with read-only access
to "Checks" into `.deploy/github-token` (mode `0600`) so that the timer can read
CI results. Git itself uses the checkout owner's credentials, such as a deploy
key.

## Configuration without surprises

`.env` is the real local and production configuration. It is ignored by Git,
excluded from the Docker image, preserved during deployment, and should stay
mode `0600`.

| Variable | Default | What it controls |
| --- | --- | --- |
| `BOT_TOKEN` | empty | Required only when the bot actually starts |
| `APP_NAME` | repository directory | Unique project name on the VPS |
| `APP_SLUG` | written by `install.sh` | Pinned project name used by Docker and systemd |
| `LOG_LEVEL` | `INFO` | Python log level |
| `DATA_DIR` | `data` | Persistent bot data |
| `LOGS_DIR` | `logs` | Rotated application logs |
| `POLLING_TIMEOUT_SECONDS` | `20` | Telegram polling timeout |
| `LONG_POLLING_TIMEOUT_SECONDS` | `30` | Telegram long-poll timeout |
| `HEALTH_MAX_AGE_SECONDS` | `120` | Unhealthy when `getUpdates` has not succeeded for this long |
| `TELEGRAM_API_URL` | empty | Optional self-hosted Bot API server |

`APP_NAME` becomes a safe lowercase slug that separates generated projects on
the same VPS. The installer pins it as `APP_SLUG`, so renaming the directory
later never orphans the bot, and plain `docker compose` commands in the project
directory find the right project.

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
shellcheck install.sh scripts/*.sh tests/shell/*.sh tests/e2e/*.sh
bash tests/shell/test-deploy.sh
ENV_FILE=.env-example APP_SLUG=compose-check docker compose config --quiet
bash tests/e2e/in-docker.sh   # about ten minutes, needs Docker
```

The shell deployment tests use real Git repositories with simulated `docker`,
`systemctl`, `flock`, and GitHub API responses. They cover deployment, CI
gating, rollback, the watch window, scheduled rebuilds, and pruning without
calling Telegram or modifying the host.

The end-to-end test runs the real installer and deployment scripts against real
Docker, with a fake Telegram API, inside a throwaway Docker-in-Docker container
so that your own containers and images are never touched. CI runs it on every
push.

</details>

<details>
<summary><strong>Manual Docker setup</strong></summary>

If you intentionally do not want the installer or automatic deployment:

```bash
cp .env-example .env
# Set BOT_TOKEN, and APP_SLUG=my-telegram-bot, in .env.
mkdir -p data logs
sudo chown -R 10001:10001 data logs
docker compose build bot
bash scripts/smoke-test.sh
docker compose up -d --no-deps bot
```

</details>

<details>
<summary><strong>When something goes wrong</strong></summary>

Start with `sudo bash scripts/status.sh`: it shows the running release, what
deployment is waiting for, and any condition that paused it.

**Invalid `BOT_TOKEN`**

Correct `.env` and run `sudo bash install.sh` again. Candidate validation calls
`getMe` before replacing the current container and redacts token-shaped output.

**Edited files on the server**

Deployment pauses while tracked files differ from Git, because restoring a
previous release would otherwise be impossible. Commit the change from your own
machine and restore the file on the server with `git checkout -- <file>`.

**Container is unhealthy**

```bash
docker compose logs --tail=200 bot
sudo tail -n 200 logs/*-deploy-$(date -u +%F).log
```

Also confirm that `data/` and `logs/` belong to UID/GID `10001`.

**Telegram error 409**

The same token is being polled elsewhere, for example by a copy of the bot
running on your laptop. The bot then reports itself unhealthy. Use a separate
test bot token for local development.

**A failed commit is skipped**

Fix the release and push a newer commit. For a reviewed transient failure only:

```bash
sudo bash scripts/deploy.sh --retry
```

**Timer is not loaded**

Run `sudo bash install.sh` again; it reinstalls the timers of this project.

**Upgrading a bot created from an older version of this template**

Copy the new `install.sh`, `scripts/`, `deploy.conf`, and application changes
into the bot, push, and run `sudo bash install.sh` once on the server. The
running container is adopted as the current release and old rollback files and
image tags are cleaned up.

</details>

<details>
<summary><strong>Production safeguards</strong></summary>

- Python 3.12 slim production image; Python 3.11–3.13 tested in CI.
- Non-root UID/GID `10001`.
- Read-only root filesystem with writable mounts only for `data/` and `logs/`.
- All Linux capabilities dropped and `no-new-privileges` enabled.
- Health marker at `/tmp/telegram-bot.healthy`, refreshed only by successful
  `getUpdates` calls.
- Daily UTC log rotation with 60 backups.
- Token redaction and no tracebacks in container stdout.
- Fast-forward-only deployment with a project-specific `flock`.
- CI gate, smoke testing before replacement, strict health stabilization
  afterward, and a ten-minute watch window with automatic rollback.
- Releases recorded as commit plus exact image, so a rollback can never mix code
  and image of different releases.
- Recovery of deployments interrupted by a reboot or a killed process.
- Weekly rebuild that picks up base-image security fixes.
- GitHub Actions pinned to reviewed commit SHAs.

Anyone who can merge to `main` can deploy code to the VPS, and the deployment
scripts run as root. Enable branch protection, require CI, use two-factor
authentication, review dependency changes, and keep Ubuntu and Docker patched.

</details>

## Before calling it production

- [ ] Set a repository description and topics.
- [ ] Enable **Template repository** if this repository remains a template.
- [ ] Protect `main` and require the CI workflow; the VPS deploys only commits
      whose checks passed.
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
- The bot pauses for a few seconds while Compose replaces the container; two
  instances cannot poll the same token at once.
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
