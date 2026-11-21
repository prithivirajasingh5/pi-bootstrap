# pi-bootstrap

One command turns a freshly flashed Raspberry Pi into the **opi** homelab: zsh with syntax
highlighting, autosuggestions and tab completion, the media folders, and the full Docker stack from
the private [`docker`](https://github.com/prithivirajasingh5/docker) repo — cloned, decrypted and started.

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/prithivirajasingh5/pi-bootstrap/main/bootstrap.sh)
```

Run it as `pi` in an SSH session on the Pi. It is **safe to re-run**: each step checks first and
skips what is already done, so after a failure just fix the cause and run it again.

> This repo is public on purpose (so `curl` works without logging in). It holds **no plaintext secrets**:
> the only secret material is `secrets.age`, encrypted with a passphrase that is kept offline.

## Before you run it

1. Flash **Raspberry Pi OS Lite (64-bit)** to the SSD with **Raspberry Pi Imager 2.x** (Flatpak:
   `flatpak install flathub org.raspberrypi.rpi-imager`), setting hostname `opi`, user `pi`,
   and SSH with your laptop's public key. Full details: [`docker/RESTORE.md`](https://github.com/prithivirajasingh5/docker/blob/main/RESTORE.md), Part B.
2. Boot the Pi and `ssh pi@opi.local`.
3. Have your **bootstrap passphrase** ready (Google Drive → Confidential). That is the only secret you need.

## What it asks (all up front)

After the one-time sudo password, it asks **five questions** and then runs unattended:

| Prompt | When | What to give it |
|---|---|---|
| **sudo password** | only if `pi` can't sudo without one | the `pi` password set in Imager (asked once; then passwordless sudo is set up) |
| **Question 1/5 — bootstrap passphrase** | only if `gh` isn't signed in to GitHub, `~/claude/docker` needs unlocking, or your GPG key is missing | Answer Enter (yes), then type the passphrase when `age` asks. It decrypts [`secrets.age`](#secrets-bundle): `gh` signs in with the bundled **GitHub token** (no code to approve), and it supplies the git-crypt key and your GPG key |
| *(fallback)* GitHub code | if you answer `n` above, the bundle can't be opened, or it has no token (made before 2026-11-20) | `gh` shows a code: open https://github.com/login/device on your phone, enter it, approve |
| *(fallback)* git-crypt key | same | one base64 line: `cd ~/claude/docker && git-crypt export-key - \| base64 -w0; echo` (or the copy in Drive) |
| **Question 2/5 — Wi-Fi chip** | unless already disabled | `y` adds `dtoverlay=disable-wifi` to `/boot/firmware/config.txt` (default **No**). Warns first if you are connected over Wi-Fi or Ethernet has no link |
| **Question 3/5 — Bluetooth chip** | unless already disabled | `y` adds `dtoverlay=disable-bt` and disables the `bluetooth` service (default **No**) |
| **Question 4/5 — Docker stack version** | unless `--no-stack` | Lists **latest main** (default: just press Enter) and every [stable release](#stable-releases) of the `docker` repo, newest first, and shows which one the Pi runs now. Type the number or the name |
| **Question 5/5 — Claude Code Remote Control** | unless already set up (then it just re-checks, and asks for a sign-in only if the old one expired) | Enter = yes. Installs Claude Code and asks for **two things only you can do**: approve the claude.ai sign-in (open the printed URL, paste the code back) and answer `y` to *Trust /home/pi/claude?* See [Claude Code on the Pi](#claude-code-on-the-pi) |

The git-crypt key unlocks **only the `docker` repo**. Your GPG master key (which unlocks every repo)
never goes to the Pi, and the Pi's GitHub key can reach only the `docker` repo — sensible limits for
an internet-facing machine.

**Undo the chip settings:** delete the `dtoverlay=disable-wifi` / `dtoverlay=disable-bt` lines from
`/boot/firmware/config.txt` (a backup `config.txt.bak.<time>` is made before editing), run
`sudo systemctl enable bluetooth` for Bluetooth, and reboot. Disabling unused radios saves a little power
and heat; the trade-off is losing Wi-Fi as a backup link if Ethernet fails.

## What it does

| Step | |
|---|---|
| 1/8 | Passwordless sudo for `pi` (Raspberry Pi OS default; Imager's setup omits it) |
| — | Questions 1/5–4/5 (above). Question 1/5 also installs `gh` if needed and lets `git` use it for `https://github.com` |
| 2/8 | `apt install` git, git-crypt, docker.io, docker-compose (Compose v2), zsh, zsh-syntax-highlighting, zsh-autosuggestions, network monitors nload, iftop, vnstat, smartmontools (SSD health; its always-on `smartd` is switched off, see health report), gh and tcpdump |
| 3/8 | Adds `pi` to the `docker` group; caps container logs (`/etc/docker/daemon.json`: 10 MB × 3 per container); sets **backup DNS** (1.1.1.1 and 9.9.9.9 first, then the router, 2 s timeout, on the NetworkManager connection; on 2026-11-20 the router's DNS failed for 5 hours and crashed Remote Control 188 times); keeps the **system log on disk** (Pi OS keeps it in RAM only, so each reboot wiped it and it held only hours; now `/var/log/journal`, max 500 MB / 2 months); makes zsh the login shell, installs [`zshrc`](zshrc) as `~/.zshrc` (existing one backed up), which puts the stack's custom scripts (`~/claude/docker/python-jobs/jobs`: `messenger`, `ren`, `run`, …) on PATH |
| 4/8 | Creates `~/movies`, `~/movies_archive`, `~/Downloads` (paths used by the stack's `.env`) |
| 5/8 | Applies the Wi-Fi / Bluetooth choices to `config.txt` (reboot needed; the script tells you) |
| 6/8 | Git identity; **moves an old `~/docker` checkout to `~/claude/docker`** if there is one (stops the stack, removes the three bind volumes that recorded the old path; no files are deleted); clones `docker` to `~/claude/docker`, or updates an existing checkout; then switches it to the version from question 4/5 (main, or the release tag). Refuses if the checkout has local changes, except changes the apps make to their own config (`qBittorrent.conf`, certbot's `renewal/*.conf`): those are stashed, the version switched, and the Pi's values put back. If GitHub changed the same file, GitHub's version wins and the Pi's stays in `git stash list` |
| 7/8 | Unlocks it with the git-crypt key from question 1/5 (temp key file shredded afterwards) — skipped if already unlocked |
| 8/8 | `docker compose up -d --build` (recreating the containers if step 6 changed the version; builds the local images `python-jobs` and `printmail`, the email-to-print service with its own CUPS: nothing printing-related is installed on the Pi itself), waits for health checks, prints the status table; enables the **container-watchdog** timer (Telegram alerts via `messenger` for crash loops / unhealthy or stopped containers / full disk, auto-stops runaway crash loops) and the **health-report** timer (below) |

## Options

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/prithivirajasingh5/pi-bootstrap/main/bootstrap.sh) --no-stack   # zsh, folders, Wi-Fi/BT, Claude Code only
bash <(curl -fsSL https://raw.githubusercontent.com/prithivirajasingh5/pi-bootstrap/main/bootstrap.sh) --no-start   # everything but starting containers
bash <(curl -fsSL https://raw.githubusercontent.com/prithivirajasingh5/pi-bootstrap/main/bootstrap.sh) --check-secrets   # test the bundle + passphrase, change nothing
```

Non-interactive inputs (avoid on shared machines; environment variables can be seen in `ps`):
`GITHUB_TOKEN`, `GITCRYPT_KEY_B64`, `DISABLE_WIFI` / `DISABLE_BT` (`yes`/`no`), `STACK_REF` (`main` or e.g. `stable-v1`), `STACK_DIR` (default `~/claude/docker`), `CLAUDE_REMOTE` (`yes`/`no`).

## Stable releases

A release is an annotated tag `stable-vN` (numbered in sequence: `stable-v1`, `stable-v2`, …), made in
**both** repos on commits that were checked on the Pi together. Each tag's message names the other repo's
commit it pairs with (`git show stable-v1`). Tags never move; question 4/5 lists them, and `main` stays the default.

```bash
# tag a new release (laptop, in each repo, after the Pi runs this code fine)
git tag -a stable-v2 -m "stable-v2: <what changed>. Pairs with <other repo> stable-v2 (<sha>)." && git push origin stable-v2
```

To run a release's own copy of this script too (if bootstrap itself changed since), use the tag in the URL:
`https://raw.githubusercontent.com/prithivirajasingh5/pi-bootstrap/stable-v1/bootstrap.sh`.

## Secrets bundle

`secrets.age` is an [age](https://age-encryption.org) file encrypted with your passphrase (scrypt, work
factor 2^18). Inside is a tar with these fixed names:

| File | Used as |
|---|---|
| `github-token` | a classic GitHub token (note *pi-bootstrap*; scopes `repo`, `workflow`, `read:org`): `gh auth login --with-token`, then `git` uses `gh` for every `https://github.com` repo. Replaces the shared deploy key older bundles had |
| `gitcrypt.key` | the `docker` repo's git-crypt key, used once for `git-crypt unlock` and then shredded |
| `gpg-secret.asc` | **your GPG key** (since 2026-11-20), imported with ultimate trust when the Pi doesn't have it: the Pi then unlocks every git-crypt repo, like the laptop. Bundles without it still work |

- **Create / rotate** (a real terminal: laptop, or the Pi over SSH): `./make-secrets.sh`. It shows a
  prefilled link to create the GitHub token, checks it works and has the scopes, exports the git-crypt and
  GPG keys, encrypts the bundle (press Enter at age's prompt to get a strong generated passphrase; save it in
  Drive), and makes you decrypt once to prove the saved passphrase. It also offers to delete deploy keys
  left from older bundles. Then commit and push `secrets.age`; revoke the previous token if you replaced it.
- **Check** any time (on a Pi): `bootstrap.sh --check-secrets`. It proves the passphrase opens the bundle,
  the GitHub token works and has its scopes, the git-crypt key matches `~/claude/docker`, and the GPG key is yours.
- **Look inside** without writing files: `age -d secrets.age | tar -tv`.
- **Security:** the file is public, so its protection is the passphrase alone; a strong generated one is
  infeasible to brute-force. Anyone with the passphrase gets **write access to all your GitHub repos**
  (the token) **and your GPG key, which unlocks every repo** (it has no passphrase of its own). If it may
  have leaked: revoke the token at https://github.com/settings/tokens, run `make-secrets.sh` (new token +
  passphrase), and change the secrets inside your repos (git-crypt and GPG keys can't be revoked).

## After it finishes

- Log out and back in (or `exec zsh`) — the new shell and the `docker` group apply to new sessions.
- nginx may show `unhealthy` for up to ~10 minutes while it renews an expired certificate; that and
  other first-start behaviours are in the `docker` repo's [`RESTORE.md`](https://github.com/prithivirajasingh5/docker/blob/main/RESTORE.md#what-to-expect-on-first-start-after-downtime).
- Personal shell tweaks go in `~/.zshrc.local` (never overwritten).

## Claude Code on the Pi

Question 5/5 runs [`claude-remote.sh`](claude-remote.sh) (also usable on its own, same `curl` style as
`bootstrap.sh`). Afterwards the Pi appears in the **Claude mobile app → Code tab** (and on
claude.ai/code), and any session you start there runs *on the Pi*.

| | |
|---|---|
| Install | Anthropic's native installer → `~/.local/bin/claude` (on PATH via `zshrc`); `claude-update.timer` runs `claude update` on Sundays 04:30 and messages you when the version changed (Claude Code's own auto-update is off for this install) |
| Sign-in | your claude.ai subscription, stored in `~/.claude/.credentials.json` (mode 600, never in this repo) |
| Services | `claude-signin.service` (renewal, below) and `claude-remote.service`: `claude remote-control` as `pi`, started at boot, restarted 30 s after any exit |
| GitHub | `gh` signed in as you (bundled token, or a device code approved on the phone): push to every repo, create repos, releases. `git` uses it for every https URL, `~/claude/docker` included. pi-bootstrap is cloned at `~/claude/pi-bootstrap` |
| Your laptop setup | `/new-project` and `/git-check` ([`opi-claude/commands/`](opi-claude/commands)), the session-start sync check ([`opi-claude/hooks/sync-check.sh`](opi-claude/hooks/sync-check.sh)), and your GPG **public** key ([`opi-claude/gpg-public.asc`](opi-claude/gpg-public.asc)). The **secret** key comes from the secrets bundle (question 1/5), so the Pi unlocks all your repos like the laptop |
| Sessions start in | `~/claude` (`CLAUDE_WORKDIR`); Claude can still `cd` anywhere and use `sudo` |
| House rules | [`opi-CLAUDE.md`](opi-CLAUDE.md) → `~/claude/CLAUDE.md`, read by every session: **phone first** (Claude runs every command itself and sends you links/codes in the chat or by `messenger`, never "use the laptop"), layout, projects, releases, git (pull first, push after each commit), secrets, what to ask before doing. Re-running replaces it (old copy kept as `CLAUDE.md.bak.<time>`) |
| Permission mode | `auto` (`CLAUDE_PERMISSION_MODE`): a safety check approves routine actions and asks you on the phone for risky ones. Others: `default`, `acceptEdits`, `bypassPermissions` |

**Why two questions can't be automated.** Remote Control needs a real claude.ai sign-in; the
long-lived token from `claude setup-token` can only call the model, not open Remote Control. And
Claude Code accepts the folder-trust answer only from a person: a scripted `y` is rejected as
"arrived too quickly".

**The sign-in expires** after about four weeks, and using it doesn't extend it. Renewal works from
the phone: `claude-signin.service` ([`claude-signin.py`](claude-signin.py), installed as
`/usr/local/bin/claude-signin`) checks `claude auth status --json` every 30 minutes. When 5 days or
fewer are left, or you're signed out, it sends you a sign-in link via `messenger` (at most once every 20 h).
Open it, approve, and reply to the Telegram bot with `claude <code>`. The helper finishes the sign-in
and restarts `claude-remote`.

| Telegram bot | |
|---|---|
| `claude` | when the sign-in ends |
| `claude login` | send a sign-in link now (valid 30 min) |
| `claude <code>` | finish the sign-in with the code the link showed |

The helper listens only on `127.0.0.1:8765`; the bot (host networking, chat allowlist) is its only
client. The bot side lives in the `docker` repo (`telegram_bot_server.py`). Without Telegram, re-run
`claude-remote.sh` to sign in at the terminal.

**Trust and access.** Sessions run as `pi`, who has passwordless sudo: effectively root on the Pi. Your
claude.ai account is therefore a key to this machine — keep two-factor sign-in on.

```bash
journalctl -u claude-remote -f              # live log (session links, connects)
sudo systemctl restart claude-remote        # after a new sign-in or settings change
sudo systemctl disable --now claude-remote  # turn it off
journalctl -u claude-signin -f              # renewal helper log
```

## Health report

[`health-report.sh`](health-report.sh) (installed as `/usr/local/bin/health-report`, `health-report.timer`,
Sundays 10:00) collects the week: power and heat flags (`vcgencmd get_throttled`), SSD health (SMART
through the USB adapter), disk and filesystem errors, memory and out-of-memory kills, kernel warnings,
errors per service, service restarts, containers (restart counts, their error lines, watchdog alerts),
DNS failures, pending updates, the Claude sign-in and repo sync state. Then **Claude reads it next to last
week's report**, may dig with read-only commands (`journalctl`, `docker logs`, `systemctl status`; not
`docker inspect`, which would show secrets), and sends you a short diagnosis on Telegram: what is
wrong, the likely cause with evidence, and a fix. Reports stay in `~/.local/state/health-report/` (12 weeks).

```bash
sudo systemctl start health-report      # run now (diagnosis on Telegram in a few minutes)
AI=0 SEND=0 health-report               # just print the facts
```

Its first run (2026-11-20) found the router's DNS failing for five hours, which crashed Remote Control
188 times, plus CPU heat throttling at 70 °C.

## zsh setup

Matches the laptop's look without oh-my-zsh:

```
┌──(pi@opi)-[~/claude/docker]
└─$                                        (exit code ⨯ / background jobs ⚙ on the right)
```

- **Autosuggestions**: grey ghost text from history; press → or End to accept.
- **Syntax highlighting**: unknown commands turn red as you type; paths are underlined.
- **Completion**: Tab opens an arrow-key menu; case-insensitive; Shift+Tab goes back.
- Aliases: `ll`, `la`, `l`, `dc` = `docker compose`, `dps` = compact `docker ps`.

## Network monitoring

| Command | Answers |
|---|---|
| `nload eth0` | How fast right now? (live in/out graph; ←/→ switch interface, `q` quits) |
| `vnstat -l` | How fast right now? (live numbers) |
| `vnstat -d` / `vnstat -m` | How much per day / per month? (history kept by the `vnstat` service; starts empty) |
| `sudo iftop -i eth0` | What is using the bandwidth? (per connection; `q` quits) |

## Testing notes

Tested on the live opi (Pi 4, Raspberry Pi OS trixie, Nov 2026): first run installs zsh and the
plugins; a re-run skips every step; a fresh clone + unlock into a scratch directory via
`GITCRYPT_KEY_B64` produced a clean, decrypted checkout with no key files left behind. (Deploy keys were
replaced by the bundled GitHub token on 2026-11-20.)
