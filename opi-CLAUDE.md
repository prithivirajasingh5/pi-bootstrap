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

**Tests run in the images, never on the host.** Run the stack's tests with
`~/claude/docker/python-jobs/run-tests` (inside the `printmail` image; nothing skipped there). Plain
`python3 -m unittest` here fails to import three test modules (no `pikepdf`): that is expected. Don't
fix it by installing `pikepdf`, CUPS, LibreOffice or any other library on the Pi: nothing goes on the
host that a container already provides. If a test needs a new library, add it to the image
(`python-jobs/Dockerfile` / `requirements.txt`).

This Pi is set up by the public `pi-bootstrap` repo, cloned at `~/claude/pi-bootstrap`. Changes to how
the Pi is installed (packages, services, timers, this file) belong there: change it, re-run the
relevant script here to test (`bash ~/claude/pi-bootstrap/claude-remote.sh`, or `bootstrap.sh`), then
commit and push. Don't hand-edit system setup that pi-bootstrap would overwrite.

**Docker first.** New services, jobs and tools go into the docker stack (`~/claude/docker`, usually a
`python-jobs` container) instead of being installed on the host: a fresh Pi then only needs
pi-bootstrap + `docker compose up -d`, and containers move to other machines/architectures easily.
Install on the host only what can't live in a container (Docker itself, Claude Code, systemd units
that manage the host); those follow the interrupt rule below.

**Interrupt rule: everything you install or set up here goes into pi-bootstrap, in the same task.**
A fresh Pi must end up identical by running pi-bootstrap alone. So whenever you install a package
(`apt`, `pip`, `npm`, a binary), add a systemd service or timer, or change system config (`/etc/...`,
network, sudoers, journald, Docker daemon), stop before calling the task done and:
1. add it to pi-bootstrap: the `PACKAGES` list in `bootstrap.sh`, or a check-first step in
   `bootstrap.sh` / `claude-remote.sh` (re-runnable: skip when already done), with a comment saying why
2. re-run that script here to prove it is idempotent
3. commit and push pi-bootstrap, and mention it in your reply
One-off debugging tools you remove afterwards are the only exception; say so if you skip this.

**~/README is my cheat sheet** (pi-bootstrap's `home-README`, installed by `bootstrap.sh`): one line
per task with the exact command ("to ssh into the router: `ssh router`"), no explanations. When you
set up or change something I use (an access path, a service, a command, a bot command), add or fix
its line there in the same task, test the command, and re-run `bootstrap.sh` to install it.
Whenever `bootstrap.sh` or `claude-remote.sh` changes, check `home-README` too: a new, moved or
removed setup step may need its cheat-sheet line added or fixed.

## Projects and GitHub
- `gh` is signed in as me (all repos, create repos, releases); git uses it for `https://github.com/...`.
  The docker repo too (its old SSH deploy key is no longer used).
- Projects live in `~/claude/<name>`, like on the laptop. New ones: `/new-project` (private repo,
  git-crypt encrypted to my GPG public key). Sync state: `/git-check`; each session starts with it.
- My GPG key is on this Pi (same as the laptop), so every repo unlocks: clone, then `git-crypt unlock`.
  It has no passphrase: never export, print or copy it anywhere.

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
If I say a secret leaked (the GitHub token, the `secrets.age` passphrase, or a lost Pi), follow
"If a secret leaks" in `~/claude/pi-bootstrap/README.md`: deleting the token comes first.

## Safety
- Ask first before: `docker compose down`, `down -v`, `docker volume rm`, `docker system prune`,
  `reboot`, or stopping nginx / wireguard / smb (other people and devices use them).
- Don't stop or restart `claude-remote` or `claude-signin` unless I ask: that cuts this session off.
- 2 GB RAM: one image build at a time; check `free -h` if things get slow.
- After changing a service: `docker compose up -d <service>`, then `docker compose ps` until it is
  healthy, and look at `docker logs --tail 30 <container>`.
