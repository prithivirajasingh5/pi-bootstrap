#!/usr/bin/env bash
# =============================================================================
# pi-bootstrap — fresh Raspberry Pi OS  ->  zsh + the "opi" Docker homelab
#
#   bash <(curl -fsSL https://raw.githubusercontent.com/prithivirajasingh5/pi-bootstrap/main/bootstrap.sh)
#
# Options:
#   --no-stack   only shell setup, folders and Wi-Fi/Bluetooth choices (no GitHub, clone, unlock or docker start)
#   --no-start   do everything except `docker compose up -d`
#   --check-secrets  only test the published secrets.age: decrypt it with your passphrase, prove the
#                    bundled deploy key works on GitHub and the git-crypt key matches ~/docker (changes nothing)
#   -h, --help
#
# Flow: sudo setup -> three questions (1/3 GitHub, 2/3 Wi-Fi chip, 3/3 Bluetooth chip) -> the rest
# runs unattended. Safe to re-run: every step checks first and skips what is already done.
# Secrets are only ever typed at hidden prompts; nothing secret is stored by this script
# except what git-crypt itself keeps in ~/docker/.git/git-crypt/keys/.
#
# Question 1/3 normally needs only your bootstrap passphrase: it decrypts secrets.age (made by
# make-secrets.sh) holding a shared deploy key + the git-crypt key. Fallback: GitHub token + pasted key.
#
# Optional non-interactive inputs (avoid on shared machines: env vars can leak via `ps`):
#   GITHUB_TOKEN       token used once to register the Pi's deploy key
#   GITCRYPT_KEY_B64   base64 of `git-crypt export-key -` for the docker repo
#   DISABLE_WIFI       yes/no — answer question 2/3
#   DISABLE_BT         yes/no — answer question 3/3
#   STACK_DIR          where to clone the repo (default ~/docker)
# =============================================================================
set -Eeuo pipefail

REPO_OWNER="prithivirajasingh5"
REPO_NAME="docker"
REPO_SSH="git@github.com:${REPO_OWNER}/${REPO_NAME}.git"
BOOTSTRAP_RAW="https://raw.githubusercontent.com/${REPO_OWNER}/pi-bootstrap/main"
STACK_DIR="${STACK_DIR:-$HOME/docker}"
DEPLOY_KEY="$HOME/.ssh/id_ed25519_github"
GIT_NAME="Prithivirajasingh K"
GIT_EMAIL="prithivirajasingh5@gmail.com"
MEDIA_DIRS=(movies movies_archive downloads_in_progress Downloads)   # must match .env paths
GITHUB_ED25519_FP="SHA256:+DiY3wvvV6TuJJhbpZisF/zLDA0zPMSvHdkr4UvCOqU"  # github.com's published key
PACKAGES=(git git-crypt docker.io docker-compose zsh zsh-syntax-highlighting zsh-autosuggestions curl ca-certificates
          nload iftop vnstat)   # network: live graph / per-connection / live + daily-monthly history
SECRETS_URL="$BOOTSTRAP_RAW/secrets.age"
CONFIG_TXT=/boot/firmware/config.txt; [ -f "$CONFIG_TXT" ] || CONFIG_TXT=/boot/config.txt   # older Pi OS

DO_STACK=1
DO_START=1
CHECK_SECRETS=0
for arg in "$@"; do
  case "$arg" in
    --check-secrets) CHECK_SECRETS=1 ;;
    --no-stack) DO_STACK=0 ;;
    --no-start) DO_START=0 ;;
    -h|--help) sed -n '2,29p' "$0" 2>/dev/null || true; exit 0 ;;
    *) echo "Unknown option: $arg (see --help)" >&2; exit 2 ;;
  esac
done

# ---- output helpers --------------------------------------------------------------------
STEP=""
step() { STEP="$*"; printf '\n\033[1;32m==> %s\033[0m\n' "$*"; }
ques() { STEP="$*"; printf '\n\033[1;36m?? %s\033[0m\n' "$*"; }
info() { printf '    %s\n' "$*"; }
ok()   { printf '    \033[32m✓\033[0m %s\n' "$*"; }
warn() { printf '    \033[1;33m! %s\033[0m\n' "$*"; }
die()  { printf '\n\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }
# Report only failures of the main shell, not harmless non-matches inside $(...) subshells.
trap '[ "$BASH_SUBSHELL" -eq 0 ] && printf "\n\033[1;31mFailed during: %s (line %s)\033[0m\nFix the problem and re-run; completed steps are skipped.\n" "$STEP" "$LINENO" >&2' ERR

# The git-crypt key lives in a temp file between question 1/3 and the unlock step; always shred it.
KEYFILE=""
BUNDLE_DIR=""
cleanup() {
  if [ -n "$KEYFILE" ] && [ -f "$KEYFILE" ]; then shred -u "$KEYFILE"; fi
  if [ -n "$BUNDLE_DIR" ] && [ -d "$BUNDLE_DIR" ]; then find "$BUNDLE_DIR" -type f -exec shred -u {} + 2>/dev/null || true; rm -rf "$BUNDLE_DIR"; fi
}
trap cleanup EXIT

# Prompts read from the terminal, so they also work when the script itself arrives on stdin.
ask()        { local v; read -r -p "$1" v </dev/tty; printf '%s' "$v"; }
ask_secret() { local v; read -r -s -p "$1" v </dev/tty; echo >/dev/tty; printf '%s' "$v"; }
is_yes()     { [[ "${1,,}" =~ ^(y|yes)$ ]]; }

# Where to read companion files (zshrc) from: next to the script if run from a clone, else GitHub.
SCRIPT_DIR=""
if [ -f "${BASH_SOURCE[0]:-}" ] && [ -f "$(dirname "${BASH_SOURCE[0]}")/zshrc" ]; then
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fi
fetch() {  # fetch <name> <dest>
  if [ -n "$SCRIPT_DIR" ]; then cp "$SCRIPT_DIR/$1" "$2"; else curl -fsSL "$BOOTSTRAP_RAW/$1" -o "$2"; fi
}

# `ssh -T git@github.com` always exits 1 (GitHub refuses a shell), so with pipefail a direct
# `ssh ... | grep -q` would always look like failure. Capture the greeting, then test it.
# -n: ssh must not read stdin, or it swallows anything typed ahead for the next prompt.
github_greeting() { ssh -n -T -o BatchMode=yes git@github.com 2>&1 || true; }
github_ok() { local g; g="$(github_greeting)"; [[ "$g" == *"successfully authenticated"* ]]; }
is_locked() { [ "$(head -c 9 "$STACK_DIR/.env" 2>/dev/null | tail -c 8)" = "GITCRYPT" ]; }
overlay_set() { grep -qx "dtoverlay=$1" "$CONFIG_TXT"; }

# Download secrets.age and decrypt it into BUNDLE_DIR (age prompts for the passphrase on the terminal).
open_bundle() {
  command -v age >/dev/null || { info "installing age (decrypts the bundle)"; sudo DEBIAN_FRONTEND=noninteractive NEEDRESTART_SUSPEND=1 apt-get install -y -qq age >/dev/null; }
  BUNDLE_DIR="$(mktemp -d)"; chmod 700 "$BUNDLE_DIR"
  if [ -n "$SCRIPT_DIR" ] && [ -f "$SCRIPT_DIR/secrets.age" ]; then cp "$SCRIPT_DIR/secrets.age" "$BUNDLE_DIR/secrets.age"
  else curl -fsSL "$SECRETS_URL" -o "$BUNDLE_DIR/secrets.age" 2>/dev/null || { warn "no secrets.age published at $SECRETS_URL"; return 1; }; fi
  local attempt
  for attempt in 1 2 3; do
    info "enter your bootstrap passphrase (Google Drive -> Confidential); input is hidden"
    if age -d -o "$BUNDLE_DIR/bundle.tar" "$BUNDLE_DIR/secrets.age" </dev/tty; then
      tar -C "$BUNDLE_DIR" -xf "$BUNDLE_DIR/bundle.tar" && rm -f "$BUNDLE_DIR/bundle.tar"
      [ -s "$BUNDLE_DIR/deploy_key" ] && [ -s "$BUNDLE_DIR/gitcrypt.key" ] || { warn "bundle is missing files"; return 1; }
      ok "bundle decrypted"; return 0
    fi
    warn "could not decrypt (wrong passphrase?) — attempt $attempt/3"
  done
  return 1
}
# Does a given private key authenticate to GitHub? (Isolated from ~/.ssh/config and any agent.)
key_works() {
  local g
  g="$(ssh -n -T -F /dev/null -o BatchMode=yes -o IdentitiesOnly=yes -o IdentityAgent=none -o UserKnownHostsFile="$HOME/.ssh/known_hosts" -i "$1" git@github.com 2>&1 || true)"
  [[ "$g" == *"successfully authenticated"* ]]
}

# =========================================================================================
step "Preflight"
[ "$(id -u)" -ne 0 ] || die "Run as your normal user (pi), not root. The script uses sudo where needed."
[ -r /etc/debian_version ] || die "This script expects Debian / Raspberry Pi OS."
[ -e /dev/tty ] || die "No terminal available for prompts. Run it from an interactive SSH session."
info "user=$USER  host=$(hostname)  os=$(. /etc/os-release && echo "$PRETTY_NAME")  arch=$(uname -m)"

# =========================================================================================
step "Step 1/8  Passwordless sudo"
if sudo -n true 2>/dev/null; then
  ok "already passwordless"
else
  info "Raspberry Pi OS normally allows 'pi' to sudo without a password; Imager's setup leaves it out."
  info "Enter your password once so this can be set up (or Ctrl+C to stop)."
  sudo -v
  tmp="$(mktemp)"
  echo "$USER ALL=(ALL) NOPASSWD: ALL" >"$tmp"
  sudo visudo -cf "$tmp" >/dev/null || die "generated sudoers line failed validation"
  sudo install -m 0440 -o root -g root "$tmp" "/etc/sudoers.d/010_${USER}-nopasswd"
  rm -f "$tmp"
  ok "added /etc/sudoers.d/010_${USER}-nopasswd (undo: sudo rm that file)"
fi

if [ "$CHECK_SECRETS" -eq 1 ]; then
  step "Check secrets.age (read-only)"
  [ -f "$HOME/.ssh/known_hosts" ] && ssh-keygen -F github.com >/dev/null 2>&1 || die "github.com is not in ~/.ssh/known_hosts yet; run the normal bootstrap first"
  open_bundle || die "could not open the bundle"
  if key_works "$BUNDLE_DIR/deploy_key"; then ok "bundled deploy key authenticates to GitHub ($(ssh-keygen -lf "$BUNDLE_DIR/deploy_key.pub" | awk '{print $2}'))"
  else die "bundled deploy key is NOT accepted by GitHub (revoked?) — re-run make-secrets.sh"; fi
  if [ -f "$STACK_DIR/.git/git-crypt/keys/default" ]; then
    cmp -s "$BUNDLE_DIR/gitcrypt.key" "$STACK_DIR/.git/git-crypt/keys/default" \
      && ok "bundled git-crypt key is identical to the key $STACK_DIR uses" \
      || die "bundled git-crypt key differs from $STACK_DIR's key"
  else
    [ "$(head -c 9 "$BUNDLE_DIR/gitcrypt.key" | tail -c 8)" = "GITCRYPT" ] && ok "bundled git-crypt key has a valid header ($STACK_DIR not unlocked here to compare)"
  fi
  step "secrets.age is good: your passphrase restores a fresh Pi"
  exit 0
fi

printf '\n\033[1mThree questions first; everything after them runs unattended.\033[0m\n'

# =========================================================================================
ques "Question 1/3  GitHub access and secrets"
if [ "$DO_STACK" -eq 0 ]; then
  ok "not needed (--no-stack)"
else
  # Deploy key, used only for github.com, and github.com's host key (checked against the published one).
  mkdir -p "$HOME/.ssh"; chmod 700 "$HOME/.ssh"
  [ -f "$DEPLOY_KEY" ] || { ssh-keygen -q -t ed25519 -N "" -C "$(hostname) ${REPO_NAME} deploy key" -f "$DEPLOY_KEY"; info "created deploy key $DEPLOY_KEY"; }
  touch "$HOME/.ssh/config"; chmod 600 "$HOME/.ssh/config"
  grep -q '^Host github.com' "$HOME/.ssh/config" || \
    printf 'Host github.com\n    User git\n    IdentityFile %s\n    IdentitiesOnly yes\n' "$DEPLOY_KEY" >>"$HOME/.ssh/config"
  if ! ssh-keygen -F github.com >/dev/null 2>&1; then
    hk="$(mktemp)"; ssh-keyscan -t ed25519 github.com 2>/dev/null >"$hk"
    fp="$(ssh-keygen -lf "$hk" | awk '{print $2}')"
    [ "$fp" = "$GITHUB_ED25519_FP" ] || { rm -f "$hk"; die "github.com host key fingerprint $fp does not match the published $GITHUB_ED25519_FP"; }
    cat "$hk" >>"$HOME/.ssh/known_hosts"; rm -f "$hk"; info "trusted github.com ($fp, matches GitHub's published key)"
  fi

  need_github=0; github_ok || need_github=1
  need_key=0; { [ -d "$STACK_DIR/.git" ] && ! is_locked; } || need_key=1
  [ "$need_github" -eq 0 ] && { g="$(github_greeting)"; g="${g#*Hi }"; ok "GitHub already accepts this Pi's key: Hi ${g%%!*}"; }
  [ "$need_key" -eq 0 ] && ok "$STACK_DIR is already unlocked; no git-crypt key needed"

  # Preferred: one passphrase opens secrets.age (shared deploy key + git-crypt key).
  if [ "$need_github" -eq 1 ] || [ "$need_key" -eq 1 ]; then
    use_bundle=0
    if [ -z "${GITHUB_TOKEN:-}${GITCRYPT_KEY_B64:-}" ]; then
      a="$(ask "    Use your bootstrap passphrase to unlock the secrets bundle? [Y/n] (n = GitHub token + pasted key) ")"
      [[ "${a,,}" =~ ^(n|no)$ ]] || use_bundle=1
    fi
    if [ "$use_bundle" -eq 1 ] && open_bundle; then
      if [ "$need_github" -eq 1 ]; then
        if [ -f "$DEPLOY_KEY" ]; then mv "$DEPLOY_KEY" "$DEPLOY_KEY.bak.$(date +%s)"; mv "$DEPLOY_KEY.pub" "$DEPLOY_KEY.pub.bak.$(date +%s)" 2>/dev/null || true; info "backed up the existing (unregistered) deploy key"; fi
        install -m 600 "$BUNDLE_DIR/deploy_key" "$DEPLOY_KEY"; install -m 644 "$BUNDLE_DIR/deploy_key.pub" "$DEPLOY_KEY.pub"
        github_ok || die "the bundled deploy key is not accepted by GitHub (revoked? re-run make-secrets.sh)"
        ok "installed the shared deploy key from the bundle; GitHub accepts it"; need_github=0
      fi
      if [ "$need_key" -eq 1 ]; then
        KEYFILE="$(mktemp)"; chmod 600 "$KEYFILE"; cp "$BUNDLE_DIR/gitcrypt.key" "$KEYFILE"
        ok "git-crypt key taken from the bundle (temp file, shredded after step 7)"; need_key=0
      fi
    elif [ "$use_bundle" -eq 1 ]; then
      warn "falling back to GitHub token + pasted git-crypt key"
    fi
  fi

  # Fallback (a): GitHub token -> register this Pi's own deploy key now, then forget the token.
  if [ "$need_github" -eq 1 ]; then
    pub="$(cat "$DEPLOY_KEY.pub")"
    token="${GITHUB_TOKEN:-}"
    if [ -z "$token" ]; then
      info "This Pi's key is not on GitHub yet. A token lets me add it as a deploy key on ${REPO_OWNER}/${REPO_NAME}."
      info "Create one at https://github.com/settings/personal-access-tokens/new"
      info "  Repository access: Only select repositories -> ${REPO_NAME};  Permissions: Administration = Read and write"
      info "  (a short expiry like 1 day is fine; it is used once and never stored)"
      token="$(ask_secret "    GitHub token (hidden; press Enter to add the key by hand instead): ")"
    fi
    if [ -n "$token" ]; then
      api="https://api.github.com/repos/${REPO_OWNER}/${REPO_NAME}/keys"
      hdr=(-H "Authorization: Bearer $token" -H "Accept: application/vnd.github+json" -H "X-GitHub-Api-Version: 2022-11-28")
      body="$(printf '{"title":"%s %s","key":"%s","read_only":false}' "$(hostname)" "$(date +%F)" "$pub")"
      resp="$(curl -sS -w '\n%{http_code}' -X POST "${hdr[@]}" "$api" -d "$body")" || true
      code="${resp##*$'\n'}"
      case "$code" in
        201) ok "deploy key added (read-write)" ;;
        422) warn "GitHub says this key is already registered; continuing" ;;
        401|403|404) unset token hdr; die "GitHub rejected the token (HTTP $code). It needs Administration: Read and write on ${REPO_NAME}." ;;
        *) unset token hdr; die "unexpected response from GitHub (HTTP $code): ${resp%$'\n'*}" ;;
      esac
      # Show all deploy keys so stale ones (e.g. a dead Pi) can be removed.
      others="$(curl -sS "${hdr[@]}" "$api" | grep -oE '"(id|title)": ?("[^"]*"|[0-9]+)' | paste - - | sed -E 's/"id": ?([0-9]+)\t"title": ?"([^"]*)"/\1  \2/')" || true
      unset token hdr
      if [ -n "$others" ]; then
        info "deploy keys now on ${REPO_NAME} (delete stale ones in GitHub -> ${REPO_NAME} -> Settings -> Deploy keys):"
        printf '%s\n' "$others" | sed 's/^/        /'
      fi
    else
      info "Add this key at https://github.com/${REPO_OWNER}/${REPO_NAME}/settings/keys/new"
      info "  Title: $(hostname)   Tick: Allow write access"
      printf '\n%s\n\n' "$pub"
      ask "    Press Enter once it is added... " >/dev/null
    fi
    for _ in 1 2 3 4 5; do github_ok && break; sleep 3; done
    github_ok || die "GitHub still does not accept this Pi's key. Check the deploy key and re-run."
    ok "GitHub accepts this Pi's key"
  fi

  # Fallback (b): git-crypt key pasted as base64 -> validated now, used in step 7.
  if [ "$need_key" -eq 1 ]; then
    key_b64="${GITCRYPT_KEY_B64:-}"
    if [ -z "$key_b64" ]; then
      info "Paste the docker repo's git-crypt key as one base64 line. On a machine with the repo unlocked:"
      info "    cd ~/claude/docker && git-crypt export-key - | base64 -w0; echo"
      info "(or the copy saved in Google Drive -> Confidential)"
      key_b64="$(ask_secret "    git-crypt key (hidden): ")"
    fi
    KEYFILE="$(mktemp)"; chmod 600 "$KEYFILE"
    if ! printf '%s' "$key_b64" | tr -d ' \n\r' | base64 -d >"$KEYFILE" 2>/dev/null || [ ! -s "$KEYFILE" ]; then
      unset key_b64; die "that is not valid base64"
    fi
    unset key_b64
    [ "$(head -c 9 "$KEYFILE" | tail -c 8)" = "GITCRYPT" ] || die "that does not look like a git-crypt key file"
    ok "git-crypt key received (held in a temp file until step 7, then shredded)"
  fi
fi

# =========================================================================================
ques "Question 2/3  Wi-Fi chip"
if overlay_set disable-wifi; then
  ok "Wi-Fi chip already disabled (dtoverlay=disable-wifi in $CONFIG_TXT)"; WANT_WIFI_OFF=0
else
  # Safety: disabling Wi-Fi when it is the only way in would lock you out after the reboot.
  ssh_dev=""
  if [ -n "${SSH_CONNECTION:-}" ]; then ssh_dev="$(ip route get "${SSH_CONNECTION%% *}" 2>/dev/null | grep -o 'dev [^ ]*' | cut -d' ' -f2)" || true; fi
  eth_up="$(cat /sys/class/net/eth0/carrier 2>/dev/null || echo 0)"
  [ "$ssh_dev" = "wlan0" ] && warn "You are connected over Wi-Fi (wlan0). Disabling it cuts this connection off after the reboot."
  [ "$eth_up" = "1" ] || warn "Ethernet (eth0) has no link. Without Wi-Fi the Pi would be offline after the reboot."
  [ "$ssh_dev" != "wlan0" ] && [ "$eth_up" = "1" ] && info "You are on Ethernet, so this is safe. Wi-Fi currently also acts as a backup link."
  a="${DISABLE_WIFI:-}"; [ -n "$a" ] || a="$(ask "    Do you want to disable wifi chip (Can be reverted by editing $CONFIG_TXT): [y/N] ")"
  if is_yes "$a"; then WANT_WIFI_OFF=1; ok "will disable the Wi-Fi chip"; else WANT_WIFI_OFF=0; ok "keeping Wi-Fi"; fi
fi

# =========================================================================================
ques "Question 3/3  Bluetooth chip"
if overlay_set disable-bt; then
  ok "Bluetooth chip already disabled (dtoverlay=disable-bt in $CONFIG_TXT)"; WANT_BT_OFF=0
else
  a="${DISABLE_BT:-}"; [ -n "$a" ] || a="$(ask "    Do you want to disable bluetooth chip: [y/N] ")"
  if is_yes "$a"; then WANT_BT_OFF=1; ok "will disable the Bluetooth chip"; else WANT_BT_OFF=0; ok "keeping Bluetooth"; fi
fi

printf '\n\033[1mThat is everything I need. Running unattended from here.\033[0m\n'

# =========================================================================================
step "Step 2/8  Packages"
missing=()
for p in "${PACKAGES[@]}"; do dpkg -s "$p" >/dev/null 2>&1 || missing+=("$p"); done
if [ "${#missing[@]}" -eq 0 ]; then
  ok "all installed"
else
  info "installing: ${missing[*]}"
  sudo apt-get update -qq
  # NEEDRESTART_SUSPEND: skip Debian's needrestart hook, which can stop at an interactive
  # "restart which services?" menu (and floods the terminal with progress bars).
  sudo DEBIAN_FRONTEND=noninteractive NEEDRESTART_SUSPEND=1 apt-get install -y -qq "${missing[@]}" >/dev/null
  ok "installed"
fi
# Note: Debian's 'docker-compose' package is Compose v2 and provides 'docker compose'.

# =========================================================================================
step "Step 3/8  Docker group, zsh shell and ~/.zshrc"
if [[ " $(id -nG "$USER") " == *" docker "* ]]; then
  ok "$USER already in docker group"
else
  sudo usermod -aG docker "$USER"; ok "added $USER to docker group (applies at next login)"
fi
sudo systemctl enable --now docker >/dev/null 2>&1 || true

ZSH_BIN="$(command -v zsh)"
if [ "$(getent passwd "$USER" | cut -d: -f7)" = "$ZSH_BIN" ]; then
  ok "login shell already zsh"
else
  sudo chsh -s "$ZSH_BIN" "$USER"; ok "login shell set to $ZSH_BIN (applies at next login)"
fi

new_rc="$(mktemp)"
fetch zshrc "$new_rc"
if [ -f "$HOME/.zshrc" ] && cmp -s "$new_rc" "$HOME/.zshrc"; then
  ok "~/.zshrc already up to date"
else
  if [ -f "$HOME/.zshrc" ]; then
    bak="$HOME/.zshrc.bak.$(date +%Y%m%d-%H%M%S)"; cp -p "$HOME/.zshrc" "$bak"; info "backed up old ~/.zshrc to $bak"
  fi
  install -m 0644 "$new_rc" "$HOME/.zshrc"; ok "installed ~/.zshrc (personal additions go in ~/.zshrc.local)"
fi
rm -f "$new_rc"

# =========================================================================================
step "Step 4/8  Media folders"
for d in "${MEDIA_DIRS[@]}"; do
  if [ -d "$HOME/$d" ]; then ok "~/$d exists"; else mkdir -p "$HOME/$d"; ok "created ~/$d"; fi
done

# =========================================================================================
step "Step 5/8  Wi-Fi / Bluetooth chips"
NEED_REBOOT=0
add_overlay() {  # add_overlay <name>: append under the final [all] section of config.txt
  if [ "$NEED_REBOOT" -eq 0 ]; then
    sudo cp -p "$CONFIG_TXT" "$CONFIG_TXT.bak.$(date +%Y%m%d-%H%M%S)"; info "backed up $CONFIG_TXT"
  fi
  # Lines after a model filter like [pi5] would only apply to that model, so make sure we are in [all].
  last_section="$(grep -E '^\[' "$CONFIG_TXT" | tail -1 || true)"
  if [ -n "$last_section" ] && [ "$last_section" != "[all]" ]; then echo "[all]" | sudo tee -a "$CONFIG_TXT" >/dev/null; fi
  echo "dtoverlay=$1" | sudo tee -a "$CONFIG_TXT" >/dev/null
  NEED_REBOOT=1
}
if [ "$WANT_WIFI_OFF" -eq 1 ]; then add_overlay disable-wifi; ok "added dtoverlay=disable-wifi"; fi
if [ "$WANT_BT_OFF" -eq 1 ]; then
  add_overlay disable-bt; ok "added dtoverlay=disable-bt"
  # No chip -> bluetoothd would only log errors at every boot.
  sudo systemctl disable --now bluetooth >/dev/null 2>&1 && ok "disabled the bluetooth service" || true
fi
[ "$NEED_REBOOT" -eq 1 ] || ok "no changes"

if [ "$DO_STACK" -eq 0 ]; then
  step "Done (--no-stack)"
  info "Log out and back in (or run: exec zsh) to start using zsh."
  [ "$NEED_REBOOT" -eq 1 ] && warn "Reboot to switch the chip(s) off: sudo reboot"
  exit 0
fi

# =========================================================================================
step "Step 6/8  Clone or update ${REPO_NAME}"
git config --global user.name  >/dev/null || git config --global user.name  "$GIT_NAME"
git config --global user.email >/dev/null || git config --global user.email "$GIT_EMAIL"
ok "git identity: $(git config --global user.name) <$(git config --global user.email)>"
if [ -d "$STACK_DIR/.git" ]; then
  if [ -z "$(git -C "$STACK_DIR" status --porcelain)" ]; then
    git -C "$STACK_DIR" pull -q --ff-only && ok "updated $STACK_DIR ($(git -C "$STACK_DIR" log --oneline -1))"
  else
    warn "$STACK_DIR has local changes; not pulling (commit or stash them, then re-run)"
  fi
else
  git clone -q "$REPO_SSH" "$STACK_DIR"; ok "cloned into $STACK_DIR ($(git -C "$STACK_DIR" log --oneline -1))"
fi

# =========================================================================================
step "Step 7/8  Unlock secrets (git-crypt)"
if ! is_locked; then
  ok "already unlocked"
else
  [ -n "$KEYFILE" ] && [ -s "$KEYFILE" ] || die "repo is encrypted but no git-crypt key was given (re-run and paste it at question 1/3)"
  (cd "$STACK_DIR" && git-crypt unlock "$KEYFILE") || die "git-crypt unlock failed (wrong key?)"
  is_locked && die "files still encrypted after unlock"
  ok "unlocked (.env readable; key kept only in $STACK_DIR/.git/git-crypt/keys/)"
fi
cleanup

# =========================================================================================
step "Step 8/8  Start the stack"
if [ "$DO_START" -eq 0 ]; then
  info "skipped (--no-start). Start later with: cd $STACK_DIR && docker compose up -d"
else
  # sudo: the docker group membership from step 3 only applies after re-login.
  (cd "$STACK_DIR" && sudo docker compose up -d) 2>&1 | { grep -vE ' (Pulling|Waiting|Downloading|Extracting|Verifying|Pull complete|Download complete|Already exists)' || true; } | tail -15
  info "waiting for health checks (up to 10 min; nginx may renew its certificate first)..."
  for _ in $(seq 1 60); do
    st="$(sudo docker compose -f "$STACK_DIR/docker-compose.yml" ps --format '{{.Status}}')"
    [[ "$st" == *"health: starting"* ]] || break
    sleep 10
  done
  sudo docker compose -f "$STACK_DIR/docker-compose.yml" ps --format 'table {{.Service}}\t{{.Status}}'
fi

# =========================================================================================
step "Finished"
info "Log out and back in (or run: exec zsh) for zsh and the docker group to take effect."
info "If a container is unhealthy, see the Troubleshooting table in $STACK_DIR/RESTORE.md"
[ "$NEED_REBOOT" -eq 1 ] && warn "Reboot to switch the chip(s) off: sudo reboot   (containers restart automatically)"
exit 0
