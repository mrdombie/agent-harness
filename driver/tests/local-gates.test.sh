#!/usr/bin/env bash
# local-gates.test.sh — CI is the one gate (the owner, 2026-10-22). When `gates.local`
# is the local set (it holds every `gates.changed` command, or there is none), self-check
# runs exactly that list and no trial of the project's whole pre-push, and the push tells
# the hook which head the set already passed on. The older whole-app `gates.local` (one
# that leaves the changed list out) runs as before.
# Run: bash "$0"
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/tests/lib/suite.sh" || exit 1
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/fixture.sh"
driver_fixture; on_exit_keep_status 'rm -rf "$FIX"'
. "$HERE/../steps/self-check.sh" || exit 1
fix_issue 301 OPEN "status:claimed"
driver_state_init 301 --worktree "$REPO"
: > "$FIX/ran"
g() { printf 'echo %s >> "%s/ran"' "$1" "$FIX"; }
# cfg <file> <gates json> — a config of its own, beside the fixture's.
cfg() { jq --argjson g "$2" '.gates = $g' "$HARNESS_CFG" > "$1"; }
ran() { tr '\n' ' ' < "$FIX/ran" | sed 's/ $//'; }

echo "--- gates.local as the local set: only its commands run ---"
cfg "$FIX/lg-only.json" "$(jq -nc --arg a "$(g lint)" --arg b "$(g typecheck)" --arg c "$(g test)" --arg p "$(g FULL-PRE-PUSH)" --arg w "$(g WHOLE-APP)" \
  '{local: [$a, $b, $c], prePush: $p, lint: $w}')"
rc=0; out=$(HARNESS_CFG="$FIX/lg-only.json" driver_step_self_check 301 2>&1) || rc=$?
want "it is green"                               "0" "$rc"
want "exactly the listed checks ran, in order"   "lint typecheck test" "$(ran)"
want_in "and it says the rest is CI's"           'CI runs every required check once' "$out"
want "it records the head they passed on"        "$(git -C "$REPO" rev-parse HEAD)" "$(driver_state_get 301 local_gates_head)"

echo "--- gates.local holding the changed list: the changed commands run once, inside it ---"
: > "$FIX/ran"
cfg "$FIX/lg-super.json" "$(jq -nc --arg a "$(g lint-changed)" --arg h "$(g house-fast)" --arg p "$(g FULL-PRE-PUSH)" \
  '{changed: [$a], local: [$a, $h], prePush: $p}')"
rc=0; HARNESS_CFG="$FIX/lg-super.json" driver_step_self_check 301 >/dev/null 2>&1 || rc=$?
want "it is green"                               "0" "$rc"
want "the local set ran and the pre-push did not" "lint-changed house-fast" "$(ran)"

echo "--- a red check in the local set is red, and no head is recorded ---"
: > "$FIX/ran"
cfg "$FIX/lg-red.json" "$(jq -nc --arg a "$(g lint)" '{local: [$a, "echo broke; exit 3"]}')"
rc=0; HARNESS_CFG="$FIX/lg-red.json" driver_step_self_check 301 >/dev/null 2>&1 || rc=$?
want "it is not green"                           "1" "$([ "$rc" -ne 0 ] && echo 1)"
want "the head is cleared"                       "" "$(driver_state_get 301 local_gates_head)"

echo "--- the older whole-app gates.local: the changed list and the pre-push run, as before ---"
: > "$FIX/ran"
cfg "$FIX/lg-old.json" "$(jq -nc --arg a "$(g lint-changed)" --arg w "$(g WHOLE-APP)" --arg p "$(g pre-push)" \
  '{changed: [$a], local: [$w], prePush: $p}')"
rc=0; HARNESS_CFG="$FIX/lg-old.json" driver_step_self_check 301 >/dev/null 2>&1 || rc=$?
want "it is green"                               "0" "$rc"
want "the changed list then the pre-push ran"    "lint-changed pre-push" "$(ran)"
want "and no local-set head is recorded"         "" "$(driver_state_get 301 local_gates_head)"

echo "--- the push tells the hook the head the local set passed on ---"
git init -q --bare "$FIX/origin.git"
git -C "$REPO" remote add origin "$FIX/origin.git"
git -C "$REPO" checkout -q -b tkt-301/work
# The hook lives in the fixture, reached through the environment: no repo config is written.
mkdir -p "$FIX/hooks"
printf '#!/usr/bin/env sh\nprintf "%%s\\n" "${HARNESS_LOCAL_GATES_HEAD:-none}" >> "%s/hook.env"\n' "$FIX" > "$FIX/hooks/pre-push"
chmod +x "$FIX/hooks/pre-push"; : > "$FIX/hook.env"
export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.hooksPath GIT_CONFIG_VALUE_0="$FIX/hooks"
hook() { tail -1 "$FIX/hook.env"; }
HARNESS_CFG="$FIX/lg-only.json" driver_step_self_check 301 >/dev/null 2>&1
HARNESS_CFG="$FIX/lg-only.json" driver_push 301 "$REPO" tkt-301/work ship >/dev/null 2>&1
want "on the head it passed on"                  "$(git -C "$REPO" rev-parse HEAD)" "$(hook)"
git -C "$REPO" commit -q --allow-empty -m "chore: a verdict trailer"
HARNESS_CFG="$FIX/lg-only.json" driver_push 301 "$REPO" tkt-301/work ship >/dev/null 2>&1
want "after an empty commit, the new head"       "$(git -C "$REPO" rev-parse HEAD)" "$(hook)"
printf 'x\n' > "$REPO/new.txt"; git -C "$REPO" add new.txt; git -C "$REPO" commit -qm "feat: a file"
HARNESS_CFG="$FIX/lg-only.json" driver_push 301 "$REPO" tkt-301/work ship >/dev/null 2>&1
want "after a commit that changes files, nothing" "none" "$(hook)"
HARNESS_CFG="$FIX/lg-only.json" driver_step_self_check 301 >/dev/null 2>&1
HARNESS_CFG="$FIX/lg-only.json" driver_push 301 "$REPO" tkt-301/work park >/dev/null 2>&1
want "a park push never carries it"              "none" "$(hook)"
HARNESS_LOCAL_GATES_HEAD=inherited HARNESS_CFG="$FIX/lg-old.json" driver_push 301 "$REPO" tkt-301/work ship >/dev/null 2>&1
want "nor one inherited from the shell"          "none" "$(hook)"

suite_end "$FAILED"
