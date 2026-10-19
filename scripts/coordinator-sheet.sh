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
#   COORDINATOR_HOST                         this machine's name; default the one claims carry

_sheet_self="${BASH_SOURCE[0]}"
if [ "$_sheet_self" = "$0" ]; then
  set -uo pipefail
  . "$(cd "$(dirname "$_sheet_self")" && pwd)/coordinator-env.sh" || exit 1
fi
. "$(cd "$(dirname "$_sheet_self")" && pwd)/claim-proc.sh" || return 1 2>/dev/null || exit 1
unset _sheet_self

COORD_HOST="${COORDINATOR_HOST:-$(claim_host)}"
COORD_SHEET_OWNER="${COORDINATOR_SHEET_OWNER-$(swarm_opt coordinator.sheet.owner "")}"
COORD_SHEET_STALE_MIN="${COORDINATOR_SHEET_STALE_MIN:-$(swarm_opt coordinator.sheet.staleMin 15)}"
case "$COORD_SHEET_STALE_MIN" in ""|0|*[!0-9]*) COORD_SHEET_STALE_MIN=15 ;; esac
COORD_SHEET_LABEL="${COORDINATOR_SHEET_LABEL:-$(swarm_opt coordinator.sheet.label build-sheet)}"
COORD_SHEET_TITLE="${COORDINATOR_SHEET_TITLE:-$(swarm_opt coordinator.sheet.title "Build queue — the shared sheet")}"
COORD_SHEET_STOP_LABELS="${COORDINATOR_SHEET_STOP_LABELS:-$(swarm_opt coordinator.sheet.stopLabels after-launch)}"
COORD_SHEET_ISSUE_FILE="$COORD_DIR/sheet.issue"
COORD_SHEET_STATE="$COORD_DIR/sheet.written"   # <hash> \t <epoch written>
COORD_SHEET_COPY="$COORD_DIR/sheet.read.md"    # a reader's last good copy

_sheet_lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

# coord_sheet_role — off (no owner set), owner (this host), or reader.
coord_sheet_role() {
  [ -n "$COORD_SHEET_OWNER" ] || { printf off; return 0; }
  if [ "$(_sheet_lower "$COORD_HOST")" = "$(_sheet_lower "$COORD_SHEET_OWNER")" ]; then printf owner; else printf reader; fi
}

# coord_sheet_issue [create] — the sheet's number: cached, else the open issue with
# the label (one REST list), else, with create, a new pinned one. 1 when none.
coord_sheet_issue() {
  local n label_q
  n=$(cat "$COORD_SHEET_ISSUE_FILE" 2>/dev/null)
  case "$n" in ''|*[!0-9]*) n="" ;; *) printf '%s' "$n"; return 0 ;; esac
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
  printf '%s\n' "$n" > "$COORD_SHEET_ISSUE_FILE"
  printf '%s' "$n"
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
# the queue's run order; an entry a host holds stays in its place, named.
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
    {order: [$wide | split("\n")[] | select(length > 0) | split("\t")
        | {n: (.[0] | tonumber), class: .[1], prin: (.[2] | tonumber? // 9)} as $e
        | ($iss[($e.n | tostring)] // null) as $i
        | select($i != null and ($i.state // "OPEN") == "OPEN")
        | ($i.labels // []) as $ls
        | ($heldby[($e.n | tostring)].host // "") as $h
        | select($h != "" or startable($ls; $e.class))
        | $e + {kind: coord_kind($ls; ""; null; $i.title), title: ($i.title // "")}
          + (if $h != "" then {host: $h} else {} end)],
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
    def kind: if .class == "repair" then "Red PR to fix" elif .class == "approved-merge" then "Approved, to merge"
              else {"half-built":"Half-built","feature":"Feature","polish":"Polish"}[.kind // ""] // "Fix" end;
    def cut: if length > 90 then .[0:89] + "…" else . end;
    (.order | length) as $n
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
      (if $n == 0 then "Nothing is ready to start."
       else (.order | to_entries[] | .key as $i | .value
             | "\($i + 1). #\(.n) · \(.prin | pri) · \(kind) · \(.title | cut) — \(if (.host // "") != "" then "building on " + .host else "ready" end)") end),
      "",
      "<!-- sheet:v1 updated=\($at) owner=\($owner) -->",
      "```json",
      (.order | map({n, class, prin} + (if (.host // "") != "" then {host} else {} end)) | tojson),
      "```"' <<<"$e"
}

_sheet_hash() { printf '%s' "$1" | cksum | awk '{ print $1 "-" $2 }'; }

# coord_sheet_publish <entries json> — the owner's write. Nothing when the content
# is what it last wrote and the heartbeat is not due. Prints what it did.
coord_sheet_publish() {
  local e="$1" h old_h old_at now beat n body
  now=$(swarm_now)
  h=$(_sheet_hash "$(jq -cS . <<<"$e")")
  old_h=$(cut -f1 "$COORD_SHEET_STATE" 2>/dev/null); old_at=$(cut -f2 "$COORD_SHEET_STATE" 2>/dev/null)
  case "$old_at" in ''|*[!0-9]*) old_at=0 ;; esac
  beat=$(( COORD_SHEET_STALE_MIN * 60 / 3 ))
  if [ "$h" = "$old_h" ] && [ $(( now - old_at )) -lt "$beat" ]; then
    printf 'unchanged — not written'; return 0
  fi
  if coord_shadow; then printf 'would write it (%s)' "$([ "$h" = "$old_h" ] && echo heartbeat || echo changed)"; return 0; fi
  n=$(coord_sheet_issue create) || { printf 'no sheet issue could be found or made'; return 1; }
  body=$(coord_sheet_render "$e" "$now")
  if ! jq -n --arg b "$body" --arg t "$COORD_SHEET_TITLE" '{body: $b, title: $t}' \
       | gh_call api -X PATCH "repos/$REPO_SLUG/issues/$n" --input - >/dev/null 2>&1; then
    # A sheet that was closed or deleted is looked for again next tick.
    rm -f "$COORD_SHEET_ISSUE_FILE"
    printf 'the write to #%s was refused — trying again next tick' "$n"; return 1
  fi
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
  SHEET_ORDER=""; SHEET_AT=""; SHEET_AGE_MIN=""; SHEET_WHY=""; SHEET_FROM=""
  body=""
  if n=$(coord_sheet_issue); then
    raw=$(gh_call api "repos/$REPO_SLUG/issues/$n" 2>/dev/null) || raw=""
    if [ -n "$raw" ] && jq -e '.state == "open"' >/dev/null 2>&1 <<<"$raw"; then
      body=$(jq -r '.body // ""' <<<"$raw")
      printf '%s\n' "$body" > "$COORD_SHEET_COPY.$$" && mv -f "$COORD_SHEET_COPY.$$" "$COORD_SHEET_COPY"
    elif [ -n "$raw" ]; then
      rm -f "$COORD_SHEET_ISSUE_FILE"   # closed: looked for again next tick
    fi
  fi
  if [ -z "$body" ]; then
    from=copy
    body=$(cat "$COORD_SHEET_COPY" 2>/dev/null)
    [ -n "$body" ] || { SHEET_WHY="the sheet could not be read$(gh_limit_why >/dev/null 2>&1 && printf ' (%s)' "$(gh_limit_why)") and there is no copy of it"; return 1; }
  fi
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
    ((.tickets // []) | map(select(.front))) as $front
    | ($front | map(.n)) as $fn
    | .source = "sheet" | .sheet_at = $at
    | .scope = (.scope // "sheet") | .label = (.label // "the shared sheet")
    | .tickets = ($front + [$o[] | select((.host // "") == "") | select(.n as $n | $fn | index($n) | not)
                           | {n, class: (.class // "new"), prin: (.prin // 9), note: ""}])' <<<"$cur" \
    > "$COORD_QUEUE.$$" && mv -f "$COORD_QUEUE.$$" "$COORD_QUEUE"
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
