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

sweep() {
  HOME="$SB/home" HARNESS_MAIN_REPO="$MAIN" HARNESS_REPO_ROOT="$MAIN" HARNESS_CFG_PATH="$SB/cfg.json" \
  HARNESS_STATE_DIR="$STATE" HARNESS_LOGIN=tester SWEEP_WORKTREE_ROOTS="$ROOT" \
  bash "$SUT" "$@" 2>&1
}
there() { [ -d "$ROOT/$1" ]; }

build_world() {
  for p in $PIDS; do kill "$p" 2>/dev/null; wait "$p" 2>/dev/null; done; PIDS=""
  rm -rf "$ROOT"/* "$SB/elsewhere"; G -C "$MAIN" worktree prune
  for b in $(G -C "$MAIN" for-each-ref --format='%(refname:short)' refs/heads | grep -v '^develop$'); do G -C "$MAIN" branch -qD "$b"; done
  add_wt 12619-any-name tkt-12619/a          # names the old glob never matched
  add_wt harness-spawn-0a1b2c                # detached, no number at all
  add_wt sh-5-claimed-ref tkt-5/a;  G -C "$MAIN" push -q origin develop:refs/claims/5 2>/dev/null
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

echo
[ "$fail" -eq 0 ] && echo "sweep-orphan-worktrees: all cases pass" || echo "sweep-orphan-worktrees: FAILURES above"
exit $fail
