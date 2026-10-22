#!/usr/bin/env bash
# reenter.test.sh — the repair path's way in. A repair re-enters the ticket's OWN
# open pull request: its branch, at origin's head, under a claim. It never cuts a
# fresh branch from the trunk, and every way that could go wrong is a refusal by
# name — no PR, two PRs, a closed or held ticket, a peer's claim, a local branch
# that has gone its own way, a PR list nobody could read.
# Run: bash "$0"
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/tests/lib/suite.sh" || exit 1
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/fixture.sh"
driver_fixture; on_exit_keep_status 'rm -rf "$FIX"'
. "$HERE/../steps/reenter.sh" || exit 1

# The claim seam, the same recorder start.test.sh uses: the real exit codes and the
# machine-wide identity, so "ours" has to be proved from the claim's own record.
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

# A bare origin, and the PR's branch on it with one commit the trunk does not have.
git init -q --bare "$FIX/origin"
git -C "$REPO" remote add origin "$FIX/origin"
git -C "$REPO" push -q origin develop
pr_branch() { # <ticket> — a pushed PR branch, a worktree-free copy in $FIX/src-<t>
  local t=$1 src="$FIX/src-$1"
  git clone -q -b develop "$FIX/origin" "$src"
  git -C "$src" config user.email t@example.invalid; git -C "$src" config user.name T
  git -C "$src" checkout -q -b "tkt-$t/work"
  printf 'pr %s\n' "$t" > "$src/pr$t.txt"; git -C "$src" add . ; git -C "$src" commit -qm "feat: $t"
  git -C "$src" push -q origin "tkt-$t/work"
}
prs() { printf '%s\n' "$1" > "$FIX/gh/prs.json"; }
pr_json() { # <n> <branch> [mergeState]
  jq -nc --argjson n "$1" --arg b "$2" --arg m "${3:-CLEAN}" '{number:$n, headRefName:$b, headRefOid:"x", isDraft:false, mergeStateStatus:$m}'
}

echo "--- a ticket with one open pull request is re-entered on that PR's branch ---"
pr_branch 201
fix_issue 201 OPEN "status:in-review"
prs "[$(pr_json 31 tkt-201/work DIRTY)]"
: > "$FIX/cl-updates.log"
out=$(CLAIM_RUN_ID=claim-201-r CLAIM_RUN_LOG=/x/201.log driver_step_reenter 201 2>&1); rc=$?
want "it finishes"                    "0" "$rc"
WT=$(driver_state_get 201 worktree)
want "a worktree exists"              "1" "$([ -d "$WT" ] && echo 1)"
want "on the PR's own branch"         "tkt-201/work" "$(git -C "$WT" rev-parse --abbrev-ref HEAD 2>/dev/null)"
want "at origin's head"               "$(git -C "$FIX/origin" rev-parse tkt-201/work)" "$(git -C "$WT" rev-parse HEAD 2>/dev/null)"
want "the PR is on the record"        "31" "$(driver_state_get 201 pr)"
want "and its merge state"            "DIRTY" "$(driver_state_get 201 merge_state)"
want "the head it is repaired from"   "$(git -C "$FIX/origin" rev-parse tkt-201/work)" "$(driver_state_get 201 repair_base)"
want "the claim was taken"            "201" "$(awk '$1==201{print $1}' "$CLAIMS")"
want_in "and tagged with the run"     'run_id=claim-201-r' "$(cat "$FIX/cl-updates.log")"
want_in "it says what it did"         'PR #31' "$out"

echo "--- a second pass keeps the tree, and takes the merge robot's new commit ---"
git -C "$FIX/src-201" commit -q --allow-empty -m "Merge develop (robot)"; git -C "$FIX/src-201" push -q origin tkt-201/work
rc=0; driver_step_reenter 201 >/dev/null 2>&1 || rc=$?
want "it finishes"                    "0" "$rc"
want "the same worktree"              "$WT" "$(driver_state_get 201 worktree)"
want "fast-forwarded to origin"       "$(git -C "$FIX/origin" rev-parse tkt-201/work)" "$(git -C "$WT" rev-parse HEAD)"

echo "--- unpushed repair commits of our own are kept on a resume ---"
git -C "$WT" commit -q --allow-empty -m "fix: half a repair"
mine=$(git -C "$WT" rev-parse HEAD)
rc=0; driver_step_reenter 201 >/dev/null 2>&1 || rc=$?
want "it finishes"                    "0" "$rc"
want "the local commit is still the head" "$mine" "$(git -C "$WT" rev-parse HEAD)"

echo "--- a local branch that has gone its own way is kept on a backup branch, never merged ---"
git -C "$FIX/src-201" commit -q --allow-empty -m "someone else"; git -C "$FIX/src-201" push -q origin tkt-201/work
out=$(driver_step_reenter 201 2>&1); rc=$?
want "it goes on from origin"         "0" "$rc"
want_in "and says its commits were kept" 'kept on backup/' "$out"

echo "--- a draft PR the driver never built is not re-entered as a repair ---"
pr_branch 230
fix_issue 230 OPEN "status:in-review"
prs "[$(pr_json 60 tkt-230/work | jq -c '.isDraft = true')]"
out=$(driver_step_reenter 230 2>&1); rc=$?
want "it refuses"                     "24" "$rc"
want_in "naming the draft"            'draft' "$out"
want "and takes no claim"             "" "$(awk '$1==230{print $1}' "$CLAIMS")"
want_in "the park note sends it to the driver's adoption, never the prose claim" 'build-ticket 230 --adopt' "$(driver_state_get 230 park_note)"
want_not_in "and names no prose claim"  'prose' "$(driver_state_get 230 park_note)"
driver_state_set 230 mode repair; driver_state_set 230 adopted "2026-10-22T00:00:00Z"
rc=0; driver_step_reenter 230 >/dev/null 2>&1 || rc=$?
want "an adopted draft is re-entered" "0" "$rc"
driver_state_set 230 adopted ""
driver_state_done 230 start
rc=0; driver_step_reenter 230 >/dev/null 2>&1 || rc=$?
want "a draft the driver's own build left is re-entered" "0" "$rc"

echo "--- a branch still checked out in another tree (a stale record's) is taken over, not re-cut ---"
# git refuses a second checkout of one branch: "already used by worktree".
pr_branch 231
fix_issue 231 OPEN "status:in-review"
git -C "$REPO" fetch -q origin tkt-231/work
git -C "$REPO" worktree add -q "$FIX/old231" -b tkt-231/work origin/tkt-231/work
prs "[$(pr_json 61 tkt-231/work)]"
out=$(driver_step_reenter 231 2>&1); rc=$?
want "it finishes"                    "0" "$rc"
want "in the tree that holds the branch" "$(cd "$FIX/old231" && pwd -P)" "$(cd "$(driver_state_get 231 worktree)" && pwd -P)"
want_in "and says so"                 'taking that tree over' "$out"

echo "--- a PR on a <ticket>/ branch with no closing reference is still the ticket's (#5654) ---"
# A person's or /claim's branch carries no prefix, and a body saying "Closes ticket n"
# gives GitHub nothing to link: the repair parked "no open pull request" beside it.
src=$(mktemp -d "$FIX/src-232.XXXX"); rmdir "$src"
git clone -q -b develop "$FIX/origin" "$src"
git -C "$src" -c user.email=t@example.invalid -c user.name=T checkout -q -b 232/approval-preview
printf 'pr 232\n' > "$src/pr232.txt"; git -C "$src" add .
git -C "$src" -c user.email=t@example.invalid -c user.name=T commit -qm "feat: 232"
git -C "$src" push -q origin 232/approval-preview
fix_issue 232 OPEN "status:in-review"
prs "[$(pr_json 62 232/approval-preview | jq -c '.body = "Closes ticket 232." | .closingIssuesReferences = []'), $(pr_json 63 2320/other)]"
out=$(driver_step_reenter 232 2>&1); rc=$?
want "it finishes"                    "0" "$rc"
want "on that PR"                     "62" "$(driver_state_get 232 pr)"
want "and its branch"                 "232/approval-preview" "$(driver_state_get 232 branch)"

echo "--- a PR whose body says Closes #n is the ticket's, whatever its branch ---"
pr_branch 233
fix_issue 233 OPEN "status:in-review"
git -C "$FIX/src-233" push -q origin "tkt-233/work:refs/heads/someone/else"
prs "[$(pr_json 64 someone/else | jq -c '.body = "Did the thing.\n\nFixes #233"'), $(pr_json 65 x/y | jq -c '.body = "Closes #2330"')]"
out=$(driver_step_reenter 233 2>&1); rc=$?
want "it finishes"                    "0" "$rc"
want "on the PR whose body closes it, not #2330's" "64" "$(driver_state_get 233 pr)"

echo "--- no open pull request: nothing to repair, and nothing is built fresh ---"
fix_issue 202 OPEN "status:in-review"; prs "[$(pr_json 32 tkt-2020/other)]"
out=$(driver_step_reenter 202 2>&1); rc=$?
want "it refuses"                     "24" "$rc"
want_in "naming what is missing"      'no open pull request' "$out"
want "no worktree was cut"            "" "$(driver_state_get 202 worktree)"
want "no claim was taken"             "" "$(awk '$1==202' "$CLAIMS")"

echo "--- no open pull request because it MERGED: the run ends clean, no park ---"
# #12766 parked "no open pull request to repair" an hour after its PR merged.
fix_issue 281 OPEN "status:in-review"; prs "[]"; claim_row 281 tester@fixture tkt-281/work ""
printf '%s\n' '[{"number":37,"headRefName":"tkt-2810/x","body":"","mergedAt":"2026-10-18T11:00:00Z"},{"number":36,"headRefName":"tkt-281/work","body":"","mergedAt":"2026-10-18T11:52:23Z"}]' > "$FIX/gh/prs-merged.json"
out=$(driver_step_reenter 281 2>&1); rc=$?
want "it ends as nothing owed"        "$DRIVER_E_NOOP" "$rc"
want_in "naming the merged PR"        '#36 merged at 2026-10-18T11:52:23Z' "$out"
want "no park note"                   "" "$(driver_state_get 281 park_note)"
want "the claim is released"          "" "$(awk '$1==281' "$CLAIMS")"
fix_issue 282 OPEN "status:in-review"
out=$(driver_step_reenter 282 2>&1); rc=$?
want "a merged PR for another ticket is not this one's" "24" "$rc"
rm -f "$FIX/gh/prs-merged.json"

echo "--- two open pull requests: which one is not the driver's guess ---"
fix_issue 203 OPEN "status:in-review"; prs "[$(pr_json 33 tkt-203/a), $(pr_json 34 tkt-203/b)]"
out=$(driver_step_reenter 203 2>&1); rc=$?
want "it refuses"                     "24" "$rc"
want_in "naming both"                 '#33.*#34' "$out"

echo "--- a closed ticket, a held ticket, a peer's claim, an unreadable list ---"
fix_issue 204 CLOSED "status:in-review"; prs "[$(pr_json 35 tkt-204/work)]"
rc=0; driver_step_reenter 204 >/dev/null 2>&1 || rc=$?
want "closed refuses"                 "24" "$rc"
fix_issue 205 OPEN "status:in-review,needs:human-approval"; prs "[$(pr_json 36 tkt-205/work)]"
out=$(driver_step_reenter 205 2>&1); rc=$?
want "held refuses"                   "24" "$rc"
want_in "naming the label"            'needs:human-approval' "$out"
pr_branch 206; fix_issue 206 OPEN "status:in-review"; prs "[$(pr_json 37 tkt-206/work)]"
claim_row 206 somebody@else tkt-206/work "$FIX/theirs"
out=$(driver_step_reenter 206 2>&1); rc=$?
want "a peer's claim is busy, not a refusal" "29" "$rc"
want_in "the reason is on the record"   'peer on another machine holds the claim' "$(driver_state_get 206 park_note)"
want_in "naming a peer"               'peer' "$out"
want "no worktree was cut"            "" "$(driver_state_get 206 worktree)"
# #13139's shape (2026-10-19): a run on THIS host holds the claim on another worktree,
# and the repair's record is fresh. It parked as "reenter left no reason on the record".
pr_branch 240; fix_issue 240 OPEN "status:in-review"; prs "[$(pr_json 40 tkt-240/work)]"
claim_row 240 "${CLAIM_AGENT:-tester@fixture}" tkt-240/work "$FIX/other-240"
out=$(driver_step_reenter 240 2>&1); rc=$?
want "a sibling run's claim is busy, not a refusal" "29" "$rc"
want_in "the reason is on the record"  'another run on this host holds the claim on #240' "$(driver_state_get 240 park_note)"
want "and the sibling's claim is untouched" "$FIX/other-240" "$(awk -F'\t' '$1==240{print $4}' "$CLAIMS")"
fix_issue 207 OPEN "status:in-review"; echo "open-prs" > "$FIX/gh-fail"
out=$(DRIVER_LOOKUP_RETRY_SEC=0 driver_step_reenter 207 2>&1); rc=$?
want "an unreadable PR list stops reenter as unread"  "26" "$rc"
want_in "and says so"                 'could not ask' "$out"
rm -f "$FIX/gh-fail"

echo "--- a recorded tree with OUR merge of the trunk in progress is resumed, not refused ---"
pr_branch 208; fix_issue 208 OPEN "status:in-review"; prs "[$(pr_json 38 tkt-208/work DIRTY)]"
rc=0; driver_step_reenter 208 >/dev/null 2>&1 || rc=$?
WT8=$(driver_state_get 208 worktree)
printf 'pr 208 changed\n' > "$WT8/pr208.txt"; git -C "$WT8" commit -qam "feat: ours" ; git -C "$WT8" push -q origin tkt-208/work
git -C "$REPO" checkout -q develop 2>/dev/null; printf 'trunk 208\n' > "$REPO/pr208.txt"; git -C "$REPO" add pr208.txt; git -C "$REPO" commit -qm "trunk 208"; git -C "$REPO" push -q origin develop
git -C "$WT8" fetch -q origin; git -C "$WT8" merge -q origin/develop >/dev/null 2>&1
out=$(driver_step_reenter 208 2>&1); rc=$?
want "it resumes"                          "0" "$rc"
want "the merge is left in progress for the repair step" "yes" "$([ -f "$(git -C "$WT8" rev-parse --git-path MERGE_HEAD)" ] && echo yes || echo no)"
want_in "and it says so"                   'merge .*in progress' "$out"
git -C "$WT8" merge --abort
git -C "$WT8" checkout -q -b foreign208 HEAD~1 2>/dev/null; printf 'x\n' > "$WT8/pr208.txt"; git -C "$WT8" commit -qam foreign; F=$(git -C "$WT8" rev-parse HEAD)
git -C "$WT8" checkout -q tkt-208/work; git -C "$WT8" merge -q "$F" >/dev/null 2>&1
out=$(driver_step_reenter 208 2>&1); rc=$?
want "a merge of something that is not the trunk refuses" "24" "$rc"
want_in "naming it"                        'not the integration branch' "$out"
git -C "$WT8" merge --abort

suite_end "$FAILED"
