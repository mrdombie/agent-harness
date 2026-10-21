#!/usr/bin/env bash
# shared-install.test.sh — a host keeps its shared clone's install at the trunk's
# lockfile with nobody running npm by hand: a moved lock installs once, under the
# lock, never while a build on the host is past its first steps; an unchanged lock
# runs nothing; a failed install leaves the old one in place. Each guard is planted
# out of a copy of the kit, and the case it holds must then fail.
# Run: bash "$0"
set -uo pipefail
for v in $(env | sed -n 's/^\(GIT_[A-Z_]*\)=.*/\1/p'); do unset "$v"; done
unset KIT_ROOT HARNESS_KIT_ROOT
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../swarm/tests/fixture.sh"
swarm_fixture; HOLDER=""
# Never `kill 0`: that signals this whole process group, the shell that ran the suite too.
trap '[ -z "$HOLDER" ] || kill "$HOLDER" 2>/dev/null; rm -rf "$FIX"' EXIT
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
case "${FAKE_NPM:-ok}" in
  ok)   [ -f "$STATE/coordinator/shared-install-hold" ] && echo held >> "$FIX/held.log"
        mkdir -p node_modules/left-pad packages/ui/node_modules; echo new > node_modules/marker ;;
  fail) mkdir -p node_modules; echo partial > node_modules/marker; exit 1 ;;
  slow) sleep 30 ;;
esac
SH
chmod +x "$BIN/fake-npm"
export SHARED_INSTALL_CMD="$BIN/fake-npm"
unset COORDINATOR_SHADOW SHARED_INSTALL SHARED_INSTALL_TIMEOUT_SEC

reset_install() { # <stamp blob> — an old install, recorded at that lock
  rm -rf "$REPO/node_modules" "$REPO/packages/ui/node_modules" "$C"
  mkdir -p "$REPO/node_modules" "$REPO/packages/ui/node_modules" "$C"
  echo old > "$REPO/node_modules/marker"; echo old > "$REPO/packages/ui/node_modules/marker"
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
tick_reads_hold() { (. "$HERE/coordinator-env.sh" && . "$HERE/shared-install-hold.sh" && shared_install_hold >/dev/null) && echo held || echo free; }
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

echo "--- a process in the clone: only one reading node_modules holds it, and never the hold ---"
SITTER=""; trap '[ -z "$HOLDER" ] || kill "$HOLDER" 2>/dev/null; [ -z "$SITTER" ] || kill "$SITTER" 2>/dev/null; rm -rf "$FIX"' EXIT
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
plant() { # <label> <file> <exact line to delete> <case> <the result the guard prevents>
  local f="$KIT/scripts/$2"; cp "$f" "$FIX/plant.bak"
  python3 -I -c 'import sys; p, l = sys.argv[1], sys.argv[2]; s = open(p).read(); n = s.count(l); open(p, "w").write(s.replace(l, "", 1)); sys.exit(0 if n == 1 else 1)' "$f" "$3" \
    || { bad "plant did not land: $1"; cp "$FIX/plant.bak" "$f"; return; }
  SUT="$KIT/scripts/shared-install.sh" HOUSE_SUT="$KIT/scripts/coordinator-housekeeping.sh"; export SUT HOUSE_SUT
  "$4"; unset SUT HOUSE_SUT
  want "planted ($1): the case now fails" "$5" "$R"
  cp "$FIX/plant.bak" "$f"
}
plant "the lock compare" shared-install.sh 'if [ "$have" = "$want" ]; then say "lock ${want:0:12} checked: unchanged — nothing to install"; exit 0; fi' case_unchanged "npm=1"
plant "the in-use wait"  shared-install.sh '  say "waiting $waited min — in use on this host: $busy; checked again next pass"; exit 0' case_mid_gate "npm=1"
plant "the drain hold"   shared-install.sh '      shared_install_hold_set "lock ${want:0:12} has waited $waited min; in use: $busy"' case_drain "hold=free npm=0"
plant "runs-only drain"  shared-install.sh ' && [ -n "$RUNS_BUSY" ]' case_reader "hold=held npm=0"
plant "the flock"        shared-install.sh '_si_flock "$LOCKF" ' case_locked "npm=1"
plant "the put-back"     shared-install.sh '  for d in $(prev_dirs); do mv "$d" "${d%"$PREV"}"; done' case_fail "marker= ui="
plant "the call"         coordinator-housekeeping.sh '  [ "$own" = off ] || bash "$own" 2>&1 || say "${own##*/} exited $?"' house "0 0"
for f in shared-install.sh coordinator-housekeeping.sh; do
  diff -q "$HERE/$f" "$KIT/scripts/$f" >/dev/null && ok "the planted $f is restored" || bad "the planted $f was not restored"
done

echo
[ "$FAILED" -eq 0 ] && echo "shared-install: all cases pass" || echo "shared-install: FAILURES above"
exit "$FAILED"
