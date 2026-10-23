#!/usr/bin/env bash
# gh-read.test.sh — gh_read never answers empty on a failure: an exit, an error body
# that came with exit 0, or GraphQL errors with no data are unknown (exit 69, nothing
# on stdout, one "unknown — <what>" line); a 404 is an answer (exit 68); a real empty
# answer is empty; a --jq filter runs only on a body that was checked.
# Run: bash "$0"
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/tests/lib/suite.sh" || exit 1
for v in $(env | sed -n 's/^\(GIT_[A-Z_]*\)=.*/\1/p'); do unset "$v"; done
HERE="$(cd "$(dirname "$0")" && pwd)"
T=$(mktemp -d); on_exit_keep_status 'rm -rf "$T"'
FAILED=0
ok()  { echo "OK       $1"; }
bad() { echo "MISMATCH $1"; FAILED=1; }

# The forge: $T/mode says how it answers.
cat > "$T/gh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$T/calls"
case "$(cat "$T/mode")" in
  exit)    echo 'gh: HTTP 502: Bad Gateway' >&2; exit 1 ;;
  limit)   echo 'gh: API rate limit exceeded for user ID 1. (HTTP 403)' >&2; exit 1 ;;
  body403) echo '{"message":"API rate limit exceeded for user ID 1.","documentation_url":"https://docs.github.com/rest/overview/rate-limits-for-the-rest-api","status":"403"}' ;;
  gqlerr)  echo '{"errors":[{"type":"RATE_LIMITED","message":"API rate limit exceeded"}],"data":null}' ;;
  missing) echo 'gh: Not Found (HTTP 404)' >&2; exit 1 ;;
  empty)   echo '[]' ;;
  rows)    echo '[{"number":17,"title":"a"},{"number":18,"title":"b"}]' ;;
  commit)  echo '{"sha":"abc","commit":{"message":"fix"},"files":[]}' ;;
  partial) echo '{"data":{"repository":{"i1":{"number":1}}},"errors":[{"message":"no i2"}]}' ;;
esac
SH
chmod +x "$T/gh"
export T SWARM_GH="$T/gh" GH_BACKOFF_FILE="$T/backoff"
. "$HERE/gh-batch.sh"

read_as() { # <mode> [jq] — sets OUT, ERR, RC
  echo "$1" > "$T/mode"; rm -f "$GH_BACKOFF_FILE"
  if [ -n "${2:-}" ]; then OUT=$(gh_read "the open tickets" api "repos/o/r/issues" --jq "$2" 2>"$T/err"); RC=$?
  else OUT=$(gh_read "the open tickets" api "repos/o/r/issues" 2>"$T/err"); RC=$?; fi
  ERR=$(cat "$T/err")
}

for m in exit limit body403 gqlerr; do
  for q in "" 'length'; do
    read_as "$m" "$q"
    [ "$RC" = 69 ] && [ -z "$OUT" ] && ok "$m${q:+ with --jq}: exit 69, nothing on stdout" || bad "$m${q:+ --jq}: rc=$RC out='$OUT'"
    case "$ERR" in "unknown — the open tickets could not be read ("*")") ok "$m${q:+ with --jq}: one unknown line naming what" ;;
      *) bad "$m${q:+ --jq}: err='$ERR'" ;; esac
  done
done
# The shape that hid 17 open tickets: a count of a failed read.
read_as body403 'length'; [ "$OUT" != 0 ] && [ "$OUT" != 2 ] && ok "a 403 body never counts as a number of rows" || bad "a 403 body counted as $OUT"
read_as limit
[ -s "$GH_BACKOFF_FILE" ] && ok "a rate-limit refusal still starts the shared backoff" || bad "no backoff after a rate limit"

read_as missing; [ "$RC" = 68 ] && [ -z "$OUT" ] && [ -z "$ERR" ] && ok "a 404 is an answer: exit 68, silent" || bad "404: rc=$RC err='$ERR'"
read_as empty;   [ "$RC" = 0 ] && [ "$OUT" = "[]" ] && ok "a real empty list is empty, exit 0" || bad "empty: rc=$RC out='$OUT'"
read_as empty length; [ "$RC" = 0 ] && [ "$OUT" = 0 ] && ok "a real empty list counts 0" || bad "empty count: $OUT"
read_as rows length;  [ "$RC" = 0 ] && [ "$OUT" = 2 ] && ok "rows count as rows" || bad "rows: $OUT"
read_as rows '.[].number'; [ "$(printf '%s' "$OUT" | tr '\n' ' ')" = "17 18" ] && ok "--jq prints raw like gh's" || bad "raw: '$OUT'"
read_as commit '.commit.message'; [ "$RC" = 0 ] && [ "$OUT" = fix ] && ok "an object with a nested message is no error body" || bad "commit: rc=$RC '$OUT'"
read_as partial '.data.repository.i1.number'; [ "$RC" = 0 ] && [ "$OUT" = 1 ] && ok "GraphQL data beside an error is an answer" || bad "partial: rc=$RC '$OUT'"
read_as rows '.[] | .nope | .deeper.x'
[ "$RC" = 0 ] && ok "a filter that matches nothing is an empty answer" || bad "filter miss: rc=$RC"
read_as rows '.[0] | keys[] | tonumber'
[ "$RC" = 69 ] && [ -z "$OUT" ] && ok "a filter that errors is unknown, not empty" || bad "filter error: rc=$RC '$OUT'"
grep -q -- '--jq' "$T/calls" && bad "the filter was handed to gh (an error body would run through it)" || ok "the filter runs here, never in gh"

suite_end "$FAILED"
