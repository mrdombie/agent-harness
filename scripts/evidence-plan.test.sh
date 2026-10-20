#!/usr/bin/env bash
# evidence-plan.test.sh — the harness files a branch's capture plan where CI reads it.
# CI's rule (the consuming project's evidence locator) is held here as the reference, and
# no script or step may build the plan's path from the ticket alone.
# Run: bash "$0"
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
pass=0; fail=0
ok()  { pass=$((pass + 1)); echo "  ok  $1"; }
bad() { fail=$((fail + 1)); echo "  FAIL $1"; }
. "$HERE/evidence-plan.sh"

# CI's locator, verbatim: the ticket off a sh-NNNN/ head ref, else the PR number.
ci_key() { local i; i=$(printf '%s' "$1" | sed -n 's|^sh-\([0-9]\{1,\}\)/.*|\1|p'); printf '%s' "${i:-$2}"; }

BRANCH_PREFIX=sh-
while IFS='|' read -r b pr; do
  [ -n "$b" ] || continue
  got=$(evidence_plan_key "$b" "$pr"); want=$(ci_key "$b" "$pr")
  [ "$got" = "$want" ] && ok "$b (PR $pr) → $want, as CI files it" || bad "$b (PR $pr): harness $got, CI $want"
done <<'T'
sh-13381/batch-approval-trail|13415
5654/approval-preview|13611
fix/42-slug|13390
sh-12|13109
sh-abc/slug|12708
sh-77/nested/slug|500
feature/sh-88/slug|501
T
[ "$(bash "$HERE/evidence-plan.sh" key 5654/approval-preview 13611)" = 13611 ] && ok "the command form agrees" || bad "command form"
[ -z "$(evidence_plan_key 5654/approval-preview '')" ] && ok "no prefix match and no PR: no key, not the ticket" || bad "invented a key"
BRANCH_PREFIX=tkt-
[ "$(evidence_plan_key tkt-9/x 10)" = 9 ] && ok "the project's own prefix is the one read" || bad "prefix not read"

# NO PATH FROM THE TICKET ALONE. Every step that reads or writes the plan asks the
# resolver; a path built as <evidence.dir>/$t/plan.json is the defect this file is for.
hits=$(grep -rnE '(evidence\.dir|EV_DIR)[^|;]*/\$\{?t\}?/plan\.json' "$ROOT/driver" "$ROOT/scripts" "$ROOT/swarm" 2>/dev/null \
  | grep -v '\.test\.sh:' | grep -v 'legacy-plan-path')
[ -z "$hits" ] && ok "no step builds the plan's path from the ticket" || bad "the plan's path is built from the ticket: $hits"

echo "evidence-plan: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
