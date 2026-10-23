#!/usr/bin/env bash
# cap-quick.sh — over the open-work cap, the quick tickets start anyway.
#
#   . "$KIT_ROOT/scripts/cap-quick.sh"
#   coord_cap_quick_on                      0 while coordinator.openPrCapQuick is on (default)
#   coord_quick_sizes <ticket>…             "<ticket>\t<size>\t<why>" for each, in order
#
# THE OWNER, 2026-10-22: quick-sized new tickets bypass coordinator.openPrCap; bigger new
# tickets still wait. The cap was set so open work could land before more started, and it
# also held the one- and two-file changes that land inside the hour: free places sat idle
# with hundreds of new tickets queued behind it.
#
# The size is the driver's own mechanical read (driver/size-rules.sh: driver_size_read),
# never a copy and never a model call. Only `quick` starts; `undecided` (the driver would
# ask the model) waits like any bigger size. A ticket is read once per text: the cache row
# carries its updatedAt, so an unchanged ticket costs no request, and a changed one is
# re-sized only when its title, sizing labels or body changed. The bodies the cache lacks
# come in one batched read, at most coordinator.openPrCapQuickScan (40) a tick. A body a
# run slipped on (it sized bigger after it started) never sizes quick again.
#
# Reads ISSUES (the tick's batched read: title, labels, updatedAt) when it is set.
[ -z "${_COORD_CAP_QUICK:-}" ] || return 0
_COORD_CAP_QUICK=1
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../driver" && pwd)/size-rules.sh" || return 1 2>/dev/null || exit 1
[ "$(type -t gh_issues_batch)" = function ] || . "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/gh-batch.sh" || return 1 2>/dev/null || exit 1

coord_cap_quick_on() {
  local v="${COORDINATOR_OPEN_PR_CAP_QUICK:-}"
  [ -n "$v" ] || v=$(jq -r 'if .coordinator.openPrCapQuick == false then "off" else "on" end' "${HARNESS_CFG:-/dev/null}" 2>/dev/null)
  case "$v" in off|false|0|no) return 1 ;; esac
  return 0
}
coord_cap_quick_scan() {
  local n="${COORDINATOR_OPEN_PR_CAP_QUICK_SCAN:-}"
  [ -n "$n" ] || n=$(jq -r '.coordinator.openPrCapQuickScan // 40' "${HARNESS_CFG:-/dev/null}" 2>/dev/null)
  case "$n" in ''|*[!0-9]*) n=40 ;; esac; printf '%s' "$n"
}

# _coord_quick_one <ticket> <updatedAt> <title> <labels-csv> <body> — sizes one read
# ticket, cached; prints "<size>\t<why>".
_coord_quick_one() {
  local t="$1" upd="$2" title="$3" labels="$4" body="$5" key bh row rk rsize rwhy rd size why
  key=$(driver_size_key "$title" "$labels" "$body"); bh=$(driver_size_body_hash "$body")
  if row=$(driver_size_cache_row "$t") && [ "$(printf '%s' "$row" | cut -f1)" = "$key" ]; then
    rsize=$(printf '%s' "$row" | cut -f4); rwhy=$(printf '%s' "$row" | cut -f5)
    driver_size_cache_put "$t" "$key" "$upd" "$bh" "$rsize" "$rwhy"
    printf '%s\t%s\n' "$rsize" "$rwhy"; return 0
  fi
  rd=$(driver_size_read "$t" "$title" "$labels" "$body")
  size=$(printf '%s' "$rd" | cut -f1); why=$(printf '%s' "$rd" | cut -f2)
  driver_size_cache_put "$t" "$key" "$upd" "$bh" "$size" "$why"
  printf '%s\t%s\n' "$size" "$why"
}

coord_quick_sizes() { # <ticket>… — COORD_QUICK_WANT: stop sizing once that many are quick
  local t row upd cached="" need="" n=0 scan bodies="{}" j title labels body sw size why bh found=0
  local want="${COORD_QUICK_WANT:-}" stamps
  scan=$(coord_cap_quick_scan)
  local -a order=("$@")
  local iss="${ISSUES:-}"; [ -n "$iss" ] || iss='{}'
  # Every ticket's updatedAt in one read: one jq a tick, not one a ticket.
  stamps=$(jq -r 'to_entries[] | "\(.key)\t\(.value.updatedAt // "")"' <<<"$iss" 2>/dev/null)
  for t in "${order[@]}"; do
    upd=$(printf '%s\n' "$stamps" | awk -F'\t' -v t="$t" '$1 == t { print $2; exit }')
    if [ -n "$upd" ] && row=$(driver_size_cache_row "$t") && [ "$(printf '%s' "$row" | cut -f2)" = "$upd" ]; then
      cached="$cached $t"
    elif [ "$n" -lt "$scan" ]; then need="$need $t"; n=$((n+1)); fi
  done
  # shellcheck disable=SC2086  # a list of numbers, split on purpose
  [ -z "${need// /}" ] || bodies=$(GH_BATCH_BODY=1 gh_issues_batch $need 2>/dev/null) || bodies="{}"
  for t in "${order[@]}"; do
    if [ -n "$want" ] && [ "$found" -ge "$want" ]; then
      printf '%s\tunread\tnot sized this tick: enough quick ones were found ahead of it\n' "$t"; continue
    fi
    if case " $cached " in *" $t "*) true ;; *) false ;; esac; then
      row=$(driver_size_cache_row "$t"); size=$(printf '%s' "$row" | cut -f4); why=$(printf '%s' "$row" | cut -f5)
      bh=$(printf '%s' "$row" | cut -f3)
    elif j=$(jq -ce --arg n "$t" '.[$n] | select(type == "object" and has("body"))' <<<"$bodies" 2>/dev/null); then
      title=$(jq -r '.title // ""' <<<"$j"); labels=$(jq -r '(.labels // []) | join(",")' <<<"$j")
      body=$(jq -r '.body // ""' <<<"$j"); upd=$(jq -r '.updatedAt // ""' <<<"$j")
      sw=$(_coord_quick_one "$t" "$upd" "$title" "$labels" "$body")
      size=${sw%%$'\t'*}; why=${sw#*$'\t'}; bh=$(driver_size_body_hash "$body")
    else
      printf '%s\tunread\tnot sized this tick (past the %s read a tick, or its body could not be read)\n' "$t" "$scan"; continue
    fi
    if [ "$size" = quick ] && driver_size_slipped "$t" "$bh"; then
      size=slipped; why="a run started as quick over the cap sized it bigger: it waits behind the cap until its text changes"
    fi
    [ "$size" != quick ] || found=$((found+1))
    printf '%s\t%s\t%s\n' "$t" "$size" "$why"
  done
}
