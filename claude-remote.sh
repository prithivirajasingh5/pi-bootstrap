#!/usr/bin/env bash
# =============================================================================
# claude-remote.sh — Claude Code on this Pi, reachable from the Claude mobile app (Remote Control)
#
#   bash <(curl -fsSL https://raw.githubusercontent.com/prithivirajasingh5/pi-bootstrap/main/claude-remote.sh)
#
# Run as your normal user (pi) in an interactive SSH session. bootstrap.sh runs it too (question 5/5).
# Safe to re-run: every step checks first and skips what is already done.
#
#   1. installs Claude Code (Anthropic's native installer -> ~/.local/bin/claude, auto-updates itself)
#   2. signs in to your claude.ai account (once: open the printed URL, approve, paste the code back).
#      Remote Control needs a real claude.ai login; a `claude setup-token` token can't open it.
#   3. creates the workspace folder sessions start in (default ~/claude), installs its CLAUDE.md
#      (opi-CLAUDE.md: house rules for every session), and accepts the
#      "Enable Remote Control?" and "Trust this folder?" first-run questions for it
#   4. installs claude-remote.service: `claude remote-control` as this user, started at boot,
#      restarted if it stops. The Pi then shows up in the Claude app -> Code tab.
#   5. installs claude-signin.service (claude-signin.py): when the sign-in is about to end it sends
#      you a sign-in link on Telegram (messenger); reply to the bot with `claude <code>` to renew.
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

logged_in() { "$CLAUDE" auth status >/dev/null 2>&1; }

step "Preflight"
[ "$(id -u)" -ne 0 ] || die "Run as your normal user (pi), not root."
[ -e /dev/tty ] || die "No terminal for the sign-in. Run it from an interactive SSH session."
case "$PERMISSION_MODE" in default|acceptEdits|auto|bypassPermissions|dontAsk|plan) ;;
  *) die "CLAUDE_PERMISSION_MODE=$PERMISSION_MODE is not a known mode" ;; esac
sudo -n true 2>/dev/null || die "$USER needs passwordless sudo (bootstrap.sh step 1 sets it up)"
ok "user=$USER  workdir=$WORKDIR  permission mode=$PERMISSION_MODE"

# =========================================================================================
step "1/5  Install Claude Code"
if [ -x "$CLAUDE" ]; then
  ok "already installed: $("$CLAUDE" --version) (it updates itself)"
else
  curl -fsSL https://claude.ai/install.sh | bash >/dev/null
  [ -x "$CLAUDE" ] || die "installer finished but $CLAUDE is missing"
  ok "installed $("$CLAUDE" --version)"
fi

# =========================================================================================
step "2/5  Sign in to claude.ai"
if logged_in; then
  ok "already signed in"
else
  info "Open the URL below on any device, approve, and paste the code back here if asked."
  "$CLAUDE" auth login --claudeai </dev/tty >/dev/tty 2>&1
  logged_in || die "still not signed in; re-run to try again"
  ok "signed in"; SIGNED_IN_NOW=1
fi

# =========================================================================================
step "3/5  Workspace and first-run questions"
mkdir -p "$WORKDIR"; ok "workspace $WORKDIR"
# House rules every session reads (opi-CLAUDE.md in this repo). Edits made on the Pi are kept as a backup.
new_md="$(mktemp)"; fetch opi-CLAUDE.md "$new_md"
if [ -f "$WORKDIR/CLAUDE.md" ] && cmp -s "$new_md" "$WORKDIR/CLAUDE.md"; then
  ok "$WORKDIR/CLAUDE.md up to date"
else
  if [ -f "$WORKDIR/CLAUDE.md" ]; then
    bak="$WORKDIR/CLAUDE.md.bak.$(date +%Y%m%d-%H%M%S)"; cp -p "$WORKDIR/CLAUDE.md" "$bak"; info "backed up the old one to $bak"
  fi
  install -m 0644 "$new_md" "$WORKDIR/CLAUDE.md"; ok "installed $WORKDIR/CLAUDE.md (house rules for sessions)"
fi
rm -f "$new_md"
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
step "4/5  systemd service ($UNIT)"
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
ExecStart=$CLAUDE remote-control --remote-control-session-name-prefix $RC_NAME --permission-mode $PERMISSION_MODE
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
step "5/5  Sign-in renewal over Telegram ($SIGNIN_UNIT)"
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

step "Done"
info "Phone: Claude app -> Code tab -> pick \"$RC_NAME\"."
info "Logs: journalctl -u $UNIT -f     Restart: sudo systemctl restart $UNIT"
info "Sign-in renewal: a Telegram link arrives ~5 days before it ends; reply to the bot: claude <code>"
info "Telegram bot: claude (status) | claude login (new link now) | claude <code>"
