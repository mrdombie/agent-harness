#!/usr/bin/env bash
# Fixture test for worktree-cache.sh — the build caches a worktree keeps.
#
# A ticket worktree is about 4.3 GB, 4.2 of it build output, and nothing ever
# removed it from a worktree that was kept: the disk filled twice in one day.
# Each case below plants the thing a guard exists for and asserts what is left
# on disk, not what the script printed.
set -uo pipefail
for v in $(env | sed -n 's/^\(GIT_[A-Z_]*\)=.*/\1/p'); do unset "$v"; done
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUT="$HERE/worktree-cache.sh"
[ -f "$SUT" ] || { echo "missing $SUT"; exit 2; }

SB=$(mktemp -d); SB=$(cd "$SB" && pwd -P)
PIDS=""
cleanup() { for p in $PIDS; do kill "$p" 2>/dev/null; wait "$p" 2>/dev/null; done; rm -rf "$SB"; }
trap cleanup EXIT
fail=0
ok()  { echo "  ok   — $1"; }
bad() { echo "  FAIL — $1"; fail=1; }
G() { git -c user.email=t@example.com -c user.name=tester -c commit.gpgsign=false -c init.defaultBranch=main "$@"; }

# A checkout with build output in the framework's usual places, all untracked.
mk_tree() { # <dir>
  local d="$1"
  mkdir -p "$d/apps/web/src" "$d/apps/web/.next/cache" "$d/apps/api/.next" "$d/.turbo"
  printf 'src\n' > "$d/apps/web/src/page.ts"
  printf '.next\n.turbo\n' > "$d/.gitignore"
  G init -q "$d"; G -C "$d" add -A; G -C "$d" commit -qm base
  head -c 2048 /dev/zero > "$d/apps/web/.next/cache/blob"
  printf 'x\n' > "$d/apps/api/.next/server.js"
  printf 'x\n' > "$d/.turbo/log"
}
# Waits until lsof sees the process in the folder: a fixed sleep raced it under load.
sit_in() { # <dir> — a process sitting in <dir>, until the suite ends
  (cd "$1" && exec sleep 300) & PIDS="$PIDS $!"
  local p=$! real; real=$(cd "$1" && pwd -P)
  for _ in $(seq 1 100); do
    lsof -a -p "$p" -d cwd -Fn 2>/dev/null | grep -qxF "n$real" && return 0
    sleep 0.1
  done
}
old() { find "$1" -exec touch -t 202001010000 {} + ; }   # nothing in it changed for years
run() { HARNESS_CFG_PATH="${CFG:-$SB/none.json}" bash "$SUT" "$@" 2>&1; }

echo "worktree-cache fixture"

# --- 1. the framework's usual folders go, the source stays --------------------
WT="$SB/wt1"; mk_tree "$WT"; old "$WT"
out=$(run clean "$WT")
[ ! -e "$WT/apps/web/.next" ] && [ ! -e "$WT/apps/api/.next" ] && [ ! -e "$WT/.turbo" ] \
  && ok "every default cache folder is removed" || bad "a default cache folder survived: $out"
[ -f "$WT/apps/web/src/page.ts" ] && ok "source next to it is untouched" || bad "source was removed"
[ -z "$(G -C "$WT" status --porcelain)" ] && ok "the tree is still clean" || bad "the tree changed: $(G -C "$WT" status --porcelain)"
printf '%s' "$out" | grep -q 'cleaned apps/web/.next' && ok "it names what it removed" || bad "no line names the removal: $out"

# --- 2. a cache folder holding a tracked file is never touched ----------------
WT="$SB/wt2"; mk_tree "$WT"
mkdir -p "$WT/apps/api/.next"; printf 'keep\n' > "$WT/apps/api/.next/committed.txt"
G -C "$WT" add -f apps/api/.next/committed.txt; G -C "$WT" commit -qm tracked
old "$WT"
out=$(run clean "$WT")
[ -f "$WT/apps/api/.next/committed.txt" ] && ok "a tracked file inside a cache folder survives" \
  || bad "a tracked file was deleted"
[ -f "$WT/apps/api/.next/server.js" ] && ok "and so does the folder holding it" || bad "the folder with a tracked file was emptied"
[ ! -e "$WT/apps/web/.next" ] && ok "the untracked sibling cache still goes" || bad "the untracked sibling stayed: $out"

# --- 3. a live process in the worktree keeps every cache ---------------------
WT="$SB/wt3"; mk_tree "$WT"; old "$WT"
sit_in "$WT/apps/web"
out=$(run clean "$WT")
[ -d "$WT/apps/web/.next" ] && [ -d "$WT/.turbo" ] && ok "a worktree a process is sitting in keeps its caches" \
  || bad "caches were removed under a live process: $out"
printf '%s' "$out" | grep -q 'in use' && ok "and it says the worktree is in use" || bad "no in-use reason: $out"

# --- 4. idle mode: a cache written to recently stays -------------------------
WT="$SB/wt4"; mk_tree "$WT"; old "$WT"
printf 'fresh\n' > "$WT/apps/web/.next/cache/fresh"     # written now
out=$(run clean --idle-min 30 "$WT")
[ -f "$WT/apps/web/.next/cache/fresh" ] && ok "a cache changed within the idle window stays" \
  || bad "a cache written seconds ago was removed: $out"
[ ! -e "$WT/apps/api/.next" ] && ok "an idle cache in the same worktree goes" || bad "the idle cache stayed: $out"

# --- 5. configured folders replace the defaults -------------------------------
WT="$SB/wt5"; mk_tree "$WT"; mkdir -p "$WT/build/tmp"; printf 'x\n' > "$WT/build/tmp/o"; old "$WT"
printf '{"build":{"cacheDirs":["build/tmp"]}}\n' > "$SB/cfg.json"
CFG="$SB/cfg.json" run clean "$WT" >/dev/null
[ ! -e "$WT/build/tmp" ] && ok "a configured cache folder is removed" || bad "the configured folder stayed"
[ -d "$WT/apps/web/.next" ] && ok "the defaults are not used when folders are configured" || bad "a default was removed despite config"

# --- 6. a symlinked cache is not followed out of the worktree -----------------
WT="$SB/wt6"; mk_tree "$WT"; rm -rf "$WT/apps/web/.next"
mkdir -p "$SB/shared/.next"; printf 'shared\n' > "$SB/shared/.next/x"
ln -s "$SB/shared/.next" "$WT/apps/web/.next"; old "$WT"
run clean "$WT" >/dev/null
[ -f "$SB/shared/.next/x" ] && ok "a cache symlinked outside the worktree is left alone" || bad "a shared cache was deleted through a link"
[ -L "$WT/apps/web/.next" ] && ok "and the link to it stays in place" || bad "the link to a shared cache was removed"

# --- 7. a path that is not a checkout's top level is refused ------------------
# The in-use check is scoped to the path given, so a subfolder would miss
# somebody sitting elsewhere in the same worktree.
WT="$SB/wt7"; mk_tree "$WT"; old "$WT"
sit_in "$WT/apps/api"
out=$(run clean "$WT/apps/web")
[ -d "$WT/apps/web/.next" ] && ok "a subfolder of a checkout is not cleaned on its own" \
  || bad "a subfolder was cleaned while its worktree was in use: $out"

# --- 7b. run from inside the worktree, as /finish and a park do ---------------
WT="$SB/wt7b"; mk_tree "$WT"; old "$WT"
out=$(cd "$WT/apps/web" && HARNESS_CFG_PATH="$SB/none.json" bash "$SUT" clean "$WT" 2>&1)
[ ! -e "$WT/apps/web/.next" ] && ok "the caller sitting in its own worktree does not count as using it" \
  || bad "a cleanup run from inside the worktree refused itself: $out"

# --- 8. dry run removes nothing ------------------------------------------------
WT="$SB/wt8"; mk_tree "$WT"; old "$WT"
out=$(run clean --dry-run "$WT")
[ -d "$WT/apps/web/.next" ] && ok "dry run removes nothing" || bad "dry run removed a cache"
printf '%s' "$out" | grep -q 'would clean apps/web/.next' && ok "and says what it would remove" || bad "dry run printed: $out"

echo
[ "$fail" -eq 0 ] && echo "worktree-cache: all cases pass" || echo "worktree-cache: FAILURES above"
exit $fail
