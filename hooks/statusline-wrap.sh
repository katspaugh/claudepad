#!/bin/bash
# claudepad statusline wrapper — tees the statusline JSON (model, effort,
# context %, rate limits) into the claudepad state file, then delegates to
# the user's original statusline script.
input=$(cat)

STATE_DIR="$HOME/.claude/claudepad/state"

if command -v jq >/dev/null 2>&1; then
  (
    sid=$(jq -r '.session_id // empty' <<<"$input" 2>/dev/null)
    if [ -n "$sid" ]; then
      mkdir -p "$STATE_DIR" 2>/dev/null
      f="$STATE_DIR/$sid.json"
      now=$(date +%s)
      # Claude pid: statusline is spawned by the claude process (possibly via sh).
      p=$PPID; i=0
      while [ "$p" -gt 1 ] && [ $i -lt 6 ]; do
        comm=$(ps -o comm= -p "$p" 2>/dev/null)
        case "$comm" in *claude*|*node*) break ;; esac
        p=$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' '); [ -z "$p" ] && p=1
        i=$((i + 1))
      done
      # Headless = hosted by the background daemon (bg-spare worker, or parent
      # is a bg-pty-host): no terminal to focus, hidden by the daemon.
      headless=0
      case "$(ps -o command= -p "$p" 2>/dev/null)" in *bg-spare*) headless=1 ;; esac
      pp=$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' ')
      case "$(ps -o command= -p "${pp:-1}" 2>/dev/null)" in *bg-pty-host*) headless=1 ;; esac
      # Same per-session lock as claudepad-hook.sh — unlocked read-modify-write
      # races with hooks and loses their updates.
      lock="$f.lock"; i=0
      while ! mkdir "$lock" 2>/dev/null; do
        i=$((i + 1))
        if [ $i -gt 40 ]; then rmdir "$lock" 2>/dev/null; fi
        [ $i -gt 44 ] && break
        sleep 0.025
      done
      cur='{}'; [ -f "$f" ] && cur=$(cat "$f" 2>/dev/null); [ -z "$cur" ] && cur='{}'
      tmp="$f.tmp.$$"
      jq -c --argjson now "$now" --argjson sl "$input" --arg pid "$p" --arg headless "$headless" '
        . + {
          session_id: ($sl.session_id),
          cwd: ($sl.cwd // $sl.workspace.current_dir // .cwd),
          transcript_path: ($sl.transcript_path // .transcript_path),
          model: ($sl.model.display_name // .model),
          model_id: ($sl.model.id // .model_id),
          effort: ($sl.effort.level // .effort),
          ctx_pct: ($sl.context_window.used_percentage // .ctx_pct),
          usage_5h: ($sl.rate_limits.five_hour.used_percentage // .usage_5h),
          usage_7d: ($sl.rate_limits.seven_day.used_percentage // .usage_7d),
          last_seen: $now,
          sl_seen: $now,
          headless: ($headless == "1")
        }
        | .pid //= ($pid | tonumber)
        | .status //= "idle" | .agents //= []
      ' <<<"$cur" >"$tmp" 2>/dev/null && mv "$tmp" "$f"
      rm -f "$tmp" 2>/dev/null
      rmdir "$lock" 2>/dev/null
    fi
  ) &
fi

if [ -f "$HOME/.claude/statusline-command.sh" ]; then
  echo "$input" | bash "$HOME/.claude/statusline-command.sh"
fi
