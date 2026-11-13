#!/usr/bin/env bash
# coord-lock.test.sh — a lock with no holder whose age cannot be read was just let go by
# its last holder and made again by another writer: it is busy, never taken over. A
# holder-less lock whose real age is over 60 s was left by a writer that died, and is.
# Run: bash "$0"
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/tests/lib/suite.sh" || exit 1
for v in $(env | sed -n 's/^\(GIT_[A-Z_]*\)=.*/\1/p'); do unset "$v"; done
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../swarm/tests/fixture.sh"
PLANTED="$HERE/.coord-env-planted.$$.sh"
swarm_fixture; on_exit_keep_status 'rm -rf "$FIX" "$PLANTED"'
export PATH="$BIN:$PATH"

# just_let_go <env file> — prints rc|why|dir|pid for coord_lock on a fresh pid-less lock
# while stat reads nothing, as when the earlier holder's dir was gone at the stat.
just_let_go() {
  local lock="$FIX/just.lock"
  rm -rf "$lock"; mkdir "$lock"
  printf '#!/usr/bin/env bash\nexit 1\n' > "$BIN/stat"; chmod +x "$BIN/stat"
  ( . "$1" >/dev/null 2>&1 || exit 9
    coord_lock "$lock" "queue writer"; rc=$?
    printf '%s|%s|%s|%s\n' "$rc" "${COORD_LOCK_WHY:+why}" \
      "$([ -d "$lock" ] && echo dir)" "$([ -e "$lock/pid" ] && echo pid)" )
  rm -f "$BIN/stat"
}

echo "--- a holder-less lock whose age cannot be read is busy, not taken ---"
want "refused with a reason, the lock left as the other writer made it" \
  "1|why|dir|" "$(just_let_go "$HERE/coordinator-env.sh")"

echo "--- a holder-less lock over 60 s old was left by a dead writer and is taken ---"
dead="$FIX/dead.lock"; mkdir "$dead"; touch -t 202001010000 "$dead"
got=$( . "$HERE/coordinator-env.sh" >/dev/null 2>&1 || exit 9
       coord_lock "$dead" "queue writer"; echo "$?|$(cat "$dead/pid" 2>/dev/null)|$$" )
want "taken, and the pid is this shell's" "0|${got##*|}|${got##*|}" "$got"

echo "--- plant: the guard removed, the first case fails ---"
sed '/just let the lock go/d' "$HERE/coordinator-env.sh" > "$PLANTED"
if cmp -s "$PLANTED" "$HERE/coordinator-env.sh"; then
  bad "planted (guard line not found): the plant changed nothing"
else
  p=$(just_let_go "$PLANTED")
  if [ "$p" != "1|why|dir|" ]; then ok "planted (guard removed): the case now fails ($p)"
  else bad "planted (guard removed): the case still passes"; fi
fi

suite_end "$FAILED"
