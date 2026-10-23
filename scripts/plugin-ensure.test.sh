#!/usr/bin/env bash
# plugin-ensure.test.sh — a plugin upgraded by hand on one host never reached the others.
#
# A stand-in `claude` keeps one host's plugins and marketplaces in two files and logs
# every call. The ensure pass is run against a declared set:
#   missing marketplace → added      below the minimum → installed / updated
#   a disable-listed id that is on → disabled      already right → no changing call
#   a CLI failure → logged, the rest of the set still runs, the pass returns 0
# and the sheet carries the set from the owner to a reader, the heartbeat the readings back.
# Run: bash "$0"
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/tests/lib/suite.sh" || exit 1
for v in $(env | sed -n 's/^\(GIT_[A-Z_]*\)=.*/\1/p'); do unset "$v"; done
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../swarm/tests/fixture.sh"
swarm_fixture; on_exit_keep_status 'rm -rf "$FIX"'
unset COORDINATOR_SHADOW COORDINATOR_SHEET_PLUGINS COORDINATOR_SHEET_OWNER
contains() { # <label> <fixed text> <text>
  if grep -qF -- "$2" <<<"$3"; then ok "$1"; else bad "$1 — no '$2' in: $(printf '%s' "$3" | tr '\n' '|')"; fi
}

CC="$FIX/cc"; mkdir -p "$CC"
cat > "$BIN/claude-pe" <<'STUB'
#!/usr/bin/env bash
cc="$PE_CC"; printf '%s\n' "$*" >> "$cc/calls.log"
fail() { [ -f "$cc/fail-$1" ] && { echo "boom: $1" >&2; exit 1; }; return 0; }
case "$*" in
  --version) echo "2.1.999 (Claude Code)" ;;
  "plugin list --json") fail list; cat "$cc/list.json" ;;
  "plugin marketplace list --json") cat "$cc/mkts.json" ;;
  "plugin marketplace add "*) fail add; n=${4##*/}
    jq --arg n "$n" --arg r "$4" '. + [{name: $n, source: "github", repo: $r}]' "$cc/mkts.json" > "$cc/t" && mv "$cc/t" "$cc/mkts.json" ;;
  "plugin marketplace update "*) fail refresh ;;
  "plugin install "*" --scope user"|"plugin update "*" --scope user") fail "$2"
    jq --arg id "$3" --arg v "$(cat "$cc/catalog-version")" \
      '[.[] | select(.id != $id or .scope != "user")] + [{id: $id, version: $v, scope: "user", enabled: true}]' \
      "$cc/list.json" > "$cc/t" && mv "$cc/t" "$cc/list.json" ;;
  "plugin enable "*" --scope user"|"plugin disable "*" --scope user") fail "$2"
    on=$([ "$2" = enable ] && echo true || echo false)
    jq --arg id "$3" --argjson on "$on" 'map(if .id == $id and .scope == "user" then .enabled = $on else . end)' \
      "$cc/list.json" > "$cc/t" && mv "$cc/t" "$cc/list.json" ;;
  *) echo "unknown: $*" >&2; exit 2 ;;
esac
STUB
chmod +x "$BIN/claude-pe"

SET='[{"marketplace":{"name":"superpowers-marketplace","source":"obra/superpowers-marketplace"},"id":"superpowers@superpowers-marketplace","min":"7.0.1","disable":["superpowers@claude-plugins-official"]}]'
OFFICIAL='{"name":"claude-plugins-official","source":"github","repo":"anthropics/claude-plugins-official"}'
OBRA='{"name":"superpowers-marketplace","source":"github","repo":"obra/superpowers-marketplace"}'
world() { # <list json> <marketplaces json> — a fresh host
  rm -rf "$STATE/coordinator"; : > "$CC/calls.log"; rm -f "$CC"/fail-*
  printf '%s\n' "$1" > "$CC/list.json"; printf '%s\n' "$2" > "$CC/mkts.json"; echo 7.0.1 > "$CC/catalog-version"
}
# ensure [set] — one pass on this host, as the tick runs it; prints its line.
ensure() {
  HARNESS_STATE_DIR="$STATE" HARNESS_MAIN_REPO="$REPO" PE_CC="$CC" COORDINATOR_PLUGINS_ENSURE=on \
    COORDINATOR_SELF_UPDATE_CLAUDE="$BIN/claude-pe" COORDINATOR_SHADOW=0 \
    bash -c '. "$1/coordinator-env.sh" && . "$1/plugin-ensure.sh" && harness_plugins_ensure "$2"' _ "$HERE" "${1:-$SET}" 2>&1
}
changing() { grep -vE '^(plugin list --json|plugin marketplace list --json|--version)$' "$CC/calls.log"; }
user_v() { jq -r --arg id "$1" '[.[] | select(.id == $id and .scope == "user")][0] | "\(.version) \(.enabled)"' "$CC/list.json"; }

echo "--- missing marketplace: added, then the plugin installed ---"
world "[{\"id\":\"superpowers@claude-plugins-official\",\"version\":\"7.0.0\",\"scope\":\"user\",\"enabled\":true}]" "[$OFFICIAL]"
line=$(ensure)
contains "the marketplace is added from its source" "plugin marketplace add obra/superpowers-marketplace" "$(changing)"
contains "the plugin is installed for the user" "plugin install superpowers@superpowers-marketplace --scope user" "$(changing)"
want "installed at the minimum" "7.0.1 true" "$(user_v superpowers@superpowers-marketplace)"
contains "the disable-listed official copy is turned off" "plugin disable superpowers@claude-plugins-official --scope user" "$(changing)"
want "and is off" "7.0.0 false" "$(user_v superpowers@claude-plugins-official)"
contains "the tick's line says what moved" "installed superpowers@superpowers-marketplace" "$line"
contains "it is logged" "plugin marketplace add obra/superpowers-marketplace — exit 0" "$(cat "$STATE/coordinator/self-update.log")"
want "the heartbeat reading names both ids" \
  '{"superpowers@claude-plugins-official":{"on":false,"v":"7.0.0"},"superpowers@superpowers-marketplace":{"on":true,"v":"7.0.1"}}' \
  "$(jq -cS .plugins "$STATE/coordinator/plugins.json")"

echo "--- below the minimum: the marketplace refreshed, the plugin updated ---"
world "[{\"id\":\"superpowers@superpowers-marketplace\",\"version\":\"7.0.0\",\"scope\":\"user\",\"enabled\":true}]" "[$OBRA]"
ensure >/dev/null
want "two changing calls, refresh then update" \
  "plugin marketplace update superpowers-marketplace
plugin update superpowers@superpowers-marketplace --scope user" "$(changing)"
want "now at the minimum" "7.0.1 true" "$(user_v superpowers@superpowers-marketplace)"

echo "--- not installed, marketplace present: refreshed, then installed ---"
world "[]" "[$OBRA]"
ensure >/dev/null
want "refresh then install" "plugin marketplace update superpowers-marketplace
plugin install superpowers@superpowers-marketplace --scope user" "$(changing)"

echo "--- an enabled disable-listed id alone: disabled ---"
world "[{\"id\":\"superpowers@superpowers-marketplace\",\"version\":\"7.0.1\",\"scope\":\"user\",\"enabled\":true},
        {\"id\":\"superpowers@claude-plugins-official\",\"version\":\"7.0.0\",\"scope\":\"user\",\"enabled\":true}]" "[$OBRA,$OFFICIAL]"
ensure >/dev/null
want "one changing call: the disable" "plugin disable superpowers@claude-plugins-official --scope user" "$(changing)"

echo "--- already right: no changing call, and the next tick inside the interval reads nothing ---"
world "[{\"id\":\"superpowers@superpowers-marketplace\",\"version\":\"7.0.2\",\"scope\":\"user\",\"enabled\":true},
        {\"id\":\"superpowers@claude-plugins-official\",\"version\":\"7.0.0\",\"scope\":\"user\",\"enabled\":false}]" "[$OBRA,$OFFICIAL]"
line=$(ensure)
want "no changing call" "" "$(changing)"
contains "the line says it is as declared" "as declared" "$line"
: > "$CC/calls.log"; line=$(ensure)
want "inside the interval: no call at all" "" "$(cat "$CC/calls.log")"
contains "and says when it checks next" "next in" "$line"
changed_set=$(jq -c '.[0].min = "7.0.2"' <<<"$SET")
: > "$CC/calls.log"; ensure "$changed_set" >/dev/null
contains "a changed set is acted on at once, inside the interval" "plugin list --json" "$(cat "$CC/calls.log")"

echo "--- a CLI failure: logged, the rest of the set runs, the pass carries on ---"
world "[{\"id\":\"superpowers@claude-plugins-official\",\"version\":\"7.0.0\",\"scope\":\"user\",\"enabled\":true}]" "[$OBRA,$OFFICIAL]"
touch "$CC/fail-install"
two=$(jq -c '. + [{"marketplace":{"name":"claude-plugins-official","source":"anthropics/claude-plugins-official"},"id":"other@claude-plugins-official","min":"1.0","disable":[]}]' <<<"$SET")
echo 1.0 > "$CC/catalog-version"
HARNESS_STATE_DIR="$STATE" HARNESS_MAIN_REPO="$REPO" PE_CC="$CC" COORDINATOR_PLUGINS_ENSURE=on \
  COORDINATOR_SELF_UPDATE_CLAUDE="$BIN/claude-pe" COORDINATOR_SHADOW=0 \
  bash -c '. "$1/coordinator-env.sh" && . "$1/plugin-ensure.sh" && harness_plugins_ensure "$2"; echo "rc=$?"; echo after' _ "$HERE" "$two" > "$FIX/fail.out" 2>&1
contains "the pass returns 0" "rc=0" "$(cat "$FIX/fail.out")"
contains "the caller carries on" "after" "$(cat "$FIX/fail.out")"
contains "the failure is in the tick's line" "FAILED: installed superpowers@superpowers-marketplace (exit 1)" "$(cat "$FIX/fail.out")"
contains "and in the log, with the CLI's words" "boom: install" "$(cat "$STATE/coordinator/self-update.log")"
contains "the same entry's disable still ran" "plugin disable superpowers@claude-plugins-official --scope user" "$(changing)"
contains "the next entry still ran" "plugin install other@claude-plugins-official --scope user" "$(changing)"
world "[]" "[$OBRA]"; touch "$CC/fail-list"
line=$(ensure)
contains "an unreadable list changes nothing and says so" "could not list" "$line"
want "and makes no changing call" "" "$(changing)"

echo "--- shadow: reads, changes nothing ---"
world "[]" "[$OFFICIAL]"
HARNESS_STATE_DIR="$STATE" HARNESS_MAIN_REPO="$REPO" PE_CC="$CC" COORDINATOR_PLUGINS_ENSURE=on \
  COORDINATOR_SELF_UPDATE_CLAUDE="$BIN/claude-pe" COORDINATOR_SHADOW=1 \
  bash -c '. "$1/coordinator-env.sh" && . "$1/plugin-ensure.sh" && harness_plugins_ensure "$2"' _ "$HERE" "$SET" >/dev/null 2>&1
want "no changing call in shadow" "" "$(changing)"

echo "--- nothing declared, or the step off: no call at all ---"
world "[]" "[]"
line=$(ensure '[]')
want "an empty set calls nothing" "" "$(cat "$CC/calls.log")"
contains "and says so" "none declared" "$line"
line=$(ensure '[{"id":"--evil@x","min":"1"}]')
want "an id that reads as a flag is dropped" "" "$(cat "$CC/calls.log")"

echo "--- the sheet carries the set: owner publishes, reader parses, heartbeat reports ---"
sheet() { # <shell> — run inside coordinator-sheet.sh's functions
  HARNESS_STATE_DIR="$STATE" HARNESS_MAIN_REPO="$REPO" COORDINATOR_HOST=box COORDINATOR_SHEET_OWNER=mac \
    bash -c '. "$1/coordinator-env.sh" && . "$1/coordinator-sheet.sh" && eval "$2"' _ "$HERE" "$1" 2>&1
}
out=$(HARNESS_STATE_DIR="$STATE" HARNESS_MAIN_REPO="$REPO" bash "$HERE/coordinator-sheet.sh" plugins set "$SET")
contains "the owner's write path takes the set" "set:" "$out"
want "and it is what the owner publishes" "$(jq -cS . <<<"$SET")" "$(sheet 'harness_plugins_published' | jq -cS .)"
bad=$(HARNESS_STATE_DIR="$STATE" HARNESS_MAIN_REPO="$REPO" bash "$HERE/coordinator-sheet.sh" plugins set '[{"id":"nomarket"}]' 2>&1); brc=$?
want "a malformed set is refused" "2" "$brc"
jq -cn --argjson p "$SET" '{order: [], building: [], plugins: $p,
  fleet: [{host: "box", version: "0.7.1", plugins: {"superpowers@superpowers-marketplace": {v: "7.0.1", on: true}}}]}' > "$FIX/entries.json"
body=$(sheet 'coord_sheet_render "$(cat "'"$FIX"'/entries.json")" "$(swarm_now)"')
contains "the sheet body carries the set under its marker" "<!-- sheet:plugins " "$body"
contains "the Machines line shows each host's plugin version" "superpowers@superpowers-marketplace 7.0.1" "$body"
printf '%s\n' "$body" > "$FIX/body.md"
# The reader's own parse: coord_sheet_read on the body the owner wrote, through a stand-in GitHub.
mkdir -p "$FIX/gh-sheet"; cp "$FIX/body.md" "$FIX/gh-sheet/body"
cat > "$BIN/gh-pe" <<'STUB'
#!/usr/bin/env bash
q=""; prev=""; for a in "$@"; do case "$prev" in --jq) q="$a" ;; esac; prev="$a"; done
case "$*" in
  "api repos/acme/widgets/issues?labels="*) echo '[{"number":777}]' | jq -r "${q:-.}" ;;
  "api repos/acme/widgets/issues/777") jq -n --rawfile b "$FIX/gh-sheet/body" '{number: 777, state: "open", labels: [{name: "build-sheet"}], body: $b}' ;;
  *) exit 1 ;;
esac
STUB
chmod +x "$BIN/gh-pe"
parsed=$(SWARM_GH="$BIN/gh-pe" sheet 'coord_sheet_read >/dev/null; harness_plugins_declared reader "$SHEET_PLUGINS"')
want "a reader declares what the sheet carries" "$(jq -cS . <<<"$SET")" "$(jq -cS . <<<"$parsed" 2>/dev/null)"
mkdir -p "$STATE/coordinator"
echo '{"at":1,"plugins":{"superpowers@superpowers-marketplace":{"v":"7.0.1","on":true}}}' > "$STATE/coordinator/plugins.json"
hb=$(sheet 'coord_heartbeat 0 100')
want "the heartbeat carries this host's plugin versions" '{"superpowers@superpowers-marketplace":{"v":"7.0.1","on":true}}' "$(jq -c .plugins <<<"$hb")"
rm -f "$STATE/coordinator/plugins.json"
want "with no reading, the heartbeat has no plugins key" "null" "$(jq -c .plugins <<<"$(sheet 'coord_heartbeat 0 100')")"

echo "--- the tick runs the step ---"
grep -qF 'say "$(harness_plugins_tick "$SHEET_ROLE" "${SHEET_PLUGINS:-}")"' "$HERE/coordinator-tick.sh"
want "coordinator-tick.sh calls the ensure step with the sheet's set" "0" "$?"

suite_end "$FAILED"
