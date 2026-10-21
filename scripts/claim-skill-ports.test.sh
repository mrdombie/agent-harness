#!/usr/bin/env bash
# claim-skill-ports.test.sh — what the claim skill took over from a project's fork.
#
# Until 2026-10-17 spawned builders on the origin project ran that project's own
# copy of the claim skill. When they moved to /agent-harness:claim, the steps only
# the fork carried moved here, and the project's own tests that pinned them went
# with its copy. These pins are their replacement: each fails if its step is
# dropped from the kit skill, and each reads the project fact from harness.json
# rather than naming any project.
set -u
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/tests/lib/suite.sh" || exit 1
cd "$(dirname "$0")/.." || exit 2
SKILL="${CLAIM_SKILL:-skills/claim/SKILL.md}"
[ -f "$SKILL" ] || { echo "missing $SKILL"; exit 2; }
fail=0
ok()  { echo "  ok   — $1"; }
bad() { echo "  FAIL — $1"; fail=1; }
has() { grep -qF -- "$2" "$SKILL" && ok "$1" || bad "$1 (no '$2')"; }

echo "claim skill: steps carried over from a project's fork"

# The SHA is written at claim time, with toolkit-env sourced so MAIN_REPO is set.
line=$(grep -n 'claimed_at_sha="$(git -C "$MAIN_REPO" rev-parse "origin/$INTEGRATION_BRANCH")"' "$SKILL" | head -1 | cut -d: -f1)
if [ -n "$line" ]; then
  ok "the claim records the integration-branch SHA it was claimed at"
  start=$(( line > 4 ? line - 4 : 1 ))
  sed -n "${start},${line}p" "$SKILL" | grep -q 'toolkit-env.sh' \
    && ok "toolkit-env is sourced in the same block, so MAIN_REPO is set" \
    || bad "the claimed_at_sha line is not in a block that sources toolkit-env"
else
  bad "the claim does not record claimed_at_sha"
fi

has "the project's machine checks run at Step 0, report-only" "(.claim.preflight // [])[]"
has "the project's planning rules are read before the plan"   "(.claim.planRules // [])[]"
has "a commit that keeps an approval is told apart"           "toolkit_cfg approval.previewOnly"
has "the park brief says whether an approval is carried"      "**Approval carried forward:**"
has "a project that owns finish keeps its own finish step"    'toolkit_cfg owns.skills'
has "the review cap is the project's review.rounds"           '`review.rounds`'
has "the build loop runs only the changed-file gates"         "jq -r '.gates.changed[]'"

echo
[ "$fail" -eq 0 ] && echo "claim-skill-ports: all cases pass" || echo "claim-skill-ports: FAILURES above"
suite_end "$fail"
