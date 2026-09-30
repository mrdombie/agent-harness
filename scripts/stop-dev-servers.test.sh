#!/usr/bin/env bash
# Fixture test for stop-dev-servers.sh — stand-in server processes in fake
# worktrees, and the four cases the sweep must get right, plus --worktree.
#
# The stand-ins are `sleep`, renamed with `exec -a next-server` so they look like
# a Next.js server to `ps`, started with their working directory in the fixture.
# Nothing outside this test's own temp directory is ever a candidate: the sweep
# is handed the fixture's worktree list and claim list, never the real ones.
set -uo pipefail

SUT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/stop-dev-servers.sh"
[ -f "$SUT" ] || { echo "missing $SUT"; exit 2; }
command -v lsof >/dev/null || { echo "  SKIP — no lsof"; exit 0; }

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "  ok   — $1"; }
fail() { FAIL=$((FAIL+1)); echo "  FAIL — $1"; }

T=$(cd "$(mktemp -d)" && pwd -P)
PIDS=()
cleanup() { for p in "${PIDS[@]:-}"; do [ -n "$p" ] && kill "$p" 2>/dev/null; done; rm -rf "$T"; }
trap cleanup EXIT

# A stand-in server whose working directory is <dir>. Prints its pid.
# Its output goes nowhere: a stand-in holding the $(...) pipe would make the
# capture wait for the whole sleep.
serve() { mkdir -p "$1"; (cd "$1" && exec -a next-server sleep 600) >/dev/null 2>&1 & echo $!; }
alive() { kill -0 "$1" 2>/dev/null; }

echo "stop-dev-servers: sweep"
mkdir -p "$T/wt-claimed/apps/web" "$T/wt-free/apps/api" "$T/elsewhere"
held=$(serve "$T/wt-claimed/apps/web"); PIDS+=("$held")
free=$(serve "$T/wt-free/apps/api");    PIDS+=("$free")
mine=$(serve "$T/elsewhere");           PIDS+=("$mine")
sleep 1
printf '[{"issue":1,"worktree":"%s"}]' "$T/wt-claimed" > "$T/claims.json"
WTS=$(printf '%s\n%s\n' "$T/wt-claimed" "$T/wt-free")

# Too young: nothing goes, even the unclaimed one.
STOP_DEV_WORKTREES="$WTS" STOP_DEV_CLAIMS_JSON="$T/claims.json" STOP_DEV_MIN_AGE=3600 bash "$SUT" --sweep >/dev/null
alive "$free" && ok "a server younger than the minimum age is kept" || fail "a young server was stopped"

# Dry run: lists, stops nothing.
out=$(STOP_DEV_WORKTREES="$WTS" STOP_DEV_CLAIMS_JSON="$T/claims.json" STOP_DEV_MIN_AGE=0 bash "$SUT" --sweep --dry-run)
{ alive "$free" && printf '%s' "$out" | grep -q "would stop $free"; } \
  && ok "--dry-run names the unclaimed server and stops nothing" || fail "--dry-run: '$out'"

# An unreadable claim list stops nothing: it cannot tell who is working.
printf 'not json' > "$T/bad.json"
STOP_DEV_WORKTREES="$WTS" STOP_DEV_CLAIMS_JSON="$T/bad.json" STOP_DEV_MIN_AGE=0 bash "$SUT" --sweep >/dev/null
alive "$free" && ok "an unreadable claim list stops nothing" || fail "stopped a server without knowing the claims"

STOP_DEV_WORKTREES="$WTS" STOP_DEV_CLAIMS_JSON="$T/claims.json" STOP_DEV_MIN_AGE=0 bash "$SUT" --sweep >/dev/null
sleep 1
alive "$free" && fail "the unclaimed worktree's server is still running" || ok "a server in a worktree no claim holds is stopped"
alive "$held" && ok "a server in a claimed worktree is kept" || fail "a claimed worktree's server was stopped"
alive "$mine" && ok "a server outside the agent worktrees is kept" || fail "the owner's own server was stopped"

echo "stop-dev-servers: --worktree"
bash "$SUT" --worktree "$T/wt-claimed" >/dev/null
sleep 1
alive "$held" && fail "--worktree left its server running" || ok "--worktree stops the servers inside it"
alive "$mine" && ok "--worktree leaves servers elsewhere alone" || fail "--worktree stopped a server outside its path"

echo "stop-dev-servers: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
