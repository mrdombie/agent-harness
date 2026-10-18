#!/usr/bin/env bash
# start.test.sh — start is the step that refuses. Everything it does is cheap and
# reversible; everything it protects is neither. So the assertions here are
# mostly about saying no: to a closed ticket, to one a person holds, to one the
# PM has gated, and to one a peer already claimed.
# Run: bash "$0"
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/fixture.sh"
driver_fixture; trap 'rm -rf "$FIX"' EXIT
. "$HERE/../steps/start.sh" || exit 1

# The claim seam: a recorder, so the suite never writes a ref to a real origin.
#
# IT CARRIES THE REAL EXIT CODES AND THE REAL IDENTITY, and both halves matter.
# `holds` in claim-lock.sh answers through `owns_claim`, and the identity it compares
# is `CLAIM_AGENT`, which spawn-claim.sh sets to `<login>@<host>` — IDENTICAL for
# every agent on the machine. So rc 0 means "somebody on this box holds it", never
# "this run holds it", and a stub whose owner is per-run would hide that. Rows are
# <ticket> <owner> <branch> <worktree>.
CLAIMS="$FIX/claims"; : > "$CLAIMS"
cat > "$BIN/claim-lock" <<'SH'
#!/usr/bin/env bash
me="${CLAIM_AGENT:-tester@fixture}"
field() { awk -v t="$1" -v n="$2" '$1==t{print $n; exit}' "$CLAIMS"; }
t="$2"
argval() { local k="$1"; shift; while [ $# -gt 0 ]; do [ "$1" = "$k" ] && { printf '%s' "$2"; return; }; shift; done; }
case "$1" in
  acquire)
    [ -n "$(field "$t" 2)" ] && exit 10
    printf '%s\t%s\t%s\t%s\n' "$t" "$me" "$(argval --branch "$@")" "$(argval --worktree "$@")" >> "$CLAIMS"
    echo "acquired #$t" ;;
  holds) o=$(field "$t" 2); [ -n "$o" ] || exit 11; [ "$o" = "$me" ] || exit 12 ;;
  show)
    o=$(field "$t" 2); [ -n "$o" ] || { echo "#$t is not claimed" >&2; exit 11; }
    jq -n --arg a "$o" --arg b "$(field "$t" 3)" --arg w "$(field "$t" 4)" \
      '{agent:$a, branch:$b, worktree:$w}' ;;
  release) awk -v t="$t" '$1!=t' "$CLAIMS" > "$CLAIMS.t"; mv "$CLAIMS.t" "$CLAIMS" ;;
  update)
    printf '%s\n' "$*" >> "$FIX/cl-updates.log"
    # `key=value`, which is the form claim-lock.sh actually takes and the form start.sh
    # actually sends. Parsed as `--branch X` the stub could never rewrite a row — so the
    # two assertions that exist to prove a peer's claim was NOT rewritten were true of
    # any code at all, including code that rewrote it.
    b=""; w=""
    for a in "$@"; do
      case "$a" in branch=*) b="${a#branch=}" ;; worktree=*) w="${a#worktree=}" ;; esac
    done
    awk -F'\t' -v OFS='\t' -v t="$t" -v b="$b" -v w="$w" \
      '$1==t{ if (b!="") $3=b; if (w!="") $4=w } {print}' "$CLAIMS" > "$CLAIMS.t"; mv "$CLAIMS.t" "$CLAIMS" ;;
esac
SH
chmod +x "$BIN/claim-lock"; export CL="$BIN/claim-lock" CLAIMS
claimed_tickets() { awk '{print $1}' "$CLAIMS" | tr '\n' ' ' | sed 's/ $//'; }
# claim_row <ticket> <owner> <branch> <worktree>
claim_row() { printf '%s\t%s\t%s\t%s\n' "$1" "$2" "${3:-}" "${4:-}" >> "$CLAIMS"; }

echo "--- a ready ticket starts ---"
fix_issue 101 OPEN "status:ready,type:feature"
mkdir -p "$(driver_state_dir 101)/steps"
printf '%s\n' '{"file":"stale.test.sh","removedBecause":"a run on another branch"}' > "$(driver_state_dir 101)/steps/replaced.jsonl"
out=$(driver_step_start 101 2>&1); rc=$?
want "a fresh branch starts with an empty reworded-tests ledger (#11222)" "" "$(cat "$(driver_state_dir 101)/steps/replaced.jsonl")"
want "it finishes"            "0" "$rc"
want "the claim was taken"    "101" "$(claimed_tickets)"
WT=$(driver_state_get 101 worktree)
want "a worktree exists"      "1" "$([ -d "$WT" ] && echo 1)"
want "on its own branch"      "tkt-101/ticket-101" "$(git -C "$WT" rev-parse --abbrev-ref HEAD)"
want "cut from the trunk"     "$(git -C "$REPO" rev-parse develop)" "$(git -C "$WT" rev-parse HEAD)"
want "the branch is recorded" "tkt-101/ticket-101" "$(driver_state_get 101 branch)"
want_in "and it says what it did" 'worktree' "$out"

echo "--- the trunk SHA the ticket was claimed at is frozen ---"
want "claimed_at is recorded" "$(git -C "$REPO" rev-parse develop)" "$(driver_state_get 101 claimed_at_sha)"

echo "--- a second start on the same ticket does not cut a second worktree ---"
before="$WT"
printf '%s\n' '{"file":"kept.test.sh","coveredBy":"kept.test.sh"}' > "$(driver_state_dir 101)/steps/replaced.jsonl"
rc=0; driver_step_start 101 >/dev/null 2>&1 || rc=$?
want "it still finishes"      "0"        "$rc"
want "same worktree"          "$before"  "$(driver_state_get 101 worktree)"
want_in "and a resume keeps the ledger its commits still need" 'kept.test.sh' "$(cat "$(driver_state_dir 101)/steps/replaced.jsonl")"

echo "--- a closed ticket ---"
fix_issue 102 CLOSED "status:ready"
out=$(driver_step_start 102 2>&1); rc=$?
want "closed refuses"   "24" "$rc"
want_in "and says so"   'CLOSED' "$out"

echo "--- a ticket a person is holding ---"
fix_issue 103 OPEN "status:ready,needs:human-approval"
out=$(driver_step_start 103 2>&1); rc=$?
want "a held ticket refuses" "24" "$rc"
want_in "naming the label"   'needs:human-approval' "$out"

echo "--- a ticket parked on a question the PM owes ---"
# A pm-classified question parks with the PM label and no hold. A resume that read
# only the hold would rebuild the ticket before the PM had answered.
fix_issue 133 OPEN "status:parked,status:pm-decision"
out=$(driver_step_start 133 2>&1); rc=$?
want "a ticket waiting on the PM refuses" "24" "$rc"
want_in "naming the PM's label"           'status:pm-decision' "$out"

echo "--- a gated ticket: the PM flips that, not the driver ---"
fix_issue 104 OPEN "status:gated"
out=$(driver_step_start 104 2>&1); rc=$?
want "gated refuses"  "24" "$rc"
want_in "and says whose call it is" 'PM' "$out"

echo "--- a ticket that is not ready ---"
fix_issue 105 OPEN "status:drafting"
out=$(driver_step_start 105 2>&1); rc=$?
want "drafting refuses" "24" "$rc"
want_in "naming the status it wanted" 'status:ready' "$out"

echo "--- a peer already holds the claim ---"
fix_issue 106 OPEN "status:ready"
claim_row 106 somebody@else tkt-106/theirs "$FIX/theirs"
out=$(driver_step_start 106 2>&1); rc=$?
want "a peer's claim is never adopted" "24" "$rc"
want_in "and it says a peer holds it"  'peer' "$out"
want "no worktree was cut"             ""     "$(driver_state_get 106 worktree)"
# There are TWO ways a peer's claim shows up, and they get different wording because
# they mean different things at three in the morning: the cache already knows (rc 12),
# and the cache said free while a peer won the compare-and-swap. Without this line the
# rc-12 arm is never entered — rc 12 falls to the default, `acquire` loses, and that
# message also contains "peer", so the arm could be deleted with the suite green.
want_in "the cache knowing says so, not 'took it first'" 'holds the claim' "$out"

echo "--- OUR OWN claim, taken but not yet recorded, is not a peer's ---"
# The window is real: a run killed between `acquire` and recording the worktree
# spans a fetch and a worktree add. Read as a peer's claim, that state parks the
# ticket, the park adds the hold label and releases the claim, and a person now has
# to clear a label for a state that was our own half-finished run — while the message
# sends them looking for an agent that does not exist.
fix_issue 107 OPEN "status:ready"
# Our own: the claim names the branch and no worktree, AND OUR RECORD ALREADY NAMES THE
# BRANCH — which is the state a run killed in that window is actually in, because start
# writes the branch onto the record one statement after acquiring and the worktree only
# after the fetch and the checkout.
claim_row 107 "${CLAIM_AGENT:-tester@fixture}" "tkt-107/ticket-107" ""
driver_state_init 107 --branch "tkt-107/ticket-107"
out=$(driver_step_start 107 2>&1); rc=$?
want "it carries on with the claim it holds" "0" "$rc"
want_not_in "and never blames a peer"        'peer' "$out"
want "a worktree was cut"                    "1" \
  "$([ -d "$(driver_state_get 107 worktree)" ] && echo 1)"
want "the claim is still held once, not twice" "1" \
  "$(awk '$1==107' "$CLAIMS" | grep -c .)"

echo "--- a SIBLING agent on this machine is not us, however the lock reads ---"
# The identity the lock compares is <login>@<host>, the same string for every agent on
# the box, so `holds` answers 0 for a claim a peer took. Believing that reads a live
# peer's claim as our own: the step carries on, cuts a second worktree on a second
# branch, and its `update` rewrites the peer's branch and worktree onto their claim —
# so the peer's work becomes invisible to every reconciler while both agents build.
# What tells them apart is the claim's OWN record, which names the branch and the
# worktree it was taken for.
fix_issue 108 OPEN "status:ready"
claim_row 108 "${CLAIM_AGENT:-tester@fixture}" "tkt-108/a-peer-got-here-first" "$FIX/peer-wt"
mkdir -p "$FIX/peer-wt"
out=$(driver_step_start 108 2>&1); rc=$?
want "a sibling's claim is not adopted" "24" "$rc"
want_in "and it says another run holds it" 'another|peer' "$out"
want "the sibling's branch is untouched"   "tkt-108/a-peer-got-here-first" \
  "$(awk -F'\t' '$1==108{print $3}' "$CLAIMS")"
want "and its worktree too"                "$FIX/peer-wt" \
  "$(awk -F'\t' '$1==108{print $4}' "$CLAIMS")"
want "no worktree was cut for us"          "" "$(driver_state_get 108 worktree)"

echo "--- a sibling in the pre-worktree window names the SAME branch, and is still not us ---"
# The branch is derived from the ticket and its title, so a sibling that acquired seconds
# ago and has not recorded a worktree yet carries exactly the branch this run computes.
# Matching on the branch alone therefore adopted it, cut a second worktree, and rewrote
# the sibling's claim. What separates them is OUR record: this run writes the branch onto
# it one statement after acquiring, so an empty record means we never acquired.
fix_issue 110 OPEN "status:ready"
claim_row 110 "${CLAIM_AGENT:-tester@fixture}" "tkt-110/ticket-110" ""
out=$(driver_step_start 110 2>&1); rc=$?
want "it is not adopted"                "24" "$rc"
want_in "and says another run holds it" 'another|peer' "$out"
want "no worktree was cut for us"       "" "$(driver_state_get 110 worktree)"
want "and the sibling's claim is untouched" "" "$(awk -F'\t' '$1==110{print $4}' "$CLAIMS")"

echo "--- and our own claim, recorded, is still ours on a resume ---"
fix_issue 109 OPEN "status:ready"
driver_state_init 109 --worktree "$FIX/ours-wt" --branch tkt-109/ours
git -C "$REPO" worktree add -q "$FIX/ours-wt" -b tkt-109/ours develop
claim_row 109 "${CLAIM_AGENT:-tester@fixture}" tkt-109/ours "$FIX/ours-wt"
out=$(driver_step_start 109 2>&1); rc=$?
want "it resumes"                  "0" "$rc"
want "in the same worktree"        "$FIX/ours-wt" "$(driver_state_get 109 worktree)"

echo "--- a ticket that does not resolve ---"
out=$(driver_step_start 999 2>&1); rc=$?
want "an unreadable ticket refuses" "24" "$rc"
want_in "and says it could not read it" 'could not be read' "$out"

echo "--- the claim is released when a gate says no, never squatted ---"
want "nothing claimed for the refused tickets" "101 107 108 110 109" \
  "$(awk '$1!=106{print $1}' "$CLAIMS" | tr '\n' ' ' | sed 's/ $//')"

echo "--- when the hooks cannot be made to run, start refuses ---"
printf '#!/usr/bin/env bash\necho "🛑 ensure-hooks: planted refusal" >&2\nexit 1\n' > "$BIN/ensure-hooks-refuses"
fix_issue 111 OPEN "status:ready"
out=$(DRIVER_ENSURE_HOOKS="$BIN/ensure-hooks-refuses" driver_step_start 111 2>&1); rc=$?
want "it refuses"                       "24" "$rc"
want_in "and says hooks could not be set up" 'hooks could not be set up' "$out"
want_in "with the script's own reason"  'planted refusal' "$out"

echo "--- with a pre-push on develop, the worktree runs ITS OWN, with no shims copied ---"
# husky's relative shared hooksPath and no .husky/_ anywhere: git used to run no hook.
git -C "$REPO" config core.hooksPath .husky/_
mkdir -p "$REPO/.husky"
printf '#!/usr/bin/env sh\necho "pre-push ran in $PWD" > "%s/hook-ran"\nexit 1\n' "$FIX" > "$REPO/.husky/pre-push"
chmod +x "$REPO/.husky/pre-push"
git -C "$REPO" add .husky/pre-push && git -C "$REPO" commit -qm "a pre-push gate" --no-verify
git -C "$REPO" rev-parse -q --verify origin/develop >/dev/null 2>&1 \
  && git -C "$REPO" update-ref refs/remotes/origin/develop develop
fix_issue 112 OPEN "status:ready"
out=$(driver_step_start 112 2>&1); rc=$?
want "it finishes"                      "0" "$rc"
WT112=$(driver_state_get 112 worktree)
want "no shims were copied in"          "0" "$([ -d "$WT112/.husky/_" ] && echo 1 || echo 0)"
rm -f "$FIX/hook-ran"
git -C "$WT112" hook run pre-push -- origin x </dev/null >/dev/null 2>&1; rc=$?
want "pre-push runs and its exit 1 stands" "1" "$rc"
want "it ran in the worktree"           "pre-push ran in $(cd "$WT112" && pwd -P)" "$(cat "$FIX/hook-ran" 2>/dev/null)"

echo "--- worktree.sparseExclude: the worktree leaves the folder out, the trunk keeps it ---"
mkdir -p "$REPO/docs/evidence/9"; printf 'png\n' > "$REPO/docs/evidence/9/a.png"
git -C "$REPO" add docs/evidence && git -C "$REPO" commit -qm "evidence" --no-verify
git -C "$REPO" rev-parse -q --verify origin/develop >/dev/null 2>&1 \
  && git -C "$REPO" update-ref refs/remotes/origin/develop develop
cp "$HARNESS_CFG_PATH" "$FIX/cfg.before-sparse"
jq '.worktree.sparseExclude = ["docs/evidence"]' "$FIX/cfg.before-sparse" > "$HARNESS_CFG_PATH"
fix_issue 113 OPEN "status:ready"
out=$(driver_step_start 113 2>&1); rc=$?
want "it finishes"                      "0" "$rc"
WT113=$(driver_state_get 113 worktree)
want "the excluded folder is not checked out" "0" "$([ -e "$WT113/docs/evidence" ] && echo 1 || echo 0)"
want "the rest of the tree is"          "1" "$([ -f "$WT113/.husky/pre-push" ] && echo 1 || echo 0)"
want "the trunk's checkout keeps it"    "1" "$([ -f "$REPO/docs/evidence/9/a.png" ] && echo 1 || echo 0)"
cp "$FIX/cfg.before-sparse" "$HARNESS_CFG_PATH"

echo "--- the claim names the spawned run, so the spawner finds the run's worktree ---"
# claim-lock notes runs/<run>.worktrees only for a claim tagged with this run's id,
# and the spawner's post-exit dev-server stop and cache pass read that note. Without
# run_id on the claim, every driver run logged "no worktree recorded" and stopped nothing.
fix_issue 114 OPEN "status:ready"; : > "$FIX/cl-updates.log"
rc=0; CLAIM_RUN_ID=claim-114-run CLAIM_RUN_LOG="$FIX/run-114.log" driver_step_start 114 >/dev/null 2>&1 || rc=$?
want "it finishes"                         "0" "$rc"
want_in "the claim is tagged with the run" 'run_id=claim-114-run' "$(cat "$FIX/cl-updates.log")"
want_in "and the run's log"                "run_log=$FIX/run-114.log" "$(cat "$FIX/cl-updates.log")"

echo "--- a ticket with an open pull request is never cut a second branch ---"
# A healing row that reached the plain build used to park, come back as parked, and
# cut a fresh branch from the trunk beside the open PR's own.
fix_issue 115 OPEN "status:parked"
printf '[{"number":77,"headRefName":"tkt-115/the-real-one","headRefOid":"abc","isDraft":false,"mergeStateStatus":"DIRTY"}]\n' > "$FIX/gh/prs.json"
out=$(driver_step_start 115 2>&1); rc=$?
want "it refuses"                          "24" "$rc"
want_in "naming the pull request and its branch" '#77.*tkt-115/the-real-one' "$out"
want_in "and the way in that does fit"     '--repair' "$out"
want "no worktree was cut"                 "" "$(driver_state_get 115 worktree)"
want "no claim was taken"                  "" "$(awk '$1==115' "$CLAIMS")"
printf '[{"number":78,"headRefName":"tkt-1150/other","headRefOid":"abc","isDraft":false,"mergeStateStatus":"CLEAN"}]\n' > "$FIX/gh/prs.json"
rc=0; driver_step_start 115 >/dev/null 2>&1 || rc=$?
want "another ticket's PR whose number merely starts the same does not count" "0" "$rc"
printf '[]\n' > "$FIX/gh/prs.json"
echo "pr list" > "$FIX/gh-fail"
fix_issue 116 OPEN "status:ready"
out=$(driver_step_start 116 2>&1); rc=$?
want "an unreadable PR list refuses, rather than reading as none" "24" "$rc"
want_in "and says so"                      'could not ask' "$out"
rm -f "$FIX/gh-fail"

echo "--- end to end: the REAL claim lock notes the run's worktree for the spawner ---"
# The recorder above proves start SENDS run_id; this proves what that does. The real
# claim-lock.sh, against a bare origin in the fixture, writes runs/<run>.worktrees —
# the file spawn-claim.sh's post-exit dev-server stop and cache pass read.
git init -q --bare "$FIX/claims-origin"
git -C "$REPO" remote add origin "$FIX/claims-origin" 2>/dev/null || git -C "$REPO" remote set-url origin "$FIX/claims-origin"
git -C "$REPO" push -q origin develop
fix_issue 117 OPEN "status:ready"
rc=0; GIT_AUTHOR_NAME=f GIT_AUTHOR_EMAIL=f@x GIT_COMMITTER_NAME=f GIT_COMMITTER_EMAIL=f@x \
  CL="$HERE/../../scripts/claim-lock.sh" CLAIM_RUN_ID=claim-117-e2e CLAIM_RUN_LOG="$FIX/e2e.log" \
  driver_step_start 117 >"$FIX/e2e.out" 2>&1 || rc=$?
want "it finishes"                         "0" "$rc"
want "runs/<run>.worktrees names the driver's tree" "$(driver_state_get 117 worktree)" "$(cat "$STATE/runs/claim-117-e2e.worktrees" 2>/dev/null)"

echo "--- work a park left on origin, from another machine, is where the branch starts ---"
git init -q --bare "$FIX/origin-park"
git -C "$REPO" remote add origin "$FIX/origin-park" 2>/dev/null || git -C "$REPO" remote set-url origin "$FIX/origin-park"
git -C "$REPO" push -q origin develop
git -C "$REPO" worktree add -q "$FIX/elsewhere" -b scratch-140 develop
printf 'parked\n' > "$FIX/elsewhere/parked.txt"; git -C "$FIX/elsewhere" add parked.txt; git -C "$FIX/elsewhere" commit -qm "chore(#140): parked"
git -C "$FIX/elsewhere" push -q origin "HEAD:refs/heads/park/140/other-box-20261017T182734Z"
fix_issue 140 OPEN "status:ready,type:feature"
rc=0; out=$(driver_step_start 140 2>&1) || rc=$?
want "it finishes"                         "0" "$rc"
want "the branch starts at the parked commit" "$(git -C "$FIX/elsewhere" rev-parse HEAD)" "$(git -C "$(driver_state_get 140 worktree)" rev-parse HEAD)"
want "on the ticket's own branch, not the park ref" "tkt-140/ticket-140" "$(git -C "$(driver_state_get 140 worktree)" rev-parse --abbrev-ref HEAD)"
want_in "and it says so"                   'park/140/other-box-20261017T182734Z' "$out"
want "claimed_at stays the trunk"          "$(git -C "$REPO" rev-parse develop)" "$(driver_state_get 140 claimed_at_sha)"
fix_issue 141 OPEN "status:ready,type:feature"
rc=0; driver_step_start 141 >/dev/null 2>&1 || rc=$?
want "a ticket with no park ref is cut from the trunk" "$(git -C "$REPO" rev-parse develop)" "$(git -C "$(driver_state_get 141 worktree)" rev-parse HEAD)"

exit $FAILED
