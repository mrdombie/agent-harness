#!/usr/bin/env bash
# Fixture test for worktree-sparse.sh — agent worktrees that leave configured folders out.
set -uo pipefail
for v in $(env | sed -n 's/^\(GIT_[A-Z_]*\)=.*/\1/p'); do unset "$v"; done
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUT="$HERE/worktree-sparse.sh"
[ -f "$SUT" ] || { echo "missing $SUT"; exit 2; }

SB=$(mktemp -d); SB=$(cd "$SB" && pwd -P)
trap 'rm -rf "$SB"' EXIT
fail=0
ok()  { echo "  ok   — $1"; }
bad() { echo "  FAIL — $1"; fail=1; }
G() { git -c user.email=t@example.com -c user.name=tester -c commit.gpgsign=false -c init.defaultBranch=develop "$@"; }

REPO="$SB/repo"
mkdir -p "$REPO/docs/evidence/1" "$REPO/src"
printf 'png\n' > "$REPO/docs/evidence/1/a.png"; printf '{}\n' > "$REPO/docs/evidence/1/plan.json"; printf 'doc\n' > "$REPO/docs/readme.md"; printf 'c\n' > "$REPO/src/c.ts"
G init -q "$REPO"; G -C "$REPO" add -A; G -C "$REPO" commit -qm base
printf '{"worktree":{"sparseExclude":["docs/evidence"]}}\n' > "$SB/on.json"
printf '{"worktree":{}}\n' > "$SB/off.json"
add() { HARNESS_CFG_PATH="$1" bash "$SUT" add "$REPO" "${@:2}" 2>&1; }
flag() { bash "$SUT" add-flag "$1"; }

echo "worktree-sparse fixture"

# --- 1. off by default: a full checkout ----------------------------------------
out=$(add "$SB/off.json" "$SB/wt-off" -b t-off develop)
[ -f "$SB/wt-off/docs/evidence/1/a.png" ] && ok "with nothing configured the worktree is a full checkout" || bad "an unconfigured worktree is missing files: $out"
[ -z "$(flag "$SB/wt-off")" ] && ok "and needs no --sparse to stage" || bad "add-flag printed '$(flag "$SB/wt-off")' for a full checkout"

# --- 2. configured: the folder is left out, everything else is there -----------
out=$(add "$SB/on.json" "$SB/wt-on" -b t-on develop)
[ ! -e "$SB/wt-on/docs/evidence" ] && ok "the excluded folder is not checked out" || bad "the excluded folder was checked out: $out"
[ -f "$SB/wt-on/docs/readme.md" ] && [ -f "$SB/wt-on/src/c.ts" ] && ok "every other file is" || bad "a file outside the exclusion is missing"
[ "$(G -C "$SB/wt-on" symbolic-ref --short HEAD)" = t-on ] && ok "the worktree is on the branch it was asked for" || bad "wrong branch"
[ -z "$(G -C "$SB/wt-on" status --porcelain)" ] && ok "and it reads as clean" || bad "the sparse tree reads dirty: $(G -C "$SB/wt-on" status --porcelain)"
[ "$(G -C "$SB/wt-on" ls-files docs/evidence | wc -l | tr -d ' ')" = 2 ] && ok "the left-out files are still tracked, not deleted" || bad "the excluded files left the index"
[ -f "$REPO/docs/evidence/1/a.png" ] && [ -z "$(G -C "$REPO" config --get core.sparseCheckout)" ] \
  && ok "the main checkout stays full and is not made sparse" || bad "the main checkout was changed"

# --- 3. a new shot in the excluded folder still commits --------------------------
mkdir -p "$SB/wt-on/docs/evidence/2"; printf 'new\n' > "$SB/wt-on/docs/evidence/2/b.png"
G -C "$SB/wt-on" add $(flag "$SB/wt-on") docs/evidence/2/b.png 2>/dev/null
G -C "$SB/wt-on" commit -qm shot 2>/dev/null
[ "$(G -C "$SB/wt-on" show --name-only --format= HEAD)" = docs/evidence/2/b.png ] \
  && ok "a new file in the excluded folder is staged with the flag add-flag prints" || bad "the new shot did not reach the commit"

# --- 4. a folder git would not let it exclude is refused, not widened ----------
printf '{"worktree":{"sparseExclude":["../up","/abs"]}}\n' > "$SB/bad.json"
out=$(add "$SB/bad.json" "$SB/wt-bad" --detach develop)
[ -f "$SB/wt-bad/docs/evidence/1/a.png" ] && ok "patterns that leave the worktree are ignored" || bad "a bad pattern changed the checkout: $out"
printf '%s' "$out" | grep -q "ignoring '../up'" && ok "and named" || bad "the bad pattern was not named: $out"

# --- 5. a file pattern leaves out only the files it names ------------------------
printf '{"worktree":{"sparseExclude":["docs/evidence/**/*.png"]}}\n' > "$SB/glob.json"
out=$(add "$SB/glob.json" "$SB/wt-glob" --detach develop)
[ ! -e "$SB/wt-glob/docs/evidence/1/a.png" ] && ok "a file pattern leaves its files out" || bad "the pattern's files were checked out: $out"
[ -f "$SB/wt-glob/docs/evidence/1/plan.json" ] && ok "and keeps the other files in the same folder" || bad "a file the pattern does not name was left out: $out"
[ -z "$(G -C "$SB/wt-glob" status --porcelain)" ] && ok "and reads as clean" || bad "the patterned tree reads dirty"

echo
[ "$fail" -eq 0 ] && echo "worktree-sparse: all cases pass" || echo "worktree-sparse: FAILURES above"
exit $fail
