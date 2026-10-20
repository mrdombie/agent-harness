#!/usr/bin/env bash
# format.sh — the branch's own files formatted as the work goes, never left for a gate.
#
#   driver_format_changed <ticket> <tree> <label>
#
# A FORMAT CHECK IS NOT A FINDING. #13623 built seven proved tasks, then self-check's
# pre-push went red on `format:changed` alone and a whole fix round — an agent, a
# re-run of every gate — was spent running a formatter. The driver runs it itself:
# after each build task, after each fix round, and before self-check's gates, so the
# check only ever sees formatted files.
#
# THE COMMAND. `driver.formatWrite` in harness.json names a formatter that takes the
# files as arguments ("" or "none" switches it off). Absent, a project that enforces
# formatting (`gates.formatChanged`) and has prettier in its install gets
# `prettier --write --ignore-unknown`. A project that checks no formatting gets none.
#
# THE FILES are what the branch changed since it left the integration branch — the
# set `format:changed` checks — minus anything already dirty in the tree: uncommitted
# work is not swept into a formatting commit.
#
# 0 committed a formatting change · 1 nothing to format, or no formatter · 2 the
# formatter or the commit failed (said; the tree is left as it was).
[ -n "${DRIVER_DIR:-}" ] || . "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/driver-env.sh" || exit 1

driver_format_cmd() { # <tree>
  local v
  if [ -n "${HARNESS_CFG:-}" ] && [ -f "$HARNESS_CFG" ] \
     && [ "$(jq -r '(.driver.formatWrite // null) | type' "$HARNESS_CFG" 2>/dev/null)" = string ]; then
    v=$(jq -r '.driver.formatWrite' "$HARNESS_CFG" 2>/dev/null)
    [ "$v" != none ] || v=""
    printf '%s' "$v"; return 0
  fi
  [ -n "${HARNESS_CFG:-}" ] && [ -f "$HARNESS_CFG" ] || return 0
  [ "$(jq -r '(.gates.formatChanged // "") | type' "$HARNESS_CFG" 2>/dev/null)" = string ] || return 0
  [ -n "$(jq -r '.gates.formatChanged // ""' "$HARNESS_CFG" 2>/dev/null)" ] || return 0
  [ -x "$1/node_modules/.bin/prettier" ] || return 0
  printf '%s' "node_modules/.bin/prettier --write --ignore-unknown"
}

driver_format_changed() { # <ticket> <tree> <label>
  local t="$1" wt="$2" label="$3" cmd base r f dirty files=() q="" out after changed=()
  cmd=$(driver_format_cmd "$wt")
  [ -n "$cmd" ] || return 1
  base=""
  for r in "origin/${INTEGRATION_BRANCH:-develop}" "${INTEGRATION_BRANCH:-develop}"; do
    base=$(git -C "$wt" merge-base "$r" HEAD 2>/dev/null) && [ -n "$base" ] && break
  done
  [ -n "$base" ] || return 1
  dirty=$(git -C "$wt" diff --name-only HEAD 2>/dev/null)
  while IFS= read -r f; do
    [ -n "$f" ] && [ -f "$wt/$f" ] && [ ! -L "$wt/$f" ] || continue
    grep -Fxq -- "$f" <<<"$dirty" && continue
    files+=("$f"); q="$q $(printf '%q' "$f")"
  done <<EOF
$(git -C "$wt" diff --name-only --diff-filter=ACMR "$base" HEAD 2>/dev/null)
EOF
  [ "${#files[@]}" -gt 0 ] || return 1
  out="$(driver_state_dir "$t")/steps/format.out"
  mkdir -p "$(dirname "$out")"
  if ! ( cd "$wt" && driver_run_project "${DRIVER_CMD_TIMEOUT:-900}" "$cmd$q" ) > "$out" 2>&1; then
    driver_say "   $label: the formatter ($cmd) failed — $(tail -2 "$out" | tr '\n' ' ' | cut -c1-300)"
    git -C "$wt" checkout -q -- "${files[@]}" 2>/dev/null
    return 2
  fi
  # Only files the formatter changed, and only from the list it was given.
  after=$(git -C "$wt" diff --name-only HEAD 2>/dev/null)
  for f in "${files[@]}"; do
    grep -Fxq -- "$f" <<<"$after" && changed+=("$f")
  done
  [ "${#changed[@]}" -gt 0 ] || return 1
  if ! ( cd "$wt" && git commit -q -m "$(driver_opt commit.formatType style): format the files #$t changed" -- "${changed[@]}" ) >> "$out" 2>&1; then
    driver_say "   $label: the formatting could not be committed — $(tail -2 "$out" | tr '\n' ' ' | cut -c1-300)"
    git -C "$wt" checkout -q -- "${changed[@]}" 2>/dev/null
    return 2
  fi
  driver_say "   $label: formatted ${#changed[@]} file(s) the branch changed, committed"
  return 0
}
