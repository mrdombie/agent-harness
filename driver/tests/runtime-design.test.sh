#!/usr/bin/env bash
# runtime-design.test.sh — the third upfront design is owed by the ticket's label and the
# plan's paths, never by the model's say-so; a plan that names a doc or ticket section with
# the heading passes; report mode names the gap and goes on; block mode refuses.
# Real git; run: bash "$0"
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/tests/lib/suite.sh" || exit 1
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/fixture.sh"
driver_fixture; on_exit_keep_status 'rm -rf "$FIX"'
fixture_path REPO "$FIX"
. "$HERE/../runtime-design.sh" || exit 1
FAILED=0
want() { if [ "$2" = "$3" ]; then echo "OK       $1"; else echo "MISMATCH $1 — wanted '$2', got '$3'"; FAILED=$((FAILED+1)); fi; }

T=7100
mkdir -p "$(driver_state_dir "$T")/steps" "$REPO/docs"
CFG="$FIX/cfg.json"   # outside the repo: the fixture tracks its own config
plan() { jq -n --arg p "$1" --arg r "${2:-}" '{tasks:[{files:[{path:$p}]}]} + (if $r == "" then {} else {runtimeDesign:$r} end)' > "$FIX/plan.json"; }
cfg() { jq -n --arg m "$1" '{design:{runtime:{mode:$m, labels:["type:feature"], paths:["apps/web/"], heading:"Runtime design"}}}' > "$CFG"; export HARNESS_CFG="$CFG"; }
check() { driver_runtime_check "$T" "$FIX/plan.json" "$REPO"; }

if suite_case "with no design.runtime in the config, nothing is ever owed"; then
  printf '{}\n' > "$CFG"; export HARNESS_CFG="$CFG"
  fix_issue "$T" OPEN "type:feature"; plan apps/web/page.tsx
  check; want "passes" 0 "$?"
  want "owes nothing" "" "$(driver_runtime_owed "$T" "$FIX/plan.json")"
fi

cfg block

if suite_case "not owed without the label, or without a path"; then
  fix_issue "$T" OPEN "type:bug"; plan apps/web/page.tsx
  check; want "a bug on a screen passes" 0 "$?"
  fix_issue "$T" OPEN "type:feature"; plan apps/worker/job.ts
  check; want "a feature off the paths passes" 0 "$?"
fi

if suite_case "owed and missing: block refuses and parks with the gap named"; then
  fix_issue "$T" OPEN "type:feature"; plan apps/web/page.tsx
  check; rc=$?
  want "refused" "$DRIVER_E_REFUSED" "$rc"
  note=$(driver_state_get "$T" park_note); got=no
  case "$note" in *"'Runtime design'"*) case "$note" in *"apps/web/page.tsx"*) got=named ;; esac ;; esac
  want "the park note names the section and the file" named "$got"
fi

if suite_case "a doc the plan names must really have the heading"; then
  printf '# Area\n\n## Data model\n' > "$REPO/docs/area.md"
  plan apps/web/page.tsx docs/area.md
  check; want "a doc without the section is refused" "$DRIVER_E_REFUSED" "$?"
  printf '# Area\n\n## Runtime design\n' > "$REPO/docs/area.md"
  check; want "a doc with the section passes" 0 "$?"
fi

if suite_case "'ticket' passes only when the ticket body has the section"; then
  plan apps/web/page.tsx ticket
  check; want "a body without it is refused" "$DRIVER_E_REFUSED" "$?"
  jq '.body = "## Runtime design\nTruth lives on the server."' "$FIX/gh/issue-$T.json" > "$FIX/i.json" && mv "$FIX/i.json" "$FIX/gh/issue-$T.json"
  check; want "a body with it passes" 0 "$?"
fi

if suite_case "report mode names the gap for the PR and goes on"; then
  cfg report
  fix_issue "$T" OPEN "type:feature"; plan apps/web/page.tsx
  check; want "passes in report mode" 0 "$?"
  case "$(driver_state_get "$T" runtime_note)" in *"A runtime design is owed"*) got=noted ;; *) got=no ;; esac
  want "the gap is kept for the PR body" noted "$got"
fi

suite_end "$FAILED"
