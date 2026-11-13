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
ORG_RUNNERS="$FIX/gh/api-orgs_acme_actions_runners_per_page_100.json"
T0=1762160000

# runners <file> <status[:label,label…]…> — that list of runners, ids 1…n; labels default to self-hosted.
runners() {
  local f="$1" i=0 s rows="[]"; shift
  for s in "$@"; do i=$((i + 1)); rows=$(jq -c --argjson i "$i" --arg s "$s" '
    ($s | split(":")) as $p
    | . + [{id: $i, name: "r\($i)", status: $p[0], labels: (($p[1] // "self-hosted") | split(",") | map({name: .}))}]' <<<"$rows"); done
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

echo "--- the org's runners count: none on the repo, every one on the org offline ---"
runners "$REPO_RUNNERS"; runners "$ORG_RUNNERS" offline offline
state
want "repo none, org all offline: offline"       "offline" "$ST"
runners "$ORG_RUNNERS" offline online
state
want "  one org runner online: online"           "online" "$ST"
runners "$REPO_RUNNERS" offline; runners "$ORG_RUNNERS" online
state
want "  the repo's offline, the org's online: online" "online" "$ST"
echo "  the org list refused (a user's repo, a token without org scope): the repo's alone decide"
runners "$REPO_RUNNERS" online; rm -f "$ORG_RUNNERS"; echo 404 > "$FIX/gh/refuse-orgs_acme_actions_runners_per_page_100"
state
want "  repo online, org refused: online"        "online" "$ST"
runners "$REPO_RUNNERS"
state
want "  repo none, org refused: none"            "none" "$ST"
rm -f "$REPO_RUNNERS" "$FIX/gh/refuse-orgs_acme_actions_runners_per_page_100"

echo "--- a runner offline past coordinator.ciRunnerStaleMin (720) is left over, not down: not counted ---"
rm -f "$ORG_RUNNERS"
runners "$REPO_RUNNERS" offline
fix_at "$T0"; state
want "one runner, first seen offline: offline"   "offline" "$ST"
fix_at $(( T0 + 719 * 60 )); state
want "  offline 719 min: offline"                "offline" "$ST"
fix_at $(( T0 + 720 * 60 )); state
want "  offline 720 min: left over, none"        "none" "$ST"
echo "  a left-over runner beside one that just went down: offline"
runners "$REPO_RUNNERS" offline offline
state
want "  the new one first seen offline: offline" "offline" "$ST"
echo "  a left-over runner that comes back online counts again from scratch"
runners "$REPO_RUNNERS" online
state
want "  back online: online"                     "online" "$ST"
runners "$REPO_RUNNERS" offline
fix_at $(( T0 + 721 * 60 )); state
want "  offline again: its clock starts again, offline" "offline" "$ST"
echo "  the cutoff is read from coordinator.ciRunnerStaleMin"
fix_at $(( T0 + 782 * 60 )); COORDINATOR_CI_RUNNER_STALE_MIN=60 state
want "  60: offline 61 min is none"              "none" "$ST"
rm -f "$REPO_RUNNERS"

echo "--- only a runner whose labels cover a self-hosted job's runs-on counts ---"
mkdir -p "$REPO/.github/workflows"
printf 'jobs:\n  test:\n    runs-on: [self-hosted, ci]\n' > "$REPO/.github/workflows/ci.yml"
printf 'jobs:\n  build:\n    runs-on: ubuntu-24.04\n' > "$REPO/.github/workflows/hosted.yml"
runners "$REPO_RUNNERS" offline:self-hosted,ci; runners "$ORG_RUNNERS" online:self-hosted,deploy
state
want "repo's CI runner offline, org's deploy box online: offline" "offline" "$ST"
runners "$ORG_RUNNERS" online:self-hosted,deploy online:Self-Hosted,Linux,CI
state
want "  an org runner labelled self-hosted, linux, ci online: online" "online" "$ST"
runners "$REPO_RUNNERS"; runners "$ORG_RUNNERS" online:self-hosted,deploy
state
want "  only the deploy box, online: none of them runs a check, none" "none" "$ST"
echo "  a block-list runs-on is read the same"
printf 'jobs:\n  test:\n    runs-on:\n      - self-hosted\n      - "ci"\n' > "$REPO/.github/workflows/ci.yml"
runners "$REPO_RUNNERS" offline:self-hosted,ci
state
want "  block list, CI runner offline, deploy box online: offline" "offline" "$ST"
echo "  coordinator.ciRunnerLabels names the labels when the workflows cannot say"
rm -f "$REPO/.github/workflows/ci.yml"
COORDINATOR_CI_RUNNER_LABELS="self-hosted,ci" state
want "  labels set, CI runner offline, deploy box online: offline" "offline" "$ST"
echo "  no self-hosted job and no labels set: any runner counts"
state
want "  hosted jobs only, deploy box online: online" "online" "$ST"
rm -rf "$REPO/.github" "$REPO_RUNNERS" "$ORG_RUNNERS"

suite_end "$FAILED"
