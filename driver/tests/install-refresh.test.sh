#!/usr/bin/env bash
# install-refresh.test.sh — a branch that merged the trunk gets the trunk's packages
# before its gates run. #12858 (2026-10-20): develop added @axe-core/playwright, the
# branch merged develop, and its node_modules — linked before the merge — had no entry
# for it, so self-check failed on "Cannot find module '@axe-core/playwright'".
#
# The real linker runs against a real shared clone and a real worktree of it; a gate
# reads the worktree's node_modules the way an import does.
# Run: bash "$0"
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/fixture.sh"
driver_fixture; trap 'rm -rf "$FIX"' EXIT
. "$HERE/../steps/self-check.sh" || exit 1

# The shared clone: a lockfile, a manifest and an install of what they name.
manifest() { # <dir> <dep…> — package.json and package-lock.json naming those deps
  local d=$1; shift
  jq -n --args '{name:"fx", private:true, dependencies:($ARGS.positional | map({(.):"1.0.0"}) | add // {})}' "$@" > "$d/package.json"
  jq -n --args '{lockfileVersion:3, packages:($ARGS.positional | map({("node_modules/" + .):{version:"1.0.0"}}) | add // {})}' "$@" > "$d/package-lock.json"
}
install() { local p; for p in "$@"; do mkdir -p "$REPO/node_modules/$p" && printf '{"name":"%s"}\n' "$p" > "$REPO/node_modules/$p/package.json"; done; }
# The gates live in a copy of the fixture's config, so the suite never rewrites the repo's.
gate() { jq --arg c "$1" '.gates = {"imports": $c}' "$HARNESS_CFG_PATH" > "$FIX/gates-cfg.json"; HARNESS_CFG="$FIX/gates-cfg.json"; }
needs() { printf 'test -e node_modules/%s || { echo "Error: Cannot find module %s"; exit 1; }' "$1" "'$1'"; }
merge_trunk() { cp "$REPO/package.json" "$REPO/package-lock.json" "$WT/"; }

manifest "$REPO" left-pad; install left-pad
git -C "$REPO" add package.json package-lock.json && git -C "$REPO" commit -qm "fixture: manifests"
WT="$FIX/wt"; git -C "$REPO" worktree add -q -b tkt-501 "$WT" develop
WT=$(cd "$WT" && pwd -P)
driver_link_install "$REPO" "$WT" 2>/dev/null
want "the worktree starts linked" "yes" "$([ -e "$WT/node_modules/left-pad" ] && echo yes || echo no)"

echo "--- the trunk added a package and the branch merged it: relinked before the gates ---"
manifest "$REPO" left-pad @axe-core/playwright; install @axe-core/playwright; merge_trunk
want "the stale install lacks it" "no" "$([ -e "$WT/node_modules/@axe-core/playwright" ] && echo yes || echo no)"
gate "$(needs @axe-core/playwright)"
driver_state_init 501 --worktree "$WT"
out=$(driver_step_self_check 501 2>&1); rc=$?
want "self-check is green" "0" "$rc"
want_in "it says the manifests moved" 'changed since its node_modules was built' "$out"
want_not_in "the gate never failed first" 'could not find' "$out"
want "the new package resolves" "yes" "$([ -e "$WT/node_modules/@axe-core/playwright" ] && echo yes || echo no)"
want "no fix round was spent" "0" "$(driver_state_count 501 selfcheck_red)"

echo "--- a worktree linked before fingerprints existed is relinked once ---"
rm -f "$WT/node_modules/.harness-link-stamp"; rm -f "$WT/node_modules/left-pad"
gate "echo ok"
driver_state_init 502 --worktree "$WT"
out=$(driver_step_self_check 502 2>&1); rc=$?
want "self-check is green" "0" "$rc"
want_in "it says there was no fingerprint" 'no fingerprint' "$out"
want "the missing link is back" "yes" "$([ -e "$WT/node_modules/left-pad" ] && echo yes || echo no)"

echo "--- matching fingerprint: nothing is relinked ---"
# The planted absence: a link gone, the manifests unchanged. A relink would restore it.
rm -f "$WT/node_modules/left-pad"
driver_state_init 503 --worktree "$WT"
out=$(driver_step_self_check 503 2>&1); rc=$?
want "self-check is green" "0" "$rc"
want_in "it says it is up to date" 'up to date' "$out"
want "nothing was relinked" "no" "$([ -e "$WT/node_modules/left-pad" ] && echo yes || echo no)"

echo "--- 'Cannot find module' for a declared package: one relink, then the gate again ---"
# The fingerprint matches, but the install is still missing the entry.
rm -rf "$WT/node_modules/@axe-core"
gate "$(needs @axe-core/playwright)"
driver_state_init 504 --worktree "$WT"
out=$(driver_step_self_check 504 2>&1); rc=$?
want "self-check is green" "0" "$rc"
want "it relinked exactly once" "1" "$(printf '%s\n' "$out" | grep -c 'Relinking it')"
want_in "naming the package" 'could not find @axe-core/playwright' "$out"
want "no fix round was spent" "0" "$(driver_state_count 504 selfcheck_red)"

echo "--- 'Cannot find module' for a package the branch does not declare is a red gate ---"
gate "echo \"Error: Cannot find module 'not-declared'\"; exit 1"
driver_state_init 505 --worktree "$WT"
out=$(driver_step_self_check 505 2>&1); rc=$?
want "it goes to fix" "30" "$rc"
want_not_in "and nothing was relinked" 'Relinking it' "$out"

echo "--- the shared clone lacks a package its own lockfile names: a machine fault ---"
manifest "$REPO" left-pad @axe-core/playwright brand-new-pkg; merge_trunk
gate "$(needs brand-new-pkg)"
driver_state_init 506 --worktree "$WT"
out=$(driver_step_self_check 506 2>&1); rc=$?
want "back on the queue, not parked or sent to fix" "29" "$rc"
want_in "named a machine fault" 'machine fault' "$out"
want_in "…on the record too" 'machine fault: the shared clone' "$(driver_state_get 506 park_note)"
want "relinked once first" "1" "$(printf '%s\n' "$out" | grep -c 'Relinking it')"
want "the shared clone was not installed into" "no" "$([ -e "$REPO/node_modules/brand-new-pkg" ] && echo yes || echo no)"
want "no fix round was spent" "0" "$(driver_state_count 506 selfcheck_red)"

echo "--- the shared clone itself is never relinked ---"
manifest "$REPO" left-pad @axe-core/playwright; gate "echo ok"
before=$(cd "$REPO/node_modules" && find . | sort | shasum)
driver_state_init 507 --worktree "$REPO"
out=$(driver_step_self_check 507 2>&1); rc=$?
want "self-check is green" "0" "$rc"
want "its node_modules is untouched" "$before" "$(cd "$REPO/node_modules" && find . | sort | shasum)"
want "no stamp is written into it" "no" "$([ -e "$REPO/node_modules/.harness-link-stamp" ] && echo yes || echo no)"

echo "--- a private install behind its lockfile: replaced before the gates, no fix round, no question ---"
# The gate reads the install the way a project's freshness check does: npm's record of
# what it put on disk against the lockfile.
FRESH='node -e '"'"'const fs=require("fs"),[i,d]=["node_modules/.package-lock.json","package-lock.json"].map(f=>JSON.parse(fs.readFileSync(f,"utf8")).packages||{});const bad=Object.keys(d).filter(k=>k&&i[k]&&i[k].version!==d[k].version);if(bad.length){console.error("FAIL — "+bad.length+" packages installed at a version the lockfile does not declare");process.exit(1)}'"'"''
manifest "$REPO" left-pad @axe-core/playwright; cp "$REPO/package-lock.json" "$REPO/node_modules/.package-lock.json"
printf '[]\n' > "$FIX/claims.json"
printf '#!/bin/sh\ncat "%s"\n' "$FIX/claims.json" > "$FIX/claim-list"; printf '#!/bin/sh\n:\n' > "$FIX/claim-refs"
chmod +x "$FIX/claim-list" "$FIX/claim-refs"
export WT_CLAIM_LIST="$FIX/claim-list" WT_CLAIM_REFS="$FIX/claim-refs"
private_wt() { # <ticket> — a worktree whose node_modules is its own npm install, one version behind
  local w="$FIX/wt-$1"
  git -C "$REPO" worktree add -q -b "tkt-$1" "$w" develop; w=$(cd "$w" && pwd -P)
  cp "$REPO/package.json" "$REPO/package-lock.json" "$w/"
  mkdir -p "$w/node_modules/left-pad"
  jq '.packages["node_modules/left-pad"].version = "0.9.0"' "$REPO/package-lock.json" > "$w/node_modules/.package-lock.json"
  printf '%s' "$w"
}
PW=$(private_wt 510)
gate "$FRESH"
want "the private install fails the gate" "1" "$(cd "$PW" && bash -c "$FRESH" >/dev/null 2>&1; echo $?)"
driver_state_init 510 --worktree "$PW"
out=$(DRIVER_TICKET=510 driver_step_self_check 510 2>&1); rc=$?
want "self-check is green" "0" "$rc"
want_in "it says the private install was replaced" 'behind its lockfile — replaced by the harness' "$out"
want "it is linked from the shared clone" "yes" "$([ -f "$PW/node_modules/.linked-from-shared-install" ] && echo yes || echo no)"
want "no fix round was spent" "0" "$(driver_state_count 510 selfcheck_red)"

echo "--- …claimed by another run: untouched, back on the queue as a machine fault, never sent to fix ---"
CW=$(private_wt 511)
printf '[{"issue":"999","worktree":"%s","branch":"","host":"elsewhere"}]\n' "$CW" > "$FIX/claims.json"
snap=$(cd "$CW/node_modules" && find . | sort | shasum)
driver_state_init 511 --worktree "$CW"
out=$(DRIVER_TICKET=511 driver_step_self_check 511 2>&1); rc=$?
want "back on the queue" "29" "$rc"
want_in "named a machine fault" 'machine fault' "$out"
want_in "…the record names the shared install's place" "$REPO/node_modules" "$(driver_state_get 511 park_note)"
want "its node_modules is untouched" "$snap" "$(cd "$CW/node_modules" && find . | sort | shasum)"
want "no fix round was spent" "0" "$(driver_state_count 511 selfcheck_red)"
printf '[]\n' > "$FIX/claims.json"

exit $FAILED
