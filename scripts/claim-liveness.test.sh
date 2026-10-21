#!/usr/bin/env bash
# claim-liveness.test.sh — the second liveness answer, and the one the reconciler
# was missing when it released #10867 out from under a run that was still working it.
#
# The claim carries a pid. That is the right question for an agent session and the
# wrong one for the step-runner: a step is a process, so between two invocations
# there is no process at all and the pid on the claim names one that exited at the
# end of the last step. The driver's run record is what says otherwise.
#
# Run: bash "$0"
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/tests/lib/suite.sh" || exit 1
. "$(cd "$(dirname "$0")" && pwd)/claim-liveness.sh" || exit 1

FIX=$(mktemp -d); on_exit_keep_status 'rm -rf "$FIX"'
FAILED=0
ok()   { printf 'OK       %s\n' "$1"; }
bad()  { printf 'MISMATCH %s\n' "$1"; FAILED=1; }
want() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 — wanted '$2', got '$3'"; fi; }
want_in() {
  if printf '%s' "$3" | grep -qE -- "$2"; then ok "$1"
  else bad "$1 — no /$2/ in: $(printf '%s' "$3" | tr '\n' '|')"; fi
}
want_not_in() {
  if printf '%s' "$3" | grep -qE -- "$2"; then bad "$1 — found /$2/ in: $(printf '%s' "$3" | tr '\n' '|')"
  else ok "$1"; fi
}

record() { # <ticket> <iso-stamp>
  mkdir -p "$FIX/driver/$1"
  jq -n --arg t "$1" --arg at "$2" '{ticket:$t, done:["start"], updated_at:$at}' \
    > "$FIX/driver/$1/state.json"
}
stamp() { # <seconds ago>
  date -u -r "$(( $(date +%s) - $1 ))" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
    || date -u -d "@$(( $(date +%s) - $1 ))" +%Y-%m-%dT%H:%M:%SZ
}
verdict() { claim_run_fresh "$1" "$FIX" "${2:-4}" && echo live || echo gone; }

echo "--- a run that touched its record a minute ago is working ---"
record 10867 "$(stamp 60)"
want "a fresh record is a live run" "live" "$(verdict 10867)"

echo "--- and one that has not been touched in a day is not ---"
record 10868 "$(stamp 90000)"
want "a day-old record is not a live run" "gone" "$(verdict 10868)"

echo "--- the window is the window ---"
record 10869 "$(stamp 18000)"   # 5 hours
want "five hours is outside the default four" "gone" "$(verdict 10869)"
want "and inside a six-hour window"           "live" "$(verdict 10869 6)"

echo "--- every way of not knowing is a 'no', never a 'yes' ---"
# The direction matters. Failing open here calls a dead run live for ever, and the
# ticket is then never reclaimable by anyone.
want "a ticket with no record at all"      "gone" "$(verdict 99999)"
mkdir -p "$FIX/driver/10870"; printf '{}\n' > "$FIX/driver/10870/state.json"
want "a record with no updated_at"         "gone" "$(verdict 10870)"
record 10871 "not-a-date"
want "a stamp neither date dialect reads"  "gone" "$(verdict 10871)"
record 10872 "$(stamp 60)"
want "a window that is not a number"       "gone" "$(verdict 10872 "4h")"
want "and no state dir at all"             "gone" "$(claim_run_fresh 10872 "" 4 && echo live || echo gone)"

echo "--- a stamp with a fractional second is still a stamp ---"
# BSD's `date -j -f` matches the format LITERALLY, so `…:00.176Z` fails it. The copy
# of swarm_epoch that used to live in claim-liveness.sh had no strip and fell through
# to "gone" — which here means release the claim. swarm_epoch handles it, which is
# why this calls swarm_epoch rather than carrying a second copy.
record 10873 "$(stamp 60 | sed 's/Z$/.176Z/')"
want "a fractional second reads as fresh" "live" "$(verdict 10873)"

echo "--- THE RECONCILER ITSELF: a dead pid and a fresh run is not a release ---"
# THIS IS THE ASSERTION THAT HAD TO BE ABLE TO FAIL. The first version of this suite
# grepped reconcile-claims.sh for the call — and a call commented out still satisfies
# a grep for its own text, so the whole thing stayed green about a reconciler that
# releases a live claim on every dead pid. Proved by planting exactly that. So this
# drives the real script, against a real bare remote and a stub gh, and reads the
# claim ref afterwards.
R="$(cd "$(dirname "$0")" && pwd)/reconcile-claims.sh"
SB="$FIX/sb"; mkdir -p "$SB/state" "$SB/bin"
# A git hook exports GIT_DIR / GIT_WORK_TREE to everything it runs; inherited, they
# would make every git call below act on the REAL checkout.
for v in $(env | sed -n 's/^\(GIT_[A-Z_]*\)=.*/\1/p'); do unset "$v"; done
export GIT_AUTHOR_NAME=fixture GIT_AUTHOR_EMAIL=fixture@test.local
export GIT_COMMITTER_NAME=fixture GIT_COMMITTER_EMAIL=fixture@test.local
git init -q --bare -b main "$SB/origin.git"
git clone -q "$SB/origin.git" "$SB/work" 2>/dev/null
mkdir -p "$SB/work/.claude"
cat > "$SB/work/.claude/harness.json" <<JSON
{
  "repo": "acme/widgets",
  "integrationBranch": "main",
  "branchPrefix": "tkt-",
  "stateDir": "$SB/state",
  "sisterRepos": [],
  "labels": {
    "drafting": "st:drafting", "ready": "st:ready", "claimed": "st:claimed",
    "inReview": "st:review", "gated": "st:gated", "partial": "st:partial",
    "blocked": "st:blocked", "parked": "st:parked",
    "externalBlocked": "st:ext-blocked", "needsHuman": "st:needs-human",
    "pmDecision": "st:pm-decision", "pmTrack": "st:pm-track",
    "hold": "hold:human",
    "decision": ["st:pm-track", "st:pm-decision", "hold:human"]
  }
}
JSON
git -C "$SB/work" add -f .claude/harness.json
git -C "$SB/work" commit -qm init >/dev/null
git -C "$SB/work" push -q origin main

# gh, answering enough for the evidence probes: the repo is reachable, the ticket is
# open and ordinary, and there is no pull request anywhere. That is the "nothing at
# all" case — the one that releases to ready, and the one #10867 was wrongly given.
cat > "$SB/bin/gh" <<'SH'
#!/usr/bin/env bash
case "$1 $2" in
  "api repos/acme/widgets") echo acme/widgets ;;
  "issue view") case "$3" in 712) printf 'st:claimed\nst:parked\n' ;; *) echo "st:claimed" ;; esac ;;
  "issue edit") printf '%s\n' "$*" >> "${GH_EDITS:-/dev/null}" ;;
  "pr list")    case "$*" in *"--head 704/work"*) echo '[{"number":9704,"state":"OPEN"}]' ;; *) printf '[]\n' ;; esac ;;
  *) : ;;
esac
exit 0
SH
chmod +x "$SB/bin/gh"

# A pid on THIS host that is certainly dead: one that existed and has exited.
DEADPID=$( (exec sh -c 'echo $$') )
while kill -0 "$DEADPID" 2>/dev/null; do DEADPID=$((DEADPID + 1)); done

# The claim, in the shape claim-lock.sh writes: a parentless commit whose message is
# the record. Planted straight into the sandbox's own bare remote — nothing here can
# reach a live claim, and the reconciler is what gets to decide its fate.
HERE_HOST=$(hostname -s 2>/dev/null || hostname | cut -d. -f1)
plant_claim() { # <ticket> [pid, default a dead one] [host] [extra record fields, json]
  local rec sha empty x="${4:-}"
  [ -n "$x" ] || x='{}'
  rec=$(jq -nc --arg i "$1" --argjson p "${2:-$DEADPID}" --arg h "${3:-$HERE_HOST}" --argjson x "$x" \
    '{issue:$i, agent:"tester@fixture", pid:$p, branch:("tkt-" + $i + "/work"),
      worktree:"", host:$h, claimed_at:"2026-09-27T21:00:00Z"} + $x')
  empty=$(git -C "$SB/work" hash-object -t tree /dev/null)
  sha=$(printf '%s\n' "$rec" | git -C "$SB/work" commit-tree "$empty")
  git -C "$SB/work" update-ref "refs/claims/$1" "$sha"
  git -C "$SB/work" push -q origin "refs/claims/$1"
}
ref_present() {
  git -C "$SB/work" ls-remote origin "refs/claims/$1" 2>/dev/null | grep -q . \
    && echo yes || echo no
}

reconcile() {
  ( cd "$SB/work" && PATH="$SB/bin:$PATH" \
      HARNESS_CFG_PATH="$SB/work/.claude/harness.json" \
      HARNESS_MAIN_REPO="$SB/work" HARNESS_REPO_ROOT="$SB/work" \
      HARNESS_STATE_DIR="$SB/state" HARNESS_LOGIN=tester \
      CLAIM_REPO="$SB/work" CLAIM_REMOTE=origin NOTIFY=0 \
      bash "$R" 2>&1 )
}

# 1. dead pid, FRESH driver record -> left alone.
mkdir -p "$SB/state/driver/701"
jq -n --arg at "$(stamp 120)" '{ticket:"701", done:["start","plan"], updated_at:$at}' \
  > "$SB/state/driver/701/state.json"
plant_claim 701
out=$(reconcile)
want "the claim survives a dead pid when the run record is fresh" "yes" "$(ref_present 701)"
want_in "and it says why" 'run record' "$out"

# 2. dead pid, STALE driver record -> the ordinary evidence path, released.
# The control for case 1: same claim, same dead pid, same absent pull request — only
# the record's age differs, so it is the record that decides and nothing else.
mkdir -p "$SB/state/driver/702"
jq -n --arg at "$(stamp 90000)" '{ticket:"702", done:["start"], updated_at:$at}' \
  > "$SB/state/driver/702/state.json"
plant_claim 702
out=$(reconcile)
want "and a stale record is still released" "no" "$(ref_present 702)"
# AND FOR THE RIGHT REASON. macOS reissues pids from a wrapping counter and the two
# reconcile runs spawn hundreds of processes, so a recycled DEADPID would make
# holder_alive answer 0 — the ref survives, this case goes red, and nothing about it
# would be a fact about the code. This says which branch actually ran.
want_not_in "and not because the dead pid looked alive" 'held by pid' "$out"


# 3. The post-exit reconcile (#35 review). spawn-claim records its wrapper subshell
# as the claim's session, and the reconcile it runs after the agent exits runs INSIDE
# that subshell — so the holder pid is alive at exactly the moment it is being judged
# dead. The wrapper passes CLAIM_EXITED_PID, and that pid counts as gone.
sleep 300 & LIVEPID=$!
plant_claim 703 "$LIVEPID"
out=$(reconcile)
want "a live holder pid keeps its claim (the control)" "yes" "$(ref_present 703)"
want_in "because it is live" 'held by pid' "$out"
out=$(CLAIM_EXITED_PID="$LIVEPID" reconcile)
want "the same pid, named as the exited session, is released" "no" "$(ref_present 703)"
kill "$LIVEPID" 2>/dev/null

# 4. A run that named its branch by the bare number. Its work is on <n>/…, not on the
# configured prefix, and its pull request is open: that is in-review, never released.
git -C "$SB/work" push -q origin "main:refs/heads/704/work"
plant_claim 704
out=$(reconcile)
want_in "a bare-number branch with an open PR reads as in review" 'IN-REVIEW +#704' "$out"
want_not_in "and is not called abandoned" 'left no branch and no PR' "$out"

# 5. A DRIVER run that crashed: its record is fresh BECAUSE it was writing until it
# died, and the wrapper names its session as exited. The freshness rescue exists for
# a step-runner between steps, where no process is the run; here the process that
# WAS the run is named as gone, so the record's age must not overrule it.
# (705, not 704: case 4 leaves a 704/work branch with an open PR behind it.)
sleep 300 & LIVEPID=$!
mkdir -p "$SB/state/driver/705"
jq -n --arg at "$(stamp 60)" '{ticket:"705", done:["start","plan"], updated_at:$at}' \
  > "$SB/state/driver/705/state.json"
plant_claim 705 "$LIVEPID"
out=$(CLAIM_EXITED_PID="$LIVEPID" reconcile)
want "a crashed driver run's claim is released by its own post-exit reconcile" "no" "$(ref_present 705)"
want_not_in "the fresh record did not rescue it" '#705 .*run record was written' "$out"
kill "$LIVEPID" 2>/dev/null

# A run record in the shape spawn-claim.sh writes; <ended> yes writes its .ended too.
run_record() { # <ticket> <run_id> <pid> <child_pid> <started_at> <ended yes|no>
  mkdir -p "$SB/state/runs"
  rm -f "$SB/state/runs/$2.ended"
  jq -n --arg r "$2" --arg t "$1" --argjson p "$3" --argjson c "$4" --arg at "$5" \
    '{run_id:$r, pid:$p, child_pid:$c, ticket:$t, builder:"driver", started_at:$at}' > "$SB/state/runs/$2.json"
  [ "$6" = yes ] && printf '{"run_id":"%s","exit_code":1,"ended_at":"2026-09-28T00:20:00Z"}\n' "$2" \
    > "$SB/state/runs/$2.ended"
  return 0
}
driver_record() { # <ticket> <seconds ago>
  mkdir -p "$SB/state/driver/$1"
  jq -n --arg t "$1" --arg at "$(stamp "$2")" '{ticket:$t, step:"build", done:["start","plan"], updated_at:$at}' \
    > "$SB/state/driver/$1/state.json"
}

echo "--- a run that is over releases its claim; a run between steps keeps it ---"
# 6. Killed in a stop-all, or ended by a park: the pid is dead, the run wrote .ended,
# and its driver record is still inside the freshness window. The run is over; the
# record's age must not hold the claim.
driver_record 706 60
run_record 706 claim-706-run "$DEADPID" "$DEADPID" "$(stamp 600)" yes
plant_claim 706 "$DEADPID" "" '{"run_id":"claim-706-run"}'
out=$(reconcile)
want "a dead pid with an ended run is released, fresh record or not" "no" "$(ref_present 706)"
want_not_in "the fresh record did not rescue it" '#706 .*run record was written' "$out"

# 7. A spawned driver run between steps: the claim's pid is gone, the run's
# build-ticket (child_pid) is alive and has not ended, and its driver record is
# stale, so only the run record can keep it.
sleep 300 & WALKER=$!
driver_record 707 90000
run_record 707 claim-707-run "$DEADPID" "$WALKER" "$(stamp 5)" no
plant_claim 707 "$DEADPID" "" '{"run_id":"claim-707-run"}'
out=$(reconcile)
want "a dead pid with a live run between steps keeps its claim" "yes" "$(ref_present 707)"
want_in "because its run is still going" 'LIVE +#707 .*run is still going' "$out"
# The same pid on a run that started an hour before the process did is a reused
# pid, not the run.
run_record 707 claim-707-run "$DEADPID" "$WALKER" "$(stamp 3600)" no
out=$(reconcile)
want "a reused pid is not the run" "no" "$(ref_present 707)"
kill "$WALKER" 2>/dev/null

# 8. A step driver run by hand: no run record, the claim's pid is gone between two
# steps, and build-ticket <n> is alive on this host.
mkdir -p "$SB/kit/driver"; printf '#!/usr/bin/env bash\nsleep 300\n' > "$SB/kit/driver/build-ticket"
bash "$SB/kit/driver/build-ticket" 708 & WALKER=$!
driver_record 708 90000
plant_claim 708
out=$(reconcile)
want "a hand-run driver walking the ticket keeps its claim" "yes" "$(ref_present 708)"
want_in "because a driver is walking it" 'LIVE +#708 .*step driver is walking' "$out"
kill "$WALKER" 2>/dev/null; wait "$WALKER" 2>/dev/null
out=$(reconcile)
want "and once the driver stops, the claim is released" "no" "$(ref_present 708)"

# 9. Another machine's claim is never judged from here, dead pid and ended run or not.
run_record 709 claim-709-run "$DEADPID" "$DEADPID" "$(stamp 600)" yes
plant_claim 709 "$DEADPID" "some-other-mac" '{"run_id":"claim-709-run"}'
out=$(reconcile)
want "a claim held on another host is kept" "yes" "$(ref_present 709)"
want_in "and reported as elsewhere" 'ELSEWHERE +#709' "$out"

# 10. The project's pre-push hook refuses every push. A claim ref carries no code, so
# its delete must not go through the gates; and a delete that failed must never be
# reported RELEASED while the ref stays.
mkdir -p "$SB/hooks"; printf '#!/bin/sh\necho "pre-push blocked" >&2\nexit 1\n' > "$SB/hooks/pre-push"
chmod +x "$SB/hooks/pre-push"
plant_claim 710
want "the claim is planted before the hook is (the control)" "yes" "$(ref_present 710)"
git -C "$SB/work" config core.hooksPath "$SB/hooks"
out=$(reconcile)
want "a refusing pre-push hook does not keep a dead claim" "no" "$(ref_present 710)"
git -C "$SB/work" config --unset core.hooksPath

# 11. A parked ticket's dead claim is released, but the ticket stays off the board.
export GH_EDITS="$SB/edits.log"; : > "$GH_EDITS"
plant_claim 712
out=$(reconcile)
want "a parked ticket's dead claim is released" "no" "$(ref_present 712)"
want_not_in "and it is not put back on the board" '712 .*--add-label st:ready' "$(cat "$GH_EDITS")"
want_in "but it loses status:claimed" '712 .*--remove-label st:claimed' "$(cat "$GH_EDITS")"

suite_end "$FAILED"
