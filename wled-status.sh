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
# after this many seconds without any Claude activity the light goes back to
# normal, whatever state it was in (WLED_DONE_TIMEOUT is the old name)
IDLE_TIMEOUT="${WLED_IDLE_TIMEOUT:-${WLED_DONE_TIMEOUT:-900}}"
# what happens then: "restore" = the light you had before Claude started,
# "off" = turn the light off (your own colors/effect are kept for next time)
IDLE_ACTION="${WLED_IDLE_ACTION:-restore}"
DAY_BRI="${WLED_BRIGHTNESS:-255}"             # brightness during the day (0-255)
NIGHT_BRI="${WLED_NIGHT_BRIGHTNESS:-70}"      # brightness at night (0-255)
NIGHT_START="${WLED_NIGHT_START:-23}"         # night mode from this hour...
NIGHT_END="${WLED_NIGHT_END:-7}"              # ...until this hour

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
DIR="${XDG_RUNTIME_DIR:-/tmp}/claude-wled-$(id -u)"
SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"

now_ns() {
  local t; t="$(date +%s%N)"
  case "$t" in *N) t="$(perl -MTime::HiRes=time -e 'printf "%d", time()*1e9')" ;; esac  # macOS
  echo "$t"
}
TS="$(now_ns)"

[ "${WLED_DISABLE:-0}" = 1 ] && exit 0

log() {
  local l="$DIR/events.log"
  echo "$(date '+%F %T') $*" >>"$l"
  if [ "$(wc -l <"$l")" -gt 1000 ]; then tail -n 500 "$l" >"$l.tmp" && mv "$l.tmp" "$l"; fi
}

# Merge all sessions (the most urgent state wins) and send it to WLED if it changed.
# Sessions with no activity for IDLE_TIMEOUT are dropped. Caller holds the lock.
apply_best() {
  local now best=idle bp=0 p s a last sf
  now="$(now_ns)"
  for sf in "$DIR"/s_*; do
    [ -f "$sf" ] || continue
    read -r s a last <"$sf"
    if [ $(( (now - ${last:-0}) / 1000000000 )) -ge "$IDLE_TIMEOUT" ]; then
      rm -f "$sf"; log "timeout ${sf##*/s_} ($s)"; continue
    fi
    [ "${a:-0}" -gt 0 ] && [ "$s" != ask ] && [ "$s" != fail ] && s=agents
    case "$s" in
      ask) p=6 ;; fail) p=5 ;; compact) p=4 ;; agents) p=3 ;;
      work) p=2 ;; done) p=1 ;; *) p=0 ;;
    esac
    [ "$p" -gt "$bp" ] && { bp=$p; best=$s; }
  done

  local prev; prev="$(cat "$DIR/current" 2>/dev/null || echo idle)"
  [ "$prev" = "$best" ] && return

  # remember your own light setting before Claude takes over
  if [ "$prev" = idle ]; then
    curl -s -m 2 "$WLED/json/state" -o "$DIR/saved.json.tmp" \
      && mv "$DIR/saved.json.tmp" "$DIR/saved.json"
  fi

  local body code
  if [ "$best" = idle ]; then
    if [ -f "$DIR/saved.json" ]; then
      body="$(jq -c --arg a "$IDLE_ACTION" \
        '{on:(if $a == "off" then false else .on end),bri,transition:10,
          seg:[.seg[]|{id,start,stop,on,bri,col,fx,sx,ix,pal,c1,c2,c3}]}' \
        "$DIR/saved.json" 2>/dev/null)"
    fi
    [ -n "$body" ] || body='{"on":false}'
  else
    local h bri="$DAY_BRI" c fx sx ix
    h=$(date +%-H)
    if [ "$NIGHT_START" -gt "$NIGHT_END" ]; then
      { [ "$h" -ge "$NIGHT_START" ] || [ "$h" -lt "$NIGHT_END" ]; } && bri="$NIGHT_BRI"
    else
      { [ "$h" -ge "$NIGHT_START" ] && [ "$h" -lt "$NIGHT_END" ]; } && bri="$NIGHT_BRI"
    fi
    read -r c fx sx ix <<<"$(look "$best")"
    body='{"on":true,"bri":'"$bri"',"transition":4,"seg":[{"id":'"$SEG"',"on":true,"bri":255,"fx":'"$fx"',"sx":'"$sx"',"ix":'"$ix"',"pal":0,"col":[['"$c"'],[0,0,0],[0,0,0]]}]}'
  fi
  code="$(curl -s -m 2 -o /dev/null -w '%{http_code}' -X POST \
    -H 'Content-Type: application/json' -d "$body" "$WLED/json/state")"
  if [ "$best" = idle ]; then
    log "light $prev -> idle (http $code) $IDLE_ACTION: $(jq -c '{on,fx:.seg[0].fx,col:.seg[0].col[0]}' <<<"$body" 2>/dev/null)"
  else
    log "light $prev -> $best (http $code)"
  fi
  # on failure mark the light as unknown so the next check retries
  if [ "$code" = 200 ]; then echo "$best" >"$DIR/current"; else echo unknown >"$DIR/current"; fi
}

# One background process per user: re-checks every so often so the light
# times out even when Claude is completely quiet. Exits once everything is idle.
watchdog() {
  exec 8>"$DIR/watchdog.lock"
  flock -n 8 || return
  local interval=$(( IDLE_TIMEOUT / 15 ))
  [ "$interval" -lt 1 ] && interval=1
  [ "$interval" -gt 60 ] && interval=60
  while sleep "$interval"; do
    (
      exec 9>"$DIR/lock"
      flock -w 5 9 || exit 0
      apply_best
    )
    [ "$(cat "$DIR/current" 2>/dev/null)" = idle ] \
      && ! ls "$DIR"/s_* >/dev/null 2>&1 && break
  done
}

run() {
  mkdir -p "$DIR"
  exec 9>"$DIR/lock"
  flock -w 5 9 || exit 0

  case "$EVENT" in
    watchdog) exec 9>&-; watchdog; exit 0 ;;
    expire:*) exit 0 ;;   # from older versions of this script; ignore
  esac

  local sid tool
  sid="$(jq -r '.session_id // "x"' <<<"$INPUT" 2>/dev/null)"
  tool="$(jq -r '.tool_name // ""' <<<"$INPUT" 2>/dev/null)"
  [ -z "$sid" ] && sid=x
  local f="$DIR/s_$sid"

  # per-session state: state subagent_count last_timestamp
  local state=idle agents=0 last=0
  [ -f "$f" ] && read -r state agents last <"$f"

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
    stop)      state=done; agents=0 ;;   # turn is over: no subagents left running
    fail)      state=fail; agents=0 ;;
    sub_start) agents=$((agents + 1)) ;;
    sub_stop)  agents=$((agents > 0 ? agents - 1 : 0)) ;;
    end)       state=gone ;;
    *)         exit 0 ;;
  esac
  if [ "$state" = gone ]; then rm -f "$f"; else echo "$state $agents $last" >"$f"; fi
  case "$EVENT" in pre|post) ;; *) log "${sid:0:8} $EVENT${tool:+ $tool} -> $state (agents $agents)" ;; esac

  apply_best

  # make sure the watchdog is running while anything is lit
  if flock -n "$DIR/watchdog.lock" true 2>/dev/null; then
    "$SELF" watchdog </dev/null >/dev/null 2>&1 9>&- &
  fi
}

( run ) </dev/null >/dev/null 2>&1 &
exit 0
