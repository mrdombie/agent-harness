#!/usr/bin/env bash
# Fixture test for worktree-cache.sh — the build caches a worktree keeps.
#
# A ticket worktree is about 4.3 GB, 4.2 of it build output, and nothing ever
# removed it from a worktree that was kept: the disk filled twice in one day.
# Each case below plants the thing a guard exists for and asserts what is left
# on disk, not what the script printed.
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/tests/lib/suite.sh" || exit 1
for v in $(env | sed -n 's/^\(GIT_[A-Z_]*\)=.*/\1/p'); do unset "$v"; done
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUT="$HERE/worktree-cache.sh"
[ -f "$SUT" ] || { echo "missing $SUT"; exit 2; }

SB=$(mktemp -d); SB=$(cd "$SB" && pwd -P)
PIDS=""
cleanup() { for p in $PIDS; do kill "$p" 2>/dev/null; wait "$p" 2>/dev/null; done; rm -rf "$SB"; }
on_exit_keep_status cleanup
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
# The claims: origin's refs and the claim list, each a planted file; a missing file is unreadable.
mkdir -p "$SB/bin" "$SB/state/runs"; printf '[]\n' > "$SB/claims.json"; : > "$SB/claim-refs.txt"
printf '#!/usr/bin/env bash\ncat "$WC_CLAIMS_JSON"\n' > "$SB/bin/claimlist"
printf '#!/usr/bin/env bash\ncat "$WC_CLAIM_REFS"\n' > "$SB/bin/claimrefs"
chmod +x "$SB/bin/claimlist" "$SB/bin/claimrefs"
export WT_CLAIM_LIST="$SB/bin/claimlist" WT_CLAIM_REFS="$SB/bin/claimrefs" \
  WC_CLAIMS_JSON="$SB/claims.json" WC_CLAIM_REFS="$SB/claim-refs.txt" STATE_DIR="$SB/state"
run() { HARNESS_CFG_PATH="${CFG:-$SB/none.json}" bash "${WC_SUT:-$SUT}" "$@" 2>&1; }

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

# --- 9. the disk guard's deep pass: only a truly idle tree loses its node_modules ----------
# A claimed build lost its node_modules to an idle-only test.
deep_world() {
  rm -rf "$SB/deep"; mkdir -p "$SB/deep"
  for n in sh-13621-claimed listed-elsewhere busy fresh idle held; do
    mk_tree "$SB/deep/$n"; mkdir -p "$SB/deep/$n/node_modules/pkg"; printf 'x\n' > "$SB/deep/$n/node_modules/pkg/i.js"
    old "$SB/deep/$n"
  done
  printf 'abc\trefs/claims/13621\n' > "$SB/claim-refs.txt"
  # Another host's claim naming this tree by its path, the folder carrying no ticket number.
  jq -n --arg w "$SB/deep/listed-elsewhere" '[{issue: 4242, worktree: $w, branch: "tkt-4242/x", host: "other-mac"}]' > "$SB/claims.json"
  touch "$SB/deep/fresh/apps/web/src/page.ts"
  rm -f "$SB/state/runs"/*; printf '{"pid": %s}\n' "$$" > "$SB/state/runs/r1.json"; printf '%s\n' "$SB/deep/held" > "$SB/state/runs/r1.worktrees"
}
nm() { [ -d "$SB/deep/$1/node_modules" ]; }
deep_world; sit_in "$SB/deep/busy"
out=$(run clean --deep --idle-min 30 "$SB/deep"/*)
nm idle && bad "the idle tree kept its node_modules: $out" || ok "a truly idle tree loses its node_modules"
nm sh-13621-claimed && ok "a tree whose ticket holds a claim on origin keeps them" || bad "a claimed tree lost its node_modules"
printf '%s' "$out" | grep -q 'sh-13621-claimed — claim #13621' && ok "  and says which claim" || bad "  no claim reason: $out"
nm listed-elsewhere && ok "a tree another host's claim names by path keeps them" || bad "a tree claimed by path lost its node_modules"
nm busy && ok "a tree with a live process keeps them" || bad "a tree in use lost its node_modules"
nm fresh && ok "a tree changed in the last 30 min keeps them" || bad "a recently touched tree lost its node_modules"
nm held && ok "a tree a live run's record names keeps them" || bad "a run-held tree lost its node_modules"
[ -d "$SB/deep/sh-13621-claimed/apps/web/.next" ] && ok "  and a claimed tree keeps its build caches too" || bad "a claimed tree lost its build cache"

deep_world; rm -f "$SB/claims.json"
out=$(run clean --deep --idle-min 30 "$SB/deep"/*)
nm idle && ok "with the claim list unreadable, nothing is cleaned, not even the idle tree" || bad "it cleaned with the claim list unreadable: $out"
printf '%s' "$out" | grep -q 'claim list could not be read' && ok "  and says why" || bad "  no reason: $out"
deep_world; rm -f "$SB/claim-refs.txt"
out=$(run clean --deep --idle-min 30 "$SB/deep"/*)
nm idle && ok "with origin's claim refs unreadable, nothing is cleaned" || bad "it cleaned with the claim refs unreadable: $out"

# A find that errors (bfs on a timestamp it rejects) is no proof of idleness.
deep_world; printf '[]\n' > "$SB/claims.json"; : > "$SB/claim-refs.txt"
printf '#!/usr/bin/env bash\necho "find: bad timestamp" >&2; exit 1\n' > "$SB/bin/find"; chmod +x "$SB/bin/find"
out=$(PATH="$SB/bin:$PATH" run clean --deep --idle-min 30 "$SB/deep/idle")
nm idle && ok "a recency test that errors keeps the tree" || bad "a failing find let the idle test pass: $out"
rm -f "$SB/bin/find"

# Plant the absence: in a copy of the scripts, each rule deleted loses the tree it alone keeps.
mkdir -p "$SB/kit"; cp "$HERE/worktree-cache.sh" "$HERE/worktree-lib.sh" "$SB/kit/"
cat > "$SB/plant.py" <<'PY'
import sys
p, t = sys.argv[1], sys.argv[2]
s = open(p).read()
assert s.count(t) == 1, "text not found once"
open(p, "w").write(s.replace(t, "", 1))
PY
plant() { # <label> <file> <exact text> <tree that must then lose node_modules | unreadable>
  cp "$SB/kit/$2" "$SB/plant.bak"
  python3 -I "$SB/plant.py" "$SB/kit/$2" "$3" || { bad "plant did not land: $1"; cp "$SB/plant.bak" "$SB/kit/$2"; return; }
  if grep -qF -- "$3" "$SB/kit/$2"; then bad "plant did not land: $1"; cp "$SB/plant.bak" "$SB/kit/$2"; return; fi
  deep_world; [ "$4" = unreadable ] && rm -f "$SB/claims.json"
  WC_SUT="$SB/kit/worktree-cache.sh" run clean --deep --idle-min 30 "$SB/deep"/* >/dev/null
  local t="$4"; [ "$t" = unreadable ] && t=idle
  nm "$t" && bad "planted ($1): $t kept its node_modules, so this suite cannot see the rule" \
           || ok "planted ($1): $t loses its node_modules, so the rule is what kept it"
  cp "$SB/plant.bak" "$SB/kit/$2"
}
plant "claim by ticket"   worktree-lib.sh   "$(grep -F 'case "$WT_CLAIM_NUMS" in' "$HERE/worktree-lib.sh")" sh-13621-claimed
plant "claim by path"     worktree-lib.sh   "$(grep -F '[ -n "$cw" ] && wt_nested' "$HERE/worktree-lib.sh")" listed-elsewhere
plant "recent tree"       worktree-cache.sh "$(grep -F 'if [ "$IDLE" -gt 0 ] && wt_recent "$real"' "$HERE/worktree-cache.sh")" fresh
plant "claimed tree kept" worktree-cache.sh "$(grep -F '[ "$crc" = 0 ] &&' "$HERE/worktree-cache.sh")" sh-13621-claimed
plant "unreadable kept"   worktree-cache.sh "$(grep -F '[ "$crc" = 2 ] &&' "$HERE/worktree-cache.sh")" unreadable
plant "run record"        worktree-cache.sh "$(grep -F 'wt_run_holder "$real"' "$HERE/worktree-cache.sh")" held
diff -q "$HERE/worktree-cache.sh" "$SB/kit/worktree-cache.sh" >/dev/null && diff -q "$HERE/worktree-lib.sh" "$SB/kit/worktree-lib.sh" >/dev/null \
  && ok "the planted copies are restored" || bad "a planted copy was not restored"

echo
[ "$fail" -eq 0 ] && echo "worktree-cache: all cases pass" || echo "worktree-cache: FAILURES above"
suite_end "$fail"
