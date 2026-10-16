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

echo "--- a job runs the plugin version installed now, not the one it was installed from ---"
co=$(i --print coordinator)
want_in "it starts the launcher outside the plugin cache" "<string>$STATE/swarm/run-current.sh</string>" "$co"
want_in "and hands it the job's path under the kit"      '<string>scripts/coordinator-tick.sh</string>' "$co"
want_not_in "never an absolute script path inside the cache" "<string>$(cd "$HERE/../.." && pwd)/scripts/coordinator-tick.sh</string>" "$co"
for j in coordinator merge-lane scheduler; do
  p=$(KIT_ROOT=/some/other/kit/0.0.1 bash "$I" --print "$j" 2>&1 | sed -n '/<key>ProgramArguments/,/<\/array>/p')
  want_not_in "$j: a shell KIT_ROOT elsewhere never makes its path absolute" '<string>/some/other' "$p"
  want_in "$j: and the arguments are the launcher and a kit path" "<string>$STATE/swarm/run-current.sh</string>" "$p"
done
want_in "report keeps its --push" '<string>--push</string>' "$(SWARM_REPORT_URL=https://example.invalid/api bash "$I" --print report 2>&1)"
R="$HERE/../run-current.sh"
CACHE="$FIX/cache/acme-market/agent-harness"
for v in 1.0.0 2.0.0; do mkdir -p "$CACHE/$v/scripts"; printf '#!/usr/bin/env bash\necho "ran %s with KIT_ROOT=$KIT_ROOT args=$*"\n' "$v" > "$CACHE/$v/scripts/job.sh"; done
REG="$FIX/installed_plugins.json"
jq -n --arg p "$CACHE/2.0.0" '{version:2, plugins:{"agent-harness@acme-market":[{scope:"project",installPath:"/nowhere"},{scope:"user",installPath:$p}]}}' > "$REG"
want "installed from 1.0.0, now 2.0.0: it runs 2.0.0" "ran 2.0.0 with KIT_ROOT=$CACHE/2.0.0 args=a b" \
  "$(KIT_ROOT="$CACHE/1.0.0" SWARM_PLUGIN_REGISTRY="$REG" bash "$R" scripts/job.sh a b)"
want "no registry: the baked version"       "ran 1.0.0 with KIT_ROOT=$CACHE/1.0.0 args=" \
  "$(KIT_ROOT="$CACHE/1.0.0" SWARM_PLUGIN_REGISTRY="$FIX/none.json" bash "$R" scripts/job.sh)"
jq -n '{plugins:{"agent-harness@acme-market":[{scope:"user",installPath:"/gone/9.9.9"}]}}' > "$REG"
want "a registry naming a missing path: the baked version" "ran 1.0.0 with KIT_ROOT=$CACHE/1.0.0 args=" \
  "$(KIT_ROOT="$CACHE/1.0.0" SWARM_PLUGIN_REGISTRY="$REG" bash "$R" scripts/job.sh)"
printf 'not json' > "$REG"
want "an unreadable registry: the baked version" "ran 1.0.0 with KIT_ROOT=$CACHE/1.0.0 args=" \
  "$(KIT_ROOT="$CACHE/1.0.0" SWARM_PLUGIN_REGISTRY="$REG" bash "$R" scripts/job.sh)"
out=$(KIT_ROOT="$FIX/nowhere/1.0.0" SWARM_PLUGIN_REGISTRY="$FIX/none.json" bash "$R" scripts/job.sh 2>&1); rc=$?
want "a job found nowhere fails loudly, not as a missing-file shell error" "127" "$rc"
want_in "and says what it looked for"      'run-current: no scripts/job.sh under' "$out"

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

echo "--- the merge lane: opt-in, its own interval, shadow unless told otherwise ---"
want_not_in "not one of the default jobs" 'merge-lane' "$(i --jobs)"
ml=$(i --print merge-lane)
want_in "it runs the lane"                'scripts/merge-lane.sh' "$ml"
want_in "every three minutes"             '<key>StartInterval</key><integer>180</integer>' "$ml"
want_in "shadow by default"               '<key>MERGE_LANE_SHADOW</key><string>1</string>' "$ml"
want_in "live only when the installer says so" '<key>MERGE_LANE_SHADOW</key><string>0</string>' \
  "$(MERGE_LANE_SHADOW=0 bash "$I" --print merge-lane 2>&1)"
want_in "the coordinator carries the lane's mode too" '<key>MERGE_LANE_SHADOW</key><string>1</string>' "$(i --print coordinator)"
want_not_in "no other job carries it"     'MERGE_LANE_SHADOW' "$(i --print scheduler)"
if command -v plutil >/dev/null 2>&1; then
  printf '%s' "$ml" > "$FIX/merge-lane.plist"
  if plutil -lint "$FIX/merge-lane.plist" >/dev/null 2>&1; then ok "merge-lane: the system parses it"; else bad "merge-lane: plutil refused it"; fi
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

cr merge-lane >/dev/null; cr merge-lane >/dev/null
want "the lane is its own line, once"     "1" "$(grep -c 'merge-lane.sh' "$FIX/crontab")"
want_in "every three minutes, in shadow"  '^\*/3 .*MERGE_LANE_SHADOW=1 ' "$(grep merge-lane.sh "$FIX/crontab")"
cr coordinator >/dev/null
want "beside the coordinator, not over it" "1" "$(grep -c 'coordinator-tick.sh' "$FIX/crontab")"
want "and the lane is still there"        "1" "$(grep -c 'merge-lane.sh' "$FIX/crontab")"
cr uninstall merge-lane >/dev/null
want "the lane uninstalls alone"          "0 1" "$(grep -c 'merge-lane.sh' "$FIX/crontab") $(grep -c 'coordinator-tick.sh' "$FIX/crontab")"
cr uninstall coordinator >/dev/null

echo "--- a hold refuses a live coordinator, not a shadow one ---"
printf 'stopped\n' > "$STATE/swarm/HOLD"
out=$(SWARM_UNAME=Linux SWARM_CRONTAB="$BIN/crontab" COORDINATOR_SHADOW=0 bash "$I" coordinator 2>&1); rc=$?
want "live is refused while held"         "3" "$rc"
cr coordinator >/dev/null
want "shadow installs while held"         "1" "$(grep -c 'COORDINATOR_SHADOW=1' "$FIX/crontab")"
out=$(SWARM_UNAME=Linux SWARM_CRONTAB="$BIN/crontab" MERGE_LANE_SHADOW=0 bash "$I" merge-lane 2>&1); rc=$?
want "a live lane is refused while held"  "3" "$rc"
cr merge-lane >/dev/null
want "a shadow lane installs while held"  "1" "$(grep 'merge-lane.sh' "$FIX/crontab" | grep -c 'MERGE_LANE_SHADOW=1')"
rm -f "$STATE/swarm/HOLD"

echo "--- another job on the live view's port is named, and replaced only on request ---"
H="$FIX/home"; mkdir -p "$H/Library/LaunchAgents"
SYS2="$FIX/launchctl.log"; : > "$SYS2"
cat > "$BIN/launchctl" <<SH
#!/usr/bin/env bash
echo "\$*" >> "$SYS2"
[ "\$1" = list ] && printf 'PID\tStatus\tLabel\n4242\t0\tcom.example.old-view\n'
exit 0
SH
chmod +x "$BIN/launchctl"
printf '<plist/>\n' > "$H/Library/LaunchAgents/com.example.old-view.plist"
lv() { HOME="$H" SWARM_UNAME=Darwin SWARM_PORT_HOLDER=4242 bash "$I" live-view 2>&1; }
out=$(lv); rc=$?
want "refused while the port is taken"   "4" "$rc"
want_in "it names who holds the port"    'com\.example\.old-view' "$out"
want_in "and how to replace it"          'SWARM_REPLACE_PORT=1' "$out"
want "the other job was left alone"      "0" "$(grep -c '^unload' "$SYS2")"
if [ -f "$H/Library/LaunchAgents/com.example.old-view.plist" ]; then ok "its definition is still there"; else bad "its definition is still there"; fi
out=$(SWARM_REPLACE_PORT=1 lv); rc=$?
want "replaced on request"               "0" "$rc"
want_in "the old job was unloaded"       'unload .*com\.example\.old-view\.plist' "$(cat "$SYS2")"
if [ -f "$STATE/swarm/replaced/com.example.old-view.plist" ]; then ok "its definition was set aside, not deleted"; else bad "its definition was set aside, not deleted"; fi
want_in "ours was loaded"                'load .*agent-harness\.swarm\.live-view\.' "$(grep '^load' "$SYS2")"
out=$(HOME="$H" SWARM_UNAME=Darwin SWARM_PORT_HOLDER= bash "$I" live-view 2>&1); rc=$?
want "a free port installs at once"      "0" "$rc"

echo "--- on Linux with a user systemd: units, not a crontab line (#165) ---"
# A recorder stands in for systemctl and loginctl: nothing here reaches the
# machine's own user manager, and the unit directory is under $FIX.
UD="$FIX/systemd-user"; SDLOG="$FIX/systemctl.log"; : > "$SDLOG"; LGLOG="$FIX/loginctl.log"; : > "$LGLOG"
mkdir -p "$FIX/sd-active"
cat > "$BIN/systemctl" <<SH
#!/usr/bin/env bash
echo "\$*" >> "$SDLOG"
[ "\$1" = --user ] || exit 1
case "\$2" in
  show-environment) echo HOME=/x ;;
  is-active) if [ -e "$FIX/sd-active/\$3" ]; then echo active; else echo inactive; exit 3; fi ;;
  show) printf 'n/a\n' ;;
esac
exit 0
SH
cat > "$BIN/loginctl" <<SH
#!/usr/bin/env bash
echo "\$*" >> "$LGLOG"
echo "Linger=\${FAKE_LINGER:-no}"
SH
chmod +x "$BIN/systemctl" "$BIN/loginctl"
printf '0 3 * * * /usr/bin/backup\n' > "$FIX/crontab"
sd() { SWARM_UNAME=Linux SWARM_SYSTEMCTL="$BIN/systemctl" SWARM_LOGINCTL="$BIN/loginctl" \
       SWARM_SYSTEMD_DIR="$UD" SWARM_CRONTAB="$BIN/crontab" bash "$I" "$@" 2>&1; }
unit() { ls "$UD"/agent-harness.swarm."$1".*."$2" 2>/dev/null | head -1; } # <job> <service|timer>

out=$(sd coordinator); rc=$?
want "the coordinator installs"            "0" "$rc"
svc=$(unit coordinator service); tmr=$(unit coordinator timer)
if [ -n "$svc" ]; then ok "it writes a service unit"; else bad "it writes a service unit — none in $UD: $(ls "$UD" 2>&1)"; fi
if [ -n "$tmr" ]; then ok "and a timer beside it"; else bad "and a timer beside it"; fi
s=$(cat "$svc" 2>/dev/null); t=$(cat "$tmr" 2>/dev/null)
want_in "the timer ticks every five minutes" '^OnUnitActiveSec=300$' "$t"
want_in "and starts after boot"             '^OnBootSec=' "$t"
want_in "the timer is wanted by timers.target" '^WantedBy=timers\.target$' "$t"
want_in "it starts the launcher outside the plugin cache" "^ExecStart=/bin/bash \"$STATE/swarm/run-current.sh\" \"scripts/coordinator-tick.sh\"$" "$s"
want_in "a real PATH, the installer's"      "^Environment=\"PATH=[^\"]*$BIN" "$s"
want_in "where the repo is"                 "^Environment=\"HARNESS_MAIN_REPO=$REPO\"$" "$s"
want_in "where the state is"                "^Environment=\"HARNESS_STATE_DIR=$STATE\"$" "$s"
want_in "which config to read"              '^Environment="HARNESS_CFG_PATH=' "$s"
want_in "which kit"                         '^Environment="KIT_ROOT=' "$s"
want_in "shadow by default"                 '^Environment="COORDINATOR_SHADOW=1"$' "$s"
want_in "the lane's mode too"               '^Environment="MERGE_LANE_SHADOW=1"$' "$s"
want_in "a judge outlives the tick"         '^KillMode=process$' "$s"
want_in "it logs where the plist logs"      "^StandardOutput=append:$STATE/logs/coordinator\.out\.log$" "$s"
want_not_in "an interval job is not kept alive" '^Restart=' "$s"
want_in "systemd was told to re-read"       '^--user daemon-reload$' "$(cat "$SDLOG")"
want_in "the timer was enabled"             '^--user enable .*agent-harness\.swarm\.coordinator\..*\.timer' "$(cat "$SDLOG")"
want_in "and (re)started"                   '^--user restart .*agent-harness\.swarm\.coordinator\..*\.timer' "$(cat "$SDLOG")"
want "no crontab line instead"              "0" "$(grep -c 'coordinator-tick' "$FIX/crontab")"
want "the owner's crontab untouched"        "1" "$(grep -c '/usr/bin/backup' "$FIX/crontab")"
want_in "the runner was copied out"         '.' "$(ls "$STATE/swarm/run-current.sh" 2>/dev/null)"

echo "--- linger off: one clear warning, and no sudo run ---"
want_in "it says timers need a session"     'linger' "$out"
want_in "and names the fix"                 'sudo loginctl enable-linger' "$out"
want "it is one line"                       "1" "$(grep -c 'enable-linger' <<<"$out")"
want_not_in "it never ran enable-linger itself" 'enable-linger' "$(cat "$LGLOG" "$SDLOG")"
out=$(FAKE_LINGER=yes sd coordinator)
want_not_in "linger on: no warning"         'enable-linger' "$out"

echo "--- live mode, and a timer that does not double ---"
SWARM_UNAME=Linux SWARM_SYSTEMCTL="$BIN/systemctl" SWARM_LOGINCTL="$BIN/loginctl" SWARM_SYSTEMD_DIR="$UD" \
  COORDINATOR_SHADOW=0 bash "$I" coordinator >/dev/null 2>&1
want_in "going live rewrites the unit"      '^Environment="COORDINATOR_SHADOW=0"$' "$(cat "$(unit coordinator service)")"
want "one service, one timer"               "2" "$(ls "$UD" | grep -c 'swarm\.coordinator\.')"
sd coordinator >/dev/null

echo "--- the merge lane: its own interval ---"
sd merge-lane >/dev/null
want_in "every three minutes"               '^OnUnitActiveSec=180$' "$(cat "$(unit merge-lane timer)" 2>/dev/null)"
want_in "it runs the lane"                  'scripts/merge-lane\.sh' "$(cat "$(unit merge-lane service)" 2>/dev/null)"
want_not_in "the lane carries no coordinator mode" 'COORDINATOR_SHADOW' "$(cat "$(unit merge-lane service)" 2>/dev/null)"

echo "--- the live view is kept alive, with no timer ---"
out=$(SWARM_PORT_HOLDER= sd live-view); rc=$?
want "it installs"                          "0" "$rc"
lv=$(cat "$(unit live-view service)" 2>/dev/null)
want_in "it restarts whenever it dies"      '^Restart=always$' "$lv"
want_in "and starts with the user manager"  '^WantedBy=default\.target$' "$lv"
want_in "it runs the view"                  '"swarm/live-view\.sh"' "$lv"
want "and has no timer"                     "" "$(unit live-view timer)"
want_in "the service itself was enabled"    '^--user enable .*agent-harness\.swarm\.live-view\..*\.service' "$(cat "$SDLOG")"
want_in "the scheduler's own interval"      '^OnUnitActiveSec=300$' "$(sd scheduler >/dev/null; cat "$(unit scheduler timer)" 2>/dev/null)"
want_in "the scheduler's agents outlive its pass" '^KillMode=process$' "$(cat "$(unit scheduler service)" 2>/dev/null)"

echo "--- systemd quoting: a % or a quote in a path survives ---"
p=$(KIT_ROOT='/k it/100%/"q"' sd --print scheduler)
want_in "% is escaped, quotes are escaped"  '^Environment="KIT_ROOT=/k it/100%%/\\"q\\""$' "$p"
want_in "--print shows the units here"      '^OnUnitActiveSec=300$' "$p"

echo "--- another service on the live view's port is named and refused ---"
out=$(SWARM_PORT_HOLDER=4242 SWARM_PROC="$FIX/proc" sd live-view); rc=$?
want "refused while the port is taken"      "4" "$rc"
want_in "it names the pid"                  'pid 4242' "$out"
mkdir -p "$FIX/proc/4243"; printf '0::/user.slice/user-1000.slice/user@1000.service/app.slice/%s\n' \
  "$(basename "$(unit live-view service)")" > "$FIX/proc/4243/cgroup"
out=$(SWARM_PORT_HOLDER=4243 SWARM_PROC="$FIX/proc" sd live-view); rc=$?
want "our own view on the port is a reinstall, not a clash" "0" "$rc"

echo "--- status reads the units back ---"
touch "$FIX/sd-active/$(basename "$(unit coordinator timer)")"
st=$(sd status)
want_in "the coordinator's timer is active" '^coordinator +timer active' "$st"
want_in "an installed job not running says so" '^scheduler +timer inactive' "$st"
want_in "the merge lane is listed once installed" '^merge-lane ' "$st"
want_in "status repeats the linger warning" 'enable-linger' "$st"
want_not_in "status installs nothing"       'enable|restart' "$(: > "$SDLOG"; sd status >/dev/null; cat "$SDLOG")"

echo "--- held: a live install is refused and touches nothing ---"
: > "$SDLOG"; rm -f "$(unit repair-watch service)" "$(unit repair-watch timer)"
printf 'stopped\n' > "$STATE/swarm/HOLD"
out=$(sd repair-watch); rc=$?
want "refused while held"                   "3" "$rc"
want "no unit written"                      "" "$(unit repair-watch service)"
want_not_in "nothing enabled"               'enable|restart' "$(cat "$SDLOG")"
out=$(sd coordinator); rc=$?
want "a shadow coordinator still installs"  "0" "$rc"
rm -f "$STATE/swarm/HOLD"

echo "--- uninstall disables and removes, and is idempotent ---"
: > "$SDLOG"
out=$(sd uninstall coordinator)
want "the coordinator's units are gone"     "" "$(unit coordinator service)$(unit coordinator timer)"
want_in "its timer was disabled and stopped" '^--user disable --now .*coordinator\..*\.timer' "$(cat "$SDLOG")"
want_in "and it says so"                    'removed agent-harness\.swarm\.coordinator\.' "$out"
want_in "uninstalling twice is fine"        'was not installed' "$(sd uninstall coordinator)"
want "the owner's crontab survives"         "1" "$(grep -c '/usr/bin/backup' "$FIX/crontab")"
sd uninstall >/dev/null
want "uninstall with no job removes them all" "0" "$(ls "$UD" | grep -c 'agent-harness\.swarm\.')"
want_in "and the live view was stopped"     '^--user disable --now .*live-view\..*\.service' "$(cat "$SDLOG")"

echo "--- systemd present but not answering: the crontab, as before ---"
printf '#!/usr/bin/env bash\necho "$*" >> "%s"\nexit 1\n' "$SDLOG" > "$BIN/systemctl-dead"; chmod +x "$BIN/systemctl-dead"
SWARM_UNAME=Linux SWARM_SYSTEMCTL="$BIN/systemctl-dead" SWARM_SYSTEMD_DIR="$UD" SWARM_CRONTAB="$BIN/crontab" \
  bash "$I" coordinator >/dev/null 2>&1
want "it falls back to one crontab line"    "1" "$(grep -c 'coordinator-tick' "$FIX/crontab")"
want "and writes no unit"                   "0" "$(ls "$UD" | grep -c 'agent-harness\.swarm\.')"
SWARM_UNAME=Linux SWARM_SYSTEMCTL="$BIN/systemctl-dead" SWARM_CRONTAB="$BIN/crontab" bash "$I" uninstall coordinator >/dev/null 2>&1

echo "--- macOS keeps launchd even where systemctl would answer ---"
: > "$SDLOG"; : > "$SYS2"
HOME="$H" SWARM_UNAME=Darwin SWARM_PORT_HOLDER= SWARM_SYSTEMCTL="$BIN/systemctl" SWARM_SYSTEMD_DIR="$UD" \
  bash "$I" scheduler >/dev/null 2>&1
if ls "$H/Library/LaunchAgents/"agent-harness.swarm.scheduler.*.plist >/dev/null 2>&1; then ok "a plist was written"; else bad "a plist was written"; fi
want_in "and loaded with launchctl"         '^load .*agent-harness\.swarm\.scheduler\.' "$(cat "$SYS2")"
want "systemctl was never asked"            "0" "$(grep -c . "$SDLOG")"

echo "--- a crontab line left from before systemd answered is not hidden (#168 review) ---"
dead() { SWARM_UNAME=Linux SWARM_SYSTEMCTL="$BIN/systemctl-dead" SWARM_CRONTAB="$BIN/crontab" bash "$I" "$@" >/dev/null 2>&1; }
COORDINATOR_SHADOW=0 dead coordinator
want "setup: a live coordinator in crontab" "1" "$(grep -c 'COORDINATOR_SHADOW=0.*coordinator-tick' "$FIX/crontab")"
st=$(sd status)
want_in "status names the stray crontab line" '^coordinator +.*crontab' "$st"
out=$(sd uninstall coordinator)
want "uninstall under systemd removes the crontab line" "0" "$(grep -c 'coordinator-tick' "$FIX/crontab")"
want_in "and says so"                       'removed .*coordinator.* from crontab' "$out"
want_not_in "it does not claim nothing was there" 'was not installed' "$out"
want "the owner's line survives"            "1" "$(grep -c '/usr/bin/backup' "$FIX/crontab")"
COORDINATOR_SHADOW=0 dead coordinator; dead merge-lane
sd coordinator >/dev/null; sd merge-lane >/dev/null
want "a systemd install replaces the crontab line" "0" "$(grep -c 'coordinator-tick' "$FIX/crontab")"
want "so exactly one scheduler: the timer"  "1" "$(ls "$UD" | grep -c 'swarm\.coordinator\..*\.timer$')"
want "the lane too"                         "0 1" "$(grep -c 'merge-lane.sh' "$FIX/crontab") $(ls "$UD" | grep -c 'swarm\.merge-lane\..*\.timer$')"
sd uninstall >/dev/null

echo "--- the timers keep their interval to the second ---"
want_in "AccuracySec is 1s"                 '^AccuracySec=1s$' "$(sd --print merge-lane)"

echo "--- on WSL, linger is not enough: the instance must stay up ---"
printf 'Linux version 6.6.0-microsoft-standard-WSL2 (gcc)\n' > "$FIX/version-wsl"
printf 'Linux version 6.6.0-generic (gcc)\n' > "$FIX/version-plain"
out=$(SWARM_PROC_VERSION="$FIX/version-wsl" sd coordinator)
want_in "WSL: it says the instance must stay up" 'WSL.*vmIdleTimeout' "$out"
want "in one line"                          "1" "$(grep -c 'vmIdleTimeout' <<<"$out")"
want_not_in "not WSL: no such line"         'vmIdleTimeout' "$(SWARM_PROC_VERSION="$FIX/version-plain" sd coordinator)"
sd uninstall coordinator >/dev/null

echo "--- a failed enable says which unit and why ---"
cat > "$BIN/systemctl-noenable" <<SH
#!/usr/bin/env bash
[ "\$2" = enable ] && { echo "Failed to enable unit: boom" >&2; exit 1; }
exec "$BIN/systemctl" "\$@"
SH
chmod +x "$BIN/systemctl-noenable"
out=$(SWARM_UNAME=Linux SWARM_SYSTEMCTL="$BIN/systemctl-noenable" SWARM_LOGINCTL="$BIN/loginctl" SWARM_SYSTEMD_DIR="$UD" \
      bash "$I" scheduler 2>&1); rc=$?
want "it fails"                             "1" "$rc"
want_in "it names the unit"                 'install: systemctl --user enable agent-harness\.swarm\.scheduler\..*\.timer failed' "$out"
want_in "with systemctl's own reason"       'boom' "$out"
sd uninstall scheduler >/dev/null

echo "--- the PATH frozen into the unit must find the tools ---"
mkdir -p "$FIX/tools"; for b in claude node; do printf '#!/bin/sh\n' > "$FIX/tools/$b"; chmod +x "$FIX/tools/$b"; done
out=$(PATH="$FIX/tools:$BIN:/usr/bin:/bin" sd scheduler)
want_not_in "all found: no warning"         'not on the PATH' "$out"
out=$(PATH="$BIN:/usr/bin:/bin" sd scheduler)
want_in "a missing tool is named"           'install: .*claude.* not on the PATH' "$out"
sd uninstall scheduler >/dev/null

exit $FAILED
