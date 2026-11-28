#!/usr/bin/env bash
# gh-write-retry.test.sh — a GitHub write retries GitHub's own failures and nothing else.
# On 2026-11-25 two finished builds parked at ship in ten minutes when one pull-request
# write met a 502. A 5xx or a timeout is tried again; a refusal (403, 422) stops at once.
# Run: bash "$0"
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/tests/lib/suite.sh" || exit 1
HERE="$(cd "$(dirname "$0")" && pwd)"
FAILED=0
ok()  { printf 'OK       %s\n' "$1"; }
bad() { printf 'MISMATCH %s\n' "$1"; FAILED=1; }
want() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 — wanted '$2', got '$3'"; fi; }
want_in() { if printf '%s' "$3" | grep -qF -- "$2"; then ok "$1"; else bad "$1 — no '$2' in: $3"; fi; }
FIX=$(mktemp -d); BIN="$FIX/bin"; mkdir -p "$BIN"; export FIX; trap 'rm -rf "$FIX"' EXIT
# The one function, read out of driver-env.sh, which needs a whole project to source.
eval "$(awk '/^driver_gh_write\(\) \{/,/^\}/' "$HERE/../driver-env.sh")"
declare -F driver_gh_write >/dev/null || { echo "MISMATCH driver_gh_write is not in driver-env.sh"; exit 1; }
export DRIVER_WRITE_RETRY_SEC=0

# fake_gh <answers…> — each call takes the next answer: "ok" exits 0, anything else is
# printed to stderr as gh would and exits 1. Calls are counted in $FIX/calls.
fake_gh() {
  printf '%s\n' "$@" > "$FIX/answers"; : > "$FIX/calls"
  cat > "$BIN/fake-gh" <<'SH'
#!/usr/bin/env bash
echo x >> "$FIX/calls"; n=$(wc -l < "$FIX/calls" | tr -d ' ')
a=$(sed -n "${n}p" "$FIX/answers"); [ -n "$a" ] || a=ok
[ "$a" = ok ] && exit 0
printf '%s\n' "$a" >&2; exit 1
SH
  chmod +x "$BIN/fake-gh"
}
calls() { wc -l < "$FIX/calls" | tr -d ' '; }

echo "--- two 502s, then GitHub answers: the write goes through ---"
fake_gh "HTTP 502: Bad Gateway (https://api.github.com/graphql)" "HTTP 502: Bad Gateway" ok
rc=0; driver_gh_write "$BIN/fake-gh" pr edit 1 >/dev/null 2>&1 || rc=$?
want "it succeeds"                 "0" "$rc"
want "  after three calls"         "3" "$(calls)"

echo "--- a timeout is GitHub's failure too ---"
fake_gh "Post \"https://api.github.com/graphql\": net/http: request canceled (Client.Timeout exceeded) i/o timeout" ok
rc=0; driver_gh_write "$BIN/fake-gh" pr create >/dev/null 2>&1 || rc=$?
want "it succeeds on the retry"    "0" "$rc"

echo "--- a refusal stops at once, with GitHub's words ---"
fake_gh "HTTP 403: Resource not accessible by integration" ok
rc=0; err=$(driver_gh_write "$BIN/fake-gh" pr edit 1 2>&1 >/dev/null) || rc=$?
want "a 403 is not retried"        "1" "$(calls)"
want "  and fails"                 "1" "$rc"
want_in "  saying why"             "403" "$err"

echo "--- GitHub down for every try: it gives up after DRIVER_WRITE_TRIES ---"
fake_gh "HTTP 503" "HTTP 503" "HTTP 503" "HTTP 503" "HTTP 503"
rc=0; driver_gh_write "$BIN/fake-gh" pr edit 1 >/dev/null 2>&1 || rc=$?
want "four tries, then the failure" "4 1" "$(calls) $rc"

echo "--- the ship step's two pull-request writes go through it ---"
SHIP="$HERE/../steps/ship.sh"
want "pr edit is retried"   "1" "$(grep -c 'driver_gh_write swarm_gh pr edit' "$SHIP")"
want "pr create is retried" "1" "$(grep -c 'driver_gh_write swarm_gh pr create' "$SHIP")"

suite_end "$FAILED"
