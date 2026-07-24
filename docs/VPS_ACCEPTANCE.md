# Clean Ubuntu VPS acceptance checklist

Use a disposable Ubuntu 22.04 or 24.04 VPS and dedicated test bot tokens. Do not
reuse a production token or place tokens, IP addresses, or user data in notes,
screenshots, commits, or issue reports.

This checklist validates the real Docker, systemd, network, filesystem
permissions, deployment, and rollback paths that fake-command tests cannot.

## 1. Clone and configure

- [ ] Create a repository with **Use this template**.
- [ ] Configure `origin`, protect `main`, and require the CI workflow manually.
- [ ] Clone the generated repository on the VPS:

```bash
git clone https://github.com/YOUR_ACCOUNT/YOUR_REPOSITORY.git
cd YOUR_REPOSITORY
git branch --show-current
git remote -v
```

- [ ] Confirm the branch is `main` and `origin` points to the generated
      repository.

## 2. Initial installation

```bash
./install.sh
```

- [ ] Enter a dedicated test bot token only at the hidden prompt.
- [ ] Record the application slug printed by the installer.
- [ ] Confirm `.env` exists with mode `0600`.
- [ ] Confirm `data/` and `logs/` are owned by UID/GID `10001`.

## 3. Container and health

Replace `my-test-bot` with the printed slug:

```bash
APP_SLUG=my-test-bot docker compose ps
APP_SLUG=my-test-bot docker compose logs --tail=100 bot
docker inspect --format \
  '{{.State.Running}} {{.RestartCount}} {{.State.Health.Status}} {{.Config.User}}' \
  "$(APP_SLUG=my-test-bot docker compose ps -q bot)"
```

- [ ] The container is running as `10001:10001`.
- [ ] Restart count is `0`.
- [ ] Health reaches `healthy`.
- [ ] `/start`, `/help`, and text echo work with the test bot.

## 4. systemd timer

```bash
sudo systemctl status my-test-bot-deploy.timer
sudo systemctl list-timers my-test-bot-deploy.timer
sudo systemctl cat my-test-bot-deploy.service
```

- [ ] The timer is loaded, enabled, and active.
- [ ] The service points to this repository and `origin/main`.

## 5. Deploy a new commit

- [ ] Push a harmless handler or documentation-plus-runtime test change to
      `main` from the development machine.
- [ ] Wait for the next timer check, normally about two minutes.

```bash
git rev-parse HEAD
git rev-parse origin/main
sudo systemctl status my-test-bot-deploy.service
sudo tail -n 200 logs/my-test-bot-deploy-$(date -u +%F).log
```

- [ ] The checkout advances to `origin/main`.
- [ ] Runtime changes create a new healthy container.
- [ ] The bot still responds correctly.

## 6. Broken deployment rollback

Perform this only in the disposable acceptance repository. Push a commit to
`main` that intentionally makes the Docker build fail, such as a temporary
`RUN false` line in the Dockerfile.

- [ ] The current healthy container remains available.
- [ ] Git and the local image tag return to the previous deployment.
- [ ] `data/.failed-deploy-sha` contains the broken commit.
- [ ] The same SHA is not retried on the next timer run.
- [ ] Revert the intentional failure, push the newer commit, and confirm a
      successful deployment.

## 7. Manual rollback

After two successful runtime deployments:

```bash
sudo ./scripts/rollback.sh
APP_SLUG=my-test-bot docker compose ps
git rev-parse HEAD
```

- [ ] The command asks for explicit confirmation.
- [ ] The previous commit and image are restored.
- [ ] The restored container reaches strict healthy state.
- [ ] The rolled-away SHA is recorded and not immediately redeployed.

## 8. Repeated installer and persistent state

```bash
sha256sum .env > /tmp/my-test-bot-env.before
sudo touch data/acceptance-state
sudo touch logs/acceptance-log
./install.sh
sha256sum --check /tmp/my-test-bot-env.before
test -e data/acceptance-state
test -e logs/acceptance-log
```

- [ ] The second installer run succeeds without asking for an existing token.
- [ ] Custom `.env` values remain unchanged.
- [ ] `data/` and `logs/` remain intact.
- [ ] The same unique timer remains enabled.
- [ ] Rollback commit and image state are available after an update.

Remove only the two acceptance marker files when finished.

## 9. Two generated projects on one VPS

- [ ] Repeat the clone and installation with a second generated repository.
- [ ] Use a different `APP_NAME` and a different dedicated test bot token.
- [ ] Confirm different Compose projects, images, locks, containers, deployment
      logs, services, and timers.

```bash
docker ps --format '{{.Names}} {{.Image}}'
systemctl list-timers '*-deploy.timer'
```

- [ ] Both bots remain healthy and respond independently.

## 10. Diagnostic collection

Redact tokens, repository credentials, server addresses, and user data before
sharing any output:

```bash
APP_SLUG=my-test-bot docker compose ps
APP_SLUG=my-test-bot docker compose logs --tail=200 bot
sudo journalctl -u my-test-bot-deploy.service -n 200 --no-pager
sudo systemctl status my-test-bot-deploy.timer --no-pager
sudo tail -n 200 logs/my-test-bot-deploy-$(date -u +%F).log
git status --short
git log -5 --oneline
docker info
docker compose version
```
