# opi — working on the Raspberry Pi

You are Claude Code running **on opi**, the home server: Raspberry Pi 4 (2 GB RAM), Raspberry Pi OS
Lite 64-bit, user `pi` with passwordless sudo. Sessions usually come from the **Claude mobile app**
(Remote Control), so the owner reads your replies on a phone.

## How to talk to me
- Explain what you do and why: I want to learn, not just get results. Keep it short enough for a phone.
- Ask before deleting files or making changes that are hard to undo.
- Prefer small, focused changes.

## Phone first: no laptop
This Pi is my main machine, driven from my phone. Never tell me to "run this on the laptop" or "SSH in
and run": run it yourself. When a step needs me (a sign-in link, a device code, an approval, a
password I must type), start it, then:
- in a chat session: show me the link or code in your reply and wait; I answer with the code or "done"
- in unattended jobs (timers, scripts): send it with `messenger "text"` (Telegram)
Only physical work (flashing an SSD, plugging cables) needs anything but the phone; say so plainly.

## Layout
| Where | What |
|---|---|
| `~/claude/docker` | The homelab stack: git repo `prithivirajasingh5/docker` (private). **One** `docker-compose.yml` at the repo root; run `docker compose` there. Read `README.md` (the stack), `python-jobs/README.md` (bot, ddns, printmail, pcloud, ...) and `RESTORE.md` (rebuild + troubleshooting) |
| `~/movies`, `~/movies_archive`, `~/Downloads` | Media, outside the repo (paths come from `.env`) |
| `~/claude/docker/python-jobs/jobs` | Scripts on PATH: `messenger` (Telegram), `ren`, `run`, ... |
| systemd | `claude-remote` (this session's connection), `claude-signin` (renews its sign-in), `container-watchdog.timer` (alerts on broken containers), `health-report.timer`, `claude-update.timer` (Sundays) |

`docker/CLAUDE.md` describes the stack: services, how to apply each kind of change, and secrets.

This Pi is set up by the public `pi-bootstrap` repo, cloned at `~/claude/pi-bootstrap`. Changes to how
the Pi is installed (packages, services, timers, this file) belong there: change it, re-run the
relevant script here to test (`bash ~/claude/pi-bootstrap/claude-remote.sh`, or `bootstrap.sh`), then
commit and push. Don't hand-edit system setup that pi-bootstrap would overwrite.

## Projects and GitHub
- `gh` is signed in as me (all repos, create repos, releases); git uses it for `https://github.com/...`.
  The docker repo uses its own SSH deploy key.
- Projects live in `~/claude/<name>`, like on the laptop. New ones: `/new-project` (private repo,
  git-crypt encrypted to my GPG public key). Sync state: `/git-check`; each session starts with it.
- My other repos are encrypted with my GPG key, which is **not** on this Pi: they clone, but their
  encrypted files stay locked here. Tell me if a task needs them unlocked.

## Health
- Every Sunday `health-report` sends a diagnosis to Telegram; reports are in `~/.local/state/health-report/`.
  On demand: `sudo systemctl start health-report` (or `AI=0 SEND=0 health-report` to just print facts).
- Claude Code updates itself on Sundays (`claude-update.timer`); `/usr/local/bin/claude-weekly-update` runs it now.

## Git (the laptop may work on the same repos)
- Before changing any repo: `git pull --ff-only --autostash` (the laptop may have pushed).
- Small focused commits, and **push right after every commit**.
- Never commit the apps' own runtime edits: `qbittorrent/config/qBittorrent/qBittorrent.conf` and
  `nginx/config/etc/letsencrypt/renewal/*.conf` are rewritten by the apps; leave them modified.
- Releases: an annotated tag `stable-vN` (next number), made in **both** `docker` and `pi-bootstrap`
  with the same number, on commits that run fine here together; each tag message names the other
  repo's commit. Only when I ask for a release.

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
