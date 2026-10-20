#!/usr/bin/env bash
# hold-status.sh — is anything holding new spawns, why, and until when, as JSON.
#
#   hold-status.sh   {"held":false} or {"held":true,"kind":…,"reason":…,"until":…}
#
# allows is "process" on a pause that still lets process fixes start.
# kind is "paused" (the owner's hold, swarm/install.sh hold) or "usage" (the
# plan's usage limit). until is an ISO instant when the source names one, the
# reset wording ("7:20pm") when it names only a time, null for a pause.
#
# The live view asks this rather than reading the hold files itself: the same
# functions the coordinator and the scheduler decide with answer here, so the
# page cannot show a hold they do not apply, or miss one they do.
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/swarm-env.sh" >/dev/null 2>&1 || { echo '{"held":false,"unknown":true}'; exit 0; }

window_name() { # <rateLimitType> — plain words for the limit's window
  case "$1" in
    seven_day*) printf 'weekly' ;;
    five_hour*) printf 'session' ;;
    *) printf '' ;;
  esac
}
usage() { # <until> [window]
  jq -cn --arg u "$1" --arg w "${2:-}" \
    '{held: true, kind: "usage", until: $u,
      reason: ("the plan'"'"'s " + (if $w == "" then "" else $w + " " end) + "usage limit was reached")}'
}

if h=$(swarm_held); then
  a=""; swarm_hold_lets_process && a=process
  jq -cn --arg r "$h" --arg a "$a" '{held: true, kind: "paused", reason: $r, until: null} + (if $a == "" then {} else {allows: $a} end)'
elif swarm_usage_file_hold >/dev/null; then
  e=$(cut -f1 "${SWARM_USAGE_HOLD_FILE:-$STATE_DIR/usage-hold}" | head -1)
  usage "$(swarm_iso "$e")"
elif u=$(swarm_usage_event_hold); then
  # "2026-10-20T19:00:00Z (seven_day window)"
  w=$(printf '%s' "$u" | sed -nE 's/.*\(([a-z_]+) window\).*/\1/p')
  usage "${u%% *}" "$(window_name "$w")"
elif u=$(swarm_usage_near_hold); then
  # "2026-10-20T19:00:00Z (seven_day window at 99%)"
  w=$(printf '%s' "$u" | sed -nE 's/.*\(([a-z_]+) window at.*/\1/p')
  jq -cn --arg u "${u%% *}" --arg w "$(window_name "$w")" --arg pct "$(printf '%s' "$u" | sed -nE 's/.* at ([0-9]+)%.*/\1/p')" \
    '{held: true, kind: "usage", until: $u,
      reason: ("the plan'"'"'s " + (if $w == "" then "" else $w + " " end) + "usage is at " + $pct + "%, too near the limit to start a run")}'
elif u=$(swarm_usage_text_hold); then
  usage "$u"
else
  echo '{"held":false}'
fi
