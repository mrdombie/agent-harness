#!/usr/bin/env bash
# behind-pr-action.test.sh — what an agent does with its own PR once develop has
# moved past it (#79).
#
# On a repo that requires PRs to be up to date AND runs a bot that brings them up
# to date one at a time, an agent merging develop in by hand queues a full extra
# CI run and lets its PR land ahead of the one the bot is landing — which then
# re-checks from zero. One PR was restarted three times that way in an afternoon.
# A conflict is different: the bot cannot resolve one, so the agent still must.
#
# Run: bash "$0"
set -uo pipefail
S="$(cd "$(dirname "$0")" && pwd)/behind-pr-action.sh"

FAILED=0
ok()   { printf 'OK       %s\n' "$1"; }
bad()  { printf 'MISMATCH %s\n' "$1"; FAILED=1; }
want() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 — wanted '$2', got '$3'"; fi; }

echo "--- a repo with an update bot: a PR that is merely behind is the bot's ---"
want "behind + mergeable, bot mode"   "bot"   "$(bash "$S" BEHIND MERGEABLE bot)"
want "a conflict is still the agent's" "merge" "$(bash "$S" DIRTY CONFLICTING bot)"
want "conflicting while behind"        "merge" "$(bash "$S" BEHIND CONFLICTING bot)"

echo "--- a DIRTY flag GitHub has not caught up on is not a conflict ---"
# DIRTY is often stale (the precompute is merge-driver-blind); mergeable says
# MERGEABLE. Treating it as a conflict sends the agent to merge develop in by
# hand on a PR that is merely behind — the restart this exists to stop.
want "stale DIRTY, mergeable, bot mode" "bot"   "$(bash "$S" DIRTY MERGEABLE bot)"
want "DIRTY, mergeable unknown"         "merge" "$(bash "$S" DIRTY UNKNOWN bot)"
want "behind, mergeable unknown"        "bot"   "$(bash "$S" BEHIND UNKNOWN bot)"

echo "--- no update bot (the default): the agent catches up, as before ---"
want "behind, agent mode"              "merge" "$(bash "$S" BEHIND MERGEABLE agent)"
want "no mode given means agent"       "merge" "$(bash "$S" BEHIND MERGEABLE)"
want "a conflict, agent mode"          "merge" "$(bash "$S" DIRTY CONFLICTING agent)"

echo "--- a PR that is not behind needs nothing, in either mode ---"
for m in bot agent; do
  want "clean ($m)"    "none" "$(bash "$S" CLEAN MERGEABLE "$m")"
  want "blocked ($m)"  "none" "$(bash "$S" BLOCKED MERGEABLE "$m")"
  want "unstable ($m)" "none" "$(bash "$S" UNSTABLE MERGEABLE "$m")"
done

echo "--- GitHub not having decided yet is a wait, never a merge ---"
# UNKNOWN is the precompute still running. Merging develop in on it is the
# self-catch-up this exists to stop.
want "unknown state, bot"   "none" "$(bash "$S" UNKNOWN UNKNOWN bot)"
want "unknown state, agent" "none" "$(bash "$S" UNKNOWN UNKNOWN agent)"

echo "--- a mode the kit does not know refuses by name ---"
out=$(bash "$S" BEHIND MERGEABLE robot 2>&1); rc=$?
want "unknown mode exits non-zero" "1" "$rc"
if printf '%s' "$out" | grep -q 'merge.updateBehind'; then ok "names the key"; else bad "names the key — got: $out"; fi

exit "$FAILED"
