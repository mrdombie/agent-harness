#!/usr/bin/env bash
# link-workspaces.sh — a worktree's own workspace packages must resolve to the
# worktree, not to the shared clone its node_modules is borrowed from.
#
# WHY: /claim symlinks the shared clone's node_modules into every worktree. npm
# links each workspace package there RELATIVELY (node_modules/@scope/pkg ->
# ../../packages/pkg), and a relative link resolves against where the link file
# really lives — the shared clone, whose working tree is never updated. So a
# package's tests in a fresh worktree imported the clone's copy of its sibling:
# measured 2026-10-02, every kit-card test failed with "parseThreadBlock is not
# a function", because the clone's copy predated that export. CI installs per
# checkout and never sees it, so a red local run looked like the change's fault.
set -uo pipefail
SUT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/link-workspaces.sh"
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "  ok   — $1"; }
fail() { FAIL=$((FAIL+1)); echo "  FAIL — $1"; }

T=$(cd "$(mktemp -d)" && pwd -P); trap 'rm -rf "$T"' EXIT
SHARED="$T/shared"; WT="$T/wt"

# The shared clone: a stale tree, with npm's relative workspace links.
mkdir -p "$SHARED/packages/core" "$SHARED/node_modules/@acme" "$SHARED/node_modules/leftpad"
printf 'module.exports = "STALE core"\n' > "$SHARED/packages/core/index.js"
printf '{"name":"@acme/core","main":"index.js"}\n' > "$SHARED/packages/core/package.json"
ln -s ../../packages/core "$SHARED/node_modules/@acme/core"
ln -s ../../apps/web      "$SHARED/node_modules/@acme/web"
ln -s ../packages/solo     "$SHARED/node_modules/solo"
ln -s ../../packages/ui    "$SHARED/node_modules/@acme/ui"
ln -s "$SHARED/packages/solo2" "$SHARED/node_modules/solo2"   # an absolute link
mkdir -p "$WT/packages/solo2"
ln -s ../../packages/ghost "$SHARED/node_modules/@acme/ghost"
printf 'module.exports = "leftpad"\n' > "$SHARED/node_modules/leftpad/index.js"

# The worktree: current sources, and the borrowed node_modules /claim gives it.
mkdir -p "$WT/packages/core" "$WT/packages/ui/src" "$WT/packages/solo" "$WT/apps/web"
printf 'module.exports = "CURRENT core"\n' > "$WT/packages/core/index.js"
printf '{"name":"@acme/core","main":"index.js"}\n' > "$WT/packages/core/package.json"
printf '{"name":"@acme/ui"}\n' > "$WT/packages/ui/package.json"
ln -s "$SHARED/node_modules" "$WT/node_modules"

resolve_from() { (cd "$1" && node -e 'console.log(require(process.argv[1]))' "$2" 2>/dev/null); }

echo "--- before: the worktree's ui imports the shared clone's stale core ---"
[ "$(resolve_from "$WT/packages/ui/src" @acme/core)" = "STALE core" ] \
  && ok "fixture reproduces the defect" || fail "fixture does not reproduce the stale import"

bash "$SUT" "$SHARED" "$WT" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 0 ] && ok "exits 0" || fail "exited $rc"

echo "--- after: every workspace imports its siblings from the worktree ---"
got=$(resolve_from "$WT/packages/ui/src" @acme/core)
[ "$got" = "CURRENT core" ] && ok "ui → worktree core" || fail "ui still resolves '$got'"
got=$(resolve_from "$WT/apps/web" @acme/core)
[ "$got" = "CURRENT core" ] && ok "apps/web → worktree core" || fail "apps/web resolves '$got'"
[ "$(readlink "$WT/packages/ui/node_modules/@acme/core")" = "$WT/packages/core" ] \
  && ok "the link names the worktree's package" || fail "link target is $(readlink "$WT/packages/ui/node_modules/@acme/core" 2>/dev/null)"
[ -L "$WT/packages/ui/node_modules/solo" ] && ok "unscoped workspace links too" || fail "unscoped workspace not linked"
[ "$(readlink "$WT/packages/ui/node_modules/solo2" 2>/dev/null)" = "$WT/packages/solo2" ] && ok "an absolute link is followed too" || fail "an absolute workspace link was missed"

echo "--- it leaves real dependencies and the shared clone alone ---"
[ "$(resolve_from "$WT/packages/ui/src" leftpad)" = "leftpad" ] && ok "a real dependency still resolves" || fail "a real dependency broke"
[ ! -e "$WT/packages/ui/node_modules/leftpad" ] && ok "real dependencies are not copied in" || fail "a real dependency was linked into the workspace"
[ "$(readlink "$SHARED/node_modules/@acme/core")" = "../../packages/core" ] && ok "the shared clone is untouched" || fail "the shared clone's link changed"
[ ! -e "$SHARED/packages/ui" ] && ok "nothing written into the shared clone" || fail "wrote into the shared clone"

echo "--- a workspace the worktree does not have is skipped, not invented ---"
[ ! -e "$WT/packages/ghost" ] && ok "no directory invented" || fail "invented a workspace directory"

echo "--- idempotent ---"
bash "$SUT" "$SHARED" "$WT" >/dev/null 2>&1 && [ "$(resolve_from "$WT/packages/ui/src" @acme/core)" = "CURRENT core" ] \
  && ok "a second run changes nothing" || fail "a second run broke resolution"

echo "--- /claim runs it right after borrowing node_modules ---"
CLAIM="$(dirname "$SUT")/../skills/claim/SKILL.md"
grep -q 'scripts/link-workspaces.sh" "$REPO_PATH" "$WORKTREE"' "$CLAIM" && ok "claim Step 6 calls it" || fail "claim Step 6 does not call link-workspaces.sh"

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
