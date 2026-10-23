#!/usr/bin/env bash
# coordinator-heartbeat-read.test.sh — a heartbeat read that fails is not an empty fleet.
# On a GitHub secondary rate limit the owner read [], dropped every reader from fleet.json,
# and the live view showed a machine heartbeating every few minutes as "no heartbeat".
# Run: bash "$0"
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/tests/lib/suite.sh" || exit 1
for v in $(env | sed -n 's/^\(GIT_[A-Z_]*\)=.*/\1/p'); do unset "$v"; done
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../swarm/tests/fixture.sh"
swarm_fixture; on_exit_keep_status 'rm -rf "$FIX"'
C="$STATE/coordinator"; mkdir -p "$C"
NOWE=$(date +%s)
cat > "$BIN/gh-limited" <<'SH'
#!/usr/bin/env bash
echo "$*" >> "$GH_LOG"
echo "You have exceeded a secondary rate limit." >&2; exit 1
SH
chmod +x "$BIN/gh-limited"
# read [gh] — coord_heartbeat_read in a fresh shell, then coord_fleet over what it returned.
read_fleet() {
  ( export SWARM_NOW="$NOWE" COORDINATOR_HOST=mac SWARM_GH="${1:-$BIN/gh-limited}" GH_BACKOFF_FILE="$FIX/backoff"
    . "$HERE/coordinator-env.sh" >/dev/null 2>&1 || exit 9; . "$HERE/coordinator-sheet.sh" >/dev/null 2>&1 || exit 9
    printf '7\t%s\n' "$COORD_SHEET_LABEL" > "$COORD_SHEET_ISSUE_FILE"
    others=$(coord_heartbeat_read 2>"$FIX/err"); echo "rc=$?" > "$FIX/rc"
    coord_fleet '{"host":"mac","tick":'"$NOWE"'}' "$others" "" | jq -r '[.[].host] | join(" ")' )
}
fleet_file() { # <yomato tick> [old host tick]
  jq -nc --argjson t "$1" --arg o "${2:-}" '{hosts: ([{host: "mac", tick: $t}, {host: "Yomato", tick: $t, builds: 3}]
    + (if $o == "" then [] else [{host: "old-vm", tick: ($o | tonumber)}] end))}' > "$C/fleet.json"
}

echo "--- the read fails: the last fleet's readers are kept ---"
fleet_file $((NOWE - 120)) $((NOWE - 90000))
want "a fresh reader stays in the fleet"        "mac Yomato" "$(read_fleet)"
want_in "  and it is said"                      'heartbeats: read failed, kept last' "$(cat "$FIX/err")"
want "  the read still reports it failed"       "rc=1" "$(cat "$FIX/rc")"
want "  a reader silent past forgetMin still ages out" "0" "$(read_fleet | grep -c old-vm)"
rm -f "$C/fleet.json"
want "no earlier fleet: only this host"          "mac" "$(read_fleet)"

echo "--- the read works: the comments decide, as before ---"
fleet_file $((NOWE - 120))
printf '[]\n' > "$FIX/gh/api-repos_acme_widgets_issues_7_comments_per_page_100.json"
rm -f "$FIX/backoff"   # the rate limit above backs the token off; this read is after it lifted
want "an empty comment list is an empty fleet"   "mac" "$(read_fleet "$BIN/gh")"

suite_end "$FAILED"
