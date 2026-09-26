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

exit $FAILED
