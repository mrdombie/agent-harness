#!/usr/bin/env bash
# steps/simplify.sh — Claude Code's /simplify on the change, once, before review.
#
#   driver_step_simplify <ticket>
#
# In the builder's own session (--resume-of build: the build task that ran last), so it
# starts from what the builder already read rather than paying to read it again. Once per
# change: a fix round that reopens the walk does not run it twice. Its clean-up stays only while every fast gate
# (gates.local) is green on the new head; a red one resets the branch to where it was.
# Never parks over a clean-up: the step is an offer, and the change goes on without it.
# Only a skill check it fails, a usage wall or a machine fault stops the walk.
[ -n "${DRIVER_DIR:-}" ] || . "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/driver-env.sh" || exit 1
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/ai-step.sh" || exit 1

# _driver_simplify_gates <tree> — 0 when every gates.local command passes in <tree>; else
# prints the first red one and its last lines.
_driver_simplify_gates() {
  local wt="$1" cmd out rc
  while IFS= read -r cmd; do
    [ -n "$cmd" ] || continue
    out=$( cd "$wt" && driver_run_project "${DRIVER_CMD_TIMEOUT:-}" "$cmd" 2>&1 ); rc=$?
    [ "$rc" -eq 0 ] && continue
    printf '%s (exit %s): %s' "$cmd" "$rc" "$(printf '%s' "$out" | tail -3 | tr '\n' ' ')"
    return 1
  done < <(jq -r '(.gates.local // [])[]? | strings' "$HARNESS_CFG" 2>/dev/null)
  return 0
}

driver_step_simplify() { # <ticket>
  local t="${1:?driver_step_simplify: need a ticket}"
  local wt trunk r before after rc=0 why d
  export DRIVER_TICKET="$t"
  d="$(driver_state_dir "$t")/steps"
  if [ "$(driver_state_get "$t" mode)" = repair ]; then
    driver_say "   simplify: a repair — skipped"; return "$DRIVER_OK"
  fi
  if [ "$(driver_state_count "$t" simplify)" -ge 1 ]; then
    driver_say "   simplify: already ran on this change — not again"; return "$DRIVER_OK"
  fi
  wt=$(driver_state_get "$t" worktree); [ -n "$wt" ] && [ -d "$wt" ] || wt="$MAIN_REPO"
  trunk=""
  for r in "origin/$INTEGRATION_BRANCH" "$INTEGRATION_BRANCH"; do
    git -C "$wt" rev-parse --verify -q "$r" >/dev/null 2>&1 && { trunk="$r"; break; }
  done
  if [ -z "$trunk" ] || [ -z "$(git -C "$wt" diff --name-only "$trunk...HEAD" 2>/dev/null)" ]; then
    driver_say "   simplify: no diff against ${trunk:-the trunk} — nothing to simplify"; return "$DRIVER_OK"
  fi
  if [ -z "$(jq -r '(.gates.local // [])[]? | strings' "$HARNESS_CFG" 2>/dev/null)" ]; then
    driver_say "   simplify: harness.json names no gates.local, so a clean-up could not be checked — skipped"
    return "$DRIVER_OK"
  fi
  # A reset below must only ever drop simplify's own work.
  if [ -n "$(git -C "$wt" status --porcelain -- . ':!node_modules' 2>/dev/null)" ]; then
    driver_say "   simplify: the tree holds uncommitted edits — skipped, so none is swept in or reset away"
    return "$DRIVER_OK"
  fi

  before=$(git -C "$wt" rev-parse HEAD)
  driver_fact_put "$t" simplify TARGET "$trunk"
  driver_ai_step "$t" simplify --resume-of build || rc=$?
  case "$rc" in "$DRIVER_E_USAGE"|"$DRIVER_E_MACHINE") ;; *) driver_state_bump "$t" simplify ;; esac
  driver_state_set "$t" simplify_agents "$(driver_log_spawns "$d/simplify.log")"

  # A clean-up left uncommitted is still the clean-up.
  if [ -n "$(git -C "$wt" status --porcelain -- . ':!node_modules' 2>/dev/null)" ]; then
    git -C "$wt" add -A -- . ':!node_modules' >/dev/null 2>&1
    git -C "$wt" commit -q -m "refactor(#$t): simplify" >/dev/null 2>&1
  fi
  after=$(git -C "$wt" rev-parse HEAD)

  if [ "$rc" -ne 0 ]; then
    [ "$after" = "$before" ] || git -C "$wt" reset -q --hard "$before"
    driver_say "   simplify: the step did not answer cleanly (exit $rc) — any clean-up is dropped"
    case "$rc" in "$DRIVER_E_QUESTION"|"$DRIVER_E_SCHEMA") return "$DRIVER_OK" ;; esac
    return "$rc"
  fi

  if [ "$after" = "$before" ]; then
    driver_say "   simplify: found nothing to change"
  elif why=$(_driver_simplify_gates "$wt"); then
    driver_say "   simplify: kept $(git -C "$wt" rev-list --count "$before..$after") clean-up commit(s); the fast gates pass"
  else
    git -C "$wt" reset -q --hard "$before"
    driver_say "   simplify: clean-up dropped — a fast gate went red on it: $why"
    return "$DRIVER_OK"
  fi
  jq -r '(.changes // [])[] | "   simplify: \(.file): \(.what)"' "$d/simplify.json" 2>/dev/null | while IFS= read -r l; do driver_say "$l"; done
  return "$DRIVER_OK"
}
