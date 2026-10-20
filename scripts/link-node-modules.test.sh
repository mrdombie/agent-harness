#!/usr/bin/env bash
# link-node-modules.test.sh — a worktree's workspace packages resolve to the
# worktree, and everything else still resolves through the shared install.
#
# Builds the real layout on disk (a shared clone with an install, a worktree of
# it) and runs the real script, because the defect was entirely in what the
# filesystem answered: one symlink to the shared node_modules carried the shared
# checkout's workspace links, so `@acme/contracts/<new-subpath>` resolved into a
# stale copy, and a dep left in `packages/ui/node_modules` resolved nowhere.
#
# Run: bash "$0"
set -uo pipefail
SCRIPT="$(cd "$(dirname "$0")" && pwd)/link-node-modules.sh"

FIX=$(mktemp -d); trap 'rm -rf "$FIX"' EXIT
FIX=$(cd "$FIX" && pwd -P)
FAILED=0
ok()   { printf 'OK       %s\n' "$1"; }
bad()  { printf 'MISMATCH %s\n' "$1"; FAILED=1; }
want() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 — wanted '$2', got '$3'"; fi; }
real() { (cd "$1" 2>/dev/null && pwd -P) || echo "unresolved"; }

pkg() { # <dir> <name>
  mkdir -p "$1"; printf '{"name":"%s","version":"0.0.0"}\n' "$2" > "$1/package.json"
}

# A shared clone: root manifest with workspaces, an install whose workspace links
# point at the SHARED checkout, a third-party package under the workspace scope,
# a dep left inside one workspace, and dot entries (.bin, the npm lock).
build_shared() { # <dir>
  local s=$1
  printf '{"name":"root","private":true,"workspaces":["apps/*","packages/*","!packages/ignored"]}\n' > "$s/package.json"
  pkg "$s/apps/web" "@acme/web"; pkg "$s/packages/ui" "@acme/ui"; pkg "$s/packages/contracts" "@acme/contracts"
  pkg "$s/packages/plain" "plainpkg"
  mkdir -p "$s/node_modules/@acme" "$s/node_modules/left-pad" "$s/node_modules/@types/node" \
           "$s/node_modules/.bin" "$s/packages/ui/node_modules/@formkit/auto-animate" \
           "$s/packages/ui/node_modules/@acme"
  ln -s ../../apps/web "$s/node_modules/@acme/web"
  ln -s ../../packages/ui "$s/node_modules/@acme/ui"
  ln -s ../../packages/contracts "$s/node_modules/@acme/contracts"
  ln -s ../packages/plain "$s/node_modules/plainpkg"
  mkdir -p "$s/node_modules/@acme/published-thing"     # in the scope, not a workspace
  printf '{}\n' > "$s/node_modules/.package-lock.json"
}

SH="$FIX/shared"; WT="$FIX/wt"
mkdir -p "$SH" "$WT"; build_shared "$SH"
# The worktree: same workspaces plus one the shared clone has not got yet, and
# one excluded by a negation.
printf '{"name":"root","private":true,"workspaces":["apps/*","packages/*","!packages/ignored"]}\n' > "$WT/package.json"
pkg "$WT/apps/web" "@acme/web"; pkg "$WT/packages/ui" "@acme/ui"; pkg "$WT/packages/contracts" "@acme/contracts"
pkg "$WT/packages/plain" "plainpkg"; pkg "$WT/packages/brand-new" "@acme/brand-new"; pkg "$WT/packages/ignored" "@acme/ignored"
before=$(cd "$SH" && find . | sort | shasum)

echo "--- a fresh worktree ---"
out=$(bash "$SCRIPT" "$SH" "$WT" 2>&1); rc=$?
want "exits 0" 0 "$rc"
want "node_modules is a real directory" "dir" "$([ -d "$WT/node_modules" ] && [ ! -L "$WT/node_modules" ] && echo dir || echo link)"
want "the workspace scope is a real directory" "dir" "$([ -d "$WT/node_modules/@acme" ] && [ ! -L "$WT/node_modules/@acme" ] && echo dir || echo link)"
want "@acme/contracts → the worktree's packages/contracts" "$WT/packages/contracts" "$(real "$WT/node_modules/@acme/contracts")"
want "@acme/ui → the worktree's packages/ui" "$WT/packages/ui" "$(real "$WT/node_modules/@acme/ui")"
want "a workspace the shared clone lacks still links" "$WT/packages/brand-new" "$(real "$WT/node_modules/@acme/brand-new")"
want "an unscoped workspace links home" "$WT/packages/plain" "$(real "$WT/node_modules/plainpkg")"
want "a negated workspace is not linked" "absent" "$([ -e "$WT/node_modules/@acme/ignored" ] && echo present || echo absent)"
want "a published package in the scope links through" "$SH/node_modules/@acme/published-thing" "$(real "$WT/node_modules/@acme/published-thing")"
want "a third-party package links through" "$SH/node_modules/left-pad" "$(real "$WT/node_modules/left-pad")"
want "another scope links through whole" "$SH/node_modules/@types" "$(real "$WT/node_modules/@types")"
want ".bin links through" "$SH/node_modules/.bin" "$(real "$WT/node_modules/.bin")"
want "the npm lock links through" "yes" "$([ "$WT/node_modules/.package-lock.json" -ef "$SH/node_modules/.package-lock.json" ] && echo yes || echo no)"
want "a dep left inside a workspace resolves from the worktree's copy of it" "$SH/packages/ui/node_modules/@formkit/auto-animate" "$(real "$WT/packages/ui/node_modules/@formkit/auto-animate")"
want "…but the workspace scope there is not mirrored" "absent" "$([ -e "$WT/packages/ui/node_modules/@acme" ] && echo present || echo absent)"
want "the shared clone was not written to" "$before" "$(cd "$SH" && find . | sort | shasum)"

echo "--- re-run is idempotent ---"
bash "$SCRIPT" "$SH" "$WT" >/dev/null 2>&1; rc=$?
want "exits 0" 0 "$rc"
want "@acme/contracts still home" "$WT/packages/contracts" "$(real "$WT/node_modules/@acme/contracts")"
want "left-pad still through" "$SH/node_modules/left-pad" "$(real "$WT/node_modules/left-pad")"

echo "--- a scope that stops being a workspace scope links through again ---"
WT5="$FIX/wt5"; cp -R "$WT" "$WT5"; rm -rf "$WT5/node_modules" "$WT5/packages/ui/node_modules"
bash "$SCRIPT" "$SH" "$WT5" >/dev/null 2>&1
# the branch renames every workspace out of @acme
for f in "$WT5"/apps/*/package.json "$WT5"/packages/*/package.json; do sed -i.bak 's/"@acme\//"@other\//' "$f" && rm -f "$f.bak"; done
bash "$SCRIPT" "$SH" "$WT5" >/dev/null 2>&1; rc=$?
want "exits 0" 0 "$rc"
want "@acme is the shared scope again" "$SH/node_modules/@acme" "$(real "$WT5/node_modules/@acme")"
want "…and holds nothing nested inside it" "absent" "$([ -e "$SH/node_modules/@acme/@acme" ] && echo present || echo absent)"
want "@other/contracts → the worktree" "$WT5/packages/contracts" "$(real "$WT5/node_modules/@other/contracts")"

echo "--- the old single symlink is converted ---"
WT2="$FIX/wt2"; cp -R "$WT" "$WT2"; rm -rf "$WT2/node_modules" "$WT2/packages/ui/node_modules"
ln -s "$SH/node_modules" "$WT2/node_modules"
# what the per-workspace shadowing step left behind in the old layout
mkdir -p "$WT2/apps/web/node_modules/@acme"; ln -s "$WT2/packages/ui" "$WT2/apps/web/node_modules/@acme/ui"
bash "$SCRIPT" "$SH" "$WT2" >/dev/null 2>&1; rc=$?
want "exits 0" 0 "$rc"
want "the symlink became a directory" "dir" "$([ -d "$WT2/node_modules" ] && [ ! -L "$WT2/node_modules" ] && echo dir || echo link)"
want "@acme/contracts → wt2" "$WT2/packages/contracts" "$(real "$WT2/node_modules/@acme/contracts")"
want "the shared clone was not written to" "$before" "$(cd "$SH" && find . | sort | shasum)"

echo "--- a real install is left alone ---"
WT3="$FIX/wt3"; cp -R "$WT" "$WT3"; rm -rf "$WT3/node_modules"; mkdir -p "$WT3/node_modules/react"
out=$(bash "$SCRIPT" "$SH" "$WT3" 2>&1); rc=$?
want "exits 0" 0 "$rc"
want "react untouched, nothing linked" "react" "$(ls -A "$WT3/node_modules")"

echo "--- no shared install: nothing to do ---"
WT4="$FIX/wt4"; mkdir -p "$FIX/empty" "$WT4"
bash "$SCRIPT" "$FIX/empty" "$WT4" >/dev/null 2>&1; rc=$?
want "exits 0" 0 "$rc"
want "creates nothing" "absent" "$([ -e "$WT4/node_modules" ] && echo present || echo absent)"

# --- the guards, each planted dead in a copy of the script ---
plant() { # <label> <old> <new> [<old> <new>…] — every anchor must match exactly once
  local p="$FIX/planted.sh" label=$1; shift
  python3 - "$SCRIPT" "$p" "$@" <<'PY' || { bad "$label — the plant did not apply" >&2; echo planted-nothing; return; }
import sys
src, dst, *pairs = sys.argv[1:]
s = open(src).read()
for old, new in zip(pairs[::2], pairs[1::2]):
    assert s.count(old) == 1, f"anchor matched {s.count(old)} times"
    s = s.replace(old, new)
open(dst, "w").write(s)
PY
  local w="$FIX/plant-wt"; rm -rf "$w" "$FIX/plant-sh"; mkdir -p "$FIX/plant-sh" "$w"
  build_shared "$FIX/plant-sh"; cp "$WT/package.json" "$w/"; cp -R "$WT/apps" "$WT/packages" "$w/"
  rm -rf "$w/node_modules" "$w"/packages/*/node_modules "$w"/apps/*/node_modules
  bash "$p" "$FIX/plant-sh" "$w" >"$FIX/plant.out" 2>&1; echo $?
}
echo "--- plant: the workspace links are never made → refused ---"
want "exits 1" 1 "$(plant "no workspace links" '  link "$WT/$dir" "$WT/node_modules/$name"' '  :')"
want "…refused by the resolution check, for all 5 workspaces" "5" "$(grep -c 'does not resolve to' "$FIX/plant.out")"
echo "--- plant: the scope stays a link into the shared clone → refused ---"
want "exits 1" 1 "$(plant "linked scope" '    owned "$name" && continue
    link "$e" "$dst/$name"' '    link "$e" "$dst/$name"' '  [ -L "$WT/node_modules/$scope" ] && rm -f "$WT/node_modules/$scope"' '  :')"
want "…refused by the scope check" "1" "$(grep -c 'is not this worktree' "$FIX/plant.out")"
echo "--- plant: workspace node_modules not mirrored → the nested dep is gone ---"
plant "no mirror" '    link_entries "$SHARED_REPO/$dir/node_modules" "$WT/$dir/node_modules"' '    :' >/dev/null
want "the nested dep no longer resolves (so the mirror assertion above is live)" "unresolved" "$(real "$FIX/plant-wt/packages/ui/node_modules/@formkit/auto-animate")"

echo "--- a lockfile that differs from the shared one gets the worktree's own install ---"
LW="$FIX/lock-wt"; LS="$FIX/lock-sh"; mkdir -p "$LW" "$LS"; build_shared "$LS"
printf '{"lockfileVersion":3,"packages":{"node_modules/left-pad":{"version":"1.0.0"}}}\n' > "$LS/package-lock.json"
cp "$LS/package.json" "$LW/package.json"; pkg "$LW/packages/ui" "@acme/ui"
cp "$LS/package-lock.json" "$LW/package-lock.json"
bash "$SCRIPT" "$LS" "$LW" >/dev/null 2>&1
want "same lockfile: linked from the shared install" "yes" "$([ -f "$LW/node_modules/.linked-from-shared-install" ] && echo yes || echo no)"
printf '{"lockfileVersion":3,"packages":{"node_modules/left-pad":{"version":"2.0.0"}}}\n' > "$LW/package-lock.json"
shared_before=$(cd "$LS" && find . | sort | shasum)
out=$(LINK_NODE_MODULES_INSTALL='mkdir -p node_modules/left-pad' bash "$SCRIPT" "$LS" "$LW" 2>&1); rc=$?
want "differing lockfile: exits 0" 0 "$rc"
want "…the links are gone" "no" "$([ -f "$LW/node_modules/.linked-from-shared-install" ] && echo yes || echo no)"
want "…its own install ran in the worktree" "dir" "$([ -d "$LW/node_modules/left-pad" ] && [ ! -L "$LW/node_modules/left-pad" ] && echo dir || echo other)"
want "…and says why" "yes" "$(printf "%s" "$out" | grep -q "differs from" && echo yes || echo no)"
want "…the shared clone is untouched" "$shared_before" "$(cd "$LS" && find . | sort | shasum)"
out=$(LINK_NODE_MODULES_INSTALL='touch ran-again' bash "$SCRIPT" "$LS" "$LW" 2>&1)
want "an own install already there is left alone" "no" "$([ -e "$LW/ran-again" ] && echo yes || echo no)"
rm -rf "$LW/node_modules"
out=$(LINK_NODE_MODULES_INSTALL='false' bash "$SCRIPT" "$LS" "$LW" 2>&1); rc=$?
want "a failed own install exits 1" 1 "$rc"

echo "--- the fingerprint: --if-stale rebuilds only when the manifests moved ---"
FW="$FIX/fp-wt"; FS="$FIX/fp-sh"; mkdir -p "$FW" "$FS"; build_shared "$FS"
printf '{"lockfileVersion":3,"packages":{"node_modules/left-pad":{"version":"1.0.0"}}}\n' > "$FS/package-lock.json"
cp "$FS/package.json" "$FS/package-lock.json" "$FW/"; pkg "$FW/packages/ui" "@acme/ui"
bash "$SCRIPT" "$FS" "$FW" >/dev/null 2>&1
want "a linked install carries a 'linked' fingerprint" "linked" "$(cut -d' ' -f1 "$FW/node_modules/.harness-link-stamp" 2>/dev/null)"
want "…a sha256" "64" "$(cut -d' ' -f2 "$FW/node_modules/.harness-link-stamp" 2>/dev/null | tr -d '\n' | wc -c | tr -d ' ')"
rm -f "$FW/node_modules/left-pad"                       # the planted absence
out=$(bash "$SCRIPT" --if-stale "$FS" "$FW" 2>&1); rc=$?
want "unchanged manifests: exits 0" 0 "$rc"
want "…says it is up to date" "yes" "$(printf '%s' "$out" | grep -q 'up to date' && echo yes || echo no)"
want "…and relinks nothing" "absent" "$([ -e "$FW/node_modules/left-pad" ] && echo present || echo absent)"
# The trunk adds a package: both lockfiles move together, the shared clone installs it.
printf '{"lockfileVersion":3,"packages":{"node_modules/left-pad":{"version":"1.0.0"},"node_modules/@axe-core/playwright":{"version":"4.0.0"}}}\n' > "$FS/package-lock.json"
mkdir -p "$FS/node_modules/@axe-core/playwright"; cp "$FS/package-lock.json" "$FW/"
out=$(bash "$SCRIPT" --if-stale "$FS" "$FW" 2>&1); rc=$?
want "moved lockfile: exits 0" 0 "$rc"
want "…the new package resolves" "$FS/node_modules/@axe-core/playwright" "$(real "$FW/node_modules/@axe-core/playwright")"
want "…the planted absence is relinked too" "$FS/node_modules/left-pad" "$(real "$FW/node_modules/left-pad")"
want "…and it is the shared install, linked" "yes" "$([ -f "$FW/node_modules/.linked-from-shared-install" ] && echo yes || echo no)"
# A workspace's package.json is in the fingerprint too.
printf '{"name":"@acme/ui","version":"0.0.1","dependencies":{"left-pad":"1"}}\n' > "$FW/packages/ui/package.json"
out=$(bash "$SCRIPT" --if-stale "$FS" "$FW" 2>&1)
want "a workspace manifest change rebuilds" "yes" "$(printf '%s' "$out" | grep -q 'changed since' && echo yes || echo no)"

echo "--- an own install made from an older lockfile is made again ---"
printf '{"lockfileVersion":3,"packages":{"node_modules/left-pad":{"version":"2.0.0"}}}\n' > "$FW/package-lock.json"
LINK_NODE_MODULES_INSTALL='mkdir -p node_modules/v2' bash "$SCRIPT" --if-stale "$FS" "$FW" >/dev/null 2>&1
want "an own install carries an 'own' fingerprint" "own" "$(cut -d' ' -f1 "$FW/node_modules/.harness-link-stamp" 2>/dev/null)"
printf '{"lockfileVersion":3,"packages":{"node_modules/left-pad":{"version":"3.0.0"}}}\n' > "$FW/package-lock.json"
out=$(LINK_NODE_MODULES_INSTALL='mkdir -p node_modules/v3' bash "$SCRIPT" --if-stale "$FS" "$FW" 2>&1); rc=$?
want "exits 0" 0 "$rc"
want "…the new install ran" "yes" "$([ -d "$FW/node_modules/v3" ] && echo yes || echo no)"
want "…over a clean directory, not the old one" "absent" "$([ -e "$FW/node_modules/v2" ] && echo present || echo absent)"
out=$(LINK_NODE_MODULES_INSTALL='mkdir -p node_modules/v4' bash "$SCRIPT" --if-stale "$FS" "$FW" 2>&1)
want "…and an up-to-date own install is not made again" "absent" "$([ -e "$FW/node_modules/v4" ] && echo present || echo absent)"

echo "--- an own install whose lockfile now matches the shared one is linked instead ---"
cp "$FS/package-lock.json" "$FW/"
out=$(bash "$SCRIPT" --if-stale "$FS" "$FW" 2>&1); rc=$?
want "exits 0" 0 "$rc"
want "…it is linked again" "yes" "$([ -f "$FW/node_modules/.linked-from-shared-install" ] && echo yes || echo no)"
want "…the own install is gone" "absent" "$([ -e "$FW/node_modules/v3" ] && echo present || echo absent)"
want "…the shared package resolves" "$FS/node_modules/@axe-core/playwright" "$(real "$FW/node_modules/@axe-core/playwright")"

echo "--- a real install this script did not make is still left alone under --if-stale ---"
RW="$FIX/real-wt"; mkdir -p "$RW/node_modules/react"; cp "$FS/package.json" "$RW/"
out=$(bash "$SCRIPT" --if-stale "$FS" "$RW" 2>&1); rc=$?
want "exits 0" 0 "$rc"
want "…react untouched, nothing linked" "react" "$(ls -A "$RW/node_modules")"

[ "$FAILED" = 0 ] && echo "PASS" || { echo "FAIL"; exit 1; }
