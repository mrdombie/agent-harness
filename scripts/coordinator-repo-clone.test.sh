#!/usr/bin/env bash
# coordinator-repo-clone.test.sh — a place kept for a class of work is dead if the start
# path refuses that class. The tooling cap kept 2 places for harness fixes, and every
# harness ticket wears repo:<the harness repo>, which the start path refused as another
# repo's work: "0 live of the cap of 2" on every tick while 6 P0 harness fixes sat ready.
#   - a repo:<name> ticket starts when this host has a clone of <name> beside the project's
#     own (or named in HARNESS_REPO_CLONES) whose trunk carries .claude/harness.json, and its
#     run is spawned in that clone, reading that clone's config
#   - a repo:<name> with no such clone is still refused, as before
# Run: bash "$0"
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/tests/lib/suite.sh" || exit 1
for v in $(env | sed -n 's/^\(GIT_[A-Z_]*\)=.*/\1/p'); do unset "$v"; done
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../swarm/tests/fixture.sh"
swarm_fixture; on_exit_keep_status 'rm -rf "$FIX"'
T="$HERE/coordinator-tick.sh"
Q="$HERE/coordinator-queue.sh"
unset COORDINATOR_PACE COORDINATOR_PACE_FACTOR COORDINATOR_TOOLING_CAP SWARM_USAGE_CEILING HARNESS_REPO_CLONES

# clone <dir> <origin-name> [with-config] — a clone of acme/<origin-name> at <dir>
clone() {
  local blob
  git init -q -b main "$1"
  # Only the trunk's config counts, so it goes straight into the commit's tree.
  if [ "${3:-}" = with-config ]; then
    blob=$(printf '{"repo":"acme/%s","integrationBranch":"main"}\n' "$2" | git -C "$1" hash-object -w --stdin)
    git -C "$1" update-index --add --cacheinfo "100644,$blob,.claude/harness.json"
  else
    blob=$(printf 'x\n' | git -C "$1" hash-object -w --stdin)
    git -C "$1" update-index --add --cacheinfo "100644,$blob,README"
  fi
  git -C "$1" -c user.email=t@example.invalid -c user.name=t commit -qm root
  git -C "$1" remote add origin "https://github.com/acme/$2.git"
  git -C "$1" update-ref refs/remotes/origin/main HEAD
}
clone "$FIX/agent-harness" agent-harness with-config   # beside $FIX/repo, the project's own
clone "$FIX/plain" plain                                # a clone with no harness config
clone "$FIX/elsewhere/tools" tools with-config          # not beside it: only an env names it

echo "--- the tick: a harness ticket fills a tooling place, in the harness clone ---"
printf '#!/usr/bin/env bash\n:\n' > "$BIN/judge"; chmod +x "$BIN/judge"
for s in reconcile sweep wtsweep; do printf '#!/usr/bin/env bash\n:\n' > "$BIN/$s"; chmod +x "$BIN/$s"; done
export COORDINATOR_RECONCILE="$BIN/reconcile" COORDINATOR_SWEEP="$BIN/sweep" COORDINATOR_WORKTREE_SWEEP="$BIN/wtsweep"
export COORDINATOR_JUDGE="$BIN/judge" COORDINATOR_NOTIFY_CMD=true COORDINATOR_HOST=here
export COORDINATOR_REFRESH=0 COORDINATOR_FREE_GB=500 COORDINATOR_CLAIMS_CMD="cat $FIX/claims.txt"
export COORDINATOR_HOUSEKEEPING=inline COORDINATOR_HOUSEKEEPING_EVERY_MIN=0
unset COORDINATOR_SHADOW COORDINATOR_CAP SWARM_NOW
export SWARM_FREE_MEM_GB=16 SWARM_IDLE=90 SWARM_CORES=10
# Records the ticket, the clone it was spawned for, the config it was pointed at, and where it ran.
cat > "$BIN/spawn-live" <<'SH'
#!/usr/bin/env bash
printf '%s %s %s %s %s\n' "$1" "${HARNESS_MAIN_REPO:-}" "${HARNESS_CFG_PATH:-none}" "$(pwd -P)" "${CLAIM_REPO:-}" >> "$SPAWNS"
SH
chmod +x "$BIN/spawn-live"
world() { rm -f "$STATE/coordinator/queue.json"; rm -rf "$STATE/runs"/*; : > "$SPAWNS"; : > "$FIX/claims.txt"; printf '[]\n' > "$FIX/gh/prs-all.json"; }
ready() { local l="$1" t; shift; for t in "$@"; do fix_issue "$t" OPEN "$l"; bash "$Q" add "$t" >/dev/null; done; }
live() { SWARM_SPAWN="$BIN/spawn-live" COORDINATOR_SHADOW=0 bash "$T" 2>&1; }
order() { cut -d' ' -f1 "$SPAWNS" | tr '\n' ' ' | sed 's/ $//'; }
row() { awk -v t="$1" '$1 == t' "$SPAWNS"; }
REPO_P=$(cd "$REPO" && pwd -P); AH_P=$(cd "$FIX/agent-harness" && pwd -P)

world; ready "P0,repo:agent-harness,status:ready" 801; ready "P1,status:ready" 701
out=$(COORDINATOR_CAP=2 live)
want "a P0 harness ticket and a P1 product ticket, both places free: the harness one starts first" "801 701" "$(order)"
want "the harness run is spawned for the harness clone, not the project's own" "$FIX/agent-harness" "$(row 801 | cut -d' ' -f2)"
want "and reads that clone's config, not the project's" "none" "$(row 801 | cut -d' ' -f3)"
want "and starts inside that clone" "$AH_P" "$(row 801 | cut -d' ' -f4)"
want "its claim stays in the project's repo, where every host's coordinator counts it" "$REPO" "$(row 801 | cut -d' ' -f5)"
want "the product run still starts in the project's own repo" "$REPO" "$(row 701 | cut -d' ' -f2)"
want_not_in "the harness ticket is not refused as another repo's" 'belongs to agent-harness' "$out"
want_in "it counts toward the tooling cap" 'tooling: 0 live of the cap of 2' "$out"

world; ready "P0,repo:nowhere,status:ready" 802; ready "P0,repo:plain,status:ready" 803; ready "P1,status:ready" 701
out=$(COORDINATOR_CAP=3 live)
want "a repo with no clone here, or a clone with no harness config, is still refused" "701" "$(order)"
want_in "named as another repo's" 'skip #802 \(new\): belongs to nowhere' "$out"
want_in "the config-less clone too" 'skip #803 \(new\): belongs to plain' "$out"

world; ready "P0,repo:tools,status:ready" 804
out=$(COORDINATOR_CAP=2 live)
want "a clone that is not beside the project is refused unless named" "" "$(order)"
world; ready "P0,repo:tools,status:ready" 804
out=$(COORDINATOR_CAP=2 HARNESS_REPO_CLONES="tools=$FIX/elsewhere/tools" live)
want "HARNESS_REPO_CLONES names it: it starts there" "804 $FIX/elsewhere/tools" "$(row 804 | cut -d' ' -f1-2)"

echo "--- the size read: a harness ticket is no longer 'never built here' ---"
. "$HERE/toolkit-env.sh" >/dev/null 2>&1
. "$HERE/../driver/size-rules.sh"
rc=0; driver_repo_foreign 'P0,repo:agent-harness' >/dev/null || rc=$?
want "repo:agent-harness with a clone beside it is this project's to build" 1 "$rc"
want "and its clone is that one" "$FIX/agent-harness" "$(driver_repo_clone_for 'P0,repo:agent-harness')"
rc=0; driver_repo_clone_for 'P1,status:ready' >/dev/null || rc=$?
want "a ticket with no repo label has no other clone" 1 "$rc"
want "repo:nowhere still belongs to nowhere" nowhere "$(driver_repo_foreign 'P0,repo:nowhere')"

echo "--- in the clone: tickets are read in the queue's repo, pull requests stay its own ---"
cat > "$BIN/gh-args" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FIX/gh-args.log"
SH
chmod +x "$BIN/gh-args"
gh_in_clone() { # <gh args…> — as a run in the clone calls it: its repo acme/kit, its tickets acme/widgets
  : > "$FIX/gh-args.log"
  ( . "$HERE/gh-batch.sh"; REPO_SLUG=acme/kit ISSUE_REF=acme/widgets SWARM_GH="$BIN/gh-args" GH_BACKOFF_FILE="$FIX/no-backoff" gh_call "$@" )
  grep -v '^api rate_limit$' "$FIX/gh-args.log"   # the free allowance reading is not the call under test
}
want "an issue read aimed at the clone's repo goes to the queue's" "issue view 17 --repo acme/widgets --json labels" "$(gh_in_clone issue view 17 --repo acme/kit --json labels)"
want "so does -R" "issue close 17 -R acme/widgets" "$(gh_in_clone issue close 17 -R acme/kit)"
want "an issue call naming no repo is sent to the queue's" "issue edit 17 --add-label a --repo acme/widgets" "$(gh_in_clone issue edit 17 --add-label a)"
want "an issue call naming a third repo is left alone" "issue view 3 --repo acme/other" "$(gh_in_clone issue view 3 --repo acme/other)"
want "a pull request stays in the clone's repo" "pr view 9 --repo acme/kit --json body" "$(gh_in_clone pr view 9 --repo acme/kit --json body)"
: > "$FIX/gh-args.log"
( . "$HERE/gh-batch.sh"; REPO_SLUG=acme/widgets ISSUE_REF="" SWARM_GH="$BIN/gh-args" GH_BACKOFF_FILE="$FIX/no-backoff" gh_call issue view 17 --repo acme/widgets )
want "one repo for both: nothing is rerouted" "issue view 17 --repo acme/widgets" "$(cat "$FIX/gh-args.log")"
. "$HERE/pr-closes.sh"
want "its PR closes the ticket in the queue's repo" "Closes acme/widgets#17" "$(printf '' | ISSUE_REF=acme/widgets pr_closes_ensure 17 Closes)"
rc=0; printf 'body\n\nCloses acme/widgets#17\n' | pr_closes_names 17 || rc=$?
want "and a body naming it that way names the ticket" 0 "$rc"
want "one repo for both: the plain form" "Closes #17" "$(printf '' | ISSUE_REF="" pr_closes_ensure 17 Closes)"

suite_end "$FAILED"
