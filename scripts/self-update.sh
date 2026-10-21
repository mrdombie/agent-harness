#!/usr/bin/env bash
# self-update.sh — every coordinator host moves its own harness forward, on its tick.
#
#   . "$KIT_ROOT/scripts/self-update.sh"     (after coordinator-env.sh)
#   harness_self_update [--floor]            one rate-limited check; prints one line
#   self-update.sh show                      the versions as this machine reads them
#
# A host used to update only when a person pasted the update into a Claude session
# on it. One night those pastes sat waiting for approval and one machine stayed 26
# versions behind the other. The tick needs no session: at most every
# coordinator.selfUpdate.everyMin it compares the marketplace's version with the
# newest one installed and, when the marketplace is ahead, runs
#   claude plugin marketplace update <marketplace>
#   claude plugin update <plugin>@<marketplace> --scope user
# under a lock (flock where the system has it; stock macOS has none, so a pid lock
# there), time-limited, and logged to $COORD_DIR/self-update.log. A failure is
# logged and the tick carries on with the version it has.
#
# RUNNING BUILDS ARE UNTOUCHED. Each version installs into its own folder beside the
# others; the CLI marks the old one orphaned and keeps it while a session holds it.
# A builder runs from the folder its spawn resolved (toolkit-env.sh derives KIT_ROOT
# from the script's own path), and swarm/run-current.sh starts the NEXT tick from
# the registry's user-scope install, so only new runs move.
#
# --floor: the shared sheet's minHarness is above this host. The check runs now,
# not on its interval; a failed attempt is still retried at most once an interval.
#
# Settings (harness.json coordinator.selfUpdate.*, or the env var):
#   enabled   COORDINATOR_SELF_UPDATE            on    off: never checks
#   everyMin  COORDINATOR_SELF_UPDATE_EVERY_MIN  15
#   timeoutSec COORDINATOR_SELF_UPDATE_TIMEOUT   300   each CLI call
#             COORDINATOR_SELF_UPDATE_CLAUDE     claude
#             COORDINATOR_SELF_UPDATE_MARKET_DIR the marketplace clone (default: under
#                                                the CLI's plugins/marketplaces)

_su_self="${BASH_SOURCE[0]}"
_su_dir="$(cd "$(dirname "$_su_self")" && pwd)"
if [ "$_su_self" = "$0" ]; then
  set -uo pipefail
  . "$_su_dir/coordinator-env.sh" || exit 1
fi
SU_KIT="$(cd "$_su_dir/.." && pwd)"
unset _su_self _su_dir

SU_ENABLED="${COORDINATOR_SELF_UPDATE:-$(swarm_opt coordinator.selfUpdate.enabled on)}"
SU_EVERY_MIN="${COORDINATOR_SELF_UPDATE_EVERY_MIN:-$(swarm_opt coordinator.selfUpdate.everyMin 15)}"
case "$SU_EVERY_MIN" in ''|*[!0-9]*) SU_EVERY_MIN=15 ;; esac
SU_TIMEOUT="${COORDINATOR_SELF_UPDATE_TIMEOUT:-$(swarm_opt coordinator.selfUpdate.timeoutSec 300)}"
case "$SU_TIMEOUT" in ''|0|*[!0-9]*) SU_TIMEOUT=300 ;; esac
SU_CLAUDE="${COORDINATOR_SELF_UPDATE_CLAUDE:-claude}"
SU_CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
SU_REGISTRY="${SWARM_PLUGIN_REGISTRY:-$SU_CLAUDE_DIR/plugins/installed_plugins.json}"
SU_PLUGIN=$(jq -r '.name // empty' "$SU_KIT/.claude-plugin/plugin.json" 2>/dev/null)
[ -n "$SU_PLUGIN" ] || SU_PLUGIN=$(basename "$SU_KIT")
# In the CLI's cache the kit sits at <cache>/<marketplace>/<plugin>/<version>.
SU_MARKET="${COORDINATOR_SELF_UPDATE_MARKETPLACE:-}"
if [ -z "$SU_MARKET" ]; then
  if [ "$(basename "$(dirname "$SU_KIT")")" = "$SU_PLUGIN" ]; then SU_MARKET=$(basename "$(dirname "$(dirname "$SU_KIT")")")
  else SU_MARKET="$SU_PLUGIN"; fi
fi
SU_MARKET_DIR="${COORDINATOR_SELF_UPDATE_MARKET_DIR:-$SU_CLAUDE_DIR/plugins/marketplaces/$SU_MARKET}"
SU_LOG="$COORD_DIR/self-update.log"
SU_CHECKED="$COORD_DIR/self-update.checked"     # epoch of the last check
SU_ATTEMPTED="$COORD_DIR/self-update.attempted" # epoch of the last update attempt

# harness_ver_lt <a> <b> — 0 when version a is below b (numeric, dot by dot).
harness_ver_lt() {
  awk -v a="$1" -v b="$2" 'BEGIN {
    na = split(a, x, "."); nb = split(b, y, "."); n = (na > nb ? na : nb)
    for (i = 1; i <= n; i++) { p = x[i] + 0; q = y[i] + 0; if (p < q) exit 0; if (p > q) exit 1 }
    exit 1 }'
}
_su_is_ver() { printf '%s' "$1" | grep -qE '^[0-9]+(\.[0-9]+)*$'; }
_su_max() { # <version>… — the highest
  local best="" v
  for v in "$@"; do _su_is_ver "$v" || continue; { [ -z "$best" ] || harness_ver_lt "$best" "$v"; } && best="$v"; done
  printf '%s' "$best"
}

# The version this process runs: the kit it was started from.
harness_running_version() { jq -r '.version // empty' "$SU_KIT/.claude-plugin/plugin.json" 2>/dev/null; }

# The version installed for new runs: the registry's user-scope record, as run-current.sh
# reads it; with no registry, the newest live version folder beside this one. Never
# below the one running.
harness_installed_version() {
  local reg="" dirs="" vd
  [ -r "$SU_REGISTRY" ] && reg=$(jq -r --arg id "$SU_PLUGIN@$SU_MARKET" \
      '((.plugins // .)[$id] // []) | (if type == "array" then . else [.] end) | map(select(.scope == "user")) | .[0].version // empty' \
      "$SU_REGISTRY" 2>/dev/null)
  vd=$(dirname "$SU_KIT")
  if ! _su_is_ver "$reg" && [ "$(basename "$vd")" = "$SU_PLUGIN" ]; then
    dirs=$(ls "$vd" 2>/dev/null | grep -E '^[0-9]+(\.[0-9]+)*$' | while read -r v; do
      [ -f "$vd/$v/.claude-plugin/plugin.json" ] && [ ! -e "$vd/$v/.orphaned_at" ] && printf '%s ' "$v"; done)
  fi
  # shellcheck disable=SC2086  # a list of versions, split on purpose
  _su_max "$reg" $dirs "$(harness_running_version)"
}

# _su_timeout <seconds> <cmd…> — timeout, gtimeout, or perl's alarm (stock macOS has neither).
_su_timeout() {
  local s="$1"; shift
  if command -v timeout >/dev/null 2>&1; then timeout "$s" "$@"
  elif command -v gtimeout >/dev/null 2>&1; then gtimeout "$s" "$@"
  else perl -e 'alarm shift @ARGV; exec @ARGV or exit 127' "$s" "$@"; fi
}

# The marketplace's version, read off the clone's remote branch after a fetch:
# reading changes nothing the CLI owns. 1 when it cannot be read.
harness_market_version() {
  local br v
  [ -d "$SU_MARKET_DIR/.git" ] || return 1
  _su_timeout "$SU_TIMEOUT" git -C "$SU_MARKET_DIR" fetch -q origin >/dev/null 2>&1 || return 1
  br=$(git -C "$SU_MARKET_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null) || return 1
  v=$(git -C "$SU_MARKET_DIR" show "origin/$br:.claude-plugin/plugin.json" 2>/dev/null | jq -r '.version // empty' 2>/dev/null)
  _su_is_ver "$v" || return 1
  printf '%s' "$v"
}

_su_log() { swarm_log "$SU_LOG" "$*"; }

# _su_apply <from> <to> — the two CLI calls; 0 when the install moved up.
_su_apply() {
  local from="$1" to="$2" rc out now_v
  printf '%s\n' "$(swarm_now)" > "$SU_ATTEMPTED"
  _su_log "update: $from -> $to with $(command -v "$SU_CLAUDE" 2>/dev/null || echo "$SU_CLAUDE") ($("$SU_CLAUDE" --version 2>/dev/null | head -1 || echo 'version unread'))"
  out=$(_su_timeout "$SU_TIMEOUT" "$SU_CLAUDE" plugin marketplace update "$SU_MARKET" 2>&1); rc=$?
  printf '%s\n' "$out" | sed 's/^/  marketplace: /' >> "$SU_LOG"
  if [ "$rc" -ne 0 ]; then SU_WHY="the marketplace refresh exited $rc"; return 1; fi
  out=$(_su_timeout "$SU_TIMEOUT" "$SU_CLAUDE" plugin update "$SU_PLUGIN@$SU_MARKET" --scope user 2>&1); rc=$?
  printf '%s\n' "$out" | sed 's/^/  plugin: /' >> "$SU_LOG"
  if [ "$rc" -ne 0 ]; then SU_WHY="the plugin update exited $rc"; return 1; fi
  now_v=$(harness_installed_version)
  if harness_ver_lt "$now_v" "$to"; then SU_WHY="the CLI exited 0 but the newest install is still $now_v"; return 1; fi
  SU_NOW_V="$now_v"
  return 0
}

# _su_locked <fn> <args…> — one update per host at a time. 75 when another holds it.
_su_locked() {
  local rc
  if [ "${SELF_UPDATE_LOCK:-}" != mkdir ] && command -v flock >/dev/null 2>&1; then
    # The subshell's verdict reaches the caller through this file.
    ( flock -n 9 || exit 75; "$@"; rc=$?; printf '%s\n%s\n' "${SU_NOW_V:-}" "${SU_WHY:-}" > "$COORD_DIR/self-update.result"; exit "$rc" ) \
      9>"$COORD_DIR/self-update.flock"
    rc=$?
    # One per line: an empty first field read with a tab IFS would hand the reason to the version.
    [ "$rc" = 75 ] || { IFS= read -r SU_NOW_V; IFS= read -r SU_WHY; } < "$COORD_DIR/self-update.result" 2>/dev/null
    return "$rc"
  fi
  coord_lock "$COORD_DIR/self-update.lock" self-update || return 75
  "$@"; rc=$?
  rm -rf "$COORD_DIR/self-update.lock"
  return "$rc"
}

# harness_self_update [--floor] — prints one line for the tick's log; always returns 0.
harness_self_update() {
  local floor="" now last cur mkt rc
  [ "${1:-}" = --floor ] && floor=1
  SU_NOW_V=""; SU_WHY=""
  case "$SU_ENABLED" in off|0|false|no) printf 'self-update: off'; return 0 ;; esac
  now=$(swarm_now); cur=$(harness_installed_version)
  if [ -n "$floor" ]; then last=$(cat "$SU_ATTEMPTED" 2>/dev/null)
  else last=$(cat "$SU_CHECKED" 2>/dev/null); fi
  case "$last" in ''|*[!0-9]*) last=0 ;; esac
  if [ $(( now - last )) -lt $(( SU_EVERY_MIN * 60 )) ]; then
    printf 'self-update: %s %s min ago — next in %s min (on %s)' "$([ -n "$floor" ] && echo 'below the floor; last tried' || echo 'checked')" \
      $(( (now - last) / 60 )) $(( SU_EVERY_MIN - (now - last) / 60 )) "${cur:-?}"
    return 0
  fi
  printf '%s\n' "$now" > "$SU_CHECKED"
  # Below the floor every look counts as a try: a floor the marketplace cannot meet is not fetched every tick.
  [ -z "$floor" ] || printf '%s\n' "$now" > "$SU_ATTEMPTED"
  if ! mkt=$(harness_market_version); then
    _su_log "check: the marketplace at $SU_MARKET_DIR could not be read — staying on ${cur:-?}"
    printf 'self-update: the marketplace could not be read — staying on %s (%s)' "${cur:-?}" "$SU_LOG"; return 0
  fi
  if ! harness_ver_lt "$cur" "$mkt"; then
    _su_log "check: installed $cur, marketplace $mkt — current"
    printf 'self-update: checked — %s is current (marketplace %s)' "$cur" "$mkt"; return 0
  fi
  if coord_shadow; then
    _su_log "check: installed $cur, marketplace $mkt — would update (shadow)"
    printf 'self-update: would update %s -> %s (shadow)' "$cur" "$mkt"; return 0
  fi
  _su_locked _su_apply "$cur" "$mkt"; rc=$?
  if [ "$rc" = 75 ]; then
    _su_log "update: another update is in flight — not starting a second"
    printf 'self-update: another update is in flight — skipped'; return 0
  fi
  if [ "$rc" -ne 0 ]; then
    _su_log "update: FAILED ($SU_WHY) — staying on $cur"
    printf 'self-update: the update to %s failed (%s) — staying on %s, see %s' "$mkt" "$SU_WHY" "$cur" "$SU_LOG"; return 0
  fi
  _su_log "update: now $SU_NOW_V — the next tick runs it"
  printf 'self-update: updated %s -> %s — the next tick and new builds run it' "$cur" "$SU_NOW_V"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  case "${1:-}" in
    show) printf 'running %s · installed %s · marketplace %s (%s)\n' "$(harness_running_version)" "$(harness_installed_version)" \
            "$(harness_market_version || echo unread)" "$SU_MARKET_DIR" ;;
    check) harness_self_update "${2:-}"; echo ;;
    *) sed -n '2,33p' "$0" | sed 's/^# \{0,1\}//' ;;
  esac
fi
