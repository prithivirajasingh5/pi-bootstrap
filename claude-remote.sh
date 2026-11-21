#!/usr/bin/env bash
# =============================================================================
# claude-remote.sh — Claude Code on this Pi, reachable from the Claude mobile app (Remote Control)
#
#   bash <(curl -fsSL https://raw.githubusercontent.com/prithivirajasingh5/pi-bootstrap/main/claude-remote.sh)
#
# Run as your normal user (pi) in an interactive SSH session. bootstrap.sh runs it too (question 5/5).
# Safe to re-run: every step checks first and skips what is already done.
#
#   1. installs Claude Code (Anthropic's native installer -> ~/.local/bin/claude)
#   2. signs in to your claude.ai account (once: open the printed URL, approve, paste the code back).
#      Remote Control needs a real claude.ai login; a `claude setup-token` token can't open it.
#   3. GitHub: installs gh, signs it in (device code you approve on the phone), lets git use it, and
#      clones pi-bootstrap into ~/claude so setup changes can be made and pushed from the Pi
#   4. workspace (~/claude): CLAUDE.md (house rules, from opi-CLAUDE.md), /new-project and /git-check,
#      the session-start sync check, your GPG public key for git-crypt, and the one-time
#      "Trust this folder?" answer
#   5. claude-remote.service: `claude remote-control` as this user, started at boot, restarted if it
#      stops, its repeated status lines filtered by log-dedupe. The Pi shows up in the Claude app.
#   6. claude-signin.service (claude-signin.py): when the sign-in is about to end it sends you a
#      sign-in link on Telegram (messenger); reply to the bot with `claude <code>` to renew.
#   7. claude-update.timer: updates Claude Code on Sundays (claude-weekly-update.sh)
#
# Claude runs as this user, who has passwordless sudo: it can do anything on the Pi you approve.
#
# Optional settings (environment variables):
#   CLAUDE_WORKDIR          folder new sessions start in (default ~/claude)
#   CLAUDE_PERMISSION_MODE  default | acceptEdits | auto | bypassPermissions (default: auto)
#   CLAUDE_RC_NAME          name prefix shown in the app (default: hostname)
# =============================================================================
set -Eeuo pipefail

WORKDIR="${CLAUDE_WORKDIR:-$HOME/claude}"
PERMISSION_MODE="${CLAUDE_PERMISSION_MODE:-auto}"
RC_NAME="${CLAUDE_RC_NAME:-$(hostname)}"
CLAUDE="$HOME/.local/bin/claude"
UNIT=claude-remote.service
SIGNIN_UNIT=claude-signin.service
SIGNIN_BIN=/usr/local/bin/claude-signin
BOOTSTRAP_RAW="https://raw.githubusercontent.com/prithivirajasingh5/pi-bootstrap/main"
# Companion files: from PI_BOOTSTRAP_DIR (bootstrap.sh run from a clone), next to this script, or GitHub.
SRC_DIR="${PI_BOOTSTRAP_DIR:-}"
if [ -z "$SRC_DIR" ] && [ -f "${BASH_SOURCE[0]:-}" ] && [ -f "$(dirname "${BASH_SOURCE[0]}")/claude-signin.py" ]; then
  SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fi
fetch() {  # fetch <name> <dest>
  if [ -n "$SRC_DIR" ]; then cp "$SRC_DIR/$1" "$2"; else curl -fsSL "$BOOTSTRAP_RAW/$1" -o "$2"; fi
}
SIGNED_IN_NOW=0

STEP=""
step() { STEP="$*"; printf '\n\033[1;32m==> %s\033[0m\n' "$*"; }
info() { printf '    %s\n' "$*"; }
ok()   { printf '    \033[32m✓\033[0m %s\n' "$*"; }
warn() { printf '    \033[1;33m! %s\033[0m\n' "$*"; }
die()  { printf '\n\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }
trap 'printf "\n\033[1;31mFailed during: %s (line %s)\033[0m\nFix the problem and re-run; completed steps are skipped.\n" "$STEP" "$LINENO" >&2' ERR

# put <repo file> <destination> <mode> [sudo]: install if different; returns 0 if it changed.
put() {
  local tmp; tmp="$(mktemp)"; fetch "$1" "$tmp"
  if cmp -s "$tmp" "$2"; then rm -f "$tmp"; return 1; fi
  ${4:+sudo} install -D -m "$3" "$tmp" "$2"; rm -f "$tmp"; return 0
}

logged_in() { "$CLAUDE" auth status >/dev/null 2>&1; }

step "Preflight"
[ "$(id -u)" -ne 0 ] || die "Run as your normal user (pi), not root."
[ -e /dev/tty ] || die "No terminal for the sign-in. Run it from an interactive SSH session."
case "$PERMISSION_MODE" in default|acceptEdits|auto|bypassPermissions|dontAsk|plan) ;;
  *) die "CLAUDE_PERMISSION_MODE=$PERMISSION_MODE is not a known mode" ;; esac
sudo -n true 2>/dev/null || die "$USER needs passwordless sudo (bootstrap.sh step 1 sets it up)"
ok "user=$USER  workdir=$WORKDIR  permission mode=$PERMISSION_MODE"

# =========================================================================================
step "1/7  Install Claude Code"
if [ -x "$CLAUDE" ]; then
  ok "already installed: $("$CLAUDE" --version) (it updates itself)"
else
  curl -fsSL https://claude.ai/install.sh | bash >/dev/null
  [ -x "$CLAUDE" ] || die "installer finished but $CLAUDE is missing"
  ok "installed $("$CLAUDE" --version)"
fi

# =========================================================================================
step "2/7  Sign in to claude.ai"
if logged_in; then
  ok "already signed in"
else
  info "Open the URL below on any device, approve, and paste the code back here if asked."
  "$CLAUDE" auth login --claudeai </dev/tty >/dev/tty 2>&1
  logged_in || die "still not signed in; re-run to try again"
  ok "signed in"; SIGNED_IN_NOW=1
fi

# =========================================================================================
step "3/7  GitHub (gh CLI: push to all your repos, create repos, releases)"
if ! command -v gh >/dev/null; then
  sudo DEBIAN_FRONTEND=noninteractive NEEDRESTART_SUSPEND=1 apt-get install -y -qq gh >/dev/null; ok "installed gh"
fi
if gh auth status >/dev/null 2>&1; then
  ok "gh signed in as $(gh api user --jq .login 2>/dev/null)"
else
  info "Open https://github.com/login/device on your phone and enter the code shown below."
  gh auth login --hostname github.com --git-protocol https --web --scopes workflow </dev/tty >/dev/tty 2>&1
  gh auth status >/dev/null 2>&1 || die "gh is not signed in; re-run to try again"
  ok "gh signed in as $(gh api user --jq .login)"
fi
gh auth setup-git; ok "git uses gh for https://github.com"
if [ -d "$WORKDIR/pi-bootstrap/.git" ]; then
  ok "$WORKDIR/pi-bootstrap present (setup changes are made and pushed there)"
else
  mkdir -p "$WORKDIR"; git clone -q https://github.com/prithivirajasingh5/pi-bootstrap.git "$WORKDIR/pi-bootstrap" </dev/null
  ok "cloned pi-bootstrap into $WORKDIR/pi-bootstrap"
fi

# =========================================================================================
step "4/7  Workspace and first-run questions"
mkdir -p "$WORKDIR"; ok "workspace $WORKDIR"
# House rules every session reads (opi-CLAUDE.md in this repo). A copy of what was last installed is
# kept, so a .bak is made only when the file was edited here (not after every update of the rules).
new_md="$(mktemp)"; fetch opi-CLAUDE.md "$new_md"
last_md="$HOME/.local/state/pi-bootstrap/CLAUDE.md.installed"
if [ -f "$WORKDIR/CLAUDE.md" ] && cmp -s "$new_md" "$WORKDIR/CLAUDE.md"; then
  ok "$WORKDIR/CLAUDE.md up to date"
else
  if [ -f "$WORKDIR/CLAUDE.md" ] && ! cmp -s "$WORKDIR/CLAUDE.md" "$last_md"; then
    bak="$WORKDIR/CLAUDE.md.bak.$(date +%Y%m%d-%H%M%S)"; cp -p "$WORKDIR/CLAUDE.md" "$bak"; info "it was edited here: kept that version as $bak"
  fi
  install -m 0644 "$new_md" "$WORKDIR/CLAUDE.md"; ok "installed $WORKDIR/CLAUDE.md (house rules for sessions)"
fi
install -D -m 0644 "$new_md" "$last_md"
rm -f "$new_md"
# The laptop's Claude setup, ported: /new-project and /git-check, and the session-start sync check.
for c in git-check new-project; do
  put "opi-claude/commands/$c.md" "$WORKDIR/.claude/commands/$c.md" 0644 && ok "installed /$c"
done
put opi-claude/hooks/sync-check.sh "$HOME/.claude/hooks/sync-check.sh" 0755 && ok "installed the sync-check hook"
python3 - "$HOME/.claude/settings.json" <<'PY'
import json, os, sys
path = sys.argv[1]
try: d = json.load(open(path))
except (OSError, ValueError): d = {}
hook = {"matcher": "startup", "hooks": [{"type": "command", "command": "$HOME/.claude/hooks/sync-check.sh",
        "timeout": 60, "statusMessage": "Checking repo sync state\u2026"}]}
starts = d.setdefault("hooks", {}).setdefault("SessionStart", [])
if not any("sync-check.sh" in h.get("command", "") for e in starts for h in e.get("hooks", [])):
    starts.append(hook)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    json.dump(d, open(path, "w"), indent=2)
    print("    \u2713 session-start sync check enabled in", path)
PY
# git-crypt for new projects: the owner's PUBLIC key only (the private key never comes here).
gpg_key=36495943FBDA0DF535B6FBA2E9A09FE2F41B0BFC
if gpg --list-keys "$gpg_key" >/dev/null 2>&1; then
  ok "GPG public key $gpg_key present"
else
  key_tmp="$(mktemp)"; fetch opi-claude/gpg-public.asc "$key_tmp"; gpg --quiet --import "$key_tmp" 2>/dev/null; rm -f "$key_tmp"
  gpg --list-keys "$gpg_key" >/dev/null 2>&1 && ok "imported GPG public key $gpg_key (new projects are encrypted to it)"
fi
# The service has no terminal, so `claude remote-control` would exit with "Workspace not trusted".
# Claude Code only accepts that answer from a person (a scripted "y" is rejected as too fast), so
# the first time we run it in the foreground once and you answer the question yourself.
trusted() {
  python3 - "$WORKDIR" <<'PY'
import json, os, sys
try: d = json.load(open(os.path.expanduser("~/.claude.json")))
except Exception: sys.exit(1)
sys.exit(0 if d.get("projects", {}).get(sys.argv[1], {}).get("hasTrustDialogAccepted") else 1)
PY
}
if trusted; then
  ok "$WORKDIR already trusted"
else
  sudo systemctl stop "$UNIT" 2>/dev/null || true
  info "Remote Control will now ask:  Trust $WORKDIR? [y/N]   -> type y and Enter"
  info "(and \"Enable Remote Control?\" if it asks: y). When it shows it is waiting for"
  info "connections, press Ctrl-C. The service takes over from there."
  printf '    Press Enter to start... '; read -r _ </dev/tty
  trap 'true' INT    # Ctrl-C stops claude, not this script (a handler, not an ignore: children get the default)
  (cd "$WORKDIR" && "$CLAUDE" remote-control --permission-mode "$PERMISSION_MODE" </dev/tty >/dev/tty 2>&1) || true
  trap - INT
  trusted || die "$WORKDIR is still not trusted; re-run and answer y"
  ok "$WORKDIR trusted"
fi

# =========================================================================================
step "5/7  systemd service ($UNIT)"
put log-dedupe.py /usr/local/bin/log-dedupe 0755 sudo && ok "installed log-dedupe"
unit_text="[Unit]
Description=Claude Code Remote Control (reach this Pi from the Claude app)
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
User=$USER
WorkingDirectory=$WORKDIR
Environment=HOME=$HOME
Environment=PATH=$HOME/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
# The status panel is redrawn every few seconds; log-dedupe keeps those repeats out of the journal.
ExecStart=/bin/bash -c 'set -o pipefail; $CLAUDE remote-control --remote-control-session-name-prefix $RC_NAME --permission-mode $PERMISSION_MODE 2>&1 | /usr/local/bin/log-dedupe'
Restart=always
RestartSec=30

[Install]
WantedBy=multi-user.target"
if [ "$(cat "/etc/systemd/system/$UNIT" 2>/dev/null)" = "$unit_text" ]; then
  ok "unit already up to date"
  sudo systemctl enable "$UNIT" >/dev/null 2>&1
  if [ "$SIGNED_IN_NOW" -eq 1 ] || ! systemctl is-active --quiet "$UNIT"; then
    sudo systemctl restart "$UNIT"; ok "(re)started with the current sign-in"
  fi
else
  printf '%s\n' "$unit_text" | sudo tee "/etc/systemd/system/$UNIT" >/dev/null
  sudo systemctl daemon-reload
  sudo systemctl enable "$UNIT" >/dev/null 2>&1
  sudo systemctl restart "$UNIT"
  ok "installed and (re)started"
fi
sleep 8
if systemctl is-active --quiet "$UNIT"; then
  ok "running. Last log lines:"
  sudo journalctl -u "$UNIT" -n 5 --no-pager -o cat | sed 's/^/        /'
else
  sudo journalctl -u "$UNIT" -n 20 --no-pager -o cat | sed 's/^/        /'
  die "$UNIT is not running (log above)"
fi

# =========================================================================================
step "6/7  Sign-in renewal over Telegram ($SIGNIN_UNIT)"
new_bin="$(mktemp)"; fetch claude-signin.py "$new_bin"
signin_unit="[Unit]
Description=Renew Claude Code's sign-in via Telegram (link out by messenger, code back via the bot)
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
User=$USER
Environment=HOME=$HOME
ExecStart=/usr/bin/python3 $SIGNIN_BIN
Restart=always
RestartSec=30

[Install]
WantedBy=multi-user.target"
changed=0
if ! cmp -s "$new_bin" "$SIGNIN_BIN"; then sudo install -m 0755 "$new_bin" "$SIGNIN_BIN"; changed=1; fi
rm -f "$new_bin"
if [ "$(cat "/etc/systemd/system/$SIGNIN_UNIT" 2>/dev/null)" != "$signin_unit" ]; then
  printf '%s\n' "$signin_unit" | sudo tee "/etc/systemd/system/$SIGNIN_UNIT" >/dev/null
  sudo systemctl daemon-reload; changed=1
fi
sudo systemctl enable "$SIGNIN_UNIT" >/dev/null 2>&1
if [ "$changed" -eq 1 ] || ! systemctl is-active --quiet "$SIGNIN_UNIT"; then sudo systemctl restart "$SIGNIN_UNIT"; fi
sleep 3
systemctl is-active --quiet "$SIGNIN_UNIT" || { sudo journalctl -u "$SIGNIN_UNIT" -n 20 --no-pager -o cat; die "$SIGNIN_UNIT is not running"; }
ok "running: $(sudo journalctl -u "$SIGNIN_UNIT" -n 1 --no-pager -o cat)"
[ -x "$HOME/claude/docker/python-jobs/jobs/messenger" ] || warn "messenger not found yet (it comes with the docker stack); links can't be sent until it is there"

# =========================================================================================
step "7/7  Weekly Claude Code update (claude-update.timer, Sundays 04:30)"
put claude-weekly-update.sh /usr/local/bin/claude-weekly-update 0755 sudo && ok "installed claude-weekly-update"
upd_service="[Unit]
Description=Update Claude Code and restart Remote Control if a new version came
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
User=$USER
Environment=HOME=$HOME
ExecStart=/usr/local/bin/claude-weekly-update"
upd_timer="[Unit]
Description=Weekly Claude Code update

[Timer]
OnCalendar=Sun 04:30
Persistent=true

[Install]
WantedBy=timers.target"
if [ "$(cat /etc/systemd/system/claude-update.service 2>/dev/null)" != "$upd_service" ] || [ "$(cat /etc/systemd/system/claude-update.timer 2>/dev/null)" != "$upd_timer" ]; then
  printf '%s\n' "$upd_service" | sudo tee /etc/systemd/system/claude-update.service >/dev/null
  printf '%s\n' "$upd_timer" | sudo tee /etc/systemd/system/claude-update.timer >/dev/null
  sudo systemctl daemon-reload
fi
sudo systemctl enable --now claude-update.timer >/dev/null 2>&1
ok "next run: $(systemctl show claude-update.timer -p NextElapseUSecRealtime --value)"

step "Done"
info "Phone: Claude app -> Code tab -> pick \"$RC_NAME\"."
info "Logs: journalctl -u $UNIT -f     Restart: sudo systemctl restart $UNIT"
info "Sign-in renewal: a Telegram link arrives ~5 days before it ends; reply to the bot: claude <code>"
info "Telegram bot: claude (status) | claude login (new link now) | claude <code>"
