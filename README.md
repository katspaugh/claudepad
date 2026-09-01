# claudepad

A Novation **Launchpad Mini MK3** as a physical control panel for **Claude Code** sessions on macOS, with Ghostty as the terminal.

Zero dependencies: a single Swift daemon (CoreMIDI + AppleScript) fed by Claude Code hooks. Only the 8×8 grid is used — the top-row arrows, scene buttons, and logo stay dark and unbound.

```
        ┌────┐┌────┐┌────┐┌────┐┌────┐┌────┐┌────┐┌────┐
 row 8  │ ⬤ ││ ⬤ ││ ⬤ ││    ││    ││    ││    ││    │  session/status pads
        ├────┤├────┤├────┤├────┤├────┤├────┤├────┤├────┤
 row 7  │ a1 ││    ││ a1 │                               subagents
 row 6  │ a2 ││    ││    │                               (up to 4,
 row 5  │    ││    ││    │                                newest on top)
 row 4  │    ││    ││    │
        ├────┤├────┤├────┤
 row 3  │ CI ││ CI ││ CI │                               PR CI status pads
 row 2  │ E  ││ E  ││ E  │                               effort pads
 row 1  │ P  ││ P  ││ P  │                               preset pads
        └────┘└────┘└────┘└────┘└────┘└────┘└────┘└────┘
                     columns = sessions
```

## What it shows

Columns are sessions, ordered by start time; a column keeps its position while the session lives. **Geometry identifies the session — color only ever encodes status, model, or effort.**

- **Row 8 — session pad, colored by status**:
  - 🟠 pulsing orange — working
  - 🟡 flashing yellow — waiting for your input / permission
  - 🔵 pulsing cyan — "monitoring": turn idle but subagents still running
  - 🟢 solid green — idle / done
- **Rows 7–4 — running subagents**, newest at the top, pulsing cyan. The stack stays compact: when an agent finishes, its pad frees and the others shift immediately.
- **Row 3 — PR CI status** for the session's current branch (via `gh`, polled every 60s and refetched early when a session stops working — it may have just pushed):
  - 🟢 solid green — checks passing
  - 🔴 solid red — a check failed (deliberately no flash)
  - 🔵 pulsing blue — checks running
  - ⚪ dim white — open PR with no checks
  - dark — no open PR for the branch (or `gh` missing/unauthenticated)
- **Row 2 — effort pad**, colored by current effort: max red → xhigh orange → high yellow → medium green → low blue.
- **Row 1 — preset pad**, colored by the matching model+effort preset (default: Fable/high white, Opus/medium purple; dim white if the session matches no preset).

## What it does

| Press | Action |
|---|---|
| session pad | focus that session's Ghostty window or tab; a flashing (waiting) pad goes solid yellow until the next waiting event |
| subagent pad | focus the session, open the agent view (`←`), and attach to that agent (`↓`…`enter`) |
| CI pad (row 3) | open the branch's PR in the browser (focus the session if there is no PR) |
| preset pad (row 1) | toggle to the next model+effort preset — pad pulses through choices, applies **1.2s after your last tap** (pastes `/model …` then `/effort …`) |
| effort pad (row 2) | step effort **up** (low → … → max, wraps to low), same debounce |
| any pad in an empty column | scroll `5h X%  7d Y%` rate-limit usage across the grid |

Applying a model/effort **pastes `/model …` or `/effort …` + Enter directly into that session's terminal in the background** via Ghostty's scripting API — no window is raised, focus stays where you are. The pad shows the new value immediately (optimistically); once the statusline next reports that session's true state, the pad snaps to it — so a rejected or failed change reverts the pad to the actual current model/effort.

> ⚠️ Model/effort presses inject into the session's composer. If that session had half-typed text, the command is appended to it. Treat those pads as "the session is at rest" controls.

Presets, model/effort lists, commands, and colors are editable in `~/.claude/claudepad/config.json` (Launchpad palette indices; hot-reloaded).

## Menu bar

A status item mirrors the pad, for when the Launchpad is out of sight or unplugged:

- **filled grid icon** — Launchpad connected
- **outlined grid icon** — not connected
- **blinking** — at least one session is waiting on your input

Blinking uses the same unacknowledged-waiting rule as the flashing session pad, so the two never disagree: press the pad and both go quiet until a newer waiting event arrives. Opening the menu shows the connection state and names the sessions that are waiting.

## How it works

1. **Hooks** (`hooks/claudepad-hook.sh`, wired into `~/.claude/settings.json` for `SessionStart`, `SessionEnd`, `UserPromptSubmit`, `Pre/PostToolUse`, `SubagentStart/Stop`, `PermissionRequest`, `Notification`, `Stop`) maintain one JSON file per session in `~/.claude/claudepad/state/`.
2. **Statusline wrapper** (`hooks/statusline-wrap.sh`) tees the JSON Claude Code pipes to the statusline — model, effort, context %, rate limits — into the same state file, then runs your original `~/.claude/statusline-command.sh` untouched. `refreshInterval: 10` makes it a heartbeat.
3. **Daemon** (`bin/claudepad`) polls the state dir 4×/s, diffs LED frames, and drives the pad over the `LPMiniMK3 MIDI` port in programmer mode. Unplug/replug is handled; on exit it clears the pad and returns it to Live mode.
4. **Liveness**: a session column is removed when its recorded pid is dead, or when its statusline heartbeat stops for 90s (covers sessions hosted by the background daemon, whose recorded pid may be a long-lived worker). Note that a session closed in the terminal may legitimately live on as a background session — it stays on the board while it's really running.
5. **Headless sessions**: the hooks mark sessions hosted by the Claude Code background daemon (`claude bg-spare` workers, or sessions whose parent is a `bg-pty-host`) as `headless`; the daemon hides them since there is no terminal to focus. Set `"hideHeadless": false` in `config.json` to show them anyway.
6. **Ghostty control** uses Ghostty's native AppleScript dictionary (`sdef /Applications/Ghostty.app`): terminals are matched by exact `working directory` (falling back to a title-substring match against the session's latest topic title from the transcript), then `focus` raises the window and `input text` / `send key "enter"` inject commands without focusing.

## Setup

```bash
./build.sh                  # → bin/claudepad
./bin/claudepad             # run in foreground (Ctrl-C to quit)
# or install as a LaunchAgent that starts at login:
./install.sh
```

- Hooks and the statusline wrapper are already wired into `~/.claude/settings.json`. Only sessions started (or restarted) after that wiring report full state.
- **Automation permission**: controlling Ghostty uses Apple Events. macOS prompts once ("…wants to control Ghostty") for the app that launches the daemon — approve it. Manage later under *System Settings → Privacy & Security → Automation*. (Accessibility is *not* required.)
- Sessions are matched to terminals by exact working directory. Two sessions in the same directory match the same terminal; worktrees are fine (distinct paths).

## Files

```
src/main.swift            the daemon (CoreMIDI, rendering, input, osascript)
hooks/claudepad-hook.sh   hook → state file reducer
hooks/statusline-wrap.sh  statusline tee (model/effort/usage) + passthrough
build.sh / install.sh     build; optional LaunchAgent install
~/.claude/claudepad/      state/, config.json, ghostty.applescript (generated)
```

## Ideas / next steps

- **Paging** for >8 sessions.
- **Attention flash**: scroll the project name across the grid when a session starts waiting for you.
- **Context-window meter**: e.g. brightness of the session pad, or a dedicated row.
- **Hold-to-interrupt**: long-press a session pad to send Escape (interrupt the turn) — needs press/release timing, deliberately not bound to a tap.
- **Idle animation** when no sessions are live.
