#!/usr/bin/env bash
# shared-install.test.sh — a host keeps its shared clone's install at the trunk's
# lockfile with nobody running npm by hand: a moved lock installs once, under the
# lock, never while a build on the host is past its first steps; an unchanged lock
# runs nothing; a failed install leaves the old one in place. Each guard is planted
# out of a copy of the kit, and the case it holds must then fail.
# Run: bash "$0"
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/tests/lib/suite.sh" || exit 1
for v in $(env | sed -n 's/^\(GIT_[A-Z_]*\)=.*/\1/p'); do unset "$v"; done
unset KIT_ROOT HARNESS_KIT_ROOT
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../swarm/tests/fixture.sh"
swarm_fixture; HOLDER=""
# Never `kill 0`: that signals this whole process group, the shell that ran the suite too.
on_exit_keep_status '[ -z "$HOLDER" ] || kill "$HOLDER" 2>/dev/null; rm -rf "$FIX"'
git config --global --get user.email >/dev/null 2>&1 || export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
C="$STATE/coordinator"
SI="$HERE/shared-install.sh"

# The trunk on origin, and the shared clone with an install recorded at lock v1.
ORIGIN="$FIX/origin.git"; git init -q --bare "$ORIGIN"
git -C "$REPO" checkout -q -b develop
printf '{"name":"w","workspaces":["packages/*"]}\n' > "$REPO/package.json"
mkdir -p "$REPO/packages/ui"; printf '{"name":"@w/ui"}\n' > "$REPO/packages/ui/package.json"
printf '{"lock":1}\n' > "$REPO/package-lock.json"
printf 'node_modules\n' > "$REPO/.gitignore"
git -C "$REPO" add -A; git -C "$REPO" commit -qm "v1"
git -C "$REPO" remote add origin "$ORIGIN"; git -C "$REPO" push -q origin develop
git -C "$REPO" fetch -q origin "+refs/heads/develop:refs/remotes/origin/develop"
PUSHER="$FIX/pusher"; git clone -q -b develop "$ORIGIN" "$PUSHER"
V1=$(git -C "$REPO" rev-parse HEAD:package-lock.json)

# The install command: records where and from what lock it ran; FAKE_NPM picks how it ends.
cat > "$BIN/fake-npm" <<'SH'
#!/usr/bin/env bash
printf '%s %s\n' "$PWD" "$(git hash-object package-lock.json)" >> "$FIX/npm.log"
printf '%s\n' "$*" >> "$FIX/npm-args.log"
# A whole tree: the workspace linked in, as npm ci leaves it; the modes below spoil it.
whole() { mkdir -p node_modules/left-pad node_modules/@w packages/ui/node_modules; ln -sfn ../../packages/ui node_modules/@w/ui; echo new > node_modules/marker; }
# A required dependency left out, under a package npm ci "installed".
spoil() { mkdir -p node_modules/eslint; printf '{"name":"eslint","version":"9.1.0","dependencies":{"@eslint-community/eslint-utils":"^4.0.0"}}\n' > node_modules/eslint/package.json; }
mode="${FAKE_NPM:-ok}"
# missing-once: the first install of a check is spoiled, the next is whole.
[ "$mode" != missing-once ] || { [ -f "$FIX/npm-once" ] && mode=ok || { : > "$FIX/npm-once"; mode=missing; }; }
case "$mode" in
  ok)   [ -f "$STATE/coordinator/shared-install-hold" ] && echo held >> "$FIX/held.log"
        whole ;;
  missing)  whole; spoil ;;
  optional) whole; mkdir -p node_modules/sassy
            printf '{"name":"sassy","version":"1.0.0","peerDependencies":{"sass":"^1"},"peerDependenciesMeta":{"sass":{"optional":true}}}\n' > node_modules/sassy/package.json ;;
  stale-ws) whole; printf '{"name":"@w/ui","stale":true}\n' > packages/ui/package.json ;;
  fail) mkdir -p node_modules; echo partial > node_modules/marker; exit 1 ;;
  slow) sleep 30 ;;
esac
SH
chmod +x "$BIN/fake-npm"
export SHARED_INSTALL_CMD="$BIN/fake-npm"
# The tree is listed by the real npm (npm ls reads node_modules only); no load probes but where a case sets them.
export SHARED_INSTALL_VERIFY=""
unset COORDINATOR_SHADOW SHARED_INSTALL SHARED_INSTALL_TIMEOUT_SEC SHARED_INSTALL_NPM SHARED_INSTALL_REVERIFY_EVERY

reset_install() { # <stamp blob> — an old install, recorded at that lock
  rm -rf "$REPO/node_modules" "$REPO/packages/ui/node_modules" "$C"
  mkdir -p "$REPO/node_modules/@w" "$REPO/packages/ui/node_modules" "$C"
  ln -sfn ../../packages/ui "$REPO/node_modules/@w/ui"
  echo old > "$REPO/node_modules/marker"; echo old > "$REPO/packages/ui/node_modules/marker"
  rm -f "$FIX/npm-once"
  [ -z "$1" ] || printf '%s %s 2026-10-20T00:00:00Z\n' "$1" "$(git -C "$REPO" rev-parse HEAD)" > "$REPO/node_modules/.harness-shared-install"
  rm -f "$STATE/runs"/*; rm -rf "$STATE/driver"; : > "$FIX/npm.log"
}
move_lock() { # <n> — the trunk's lockfile moves on origin
  printf '{"lock":%s}\n' "$1" > "$PUSHER/package-lock.json"
  git -C "$PUSHER" commit -qam "lock $1"; git -C "$PUSHER" push -q origin develop
}
run() { (cd "$FIX" && COORDINATOR_SHADOW="${SHADOW:-0}" bash "${SUT:-$SI}" 2>&1); }
npm_runs() { grep -c . "$FIX/npm.log" 2>/dev/null || true; }
live_driver_run() { # <ticket> <done steps…>
  local t="$1"; shift
  printf '{"run_id":"claim-%s-x","ticket":"%s","builder":"driver","pid":%s}\n' "$t" "$t" "$$" > "$STATE/runs/claim-$t-x.json"
  mkdir -p "$STATE/driver/$t"
  jq -n '{done: $ARGS.positional}' --args "$@" > "$STATE/driver/$t/state.json"
}

# Each case leaves R (what happened) for the main body and the plants.
case_unchanged() { reset_install "$(git -C "$REPO" rev-parse refs/remotes/origin/develop:package-lock.json)"; OUT=$(run); R="npm=$(npm_runs)"; }
case_mid_gate()  { reset_install "$V1"; live_driver_run 601 start plan build; OUT=$(run); R="npm=$(npm_runs)"; }
case_locked() {
  reset_install "$V1"
  perl -MFcntl=:flock -e 'open(my $h, ">>", shift) or die; flock($h, LOCK_EX) or die; sleep 60' "$C/shared-install.lock" & HOLDER=$!
  sleep 1; OUT=$(run); R="npm=$(npm_runs)"; kill "$HOLDER" 2>/dev/null; wait "$HOLDER" 2>/dev/null; HOLDER=""
}
case_fail() { reset_install "$V1"; OUT=$(FAKE_NPM=fail run); R="marker=$(cat "$REPO/node_modules/marker" 2>/dev/null) ui=$(cat "$REPO/packages/ui/node_modules/marker" 2>/dev/null)"; }

echo "--- an unchanged lock runs nothing ---"
git -C "$REPO" checkout -q --detach "$(git -C "$REPO" rev-parse HEAD)"
case_unchanged
want "npm ci did not run"                     "npm=0" "$R"
want_in "the check is logged"                 "shared install: lock [0-9a-f]{12} checked: unchanged" "$(cat "$C/tick.log")"

echo "--- shadow says what it would do, and does nothing ---"
move_lock 2; V2=$(git -C "$PUSHER" rev-parse HEAD:package-lock.json)
reset_install "$V1"; OUT=$(SHADOW=1 run)
want "nothing ran in shadow"                  "0" "$(npm_runs)"
want_in "it says it would install"            "would install lock ${V2:0:12}" "$OUT"

echo "--- a moved lock installs once, at the trunk, under the lock ---"
reset_install "$V1"; OUT=$(run)
want "npm ci ran once"                        "1" "$(npm_runs)"
want "in the shared clone, at the trunk's lock" "$REPO $V2" "$(cat "$FIX/npm.log")"
want "the checkout is the trunk's"            "$(git -C "$PUSHER" rev-parse HEAD)" "$(git -C "$REPO" rev-parse HEAD)"
want "the new install is in place"            "new" "$(cat "$REPO/node_modules/marker")"
want "the lock it was made from is recorded"  "$V2" "$(awk '{print $1}' "$REPO/node_modules/.harness-shared-install")"
want "the old install is gone, not left beside it" "" "$(ls -d "$REPO"/node_modules.harness-prev "$REPO"/packages/ui/node_modules.harness-prev 2>/dev/null)"
want_in "the install is logged"               "shared install: installed origin/develop's lock ${V2:0:12}" "$(cat "$C/tick.log")"
want_in "the lock it replaces is named once, short" "the install was made from ${V1:0:12}$" "$(grep 'lock checked: origin' "$C/tick.log")"
OUT=$(run)
want "the next check runs nothing again"      "1" "$(npm_runs)"
want_in "and says the lock is unchanged"      "checked: unchanged" "$OUT"

echo "--- a build past its first steps holds it; a build still planning does not ---"
move_lock 3; V3=$(git -C "$PUSHER" rev-parse HEAD:package-lock.json)
case_mid_gate
want "nothing installed while #601 is mid-gate" "npm=0" "$R"
want_in "it names what it waits on"           "waiting 0 min — in use on this host: claim-601-x \(#601, past build\)" "$OUT"
touch "$STATE/runs/claim-601-x.ended"; OUT=$(run)
want "once the run ends, the next check installs" "1" "$(npm_runs)"
reset_install "$V2"; live_driver_run 602; OUT=$(run)
want "a run still in its start step does not hold it" "1" "$(npm_runs)"
reset_install "$V2"; live_driver_run 604 start; OUT=$(run)
want "a run past start does (plan reads the install too)" "0" "$(npm_runs)"
reset_install "$V2"
printf '{"run_id":"claim-603-x","ticket":"603","pid":%s}\n' "$$" > "$STATE/runs/claim-603-x.json"
OUT=$(run)
want "a run whose step cannot be read holds it" "0" "$(npm_runs)"
want_in "and says why"                        "its step cannot be read" "$OUT"

echo "--- a wait past the drain bound holds new starts until the builds drain ---"
HOLDF="$STATE/coordinator/shared-install-hold"
tick_reads_hold() { local d; d=$(dirname "${SUT:-$SI}"); (. "$d/coordinator-env.sh" && . "$d/shared-install-hold.sh" && shared_install_hold >/dev/null) && echo held || echo free; }
case_drain() { # a build past its gates, and a lock that has waited 31 min
  reset_install "$V1"; live_driver_run 605 start plan build self-check
  printf '%s %s\n' "$(git -C "$PUSHER" rev-parse HEAD:package-lock.json)" "$(( $(date +%s) - 31 * 60 ))" > "$STATE/coordinator/shared-install.waiting"
  OUT=$(run); R="hold=$(tick_reads_hold) npm=$(npm_runs)"
}
reset_install "$V1"; live_driver_run 605 start plan build self-check; OUT=$(run)
want "under the bound: it waits, holding nothing" "free" "$(tick_reads_hold)"
case_drain
want "past the bound: new starts are held, nothing installed yet" "hold=held npm=0" "$R"
want_in "and it says so"                      "waiting 31 min, past 30 — holding new starts on this host" "$OUT"
want_in "the tick names the hold"             "the shared install waits on the builds running here" "$( (. "$HERE/coordinator-env.sh" && . "$HERE/shared-install-hold.sh" && shared_install_hold) )"
: > "$FIX/held.log"; touch "$STATE/runs/claim-605-x.ended"; OUT=$(run)
want "once they drain, it installs"           "1" "$(npm_runs)"
want "with new starts held while it installs" "held" "$(cat "$FIX/held.log")"
want "and the hold is lifted after"           "free" "$(tick_reads_hold)"
printf 'old\n' > "$HOLDF"; touch -t 202601010000 "$HOLDF"
want "a hold its writer stopped rewriting holds nothing" "free" "$(tick_reads_hold)"
rm -f "$HOLDF"

echo "--- a hold has an end: stale past holdStaleMin, dropped past drainMaxMin, lifted once its run ends ---"
age_min() { touch -t "$(date -v-"$2"M +%Y%m%d%H%M.%S 2>/dev/null || date -d "-$2 min" +%Y%m%d%H%M.%S)" "$1"; }
case_stale_hold() { # a hold last written 16 min ago, by a check that has stopped
  printf 'lock abc has waited 102 min; in use: claim-13447-x (#13447, past repair)\n' > "$HOLDF"; age_min "$HOLDF" 16
  R="hold=$(tick_reads_hold)"; rm -f "$HOLDF"
}
case_stale_hold
want "a hold 16 min old holds nothing (holdStaleMin 15)" "hold=free" "$R"
case_ended_lifts() { # the 22 Oct shape: a drain whose only listed run has ended
  case_drain; touch "$STATE/runs/claim-605-x.ended"; OUT=$(run); R="hold=$(tick_reads_hold) npm=$(npm_runs)"
}
case_ended_lifts
want "a drain whose only run has .ended lifts on the next pass" "hold=free npm=1" "$R"
case_drain_max() { # a build past its gates, and a lock held past drainAfterMin + drainMaxMin
  reset_install "$V1"; live_driver_run 607 start plan build self-check
  printf '%s %s\n' "$(git -C "$PUSHER" rev-parse HEAD:package-lock.json)" "$(( $(date +%s) - 91 * 60 ))" > "$STATE/coordinator/shared-install.waiting"
  printf 'lock abc has waited 90 min\n' > "$HOLDF"
  OUT=$(run); R="hold=$(tick_reads_hold) npm=$(npm_runs)"
}
case_drain_max
want "a drain past drainMaxMin drops the hold" "hold=free npm=0" "$R"
want_in "and says so, loudly"                 "⚠ shared install drain timed out: lock [0-9a-f]{12} has waited 91 min, new starts held past 60 min" "$OUT"
want "the timeout is marked for the tick's alert" "1" "$([ -f "$C/shared-install.drain-timeout" ] && echo 1 || echo 0)"
OUT=$(run)
want "the next pass holds nothing either"     "free" "$(tick_reads_hold)"
rm -f "$STATE/runs/claim-607-x.json"; OUT=$(run)
want "once the build ends it installs, and the alert goes" "npm=1 marker=0" "npm=$(npm_runs) marker=$([ -f "$C/shared-install.drain-timeout" ] && echo 1 || echo 0)"
case_check_running() { # another check is live; the hold it wrote is 16 min old
  reset_install "$V1"; sleep 30 & HOLDER=$!
  mkdir -p "$C/shared-install.check"; echo "$HOLDER" > "$C/shared-install.check/pid"
  (. "$HERE/coordinator-env.sh" && coord_started_of "$HOLDER") > "$C/shared-install.check/started"
  printf 'lock abc is being installed\n' > "$HOLDF"; age_min "$HOLDF" 16
  OUT=$(run); R="hold=$(tick_reads_hold) npm=$(npm_runs)"
  kill "$HOLDER" 2>/dev/null; wait "$HOLDER" 2>/dev/null; HOLDER=""; rm -rf "$C/shared-install.check" "$HOLDF"
}
case_check_running
want "a check already running: no second one, and its hold stays live" "hold=held npm=0" "$R"
want_in "it says so"                          "another shared install check \(pid [0-9]+\) is running — checked by it" "$OUT"

echo "--- a process in the clone: only one reading node_modules holds it, and never the hold ---"
SITTER=""; on_exit_keep_status '[ -z "$HOLDER" ] || kill "$HOLDER" 2>/dev/null; [ -z "$SITTER" ] || kill "$SITTER" 2>/dev/null; rm -rf "$FIX"'
reset_install "$V1"; (cd "$REPO" && exec sleep 60) & SITTER=$!; sleep 1
OUT=$(run)
want "a shell sitting in the clone does not hold it" "1" "$(npm_runs)"
kill "$SITTER" 2>/dev/null; wait "$SITTER" 2>/dev/null; SITTER=""
case_reader() { # a node process working in the clone, and a lock that has waited 31 min
  reset_install "$V1"; (cd "$REPO" && exec node -e 'setTimeout(() => {}, 60000)') & SITTER=$!; sleep 1
  printf '%s %s\n' "$(git -C "$PUSHER" rev-parse HEAD:package-lock.json)" "$(( $(date +%s) - 31 * 60 ))" > "$STATE/coordinator/shared-install.waiting"
  OUT=$(run); R="hold=$(tick_reads_hold) npm=$(npm_runs)"
  kill "$SITTER" 2>/dev/null; wait "$SITTER" 2>/dev/null; SITTER=""
}
case_reader
want "a node process holds it, and no drain hold is set over it" "hold=free npm=0" "$R"
want_in "it names the process"                "pid [0-9]+ \(node\) works in" "$OUT"

echo "--- a held lock: no second install ---"
move_lock 4
case_locked
want "nothing ran while another held the lock" "npm=0" "$R"
want_in "it says so"                          "another install holds" "$OUT"

echo "--- a failed install keeps the old one, and its checkout ---"
move_lock 5; V5=$(git -C "$PUSHER" rev-parse HEAD:package-lock.json)
git -C "$REPO" fetch -q origin "+refs/heads/develop:refs/remotes/origin/develop"
git -C "$REPO" checkout -q -f --detach HEAD~1; before=$(git -C "$REPO" rev-parse HEAD)
case_fail
want "the old install is back, root and workspace" "marker=old ui=old" "$R"
want "the checkout is back where it was"      "$before" "$(git -C "$REPO" rev-parse HEAD)"
want "the recorded lock is still the old one" "$V1" "$(awk '{print $1}' "$REPO/node_modules/.harness-shared-install")"
want_in "the failure is logged"               "the install of lock ${V5:0:12} failed \(it exited 1\) — the old install and checkout are back" "$(cat "$C/tick.log")"
: > "$FIX/npm.log"; OUT=$(run)
want "the same lock is not tried again at once" "0" "$(npm_runs)"
want_in "and it says when it will be"         "tried again 60 min after it" "$OUT"

echo "--- a hung install is stopped at the limit, and the old one kept ---"
reset_install "$V1"; OUT=$(FAKE_NPM=slow SHARED_INSTALL_TIMEOUT_SEC=2 run)
want "the old install is still there"         "old" "$(cat "$REPO/node_modules/marker" 2>/dev/null)"
want_in "the timeout is logged"               "failed \(timed out after 0 min\)" "$OUT"

echo "--- an install a person already brought up to the lock is adopted, not redone ---"
git -C "$REPO" checkout -q -f --detach refs/remotes/origin/develop
reset_install ""
printf '{"lockfileVersion":3,"packages":{}}\n' > "$REPO/node_modules/.package-lock.json"
OUT=$(run)
want "nothing ran"                            "0" "$(npm_runs)"
want "the lock is recorded"                   "$(git -C "$REPO" rev-parse refs/remotes/origin/develop:package-lock.json)" "$(awk '{print $1}' "$REPO/node_modules/.harness-shared-install")"

echo "--- a stamp a hand install left behind: the install that matches the lock is adopted ---"
reset_install "$V1"
printf '{"lockfileVersion":3,"packages":{}}\n' > "$REPO/node_modules/.package-lock.json"
OUT=$(run)
want "nothing ran over the old stamp"         "0" "$(npm_runs)"
want "the trunk's lock is recorded"           "$(git -C "$REPO" rev-parse refs/remotes/origin/develop:package-lock.json)" "$(awk '{print $1}' "$REPO/node_modules/.harness-shared-install")"

echo "--- a lockfile bump runs the sync, the project's age rule lifted for it alone ---"
case_age() { reset_install "$V1"; : > "$FIX/npm-args.log"; OUT=$(run); R="npm=$(npm_runs) args=$(tr '\n' ' ' < "$FIX/npm-args.log" | sed 's/ *$//')"; }
move_lock 6
case_age
want "no age rule in the trunk's .npmrc: npm ci as it is" "npm=1 args=" "$R"
printf 'prefer-offline=true\nmin-release-age=7\n' > "$PUSHER/.npmrc"; git -C "$PUSHER" add .npmrc
move_lock 7
case_age
want "min-release-age in the trunk's .npmrc: the bump installs with it lifted" "npm=1 args=--min-release-age=0" "$R"
want_in "and it says it lifted it"            "lifted for this lockfile install only \(--min-release-age=0\)" "$OUT"

echo "--- a build already on the trunk's lock is not waited for; one on the old lock is, loudly ---"
LOCK8='{"lock":8,"packages":{"":{},"node_modules/next":{"version":"16.4.2"},"node_modules/left-pad":{"version":"1.0.0"}}}'
printf '%s\n' "$LOCK8" > "$PUSHER/package-lock.json"; git -C "$PUSHER" commit -qam "lock 8"; git -C "$PUSHER" push -q origin develop
case_tree() { # <lock content for the live run's tree>
  reset_install "$V1"
  printf '{"lockfileVersion":3,"packages":{"node_modules/next":{"version":"16.4.0"},"node_modules/left-pad":{"version":"1.0.0"}}}\n' > "$REPO/node_modules/.package-lock.json"
  live_driver_run 606 start plan build
  mkdir -p "$FIX/wt606"; printf '%s\n' "$1" > "$FIX/wt606/package-lock.json"
  jq --arg w "$FIX/wt606" '.worktree = $w' "$STATE/driver/606/state.json" > "$FIX/st.json" && mv "$FIX/st.json" "$STATE/driver/606/state.json"
  OUT=$(run); R="npm=$(npm_runs)"
}
case_tree '{"lock":1}'
want "a tree on the old lock is waited for"   "npm=0" "$R"
want_in "and the wait is loud, with the count" "⚠ shared install behind the lockfile: 1 packages, pushes will fail" "$OUT"
case_tree_on_lock() { case_tree "$LOCK8"; }
case_tree_on_lock
want "a tree already on the trunk's lock is not: the install is its fix" "npm=1" "$R"
want_in "it says why"                         "claim-606-x \(#606\) is already on the trunk's lock" "$OUT"
rm -f "$STATE/runs/claim-606-x.json"

echo "--- an install that exits 0 is verified before it is recorded ---"
stamp() { awk '{print $1}' "$REPO/node_modules/.harness-shared-install" 2>/dev/null; }
move_lock 9; V9=$(git -C "$PUSHER" rev-parse HEAD:package-lock.json)
case_missing() { # npm ci "succeeds" twice, each time leaving a required package out
  reset_install "$V1"; OUT=$(FAKE_NPM=missing run); R="npm=$(npm_runs) rec=$(stamp) hold=$(tick_reads_hold)"
}
case_missing
want "a required package missing: installed once more, nothing recorded, new starts held" "npm=2 rec=$V1 hold=held" "$R"
want_in "it says so, with the count"          "⚠ shared install broken: 1 required missing — npm ls: @eslint-community/eslint-utils@\^4.0.0" "$OUT"
want_in "the tick names it as broken, not as a wait" "^⚠ shared install broken: 1 required missing" "$( (. "$HERE/coordinator-env.sh" && . "$HERE/shared-install-hold.sh" && shared_install_hold) )"
want "the old install is back"                "old" "$(cat "$REPO/node_modules/marker" 2>/dev/null)"
OUT=$(run)
want "the next check, inside retryMin: nothing runs, and starts stay held" "npm=2 hold=held" "npm=$(npm_runs) hold=$(tick_reads_hold)"
case_missing_once() { reset_install "$V1"; OUT=$(FAKE_NPM=missing-once run); R="npm=$(npm_runs) rec=$(stamp) hold=$(tick_reads_hold)"; }
case_missing_once
want "broken once, whole the second time: recorded, and the hold lifted" "npm=2 rec=$V9 hold=free" "$R"
want_in "the record says it was verified"     "installed origin/develop's lock ${V9:0:12} .*verified: 0 required missing" "$OUT"
case_optional() { reset_install "$V1"; OUT=$(FAKE_NPM=optional run); R="npm=$(npm_runs) rec=$(stamp) hold=$(tick_reads_hold)"; }
case_optional
want "only an optional peer unmet: it passes, once" "npm=1 rec=$V9 hold=free" "$R"
case_probe() { # the tree lists whole, but a load probe fails
  reset_install "$V1"; OUT=$(SHARED_INSTALL_VERIFY='node -e "require(\"no-such-module-516\")"' run); R="npm=$(npm_runs) rec=$(stamp) hold=$(tick_reads_hold)"
}
case_probe
want "a failed load probe: nothing recorded, starts held" "npm=2 rec=$V1 hold=held" "$R"
want_in "it names the probe"                  "the load probe failed: node -e" "$OUT"

echo "--- every manifest the lock names comes from the trunk's commit ---"
printf '{"name":"@w/ui","version":"2.0.0"}\n' > "$PUSHER/packages/ui/package.json"
printf '{"lock":10,"packages":{"":{"name":"w"},"packages/ui":{"name":"@w/ui","version":"2.0.0"},"node_modules/@w/ui":{"resolved":"packages/ui","link":true}}}\n' > "$PUSHER/package-lock.json"
git -C "$PUSHER" commit -qam "lock 10: a workspace moves"; git -C "$PUSHER" push -q origin develop
V10=$(git -C "$PUSHER" rev-parse HEAD:package-lock.json); UI10=$(git -C "$PUSHER" rev-parse HEAD:packages/ui/package.json)
case_ws() { # the clone's checkout one commit behind the trunk, as a stale checkout is
  git -C "$REPO" checkout -q -f --detach "$(git -C "$PUSHER" rev-parse HEAD~1)"
  reset_install "$V1"; OUT=$(run); R="rec=$(stamp) ui=$(git hash-object "$REPO/packages/ui/package.json")"; }
case_ws
want "the workspace's manifest is the trunk's, and the install is recorded" "rec=$V10 ui=$UI10" "$R"
case_stale_ws() { reset_install "$V1"; OUT=$(FAKE_NPM=stale-ws run); R="rec=$(stamp) hold=$(tick_reads_hold)"; }
case_stale_ws
want "a workspace manifest left off the commit: nothing recorded, starts held" "rec=$V1 hold=held" "$R"
want_in "it names the manifest"               "manifests not at [0-9a-f]{10}: packages/ui/package.json" "$OUT"

echo "--- a tree broken after its install: caught on the unchanged pass, its record dropped, installed again ---"
case_reverify() { # recorded whole at V10, then spoiled in place; re-verified every 2nd pass
  reset_install "$V10"; (cd "$REPO" && spoil); : > "$FIX/npm.log"
  export SHARED_INSTALL_REVERIFY_EVERY=2
  OUT1=$(run); OUT=$(run); R="npm=$(npm_runs) rec=$(stamp) hold=$(tick_reads_hold)"
  unset SHARED_INSTALL_REVERIFY_EVERY
}
spoil() { mkdir -p node_modules/eslint; printf '{"name":"eslint","version":"9.1.0","dependencies":{"@eslint-community/eslint-utils":"^4.0.0"}}\n' > node_modules/eslint/package.json; }
case_reverify
want_in "the first pass is the cheap one"     "checked: unchanged — nothing to install" "$OUT1"
want "the second verifies, finds it broken, and installs it again" "npm=1 rec=$V10 hold=free" "$R"
want_in "and says so"                         "⚠ shared install broken: 1 required missing" "$OUT"
case_adopt_broken() { # a hand install at the trunk's lock, unrecorded, with a required package out
  git -C "$REPO" checkout -q -f --detach refs/remotes/origin/develop
  reset_install ""; printf '{"lockfileVersion":3,"packages":{}}\n' > "$REPO/node_modules/.package-lock.json"
  (cd "$REPO" && spoil); OUT=$(run); R="npm=$(npm_runs) rec=$(stamp)"
}
case_adopt_broken
want "a broken hand install is not adopted: it is installed" "npm=1 rec=$V10" "$R"

echo "--- a clone with no install is not one to keep ---"
reset_install ""; rm -rf "$REPO/node_modules"; OUT=$(run)
want "nothing ran"                            "0" "$(npm_runs)"
want_in "it says why"                         "no node_modules" "$OUT"

echo "--- housekeeping runs both passes every time ---"
for s in reconcile sweep wtsweep polish critic judge cache own-install own-stranded; do
  printf '#!/usr/bin/env bash\necho "%s $*" >> "$FIX/house.log"\n' "$s" > "$BIN/$s"; chmod +x "$BIN/$s"
done
house() {
  : > "$FIX/house.log"
  (cd "$FIX" && COORDINATOR_SHADOW=0 COORDINATOR_RECONCILE="$BIN/reconcile" COORDINATOR_SWEEP="$BIN/sweep" \
    COORDINATOR_WORKTREE_SWEEP="$BIN/wtsweep" COORDINATOR_POLISH_LIST="$BIN/polish" COORDINATOR_CRITIC_JUDGE="$BIN/critic" \
    COORDINATOR_JUDGE="$BIN/judge" COORDINATOR_CACHE="$BIN/cache" COORDINATOR_FREE_GB=500 \
    COORDINATOR_SHARED_INSTALL="$BIN/own-install" COORDINATOR_STRANDED_SWEEP="$BIN/own-stranded" \
    bash "${HOUSE_SUT:-$HERE/coordinator-housekeeping.sh}" >/dev/null 2>&1)
  R="$(grep -c '^own-install' "$FIX/house.log") $(grep -c '^own-stranded' "$FIX/house.log")"
}
house
want "the shared install and the stranded sweep each ran once" "1 1" "$R"
order=$(grep -nE '^(own-stranded|wtsweep)' "$FIX/house.log" | cut -d' ' -f1 | tr '\n' ' ')
want_in "the stranded backup runs before the worktree sweep" '^[0-9]+:own-stranded [0-9]+:wtsweep $' "$order"

echo "--- plants: each guard out, its case fails ---"
KIT="$FIX/kit"; mkdir -p "$KIT"; cp -R "$HERE/../scripts" "$HERE/../swarm" "$HERE/../driver" "$KIT/"
plant() { # <label> <file> <exact text to delete> <case> <the result the guard prevents> [<text put in its place>]
  local f="$KIT/scripts/$2"; cp "$f" "$FIX/plant.bak"
  python3 -I -c 'import sys; p, l, r = sys.argv[1], sys.argv[2], sys.argv[3]; s = open(p).read(); n = s.count(l); open(p, "w").write(s.replace(l, r, 1)); sys.exit(0 if n == 1 else 1)' "$f" "$3" "${6:-}" \
    || { bad "plant did not land: $1"; cp "$FIX/plant.bak" "$f"; return; }
  SUT="$KIT/scripts/shared-install.sh" HOUSE_SUT="$KIT/scripts/coordinator-housekeeping.sh"; export SUT HOUSE_SUT
  "$4"; unset SUT HOUSE_SUT
  want "planted ($1): the case now fails" "$5" "$R"
  cp "$FIX/plant.bak" "$f"
}
plant "the lock compare" shared-install.sh '    say "lock ${want:0:12} checked: unchanged — nothing to install"; exit 0' case_unchanged "npm=1" '    :'
plant "the in-use wait"  shared-install.sh '  say "waiting $waited min — in use on this host: $busy; checked again next pass"
  si_loud "$want" "the install waits on builds still on the old lock"; exit 0' case_mid_gate "npm=1"
plant "the drain hold"   shared-install.sh '      shared_install_hold_set "lock ${want:0:12} has waited $waited min; in use: $busy"' case_drain "hold=free npm=0"
plant "the stale limit"  shared-install-hold.sh '  ! shared_install_hold_stale >/dev/null || return 1' case_stale_hold "hold=held"
plant "the drain timeout" shared-install.sh '      si_loud "$want" "its drain timed out; it waits on builds still on the old lock"; exit 0' case_drain_max "hold=held npm=0"
plant "the live check's refresh" shared-install.sh '  [ ! -f "$(shared_install_hold_file)" ] || coord_shadow || touch "$(shared_install_hold_file)"' case_check_running "hold=free npm=0"
plant "runs-only drain"  shared-install.sh ' && [ -n "$RUNS_BUSY" ]' case_reader "hold=held npm=0"
plant "the age override" shared-install.sh '  grep -qE '"'"'^[[:space:]]*min-release-age[[:space:]]*='"'"' "$f" && out="--min-release-age=0"' case_age "npm=1 args="
plant "the on-lock skip" shared-install.sh '    say "$rid (#${t:-?}) is already on the trunk'"'"'s lock — the install fixes it, so it is not waited for"
    continue' case_tree_on_lock "npm=0"
plant "the flock"        shared-install.sh '_si_flock "$LOCKF" ' case_locked "npm=1"
plant "the put-back"     shared-install.sh '  for d in $(prev_dirs); do mv "$d" "${d%"$PREV"}"; done' case_fail "marker= ui="
plant "the verify before the record" shared-install.sh ' && [ "$verified" = 1 ]; then' case_missing "npm=2 rec=$V10 hold=free" '; then'
plant "the required count" shared-install.sh '    SI_N=$(printf '"'"'%s'"'"' "$names" | grep -c .)
' case_missing "npm=1 rec=$V10 hold=free"
plant "optional unmet ignored" shared-install.sh 'UNMET DEPENDENCY ([^ ]+)' case_optional "npm=2 rec=$V1 hold=held" 'UNMET [A-Z ]*DEPENDENCY ([^ ]+)'
plant "the load probes"  shared-install.sh '    (cd "$CLONE" && _si_timeout 120 bash -c "$probe") >> "$LOGF" 2>&1 || SI_WHY="${SI_WHY:+$SI_WHY; }the load probe failed: $probe"
' case_probe "npm=1 rec=$V10 hold=free"
plant "the manifest compare" shared-install.sh '  [ -z "$drift" ] || SI_WHY="manifests not at ${c:0:10}: $drift"
' case_stale_ws "rec=$V10 hold=free"
UI1=$(printf '{"name":"@w/ui"}\n' | git hash-object --stdin)
plant "the whole checkout" shared-install.sh 'git_c checkout -q -f --detach "refs/remotes/origin/$BR"' case_ws "rec=$V1 ui=$UI1" 'git_c checkout -q -f "refs/remotes/origin/$BR" -- package.json package-lock.json'
plant "the retry"        shared-install.sh '    # shellcheck disable=SC2086 # as above
    (cd "$CLONE" && _si_timeout "$TIMEOUT_SEC" ${SHARED_INSTALL_CMD:-npm ci --no-audit --no-fund} $age) >> "$LOGF" 2>&1 || rc=$?
' case_missing_once "npm=1 rec=$V1 hold=held"
plant "the broken hold kept" shared-install.sh '  [ ! -s "$BROKEN_F" ] || shared_install_hold_set "$(head -1 "$BROKEN_F")"
' case_missing "npm=2 rec=$V1 hold=free"
plant "the unchanged re-verify" shared-install.sh '  [ "$REVERIFY" -gt 0 ] && [ $(( passes % REVERIFY )) -eq 0 ] && due=1
' case_reverify "npm=0 rec=$V10 hold=free"
plant "the adopt verify" shared-install.sh ' \
   && si_adoptable; then' case_adopt_broken "npm=0 rec=$V10" '; then'
plant "the call"         coordinator-housekeeping.sh '  [ "$own" = off ] || bash "$own" 2>&1 || say "${own##*/} exited $?"' house "0 0"
for f in shared-install.sh shared-install-hold.sh coordinator-housekeeping.sh; do
  diff -q "$HERE/$f" "$KIT/scripts/$f" >/dev/null && ok "the planted $f is restored" || bad "the planted $f was not restored"
done

echo
[ "$FAILED" -eq 0 ] && echo "shared-install: all cases pass" || echo "shared-install: FAILURES above"
suite_end "$FAILED"
