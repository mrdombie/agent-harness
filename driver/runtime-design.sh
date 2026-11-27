#!/usr/bin/env bash
# runtime-design.sh — the third upfront design. Beside the picture and the data model, a
# feature says where its truth lives, its view models, its actions and what each returns,
# and what the assistant reads of it (the owner, 2026-11-27: "every feature gets three
# upfront designs"). Found that day: no design said where the truth lives, so each card
# worked out its own buttons and times in the browser.
#
#   driver_runtime_check <ticket> <plan.json> <tree>   from steps/plan.sh, after the data model
#
# Owed, checked with no model: the ticket carries one of the project's labels AND a file
# the plan touches starts with one of its paths. Then the plan's `runtimeDesign` must name
# a doc in the tree whose headings include the project's heading, or `ticket` with that
# heading in the ticket body. A model saying "not owed" is never asked.
#
# The project turns it on in harness.json; with no `design.runtime` it is never owed:
#
#   "design": { "runtime": {
#     "mode":    "report" | "block",     report names the gap on the PR; block refuses the plan
#     "labels":  ["type:feature", …],
#     "paths":   ["apps/web/src/app/", …],
#     "heading": "Runtime design"
#   } }
#
# REPORT FIRST. A new blocking check is switched on alone, after it has run report-only
# and been proved (the owner, 2026-10-22). On the day this landed no doc had the section,
# so blocking at once would have parked every feature build.

[ -n "${DRIVER_DIR:-}" ] || . "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/driver-env.sh" || exit 1
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/state.sh" || exit 1

_driver_runtime_cfg() { jq -r --arg k "$1" '.design.runtime[$k] // empty | if type == "array" then .[] else . end' "${HARNESS_CFG:-/dev/null}" 2>/dev/null; }

# _driver_runtime_has_heading <file> <heading> — 0 when a markdown heading names it.
_driver_runtime_has_heading() {
  [ -f "$1" ] || return 1
  grep -qiE "^#{1,6}[[:space:]].*$(printf '%s' "$2" | sed 's/[][\.*^$/]/\\&/g')" "$1"
}

# driver_runtime_owed <ticket> <plan.json> — prints why when owed, returns 1 when not.
driver_runtime_owed() {
  local t="$1" ans="$2" labels paths l p f hit=""
  [ -n "$(_driver_runtime_cfg heading)" ] || return 1
  labels=$(driver_ticket_view "$t" labels '[.labels[]?.name] | .[]' 2>/dev/null) || return 1
  for l in $(_driver_runtime_cfg labels); do
    printf '%s\n' "$labels" | grep -qx -- "$l" && { hit="$l"; break; }
  done
  [ -n "$hit" ] || return 1
  paths=$(_driver_runtime_cfg paths)
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    while IFS= read -r p; do
      [ -n "$p" ] || continue
      case "$f" in "$p"*) printf '%s, and the plan touches %s' "$hit" "$f"; return 0 ;; esac
    done <<<"$paths"
  done < <(jq -r '[.tasks[]?.files[]?.path] | .[]' "$ans" 2>/dev/null)
  return 1
}

driver_runtime_check() { # <ticket> <plan.json> <tree>
  local t="$1" ans="$2" wt="$3" why named heading mode body ok="" note
  why=$(driver_runtime_owed "$t" "$ans") || { driver_state_set "$t" runtime_note ""; return "$DRIVER_OK"; }
  heading=$(_driver_runtime_cfg heading); mode=$(_driver_runtime_cfg mode); [ "$mode" = block ] || mode=report
  named=$(jq -r '.runtimeDesign // ""' "$ans")
  if [ "$named" = ticket ]; then
    body=$(mktemp); driver_ticket_view "$t" body '.body // ""' > "$body" 2>/dev/null
    _driver_runtime_has_heading "$body" "$heading" && ok="the ticket body"
    rm -f "$body"
  elif [ -n "$named" ]; then
    _driver_runtime_has_heading "$wt/${named%%#*}" "$heading" && ok="${named%%#*}"
  fi
  if [ -n "$ok" ]; then
    driver_say "   plan: runtime design owed ($why) — built to the '$heading' section of $ok"
    driver_state_set "$t" runtime_note ""
    return "$DRIVER_OK"
  fi
  note="A runtime design is owed ($why) and the plan names none with a '$heading' section${named:+ (it named '$named')}. Write it in the area's architecture doc or the ticket: where the truth lives, the view models, the actions and what each returns, what the assistant reads."
  if [ "$mode" = block ]; then
    driver_say "✋ plan: $note"
    driver_state_set "$t" park_note "$note"
    return "$DRIVER_E_REFUSED"
  fi
  driver_say "⚠ plan: $note Report only: design.runtime.mode is not 'block'."
  driver_state_set "$t" runtime_note "$note"
  return "$DRIVER_OK"
}
