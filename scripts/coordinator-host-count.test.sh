#!/usr/bin/env bash
# coordinator-host-count.test.sh — the heavy jobs on this host that no tracked run owns,
# each counted once at its top-most process.
#
# On 2026-11-05 the live line said 4 runs while ~9 heavy jobs ran: build-ticket drivers,
# `claude -p --name fix|build` sessions and the develop-hook-red lint sweep, none of them
# a run the coordinator still tracked. host_heavy_untracked reads one ps snapshot.
# Run: bash "$0"
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/tests/lib/suite.sh" || exit 1
for v in $(env | sed -n 's/^\(GIT_[A-Z_]*\)=.*/\1/p'); do unset "$v"; done
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../swarm/tests/fixture.sh"
swarm_fixture; on_exit_keep_status 'rm -rf "$FIX"'

# untracked [tracked pid…] — host_heavy_untracked as the coordinator sources it.
untracked() { ( . "$HERE/coordinator-env.sh" >/dev/null 2>&1 || exit 9; host_heavy_untracked "$@" ); }

echo "--- the fixture's host is empty: no suite sees the developer's real builds ---"
want "nothing on the fixture's host" "" "$(untracked)"

cat > "$FIX/ps.txt" <<'PS'
    1     0 /sbin/launchd
  501     1 bash /kit/driver/build-ticket 18295
  502   501 bash /kit/driver/build-ticket 18295 --step build
  503   501 claude -p --output-format stream-json --verbose --name build --permission-mode auto --add-dir /wt/sh-18295
  610     1 claude -p --output-format stream-json --verbose --name fix --permission-mode auto --add-dir /wt/sh-18178
  700     1 bash /kit/scripts/develop-hook-red.sh sweep
  701   700 npm run lint:all
  800     1 claude -p --output-format json --max-turns 4
  900     1 grep build-ticket
  901     1 vim /kit/driver/build-ticket
PS
printf '#!/usr/bin/env bash\ncat "%s"\n' "$FIX/ps.txt" > "$BIN/host-ps"; chmod +x "$BIN/host-ps"
export COORDINATOR_HOST_PS="$BIN/host-ps"

echo "--- nothing tracked: each heavy unit once, at its top-most process ---"
want "a build driver, a fix session, the lint sweep" \
  "$(printf '501\tbuild\t18295\n610\tfix\tsh-18178\n700\thook-sweep\t-')" "$(untracked)"

echo "--- a tracked run's whole tree is the coordinator's own count ---"
want "only the fix session and the lint sweep" \
  "$(printf '610\tfix\tsh-18178\n700\thook-sweep\t-')" "$(untracked 501)"

echo "--- a tracked ancestor drops its descendants too ---"
want "the sweep's tree tracked at its root" \
  "$(printf '501\tbuild\t18295\n610\tfix\tsh-18178')" "$(untracked 700 1234)"

suite_end "$FAILED"
