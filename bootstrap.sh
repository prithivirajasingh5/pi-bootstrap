#!/usr/bin/env bash
# =============================================================================
# pi-bootstrap — fresh Raspberry Pi OS  ->  zsh + the "opi" Docker homelab
#
#   bash <(curl -fsSL https://raw.githubusercontent.com/prithivirajasingh5/pi-bootstrap/main/bootstrap.sh)
#
# Options:
#   --no-stack   only shell setup + media folders (no GitHub, clone, unlock or docker start)
#   --no-start   do everything except `docker compose up -d`
#   -h, --help
#
# Safe to re-run: every step checks first and skips what is already done.
# Secrets are only ever typed at hidden prompts; nothing secret is stored by this script
# except what git-crypt itself keeps in ~/docker/.git/git-crypt/keys/.
#
# Optional non-interactive inputs (avoid on shared machines: env vars can leak via `ps`):
#   GITHUB_TOKEN       token used once to register the Pi's deploy key
#   GITCRYPT_KEY_B64   base64 of `git-crypt export-key -` for the docker repo
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
PACKAGES=(git git-crypt docker.io docker-compose zsh zsh-syntax-highlighting zsh-autosuggestions curl ca-certificates)

DO_STACK=1
DO_START=1
for arg in "$@"; do
  case "$arg" in
    --no-stack) DO_STACK=0 ;;
    --no-start) DO_START=0 ;;
    -h|--help) sed -n '2,22p' "$0" 2>/dev/null || true; exit 0 ;;
    *) echo "Unknown option: $arg (see --help)" >&2; exit 2 ;;
  esac
done

# ---- output helpers --------------------------------------------------------------------
STEP=""
step() { STEP="$*"; printf '\n\033[1;32m==> %s\033[0m\n' "$*"; }
info() { printf '    %s\n' "$*"; }
ok()   { printf '    \033[32m✓\033[0m %s\n' "$*"; }
warn() { printf '    \033[1;33m! %s\033[0m\n' "$*"; }
die()  { printf '\n\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }
# Report only failures of the main shell, not harmless non-matches inside $(...) subshells.
trap '[ "$BASH_SUBSHELL" -eq 0 ] && printf "\n\033[1;31mFailed during: %s (line %s)\033[0m\nFix the problem and re-run; completed steps are skipped.\n" "$STEP" "$LINENO" >&2' ERR

# Prompts read from the terminal, so they also work when the script itself arrives on stdin.
ask()        { local v; read -r -p "$1" v </dev/tty; printf '%s' "$v"; }
ask_secret() { local v; read -r -s -p "$1" v </dev/tty; echo >/dev/tty; printf '%s' "$v"; }

# Where to read companion files (zshrc) from: next to the script if run from a clone, else GitHub.
SCRIPT_DIR=""
if [ -f "${BASH_SOURCE[0]:-}" ] && [ -f "$(dirname "${BASH_SOURCE[0]}")/zshrc" ]; then
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fi
fetch() {  # fetch <name> <dest>
  if [ -n "$SCRIPT_DIR" ]; then cp "$SCRIPT_DIR/$1" "$2"; else curl -fsSL "$BOOTSTRAP_RAW/$1" -o "$2"; fi
}

# =========================================================================================
step "Preflight"
[ "$(id -u)" -ne 0 ] || die "Run as your normal user (pi), not root. The script uses sudo where needed."
[ -r /etc/debian_version ] || die "This script expects Debian / Raspberry Pi OS."
[ -e /dev/tty ] || die "No terminal available for prompts. Run it from an interactive SSH session."
info "user=$USER  host=$(hostname)  os=$(. /etc/os-release && echo "$PRETTY_NAME")  arch=$(uname -m)"

# =========================================================================================
step "1/9  Passwordless sudo"
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

# =========================================================================================
step "2/9  Packages"
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
step "3/9  Docker group, zsh shell and ~/.zshrc"
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
step "4/9  Media folders"
for d in "${MEDIA_DIRS[@]}"; do
  if [ -d "$HOME/$d" ]; then ok "~/$d exists"; else mkdir -p "$HOME/$d"; ok "created ~/$d"; fi
done

if [ "$DO_STACK" -eq 0 ]; then
  step "Done (--no-stack)"
  info "Log out and back in (or run: exec zsh) to start using zsh."
  exit 0
fi

# =========================================================================================
step "5/9  Git identity and GitHub SSH (deploy key)"
git config --global user.name  >/dev/null || git config --global user.name  "$GIT_NAME"
git config --global user.email >/dev/null || git config --global user.email "$GIT_EMAIL"
ok "git identity: $(git config --global user.name) <$(git config --global user.email)>"

mkdir -p "$HOME/.ssh"; chmod 700 "$HOME/.ssh"
if [ -f "$DEPLOY_KEY" ]; then
  ok "deploy key exists ($DEPLOY_KEY)"
else
  ssh-keygen -q -t ed25519 -N "" -C "$(hostname) ${REPO_NAME} deploy key" -f "$DEPLOY_KEY"
  ok "created deploy key $DEPLOY_KEY"
fi
touch "$HOME/.ssh/config"; chmod 600 "$HOME/.ssh/config"
if grep -q '^Host github.com' "$HOME/.ssh/config"; then
  ok "~/.ssh/config already has a github.com entry"
else
  printf 'Host github.com\n    User git\n    IdentityFile %s\n    IdentitiesOnly yes\n' "$DEPLOY_KEY" >>"$HOME/.ssh/config"
  ok "added github.com entry to ~/.ssh/config"
fi

if ssh-keygen -F github.com >/dev/null 2>&1; then
  ok "github.com host key already trusted"
else
  hk="$(mktemp)"; ssh-keyscan -t ed25519 github.com 2>/dev/null >"$hk"
  fp="$(ssh-keygen -lf "$hk" | awk '{print $2}')"
  [ "$fp" = "$GITHUB_ED25519_FP" ] || { rm -f "$hk"; die "github.com host key fingerprint $fp does not match the published $GITHUB_ED25519_FP"; }
  cat "$hk" >>"$HOME/.ssh/known_hosts"; rm -f "$hk"; ok "trusted github.com ($fp, matches GitHub's published key)"
fi

# `ssh -T git@github.com` always exits 1 (GitHub refuses a shell), so with pipefail a direct
# `ssh ... | grep -q` would always look like failure. Capture the greeting, then test it.
github_greeting() { ssh -T -o BatchMode=yes git@github.com 2>&1 || true; }
github_ok() { local g; g="$(github_greeting)"; [[ "$g" == *"successfully authenticated"* ]]; }

# =========================================================================================
step "6/9  Register the deploy key with GitHub"
if github_ok; then
  g="$(github_greeting)"; g="${g#*Hi }"; ok "GitHub accepts this Pi's key: Hi ${g%%!*}"
else
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
      401|403|404) unset token; die "GitHub rejected the token (HTTP $code). It needs Administration: Read and write on ${REPO_NAME}." ;;
      *) unset token; die "unexpected response from GitHub (HTTP $code): ${resp%$'\n'*}" ;;
    esac
    # Show other deploy keys so stale ones (e.g. a dead Pi) can be removed.
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

# =========================================================================================
step "7/9  Clone or update ${REPO_NAME}"
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
step "8/9  Unlock secrets (git-crypt)"
is_locked() { [ "$(head -c 9 "$STACK_DIR/.env" | tail -c 8)" = "GITCRYPT" ]; }
if ! is_locked; then
  ok "already unlocked"
else
  key_b64="${GITCRYPT_KEY_B64:-}"
  if [ -z "$key_b64" ]; then
    info "Paste this repo's git-crypt key as one base64 line. On a machine with the repo unlocked, get it with:"
    info "    cd ~/claude/docker && git-crypt export-key - | base64 -w0; echo"
    info "(store that line in Google Drive -> Confidential to restore without the laptop next time)"
    key_b64="$(ask_secret "    git-crypt key (hidden): ")"
  fi
  keyfile="$(mktemp)"; chmod 600 "$keyfile"
  if ! printf '%s' "$key_b64" | tr -d ' \n\r' | base64 -d >"$keyfile" 2>/dev/null || [ ! -s "$keyfile" ]; then
    shred -u "$keyfile"; unset key_b64; die "that is not valid base64"
  fi
  unset key_b64
  if (cd "$STACK_DIR" && git-crypt unlock "$keyfile"); then shred -u "$keyfile"; else shred -u "$keyfile"; die "git-crypt unlock failed (wrong key?)"; fi
  is_locked && die "files still encrypted after unlock"
  ok "unlocked (.env readable; key kept only in $STACK_DIR/.git/git-crypt/keys/)"
fi

# =========================================================================================
step "9/9  Start the stack"
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
