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

# Only care about a push. Handles `git -C <dir> push`, `git push origin main`, and
# a push behind VAR=value settings or an env wrapper (hooks/lib/command-words.sh).
# Judged PER COMMAND SEGMENT (split on ; && || |): on 2026-09-02 a
# `git merge --no-verify … && git push` line was denied because the flag sat on
# the merge and the push sat later in the same text. The flag has to be on the
# push itself, and git has to be the command (not words inside an echo).
. "$(dirname "$0")/lib/command-words.sh"
hit=0
while IFS= read -r seg; do
  case "$seg" in *git*push*--no-verify*) ;; *) continue ;; esac
  command_words "$seg" && command_is git || continue
  i=1; n=${#CMD_WORDS[@]}
  while [ "$i" -lt "$n" ]; do
    case "${CMD_WORDS[$i]}" in
      -C | -c | --git-dir | --work-tree | --namespace) i=$((i + 2)) ;;
      -*) i=$((i + 1)) ;;
      *) break ;;
    esac
  done
  [ "${CMD_WORDS[$i]:-}" = push ] || continue
  for a in "${CMD_WORDS[@]:$((i + 1))}"; do [ "$a" = --no-verify ] && { hit=1; break 2; }; done
done < <(cmd_segments "$cmd")
[ "$hit" = "1" ] || exit 0

jq -nc '{
  hookSpecificOutput: {
    hookEventName: "PreToolUse",
    permissionDecision: "deny",
    permissionDecisionReason: "git push --no-verify skips all 26 checks in .husky/pre-push — changelog, migration order, ownership scoping, PII, secrets. Push without it. If a hook is genuinely wrong, fix the hook rather than bypassing every other one. (git commit --no-verify is blocked too, by block-hookify-rules.sh: measured against .husky/pre-commit it skips the secret scan, not just formatting.)"
  }
}'
