#!/usr/bin/env bash
# queue-not-build.test.sh — while the coordinator is live, a /work or /auto run
# that spawns a builder agent is refused; reviewers and PM help pass; with the
# coordinator off or in shadow nothing is refused.
# Run: bash "$0"
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
H="$HERE/queue-not-build.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
FAILED=0
ok()  { printf 'OK       %s\n' "$1"; }
bad() { printf 'MISMATCH %s\n' "$1"; FAILED=1; }
for m in live shadow off; do printf '#!/usr/bin/env bash\necho %s\n' "$m" > "$T/$m.sh"; done
mkdir -p "$T/state"
call() { # <mode> <prompt> [isolation] -> rc
  local j; j=$(jq -cn --arg p "$2" --arg i "${3:-}" '{tool_name:"Agent",tool_input:{prompt:$p,description:"x"} } | if $i != "" then .tool_input.isolation=$i else . end')
  printf '%s' "$j" | QUEUE_NOT_BUILD_SERVICE="$T/$1.sh" HARNESS_STATE_DIR="$T/state" bash "$H" 2>"$T/err"
}
expect() { # <label> <want-rc> <mode> <prompt> [isolation]
  local label="$1" want="$2"; shift 2
  call "$@"; local rc=$?
  [ "$rc" = "$want" ] && ok "$label" || bad "$label — wanted rc $want, got $rc"
}

echo "--- coordinator live: builders are refused ---"
expect "a /work run's builder running the claim flow" 2 live "Run /agent-harness:claim 12797 and ship it to merged."
expect "a builder told to run /claim"                 2 live "Use /claim 12801, resume the worktree, then /finish."
expect "a builder told to take the claim lock"        2 live "claim-lock.sh acquire 12794 --branch x --worktree y, then build"
expect "a builder told to build ticket #n"            2 live "Build ticket #12799 end to end"
grep -q 'coordinator-queue.sh" add' "$T/err" && ok "the refusal says how to queue" || bad "the refusal says how to queue"
: > "$T/state/.loop-active"
expect "a worktree agent during a loop"               2 live "Fix the failing unit tests" worktree
rm -f "$T/state/.loop-active"

echo "--- coordinator live: everything else passes ---"
expect "a reviewer"                                   0 live "Review the diff for dead controls and report"
expect "an explorer naming /claims in a path"         0 live "Read hooks/claims/README and summarise"
expect "a worktree agent with no loop running"        0 live "Try a refactor" worktree

echo "--- coordinator shadow or off: nothing is refused ---"
expect "shadow"                                       0 shadow "Run /agent-harness:claim 12797"
expect "off"                                          0 off "Run /agent-harness:claim 12797"

exit $FAILED
