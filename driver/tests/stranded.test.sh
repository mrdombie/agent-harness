#!/usr/bin/env bash
# stranded.test.sh — work the driver could not push still reaches origin, on a ref
# nothing reacts to, and the next run on ANOTHER machine resumes from it. A bundle
# on one machine's disk was once the only copy of 40 commits for days.
# Run: bash "$0"
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/fixture.sh"
driver_fixture; trap 'rm -rf "$FIX"' EXIT
. "$HERE/../steps/park.sh" || exit 1
. "$HERE/../steps/start.sh" || exit 1
. "$HERE/../steps/reenter.sh" || exit 1
git init -q --bare "$FIX/origin"
git -C "$REPO" remote add origin "$FIX/origin"
git -C "$REPO" push -q origin develop

# A claim lock per machine: free unless this machine acquired it.
cat > "$BIN/claim-lock" <<'SH'
#!/usr/bin/env bash
f="${CLAIMS:?}"; touch "$f"
case "$1" in
  acquire) grep -qx "$2" "$f" && exit 10; echo "$2" >> "$f" ;;
  holds)   grep -qx "$2" "$f" || exit 11 ;;
  show)    grep -qx "$2" "$f" || exit 11; echo '{}' ;;
  release) grep -vx "$2" "$f" > "$f.t"; mv "$f.t" "$f" ;;
esac
exit 0
SH
chmod +x "$BIN/claim-lock"; export CL="$BIN/claim-lock" CLAIMS="$FIX/claims-a"

refusing_hook() { mkdir -p "$1"; printf '#!/usr/bin/env sh\necho "✗ check:no-new-smells"\nexit 1\n' > "$1/pre-push"; chmod +x "$1/pre-push"; }
stranded() { git -C "$FIX/origin" for-each-ref --format='%(refname)' "refs/stranded/$1/"; }
heads()    { git -C "$FIX/origin" for-each-ref --format='%(refname) %(objectname)' refs/heads/ refs/tags/ | sort; }

# MACHINE B: a separate clone with its own state, worktree root, claims and host name.
M2="$FIX/machine-b"
git clone -q "$FIX/origin" "$M2"
git -C "$M2" config user.email b@example.invalid; git -C "$M2" config user.name B
jq --arg r "$FIX/trees-b" '.worktreeRoot = $r' "$REPO/.claude/harness.json" > "$FIX/harness-b.json"
mkdir -p "$FIX/state-b/driver" "$FIX/state-b/runs" "$FIX/state-b/logs" "$FIX/bin-b"
printf '#!/usr/bin/env sh\necho other-box\n' > "$FIX/bin-b/hostname"; chmod +x "$FIX/bin-b/hostname"
on_b() { # <function call…> — runs one driver step as machine B, in its own process
  env -u DRIVER_DIR PATH="$FIX/bin-b:$PATH" HARNESS_MAIN_REPO="$M2" HARNESS_REPO_ROOT="$M2" \
    HARNESS_STATE_DIR="$FIX/state-b" HARNESS_CFG_PATH="$FIX/harness-b.json" CLAIMS="$FIX/claims-b" \
    CLAIM_REPO="$M2" bash -c '. "$1/../steps/start.sh"; . "$1/../steps/reenter.sh"; shift; "$@"' _ "$HERE" "$@"
}

echo "--- a park whose push the pre-push refused leaves the work on a stranded ref ---"
git -C "$REPO" worktree add -q "$FIX/wt140" -b tkt-140/ticket-140 develop
for i in 1 2 3; do printf '%s\n' "$i" > "$FIX/wt140/f$i.txt"; git -C "$FIX/wt140" add .; git -C "$FIX/wt140" commit -qm "feat: part $i"; done
refusing_hook "$FIX/hooks140"; git -C "$FIX/wt140" config core.hooksPath "$FIX/hooks140"
driver_state_init 140 --worktree "$FIX/wt140" --branch tkt-140/ticket-140
fix_issue 140 OPEN "status:claimed,type:feature"
before=$(heads)
out=$(driver_park 140 "the pre-push refused" "" driver 2>&1); rc=$?
ref=$(stranded 140)
want "park reports parked"                   "20" "$rc"
want "the ticket's branch was refused"       "" "$(git -C "$FIX/origin" rev-parse --verify -q refs/heads/tkt-140/ticket-140)"
want_in "the work is on a stranded ref"      "^refs/stranded/140/[A-Za-z0-9-]+-[0-9]{8}T[0-9]{6}Z$" "$ref"
want "at the worktree's head, all 3 commits" "$(git -C "$FIX/wt140" rev-parse HEAD)" "$(git -C "$FIX/origin" rev-parse --verify -q "$ref" 2>/dev/null)"
want "no branch or tag on origin moved"      "$before" "$(heads)"
want_in "the park comment names the ref"     "issue comment 140 .*$ref" "$(tr '\n' ' ' < "$GH_LOG")"
want_in "and the one-line fetch"             "git fetch origin $ref" "$(cat "$GH_LOG")"
want_in "the bundle is still written"        'bundled at' "$(cat "$GH_LOG")"
git -C "$FIX/wt140" config --unset core.hooksPath

echo "--- a second machine resumes from it ---"
fix_issue 140 OPEN "status:ready,type:feature"
out=$(on_b driver_step_start 140 2>&1); rc=$?
WTB=$(jq -r '.worktree // ""' "$FIX/state-b/driver/140/state.json" 2>/dev/null)
want "machine B's start finishes"            "0" "$rc"
want "its tree is machine B's own"           "1" "$([[ "$WTB" == "$FIX/trees-b/"* ]] && echo 1)"
want "its branch starts at the stranded work" "$(git -C "$FIX/wt140" rev-parse HEAD)" "$(git -C "$WTB" rev-parse HEAD 2>/dev/null)"
want "on the ticket's own branch"            "tkt-140/ticket-140" "$(git -C "$WTB" rev-parse --abbrev-ref HEAD 2>/dev/null)"
want_in "and it says so"                     "stranded work on origin as $ref" "$out"

echo "--- a stranded ref whose commits origin's branch already has is not resumed ---"
git -C "$FIX/wt140" push -q --no-verify origin HEAD:refs/heads/tkt-140/ticket-140
printf 'later\n' > "$FIX/wt140/later.txt"; git -C "$FIX/wt140" add .; git -C "$FIX/wt140" commit -qm "feat: later"
git -C "$FIX/wt140" push -q --no-verify origin HEAD:refs/heads/tkt-140/ticket-140
rm -rf "$FIX/state-b/driver/140" "$FIX/claims-b"
git -C "$M2" worktree remove --force "$WTB"; git -C "$M2" branch -q -D tkt-140/ticket-140
out=$(on_b driver_step_start 140 2>&1)
WTB=$(jq -r '.worktree // ""' "$FIX/state-b/driver/140/state.json" 2>/dev/null)
want_not_in "it does not start from it"      'stranded work on origin' "$out"
want "the stranded ref is younger than 14 days, so it stays" "$ref" "$(stranded 140)"

echo "--- expiry: only refs older than 14 days whose commits are on the ticket's branch ---"
old_on="refs/stranded/140/yomato-20260101T000000Z"
git -C "$FIX/origin" update-ref "$old_on" "$(git -C "$FIX/origin" rev-parse refs/heads/tkt-140/ticket-140~1)"
git -C "$REPO" worktree add -q --detach "$FIX/off140" develop
printf 'off\n' > "$FIX/off140/off.txt"; git -C "$FIX/off140" add .; git -C "$FIX/off140" commit -qm "feat: not on the branch"
old_off="refs/stranded/140/yomato-20260102T000000Z"
git -C "$FIX/off140" push -q --no-verify origin "HEAD:$old_off"
git -C "$REPO" fetch -q origin "+refs/heads/tkt-140/ticket-140:refs/remotes/origin/tkt-140/ticket-140"
out=$(driver_stranded_expire 140 "$REPO" tkt-140/ticket-140 2>&1)
left=$(stranded 140 | tr '\n' ' ')
want_not_in "an old ref on the branch is removed" "$old_on" "$left"
want_in "an old ref NOT on the branch is kept"   "$old_off" "$left"
want_in "a young ref on the branch is kept"      "$ref" "$left"

echo "--- a repair's withheld push: stranded ref written, the PR head untouched ---"
src="$FIX/src-150"; git clone -q -b develop "$FIX/origin" "$src"
git -C "$src" config user.email t@example.invalid; git -C "$src" config user.name T
git -C "$src" checkout -q -b tkt-150/work
printf 'pr\n' > "$src/pr.txt"; git -C "$src" add .; git -C "$src" commit -qm "feat: 150"
git -C "$src" push -q origin tkt-150/work
prhead=$(git -C "$FIX/origin" rev-parse refs/heads/tkt-150/work)
git -C "$REPO" fetch -q origin "+refs/heads/tkt-150/work:refs/remotes/origin/tkt-150/work"
git -C "$REPO" worktree add -q "$FIX/wt150" -b tkt-150/work origin/tkt-150/work
printf 'half a repair\n' > "$FIX/wt150/r.txt"
driver_state_init 150 --worktree "$FIX/wt150" --branch tkt-150/work
driver_state_set 150 mode repair; driver_state_set 150 pr 91
fix_issue 150 OPEN "status:claimed"
: > "$GH_LOG"
out=$(driver_park 150 "the review blocked the repair" "" driver 2>&1)
rref=$(stranded 150)
want "the PR head did not move"              "$prhead" "$(git -C "$FIX/origin" rev-parse refs/heads/tkt-150/work)"
want_in "the repair is on a stranded ref"    '^refs/stranded/150/' "$rref"
want "holding the repair's commit"           "$(git -C "$FIX/wt150" rev-parse HEAD)" "$(git -C "$FIX/origin" rev-parse --verify -q "$rref" 2>/dev/null)"
want_in "the park comment names it"          "git fetch origin $rref" "$(cat "$GH_LOG")"

echo "--- and a second machine's re-entry resumes the repair from it ---"
pr_json() { jq -nc --argjson n "$1" --arg b "$2" '[{number:$n, headRefName:$b, headRefOid:"x", isDraft:false, mergeStateStatus:"CLEAN"}]'; }
pr_json 91 tkt-150/work > "$FIX/gh/prs.json"
fix_issue 150 OPEN "status:in-review"
out=$(on_b driver_step_reenter 150 2>&1); rc=$?
WTB=$(jq -r '.worktree // ""' "$FIX/state-b/driver/150/state.json" 2>/dev/null)
want "machine B's reenter finishes"          "0" "$rc"
want "its tree holds the stranded repair"    "$(git -C "$FIX/wt150" rev-parse HEAD)" "$(git -C "$WTB" rev-parse HEAD 2>/dev/null)"
want "and still nothing was pushed to the PR" "$prhead" "$(git -C "$FIX/origin" rev-parse refs/heads/tkt-150/work)"
want_in "it says so"                         "resumes from it" "$out"

echo "--- a re-entry that sets diverged local commits aside puts them on origin too ---"
git -C "$src" checkout -q -b tkt-160/work develop
printf 'pr\n' > "$src/p160.txt"; git -C "$src" add .; git -C "$src" commit -qm "feat: 160"
git -C "$src" push -q origin tkt-160/work
git -C "$REPO" fetch -q origin "+refs/heads/tkt-160/work:refs/remotes/origin/tkt-160/work"
git -C "$REPO" worktree add -q "$FIX/wt160" -b tkt-160/work origin/tkt-160/work
printf 'mine\n' > "$FIX/wt160/mine.txt"; git -C "$FIX/wt160" add .; git -C "$FIX/wt160" commit -qm "feat: local only"
mine=$(git -C "$FIX/wt160" rev-parse HEAD)
printf 'theirs\n' > "$src/theirs.txt"; git -C "$src" add .; git -C "$src" commit -qm "feat: pushed elsewhere"
git -C "$src" push -q origin tkt-160/work
driver_state_init 160 --worktree "$FIX/wt160" --branch tkt-160/work
pr_json 92 tkt-160/work > "$FIX/gh/prs.json"
fix_issue 160 OPEN "status:in-review"
out=$(driver_step_reenter 160 2>&1); rc=$?
want "the re-entry finishes"                 "0" "$rc"
want "the set-aside commits are on origin"   "$mine" "$(git -C "$FIX/origin" rev-parse --verify -q "$(stranded 160 | tail -1)" 2>/dev/null)"
want "the tree took origin's head"           "$(git -C "$src" rev-parse HEAD)" "$(git -C "$FIX/wt160" rev-parse HEAD)"
want_in "and a diverged stranded ref is not taken" 'has diverged' "$out"

exit $FAILED
