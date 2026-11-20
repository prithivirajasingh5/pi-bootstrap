#!/usr/bin/env bash
# claude-weekly-update — update Claude Code once a week (claude-update.timer, Sunday 04:30).
#
# Claude Code's own auto-updater is off for this install (autoUpdates=false in ~/.claude.json), so a
# long-running Remote Control server would otherwise stay on the version installed by pi-bootstrap.
# After an update the services are restarted so they run the new version (an open phone session
# reconnects), and you get one Telegram message. No message when nothing changed.
set -uo pipefail

CLAUDE="$HOME/.local/bin/claude"
MESSENGER="${MESSENGER:-$HOME/claude/docker/python-jobs/jobs/messenger}"
HOST="$(hostname)"

notify() {
  [ -x "$MESSENGER" ] && MESSENGER_ENV_FILE="$(dirname "$MESSENGER")/../../.env" "$MESSENGER" --text="$1" >/dev/null 2>&1
  echo "$1"
}

before="$("$CLAUDE" --version 2>/dev/null | awk '{print $1}')"
if ! out="$("$CLAUDE" update 2>&1)"; then
  notify "⚠️ $HOST: Claude Code update failed (still $before):
$(tail -5 <<< "$out")"
  exit 1
fi
after="$("$CLAUDE" --version 2>/dev/null | awk '{print $1}')"

if [ "$before" = "$after" ]; then
  echo "Claude Code $after is up to date"
  exit 0
fi
sudo -n systemctl restart claude-remote.service claude-signin.service
notify "⬆️ $HOST: Claude Code updated $before → $after; Remote Control restarted."
