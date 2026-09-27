#!/usr/bin/env bash
# Refuse `git push --no-verify`.
#
# WHY: .husky/pre-push runs 29 checks. `--no-verify` skips ALL of them, silently
# and instantly. Git hooks cannot defend themselves against it — but this runs at
# the TOOL layer, before bash sees the command, so --no-verify never gets a say.
#
# Measured 2026-08-19: every push in a full working session used --no-verify, and
# the .deploy-trigger gate then caught in CI (42 billed minutes) exactly what the
# skipped pre-commit hook would have prevented for free.
#
# NOT blocked:
#   * `git commit --no-verify` — the documented workaround for prettier churn
#     when merging develop. That skips FORMATTING, not the 29 gates.
#   * `git push -n` — for push that is --dry-run, not --no-verify. Different flag.
set -euo pipefail
payload=$(cat)
cmd=$(printf '%s' "$payload" | jq -r '.tool_input.command // ""' 2>/dev/null || echo "")
[ -z "$cmd" ] && exit 0

# Only care about a push. Handles `git -C <dir> push`, `git push origin main`, etc.
# Judged PER COMMAND SEGMENT (split on ; && || |): on 2026-09-02 a
# `git merge --no-verify … && git push` line was denied because the flag sat on
# the merge and the push sat later in the same text. The flag has to be on the
# push itself.
hit=0
while IFS= read -r seg; do
  printf '%s' "$seg" | grep -qE '(^|\s)git(\s+-[A-Za-z-]+(\s+\S+)?)*\s+push(\s|$)' || continue
  printf '%s' "$seg" | grep -qE '(^|\s)--no-verify(\s|$)' && { hit=1; break; }
done < <(printf '%s\n' "$cmd" | sed -E 's/(&&|\|\||;|\|)/\n/g')
[ "$hit" = "1" ] || exit 0

jq -nc '{
  hookSpecificOutput: {
    hookEventName: "PreToolUse",
    permissionDecision: "deny",
    permissionDecisionReason: "git push --no-verify skips all 26 checks in .husky/pre-push — changelog, deploy-trigger, migration order, ownership scoping, PII, secrets. Push without it. If a hook is genuinely wrong, fix the hook rather than bypassing every other one. (git commit --no-verify is blocked too, by block-hookify-rules.sh: measured against .husky/pre-commit it skips the secret scan, not just formatting.)"
  }
}'
