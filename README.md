# pi-bootstrap

One command turns a freshly flashed Raspberry Pi into the **opi** homelab: zsh with syntax
highlighting, autosuggestions and tab completion, the media folders, and the full Docker stack from
the private [`docker`](https://github.com/prithivirajasingh5/docker) repo — cloned, decrypted and started.

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/prithivirajasingh5/pi-bootstrap/main/bootstrap.sh)
```

Run it as `pi` in an SSH session on the Pi. It is **safe to re-run**: each step checks first and
skips what is already done, so after a failure just fix the cause and run it again.

> This repo is public on purpose (so `curl` works without logging in). It contains **no secrets**;
> the secrets the script needs are typed at hidden prompts and never stored by it.

## Before you run it

1. Flash **Raspberry Pi OS Lite (64-bit)** to the SSD with **Raspberry Pi Imager 2.x** (Flatpak:
   `flatpak install flathub org.raspberrypi.rpi-imager`), setting hostname `opi`, user `pi`,
   and SSH with your laptop's public key. Full details: [`docker/RESTORE.md`](https://github.com/prithivirajasingh5/docker/blob/main/RESTORE.md), Part B.
2. Boot the Pi and `ssh pi@opi.local`.
3. Have the GitHub token and git-crypt key line ready (below).

## What it asks (all up front)

After the one-time sudo password, it asks **three questions** and then runs unattended:

| Prompt | When | What to give it |
|---|---|---|
| **sudo password** | only if `pi` can't sudo without one | the `pi` password set in Imager (asked once; then passwordless sudo is set up) |
| **Question 1/3 — GitHub token** | only if this Pi's deploy key isn't on GitHub yet | a [fine-grained token](https://github.com/settings/personal-access-tokens/new): *Only select repositories → `docker`*, permission *Administration: Read and write*, short expiry. The key is registered immediately and the token discarded. Press Enter instead to add the printed key by hand |
| **Question 1/3 — git-crypt key** | only if `~/docker` is missing or still encrypted | one base64 line. On a machine with the repo unlocked: `cd ~/claude/docker && git-crypt export-key - \| base64 -w0; echo` — or the copy saved in **Google Drive → Confidential**. Validated on the spot |
| **Question 2/3 — Wi-Fi chip** | unless already disabled | `y` adds `dtoverlay=disable-wifi` to `/boot/firmware/config.txt` (default **No**). Warns first if you are connected over Wi-Fi or Ethernet has no link |
| **Question 3/3 — Bluetooth chip** | unless already disabled | `y` adds `dtoverlay=disable-bt` and disables the `bluetooth` service (default **No**) |

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
| — | Questions 1/3–3/3 (above). Question 1/3 also creates `~/.ssh/id_ed25519_github` (github.com only), checks github.com's published fingerprint and registers the deploy key |
| 2/8 | `apt install` git, git-crypt, docker.io, docker-compose (Compose v2), zsh, zsh-syntax-highlighting, zsh-autosuggestions, and network monitors nload, iftop, vnstat |
| 3/8 | Adds `pi` to the `docker` group, makes zsh the login shell, installs [`zshrc`](zshrc) as `~/.zshrc` (existing one backed up) |
| 4/8 | Creates `~/movies`, `~/movies_archive`, `~/downloads_in_progress`, `~/Downloads` (paths used by the stack's `.env`) |
| 5/8 | Applies the Wi-Fi / Bluetooth choices to `config.txt` (reboot needed; the script tells you) |
| 6/8 | Git identity; clones `docker` to `~/docker`, or fast-forwards it if it exists and has no local changes |
| 7/8 | Unlocks it with the git-crypt key from question 1/3 (temp key file shredded afterwards) — skipped if already unlocked |
| 8/8 | `docker compose up -d`, waits for health checks, prints the status table |

## Options

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/prithivirajasingh5/pi-bootstrap/main/bootstrap.sh) --no-stack   # zsh, folders, Wi-Fi/BT only
bash <(curl -fsSL https://raw.githubusercontent.com/prithivirajasingh5/pi-bootstrap/main/bootstrap.sh) --no-start   # everything but starting containers
```

Non-interactive inputs (avoid on shared machines; environment variables can be seen in `ps`):
`GITHUB_TOKEN`, `GITCRYPT_KEY_B64`, `DISABLE_WIFI` / `DISABLE_BT` (`yes`/`no`), `STACK_DIR` (default `~/docker`).

## After it finishes

- Log out and back in (or `exec zsh`) — the new shell and the `docker` group apply to new sessions.
- nginx may show `unhealthy` for up to ~10 minutes while it renews an expired certificate; that and
  other first-start behaviours are in the `docker` repo's [`RESTORE.md`](https://github.com/prithivirajasingh5/docker/blob/main/RESTORE.md#what-to-expect-on-first-start-after-downtime).
- Personal shell tweaks go in `~/.zshrc.local` (never overwritten).

## zsh setup

Matches the laptop's look without oh-my-zsh:

```
┌──(pi@opi)-[~/docker]
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
`GITCRYPT_KEY_B64` produced a clean, decrypted checkout with no key files left behind; the deploy-key
API call was verified (201 created, 422 already registered).
