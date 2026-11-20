# opi — working on the Raspberry Pi

You are Claude Code running **on opi**, the home server: Raspberry Pi 4 (2 GB RAM), Raspberry Pi OS
Lite 64-bit, user `pi` with passwordless sudo. Sessions usually come from the **Claude mobile app**
(Remote Control), so the owner reads your replies on a phone.

## How to talk to me
- Explain what you do and why: I want to learn, not just get results. Keep it short enough for a phone.
- Ask before deleting files or making changes that are hard to undo.
- Prefer small, focused changes.

## Layout
| Where | What |
|---|---|
| `~/claude/docker` | The homelab stack: git repo `prithivirajasingh5/docker` (private). **One** `docker-compose.yml` at the repo root; run `docker compose` there. Read `README.md` (the stack), `python-jobs/README.md` (bot, ddns, printmail, pcloud, ...) and `RESTORE.md` (rebuild + troubleshooting) |
| `~/movies`, `~/movies_archive`, `~/Downloads` | Media, outside the repo (paths come from `.env`) |
| `~/claude/docker/python-jobs/jobs` | Scripts on PATH: `messenger` (Telegram), `ren`, `run`, ... |
| systemd | `claude-remote` (this session's connection), `claude-signin` (renews its sign-in), `container-watchdog.timer` (alerts on broken containers) |

`docker/CLAUDE.md` describes the stack: services, how to apply each kind of change, and secrets.

This Pi is set up by the public `pi-bootstrap` repo, which lives on the laptop, not here. Changes to
how the Pi is installed belong there: tell me instead of editing system setup by hand.

## Git (the laptop works on the same repo)
- Before changing anything in `~/claude/docker`: `git pull --ff-only --autostash`.
- Small focused commits, and **push right after every commit**.
- Never commit the apps' own runtime edits: `qbittorrent/config/qBittorrent/qBittorrent.conf` and
  `nginx/config/etc/letsencrypt/renewal/*.conf` are rewritten by the apps; leave them modified.
- Don't create release tags (`stable-vN`): releases are made from the laptop after testing.

## Secrets
The repo is git-crypt **unlocked** here, so `.env`, keys and certificates are plain text. Don't print
or read whole secret files: to check a variable, test that it is set (`grep -c '^NAME=' .env`), not
its value. Never paste secrets into replies or commit messages.

## Safety
- Ask first before: `docker compose down`, `down -v`, `docker volume rm`, `docker system prune`,
  `reboot`, or stopping nginx / wireguard / smb (other people and devices use them).
- Don't stop or restart `claude-remote` or `claude-signin` unless I ask: that cuts this session off.
- 2 GB RAM: one image build at a time; check `free -h` if things get slow.
- After changing a service: `docker compose up -d <service>`, then `docker compose ps` until it is
  healthy, and look at `docker logs --tail 30 <container>`.
