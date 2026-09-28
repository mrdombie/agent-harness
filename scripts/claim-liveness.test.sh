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
. "$(cd "$(dirname "$0")" && pwd)/claim-liveness.sh" || exit 1

FIX=$(mktemp -d); trap 'rm -rf "$FIX"' EXIT
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
  "issue view") echo "st:claimed" ;;
  "pr list")    printf '[]\n' ;;
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
plant_claim() { # <ticket>
  local rec sha empty
  rec=$(jq -nc --arg i "$1" --argjson p "$DEADPID" --arg h "$(hostname -s 2>/dev/null || hostname | cut -d. -f1)" \
    '{issue:$i, agent:"tester@fixture", pid:$p, branch:("tkt-" + $i + "/work"),
      worktree:"", host:$h, claimed_at:"2026-09-27T21:00:00Z"}')
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

exit $FAILED
