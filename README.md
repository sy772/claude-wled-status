# Claude Code × WLED: an ambient status light for your AI pair programmer

Stop staring at the terminal waiting for Claude. This project turns any [WLED](https://kno.wled.ge/) light into a status indicator for [Claude Code](https://claude.com/claude-code). Glance at the wall and you can tell whether Claude is **thinking**, **needs your approval**, or **is done and waiting for you**.

It works well with a strip behind the monitor or keyboard. The colors and effects are chosen so you can read them **from the reflection on the wall** without looking at the LEDs directly.

> 🤖 **This project was created automatically with [Claude Code](https://claude.com/claude-code).** Claude designed, wrote, tested and published it after a single conversation about "can my WLED strip tell me what Claude is doing?"

---

## What the colors mean

| Light | Meaning |
|---|---|
| 🔵 **Blue, slow breathe** | Claude is thinking or working. Nothing to do. |
| 🟣 **Purple, slow breathe** | Subagents are running in the background (longer jobs). |
| 🟠 **Orange, fast blink** | **Claude needs you:** a permission prompt or a question. |
| 🟢 **Green, solid** | Finished. Your turn to reply. |
| 🔴 **Red, slow breathe** | Something failed (API error, rate limit). Check the terminal. |
| ⚪ **White, breathe** | Claude is compacting its context. Takes a moment. |
| *your normal light* (or off) | No Claude activity for 15 minutes (whatever the color was), or the session ended. Your previous WLED state is restored, or the light turns off if you set `WLED_IDLE_ACTION=off`. |

**Several Claude sessions open?** The most urgent state wins. If any session needs you, the light is orange.

**Night mode:** between 23:00 and 07:00 brightness drops to 70/255.

---

## Install (about 1 minute)

**Requirements:** Claude Code, a WLED device on your network, and `jq`, `curl` and `flock`.
- Debian/Ubuntu: `sudo apt install jq curl util-linux`
- Arch: `sudo pacman -S jq curl util-linux`
- macOS: `brew install jq flock`

```bash
git clone https://github.com/sy772/claude-wled-status.git
cd claude-wled-status
./install.sh http://192.168.1.50      # ← your WLED's IP or hostname (e.g. http://wled.local)
```

Restart Claude Code (or open a new session) and send a message. Your light should go blue, then green when Claude answers.

What the installer does:
- copies `wled-status.sh` to `~/.claude/hooks/`
- writes your WLED address to `~/.claude/hooks/wled-status.conf`
- adds hooks to `~/.claude/settings.json`, **keeping all your existing hooks**
- saves a timestamped backup of your settings first (`settings.json.bak-wled-…`)

Running it again is safe. It replaces its own hooks and does not add duplicates.

### Uninstall

```bash
./install.sh --uninstall
```

---

## Customize

All settings go in **`~/.claude/hooks/wled-status.conf`**. It is a plain shell file and survives re-installs. Changes apply immediately, no restart needed.

```bash
WLED_HOST="http://192.168.1.50"

# brightness and night mode
WLED_BRIGHTNESS=255          # daytime brightness (0-255)
WLED_NIGHT_BRIGHTNESS=70     # night brightness (0-255)
WLED_NIGHT_START=23          # night mode from 23:00...
WLED_NIGHT_END=7             # ...until 07:00

# seconds without any Claude activity before your normal light comes back
# (applies to every state, so nothing can stay stuck)
WLED_IDLE_TIMEOUT=900

# what happens after that: "restore" (default) brings back the light you had
# before Claude started; "off" always turns the light off
WLED_IDLE_ACTION=restore

# which WLED segment to use (if you split your strip)
WLED_SEGMENT=0

# change any state's look: "R,G,B  effect-id  speed  intensity"
WLED_LOOK_work="0,255,255 2 110 128"     # cyan instead of blue
WLED_LOOK_ask="255,0,80 1 240 128"       # pink, even faster blink
WLED_LOOK_done="0,255,30 0 128 128"      # solid green
```

States you can override: `work`, `agents`, `ask`, `done`, `fail`, `compact`.

**Effect IDs:** `0` Solid, `1` Blink, `2` Breathe. Any of WLED's 200+ effects work. You can find the IDs in the WLED web UI or at `http://<your-wled>/json/effects` (the list is zero-indexed). Speed and intensity are 0–255, the same as the sliders in the WLED UI.

**Pause it temporarily:** start Claude with `WLED_DISABLE=1 claude`.

### Tips for indirect / reflected light
- Use **different hues and different motion** for states you need to tell apart. On a wall, blue vs. cyan is hard to distinguish, but blue *breathing* vs. orange *blinking* is obvious even in your peripheral vision.
- Spatial effects (chases, progress bars, split segments) blur together in a reflection. Keep those for strips you look at directly.

---

## How it works

Claude Code has [hooks](https://docs.claude.com/en/docs/claude-code/hooks): shell commands it runs at specific moments. This project connects them to WLED's [JSON API](https://kno.wled.ge/interfaces/json-api/):

| Claude Code hook | → state |
|---|---|
| `UserPromptSubmit`, `PreToolUse`, `PostToolUse` | work |
| `SubagentStart` / `SubagentStop` | agents (counted per session) |
| `PermissionRequest`, `Notification` (permission / elicitation), `AskUserQuestion`, `ExitPlanMode` | ask |
| `PreCompact` | compact |
| `Stop` | done |
| `StopFailure` | fail |
| `SessionEnd` | session removed |

Design notes:
- **Never slows Claude down.** The hook returns immediately and the HTTP call happens in the background with a 2-second timeout. If WLED is offline, nothing breaks.
- **Only sends when something changes.** Hundreds of tool calls produce one request.
- **Multi-session aware.** Each session's state is stored in `$XDG_RUNTIME_DIR/claude-wled-<uid>/`, and the light shows the most urgent one.
- **Restores your light.** Before the first change it snapshots your WLED state, and it puts it back when Claude goes idle. If your normal light looks like one of the status colors (e.g. a red preset), set `WLED_IDLE_ACTION=off` so an idle light can never be mistaken for a Claude state.
- **Nothing stays stuck.** A single background watchdog checks every minute and drops any session that has been quiet for `WLED_IDLE_TIMEOUT`, so a light left over from an interrupted turn (Esc), a denied permission or a crashed terminal clears on its own. The watchdog exits once everything is idle.
- **Failed tool calls are deliberately *not* flashed red.** Normal things like `grep` finding nothing count as "failures" and would make the light flicker constantly.

Tested on Linux with WLED 16 and Claude Code 2.1. It should also work on macOS (with `flock` from Homebrew). Windows users can try WSL.

---

## Troubleshooting

Every state change is logged to `$XDG_RUNTIME_DIR/claude-wled-<uid>/events.log` (on most Linux systems that is `/run/user/1000/claude-wled-1000/events.log`):

```
2026-09-27 21:18:35 3f2a91c0 fail -> fail (agents 0)
2026-09-27 21:18:35 light idle -> fail (http 200)
2026-09-27 21:33:42 timeout 3f2a91c0 (fail)
2026-09-27 21:33:42 light fail -> idle (http 200)
```

- **Light shows an unexpected color?** `tail -20` the log to see which session and event caused it.
- **`http 000`?** The WLED device could not be reached. Check `WLED_HOST` in `~/.claude/hooks/wled-status.conf`. The script retries on the next check.
- **Nothing happens at all?** Run `/hooks` in Claude Code and check that the `wled-status.sh` entries are listed.

---

## License

MIT. Do whatever you like. PRs with new states or effects are welcome.
