#!/bin/bash
# claudepad hook — receives Claude Code hook JSON on stdin, maintains
# ~/.claude/claudepad/state/<session_id>.json for the claudepad daemon.
# Must be fast and silent; never block Claude on errors.
set -u
STATE_DIR="$HOME/.claude/claudepad/state"
mkdir -p "$STATE_DIR" 2>/dev/null

command -v jq >/dev/null 2>&1 || exit 0
input=$(cat)

sid=$(jq -r '.session_id // empty' <<<"$input" 2>/dev/null)
[ -z "$sid" ] && exit 0
evt=$(jq -r '.hook_event_name // empty' <<<"$input")
f="$STATE_DIR/$sid.json"
now=$(date +%s)

# Walk ancestors to find the claude CLI process pid (daemon uses it for liveness).
find_claude_pid() {
  local p=$PPID i=0 comm
  while [ "$p" -gt 1 ] && [ $i -lt 6 ]; do
    comm=$(ps -o comm= -p "$p" 2>/dev/null)
    case "$comm" in
      *claude*|*node*) echo "$p"; return ;;
    esac
    p=$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' ')
    [ -z "$p" ] && break
    i=$((i + 1))
  done
  echo "$PPID"
}

# merge <jq-filter> [extra jq args...] — apply filter to state file under a
# per-session lock (hooks for one session can fire concurrently; an unlocked
# read-modify-write loses entries, e.g. a PostToolUse clobbering SubagentStart).
# $now, $sid are always bound.
merge() {
  local filter="$1"; shift
  local lock="$f.lock" i=0
  while ! mkdir "$lock" 2>/dev/null; do
    i=$((i + 1))
    if [ $i -gt 40 ]; then rmdir "$lock" 2>/dev/null; fi   # steal stale lock
    [ $i -gt 44 ] && break
    sleep 0.025
  done
  local tmp="$f.tmp.$$" cur='{}'
  [ -f "$f" ] && cur=$(cat "$f" 2>/dev/null)
  [ -z "$cur" ] && cur='{}'
  if jq -c --argjson now "$now" --arg sid "$sid" "$@" "$filter" <<<"$cur" >"$tmp" 2>/dev/null; then
    mv "$tmp" "$f"
  fi
  rm -f "$tmp" 2>/dev/null
  rmdir "$lock" 2>/dev/null
  return 0
}

case "$evt" in
  SessionStart)
    cwd=$(jq -r '.cwd // empty' <<<"$input")
    tp=$(jq -r '.transcript_path // empty' <<<"$input")
    pid=$(find_claude_pid)
    merge '. + {session_id: $sid, cwd: $cwd, transcript_path: $tp, pid: ($pid | tonumber), status: "idle", last_seen: $now}
           | .agents //= [] | .started_at //= $now' \
      --arg cwd "$cwd" --arg tp "$tp" --arg pid "$pid"
    ;;
  UserPromptSubmit)
    merge '.status = "working" | .last_seen = $now
           | .agents = [(.agents // [])[] | select(.status == "running")]'
    ;;
  PreToolUse|PostToolUse)
    merge '.status = "working" | .last_seen = $now'
    ;;
  SubagentStart)
    aid=$(jq -r '.agent_id // empty' <<<"$input")
    atype=$(jq -r '.agent_type // "agent"' <<<"$input" | head -c 40)
    merge '.status = "working" | .last_seen = $now
           | .agents = (((.agents // []) + [{id: $aid, desc: $atype, status: "running", t: $now}]) | .[-8:])' \
      --arg aid "$aid" --arg atype "$atype"
    ;;
  SubagentStop)
    aid=$(jq -r '.agent_id // empty' <<<"$input")
    # Only mark the matching agent done. When an id is present but unknown to
    # us (internal helper agents), do nothing — a first-running fallback would
    # kill a real agent's pad. Fallback only when no id was provided at all.
    merge '.last_seen = $now
           | .agents = ((.agents // []) as $a
               | (if $aid != "" then (first(range($a | length) as $i | select($a[$i].id == $aid and $a[$i].status == "running") | $i) // -1)
                  else (first(range($a | length) as $i | select($a[$i].status == "running") | $i) // -1)
                  end) as $i
               | if $i >= 0 then ($a | .[$i].status = "done") else $a end)' \
      --arg aid "$aid"
    ;;
  PermissionRequest|Notification)
    msg=$(jq -r '.message // ""' <<<"$input" | head -c 120)
    merge '.status = "waiting" | .message = $msg | .last_seen = $now' --arg msg "$msg"
    ;;
  Stop)
    merge '.status = "idle" | .last_seen = $now'
    ;;
  SessionEnd)
    rm -f "$f"
    ;;
esac
exit 0
