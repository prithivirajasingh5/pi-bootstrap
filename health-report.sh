#!/usr/bin/env bash
# =============================================================================
# health-report — weekly health check of this machine; Claude diagnoses it; result on Telegram.
#
# health-report.timer runs it on Sundays at 10:00 (as pi). On demand:
#   sudo systemctl start health-report        # full run, message arrives in a few minutes
#   AI=0 SEND=0 health-report                 # just print the collected facts
#
# 1. Collects the facts of the last DAYS days: power/heat flags, SSD health (SMART), disk space,
#    memory and OOM kills, kernel warnings, errors per service, restarts, containers and their
#    error lines, DNS failures, pending updates, Claude sign-in, repo sync state.
# 2. Claude reads it next to last week's report, may dig with read-only commands (journalctl,
#    docker logs, systemctl status), and writes a short diagnosis: what is wrong, likely cause
#    with evidence, suggested fix, trends. Changing anything is not allowed.
# 3. messenger sends that to Telegram (or the plain facts if Claude is unavailable).
# Reports are kept in ~/.local/state/health-report/ (12 weeks).
# =============================================================================
set -uo pipefail

DAYS="${DAYS:-7}"
AI="${AI:-1}"
SEND="${SEND:-1}"
STACK_DIR="${STACK_DIR:-$HOME/claude/docker}"
MESSENGER="${MESSENGER:-$STACK_DIR/python-jobs/jobs/messenger}"
CLAUDE="${CLAUDE:-$HOME/.local/bin/claude}"
OUT_DIR="${OUT_DIR:-$HOME/.local/state/health-report}"
HOST="$(hostname)"
SINCE="-${DAYS}d"
mkdir -p "$OUT_DIR"
REPORT="$OUT_DIR/$(date +%F).txt"

sec() { printf '\n## %s\n' "$1"; }
top() { sed -E 's/[0-9a-f]{12,}/<id>/g; s/[0-9]+/N/g' | cut -c1-220 | sort | uniq -c | sort -rn | head -"${1:-15}"; }

throttle_text() {   # decode vcgencmd get_throttled bits
  local v=$(( $1 )) out=()
  (( v & 0x1 ))     && out+=("UNDER-VOLTAGE NOW")
  (( v & 0x2 ))     && out+=("CPU capped now")
  (( v & 0x4 ))     && out+=("throttled now")
  (( v & 0x8 ))     && out+=("soft temperature limit now")
  (( v & 0x10000 )) && out+=("under-voltage happened since boot")
  (( v & 0x20000 )) && out+=("CPU capping happened since boot")
  (( v & 0x40000 )) && out+=("throttling happened since boot")
  (( v & 0x80000 )) && out+=("soft temperature limit hit since boot")
  [ ${#out[@]} -eq 0 ] && out=("no power or heat problems since boot")
  local IFS=';'; echo "${out[*]}"
}

collect() {
  echo "# Health report: $HOST, $(date '+%F %H:%M %Z'), covering the last $DAYS days"

  sec "System"
  . /etc/os-release; echo "$PRETTY_NAME, kernel $(uname -r), $(uname -m), $(nproc) CPUs"
  echo "up since $(uptime -s); load $(cut -d' ' -f1-3 /proc/loadavg)"
  echo "boots on record (journal):"; journalctl --list-boots --no-pager -q 2>/dev/null | tail -n 8

  sec "Power and temperature"
  if command -v vcgencmd >/dev/null; then
    t="$(vcgencmd get_throttled | cut -d= -f2)"; echo "get_throttled=$t: $(throttle_text "$t")"
    vcgencmd measure_temp
  fi
  for z in /sys/class/thermal/thermal_zone*/temp; do
    [ -r "$z" ] && echo "$(cat "$(dirname "$z")/type"): $(( $(cat "$z") / 1000 )) °C"
  done
  echo "kernel thermal / voltage messages:"; journalctl -k --since "$SINCE" --no-pager -q -o cat | grep -iE 'thermal|throttl|under-voltage|voltage' | top 5

  sec "Disks"
  df -h -x tmpfs -x devtmpfs -x overlay -x squashfs -x efivarfs 2>/dev/null
  for d in $(lsblk -dno NAME,TYPE | awk '$2=="disk" && $1 !~ /^(zram|loop)/ {print $1}'); do
    echo "SMART /dev/$d:"
    { sudo -n smartctl -H -A -d sat "/dev/$d" 2>/dev/null || sudo -n smartctl -H -A "/dev/$d" 2>/dev/null; } |
      grep -E 'overall-health|Reallocated|Pending|Uncorrect|Wear_Level|Power_On_Hours|Temperature_Celsius|CRC_Error|Percentage Used|Media and Data|Unsafe Shutdowns|Available Spare' |
      sed 's/^/  /' || echo "  (no SMART data)"
  done
  echo "disk / filesystem errors (kernel):"
  journalctl -k --since "$SINCE" --no-pager -q -o cat | grep -iE 'I/O error|EXT4-fs (error|warning)|blk_update_request|reset (high|super)-speed USB|uas_eh|buffer I/O' | top 8

  sec "Memory"
  free -h
  echo "out-of-memory kills:"; journalctl -k --since "$SINCE" --no-pager -q -o cat | grep -iE 'out of memory|oom-kill|killed process' | tail -n 8

  sec "Kernel warnings and errors (most repeated)"
  journalctl -k -p warning --since "$SINCE" --no-pager -q -o cat | top 12

  sec "Errors per service (priority err and worse)"
  journalctl -p err --since "$SINCE" --no-pager -q -o json --output-fields=_SYSTEMD_UNIT,SYSLOG_IDENTIFIER 2>/dev/null |
    python3 -c '
import collections, json, sys
c = collections.Counter()
for line in sys.stdin:
    try: d = json.loads(line)
    except ValueError: continue
    c[d.get("_SYSTEMD_UNIT") or d.get("SYSLOG_IDENTIFIER") or "?"] += 1
for name, n in c.most_common(10): print(f"{n:7} {name}")'
  echo "most repeated error lines:"; journalctl -p err --since "$SINCE" --no-pager -q -o cat | top 12

  sec "Service restarts and failures"
  journalctl --since "$SINCE" --no-pager -q -o cat | grep -oE '^[^ ]+\.service: (Scheduled restart job|Failed with result .*)' | top 10
  echo "failed units now:"; systemctl --failed --no-legend --plain | sed 's/^/  /'

  sec "Containers"
  docker ps -a --format '{{.Names}}\t{{.Status}}' 2>/dev/null | sort
  echo "restart counts since each container was created:"
  docker ps -aq 2>/dev/null | xargs -r docker inspect -f '{{.Name}} restarts={{.RestartCount}} started={{.State.StartedAt}}' 2>/dev/null | sed 's#^/#  #'
  echo "watchdog alerts sent:"; journalctl -u container-watchdog --since "$SINCE" --no-pager -q -o cat | grep -E '⚠️|🛑|🔴|✅' | top 10
  for c in $(docker ps -a --format '{{.Names}}' 2>/dev/null | sort); do
    lines="$(docker logs --since "$((DAYS * 24))h" "$c" 2>&1 | grep -iE 'error|exception|traceback|fatal|failed' | tail -n 200 | top 5)"
    [ -n "$lines" ] && printf '%s error lines (most repeated):\n%s\n' "$c" "$lines"
  done

  sec "Network and DNS"
  echo "Docker DNS lookups that timed out: $(journalctl -u docker --since "$SINCE" --no-pager -q -o cat | grep -c 'failed to query external DNS')"
  journalctl -u docker --since "$SINCE" --no-pager -q -o short-iso | grep 'failed to query external DNS' | cut -c1-13 | uniq -c | sort -rn | head -5 | sed 's/^/  busiest hours: /'
  grep -E '^(nameserver|search)' /etc/resolv.conf
  echo "link changes:"; journalctl --since "$SINCE" --no-pager -q -o cat | grep -iE 'eth0.*(link is (up|down)|carrier)|NIC Link is' | top 5

  sec "Updates"
  sudo -n apt-get update -qq >/dev/null 2>&1
  echo "packages waiting for an update: $(apt list --upgradable 2>/dev/null | tail -n +2 | wc -l)"
  [ -f /var/run/reboot-required ] && echo "a reboot is required to finish updates"

  sec "Claude Code"
  "$CLAUDE" --version 2>/dev/null
  "$CLAUDE" auth status --json 2>/dev/null | python3 -c 'import json,sys; d=json.load(sys.stdin); print("signed in:", d.get("loggedIn"), "until", d.get("loginExpiresAt"))'

  sec "Repos in ~/claude"
  [ -x "$HOME/.claude/hooks/sync-check.sh" ] && "$HOME/.claude/hooks/sync-check.sh" 2>/dev/null | sed -n '1,30p'
}

collect > "$REPORT" 2>&1
for ext in txt diagnosis; do ls -1t "$OUT_DIR"/*."$ext" 2>/dev/null | tail -n +13 | xargs -r rm -f; done   # keep 12 weeks
[ "$AI" = 1 ] || { cat "$REPORT"; [ "$SEND" = 1 ] && "$MESSENGER" --text="$(head -c 3800 "$REPORT")" >/dev/null; exit 0; }

# shellcheck disable=SC2010  # report names are dates
prev="$(ls -1t "$OUT_DIR"/*.txt | grep -vxF "$REPORT" | head -1)"
prompt="You are the weekly health reviewer for $HOST, the owner's home server: a Raspberry Pi 4 (2 GB RAM, SSD over USB) that runs a Docker homelab stack (~/claude/docker; see its CLAUDE.md) and Claude Code Remote Control, which the owner uses from a phone.

Below is this week's report${prev:+, followed by the report from a week earlier}. You may run read-only commands (journalctl, docker logs, systemctl status) to dig into anything suspicious, e.g. why something restarts often. Change nothing. Never print secrets. Known normal, not issues: qBittorrent.conf and letsencrypt renewal/*.conf in ~/claude/docker always show as modified (the apps rewrite them; they are never committed).

Then reply with ONLY a plain-text Telegram message (no markdown tables, at most about 1500 characters):
- first line: '🩺 $HOST weekly: all good' or '🩺 $HOST weekly: N things to look at'
- then each real issue, most important first: what happened (numbers), the likely cause with the evidence, and a concrete fix
- then notable changes since last week, if any
Skip everything that is fine. Explain simply: the owner likes to learn."

input="=== THIS WEEK ($REPORT) ===
$(cat "$REPORT")"
[ -n "$prev" ] && input="$input

=== LAST WEEK ($prev) ===
$(cat "$prev")"

diag="$(cd "$OUT_DIR" && printf '%s' "$input" | timeout 900 "$CLAUDE" -p "$prompt" --permission-mode default \
  --allowedTools "Bash(journalctl *)" "Bash(docker logs *)" "Bash(systemctl status *)" "Read" "Grep" 2>&1)"
status=$?
if [ $status -ne 0 ] || [ -z "$diag" ]; then
  diag="🩺 $HOST weekly: Claude could not analyse it (exit $status: $(tail -c 300 <<< "$diag")). Raw report:

$(head -c 3000 "$REPORT")"
fi
printf '%s\n' "$diag" > "${REPORT%.txt}.diagnosis"
echo "$diag"
[ "$SEND" = 1 ] && MESSENGER_ENV_FILE="$STACK_DIR/.env" "$MESSENGER" --text="$diag" >/dev/null
exit 0
