#!/usr/bin/env bash
# coordinator-sheet.sh — one work order for every machine that runs a coordinator.
#
#   . "$KIT_ROOT/scripts/coordinator-sheet.sh"   (after coordinator-env.sh)
#   coordinator-sheet.sh show                    the sheet as this machine reads it
#
# Two machines that each own a copy of the work order will pick against each
# other; the order lives in one shared place. Each coordinator used to seed its
# own queue, and the only things the machines shared were labels and claims, so
# the second machine could not see the first one's order and picked on its own.
#
# One machine is the order's owner (coordinator.sheet.owner, its `hostname -s`).
# Each tick it publishes the startable queue, in run order, to ONE pinned issue
# (the sheet): a header, what is building and where, the numbered order, and the
# same order as a fenced JSON block under `<!-- sheet:v1 … -->` that readers parse.
# It writes only when the content changed (a hash kept on disk), plus a heartbeat
# every third of staleMin so readers can tell a quiet owner from a dead one: one
# PATCH per change, nothing on a quiet tick.
#
# Every other machine reads the sheet (one REST GET a tick, through the shared
# backoff; a refused read falls back to the last copy while it is fresh) and works
# its order in place of seeding its own. A sheet older than staleMin, or one that
# cannot be read, starts nothing new on that machine, and the tick says why. It
# never falls back to its own order: that is the clash this removes.
#
# Claims already carry their host (claim-lock.sh's ref record), and every machine
# reads the same refs, so a ticket another host holds is skipped everywhere; the
# sheet shows it as "building on <host>".
#
# Settings under coordinator.sheet in harness.json (or the env var):
#   owner      COORDINATOR_SHEET_OWNER       unset  the host that writes the order; unset,
#                                                   no sheet and every machine as before
#   staleMin   COORDINATOR_SHEET_STALE_MIN   15     older than this, a reader starts nothing
#   label      COORDINATOR_SHEET_LABEL       build-sheet
#   title      COORDINATOR_SHEET_TITLE       Build queue — the shared sheet
#   stopLabels COORDINATOR_SHEET_STOP_LABELS after-launch  more labels that keep a ticket off it
#   minHarness COORDINATOR_MIN_HARNESS      unset  the version floor the owner publishes; unset,
#                                                   the owner's own installed version
#   COORDINATOR_HOST                         this machine's name; default the one claims carry
#
# THE FLEET. Every host's heartbeat — {host, version, free disk, builds, last tick} —
# rides on the sheet. A reader posts its own as ONE comment on the sheet issue,
# edited in place (one PATCH when it changes or every third of staleMin; a git ref
# would cost a push and a fetch a tick, and the owner already reads this issue).
# The owner reads those comments (one GET a tick), adds its own, and writes every
# machine into the sheet with the floor: minHarness, `<!-- sheet:floor … -->`.
# A reader running under the floor starts nothing new and updates itself at once
# (self-update.sh); the tick after it runs the floor, it takes work again. Each
# host keeps what it knows in $COORD_DIR/fleet.json for the live view.

_sheet_self="${BASH_SOURCE[0]}"
if [ "$_sheet_self" = "$0" ]; then
  set -uo pipefail
  . "$(cd "$(dirname "$_sheet_self")" && pwd)/coordinator-env.sh" || exit 1
fi
. "$(cd "$(dirname "$_sheet_self")" && pwd)/claim-proc.sh" || return 1 2>/dev/null || exit 1
. "$(cd "$(dirname "$_sheet_self")" && pwd)/self-update.sh" || return 1 2>/dev/null || exit 1
unset _sheet_self

COORD_HOST="${COORDINATOR_HOST:-$(claim_host)}"
COORD_SHEET_OWNER="${COORDINATOR_SHEET_OWNER-$(swarm_opt coordinator.sheet.owner "")}"
COORD_SHEET_STALE_MIN="${COORDINATOR_SHEET_STALE_MIN:-$(swarm_opt coordinator.sheet.staleMin 15)}"
case "$COORD_SHEET_STALE_MIN" in ""|0|*[!0-9]*) COORD_SHEET_STALE_MIN=15 ;; esac
COORD_SHEET_LABEL="${COORDINATOR_SHEET_LABEL:-$(swarm_opt coordinator.sheet.label build-sheet)}"
COORD_SHEET_TITLE="${COORDINATOR_SHEET_TITLE:-$(swarm_opt coordinator.sheet.title "Build queue — the shared sheet")}"
COORD_SHEET_STOP_LABELS="${COORDINATOR_SHEET_STOP_LABELS:-$(swarm_opt coordinator.sheet.stopLabels after-launch)}"
COORD_SHEET_ISSUE_FILE="$COORD_DIR/sheet.issue"   # <number> \t <the label it was found by>
COORD_SHEET_STATE="$COORD_DIR/sheet.written"   # <hash> \t <epoch written>
COORD_SHEET_COPY="$COORD_DIR/sheet.read.md"    # a reader's last good copy
COORD_SHEET_MIN_HARNESS="${COORDINATOR_MIN_HARNESS:-$(swarm_opt coordinator.sheet.minHarness "")}"
COORD_HEARTBEAT_STATE="$COORD_DIR/heartbeat.posted"   # <comment id> \t <hash> \t <epoch posted>
COORD_FLEET="$COORD_DIR/fleet.json"
# A heartbeat older than this is left off the sheet: the machine is gone, not quiet.
COORD_FLEET_FORGET_MIN="${COORDINATOR_FLEET_FORGET_MIN:-1440}"

_sheet_lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

# coord_sheet_role — off (no owner set), owner (this host), or reader.
coord_sheet_role() {
  [ -n "$COORD_SHEET_OWNER" ] || { printf off; return 0; }
  if [ "$(_sheet_lower "$COORD_HOST")" = "$(_sheet_lower "$COORD_SHEET_OWNER")" ]; then printf owner; else printf reader; fi
}

# coord_sheet_issue [create] — the sheet's number: cached under the label it was found
# by, else the open issue with the label (one REST list), else, with create, a new
# pinned one. 1 when none. A cache made under another label is looked up again.
coord_sheet_issue() {
  local n label_q cached
  cached=$(head -1 "$COORD_SHEET_ISSUE_FILE" 2>/dev/null)
  n=${cached%%$'\t'*}
  case "$n" in ''|*[!0-9]*) n="" ;; esac
  if [ -n "$n" ] && [ "$cached" = "$n"$'\t'"$COORD_SHEET_LABEL" ]; then printf '%s' "$n"; return 0; fi
  n=""
  label_q=$(jq -rn --arg l "$COORD_SHEET_LABEL" '$l | @uri')
  n=$(gh_call api "repos/$REPO_SLUG/issues?labels=$label_q&state=open&per_page=10" \
        --jq '[.[] | select(.pull_request | not)] | sort_by(.number) | .[0].number // empty' 2>/dev/null)
  case "$n" in ''|*[!0-9]*) n="" ;; esac
  if [ -z "$n" ] && [ "${1:-}" = create ]; then
    gh_call api "repos/$REPO_SLUG/labels" -f name="$COORD_SHEET_LABEL" -f color=0E8A16 \
      -f description="The build order every coordinator reads" >/dev/null 2>&1 || true
    n=$(gh_call api "repos/$REPO_SLUG/issues" -f title="$COORD_SHEET_TITLE" \
          -f body="The coordinator fills this in on its next tick." -f "labels[]=$COORD_SHEET_LABEL" --jq .number 2>/dev/null)
    case "$n" in ''|*[!0-9]*) return 1 ;; esac
    gh_call issue pin "$n" --repo "$REPO_SLUG" >/dev/null 2>&1 || true
  fi
  [ -n "$n" ] || return 1
  mkdir -p "$COORD_DIR" 2>/dev/null
  printf '%s\t%s\n' "$n" "$COORD_SHEET_LABEL" > "$COORD_SHEET_ISSUE_FILE"
  printf '%s' "$n"
}

# _sheet_carries <issue json> — the issue is open and still carries the sheet's label.
_sheet_carries() {
  jq -e --arg l "$COORD_SHEET_LABEL" '.state == "open" and ([.labels[]? | (.name? // .)] | index($l) != null)' >/dev/null 2>&1 <<<"$1"
}

# ---- what is startable -------------------------------------------------------
# Open; a new build carries the ready label; none of the labels that keep a ticket
# from every agent (the tick's own stop list), nor drafting, claimed, a decision
# waiting on the PM, or the sheet's extra stops (after-launch). A repair or an
# approved merge is in review by definition, so that one label never stops it.
coord_sheet_stop_labels() {
  { swarm_blocking_labels
    printf '%s\n' "$LBL_GATED" "$LBL_EXTERNAL_BLOCKED" "$LBL_DRAFTING" "$LBL_CLAIMED" "$LBL_PM_DECISION" "$LBL_OWNER_DECISION" "$HOLD_LABEL"
    printf '%s\n' $COORD_SHEET_STOP_LABELS; } | awk 'NF && !seen[$0]++' | jq -R . | jq -sc .
}

# coord_sheet_entries <wide order> <issues json> <claims tsv> <started here, comma list>
# — the sheet's content as JSON: {order: [...], building: [...]}. The order keeps
# the queue's run order; an entry a host holds stays in its place, named. Process
# fixes (coordinator.processLabel) are listed first, whatever order the rows came in.
#   wide order  coord_queue_ordered --wide rows
#   claims tsv  <ticket> \t <host> \t <step>, every live claim on every host
coord_sheet_entries() {
  local wide="$1" issues="${2:-}" claims="$3" plan="${4:-}"
  [ -n "$issues" ] || issues='{}'
  coord_jq -c --arg wide "$wide" --arg claims "$claims" --arg plan "$plan" --arg host "$COORD_HOST" \
     --arg ready "$LBL_READY" --arg inreview_l "${LBL_IN_REVIEW:-status:in-review}" \
     --argjson stops "$(coord_sheet_stop_labels)" "$COORD_TICKET_JQ"'
    . as $iss
    | ($claims | split("\n") | map(select(length > 0) | split("\t") | {n: (.[0] | tonumber? // null), host: (.[1] // ""), step: (.[2] // "")})
        | map(select(.n != null))) as $claimed
    | ($plan | split(",") | map(select(length > 0) | tonumber? // empty)) as $started
    | ($claimed + ($started | map({n: ., host: $host, step: "starting"}))
        | unique_by(.n)) as $held
    | ($held | map({key: (.n | tostring), value: .}) | from_entries) as $heldby
    | def startable($ls; $cls):
        ($cls != "new" or ($ls | index($ready)) != null)
        and ([$ls[] | select(. as $l | $stops | index($l) != null)
                    | select(. != $inreview_l or $cls == "new")] | length == 0);
    {order: ([$wide | split("\n")[] | select(length > 0) | split("\t")
        | {n: (.[0] | tonumber), class: .[1], prin: (.[2] | tonumber? // 9)} as $e
        | ($iss[($e.n | tostring)] // null) as $i
        | select($i != null and ($i.state // "OPEN") == "OPEN")
        | ($i.labels // []) as $ls
        | ($heldby[($e.n | tostring)].host // "") as $h
        | select($h != "" or startable($ls; $e.class))
        | $e + {kind: coord_kind($ls; ""; null; $i.title), title: ($i.title // "")}
          + (if coord_process($ls) then {process: true} else {} end)
          + (if $h != "" then {host: $h} else {} end)]
        | sort_by(if .process then 0 else 1 end)),
     building: [$held[] | . + {title: ($iss[(.n | tostring)].title // "")}] | sort_by(.n)}' <<<"$issues"
}

_sheet_when() { # <epoch> — the owner's local wall clock, as a person reads it
  TZ="${COORDINATOR_SHEET_TZ:-Europe/London}" date -r "$1" '+%d %b %H:%M %Z' 2>/dev/null \
    || TZ="${COORDINATOR_SHEET_TZ:-Europe/London}" date -d "@$1" '+%d %b %H:%M %Z' 2>/dev/null \
    || swarm_iso "$1"
}

# coord_sheet_render <entries json> <epoch> — the issue body. Plain words first, for a
# phone; the machine-readable order last, under its marker.
coord_sheet_render() {
  local e="$1" at="$2"
  jq -r --arg when "$(_sheet_when "$at")" --arg owner "$COORD_HOST" --arg at "$at" '
    def pri: {"0":"Urgent","1":"High","2":"Normal","3":"Polish"}[tostring] // "No priority";
    def kind: if .process then "Process fix" elif .class == "repair" then "Red PR to fix" elif .class == "approved-merge" then "Approved, to merge"
              else {"half-built":"Half-built","feature":"Feature","polish":"Polish"}[.kind // ""] // "Fix" end;
    def cut: if length > 90 then .[0:89] + "…" else . end;
    (.order | length) as $n
    | ([.order[] | select(.process)] | length) as $np
    | ([.order[] | .prin] | group_by(.) | map("\(.[0] | pri) \(length)") | join(" · ")) as $counts
    | "The order every machine builds in. Written by the coordinator on \($owner) each time it changes — please do not edit it by hand.",
      "",
      "**Updated \($when)** · order kept by \($owner) · \($n) in the queue\(if $n > 0 then ": " + $counts else "" end)",
      "",
      "### Building now",
      (if (.building | length) == 0 then "Nothing is building."
       else (.building[] | "- #\(.n)\(if .title != "" then " · " + (.title | cut) else "" end) — on \(.host)\(if (.step // "") != "" then ", step: " + .step else "" end)") end),
      "",
      "### Next up, in run order",
      (if $np > 0 then "Process fixes first: \($np)\n" else empty end),
      (if $n == 0 then "Nothing is ready to start."
       else (.order | to_entries[] | .key as $i | .value
             | "\($i + 1). #\(.n) · \(.prin | pri) · \(kind) · \(.title | cut) — \(if (.host // "") != "" then "building on " + .host else "ready" end)") end),
      (if (.fleet // []) | length > 0 then
        "", "### Machines\(if (.minHarness // "") != "" then " · harness floor " + .minHarness else "" end)",
        (.fleet[] | "- \(.host) · harness \(.version // "?")\(if .behind then " — **behind**, starts nothing new until it updates" else "" end)"
                    + " · \(if .freeGb == null then "disk not read" else "\(.freeGb) GB free" end) · \(.builds // 0) building"
                    + " · last tick \(((($at | tonumber) - (.tick // 0)) / 60 | floor | if . < 0 then 0 else . end)) min before this update")
       else empty end),
      (if .pace then
        "", "### Usage budget",
        "Five-hour window \(.pace.usage.five_hour.u * 100 | round)% against a straight line of \(.pace.fiveHour.line * 100 | round)%"
        + (if .pace.sevenDay then " · week \(.pace.sevenDay.u * 100 | round)% against \(.pace.sevenDay.line * 100 | round)%" else "" end)
        + " · at most \(.pace.maxBuildsFleet) building across every machine: "
        + (.pace.shares | to_entries | map("\(.key) \(.value)") | join(", "))
       else empty end),
      "",
      "<!-- sheet:v1 updated=\($at) owner=\($owner) -->",
      "```json",
      (.order | map({n, class, prin} + (if .process then {process} else {} end) + (if (.host // "") != "" then {host} else {} end)) | tojson),
      "```",
      (if (.minHarness // "") != "" then "<!-- sheet:floor minHarness=\(.minHarness) -->" else empty end),
      (if (.fleet // []) | length > 0 then "<!-- sheet:fleet \(.fleet | tojson) -->" else empty end),
      (if .pace then "<!-- sheet:pace \(.pace | tojson) -->" else empty end)' <<<"$e"
}

_sheet_hash() { printf '%s' "$1" | cksum | awk '{ print $1 "-" $2 }'; }

# coord_sheet_publish <entries json> — the owner's write. Nothing when the content
# is what it last wrote and the heartbeat is not due. Prints what it did.
coord_sheet_publish() {
  local e="$1" h old_h old_at now beat n body
  now=$(swarm_now)
  # A machine's tick time and disk move every tick; they ride on the heartbeat write, not their own.
  h=$(_sheet_hash "$COORD_SHEET_LABEL $(jq -cS 'del(.fleet, .pace) + {fleet: [(.fleet // [])[] | {host, version, behind}]}
                                                + (if .pace then {pace: (.pace | {maxBuildsFleet, shares, settings})} else {} end)' <<<"$e")")
  old_h=$(cut -f1 "$COORD_SHEET_STATE" 2>/dev/null); old_at=$(cut -f2 "$COORD_SHEET_STATE" 2>/dev/null)
  case "$old_at" in ''|*[!0-9]*) old_at=0 ;; esac
  beat=$(( COORD_SHEET_STALE_MIN * 60 / 3 ))
  if [ "$h" = "$old_h" ] && [ $(( now - old_at )) -lt "$beat" ]; then
    printf 'unchanged — not written'; return 0
  fi
  if coord_shadow; then printf 'would write it (%s)' "$([ "$h" = "$old_h" ] && echo heartbeat || echo changed)"; return 0; fi
  body=$(coord_sheet_render "$e" "$now")
  local try resp
  for try in 1 2; do
    n=$(coord_sheet_issue create) || { printf 'no sheet issue could be found or made'; return 1; }
    if ! resp=$(jq -n --arg b "$body" --arg t "$COORD_SHEET_TITLE" '{body: $b, title: $t}' \
         | gh_call api -X PATCH "repos/$REPO_SLUG/issues/$n" --input - 2>/dev/null); then
      # A sheet that was closed or deleted is looked for again next tick.
      rm -f "$COORD_SHEET_ISSUE_FILE"
      printf 'the write to #%s was refused — trying again next tick' "$n"; return 1
    fi
    # Written to an issue that is closed or lost the label: readers never look there.
    _sheet_carries "$resp" && break
    rm -f "$COORD_SHEET_ISSUE_FILE"
    [ "$try" = 2 ] && { printf '#%s does not carry %s once written — looked for again next tick' "$n" "$COORD_SHEET_LABEL"; return 1; }
  done
  printf '%s\t%s\n' "$h" "$now" > "$COORD_SHEET_STATE.$$" && mv -f "$COORD_SHEET_STATE.$$" "$COORD_SHEET_STATE"
  printf 'wrote #%s (%s)' "$n" "$([ "$h" = "$old_h" ] && echo heartbeat || echo changed)"
}

# coord_sheet_parse <body> — "<updated epoch> \t <owner> \t <order json>"; 1 when it holds no sheet.
coord_sheet_parse() {
  local meta at owner order
  meta=$(printf '%s\n' "$1" | tr -d '\r' | grep -oE '<!-- sheet:v1 updated=[0-9]+ owner=[^ ]+ -->' | tail -1)
  [ -n "$meta" ] || return 1
  at=$(printf '%s' "$meta" | sed -E 's/.*updated=([0-9]+).*/\1/')
  owner=$(printf '%s' "$meta" | sed -E 's/.*owner=([^ ]+) -->.*/\1/')
  order=$(printf '%s\n' "$1" | tr -d '\r' | awk -v m="$meta" '
    index($0, m) { s = 1; next }
    s == 1 && /^```json/ { s = 2; next }
    s == 2 && /^```/ { exit }
    s == 2 { print }')
  order=$(jq -c 'if type == "array" and all(.[]; (.n | type) == "number") then . else error("bad") end' <<<"$order" 2>/dev/null) || return 1
  printf '%s\t%s\t%s' "$at" "$owner" "$order"
}

# coord_sheet_read — a reader's look at the sheet. Sets SHEET_ORDER (JSON), SHEET_AT,
# SHEET_AGE_MIN, SHEET_FROM (github|copy); returns 1 with SHEET_WHY when it may not
# be worked from: unreadable with no fresh copy, or older than staleMin.
coord_sheet_read() {
  local n raw body parsed from=github age
  SHEET_ORDER=""; SHEET_AT=""; SHEET_AGE_MIN=""; SHEET_WHY=""; SHEET_FROM=""; SHEET_MIN_HARNESS=""; SHEET_FLEET="[]"; SHEET_PACE=""
  body=""
  local try
  for try in 1 2; do
    n=$(coord_sheet_issue) || break
    raw=$(gh_call api "repos/$REPO_SLUG/issues/$n" 2>/dev/null) || raw=""
    [ -n "$raw" ] || break
    if _sheet_carries "$raw"; then
      body=$(jq -r '.body // ""' <<<"$raw")
      printf '%s\n' "$body" > "$COORD_SHEET_COPY.$$" && mv -f "$COORD_SHEET_COPY.$$" "$COORD_SHEET_COPY"
      break
    fi
    rm -f "$COORD_SHEET_ISSUE_FILE"   # closed, or the label moved: looked up again
  done
  if [ -z "$body" ]; then
    from=copy
    body=$(cat "$COORD_SHEET_COPY" 2>/dev/null)
    [ -n "$body" ] || { SHEET_WHY="the sheet could not be read$(gh_limit_why >/dev/null 2>&1 && printf ' (%s)' "$(gh_limit_why)") and there is no copy of it"; return 1; }
  fi
  # The floor and the fleet are read before the age test: a stale sheet still says how far behind this host is.
  SHEET_MIN_HARNESS=$(printf '%s\n' "$body" | tr -d '\r' | sed -nE 's/^<!-- sheet:floor minHarness=([0-9][0-9.]*) -->$/\1/p' | tail -1)
  SHEET_FLEET=$(printf '%s\n' "$body" | tr -d '\r' | sed -nE 's/^<!-- sheet:fleet (\[.*\]) -->$/\1/p' | tail -1 | jq -c 'if type == "array" then . else [] end' 2>/dev/null)
  [ -n "$SHEET_FLEET" ] || SHEET_FLEET="[]"
  SHEET_PACE=$(printf '%s\n' "$body" | tr -d '\r' | sed -nE 's/^<!-- sheet:pace (\{.*\}) -->$/\1/p' | tail -1 | jq -c 'if type == "object" then . else empty end' 2>/dev/null)
  parsed=$(coord_sheet_parse "$body") || { SHEET_WHY="the sheet holds no order this coordinator can read"; return 1; }
  SHEET_AT=$(cut -f1 <<<"$parsed"); SHEET_ORDER=$(cut -f3- <<<"$parsed"); SHEET_FROM=$from
  age=$(( ($(swarm_now) - SHEET_AT) / 60 )); [ "$age" -ge 0 ] || age=0
  SHEET_AGE_MIN=$age
  if [ "$age" -gt "$COORD_SHEET_STALE_MIN" ]; then
    SHEET_WHY="the sheet is ${age} min old (its owner, $(cut -f2 <<<"$parsed"), last wrote it at $(swarm_iso "$SHEET_AT")), over the ${COORD_SHEET_STALE_MIN} min limit$([ "$from" = copy ] && printf ' — and GitHub could not be read for a newer one')"
    return 1
  fi
  return 0
}

# coord_sheet_seed_queue <order json> — this machine's queue becomes the sheet's
# order: every entry no host holds, in the sheet's order. A resume this machine
# put at the front (a run of its own the wall cut off) stays first: its worktree is here.
coord_sheet_seed_queue() {
  local cur; cur=$( [ -s "$COORD_QUEUE" ] && cat "$COORD_QUEUE" || echo '{}')
  jq -c --argjson o "$1" --arg at "$(swarm_stamp)" '
    ((.tickets // []) | map(select(.front or .top))) as $front
    | ($front | map(.n)) as $fn
    | .source = "sheet" | .sheet_at = $at
    | .scope = (.scope // "sheet") | .label = (.label // "the shared sheet")
    | .tickets = ($front + [$o[] | select((.host // "") == "") | select(.n as $n | $fn | index($n) | not)
                           | {n, class: (.class // "new"), prin: (.prin // 9), note: ""}
                             + (if .process then {process: true} else {} end)])' <<<"$cur" \
    > "$COORD_QUEUE.$$" && mv -f "$COORD_QUEUE.$$" "$COORD_QUEUE"
}

# ---- the fleet -------------------------------------------------------------------
# coord_sheet_floor — the version floor the owner publishes: the configured one, else its own install.
coord_sheet_floor() {
  local v="$COORD_SHEET_MIN_HARNESS"
  [ -n "$v" ] || v=$(harness_installed_version)
  printf '%s' "$v"
}

# coord_heartbeat <builds> <free GB> [machine capacity] — this host, as one JSON object:
# with its capacity (the builders its CPU and memory fit, the owner's split weight)
# and this tick's usage readings (pace.json), so every host acts on the newest number.
coord_heartbeat() {
  local b="${1:-0}" c="${3:-}" usage; case "$b" in ''|*[!0-9]*) b=0 ;; esac
  case "$c" in *[!0-9]*) c="" ;; esac
  usage=$(jq -c --argjson now "$(swarm_now)" 'select((.at // 0) > $now - 900) | .usage // empty' "${COORD_PACE_STATE:-$COORD_DIR/pace.json}" 2>/dev/null)
  # This host's last GitHub allowance reading: the token is the fleet's, so every host holds on it.
  local ghr
  ghr=$(awk -F'\t' 'NF >= 4 && $2 ~ /^[0-9]+$/ && $3 ~ /^[0-9]+$/ && $4 ~ /^[0-9]+$/ { printf "%s{\"resource\":\"%s\",\"remaining\":%s,\"limit\":%s,\"reset\":%s}", (n++ ? "," : ""), $1, $2, $3, $4 }' \
          "$(gh_allowance_file)" 2>/dev/null)
  jq -cn --arg host "$COORD_HOST" --arg v "$(harness_running_version)" --arg inst "$(harness_installed_version)" \
     --arg disk "${2:-}" --argjson builds "$b" --argjson tick "$(swarm_now)" --arg role "$(coord_sheet_role)" \
     --arg cap "$c" --arg usage "${usage:-}" --arg gh "${ghr:+[$ghr]}" \
     '{host: $host, version: $v, installed: $inst, freeGb: ($disk | tonumber? // null), builds: $builds, tick: $tick, role: $role}
      + (if $cap == "" then {} else {capacity: ($cap | tonumber)} end)
      + (if $usage == "" then {} else {usage: ($usage | fromjson)} end)
      + (if $gh == "" then {} else {gh: ($gh | fromjson)} end)'
}

# coord_fleet <own heartbeat> <others json array> <floor> — every machine, this one first,
# each marked behind when it runs under the floor. A host silent past forgetMin is dropped.
coord_fleet() {
  local now; now=$(swarm_now)
  jq -cn --argjson me "$1" --argjson others "${2:-[]}" --arg floor "${3:-}" --argjson now "$now" \
     --argjson forget "$(( COORD_FLEET_FORGET_MIN * 60 ))" '
    def vlt($a; $b): ($a | split(".") | map(tonumber? // 0)) < ($b | split(".") | map(tonumber? // 0));
    [$me] + ([$others[]? | select(type == "object" and (.host // "") != "" and (.host | ascii_downcase) != ($me.host | ascii_downcase))
              | select(($now - (.tick // 0)) < $forget)] | unique_by(.host | ascii_downcase) | sort_by(.host))
    | map(. + {behind: ($floor != "" and (.version // "") != "" and vlt(.version; $floor))})' 2>/dev/null
}

# coord_fleet_write <fleet json> <floor> — what the live view draws a line per machine from.
coord_fleet_write() {
  jq -cn --argjson f "${1:-[]}" --arg floor "${2:-}" --arg owner "$COORD_SHEET_OWNER" --argjson at "$(swarm_now)" \
     '{at: $at, owner: (if $owner == "" then null else $owner end), minHarness: (if $floor == "" then null else $floor end), hosts: $f}' \
     > "$COORD_FLEET.$$" 2>/dev/null && mv -f "$COORD_FLEET.$$" "$COORD_FLEET"
}

_hb_marker() { printf '<!-- sheet:heartbeat host=%s -->' "$COORD_HOST"; }

# coord_heartbeat_read — the owner's read of every reader's heartbeat comment, as a JSON array.
coord_heartbeat_read() {
  local n raw cached
  # Only the sheet it has written: before the first write no reader can have posted, and a lookup would cost a call.
  cached=$(head -1 "$COORD_SHEET_ISSUE_FILE" 2>/dev/null); n=${cached%%$'\t'*}
  case "$n" in ''|*[!0-9]*) printf '[]'; return 0 ;; esac
  [ "$cached" = "$n"$'\t'"$COORD_SHEET_LABEL" ] || { printf '[]'; return 0; }
  raw=$(gh_call api "repos/$REPO_SLUG/issues/$n/comments?per_page=100" 2>/dev/null) || { printf '[]'; return 1; }
  jq -c '[if type == "array" then .[] else empty end | (.body // "") | split("\n")[]
          | capture("^<!-- sheet:heartbeat-json (?<j>\\{.*\\}) -->\r?$")? | .j | fromjson? | select(type == "object")]' <<<"$raw" 2>/dev/null \
    || printf '[]'
}

# coord_heartbeat_post <heartbeat json> — a reader's comment on the sheet, edited in place: written
# when what it says changes, or every third of staleMin so the owner can tell quiet from gone.
coord_heartbeat_post() {
  local hb="$1" n h now beat id old_h old_at body resp line
  now=$(swarm_now); beat=$(( COORD_SHEET_STALE_MIN * 60 / 3 ))
  # Capacity and whole-percent usage too: the owner splits the fleet cap on them.
  # The allowance in tenths: a host going low reaches the others within a tick.
  h=$(_sheet_hash "$(jq -cS '{version, installed, builds, role, capacity,
                              usage: ((.usage // {}) | map_values((.u * 100 | round))),
                              gh: [(.gh // [])[] | {resource, reset, tenth: (if .limit > 0 then (.remaining * 10 / .limit | floor) else 0 end)}]}' <<<"$hb")")
  IFS=$'\t' read -r id old_h old_at < "$COORD_HEARTBEAT_STATE" 2>/dev/null || { id=""; old_h=""; old_at=0; }
  case "$old_at" in ''|*[!0-9]*) old_at=0 ;; esac
  case "$id" in *[!0-9]*) id="" ;; esac
  if [ -n "$id" ] && [ "$h" = "$old_h" ] && [ $(( now - old_at )) -lt "$beat" ]; then printf 'heartbeat: unchanged — not posted'; return 0; fi
  if coord_shadow; then printf 'heartbeat: would post it'; return 0; fi
  n=$(coord_sheet_issue) || { printf 'heartbeat: no sheet issue to post on'; return 1; }
  line=$(jq -r '"**\(.host)** · harness \(.version) · \(if .freeGb == null then "disk not read" else "\(.freeGb) GB free" end) · \(.builds) building"
                + (if .usage.five_hour then " · five-hour usage \(.usage.five_hour.u * 100 | round)%" else "" end)' <<<"$hb")
  body=$(printf '%s\n%s · last tick %s\n<!-- sheet:heartbeat-json %s -->' "$(_hb_marker)" "$line" "$(_sheet_when "$now")" "$hb")
  _hb_patch() { [ -n "$id" ] && resp=$(jq -n --arg b "$body" '{body: $b}' | gh_call api --method PATCH "repos/$REPO_SLUG/issues/comments/$id" --input - 2>/dev/null) \
                 && [ "$(jq -r '.id // empty' <<<"$resp" 2>/dev/null)" = "$id" ]; }
  if ! _hb_patch; then
    # Its comment looked up by marker; posted anew only when the list was read and holds none,
    # so a refused edit never leaves a second heartbeat beside the first.
    resp=$(gh_call api "repos/$REPO_SLUG/issues/$n/comments?per_page=100" 2>/dev/null) \
      && jq -e 'type == "array"' >/dev/null 2>&1 <<<"$resp" \
      || { printf 'heartbeat: the comments on #%s could not be read — trying again next tick' "$n"; return 1; }
    id=$(jq -r --arg m "$(_hb_marker)" '[.[] | select((.body // "") | startswith($m)) | .id] | .[0] // empty' <<<"$resp" 2>/dev/null)
    case "$id" in *[!0-9]*) id="" ;; esac
    if [ -n "$id" ]; then
      _hb_patch || { printf 'heartbeat: the edit to its comment on #%s was refused — trying again next tick' "$n"; return 1; }
    else
      resp=$(jq -n --arg b "$body" '{body: $b}' | gh_call api --method POST "repos/$REPO_SLUG/issues/$n/comments" --input - 2>/dev/null) || resp=""
      id=$(jq -r '.id // empty' <<<"$resp" 2>/dev/null)
      case "$id" in ''|*[!0-9]*) rm -f "$COORD_HEARTBEAT_STATE"; printf 'heartbeat: the post to #%s was refused — trying again next tick' "$n"; return 1 ;; esac
    fi
  fi
  printf '%s\t%s\t%s\n' "$id" "$h" "$now" > "$COORD_HEARTBEAT_STATE.$$" && mv -f "$COORD_HEARTBEAT_STATE.$$" "$COORD_HEARTBEAT_STATE"
  printf 'heartbeat: posted on #%s' "$n"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  case "${1:-}" in
    show)
      echo "this host: $COORD_HOST · role: $(coord_sheet_role) · owner: ${COORD_SHEET_OWNER:-none set}"
      [ "$(coord_sheet_role)" = off ] && exit 0
      if coord_sheet_read; then
        echo "sheet: ${SHEET_AGE_MIN} min old, from $SHEET_FROM"
        jq -r '.[] | "#\(.n)\t\(.class)\tP\(.prin)\t\(.host // "ready")"' <<<"$SHEET_ORDER"
      else
        echo "sheet: not workable — $SHEET_WHY"; exit 1
      fi ;;
    *) sed -n '2,36p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' ;;
  esac
fi
