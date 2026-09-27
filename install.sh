#!/usr/bin/env bash
# Installs claude-wled-status into Claude Code.
#   ./install.sh http://192.168.1.50      (your WLED address)
#   ./install.sh --uninstall
set -euo pipefail

CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
SETTINGS="$CLAUDE_DIR/settings.json"
TARGET="$CLAUDE_DIR/hooks/wled-status.sh"
CONF="$CLAUDE_DIR/hooks/wled-status.conf"
HERE="$(cd "$(dirname "$0")" && pwd)"

for cmd in jq curl flock; do
  command -v "$cmd" >/dev/null || { echo "Missing dependency: $cmd"; exit 1; }
done

mkdir -p "$CLAUDE_DIR/hooks"
[ -f "$SETTINGS" ] || echo '{}' >"$SETTINGS"
cp "$SETTINGS" "$SETTINGS.bak-wled-$(date +%Y%m%d%H%M%S)"

# remove any hooks from a previous install (keeps all your other hooks)
strip='
  .hooks = ((.hooks // {})
    | map_values(map(.hooks |= map(select((.command // "") | contains("wled-status.sh") | not)))
                 | map(select(.hooks | length > 0)))
    | with_entries(select(.value | length > 0)))
'

if [ "${1:-}" = "--uninstall" ]; then
  jq "$strip" "$SETTINGS" >"$SETTINGS.tmp" && mv "$SETTINGS.tmp" "$SETTINGS"
  rm -f "$TARGET" "$CONF"
  echo "Uninstalled. Backup of your settings: $SETTINGS.bak-wled-*"
  exit 0
fi

HOST="${1:-}"
if [ -z "$HOST" ]; then
  read -rp "WLED address (e.g. http://192.168.1.50 or http://wled.local): " HOST
fi
case "$HOST" in http://*|https://*) ;; *) HOST="http://$HOST" ;; esac
HOST="${HOST%/}"

if curl -s -m 3 "$HOST/json/info" | jq -e .ver >/dev/null 2>&1; then
  echo "Found WLED $(curl -s -m 3 "$HOST/json/info" | jq -r '.name + " (v" + .ver + ", " + (.leds.count|tostring) + " LEDs)"')"
else
  echo "Warning: could not reach WLED at $HOST - installing anyway."
fi

install -m 755 "$HERE/wled-status.sh" "$TARGET"
{ grep -v '^WLED_HOST=' "$CONF" 2>/dev/null || true; echo "WLED_HOST=\"$HOST\""; } >"$CONF.tmp"
mv "$CONF.tmp" "$CONF"

jq --arg s "$TARGET" "$strip"'
  | def add(ev; m; arg):
      .hooks[ev] = ((.hooks[ev] // []) + [{"matcher": m, "hooks": [{"type": "command", "command": ($s + " " + arg), "timeout": 5}]}]);
  add("UserPromptSubmit"; ""; "prompt")
  | add("PreToolUse"; ""; "pre")
  | add("PostToolUse"; ""; "post")
  | add("PermissionRequest"; ""; "ask")
  | add("Notification"; "permission_prompt|elicitation_dialog"; "ask")
  | add("PreCompact"; ""; "compact")
  | add("SessionStart"; "compact"; "stop")
  | add("Stop"; ""; "stop")
  | add("StopFailure"; ""; "fail")
  | add("SubagentStart"; ""; "sub_start")
  | add("SubagentStop"; ""; "sub_stop")
  | add("SessionEnd"; ""; "end")
' "$SETTINGS" >"$SETTINGS.tmp" && mv "$SETTINGS.tmp" "$SETTINGS"

echo "Installed. Restart Claude Code (or open /hooks) and send a message - your light should turn blue."
