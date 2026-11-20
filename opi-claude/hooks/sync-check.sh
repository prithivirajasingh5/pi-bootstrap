#!/usr/bin/env bash
# SessionStart hook: report git sync state of every project in ~/claude
# (plus the ~/claude-backup repo) against its GitHub remote.
# stdout is injected into Claude's context at session start.
# Rules (see ~/claude/CLAUDE.md):
#   - folders with a .local-only marker are skipped silently
#   - non-git folders without the marker are flagged
#   - never pushes or pulls; read-only apart from `git fetch`

set -u
ROOT="${SYNC_CHECK_ROOT:-$HOME/claude}"   # override only for testing
FETCH_TIMEOUT=15

dirs=()
for d in "$ROOT"/*/ "$HOME/claude-backup/"; do
  [ -d "$d" ] || continue
  [ -e "$d.local-only" ] && continue
  dirs+=("${d%/}")
done

# Fetch all repos in parallel so a slow remote doesn't stall session start.
for d in "${dirs[@]}"; do
  if [ -d "$d/.git" ] && git -C "$d" remote get-url origin >/dev/null 2>&1; then
    timeout "$FETCH_TIMEOUT" git -C "$d" fetch -q origin >/dev/null 2>&1 &
  fi
done
wait

issues=()
ok=()
for d in "${dirs[@]}"; do
  name="${d#$ROOT/}"; [ "$d" = "$HOME/claude-backup" ] && name="~/claude-backup"

  if [ ! -d "$d/.git" ]; then
    issues+=("- $name: NOT a git repo and no .local-only marker (git init it, or mark it local-only)")
    continue
  fi
  if ! git -C "$d" remote get-url origin >/dev/null 2>&1; then
    issues+=("- $name: git repo with NO GitHub remote (offer to create a private repo)")
    continue
  fi

  branch=$(git -C "$d" branch --show-current 2>/dev/null)
  up=$(git -C "$d" rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null) \
    || up="origin/$branch"
  if ! git -C "$d" rev-parse -q --verify "$up" >/dev/null; then
    issues+=("- $name: branch '$branch' has no remote counterpart ($up) — never pushed?")
    continue
  fi

  ahead=$(git -C "$d" rev-list --count "$up..HEAD")
  behind=$(git -C "$d" rev-list --count "HEAD..$up")
  dirty=$(git -C "$d" status --porcelain | wc -l)

  msg=()
  [ "$ahead"  -gt 0 ] && msg+=("$ahead ahead (needs push)")
  [ "$behind" -gt 0 ] && msg+=("$behind behind (needs pull)")
  if [ "$dirty" -gt 0 ]; then
    files=$(git -C "$d" status --porcelain | head -5 | awk '{print $2}' | paste -sd, -)
    [ "$dirty" -gt 5 ] && files="$files, …"
    msg+=("$dirty uncommitted ($files)")
  fi

  if [ ${#msg[@]} -eq 0 ]; then
    ok+=("$name")
  else
    joined=$(printf '%s; ' "${msg[@]}"); issues+=("- $name: ${joined%; }")
  fi
done

echo "## Startup sync check (~/claude repos vs GitHub)"
if [ ${#issues[@]} -eq 0 ]; then
  echo "All repos in sync: ${ok[*]:-none}."
else
  printf '%s\n' "${issues[@]}"
  [ ${#ok[@]} -gt 0 ] && echo "In sync: ${ok[*]}"
  echo
  echo "Instruction: before other work, show the user this sync state as a short table and list the"
  echo "needed actions as a numbered list. Do NOT push, pull or commit without the user's confirmation."
fi
exit 0
