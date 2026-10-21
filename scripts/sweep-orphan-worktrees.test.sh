#!/usr/bin/env bash
# Fixture test for sweep-orphan-worktrees.sh.
#
# Every worktree here is a real registered worktree of a scratch clone. Each
# keep-rule has a tree that only that rule protects, so deleting the rule
# deletes a tree this suite then finds missing.
set -uo pipefail
for v in $(env | sed -n 's/^\(GIT_[A-Z_]*\)=.*/\1/p'); do unset "$v"; done
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUT="$HERE/sweep-orphan-worktrees.sh"
[ -f "$SUT" ] || { echo "missing $SUT"; exit 2; }

SB=$(mktemp -d); SB=$(cd "$SB" && pwd -P)
PIDS=""
cleanup() { for p in $PIDS; do kill "$p" 2>/dev/null; wait "$p" 2>/dev/null; done; rm -rf "$SB"; }
trap cleanup EXIT
fail=0
ok()  { echo "  ok   — $1"; }
bad() { echo "  FAIL — $1"; fail=1; }
G() { git -c user.email=t@example.com -c user.name=tester -c commit.gpgsign=false -c init.defaultBranch=develop "$@"; }

ORIGIN="$SB/origin.git"; MAIN="$SB/main"; ROOT="$SB/root"; STATE="$SB/state"
mkdir -p "$ROOT" "$STATE/claims" "$SB/home"
G init -q --bare "$ORIGIN"
G clone -q "$ORIGIN" "$MAIN" 2>/dev/null
mkdir -p "$MAIN/apps/web"; printf 'src\n' > "$MAIN/apps/web/page.ts"; printf '.next\n' > "$MAIN/.gitignore"
G -C "$MAIN" add -A; G -C "$MAIN" commit -qm base; G -C "$MAIN" push -q origin HEAD:develop 2>/dev/null
cat > "$SB/cfg.json" <<'JSON'
{
  "repo": "example/thing", "integrationBranch": "develop", "branchPrefix": "tkt-", "sisterRepos": [],
  "labels": {
    "drafting": "status:drafting", "ready": "status:ready", "claimed": "status:claimed",
    "inReview": "status:in-review", "gated": "status:gated", "partial": "status:partial",
    "needsHuman": "status:needs-human", "pmDecision": "status:pm-decision",
    "pmTrack": "status:pm-track", "blocked": "status:blocked",
    "externalBlocked": "status:external-blocked", "parked": "status:parked",
    "hold": "needs:human-approval", "decision": ["needs:human-approval"]
  }
}
JSON

# Waits until lsof sees the process in the folder: a fixed sleep raced it under load.
sit_in() { # <dir> — a process sitting in <dir>, until the suite ends
  (cd "$1" && exec sleep 300) & PIDS="$PIDS $!"
  local p=$! real; real=$(cd "$1" && pwd -P)
  for _ in $(seq 1 100); do
    lsof -a -p "$p" -d cwd -Fn 2>/dev/null | grep -qxF "n$real" && return 0
    sleep 0.1
  done
}
add_wt() { # <name> [branch] — a registered worktree under the root, at the pushed commit
  if [ -n "${2:-}" ]; then G -C "$MAIN" worktree add -q "$ROOT/$1" -b "$2" develop
  else G -C "$MAIN" worktree add -q --detach "$ROOT/$1" develop; fi
}
cache() { mkdir -p "$1/apps/web/.next"; printf 'x\n' > "$1/apps/web/.next/out"; }
age_all() { find "$ROOT" "$SB/elsewhere" -exec touch -t 202001010000 {} + 2>/dev/null; }

# The forge: PRs per branch ($SB/prs.tsv: branch state number headOid) and ticket states
# ($SB/issues.tsv: number state), answered from the aliases the sweeper's one GraphQL query asks for.
mkdir -p "$SB/bin"; : > "$SB/prs.tsv"; : > "$SB/issues.tsv"
cat > "$SB/bin/gh" <<'GH'
#!/usr/bin/env bash
[ -f "$FORGE_DOWN" ] && exit 1
q=""; for a in "$@"; do case "$a" in query=*) q=${a#query=} ;; esac; done
printf '%s\n' "$q" > "$FORGE_LOG"
{
  printf '%s' "$q" | grep -oE 'b[0-9]+: pullRequests\(headRefName: "[^"]*"' | sed -E 's/^(b[0-9]+): pullRequests\(headRefName: "(.*)"$/\1\t\2/' |
  while IFS=$'\t' read -r k br; do
    awk -F'\t' -v b="$br" '$1==b {print $2"\t"$3"\t"$4}' "$FORGE_PRS" |
      jq -R 'split("\t") | {state: .[0], number: (.[1]|tonumber), headRefOid: .[2]}' | jq -s --arg k "$k" '{($k): {nodes: .}}'
  done
  printf '%s' "$q" | grep -oE 't[0-9]+: issueOrPullRequest\(number: [0-9]+' | sed -E 's/^t([0-9]+).*/\1/' |
  while read -r n; do
    st=$(awk -F'\t' -v n="$n" '$1==n {print $2}' "$FORGE_ISSUES")
    if [ -n "$st" ]; then jq -n --arg k "t$n" --arg s "$st" '{($k): {state: $s}}'; else jq -n --arg k "t$n" '{($k): null}'; fi
  done
} | jq -s '{data: {repository: (add // {})}}'
GH
chmod +x "$SB/bin/gh"
# The claim list (claim-lock.sh list --json): the planted file, or unreadable when there is none.
printf '[]\n' > "$SB/claims.json"
printf '#!/usr/bin/env bash\ncat "$SWEEP_CLAIMS_JSON"\n' > "$SB/bin/claimlist"; chmod +x "$SB/bin/claimlist"

sweep() {
  HOME="$SB/home" HARNESS_MAIN_REPO="$MAIN" HARNESS_REPO_ROOT="$MAIN" HARNESS_CFG_PATH="$SB/cfg.json" \
  HARNESS_STATE_DIR="$STATE" HARNESS_LOGIN=tester SWEEP_WORKTREE_ROOTS="$ROOT" \
  WT_CLAIM_LIST="$SB/bin/claimlist" SWEEP_CLAIMS_JSON="$SB/claims.json" \
  SWEEP_GH="$SB/bin/gh" FORGE_PRS="$SB/prs.tsv" FORGE_ISSUES="$SB/issues.tsv" FORGE_LOG="$SB/forge.log" FORGE_DOWN="$SB/forge-down" \
  bash "$SUT" "$@" 2>&1
}
there() { [ -d "$ROOT/$1" ]; }

build_world() {
  for p in $PIDS; do kill "$p" 2>/dev/null; wait "$p" 2>/dev/null; done; PIDS=""
  rm -rf "$ROOT"/* "$SB/elsewhere"; G -C "$MAIN" worktree prune
  for b in $(G -C "$MAIN" for-each-ref --format='%(refname:short)' refs/heads | grep -v '^develop$'); do G -C "$MAIN" branch -qD "$b"; done
  add_wt 12619-any-name tkt-12619/a          # names the old glob never matched
  add_wt harness-spawn-0a1b2c                # detached, no number at all
  add_wt sh-5-claimed-ref tkt-5/a;  G -C "$MAIN" push -q origin develop:refs/claims/5 2>/dev/null; cache "$ROOT/sh-5-claimed-ref"
  add_wt odd-folder tkt-706/work;   G -C "$MAIN" push -q origin develop:refs/claims/706 2>/dev/null
  add_wt 705-lockfile tkt-705/a;    mkdir -p "$STATE/claims/705.lock"
  add_wt 701-dirty tkt-701/a;       printf 'wip\n' > "$ROOT/701-dirty/apps/web/page.ts"; cache "$ROOT/701-dirty"
  add_wt 702-unpushed tkt-702/a;    printf 'n\n' > "$ROOT/702-unpushed/new.txt"
  G -C "$ROOT/702-unpushed" add -A; G -C "$ROOT/702-unpushed" commit -qm local
  add_wt 703-busy tkt-703/a;        cache "$ROOT/703-busy"
  add_wt 704-young tkt-704/a
  mkdir -p "$SB/elsewhere"; G -C "$MAIN" worktree add -q --detach "$SB/elsewhere/707-outside" develop
  age_all
  touch "$ROOT/704-young"
  sit_in "$ROOT/703-busy"
}

echo "sweep-orphan-worktrees fixture"

# --- 1. dry run: reports, removes nothing --------------------------------------
build_world
out=$(sweep)
there 12619-any-name && there harness-spawn-0a1b2c && ok "a dry run removes nothing" || bad "a dry run removed a worktree"
printf '%s' "$out" | grep -q 'would remove .*12619-any-name' && ok "it reports a number-first name it would remove" \
  || bad "a 12619-… worktree was never considered: $out"
[ -f "$ROOT/701-dirty/apps/web/.next/out" ] && ok "a dry run cleans no cache" || bad "a dry run removed a cache"

# --- 2. apply: every name is considered, every keep-rule holds -------------------
out=$(sweep --apply)
there 12619-any-name && bad "a clean, pushed, idle worktree named 12619-… survived" || ok "a worktree named for its ticket number first is removed"
there harness-spawn-0a1b2c && bad "a clean detached worktree with no ticket in its name survived" || ok "a worktree whose name carries no ticket is removed"
there sh-5-claimed-ref && ok "a claim ref on origin keeps its worktree" || bad "a claimed worktree was removed"
there odd-folder && ok "a claim found through the branch keeps a worktree whatever its folder is called" || bad "a claim on the branch did not protect its worktree"
there 705-lockfile && ok "a local lockfile keeps its worktree" || bad "a locked worktree was removed"
there 701-dirty && ok "uncommitted changes keep a worktree" || bad "a dirty worktree was removed"
there 702-unpushed && ok "a commit on no remote keeps a worktree" || bad "a worktree with an unpushed commit was removed"
there 703-busy && ok "a process sitting in a worktree keeps it" || bad "a worktree in use was removed"
there 704-young && ok "a worktree touched inside the threshold is kept" || bad "a young worktree was removed"
[ -d "$SB/elsewhere/707-outside" ] && ok "a worktree outside the root is never considered" || bad "a worktree outside the root was removed"
[ -f "$MAIN/apps/web/page.ts" ] && ok "the main checkout is untouched" || bad "the main checkout lost a file"
printf '%s' "$out" | grep -q 'Sweep complete: kept=7 removed=2' && ok "the summary counts both" || bad "summary: $(printf '%s' "$out" | tail -2)"

# --- 3. the cache pass runs over the worktrees it keeps ------------------------
[ ! -e "$ROOT/701-dirty/apps/web/.next" ] && ok "a kept worktree loses its idle build cache" || bad "the kept worktree's cache survived the sweep"
[ "$(cat "$ROOT/701-dirty/apps/web/page.ts")" = wip ] && ok "and keeps its uncommitted work" || bad "the dirty worktree's change was lost"
[ -f "$ROOT/703-busy/apps/web/.next/out" ] && ok "a worktree in use keeps its cache" || bad "a cache was removed under a live process"
[ -f "$ROOT/sh-5-claimed-ref/apps/web/.next/out" ] && ok "a claimed worktree keeps its cache" || bad "the cache pass cleaned a claimed worktree"

# --- 4. --caches-only removes no worktree --------------------------------------
build_world
cache "$ROOT/12619-any-name"; age_all
out=$(sweep --caches-only --apply)
there 12619-any-name && ok "--caches-only removes no worktree" || bad "--caches-only removed a worktree"
[ ! -e "$ROOT/12619-any-name/apps/web/.next" ] && ok "but it cleans the idle cache in it" || bad "--caches-only left an idle cache: $out"
[ -f "$ROOT/703-busy/apps/web/.next/out" ] && ok "and still spares a worktree in use" || bad "--caches-only cleaned under a live process"

# --- 4b. the caller's own session is somebody using the worktree it sits in ----
build_world
out=$(cd "$ROOT/12619-any-name" && sweep --apply)
there 12619-any-name && ok "a sweep run from inside a worktree keeps that worktree" \
  || bad "the sweeper removed the worktree its own caller was sitting in"

# --- 5. claims that cannot be read remove nothing ------------------------------
build_world
G -C "$MAIN" remote set-url origin "$SB/no-such-origin.git"
out=$(sweep --apply)
there 12619-any-name && ok "with the claims unreadable, nothing is removed" || bad "it removed a worktree without reading the claims"
printf '%s' "$out" | grep -q 'claims could not be read' && ok "and it says why" || bad "no reason given: $out"
G -C "$MAIN" remote set-url origin "$ORIGIN"

# --- 6. the main checkout is never a candidate, even under a root --------------
find "$MAIN" -maxdepth 0 -exec touch -t 202001010000 {} +
out=$(HOME="$SB/home" HARNESS_MAIN_REPO="$MAIN" HARNESS_REPO_ROOT="$MAIN" HARNESS_CFG_PATH="$SB/cfg.json" \
      HARNESS_STATE_DIR="$STATE" HARNESS_LOGIN=tester SWEEP_WORKTREE_ROOTS="$SB" bash "$SUT" 2>&1)
printf '%s' "$out" | grep -qE '(would remove|keep) +main ' && bad "the main checkout was considered: $out" \
  || ok "the main checkout is never considered, even when a root holds it"

# --- 7. finished work goes at once; every never-delete guard still holds ----------
MAIN2="$SB/main2"; G clone -q "$ORIGIN" "$MAIN2" 2>/dev/null
FOREIGN_ORIGIN="$SB/foreign.git"; FOREIGN="$SB/foreign"
G init -q --bare "$FOREIGN_ORIGIN"; G clone -q "$FOREIGN_ORIGIN" "$FOREIGN" 2>/dev/null
G -C "$FOREIGN" commit -q --allow-empty -m f; G -C "$FOREIGN" push -q origin HEAD:develop 2>/dev/null
merged() { printf '%s\tMERGED\t%s\t%s\n' "$1" "$2" "$3" >> "$SB/prs.tsv"; }
commit_in() { printf '%s\n' "$2" > "$ROOT/$1/$2.txt"; G -C "$ROOT/$1" add -A; G -C "$ROOT/$1" commit -qm "$2"; }
# Pushed to its PR branch, then the branch deleted on merge: the commit is on no remote any more.
pushed_then_deleted() { # <folder> <branch>
  G -C "$ROOT/$1" push -q origin "$2" 2>/dev/null; G -C "$ROOT/$1" push -q origin --delete "$2" 2>/dev/null
}
build_finished() {
  for p in $PIDS; do kill "$p" 2>/dev/null; wait "$p" 2>/dev/null; done; PIDS=""
  rm -rf "$ROOT"/* "$SB/forge-down"; rm -rf "$STATE/claims"/*; : > "$SB/prs.tsv"; : > "$SB/issues.tsv"
  for m in "$MAIN" "$MAIN2" "$FOREIGN"; do
    G -C "$m" worktree prune
    for b in $(G -C "$m" for-each-ref --format='%(refname:short)' refs/heads | grep -vxE 'develop|master|main'); do G -C "$m" branch -qD "$b"; done
  done
  add_wt 801-merged tkt-801/a;   commit_in 801-merged one; pushed_then_deleted 801-merged tkt-801/a
  merged tkt-801/a 1801 "$(G -C "$ROOT/801-merged" rev-parse HEAD)"
  add_wt 802-extra tkt-802/a;    commit_in 802-extra one; pushed_then_deleted 802-extra tkt-802/a
  merged tkt-802/a 1802 "$(G -C "$ROOT/802-extra" rev-parse HEAD)"; commit_in 802-extra two
  add_wt 803-dirty tkt-803/a;    merged tkt-803/a 1803 "$(G -C "$MAIN" rev-parse develop)"
  printf 'wip\n' > "$ROOT/803-dirty/apps/web/page.ts"
  add_wt 804-busy tkt-804/a;     merged tkt-804/a 1804 "$(G -C "$MAIN" rev-parse develop)"
  add_wt 805-claimed tkt-805/a;  merged tkt-805/a 1805 "$(G -C "$MAIN" rev-parse develop)"; mkdir -p "$STATE/claims/805.lock"
  add_wt 806-closed;             printf '806\tCLOSED\n' >> "$SB/issues.tsv"
  add_wt 807-open-pr tkt-807/a;  printf '807\tCLOSED\n' >> "$SB/issues.tsv"
  printf 'tkt-807/a\tOPEN\t1807\t%s\n' "$(G -C "$MAIN" rev-parse develop)" >> "$SB/prs.tsv"
  add_wt 808-open tkt-808/a;     printf '808\tOPEN\n' >> "$SB/issues.tsv"
  add_wt 811-untracked tkt-811/a; merged tkt-811/a 1811 "$(G -C "$MAIN" rev-parse develop)"; printf 'n\n' > "$ROOT/811-untracked/notes.txt"
  # A second clone of the same project registered this one; the sweeper never listed it.
  G -C "$MAIN2" worktree add -q "$ROOT/809-other-clone" -b tkt-809/a origin/develop
  merged tkt-809/a 1809 "$(G -C "$MAIN" rev-parse develop)"
  G -C "$FOREIGN" worktree add -q "$ROOT/810-foreign" -b tkt-810/a develop
  merged tkt-810/a 1810 "$(G -C "$FOREIGN" rev-parse develop)"
  sit_in "$ROOT/804-busy"
}
build_finished
out=$(sweep)
there 801-merged && ok "a dry run removes no finished worktree" || bad "a dry run removed a finished worktree"
printf '%s' "$out" | grep -q 'would remove .*801-merged — PR #1801 merged' && ok "the dry run names the merged PR" || bad "no merged-PR reason: $out"
out=$(sweep --apply)
there 801-merged && bad "a merged worktree under a day old survived: $out" || ok "a worktree whose PR merged goes at once, though under a day old and its branch deleted"
there 806-closed && bad "a closed ticket's worktree survived: $out" || ok "a worktree whose ticket is closed goes at once"
printf '%s' "$out" | grep -q 'remove  806-closed — ticket #806 closed' && ok "and it says the ticket closed" || bad "no closed-ticket reason: $out"
there 809-other-clone && bad "a second clone's merged worktree survived: $out" || ok "a merged worktree another clone registered is removed too"
G -C "$MAIN2" worktree list | grep -q 809-other-clone && bad "the other clone still lists the removed worktree" || ok "and that clone no longer lists it"
there 802-extra && ok "a commit made after the PR's head keeps a merged worktree" || bad "a merged worktree with an unpushed commit was removed"
printf '%s' "$out" | grep -q 'keep    802-extra — 1 commit(s) on no remote' && ok "and it says the commit is on no remote" || bad "802 reason: $out"
there 803-dirty && ok "uncommitted changes keep a merged worktree" || bad "a merged worktree with uncommitted changes was removed"
[ "$(cat "$ROOT/803-dirty/apps/web/page.ts" 2>/dev/null)" = wip ] && ok "and its change survives" || bad "the dirty merged worktree lost its change"
there 811-untracked && ok "an untracked file keeps a merged worktree" || bad "a merged worktree with an untracked file was removed"
there 804-busy && ok "a process inside keeps a merged worktree" || bad "a merged worktree in use was removed"
there 805-claimed && ok "a live claim keeps a merged worktree" || bad "a claimed merged worktree was removed"
there 807-open-pr && ok "an open PR keeps a closed ticket's young worktree" || bad "a worktree with an open PR was removed"
there 808-open && ok "an open ticket with no merged PR keeps the age rule" || bad "an open ticket's young worktree was removed"
there 810-foreign && ok "another repo's worktree under the root is never removed" || bad "a foreign repo's worktree was removed"
grep -q 'b[0-9]*: pullRequests(headRefName: "tkt-801/a"' "$SB/forge.log" && ok "the query asks for the branch's PRs" || bad "query: $(cat "$SB/forge.log")"

build_finished; touch "$SB/forge-down"
out=$(sweep --apply)
there 801-merged && ok "with the forge unreadable, a young merged worktree is kept" || bad "it removed a young worktree without reading its PR"
printf '%s' "$out" | grep -q 'PR and ticket states unreadable' && ok "and the summary says so" || bad "no forge note: $(printf '%s' "$out" | grep Sweep)"

# --- 8. harness-tools-* snapshots ----------------------------------------------
build_world
CUR=$(G -C "$MAIN" rev-parse origin/develop)
tools() { mkdir -p "$ROOT/harness-tools-$1/scripts"; printf 'echo\n' > "$ROOT/harness-tools-$1/scripts/x.sh"; }
tools "$(printf '%.10s' "$CUR")"; tools aaaa111111; tools bbbb222222; tools cccc333333; tools dddd444444
find "$ROOT"/harness-tools-* -exec touch -t 202001010000 {} +
touch "$ROOT/harness-tools-bbbb222222"
sit_in "$ROOT/harness-tools-cccc333333"
(exec 3<"$ROOT/harness-tools-dddd444444/scripts/x.sh"; cd /; exec sleep 300) & PIDS="$PIDS $!"
holder=$!; for _ in $(seq 1 100); do lsof -p "$holder" -Fn 2>/dev/null | grep -q dddd444444 && break; sleep 0.1; done
out=$(sweep)
[ -d "$ROOT/harness-tools-aaaa111111" ] && ok "a dry run removes no snapshot" || bad "a dry run removed a snapshot"
printf '%s' "$out" | grep -q 'tools snapshots (dry run): would-remove=1 kept=4' && ok "the dry run counts them" || bad "tools dry: $(printf '%s' "$out" | grep tools)"
out=$(sweep --apply)
[ -d "$ROOT/harness-tools-aaaa111111" ] && bad "an old unused snapshot survived" || ok "an old snapshot nothing uses is removed"
[ -d "$ROOT/harness-tools-$(printf '%.10s' "$CUR")" ] && ok "the current branch head's snapshot is kept" || bad "the current snapshot was removed"
[ -d "$ROOT/harness-tools-bbbb222222" ] && ok "a snapshot under a day old is kept" || bad "a young snapshot was removed"
[ -d "$ROOT/harness-tools-cccc333333" ] && ok "a snapshot a process sits in is kept" || bad "a snapshot in use (cwd) was removed"
[ -f "$ROOT/harness-tools-dddd444444/scripts/x.sh" ] && ok "a snapshot with a file open is kept" || bad "a snapshot with an open file was removed"

echo
[ "$fail" -eq 0 ] && echo "sweep-orphan-worktrees: all cases pass" || echo "sweep-orphan-worktrees: FAILURES above"
exit $fail
