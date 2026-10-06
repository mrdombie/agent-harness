#!/usr/bin/env bash
# behind-pr-action.sh — who brings an agent's PR up to date once develop has moved.
#
#   behind-pr-action.sh <mergeStateStatus> <mergeable> [<mode>]
#
# Prints one word:
#   none   nothing to catch up on (or GitHub has not decided yet) — leave it
#   bot    behind but clean, and the repo runs an update bot — leave it to the bot
#   merge  the agent merges the integration branch in, re-gates and pushes
#
# <mode> is `merge.updateBehind` from harness.json: `bot` when the repo has a bot
# that brings behind PRs up to date one at a time, `agent` (the default) when it
# does not. Read it with: toolkit_cfg merge.updateBehind 2>/dev/null || echo agent
#
# Why `bot` exists (#79): on a repo that requires PRs to be up to date, an agent
# merging develop in by hand queues a full extra CI run and lets its PR land ahead
# of the PR the bot is landing, which then re-checks from zero. A conflict is the
# exception — the bot cannot resolve one, so that stays the agent's job.
set -euo pipefail

STATE="${1:?usage: behind-pr-action.sh <mergeStateStatus> <mergeable> [<mode>]}"
MERGEABLE="${2:?usage: behind-pr-action.sh <mergeStateStatus> <mergeable> [<mode>]}"
MODE="${3:-agent}"

case "$MODE" in
  agent|bot) ;;
  *) echo "behind-pr-action: harness.json merge.updateBehind is '$MODE' — expected 'agent' or 'bot'." >&2; exit 1 ;;
esac

if [ "$MERGEABLE" = "CONFLICTING" ] || [ "$STATE" = "DIRTY" ]; then
  echo merge
elif [ "$STATE" = "BEHIND" ]; then
  if [ "$MODE" = "bot" ]; then echo bot; else echo merge; fi
else
  echo none
fi
