#!/usr/bin/env bash
# claude-wled-status: shows what Claude Code is doing on a WLED light.
# Called by Claude Code hooks: hook JSON on stdin, event name in $1.
# Never blocks Claude: all work happens in the background and errors are ignored.
# https://github.com/sy772/claude-wled-status

# ---- Settings ----------------------------------------------------------------
# Put overrides in wled-status.conf next to this script (install.sh writes
# WLED_HOST there), or set them as environment variables.
CONF="$(dirname "$0")/wled-status.conf"
[ -f "$CONF" ] && . "$CONF"
WLED="${WLED_HOST:-http://wled.local}"       # your WLED address
SEG="${WLED_SEGMENT:-0}"                      # segment to use
DONE_TIMEOUT="${WLED_DONE_TIMEOUT:-900}"      # seconds green stays on before restoring your light
DAY_BRI="${WLED_BRIGHTNESS:-255}"             # brightness during the day (0-255)
NIGHT_BRI="${WLED_NIGHT_BRIGHTNESS:-70}"      # brightness at night (0-255)
NIGHT_START="${WLED_NIGHT_START:-23}"         # night mode from this hour...
NIGHT_END="${WLED_NIGHT_END:-7}"              # ...until this hour
STALE_MIN=180                                 # ignore sessions untouched for 3 hours

# ---- Look of each state ----------------------------------------------------
# color "r,g,b" | WLED effect id | speed | intensity
# Effect ids: 0 = Solid, 1 = Blink, 2 = Breathe (full list: WLED UI or /json/effects)
# Override one in wled-status.conf, e.g.  WLED_LOOK_work="0,255,255 2 110 128"
look() {
  local v="WLED_LOOK_$1"
  [ -n "${!v:-}" ] && { echo "${!v}"; return; }
  case "$1" in
    ask)     echo "255,80,0     1 225 128" ;;  # orange, fast blink   -> needs your input
    fail)    echo "255,0,0      2 60  128" ;;  # red, slow breathe    -> error, check terminal
    compact) echo "255,255,255  2 180 128" ;;  # white, breathe       -> compacting context
    agents)  echo "170,0,255    2 110 128" ;;  # purple, breathe      -> subagents running
    work)    echo "0,40,255     2 110 128" ;;  # blue, breathe        -> thinking / working
    done)    echo "0,255,30     0 128 128" ;;  # green, solid         -> finished, your turn
  esac
}
# -----------------------------------------------------------------------------

EVENT="$1"
INPUT="$(cat 2>/dev/null)"
TS="$(date +%s%N)"
case "$TS" in *N) TS="$(perl -MTime::HiRes=time -e 'printf "%d", time()*1e9')" ;; esac  # macOS
DIR="${XDG_RUNTIME_DIR:-/tmp}/claude-wled-$(id -u)"

[ "${WLED_DISABLE:-0}" = 1 ] && exit 0

run() {
  mkdir -p "$DIR"
  exec 9>"$DIR/lock"
  flock -w 5 9 || exit 0

  local sid tool
  sid="$(jq -r '.session_id // "x"' <<<"$INPUT" 2>/dev/null)"
  tool="$(jq -r '.tool_name // ""' <<<"$INPUT" 2>/dev/null)"
  [ -z "$sid" ] && sid=x
  local f="$DIR/s_$sid"

  # per-session state: state subagent_count last_timestamp
  local state=idle agents=0 last=0
  [ -f "$f" ] && read -r state agents last <"$f"

  case "$EVENT" in
    expire:*)
      # only go dark if nothing happened since that Stop
      [ "${EVENT#expire:}" = "$last" ] && [ "$state" = done ] && state=idle
      ;;
    *)
      # drop events that arrive out of order
      [ "$TS" -lt "${last:-0}" ] 2>/dev/null && exit 0
      last="$TS"
      case "$EVENT" in
        prompt|post) state=work ;;
        pre)
          case "$tool" in
            AskUserQuestion|ExitPlanMode) state=ask ;;
            *) state=work ;;
          esac ;;
        ask)       state=ask ;;
        compact)   state=compact ;;
        stop)      state=done ;;
        fail)      state=fail ;;
        sub_start) agents=$((agents + 1)) ;;
        sub_stop)  agents=$((agents > 0 ? agents - 1 : 0)) ;;
        end)       rm -f "$f"; state=gone ;;
      esac
      ;;
  esac
  [ "$state" != gone ] && echo "$state $agents $last" >"$f"

  if [ "$EVENT" = stop ]; then
    ( sleep "$DONE_TIMEOUT"; echo '{"session_id":"'"$sid"'"}' | "$0" "expire:$TS" ) \
      </dev/null >/dev/null 2>&1 9>&- &
  fi

  # merge all sessions: the most urgent state wins
  find "$DIR" -name 's_*' -mmin +"$STALE_MIN" -delete 2>/dev/null
  local best=idle bp=0 p s a
  for sf in "$DIR"/s_*; do
    [ -f "$sf" ] || continue
    read -r s a _ <"$sf"
    [ "${a:-0}" -gt 0 ] && [ "$s" != ask ] && [ "$s" != fail ] && s=agents
    case "$s" in
      ask) p=6 ;; fail) p=5 ;; compact) p=4 ;; agents) p=3 ;;
      work) p=2 ;; done) p=1 ;; *) p=0 ;;
    esac
    [ "$p" -gt "$bp" ] && { bp=$p; best=$s; }
  done

  [ "$(cat "$DIR/current" 2>/dev/null)" = "$best" ] && exit 0

  local prev; prev="$(cat "$DIR/current" 2>/dev/null || echo idle)"
  # remember your own light setting before Claude takes over
  if [ "$prev" = idle ] && [ "$best" != idle ]; then
    curl -s -m 2 "$WLED/json/state" -o "$DIR/saved.json.tmp" \
      && mv "$DIR/saved.json.tmp" "$DIR/saved.json"
  fi

  if [ "$best" = idle ]; then
    if [ -f "$DIR/saved.json" ]; then
      jq -c '{on,bri,transition:10,seg:[.seg[]|{id,start,stop,on,bri,col,fx,sx,ix,pal,c1,c2,c3}]}' \
        "$DIR/saved.json" 2>/dev/null \
        | curl -s -m 2 -X POST -H 'Content-Type: application/json' -d @- "$WLED/json/state" >/dev/null
    else
      curl -s -m 2 -X POST -d '{"on":false}' "$WLED/json/state" >/dev/null
    fi
  else
    local h bri="$DAY_BRI" c fx sx ix
    h=$(date +%-H)
    if [ "$NIGHT_START" -gt "$NIGHT_END" ]; then
      { [ "$h" -ge "$NIGHT_START" ] || [ "$h" -lt "$NIGHT_END" ]; } && bri="$NIGHT_BRI"
    else
      { [ "$h" -ge "$NIGHT_START" ] && [ "$h" -lt "$NIGHT_END" ]; } && bri="$NIGHT_BRI"
    fi
    read -r c fx sx ix <<<"$(look "$best")"
    curl -s -m 2 -X POST -H 'Content-Type: application/json' \
      -d '{"on":true,"bri":'"$bri"',"transition":4,"seg":[{"id":'"$SEG"',"on":true,"bri":255,"fx":'"$fx"',"sx":'"$sx"',"ix":'"$ix"',"pal":0,"col":[['"$c"'],[0,0,0],[0,0,0]]}]}' \
      "$WLED/json/state" >/dev/null
  fi
  echo "$best" >"$DIR/current"
}

( run ) </dev/null >/dev/null 2>&1 &
exit 0
