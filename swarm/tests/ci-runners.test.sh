#!/usr/bin/env bash
# ci-runners.test.sh — ci_runners_state (scripts/ci-runners.sh): is there a self-hosted
# runner to run a check, read the way the rebuild pass reads it once a tick.
# Run: bash "$0"
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/tests/lib/suite.sh" || exit 1
for v in $(env | sed -n 's/^\(GIT_[A-Z_]*\)=.*/\1/p'); do unset "$v"; done
# A driver run exports the host's state paths; left set, they win over the fixture's.
unset DRIVER_DIR RUNS_DIR STATE_DIR SWARM_DIR SWARM_LOGS COORD_DIR COORD_LOG COORD_QUEUE COORD_EVENTS COORD_ACTIONS COORD_NEEDS_YOU
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/fixture.sh"
swarm_fixture; on_exit_keep_status 'rm -rf "$FIX"'
KIT="$(cd "$HERE/../.." && pwd)"
REPO_RUNNERS="$FIX/gh/api-repos_acme_widgets_actions_runners_per_page_100.json"
T0=1762160000

# runners <file> <status…> — that list of runners, ids 1…n.
runners() {
  local f="$1" i=0 s rows="[]"; shift
  for s in "$@"; do i=$((i + 1)); rows=$(jq -c --argjson i "$i" --arg s "$s" '. + [{id: $i, name: "r\($i)", status: $s}]' <<<"$rows"); done
  jq -n --argjson r "$rows" '{total_count: ($r | length), runners: $r}' > "$f"
}
# state [shell before the read] — what ci_runners_state answers in a fresh coordinator process.
state() {
  OUT=$(cd "$REPO" && bash -c '. "$1/scripts/coordinator-env.sh" || exit 1; eval "$2"; ci_runners_state' _ "$KIT" "${1:-:}" 2>&1)
  ST=$(printf '%s\n' "$OUT" | tail -1)
}

echo "--- another coordinator process starting mid-tick does not turn a read into unread ---"
runners "$REPO_RUNNERS" online
# What another process's sourcing leaves for an instant: its rm -rf of a shared per-tick dir.
state 'rm -rf "$COORD_DIR"/ci-runners.*'
want "one runner online, the shared dir gone: online" "online" "$ST"
want_not_in "  and no failed read is logged"             'could not be read' "$OUT"

echo "--- a token GitHub refuses the runner list (403, 404): no self-hosted runners, said once ---"
REFUSE="$FIX/gh/refuse-repos_acme_widgets_actions_runners_per_page_100"
rm -f "$REPO_RUNNERS"; echo 403 > "$REFUSE"
state
want "refused with 403: none"                    "none" "$ST"
want_in "  it says the token may not read it"    'runner list of acme/widgets is refused \(HTTP 403\)' "$OUT"
state
want "  read again: none"                        "none" "$ST"
want_not_in "  and not said a second time"       'refused' "$OUT"
echo 404 > "$REFUSE"
state
want "refused with 404: none"                    "none" "$ST"
echo "  any other failure is still unread"
rm -f "$REFUSE"; : > "$FIX/gh/runners-unread"
state
want "  a failed read: unread"                   "unread" "$ST"
rm -f "$FIX/gh/runners-unread"

suite_end "$FAILED"
