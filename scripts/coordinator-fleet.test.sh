#!/usr/bin/env bash
# coordinator-fleet.test.sh — a fleet that only updates when a person pastes into each
# machine stays behind the night nobody is there to paste.
#
# Two hosts run real ticks, each from its own copy of the kit in its own plugin cache,
# started through swarm/run-current.sh the way launchd and cron start them: "mac" owns
# the sheet on 0.7.12, "box" reads it on 0.7.10. The stand-in GitHub keeps the sheet and
# its comments; the stand-in `claude` installs 0.7.12 into box's cache the way the CLI
# does (a new version folder and the registry's user record moved to it).
#
#   box under the floor  → starts nothing, updates itself, posts a heartbeat
#   the next box tick    → runs 0.7.12 from the new folder and takes work
#   the self-update      → once per interval, never two at once, a failure keeps the old version
# Run: bash "$0"
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/tests/lib/suite.sh" || exit 1
for v in $(env | sed -n 's/^\(GIT_[A-Z_]*\)=.*/\1/p'); do unset "$v"; done
HERE="$(cd "$(dirname "$0")" && pwd)"
KIT="$(cd "$HERE/.." && pwd)"
. "$HERE/../swarm/tests/fixture.sh"
swarm_fixture; on_exit_keep_status 'rm -rf "$FIX"'
Q="$HERE/coordinator-queue.sh"

for s in reconcile sweep notify; do printf '#!/usr/bin/env bash\nexit 0\n' > "$BIN/$s"; chmod +x "$BIN/$s"; done
printf '#!/usr/bin/env bash\nprintf "[]\\n"\n' > "$BIN/fixlock"; chmod +x "$BIN/fixlock"
export COORDINATOR_FIX_LOCK="$BIN/fixlock" COORDINATOR_RECONCILE="$BIN/reconcile" COORDINATOR_SWEEP="$BIN/sweep"
export COORDINATOR_NOTIFY_CMD="$BIN/notify" COORDINATOR_HOUSEKEEPING_CMD="$BIN/sweep" COORDINATOR_HOUSEKEEPING=inline
export COORDINATOR_REFRESH=0 COORDINATOR_FREE_GB=500 SWARM_FREE_MEM_GB=16 TEST_PID=$$
export COORDINATOR_CLAIMS_CMD="cat $FIX/claims.tsv" COORDINATOR_LIVE_VIEW_WATCHDOG=off
unset COORDINATOR_SHADOW COORDINATOR_CAP COORDINATOR_SHEET_OWNER COORDINATOR_HOST COORDINATOR_MIN_HARNESS

# ---- the stand-in GitHub: the sheet (#777) and its comments ------------------------
SH="$FIX/sheet"
cat > "$BIN/gh-fleet" <<'STUB'
#!/usr/bin/env bash
SH="$FIX/sheet"; q=""; prev=""
for a in "$@"; do case "$prev" in --jq|-q) q="$a" ;; esac; prev="$a"; done
out() { if [ -n "$q" ]; then jq -r "$q"; else cat; fi; }
printf '%s\n' "$*" >> "$GH_LOG"
case "$*" in
  "api repos/acme/widgets/issues?labels="*)
    if [ -s "$SH/number" ]; then printf '[{"number":777}]\n' | out; else echo '[]' | out; fi ;;
  "api repos/acme/widgets/labels "*|"issue pin "*) : ;;
  "api repos/acme/widgets/issues -f title="*) echo 777 > "$SH/number"; echo '{"number":777}' | out ;;
  "api repos/acme/widgets/issues/777/comments?per_page=100") out < "$SH/comments.json" ;;
  "api --method POST repos/acme/widgets/issues/777/comments --input -")
    b=$(jq -r .body); id=$(( 9000 + $(jq length "$SH/comments.json") ))
    jq --arg b "$b" --argjson id "$id" '. + [{id: $id, body: $b}]' "$SH/comments.json" > "$SH/c.tmp" && mv "$SH/c.tmp" "$SH/comments.json"
    echo "post $id" >> "$SH/writes.log"; jq -n --argjson id "$id" '{id: $id}' | out ;;
  "api --method PATCH repos/acme/widgets/issues/comments/"*)
    id=${4##*/}; b=$(jq -r .body)
    jq -e --argjson id "$id" 'any(.[]; .id == $id)' "$SH/comments.json" >/dev/null || exit 1
    jq --arg b "$b" --argjson id "$id" 'map(if .id == $id then .body = $b else . end)' "$SH/comments.json" > "$SH/c.tmp" && mv "$SH/c.tmp" "$SH/comments.json"
    echo "edit $id" >> "$SH/writes.log"; jq -n --argjson id "$id" '{id: $id}' | out ;;
  "api -X PATCH repos/acme/widgets/issues/777 "*)
    jq -r .body > "$SH/body"; echo "sheet" >> "$SH/writes.log"
    jq -n --rawfile b "$SH/body" '{number: 777, state: "open", labels: [{name: "build-sheet"}], body: $b}' | out ;;
  "api repos/acme/widgets/issues/777")
    jq -n --rawfile b "$SH/body" '{number: 777, state: "open", labels: [{name: "build-sheet"}], body: $b}' | out ;;
  *) exec "$BIN/gh" "$@" ;;
esac
STUB
chmod +x "$BIN/gh-fleet"; export SWARM_GH="$BIN/gh-fleet"

cat > "$BIN/spawn-host" <<'STUB'
#!/usr/bin/env bash
printf '%s\t%s\n' "$1" "$COORDINATOR_HOST" >> "$SPAWNS"
printf '{"run_id":"claim-%s-live","ticket":"%s","child_pid":%s}\n' "$1" "$1" "$TEST_PID" \
  > "$HARNESS_STATE_DIR/runs/claim-$1-live.json"
STUB
chmod +x "$BIN/spawn-host"

# ---- the stand-in `claude`: installs the marketplace's version into this host's cache ----
cat > "$BIN/claude-stub" <<'STUB'
#!/usr/bin/env bash
cc="$CLAUDE_CONFIG_DIR"; reg="$cc/plugins/installed_plugins.json"; cache="$cc/plugins/cache/agent-harness/agent-harness"
printf '%s\n' "$*" >> "$cc/claude.log"
case "$*" in
  --version) echo "2.1.999 (Claude Code)" ;;
  # The companion plugins (plugin-ensure.sh): a list in $cc/plist.json, marketplaces in $cc/mlist.json.
  "plugin list --json") cat "$cc/plist.json" 2>/dev/null || echo '[]' ;;
  "plugin marketplace list --json") cat "$cc/mlist.json" 2>/dev/null || echo '[]' ;;
  "plugin marketplace add "*) jq -n --arg n "${4##*/}" '[{name: $n}]' > "$cc/mlist.json" ;;
  "plugin install "*" --scope user") jq -n --arg id "$3" '[{id: $id, version: "7.0.1", scope: "user", enabled: true}]' > "$cc/plist.json" ;;
  "plugin marketplace update agent-harness") [ -f "$cc/fail-market" ] && { echo "network down" >&2; exit 1; }; exit 0 ;;
  "plugin update agent-harness@agent-harness --scope user")
    [ -f "$cc/fail-update" ] && { echo "Failed to update plugin" >&2; exit 1; }
    if [ -f "$cc/block" ]; then : > "$cc/inside"; while [ -f "$cc/block" ]; do sleep 0.1; done; fi
    [ -f "$cc/slow" ] && sleep 5
    cur=$(jq -r '.plugins["agent-harness@agent-harness"][0].installPath' "$reg")
    to=$(git -C "$cc/plugins/marketplaces/agent-harness" show origin/main:.claude-plugin/plugin.json | jq -r .version)
    [ -d "$cache/$to" ] || cp -R "$cur" "$cache/$to"
    jq --arg v "$to" '.version = $v' "$cur/.claude-plugin/plugin.json" > "$cache/$to/.claude-plugin/plugin.json"
    jq --arg p "$cache/$to" --arg v "$to" '.plugins["agent-harness@agent-harness"][0] |= (.installPath = $p | .version = $v)' "$reg" > "$reg.tmp" && mv "$reg.tmp" "$reg"
    echo "updated to $to" ;;
  *) exit 2 ;;
esac
STUB
chmod +x "$BIN/claude-stub"

# One copy of the kit, laid out per host the way the CLI lays out its cache.
BASEKIT="$FIX/basekit"; mkdir -p "$BASEKIT"
(cd "$KIT" && tar cf - --exclude=.git --exclude=node_modules .) | (cd "$BASEKIT" && tar xf -)
# A marketplace repo on "GitHub", and each host's clone of it.
MKT_SRC="$FIX/mkt-src"; MKT_BARE="$FIX/mkt.git"
git init -q -b main "$MKT_SRC" && mkdir -p "$MKT_SRC/.claude-plugin"
git init -q --bare -b main "$MKT_BARE"
publish() { # <version> — the marketplace moves to it
  jq -n --arg v "$1" '{name: "agent-harness", version: $v}' > "$MKT_SRC/.claude-plugin/plugin.json"
  git -C "$MKT_SRC" add -A && git -C "$MKT_SRC" -c user.name=t -c user.email=t@example.invalid commit -qm "v$1" >/dev/null 2>&1
  git -C "$MKT_SRC" push -q "$MKT_BARE" main 2>/dev/null
}
host_setup() { # <host> <installed version> — a host with its own cache, registry and clone
  local h="$1" v="$2" cc="$FIX/cc-$1" cache
  cache="$cc/plugins/cache/agent-harness/agent-harness"
  rm -rf "$cc" "$FIX/m-$h"; mkdir -p "$cache" "$cc/plugins/marketplaces" "$FIX/m-$h/runs"
  cp -R "$BASEKIT" "$cache/$v"
  jq --arg v "$v" '.version = $v' "$BASEKIT/.claude-plugin/plugin.json" > "$cache/$v/.claude-plugin/plugin.json"
  jq -n --arg p "$cache/$v" --arg v "$v" '{version: 2, plugins: {"agent-harness@agent-harness": [{scope: "user", installPath: $p, version: $v}]}}' \
    > "$cc/plugins/installed_plugins.json"
  git clone -q "$MKT_BARE" "$cc/plugins/marketplaces/agent-harness" 2>/dev/null
  : > "$cc/claude.log"
}
world() { # <mac version> <box version> <marketplace version>
  rm -rf "$SH"; mkdir -p "$SH"; echo '[]' > "$SH/comments.json"; : > "$SH/body"; : > "$SH/writes.log"
  : > "$SPAWNS"; : > "$FIX/claims.tsv"; : > "$GH_LOG"; unset SWARM_NOW
  publish "$3"; host_setup mac "$1"; host_setup box "$2"
}
# tick <host> [cap] — one live tick, launched like the timer launches it: the runner
# copy, KIT_ROOT the version first installed, the registry deciding which one runs.
tick() {
  local h="$1" cc="$FIX/cc-$1" first
  first=$(ls "$cc/plugins/cache/agent-harness/agent-harness" | sort -t. -k1,1n -k2,2n -k3,3n | head -1)
  HARNESS_STATE_DIR="$FIX/m-$h" COORDINATOR_HOST="$h" CLAUDE_CONFIG_DIR="$cc" \
    SWARM_PLUGIN_REGISTRY="$cc/plugins/installed_plugins.json" COORDINATOR_SELF_UPDATE=on \
    COORDINATOR_SELF_UPDATE_CLAUDE="$BIN/claude-stub" COORDINATOR_SHEET_OWNER=mac \
    COORDINATOR_CAP="${2:-1}" COORDINATOR_SHADOW=0 SWARM_SPAWN="$BIN/spawn-host" \
    KIT_ROOT="$cc/plugins/cache/agent-harness/agent-harness/$first" \
    bash "${RUNNER:-$KIT/swarm/run-current.sh}" scripts/coordinator-tick.sh 2>&1
}
queue_on() { local h="$1" t; shift; for t in "$@"; do HARNESS_STATE_DIR="$FIX/m-$h" bash "$Q" add "$t" >/dev/null; done; }
by() { awk -F'\t' -v h="$1" '$2 == h { print $1 }' "$SPAWNS" | tr '\n' ' ' | sed 's/ $//'; }
registry_v() { jq -r '.plugins["agent-harness@agent-harness"][0].version' "$FIX/cc-$1/plugins/installed_plugins.json"; }
updates() { grep -c '^plugin update ' "$FIX/cc-$1/claude.log" | tr -d ' '; }

for t in 501 502 503; do fix_issue "$t" OPEN "status:ready,P1"; done

echo "--- the owner publishes its own version as the floor ---"
world 0.7.12 0.7.10 0.7.12
queue_on mac 501 502 503
out=$(tick mac 1)
want "the owner takes the head of its order"          "501" "$(by mac)"
want_in "the sheet carries the floor: the owner's own install" '^<!-- sheet:floor minHarness=0\.7\.12 -->$' "$(cat "$SH/body")"
want_in "and the owner's own heartbeat"               '^- mac · harness 0\.7\.12 · ' "$(cat "$SH/body")"
want_in "its self-update checked the marketplace"     'self-update: checked — 0\.7\.12 is current \(marketplace 0\.7\.12\)' "$out"

echo "--- box under the floor: nothing starts, it updates itself, it says so ---"
out=$(tick box 1)
want "box spawns nothing below the floor"             "" "$(by box)"
want_in "and the tick says why"                       'spawn: starting nothing new — this machine runs harness 0\.7\.10, under the sheet.s floor 0\.7\.12' "$out"
want_in "it updates at once, not on its interval"     'self-update: updated 0\.7\.10 -> 0\.7\.12' "$out"
want "the CLI was asked once"                         "1" "$(updates box)"
want_in "the marketplace refreshed first"             '^plugin marketplace update agent-harness$' "$(head -2 "$FIX/cc-box/claude.log")"
want "the registry moved to 0.7.12"                   "0.7.12" "$(registry_v box)"
want "the old version's folder is still there for running builds" "yes" \
  "$([ -f "$FIX/cc-box/plugins/cache/agent-harness/agent-harness/0.7.10/scripts/coordinator-tick.sh" ] && echo yes || echo no)"
want_in "the update is logged with the CLI's version" 'update: 0\.7\.10 -> 0\.7\.12 with .*\(2\.1\.999 \(Claude Code\)\)' "$(cat "$FIX/m-box/coordinator/self-update.log")"
want_in "box posted a heartbeat on the sheet"         'heartbeat: posted on #777' "$out"
hb=$(jq -r '.[0].body' "$SH/comments.json")
want_in "one comment, its marker first"               '^<!-- sheet:heartbeat host=box -->' "$hb"
want_in "it names the version this tick ran"          '"host":"box","version":"0\.7\.10","installed":"0\.7\.12"' "$hb"

echo "--- the owner reads the heartbeat: box shows behind on the sheet and the owner's live view ---"
out=$(tick mac 2)
want_in "the sheet lists box as behind"               '^- box · harness 0\.7\.10 — \*\*behind\*\*' "$(cat "$SH/body")"
want "the owner's fleet file marks box behind"        "box:true mac:false" \
  "$(jq -r '[.hosts[] | "\(.host):\(.behind)"] | sort | join(" ")' "$FIX/m-mac/coordinator/fleet.json")"
want "and carries the floor"                          "0.7.12" "$(jq -r .minHarness "$FIX/m-mac/coordinator/fleet.json")"

echo "--- the next box tick runs 0.7.12 from its new folder and takes work ---"
out=$(tick box 1)
want "box takes the sheet's next ticket"              "503" "$(by box)"
want_not_in "no floor hold now"                       'under the sheet.s floor' "$out"
want_in "and its self-update waits its interval"      'self-update: checked [0-9]+ min ago' "$out"
want "the CLI was not asked again"                    "1" "$(updates box)"
want "still one heartbeat comment, edited in place"   "1" "$(jq length "$SH/comments.json")"
want_in "it now says 0.7.12"                          '"version":"0\.7\.12"' "$(jq -r '.[0].body' "$SH/comments.json")"
tick mac 2 >/dev/null
want_not_in "the owner's sheet no longer calls box behind" 'box · .*behind' "$(cat "$SH/body")"

echo "--- plant the absence: the floor gate deleted, box below the floor starts work ---"
world 0.7.12 0.7.10 0.7.12
queue_on mac 501 502 503
tick mac 1 >/dev/null
PT="$FIX/cc-box/plugins/cache/agent-harness/agent-harness/0.7.10/scripts/coordinator-tick.sh"
cp "$PT" "$FIX/tick.orig"
sed -i.bak '/^  FLOOR_HOLD="this machine runs harness/d' "$PT" && rm -f "$PT.bak"
want "the plant removed the floor gate's one line"    "0" "$(grep -c 'FLOOR_HOLD="this machine runs harness' "$PT" | tr -d ' ')"
tick box 1 >/dev/null
want "planted: the behind host starts work, which the guard above refuses" "502" "$(by box)"
cp "$FIX/tick.orig" "$PT"

echo "--- the companion plugins: the owner publishes the set, box puts itself in line and reports it ---"
PSET='[{"marketplace":{"name":"superpowers-marketplace","source":"obra/superpowers-marketplace"},"id":"superpowers@superpowers-marketplace","min":"7.0.1","disable":["superpowers@claude-plugins-official"]}]'
world 0.7.12 0.7.12 0.7.12
queue_on mac 501
COORDINATOR_SHEET_PLUGINS="$PSET" tick mac 1 >/dev/null
want_in "the sheet carries the set under its marker"  '^<!-- sheet:plugins \[\{"id":"superpowers@superpowers-marketplace"' "$(cat "$SH/body")"
out=$(COORDINATOR_PLUGINS_ENSURE=on tick box 1)
want_in "box's tick adds the missing marketplace"      '^plugin marketplace add obra/superpowers-marketplace$' "$(cat "$FIX/cc-box/claude.log")"
want_in "and installs the plugin for the user"         '^plugin install superpowers@superpowers-marketplace --scope user$' "$(cat "$FIX/cc-box/claude.log")"
want_in "the tick's line says so"                      'plugins: added marketplace superpowers-marketplace, installed superpowers@superpowers-marketplace' "$out"
want_in "box's heartbeat reports the version"          '"plugins":\{"superpowers@superpowers-marketplace":\{"v":"7\.0\.1","on":true\}' "$(jq -r '.[0].body' "$SH/comments.json")"
COORDINATOR_SHEET_PLUGINS="$PSET" tick mac 1 >/dev/null
want_in "the owner's sheet shows box's plugin version" '^- box · harness 0\.7\.12 · superpowers@superpowers-marketplace 7\.0\.1 ·' "$(cat "$SH/body")"
: > "$FIX/cc-box/claude.log"
COORDINATOR_PLUGINS_ENSURE=on tick box 1 >/dev/null
want_not_in "box's next tick inside the interval changes nothing" '^plugin (install|update|disable|marketplace add)' "$(cat "$FIX/cc-box/claude.log")"

# ---- the self-update on its own -----------------------------------------------------
su() { # <host> <args…> — harness_self_update from that host's installed kit
  local h="$1" cc="$FIX/cc-$1"; shift
  HARNESS_STATE_DIR="$FIX/m-$h" CLAUDE_CONFIG_DIR="$cc" SWARM_PLUGIN_REGISTRY="$cc/plugins/installed_plugins.json" \
    COORDINATOR_SELF_UPDATE="${SU_MODE:-on}" COORDINATOR_SELF_UPDATE_CLAUDE="$BIN/claude-stub" COORDINATOR_SHADOW=0 \
    bash -c '. "$1/scripts/coordinator-env.sh" && . "$1/scripts/self-update.sh" && harness_self_update "${@:2}"' _ \
      "$cc/plugins/cache/agent-harness/agent-harness/0.7.10" "$@" 2>&1
}
checks() { grep -c 'check:\|update: 0' "$FIX/m-$1/coordinator/self-update.log" 2>/dev/null | tr -d ' '; }

echo "--- once per interval: a second look inside 15 min asks nothing ---"
world 0.7.10 0.7.10 0.7.10
T0=$(date +%s)
want_in "the first look checks"                       'checked — 0\.7\.10 is current' "$(SWARM_NOW=$T0 su box)"
want_in "ten minutes on, it waits"                    'checked 10 min ago — next in 5 min' "$(SWARM_NOW=$((T0 + 600)) su box)"
want "one check on the log"                           "1" "$(checks box)"
publish 0.7.11
want_in "fifteen minutes on, it looks again and updates" 'updated 0\.7\.10 -> 0\.7\.11' "$(SWARM_NOW=$((T0 + 900)) su box)"
want "two checks on the log"                          "2" "$(checks box)"

echo "--- a failed update keeps the old version, logs it, and is not retried inside the interval ---"
world 0.7.10 0.7.10 0.7.11
: > "$FIX/cc-box/fail-update"
out=$(SWARM_NOW=$T0 su box)
want_in "it says it failed and stays"                 'the update to 0\.7\.11 failed \(the plugin update exited 1\) — staying on 0\.7\.10' "$out"
want "the registry is untouched"                      "0.7.10" "$(registry_v box)"
want_in "the log names the failure"                   'update: FAILED \(the plugin update exited 1\) — staying on 0\.7\.10' "$(cat "$FIX/m-box/coordinator/self-update.log")"
want_in "with the CLI's own words"                    'plugin: Failed to update plugin' "$(cat "$FIX/m-box/coordinator/self-update.log")"
SWARM_NOW=$((T0 + 120)) su box --floor >/dev/null
want "below the floor, two minutes on: no second attempt" "1" "$(updates box)"
rm -f "$FIX/cc-box/fail-update"
want_in "an interval on, below the floor, it tries again and lands" 'updated 0\.7\.10 -> 0\.7\.11' "$(SWARM_NOW=$((T0 + 900)) su box --floor)"
world 0.7.10 0.7.10 0.7.11
: > "$FIX/cc-box/fail-market"
want_in "a marketplace that will not refresh: no plugin update" 'failed \(the marketplace refresh exited 1\)' "$(SWARM_NOW=$T0 su box)"
want "and the plugin update never ran"                "0" "$(updates box)"
world 0.7.10 0.7.10 0.7.11
: > "$FIX/cc-box/slow"
want_in "a CLI that hangs is cut off by the time limit" 'the update to 0\.7\.11 failed \(the plugin update exited [0-9]+\) — staying on 0\.7\.10' \
  "$(COORDINATOR_SELF_UPDATE_TIMEOUT=1 SWARM_NOW=$T0 su box)"
want "and the old version stays"                      "0.7.10" "$(registry_v box)"

for mode in default mkdir; do
  echo "--- one update at a time ($mode lock): a second look while one runs starts nothing ---"
  world 0.7.10 0.7.10 0.7.11
  : > "$FIX/cc-box/block"
  ( SELF_UPDATE_LOCK=$([ "$mode" = mkdir ] && echo mkdir) SWARM_NOW=$T0 su box > "$FIX/first.out" ) &
  first=$!
  for _ in $(seq 1 100); do [ -f "$FIX/cc-box/inside" ] && break; sleep 0.1; done
  want "the first update is inside the CLI"           "yes" "$([ -f "$FIX/cc-box/inside" ] && echo yes || echo no)"
  out=$(SELF_UPDATE_LOCK=$([ "$mode" = mkdir ] && echo mkdir) COORDINATOR_SELF_UPDATE_EVERY_MIN=0 SWARM_NOW=$T0 su box)
  want_in "the second says one is in flight"          'another update is in flight — skipped' "$out"
  rm -f "$FIX/cc-box/block"; wait "$first"
  want_in "the first lands"                           'updated 0\.7\.10 -> 0\.7\.11' "$(cat "$FIX/first.out")"
  want "the CLI's update ran once"                    "1" "$(updates box)"
done

echo "--- off means off ---"
world 0.7.10 0.7.10 0.7.11
want "COORDINATOR_SELF_UPDATE=off asks nothing" "self-update: off" "$(SU_MODE=off su box | tail -1)"
want "and the CLI was never called"             "0" "$(grep -c . "$FIX/cc-box/claude.log" | tr -d ' ')"

echo "--- the live view draws a line per machine, behind in amber ---"
FL="$FIX/m-mac/coordinator/fleet.json"; mkdir -p "$(dirname "$FL")"
jq -n --argjson now "$(date +%s)" '{minHarness: "0.7.12", owner: "mac", hosts: [
  {host: "mac", version: "0.7.12", freeGb: 120, builds: 2, tick: ($now - 10), behind: false},
  {host: "box", version: "0.7.10", freeGb: 37, builds: 0, tick: ($now - 600), behind: true}]}' > "$FL"
r=$(FLEET="$FL" PAGE="$KIT/swarm/live-view/index.html" SERVER_MJS="$KIT/swarm/live-view/server.mjs" SWARM_RUNS_DIR="$FIX/m-mac/runs" node --input-type=module -e '
  import fs from "node:fs"; import vm from "node:vm"; import { pathToFileURL } from "node:url"
  const { fleetOf } = await import(pathToFileURL(process.env.SERVER_MJS).href)
  const fleet = fleetOf(process.env.FLEET)
  const html = fs.readFileSync(process.env.PAGE, "utf8")
  const js = html.slice(html.indexOf("<script>") + 8, html.lastIndexOf("</script>"))
  const ctx = { document: { getElementById: () => ({}) }, fetch: () => new Promise(() => {}), setInterval: () => 0, console }
  vm.createContext(ctx); vm.runInContext(js + "\n;globalThis.__f = fleetLines", ctx)
  console.log(JSON.stringify(fleet)); console.log(ctx.__f(fleet))' 2>&1)
want_in "the snapshot reads each machine's tick age"  '"host":"box","version":"0\.7\.10","freeGb":37,"builds":0,"tickAgoMin":10,"behind":true' "$r"
want_in "the floor heads the lines"                   'Machines \(harness floor 0\.7\.12\):' "$r"
want_in "a current machine: version, disk, builds, last tick" '<br>mac: harness 0\.7\.12 · 120 GB disk free · 2 building · last tick just now' "$r"
want_in "a behind one says so, in amber"              '<br>box: harness 0\.7\.10 <span class="behind">behind — starts nothing new until it updates to 0\.7\.12</span> · 37 GB disk free · 0 building · last tick 10 min ago' "$r"
grep -q '\.behind{color:var(--warn)' "$KIT/swarm/live-view/index.html" && ok "behind is drawn in the page's amber" || bad "behind has no amber rule"

suite_end "$FAILED"
