#!/usr/bin/env bash
# tier.test.sh — the process matches the change (the owner, 2026-10-20). A build is
# tiered by the files it changes: screen (unchanged), backend (full review, no design
# steps, no picture verdict owed), tooling (one review round, only Critical and Major
# block). A later push that touches a screen promotes the build.
# Run: bash "$0"
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/tests/lib/suite.sh" || exit 1
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/fixture.sh"
driver_fixture; on_exit_keep_status 'rm -rf "$FIX"'
. "$HERE/../steps/review.sh" || exit 1
. "$HERE/../steps/compare.sh" || exit 1
. "$HERE/../steps/ship.sh" || exit 1
fix_brief review superpowers:requesting-code-review
CFG="$REPO/.claude/harness.json"
cfg() { jq "$1" "$CFG" > "$FIX/cfg.t" && mv "$FIX/cfg.t" "$CFG"; }
cfg '.design = {"surfacePaths": ["apps/web/**"]}'
git -C "$REPO" add -A && git -C "$REPO" commit -qm "screens are apps/web"

tree() { # <ticket> — a fresh worktree and record
  git -C "$REPO" worktree add -q "$FIX/wt$1" -b "tkt-$1/work" develop
  driver_state_init "$1" --worktree "$FIX/wt$1" --branch "tkt-$1/work"
  fix_issue "$1" OPEN "status:claimed"
}
put() { # <ticket> <path>
  mkdir -p "$(dirname "$FIX/wt$1/$2")"; printf 'x %s\n' "$RANDOM" > "$FIX/wt$1/$2"
  git -C "$FIX/wt$1" add -A; git -C "$FIX/wt$1" commit -qm "change $2"
}
tier_of() { driver_change_tier "$1" "$FIX/wt$1" develop | cut -f1; }

echo "--- the tier is read off the diff ---"
tree 701; put 701 lib/api.ts
want "product code and no screen is backend"        "backend" "$(tier_of 701)"
tree 702; put 702 .github/workflows/ci.yml; put 702 docs/how.md; put 702 README.md
want "CI, docs and config only is tooling"          "tooling" "$(tier_of 702)"
tree 703; put 703 apps/web/src/Home.tsx
want "a screen file is screen"                      "screen" "$(tier_of 703)"
tree 704; put 704 lib/app/page.tsx
want "a page that renders a route is screen"        "screen" "$(tier_of 704)"
tree 705; put 705 scripts/build.sh
want "a path the project calls tooling is tooling"  "backend" "$(tier_of 705)"
cfg '.tiers = {"toolingPaths": ["scripts/**"]}'
want "once tiers.toolingPaths names it"             "tooling" "$(tier_of 705)"
cfg 'del(.tiers)'

echo "--- a later push that touches a screen promotes the build ---"
tree 706; put 706 lib/api.ts
want "first a backend build"                        "backend" "$(tier_of 706)"
put 706 apps/web/src/Settings.tsx
out=$(driver_change_tier 706 "$FIX/wt706" develop 2>"$FIX/promo.err")
want "then a screen build, and stdout is the tier alone" "screen" "$(printf '%s\n' "$out" | cut -f1)"
want_in "the promotion is said, on stderr"          'promoted to the screen tier' "$(cat "$FIX/promo.err")"
want "the promotion is on the record"               "backend" "$(driver_state_get 706 tier_promoted)"
want_in "and said in the PR body"                   'Promoted from backend' "$(_driver_ship_tier_line 706 screen "it changes a screen")"

echo "--- a project that says nothing about screens is not tiered ---"
cfg 'del(.design)'
want "no surfacePaths: every build is a screen build" "screen" "$(tier_of 701)"
cfg '.design = {"surfacePaths": ["apps/web/**"]} | .tiers = {"enabled": false}'
want "tiers.enabled false: screen"                  "screen" "$(tier_of 701)"
cfg 'del(.tiers)'

echo "--- compare: a backend build has no picture to compare ---"
rc=0; out=$(driver_step_compare 701 2>&1) || rc=$?
want "it finishes"                                  "0" "$rc"
want_in "and says it is a backend build"            'a backend build' "$(driver_state_get 701 renders)"

echo "--- push-requires: a backend build owes no design-critic verdict ---"
cfg '.review = {"attest": {"design-critic": {"owed": "exit 3", "agent": "agent-harness:design-critic", "record": "true", "needsRenders": true}}}'
rc=0; out=$(driver_push_requires 701 2>&1) || rc=$?
want "it passes"                                    "0" "$rc"
want_in "saying why"                                "backend build that changes none" "$out"
want "and owes nothing after the push"              "" "$(driver_state_get 701 attest_after_push)"
rc=0; out=$(driver_push_requires 703 2>&1) || rc=$?
want "a screen build still owes it after the push"  "design-critic" "$(driver_state_get 703 attest_after_push)"
cfg 'del(.review)'

echo "--- review: backend keeps the full rounds; tooling gets one, Critical and Major only ---"
minor='{"verdict":"BLOCKED","findings":[{"file":"docs/how.md","line":2,"grade":"minor","summary":"a stiff sentence","reason":"reads oddly"}]}'
major='{"verdict":"BLOCKED","findings":[{"file":".github/workflows/ci.yml","line":4,"grade":"major","summary":"the job never runs","reason":"a red build reads green"}]}'
export DRIVER_POLISH_LIST="$FIX/pl" DRIVER_SCREEN_FINDINGS="$FIX/sf"
printf '#!/usr/bin/env bash\nexit 0\n' > "$FIX/pl"; printf '#!/usr/bin/env bash\nexit 0\n' > "$FIX/sf"; chmod +x "$FIX/pl" "$FIX/sf"
fix_ai review "$minor" superpowers:requesting-code-review
rc=0; driver_step_review 701 >/dev/null 2>&1 || rc=$?
want "backend round 1: a Minor blocks"              "30" "$rc"
rc=0; driver_step_review 702 >/dev/null 2>&1 || rc=$?
want "tooling round 1: a Minor does not"            "0" "$rc"
want_in "it is kept as a note for the PR"           'Minor, deferred' "$(_driver_ship_deferred 702)"
tree 707; put 707 .github/workflows/ci.yml
fix_ai review "$major" superpowers:requesting-code-review
rc=0; driver_step_review 707 >/dev/null 2>&1 || rc=$?
want "tooling round 1: a Major blocks"              "30" "$rc"
rc=0; out=$(driver_step_review 707 2>&1) || rc=$?
want "and there is no second round to send it back" "0" "$rc"
want "the Major is still on the answer, for ship to refuse" "major" "$(jq -r '[.findings[].grade] | join(" ")' "$(driver_state_dir 707)/steps/review.json")"

echo "--- the PR says which tier it took ---"
want_in "backend"  '^Change tier: backend — .*no sign-off hold' "$(_driver_ship_tier_line 701 backend "it changes product code")"
want_in "tooling"  '^Change tier: tooling — .*one review round' "$(_driver_ship_tier_line 702 tooling "CI only")"
want_in "screen"   '^Change tier: screen — .*sign-off apply' "$(_driver_ship_tier_line 703 screen "it changes a screen")"
want_in "ship writes it into the body" '\$tierline' "$(sed -n '/body=\$(cat <<PRBODY/,/^PRBODY/p' "$HERE/../steps/ship.sh")"

suite_end "$FAILED"
