#!/usr/bin/env bash
# push-retry.test.sh — GitHub's bare "[remote rejected] … (failed)" is tried once more, and
# only that: a push refused for a stated reason is not sent twice.
# Run: bash "$0"
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/tests/lib/suite.sh" || exit 1
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/fixture.sh"
driver_fixture; on_exit_keep_status 'rm -rf "$FIX"'
. "$HERE/../steps/ship.sh" || exit 1
git init -q --bare "$FIX/origin"; git -C "$REPO" remote add origin "$FIX/origin"
git -C "$REPO" switch -q -c tkt-1/work

REAL_GIT=$(command -v git); BIN="$FIX/bin"; mkdir -p "$BIN"; export PUSHES="$FIX/pushes" REFUSALS="$FIX/refusals" REASON="$FIX/reason" REAL_GIT
cat > "$BIN/git" <<'SH'
#!/usr/bin/env bash
for a in "$@"; do
  [ "$a" = push ] || continue
  echo x >> "$PUSHES"
  if [ "$(wc -l < "$PUSHES")" -le "$(cat "$REFUSALS")" ]; then
    echo " ! [remote rejected] tkt-1/work -> tkt-1/work ($(cat "$REASON"))" >&2
    echo "error: failed to push some refs" >&2; exit 1
  fi
done
exec "$REAL_GIT" "$@"
SH
chmod +x "$BIN/git"; export PATH="$BIN:$PATH" DRIVER_PUSH_RETRY_SECS=0

try() { # <refusals> <reason>
  : > "$PUSHES"; echo "$1" > "$REFUSALS"; echo "$2" > "$REASON"
  "$REAL_GIT" -C "$FIX/origin" update-ref -d refs/heads/tkt-1/work 2>/dev/null
  driver_push 1 "$REPO" tkt-1/work ship >/dev/null 2>&1; RC=$?
  N=$(wc -l < "$PUSHES" | tr -d ' ')
  ON=$("$REAL_GIT" -C "$FIX/origin" rev-parse -q --verify refs/heads/tkt-1/work >/dev/null && echo yes || echo no)
}
HEAD_NOW=$("$REAL_GIT" -C "$REPO" rev-parse HEAD)
try 1 failed
want "a bare (failed) once: the second try lands"  "0 2 yes" "$RC $N $ON"
want "and the head is on origin"                   "$HEAD_NOW" "$("$REAL_GIT" -C "$FIX/origin" rev-parse refs/heads/tkt-1/work 2>/dev/null)"
try 2 failed
want "(failed) twice: refused after one retry"     "1 2 no" "$([ "$RC" -ne 0 ] && echo 1 || echo 0) $N $ON"
try 1 "fatal error in commit_refs_rules"
want "GitHub's internal rules error once: the second try lands" "0 2 yes" "$RC $N $ON"
try 1 "pre-receive hook declined"
want "a stated reason is not sent twice"           "1 1 no" "$([ "$RC" -ne 0 ] && echo 1 || echo 0) $N $ON"
suite_end "$FAILED"
