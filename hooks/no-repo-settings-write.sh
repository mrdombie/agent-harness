#!/usr/bin/env bash
# PreToolUse(Bash): a build run never writes the repository's settings.
#
# A build run is a spawned claim (CLAIM_RUN_ID) or a driver step (HARNESS_DRIVER_RUN).
# On 2026-10-20 a driver build added a required check to the live develop ruleset
# with `gh api` from inside a build step; its ticket had said the change was an
# admin step for later. A person's own session is not refused — the PM makes these.
#
# Judged per command segment (split on ; && || |), and only where gh is the command.
# Self-test: hooks/no-repo-settings-write.test.sh
[ -n "${CLAIM_RUN_ID:-}${HARNESS_DRIVER_RUN:-}" ] || exit 0
cmd=$(jq -r '.tool_input.command // empty' 2>/dev/null)
[ -n "$cmd" ] || exit 0
. "$(dirname "$0")/lib/repo-settings-write.sh"
hit=""
while IFS= read -r seg; do
  repo_settings_write "$seg" && { hit="$seg"; break; }
done < <(printf '%s\n' "$cmd" | sed -E 's/(&&|\|\||;|\|)/\n/g')
[ -n "$hit" ] || exit 0
jq -nc --arg r "$REPO_SETTINGS_WRITE_REASON Refused: $(printf '%s' "$hit" | sed -E 's/^[[:space:]]+//' | cut -c1-200)" '{
  hookSpecificOutput: { hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $r }
}'
