#!/usr/bin/env bash
# runner-offline.sh <runners.json> — name a CI lane whose every runner has been offline too long.
#
# Reads the forge's runner list (GET /repos/<slug>/actions/runners, as JSON) and the
# lanes the required checks run on (coordinator.runnerLanes, space-separated labels;
# none set = nothing watched). A lane is down when it has runners and none is online.
# Prints one line per change, tab-separated:
#   down <lane> <key> <message>   a lane down for coordinator.runnerOfflineMin (15) or more
#   back <lane>                   a lane that was down has a runner online again
# The first time a lane is seen down is kept in $COORD_DIR/runner-down.<lane>, so the
# key stays the same for one outage and the owner is told once per outage.
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/coordinator-env.sh" || exit 1

JSON="${1:?usage: runner-offline.sh <runners.json>}"
LANES="${COORDINATOR_RUNNER_LANES:-$(swarm_opt coordinator.runnerLanes '')}"
MIN="${COORDINATOR_RUNNER_OFFLINE_MIN:-$(swarm_opt coordinator.runnerOfflineMin 15)}"
NOW="${COORDINATOR_NOW:-$(date -u +%s)}"
[ -n "$LANES" ] || exit 0
jq -e '.runners | type == "array"' "$JSON" >/dev/null 2>&1 || exit 0   # an unread list is not "all offline"

for lane in $LANES; do
  mark="$COORD_DIR/runner-down.$lane"
  read -r total online names < <(jq -r --arg l "$lane" '
    [.runners[] | select([.labels[].name] | index($l))] as $r
    | "\($r | length) \([$r[] | select(.status == "online")] | length) \([$r[].name] | join(","))"' "$JSON")
  if [ "${total:-0}" -eq 0 ]; then continue; fi
  if [ "${online:-0}" -gt 0 ]; then
    [ -f "$mark" ] && { rm -f "$mark"; printf 'back\t%s\n' "$lane"; }
    continue
  fi
  [ -f "$mark" ] || printf '%s\n' "$NOW" > "$mark"
  since=$(cat "$mark")
  mins=$(( (NOW - since) / 60 ))
  [ "$mins" -ge "$MIN" ] || continue
  at=$(date -u -r "$since" +%H:%MZ 2>/dev/null || date -u -d "@$since" +%H:%MZ)
  printf 'down\t%s\t%s\t%s\n' "$lane" "runners-offline:$lane:$since" \
    "Every CI runner on the $lane lane ($names) has been offline since $at ($mins min): checks that need it cannot run. Restart that machine or its runner service."
done
