# Clean Ubuntu VPS acceptance checklist

Use a disposable Ubuntu 22.04 or 24.04 VPS and dedicated test bot tokens. Do not
reuse a production token or place tokens, IP addresses, or user data in notes,
screenshots, commits, or issue reports.

This checklist validates what automated tests cannot: the real systemd, network,
filesystem permissions, GitHub checks, and Telegram on your own server.

## 1. Clone and configure

- [ ] Create a repository with **Use this template**.
- [ ] Protect `main` and require the CI workflow.
- [ ] Clone the generated repository on the VPS as a regular user:

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
sudo bash install.sh
```

- [ ] Enter a dedicated test bot token only at the hidden prompt.
- [ ] Note the application slug printed by the installer; `.env` now contains
      `APP_SLUG`.
- [ ] Confirm `.env` exists with mode `0600` and belongs to your user.
- [ ] Confirm `data/` and `logs/` are owned by UID/GID `10001`.
- [ ] Confirm `git status` and `git log` still work as your own user.

## 3. Container and health

```bash
sudo bash scripts/status.sh
docker compose logs --tail=100 bot
```

- [ ] `status.sh` shows the running release with `running=true health=healthy
      restarts=0`.
- [ ] `/start`, `/help`, and text echo work with the test bot.
- [ ] Both timers are listed: `<slug>-deploy.timer` and `<slug>-rebuild.timer`.

## 4. Deploy a new commit

- [ ] Push a harmless handler change to `main` from the development machine.
- [ ] While CI runs, `status.sh` shows the commit under "Waiting" and the
      deploy log says it is waiting for CI checks.
- [ ] A few minutes after CI passes, `status.sh` shows the new commit as
      running and the previous one under "Previous".
- [ ] The bot responds with the new behavior.

## 5. Documentation-only commit

- [ ] Push a README-only change.
- [ ] `docker compose ps` shows the same container (not recreated), and
      `status.sh` shows the new commit.

## 6. Failed CI is never deployed

- [ ] Push a commit whose tests fail.
- [ ] The deploy log reports that CI failed; the running release is unchanged.
- [ ] Fix the tests and push; the fixed commit is deployed.

## 7. Broken release rollback

Perform this only in the disposable acceptance repository. Push a commit with
passing tests that crashes the bot at start, for example `raise SystemExit(3)`
as the first line of `main()` in `main.py`.

- [ ] The broken container is replaced by the previous release within about a
      minute, and the bot keeps responding.
- [ ] `status.sh` reports the broken commit as skipped.
- [ ] Revert the change and push; the newer commit is deployed.

## 8. Watch window

Within ten minutes after a successful release, start the same test bot token
on another machine (`python main.py`) so that Telegram answers the server's
`getUpdates` with 409.

- [ ] About two to three minutes later the server bot reports `unhealthy`.
- [ ] The next timer run restores the previous release and the deploy log says
      that the release became unhealthy after it started.
- [ ] Stop the second instance.

## 9. Manual rollback

```bash
sudo bash scripts/rollback.sh
sudo bash scripts/status.sh
```

- [ ] The command asks for explicit confirmation.
- [ ] The previous commit and exact image are restored and reach healthy state.
- [ ] The timer does not redeploy the rolled-back commit; the next push does.
- [ ] Running `rollback.sh` again returns to the release that was replaced.

## 10. Scheduled rebuild

```bash
sudo systemctl start <slug>-rebuild.service
sudo tail -n 20 logs/<slug>-deploy-$(date -u +%F).log
```

- [ ] With an unchanged base image, the log says the rebuild produced the same
      image and the container keeps running.

## 11. Repeated installer and persistent state

```bash
sha256sum .env > /tmp/acceptance-env.before
sudo touch data/acceptance-state logs/acceptance-log
sudo bash install.sh
sha256sum --check /tmp/acceptance-env.before
test -e data/acceptance-state && test -e logs/acceptance-log
```

- [ ] The second run succeeds without asking for the existing token and without
      restarting an unchanged bot.
- [ ] `.env`, `data/`, and `logs/` remain intact.

Remove only the two acceptance marker files when finished.

## 12. Reboot during a deployment

- [ ] Push a runtime change and reboot the VPS while `status.sh` shows the
      deployment in progress.
- [ ] After the reboot the previous release runs, and the next timer run
      deploys the commit again.

## 13. Two generated projects on one VPS

- [ ] Repeat the clone and installation with a second generated repository,
      a different `APP_NAME`, and a different test bot token.
- [ ] Confirm separate Compose projects, images, locks, containers, deploy
      logs, and timers.

```bash
docker ps --format '{{.Names}} {{.Image}}'
systemctl list-timers '*-deploy.timer' '*-rebuild.timer'
```

- [ ] Both bots remain healthy and deploy independently.

## 14. Diagnostic collection

Redact tokens, repository credentials, server addresses, and user data before
sharing any output:

```bash
sudo bash scripts/status.sh
docker compose logs --tail=200 bot
sudo journalctl -u <slug>-deploy.service -n 200 --no-pager
sudo tail -n 200 logs/<slug>-deploy-$(date -u +%F).log
git status --short
git log -5 --oneline
docker info
docker compose version
```
