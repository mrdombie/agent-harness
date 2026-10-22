#!/usr/bin/env bash
# plugin-ensure.sh — every coordinator host keeps the companion plugins the builds use in line.
#
#   . "$KIT_ROOT/scripts/plugin-ensure.sh"   (after coordinator-env.sh and self-update.sh)
#   harness_plugins_declared <role> [sheet set]   the set this host must match, as JSON
#   harness_plugins_ensure <set json>             one rate-limited pass; prints one line
#   harness_plugins_tick <role> [sheet set]       the tick's call: declared, then ensured
#   harness_plugins_state                         this host's readings, for the heartbeat
#   plugin-ensure.sh show | check                 the same, run by hand
#
# self-update.sh moves agent-harness itself. The plugins a build leans on (superpowers,
# say) were upgraded by hand on one host, and nothing carried the upgrade to the others.
# A declared set fixes that: each entry is
#   {"marketplace": {"name": "<market>", "source": "<owner/repo>"},
#    "id": "<plugin>@<market>", "min": "<version>", "disable": ["<plugin>@<market>", …]}
# and every host, on its own tick, at most every coordinator.plugins.everyMin (and at
# once when the set changes), reads `claude plugin list --json` and
# `claude plugin marketplace list --json`, then only for what differs runs
#   claude plugin marketplace add <source>             the marketplace is missing
#   claude plugin marketplace update <market>          before an install or an update
#   claude plugin install <id> --scope user            not installed for the user
#   claude plugin update <id> --scope user             installed below min
#   claude plugin enable <id> --scope user             installed but turned off
#   claude plugin disable <id> --scope user            a disable-listed id that is on
# under self-update's lock, each call time-limited, all logged to self-update.log. A
# failed call is logged, the rest of the set still runs, and the tick carries on.
#
# WHERE THE SET COMES FROM. The sheet's owner publishes it as `<!-- sheet:plugins … -->`
# (coordinator-sheet.sh), from COORDINATOR_SHEET_PLUGINS, else harness.json
# coordinator.sheet.plugins, else the file `coordinator-sheet.sh plugins set` writes.
# A reader works the sheet's set; with none on the sheet, harness.json coordinator.plugins.
#
# RUNNING BUILDS ARE UNTOUCHED: a session loads its plugins when it starts, so a change
# reaches only the runs started after it.
#
# Settings (env, or harness.json):
#   COORDINATOR_PLUGINS_ENSURE       on   off: never checks (the test fixture's default)
#   COORDINATOR_PLUGINS_EVERY_MIN    coordinator.selfUpdate.everyMin (15)
#   COORDINATOR_SELF_UPDATE_CLAUDE   claude   (shared with self-update.sh)

_pe_self="${BASH_SOURCE[0]}"
_pe_dir="$(cd "$(dirname "$_pe_self")" && pwd)"
if [ "$_pe_self" = "$0" ]; then
  set -uo pipefail
  . "$_pe_dir/coordinator-env.sh" || exit 1
fi
command -v harness_self_update >/dev/null 2>&1 || . "$_pe_dir/self-update.sh" || return 1 2>/dev/null || exit 1
unset _pe_self _pe_dir

PE_ENABLED="${COORDINATOR_PLUGINS_ENSURE:-on}"
PE_EVERY_MIN="${COORDINATOR_PLUGINS_EVERY_MIN:-$SU_EVERY_MIN}"
case "$PE_EVERY_MIN" in ''|*[!0-9]*) PE_EVERY_MIN=15 ;; esac
PE_CHECKED="$COORD_DIR/plugins.checked"    # <epoch> \t <hash of the set>
PE_STATE="$COORD_DIR/plugins.json"         # {at, plugins: {id: {v, on}}} — the last reading
PE_SHEET_FILE="$COORD_DIR/sheet-plugins.json"   # the owner's set, from `coordinator-sheet.sh plugins set`

# harness_plugins_normalise — stdin: any JSON; stdout: the valid entries as a compact array.
# Ids and sources are passed to the CLI as arguments; none may start with a dash.
harness_plugins_normalise() {
  jq -c '
    def okid: type == "string" and test("^[A-Za-z0-9][A-Za-z0-9._-]*@[A-Za-z0-9][A-Za-z0-9._-]*$");
    [if type == "array" then .[] else empty end | objects | select(.id | okid)
     | (.id | split("@")[1]) as $m
     | {id, marketplace: {name: (.marketplace.name? // $m), source: (.marketplace.source? // "")},
        min: ((.min // "") | tostring), disable: [(.disable // [])[]? | select(okid)]}
     | select(.marketplace.name == $m)
     | select(.marketplace.source == "" or (.marketplace.source | test("^[A-Za-z0-9][A-Za-z0-9._/:@-]*$")))
     | select(.min == "" or (.min | test("^[0-9]+(\\.[0-9]+)*$")))]' 2>/dev/null || printf '[]'
}

_pe_cfg_json() { # <dotted key> — a raw JSON value from harness.json, or nothing
  [ -n "${HARNESS_CFG:-}" ] && [ -f "$HARNESS_CFG" ] || return 0
  jq -c --arg k "$1" 'getpath($k | split(".")) // empty' "$HARNESS_CFG" 2>/dev/null
}

# harness_plugins_published — the set the sheet's owner writes onto the sheet.
harness_plugins_published() {
  local s="${COORDINATOR_SHEET_PLUGINS:-}"
  [ -n "$s" ] || s=$(_pe_cfg_json coordinator.sheet.plugins)
  [ -n "$s" ] || s=$(cat "$PE_SHEET_FILE" 2>/dev/null)
  printf '%s' "${s:-[]}" | harness_plugins_normalise
}

# harness_plugins_declared <role> [sheet set] — what this host must match.
harness_plugins_declared() {
  local role="${1:-off}" s=""
  case "$role" in
    reader) s="${2:-}" ;;
    *)      s=$(harness_plugins_published) ;;
  esac
  [ -n "$s" ] && [ "$s" != "[]" ] || s=$(_pe_cfg_json coordinator.plugins)
  printf '%s' "${s:-[]}" | harness_plugins_normalise
}

_pe_log() { swarm_log "$SU_LOG" "plugins: $*"; }
_pe_cli() { _su_timeout "$SU_TIMEOUT" "$SU_CLAUDE" "$@" 2>&1; }

# _pe_run <what> <cli args…> — one changing call, logged; 1 when it failed.
_pe_run() {
  local what="$1" out rc; shift
  if coord_shadow; then _pe_log "would run: claude $* (shadow)"; PE_DID+=("would $what"); return 0; fi
  out=$(_pe_cli "$@"); rc=$?
  _pe_log "claude $* — exit $rc"
  printf '%s\n' "$out" | tail -5 | sed 's/^/  /' >> "$SU_LOG"
  if [ "$rc" -ne 0 ]; then PE_FAILED+=("$what (exit $rc)"); return 1; fi
  PE_DID+=("$what"); return 0
}

# _pe_read — the two list readings into PE_LIST and PE_MKTS; 1 when either cannot be read.
_pe_read() {
  PE_LIST=$(_pe_cli plugin list --json) && PE_LIST=$(jq -c 'if type == "array" then . else error("x") end' <<<"$PE_LIST" 2>/dev/null) || return 1
  PE_MKTS=$(_pe_cli plugin marketplace list --json) && PE_MKTS=$(jq -c 'if type == "array" then . else error("x") end' <<<"$PE_MKTS" 2>/dev/null) || return 1
}
_pe_user() { # <id> — "<version>\t<true|false>" of the user-scope install, or nothing
  jq -r --arg id "$1" '[.[] | select(.id == $id and .scope == "user")][0] // empty | "\(.version // "")\t\(.enabled // false)"' <<<"$PE_LIST" 2>/dev/null
}
_pe_has_market() { jq -e --arg n "$1" 'any(.[]; .name == $n)' >/dev/null 2>&1 <<<"$PE_MKTS"; }

# _pe_write_state <set> — this host's readings of every id the set names.
_pe_write_state() {
  jq -cn --argjson set "$1" --argjson list "$PE_LIST" --argjson at "$(swarm_now)" '
    # A disable-listed id that is not installed is as wanted: it is left off the reading.
    {at: $at, plugins: ([$set[] | .id, .disable[]] | unique | map(. as $id
       | ([$list[] | select(.id == $id and .scope == "user")][0]) as $e
       | select($e != null or any($set[]; .id == $id))
       | {key: $id, value: (if $e == null then {v: null, on: false} else {v: (($e.version // null) | if type == "string" then gsub("[<>]"; "") else . end), on: ($e.enabled // false)} end)})
       | from_entries)}' > "$PE_STATE.$$" 2>/dev/null && mv -f "$PE_STATE.$$" "$PE_STATE"
}

# _pe_apply <set> — the pass itself. Its line goes to $COORD_DIR/plugins.result.
_pe_apply() {
  local set="$1" e id mk src min cur on added d dv don now_v line
  PE_DID=(); PE_FAILED=(); PE_LOW=()
  if ! _pe_read; then
    _pe_log "the CLI's plugin list could not be read ($("$SU_CLAUDE" --version 2>/dev/null | head -1 || echo 'version unread')) — nothing changed"
    printf 'plugins: the CLI could not list the plugins — nothing changed (%s)\n' "$SU_LOG" > "$COORD_DIR/plugins.result"; return 0
  fi
  while IFS= read -r e; do
    id=$(jq -r .id <<<"$e"); mk=$(jq -r .marketplace.name <<<"$e"); src=$(jq -r .marketplace.source <<<"$e"); min=$(jq -r .min <<<"$e")
    added=""
    if ! _pe_has_market "$mk"; then
      if [ -z "$src" ]; then PE_FAILED+=("marketplace $mk is missing and the set gives no source"); _pe_log "marketplace $mk missing, no source declared — $id skipped"; continue; fi
      _pe_run "added marketplace $mk" plugin marketplace add "$src" || continue
      added=1
    fi
    IFS=$'\t' read -r cur on <<<"$(_pe_user "$id")"
    if [ -z "$cur" ] && [ -z "$on" ]; then
      [ -n "$added" ] || _pe_run "refreshed $mk" plugin marketplace update "$mk" || true
      _pe_run "installed $id" plugin install "$id" --scope user || true
    elif [ -n "$min" ] && { ! _su_is_ver "$cur" || harness_ver_lt "$cur" "$min"; }; then
      [ -n "$added" ] || _pe_run "refreshed $mk" plugin marketplace update "$mk" || true
      _pe_run "updated $id from ${cur:-?}" plugin update "$id" --scope user || true
    elif [ "$on" != true ]; then
      _pe_run "enabled $id" plugin enable "$id" --scope user || true
    fi
    for d in $(jq -r '.disable[]' <<<"$e"); do
      IFS=$'\t' read -r dv don <<<"$(_pe_user "$d")"
      [ "$don" = true ] && { _pe_run "disabled $d" plugin disable "$d" --scope user || true; }
    done
  done < <(jq -c '.[]' <<<"$set")
  # What the calls left behind, read once more, is what the heartbeat reports.
  if [ "${#PE_DID[@]}" -gt 0 ] && ! coord_shadow; then _pe_read || true; fi
  _pe_write_state "$set"
  while IFS= read -r e; do
    id=$(jq -r .id <<<"$e"); min=$(jq -r .min <<<"$e")
    IFS=$'\t' read -r now_v on <<<"$(_pe_user "$id")"
    if [ -z "$now_v" ] || { [ -n "$min" ] && { ! _su_is_ver "$now_v" || harness_ver_lt "$now_v" "$min"; }; }; then
      PE_LOW+=("$id ${now_v:-not installed}, wants ${min:-any}")
    fi
  done < <(jq -c '.[]' <<<"$set")
  if [ "${#PE_DID[@]}" -eq 0 ] && [ "${#PE_FAILED[@]}" -eq 0 ] && [ "${#PE_LOW[@]}" -eq 0 ]; then
    _pe_log "checked — every declared plugin as declared"
    line="plugins: checked — $(jq -r '[.[] | .id] | join(", ")' <<<"$set") as declared"
  else
    line="plugins:"
    [ "${#PE_DID[@]}" -eq 0 ] || line="$line $(IFS=';'; printf '%s' "${PE_DID[*]}" | sed 's/;/, /g')."
    [ "${#PE_FAILED[@]}" -eq 0 ] || line="$line FAILED: $(IFS=';'; printf '%s' "${PE_FAILED[*]}" | sed 's/;/, /g')."
    [ "${#PE_LOW[@]}" -eq 0 ] || line="$line still short: $(IFS=';'; printf '%s' "${PE_LOW[*]}" | sed 's/;/, /g')."
    line="$line See $SU_LOG"
    _pe_log "${line#plugins: }"
  fi
  printf '%s\n' "$line" > "$COORD_DIR/plugins.result"
  return 0
}

# harness_plugins_ensure <set json> — prints one line for the tick's log; always returns 0.
harness_plugins_ensure() {
  local set h now last old_h rc
  case "$PE_ENABLED" in off|0|false|no) printf 'plugins: off'; return 0 ;; esac
  set=$(printf '%s' "${1:-[]}" | harness_plugins_normalise)
  [ "$(jq 'length' <<<"$set" 2>/dev/null)" -gt 0 ] 2>/dev/null || { printf 'plugins: none declared'; return 0; }
  h=$(printf '%s' "$set" | cksum | awk '{ print $1 "-" $2 }')
  now=$(swarm_now)
  IFS=$'\t' read -r last old_h < "$PE_CHECKED" 2>/dev/null || { last=0; old_h=""; }
  case "$last" in ''|*[!0-9]*) last=0 ;; esac
  # A new set is acted on at once; an unchanged one once an interval.
  if [ "$h" = "$old_h" ] && [ $(( now - last )) -lt $(( PE_EVERY_MIN * 60 )) ]; then
    printf 'plugins: checked %s min ago — next in %s min' $(( (now - last) / 60 )) $(( PE_EVERY_MIN - (now - last) / 60 ))
    return 0
  fi
  mkdir -p "$COORD_DIR" 2>/dev/null
  printf '%s\t%s\n' "$now" "$h" > "$PE_CHECKED"
  rm -f "$COORD_DIR/plugins.result"
  _su_locked _pe_apply "$set"; rc=$?
  if [ "$rc" = 75 ]; then
    _pe_log "an update is in flight — not starting a second"; printf 'plugins: an update is in flight — skipped'; return 0
  fi
  if [ -s "$COORD_DIR/plugins.result" ]; then printf '%s' "$(cat "$COORD_DIR/plugins.result")"
  else printf 'plugins: the pass ended without a verdict (exit %s) — see %s' "$rc" "$SU_LOG"; fi
  return 0
}

# harness_plugins_tick <role> [sheet set] — the tick's call: the set is not even read when the step is off.
harness_plugins_tick() {
  case "$PE_ENABLED" in off|0|false|no) printf 'plugins: off'; return 0 ;; esac
  harness_plugins_ensure "$(harness_plugins_declared "$@")"
}

# harness_plugins_state — {id: {v, on}} from the last pass, for the heartbeat; {} when none.
harness_plugins_state() {
  jq -c '.plugins // {} | if type == "object" then . else {} end' "$PE_STATE" 2>/dev/null || printf '{}'
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  case "${1:-}" in
    show)  printf 'declared (as the owner or a host with no sheet): %s\nlast reading: %s\n' \
             "$(harness_plugins_declared owner)" "$(harness_plugins_state)" ;;
    check) harness_plugins_ensure "${2:-$(harness_plugins_declared owner)}"; echo ;;
    *) sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//' ;;
  esac
fi
