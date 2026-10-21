#!/usr/bin/env bash
# stranded-sweep.test.sh — commits in a worktree that are on no ref of origin reach
# origin as a stranded ref with nobody asking; a tree already pushed, already on a
# stranded ref, already on the trunk, or held by a live run is left as it is, and
# nothing is deleted. Each guard is planted out of a copy of the kit, and the case it
# holds must then fail.
# Run: bash "$0"
set -uo pipefail
for v in $(env | sed -n 's/^\(GIT_[A-Z_]*\)=.*/\1/p'); do unset "$v"; done
unset KIT_ROOT HARNESS_KIT_ROOT
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../swarm/tests/fixture.sh"
swarm_fixture; trap 'rm -rf "$FIX"' EXIT
git config --global --get user.email >/dev/null 2>&1 || export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
C="$STATE/coordinator"
SS="$HERE/stranded-sweep.sh"
export HARNESS_WORKTREE_ROOT="$FIX/trees" DRIVER_STRANDED_RETRY_SEC=0
export STRANDED_SWEEP_ROOT="$HARNESS_WORKTREE_ROOT"
mkdir -p "$HARNESS_WORKTREE_ROOT"

ORIGIN="$FIX/origin.git"; git init -q --bare "$ORIGIN"
git -C "$REPO" checkout -q -b develop
echo base > "$REPO/f.txt"; git -C "$REPO" add -A; git -C "$REPO" commit -qm base
git -C "$REPO" remote add origin "$ORIGIN"; git -C "$REPO" push -q origin develop
tree() { # <folder> <branch> <file> <content> — a worktree with one commit of its own
  git -C "$REPO" worktree add -q "$HARNESS_WORKTREE_ROOT/$1" -b "$2" develop
  printf '%s\n' "$4" > "$HARNESS_WORKTREE_ROOT/$1/$3"
  git -C "$HARNESS_WORKTREE_ROOT/$1" add -A; git -C "$HARNESS_WORKTREE_ROOT/$1" commit -qm "work on $2"
}
head_of() { git -C "$HARNESS_WORKTREE_ROOT/$1" rev-parse HEAD; }
stranded() { git -C "$ORIGIN" for-each-ref --format='%(objectname)' "refs/stranded/$1/"; }

tree tkt-701-a tkt-701/a a.txt one                       # unpushed: goes to origin
echo two >> "$HARNESS_WORKTREE_ROOT/tkt-701-a/a.txt"; git -C "$HARNESS_WORKTREE_ROOT/tkt-701-a" commit -qam "more"
tree tkt-702-b tkt-702/b b.txt one                       # its branch is on origin
git -C "$HARNESS_WORKTREE_ROOT/tkt-702-b" push -q origin tkt-702/b
tree tkt-706-f tkt-706/f f6.txt one                      # its upstream, under another name, is on origin
git -C "$HARNESS_WORKTREE_ROOT/tkt-706-f" push -q -u origin HEAD:tkt-706/renamed
tree tkt-703-c tkt-703/c c.txt one                       # a live run holds it
printf '{"run_id":"claim-703-x","ticket":"703","pid":%s}\n' "$$" > "$STATE/runs/claim-703-x.json"
printf '%s\n' "$HARNESS_WORKTREE_ROOT/tkt-703-c" > "$STATE/runs/claim-703-x.worktrees"
tree tkt-704-d tkt-704/d d.txt one                       # already on a stranded ref
git -C "$HARNESS_WORKTREE_ROOT/tkt-704-d" push -q --no-verify origin "HEAD:refs/stranded/704/other-box-20261001T000000Z"
tree tkt-705-e tkt-705/e e.txt one                       # squash-merged: the trunk reads the same
P="$FIX/pusher"; git clone -q -b develop "$ORIGIN" "$P"; echo one > "$P/e.txt"; git -C "$P" add -A; git -C "$P" commit -qm "squash 705"; git -C "$P" push -q origin develop
tree scratch scratch s.txt one                           # no ticket to name a ref by
BEFORE=$(git -C "$REPO" worktree list --porcelain | grep -c '^worktree ')

run() { (cd "$FIX" && COORDINATOR_SHADOW="${SHADOW:-0}" bash "${SUT:-$SS}" "$@" 2>&1); }

echo "--- shadow says what it would push, and pushes nothing ---"
OUT=$(SHADOW=1 run)
want_in "it would push #701"                  "would push 2 commit\(s\) from .*tkt-701-a \(#701, tkt-701/a\)" "$OUT"
want "nothing reached origin"                 "" "$(stranded 701)"

echo "--- a live sweep pushes only the stranded tree ---"
OUT=$(run --force)
want "#701's commits are on a stranded ref"   "$(head_of tkt-701-a)" "$(stranded 701)"
want_in "the push is logged"                  "stranded sweep: pushed 2 commit\(s\) from .*tkt-701-a \(#701, tkt-701/a\) to refs/stranded/701/" "$(cat "$C/tick.log")"
want "a tree whose branch is on origin is left" "" "$(stranded 702)"
want "a tree whose upstream is on origin is left" "" "$(stranded 706)"
want "a tree a live run holds is left"        "" "$(stranded 703)"
want_in "and that is said"                    "tkt-703-c: held by live run claim-703-x — untouched" "$OUT"
want "a tree already on a stranded ref gets no second" "1" "$(stranded 704 | grep -c .)"
want "a squash-merged tree is left"           "" "$(stranded 705)"
want_in "a tree with no ticket is named, not pushed" "scratch: 1 commit\(s\) on no ref of origin, but no ticket" "$OUT"
want_in "the summary counts them"             "7 worktree\(s\) under .*: 1 pushed, 3 already on origin, 1 already on develop, 1 held by a live run" "$OUT"
want "no worktree was removed"                "$BEFORE" "$(git -C "$REPO" worktree list --porcelain | grep -c '^worktree ')"
want "no branch was moved"                    "$(head_of tkt-701-a)" "$(git -C "$REPO" rev-parse tkt-701/a)"

echo "--- the next sweep pushes nothing again ---"
OUT=$(run --force)
want "still one stranded ref for #701"        "1" "$(stranded 701 | grep -c .)"
want_in "it counts #701 as on origin now"     "0 pushed, 4 already on origin" "$OUT"

echo "--- at most once an hour ---"
echo three >> "$HARNESS_WORKTREE_ROOT/tkt-701-a/a.txt"; git -C "$HARNESS_WORKTREE_ROOT/tkt-701-a" commit -qam "later"
OUT=$(run)
want "a sweep inside the hour does nothing"   "" "$OUT"
want "and pushes nothing"                     "1" "$(stranded 701 | grep -c .)"
OUT=$(STRANDED_SWEEP_EVERY_MIN=0 run)
want "past the hour, the new commit goes"     "2" "$(stranded 701 | grep -c .)"

echo "--- plants: each guard out, its case fails ---"
KIT="$FIX/kit"; mkdir -p "$KIT"; cp -R "$HERE/../scripts" "$HERE/../swarm" "$HERE/../driver" "$KIT/"
plant() { # <label> <exact text to delete> <ticket whose stranded refs then change> <count it must not reach>
  local f="$KIT/scripts/stranded-sweep.sh"; cp "$f" "$FIX/plant.bak"
  python3 -I -c 'import sys; p, l = sys.argv[1], sys.argv[2]; s = open(p).read(); n = s.count(l); open(p, "w").write(s.replace(l, "", 1)); sys.exit(0 if n == 1 else 1)' "$f" "$2" \
    || { bad "plant did not land: $1"; cp "$FIX/plant.bak" "$f"; return; }
  SUT="$f" run --force >/dev/null
  want "planted ($1): #$3 gets a stranded ref it must not" "$4" "$(stranded "$3" | grep -c .)"
  cp "$FIX/plant.bak" "$f"
}
plant "the live-run hold"   'if rid=$(wt_run_holder "$wt"); then held=$((held+1)); say "$wt: held by live run $rid — untouched"; continue; fi' 703 1
plant "the stranded refs"   " --glob='refs/remotes/origin/stranded/*'" 704 2
plant "the branch on origin" '[ -n "$b" ] && git -C "$wt" rev-parse -q --verify "refs/remotes/origin/$b" >/dev/null 2>&1 && nots+=("refs/remotes/origin/$b")' 702 1
plant "the upstream"        'up=$(git -C "$wt" rev-parse -q --verify '"'"'@{upstream}'"'"' 2>/dev/null) && nots+=("$up")' 706 1
diff -q "$SS" "$KIT/scripts/stranded-sweep.sh" >/dev/null && ok "the planted copy is restored" || bad "the planted copy was not restored"

echo
[ "$FAILED" -eq 0 ] && echo "stranded-sweep: all cases pass" || echo "stranded-sweep: FAILURES above"
exit "$FAILED"
