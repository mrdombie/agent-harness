#!/usr/bin/env bash
# coordinator-service.test.sh — "is the coordinator live" is read from what is
# installed, the way install.sh installs it: a launchd job loaded with
# COORDINATOR_SHADOW=0, or a crontab line carrying it. Shadow and absent are not live.
# Run: bash "$0"
set -uo pipefail
for v in $(env | sed -n 's/^\(GIT_[A-Z_]*\)=.*/\1/p'); do unset "$v"; done
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../swarm/tests/fixture.sh"
swarm_fixture; trap 'rm -rf "$FIX"' EXIT
unset COORDINATOR_SERVICE
S="$HERE/coordinator-service.sh"
H="$FIX/home"; mkdir -p "$H/Library/LaunchAgents"
LOADED="$FIX/loaded"; : > "$LOADED"
cat > "$BIN/launchctl" <<SH
#!/usr/bin/env bash
[ "\$1" = list ] && { printf 'PID\tStatus\tLabel\n'; cat "$LOADED"; }
exit 0
SH
chmod +x "$BIN/launchctl"
I="$HERE/../swarm/install.sh"
svc() { HOME="$H" SWARM_UNAME="${UN:-Darwin}" bash "$S"; }
label=$(HOME="$H" bash "$I" --print coordinator | sed -n 's|.*<key>Label</key><string>\(.*\)</string>.*|\1|p')
want_in "the label is the installer's" '^agent-harness\.swarm\.coordinator\.' "$label"

echo "--- launchd ---"
want "nothing installed: off"           "off" "$(svc)"
COORDINATOR_SHADOW=0 HOME="$H" bash "$I" --print coordinator > "$H/Library/LaunchAgents/$label.plist"
want "a definition nobody loaded: off"  "off" "$(svc)"
printf -- '-\t0\t%s\n' "$label" > "$LOADED"
want "loaded with shadow off: live"     "live" "$(svc)"
svc >/dev/null; want "and exits 0" "0" "$?"
HOME="$H" bash "$I" --print coordinator > "$H/Library/LaunchAgents/$label.plist"
want "loaded in shadow: shadow"         "shadow" "$(svc)"
svc >/dev/null; want "which is not live" "1" "$?"
want "another project's state dir does not see it" "off" \
  "$(HOME="$H" SWARM_UNAME=Darwin HARNESS_STATE_DIR="$FIX/other" bash "$S")"

echo "--- crontab ---"
CT="$FIX/crontab.txt"; : > "$CT"
printf '#!/usr/bin/env bash\ncat "%s"\n' "$CT" > "$BIN/crontab"; chmod +x "$BIN/crontab"
UN=Linux; export UN
want "no line: off"                     "off" "$(svc)"
printf '*/5 * * * * COORDINATOR_SHADOW=0 MERGE_LANE_SHADOW=1 /bin/bash tick.sh # %s\n' "$label" > "$CT"
want "a live line: live"                "live" "$(svc)"
printf '*/5 * * * * COORDINATOR_SHADOW=1 MERGE_LANE_SHADOW=1 /bin/bash tick.sh # %s\n' "$label" > "$CT"
want "a shadow line: shadow"            "shadow" "$(svc)"
unset UN

echo "--- the override answers for it ---"
want "COORDINATOR_SERVICE=live"         "live" "$(COORDINATOR_SERVICE=live HOME="$H" bash "$S")"

exit $FAILED
