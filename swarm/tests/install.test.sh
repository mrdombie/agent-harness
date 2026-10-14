#!/usr/bin/env bash
# install.test.sh — six jobs were installed by hand on the machine this came
# from, and three of them were running a version nobody could name. So what
# this asserts is that the definition is GENERATED: it parses, it names the
# right script, it carries the environment a launchd job does not inherit, and
# two projects on one machine do not collide.
#
# Nothing here loads anything: every case goes through --print.
# Run: bash "$0"
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/fixture.sh"
swarm_fixture; trap 'rm -rf "$FIX"' EXIT
I="$HERE/../install.sh"
i() { bash "$I" "$@" 2>&1; }

echo "--- the jobs a project gets ---"
want "three without a report url" "live-view scheduler repair-watch" "$(i --jobs | tr '\n' ' ' | sed 's/ $//')"
want "four with one"              "live-view scheduler repair-watch report" \
     "$(SWARM_REPORT_URL=https://example.invalid/api bash "$I" --jobs | tr '\n' ' ' | sed 's/ $//')"

echo "--- each definition is well-formed and names its own script ---"
for j in live-view scheduler repair-watch; do
  p=$(i --print "$j")
  want_in "$j: it is a plist"        '<plist version="1.0">' "$p"
  want_in "$j: it runs its script"   "swarm/$j.sh" "$p"
  if command -v plutil >/dev/null 2>&1; then
    printf '%s' "$p" > "$FIX/$j.plist"
    if plutil -lint "$FIX/$j.plist" >/dev/null 2>&1; then ok "$j: the system parses it"; else bad "$j: plutil refused it"; fi
  fi
done

echo "--- the environment a launchd job does not inherit ---"
p=$(i --print scheduler)
want_in "a real PATH"              '<key>PATH</key>' "$p"
want_in "where the repo is"        "<key>HARNESS_MAIN_REPO</key><string>$REPO</string>" "$p"
want_in "where the state is"       "<key>HARNESS_STATE_DIR</key><string>$STATE</string>" "$p"
want_in "and which config to read" '<key>HARNESS_CFG_PATH</key>' "$p"

echo "--- kept alive, or on an interval, never both ---"
lv=$(i --print live-view)
want_in "the view is kept alive"   '<key>KeepAlive</key><true/>' "$lv"
want_not_in "and has no interval"  'StartInterval' "$lv"
sc=$(i --print scheduler)
want_in "the scheduler has one"    '<key>StartInterval</key><integer>300</integer>' "$sc"
want_not_in "and is not kept alive" 'KeepAlive' "$sc"
want_in "the repair pass is slower" '<integer>600</integer>' "$(i --print repair-watch)"

echo "--- two projects on one machine do not collide ---"
a=$(i --print scheduler | grep '<key>Label</key>')
b=$(HARNESS_STATE_DIR="$FIX/other-state" bash "$I" --print scheduler 2>/dev/null | grep '<key>Label</key>')
want_in "the label is the kit's, not a project's" 'agent-harness\.swarm\.scheduler\.' "$a"
if [ "$a" = "$b" ]; then bad "a second state dir must get its own label"; else ok "a second state dir gets its own label"; fi

echo "--- a job that does not exist is refused, not invented ---"
if i --print nonsense >/dev/null 2>&1; then bad "an unknown job must refuse"; else ok "an unknown job refuses"; fi

echo "--- the report job only exists when there is somewhere to send ---"
want_not_in "absent by default" 'report' "$(i --jobs)"
want_in "present when configured" '--push' \
  "$(SWARM_REPORT_URL=https://example.invalid/api bash "$I" --print report 2>&1)"

echo "--- the coordinator: opt-in, every five minutes, shadow unless told otherwise ---"
want_not_in "not one of the default jobs" 'coordinator' "$(i --jobs)"
co=$(i --print coordinator)
want_in "it runs the tick"                'scripts/coordinator-tick.sh' "$co"
want_in "every five minutes"              '<key>StartInterval</key><integer>300</integer>' "$co"
want_in "shadow by default"               '<key>COORDINATOR_SHADOW</key><string>1</string>' "$co"
want_in "a judge outlives the tick"       '<key>AbandonProcessGroup</key><true/>' "$co"
want_in "live only when the installer says so" '<key>COORDINATOR_SHADOW</key><string>0</string>' \
  "$(COORDINATOR_SHADOW=0 bash "$I" --print coordinator 2>&1)"
want_in "anything but 0 is shadow"        '<key>COORDINATOR_SHADOW</key><string>1</string>' \
  "$(COORDINATOR_SHADOW=no bash "$I" --print coordinator 2>&1)"
want_not_in "no other job carries it"     'COORDINATOR_SHADOW' "$(i --print scheduler)"
if command -v plutil >/dev/null 2>&1; then
  printf '%s' "$co" > "$FIX/coordinator.plist"
  if plutil -lint "$FIX/coordinator.plist" >/dev/null 2>&1; then ok "coordinator: the system parses it"; else bad "coordinator: plutil refused it"; fi
fi

echo "--- off macOS it is one crontab line, installed and removed idempotently ---"
cat > "$BIN/crontab" <<'SH'
#!/usr/bin/env bash
case "$1" in
  -l) [ -f "$FIX/crontab" ] && cat "$FIX/crontab" || { echo "no crontab for you" >&2; exit 1; } ;;
  -)  cat > "$FIX/crontab" ;;
esac
SH
chmod +x "$BIN/crontab"
printf '0 3 * * * /usr/bin/backup\n' > "$FIX/crontab"
cr() { SWARM_UNAME=Linux SWARM_CRONTAB="$BIN/crontab" bash "$I" "$@" 2>&1; }
cr coordinator >/dev/null; cr coordinator >/dev/null
want "installed twice is one line"        "1" "$(grep -c 'coordinator-tick.sh' "$FIX/crontab")"
want_in "every five minutes, in shadow"   '^\*/5 .*COORDINATOR_SHADOW=1 ' "$(grep coordinator-tick "$FIX/crontab")"
want "the owner's own lines are kept"     "1" "$(grep -c '/usr/bin/backup' "$FIX/crontab")"
want_in "it carries a PATH that finds claude" ' PATH=[^ ]*'"$BIN" "$(grep coordinator-tick "$FIX/crontab")"
SWARM_UNAME=Linux SWARM_CRONTAB="$BIN/crontab" COORDINATOR_SHADOW=0 bash "$I" coordinator >/dev/null 2>&1
want "going live replaces the line"       "1" "$(grep -c 'COORDINATOR_SHADOW=0' "$FIX/crontab")"
want "and does not double it"             "1" "$(grep -c 'coordinator-tick.sh' "$FIX/crontab")"
cr uninstall coordinator >/dev/null; out=$(cr uninstall coordinator)
want "uninstalled"                        "0" "$(grep -c 'coordinator-tick.sh' "$FIX/crontab")"
want_in "and uninstalling twice is fine"  'was not installed' "$out"
want "the owner's own lines survive"      "1" "$(grep -c '/usr/bin/backup' "$FIX/crontab")"

echo "--- a hold refuses a live coordinator, not a shadow one ---"
printf 'stopped\n' > "$STATE/swarm/HOLD"
out=$(SWARM_UNAME=Linux SWARM_CRONTAB="$BIN/crontab" COORDINATOR_SHADOW=0 bash "$I" coordinator 2>&1); rc=$?
want "live is refused while held"         "3" "$rc"
cr coordinator >/dev/null
want "shadow installs while held"         "1" "$(grep -c 'COORDINATOR_SHADOW=1' "$FIX/crontab")"
rm -f "$STATE/swarm/HOLD"

exit $FAILED
