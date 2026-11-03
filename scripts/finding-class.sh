#!/usr/bin/env bash
# finding-class.sh — every review finding has a class; a class seen a second time is told
# to the PM once, with the source fix to make; one command counts each class a week.
# It replaces the lesson check, which asked each builder for one more test on its own
# change, never changed what builders read or build with, and never counted whether a
# mistake came back.
#
#   finding-class.sh key
#       the class key of the one finding on stdin.
#   finding-class.sh record <ticket> <posted.jsonl> [<pr>]
#       each finding the review step posted (steps/review.posted.jsonl) becomes one sighting
#       on the class ledger; then every class seen twice or more, on this machine or any
#       other, that has had no notice is told to the PM ONCE (coordinator-notify.sh, agent
#       class: the PM's channel) with its instances and a proposed source fix.
#   finding-class.sh fixed <class key> "<what changed>"
#       the class's source fix landed now: the weekly count says from then on whether the
#       class falls. A red check's class is `check:<check name>`.
#   finding-class.sh weekly [--weeks N]
#       the count per class per ISO week (default the last 4): review classes and red checks
#       (develop-red.sh count, check-class-count.tsv) in one table. A class whose count has
#       not fallen since its source fix reads "not falling".
#   exit 0 done · 2 usage or unreadable input
#
# THE KEY is class_key (scripts/finding-key.jq): the review's own `class` as a slug, the
# shape the code sweep keys its classes in (`sweep-class`); a finding with no class falls
# back to finding_key, its file and the first twelve words of its summary. Both are fields
# the review already returns: no model call here, ever.
#
# HOW MANY is review.classNoticeAt in harness.json (default 2, read through swarm_opt): the
# count of sightings at which the PM is told.
#
# A SIGHTING is one finding on one change: ticket, key and file. The same finding still
# standing in a later round is the same sighting, not a repeat.
#
# ANY MACHINE. Each host keeps its own ledger and publishes it as ONE comment on a shared
# tally issue (label findingClasses.label, default finding-classes), edited in place: the
# coordinator sheet's fleet pattern. A record reads that issue once, so a class seen once
# here and once on another host is seen twice. A notice is posted there too, marked, so no
# other host tells the PM again. An unreadable tally is said, and that pass counts this
# host alone. findingClasses.share false, or FINDING_CLASS_SHARE=off, keeps it local.
#
# THE BUILDER NEVER GETS THE CLASS BACK. Nothing here writes to the ticket, its PR or a
# brief: a repeat is a source fix for the PM (a kit component, a lint rule, a brief or
# REVIEW.md line), never one more test on the next change.
#
#   finding-classes.jsonl      one sighting a line: {id, at, week, key, class, ticket, pr,
#                              file, line, grade, summary, host}
#   finding-classes.noticed    one key a line: told to the PM
#   finding-classes.fixed.tsv  <key> \t <epoch> \t <what changed>
#   finding-classes.issue      the tally issue's number, once found
# Seams: FINDING_CLASS_LEDGER (the jsonl; the rest sit beside it), FINDING_CLASS_NOTIFY,
# FINDING_CLASS_SHARE, FINDING_CLASS_NOW, FINDING_CLASS_HOST, SWARM_GH, DEVELOP_RED_COUNT.
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KEYDEF="$(cat "$SELF_DIR/finding-key.jq")" || { echo "finding-class: $SELF_DIR/finding-key.jq is missing" >&2; exit 2; }
die() { echo "finding-class: $*" >&2; exit 2; }
say() { echo "finding-class: $*"; }

CMD="${1:-}"
case "$CMD" in
  key) jq -r "$KEYDEF class_key" 2>/dev/null || die "the finding on stdin is not JSON"; exit 0 ;;
  record|fixed|weekly) shift ;;
  *) die "usage: finding-class.sh key | record <ticket> <posted.jsonl> [<pr>] | fixed <key> \"<what>\" | weekly [--weeks N]" ;;
esac

if ! . "$SELF_DIR/toolkit-env.sh" >/dev/null 2>&1; then
  [ -n "${FINDING_CLASS_LEDGER:-}" ] || die "no harness.json to find the state dir in, and no FINDING_CLASS_LEDGER"
  REPO_SLUG=""
fi
declare -F toolkit_cfg >/dev/null 2>&1 || toolkit_cfg() { return 1; }
# swarm-env.sh's own reader, without the rest of swarm-env: the setting, else its default.
declare -F swarm_opt >/dev/null 2>&1 || swarm_opt() { local v; v=$(toolkit_cfg "$1" 2>/dev/null) || v=""; printf '%s' "${v:-$2}"; }
declare -F gh_read >/dev/null 2>&1 || . "$SELF_DIR/gh-batch.sh" || exit 2
export GH_CALL_TIMEOUT="${GH_CALL_TIMEOUT:-30}"

LEDGER="${FINDING_CLASS_LEDGER:-${STATE_DIR:-}/swarm/finding-classes.jsonl}"
[ "$LEDGER" != /swarm/finding-classes.jsonl ] || die "no state dir: set stateDir in harness.json or FINDING_CLASS_LEDGER"
NOTICED="${LEDGER%.jsonl}.noticed"; FIXED="${LEDGER%.jsonl}.fixed.tsv"; ISSUE_CACHE="${LEDGER%.jsonl}.issue"
mkdir -p "$(dirname "$LEDGER")" 2>/dev/null; touch "$LEDGER" "$NOTICED" "$FIXED" 2>/dev/null
NOTIFY="${FINDING_CLASS_NOTIFY:-$SELF_DIR/coordinator-notify.sh}"
HOST="${FINDING_CLASS_HOST:-${COORDINATOR_HOST:-$(hostname -s 2>/dev/null || echo host)}}"
LABEL=$(toolkit_cfg findingClasses.label 2>/dev/null); LABEL="${LABEL:-finding-classes}"
WINDOW_WEEKS=8 MAX_PUBLISHED=150
# HOW MANY SIGHTINGS TELL THE PM: review.classNoticeAt (default 2). Anthropic's practice names
# no count ("when the reviewer keeps flagging the same thing"), so it is a setting.
NOTICE_AT=$(swarm_opt review.classNoticeAt 2)
case "$NOTICE_AT" in
  ''|*[!0-9]*|0|1)
    [ "$CMD" != record ] || echo "finding-class: review.classNoticeAt is '$NOTICE_AT', not a count of 2 or more, so 2 is used" >&2
    NOTICE_AT=2 ;;
esac

fc_now() { printf '%s' "${FINDING_CLASS_NOW:-$(date +%s)}"; }
fc_week() { date -u -r "$1" +%G-W%V 2>/dev/null || date -u -d "@$1" +%G-W%V; }
fc_share_on() {
  [ "${FINDING_CLASS_SHARE:-on}" != off ] || return 1
  [ "$(toolkit_cfg findingClasses.share 2>/dev/null)" != false ] || return 1
  [ -n "${REPO_SLUG:-}" ]
}

# ---- the shared tally ------------------------------------------------------------------
# fc_tally_issue [create] — the tally issue's number; with create, filed when there is none.
fc_tally_issue() {
  local n rc=0
  n=$(cat "$ISSUE_CACHE" 2>/dev/null)
  case "$n" in ''|*[!0-9]*) n="" ;; esac
  [ -n "$n" ] && { printf '%s' "$n"; return 0; }
  n=$(gh_read "the finding-class tally" api "repos/$REPO_SLUG/issues?labels=$LABEL&state=open&per_page=5" \
        -q '[.[]? | select(.pull_request == null)][0].number // empty') || return 1
  if [ -z "$n" ] && [ "${1:-}" = create ]; then
    n=$(gh_call api -X POST "repos/$REPO_SLUG/issues" -f title="Finding classes: the shared tally (not a ticket)" \
          -f body="Each build machine keeps one comment here: the review-finding classes it has seen (scripts/finding-class.sh). A class seen a second time, on any change or machine, gets one notice comment here and one line in the PM's channel. Not a ticket: nothing builds from it. \`finding-class.sh weekly\` prints the count." \
          -f "labels[]=$LABEL" -q .number 2>/dev/null) || n=""
  fi
  case "$n" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s\n' "$n" > "$ISSUE_CACHE"
  printf '%s' "$n"
}

# fc_tally_read <issue> — the tally's comments as JSON lines: {own: <comment id>} for this
# host's, {s: <sighting>} for each of the other hosts', {n: <key>} for each notice posted.
fc_tally_read() {
  local raw rc=0
  raw=$(gh_read "the finding-class tally's comments" api --paginate "repos/$REPO_SLUG/issues/$1/comments?per_page=100") || rc=$?
  if [ "$rc" -eq "${GH_READ_MISSING:-68}" ]; then rm -f "$ISSUE_CACHE"; return 1; fi
  [ "$rc" -eq 0 ] || return 1
  printf '%s' "$raw" | jq -s -c --arg host "$HOST" '
    (map(if type == "array" then .[] else . end)) | .[] | select(type == "object") | (.body // "") as $b
    | if ($b | test("<!-- finding-classes:v1 host=")) then
        ($b | capture("<!-- finding-classes:v1 host=(?<h>[^ ]+) -->").h) as $h
        | if $h == $host then {own: .id}
          else (($b | capture("```json\n(?<j>[\\s\\S]*?)\n```").j? // "[]") | (fromjson? // []) | .[]? | select(type == "object") | {s: .}) end
      elif ($b | test("<!-- finding-class-notice: ")) then {n: ($b | capture("<!-- finding-class-notice: (?<k>.*?) -->").k)}
      else empty end' 2>/dev/null
}

# fc_tally_publish <issue> <own comment id or ""> — this host's sightings, the newest first,
# as its one comment.
fc_tally_publish() {
  local n="$1" id="$2" rows body cutoff
  cutoff=$(( $(fc_now) - WINDOW_WEEKS * 7 * 86400 ))
  rows=$(jq -s -c --argjson c "$cutoff" --argjson max "$MAX_PUBLISHED" '
    [.[] | select((.at // 0) >= $c)] | sort_by(-.at) | .[:$max]
    | map(. + {summary: ((.summary // "") | tostring | .[0:140] | gsub("`"; "'"'"'")), file: ((.file // "") | tostring | gsub("`"; "'"'"'"))})' "$LEDGER" 2>/dev/null) || return 1
  body="<!-- finding-classes:v1 host=$HOST -->
Review-finding classes seen on **$HOST**, the last $WINDOW_WEEKS weeks. Written by \`scripts/finding-class.sh\` and edited in place; never edit it by hand.

\`\`\`json
$rows
\`\`\`"
  if [ -n "$id" ]; then
    jq -n --arg b "$body" '{body: $b}' | gh_call api --method PATCH "repos/$REPO_SLUG/issues/comments/$id" --input - >/dev/null 2>&1
  else
    jq -n --arg b "$body" '{body: $b}' | gh_call api --method POST "repos/$REPO_SLUG/issues/$n/comments" --input - >/dev/null 2>&1
  fi
}

# ---- the notice --------------------------------------------------------------------------
# fc_proposal <sightings json> — the source fix to propose, from where the class lives.
fc_proposal() {
  jq -r '[.[].file // "" | tostring] as $f
    | if any($f[]; test("\\.(tsx|jsx|vue|svelte|css|scss)(:[0-9]+)?$") or test("(^|/)(components|ui)/")) then
        "a kit component (or a prop on one) that cannot be built the wrong way, and the screens moved onto it"
      elif any($f[]; test("\\.(ts|js|mjs|cjs|py|sh|go|rb|rs|java|kt|swift)(:[0-9]+)?$")) then
        "a lint rule or a write-time check that refuses the pattern where it is written"
      else
        "a line in the build brief or REVIEW.md that names the mistake, so the next builder never writes it"
      end' <<<"$1"
}

# fc_notice_line <key> <sightings json> — the one line the PM is told.
fc_notice_line() {
  local inst prop
  inst=$(jq -r '[.[] | "\(if (.pr // "") != "" then "PR #\(.pr)" else "ticket #\(.ticket)" end) \(.file // "?"):\(.line // 0)\(if (.host // "") != "" then " (\(.host))" else "" end)"] | unique | .[:8] | join("; ")' <<<"$2")
  prop=$(fc_proposal "$2")
  printf "Finding class '%s' seen %s times — %s. What it is: %s. Fix it at the source: %s. Not a test on the next change. When the fix lands: finding-class.sh fixed '%s' \"<what changed>\"." \
    "$1" "$(jq 'length' <<<"$2")" "$inst" "$(jq -r '.[0].summary // "" | tostring | .[0:160]' <<<"$2")" "$prop" "$1"
}

# ---- record ------------------------------------------------------------------------------
fc_record() {
  local t="${1:-}" posted="${2:-}" pr="${3:-}" at wk new added share=0 issue="" own="" tally="" k line all keys nb
  [ -n "$t" ] && [ -n "$posted" ] || die "usage: record <ticket> <posted.jsonl> [<pr>]"
  [ -s "$posted" ] || { say "#$t: no finding was posted, so there is nothing to class"; return 0; }
  at=$(fc_now); wk=$(fc_week "$at")
  new=$(jq -c --arg t "$t" --arg pr "$pr" --arg host "$HOST" --argjson at "$at" --arg wk "$wk" "$KEYDEF"'
      select(type == "object") | class_key as $k
      | ((.file // "") | tostring | sub("^\\./"; "") | sub(":[0-9]+$"; "")) as $file
      | {id: "\($t)|\($k)|\($file)", at: $at, week: $wk, key: $k, class: (.class // null), ticket: $t, pr: $pr,
         file: $file, line: (.line // 0), grade: (.grade // ""), summary: (.summary // ""), host: $host}' "$posted" 2>/dev/null) \
    || die "#$t: $posted is not one JSON finding a line"
  added=$(jq -c --slurpfile have "$LEDGER" '([$have[].id]) as $ids | select(.id as $i | $ids | index($i) | not)' <<<"$new" \
    | jq -s -c 'unique_by(.id) | .[]')
  [ -z "$added" ] || printf '%s\n' "$added" >> "$LEDGER"
  say "#$t: $(printf '%s' "$added" | grep -c .) new sighting(s) on the class ledger, $(printf '%s' "$new" | grep -c .) finding(s) posted"

  # Every machine's sightings: this host's ledger and, when it can be read, the tally.
  if fc_share_on; then
    if issue=$(fc_tally_issue create) && tally=$(fc_tally_read "$issue"); then share=1
      own=$(printf '%s\n' "$tally" | jq -r 'select(.own) | .own' | head -1)
    else
      say "unknown — the shared tally could not be read; this pass counts this host's sightings only"
    fi
  fi
  all=$( { cat "$LEDGER"; [ "$share" = 1 ] && printf '%s\n' "$tally" | jq -c 'select(.s) | .s'; } | jq -s -c 'unique_by(.id)')
  keys=$(jq -r --argjson at "$NOTICE_AT" --rawfile seen "$NOTICED" --arg shared "$( [ "$share" = 1 ] && printf '%s\n' "$tally" | jq -r 'select(.n) | .n')" '
      (($seen + "\n" + $shared) | split("\n") | map(select(length > 0))) as $told
      | group_by(.key)[] | select(length >= $at) | .[0].key | select(. as $k | $told | index($k) | not)' <<<"$all")
  while IFS= read -r k; do
    [ -n "$k" ] || continue
    line=$(fc_notice_line "$k" "$(jq -c --arg k "$k" '[.[] | select(.key == $k)] | sort_by(.at)' <<<"$all")")
    if ! bash "$NOTIFY" --class agent "finding-class:$k" "$line" >/dev/null 2>&1; then
      say "the PM could not be told of class '$k' — the next record tries again"; continue
    fi
    printf '%s\n' "$k" >> "$NOTICED"
    say "told the PM once: $line"
    [ "$share" = 1 ] || continue
    nb=$(jq -n --arg b "**Seen again.** $line"$'\n\n'"<!-- finding-class-notice: $k -->" '{body: $b}')
    printf '%s' "$nb" | gh_call api --method POST "repos/$REPO_SLUG/issues/$issue/comments" --input - >/dev/null 2>&1 \
      || say "the notice for '$k' could not be posted on the tally (#$issue); another host may tell the PM again"
  done <<<"$keys"
  if [ "$share" = 1 ] && [ -n "$added" ]; then
    fc_tally_publish "$issue" "$own" || say "this host's sightings could not be published on the tally (#$issue); the next record tries again"
  fi
  return 0
}

# ---- fixed -------------------------------------------------------------------------------
fc_fixed() {
  local k="${1:-}" what="${2:-}"
  [ -n "$k" ] && [ -n "$what" ] || die "usage: fixed <class key> \"<what changed>\""
  printf '%s\t%s\t%s\n' "$k" "$(fc_now)" "$(printf '%s' "$what" | tr '\t\n' '  ')" >> "$FIXED"
  say "'$k': source fix recorded for $(fc_week "$(fc_now)") — the weekly count shows whether it falls"
}

# ---- weekly ------------------------------------------------------------------------------
fc_weekly() {
  local weeks=4 now i w wl="" rows issue tally share=0 note=""
  while [ $# -gt 0 ]; do
    case "$1" in --weeks) weeks="${2:-}"; shift 2 ;; *) die "weekly: unknown argument $1" ;; esac
  done
  case "$weeks" in ''|*[!0-9]*|0) weeks=4 ;; esac
  now=$(fc_now)
  for ((i = weeks - 1; i >= 0; i--)); do wl="$wl$(fc_week $((now - i * 604800))) "; done
  if fc_share_on; then
    if issue=$(fc_tally_issue) && tally=$(fc_tally_read "$issue"); then share=1
    else note="(the shared tally could not be read, or there is none yet: this host's sightings only)"; fi
  fi
  # One row per sighting: <week> \t <kind> \t <key>. Review classes from every machine's
  # sightings; red checks from develop-red.sh's own weekly count.
  rows=$( { { cat "$LEDGER"; [ "$share" = 1 ] && printf '%s\n' "$tally" | jq -c 'select(.s) | .s'; } \
              | jq -s -r 'unique_by(.id)[] | "\(.week)\treview\t\(.key)\t\(.at // 0)"'
            for w in $(fc_week $((now - (weeks + 1) * 604800))) $(fc_week $((now - weeks * 604800))) $wl; do
              bash "$SELF_DIR/develop-red.sh" count "$w" 2>/dev/null | awk -F'\t' -v w="$w" 'NF >= 2 { for (i = 0; i < $1; i++) print w "\tcheck\tcheck:" $2 "\t0" }'
            done; } 2>/dev/null)
  printf '%s\n' "finding classes by week — review findings and red checks, from the ledgers; no model calls"
  [ -z "$note" ] || printf '%s\n' "$note"
  printf '%s\n' "$rows" | awk -F'\t' -v weeks="$wl" -v fixed="$FIXED" -v lastfull="$(fc_week $((now - 604800)))" -v cur="$(fc_week "$now")" -v now="$now" '
    function prevweek(w,   y, n) { y = substr(w, 1, 4) + 0; n = substr(w, 7) + 0; if (n > 1) return sprintf("%04d-W%02d", y, n - 1); return sprintf("%04d-W52", y - 1) }
    BEGIN { nw = split(weeks, W, " "); while ((getline l < fixed) > 0) { split(l, f, "\t"); fx[f[1]] = f[2] } }
    NF >= 3 { c[$3 SUBSEP $1]++; kind[$3] = $2; if (index(weeks, $1)) tot[$3]++; if ($4 > 0) { na[$3]++; at[$3, na[$3]] = $4 } }
    END {
      hdr = sprintf("%-44s %-6s", "class", "kind"); for (i = 1; i <= nw; i++) hdr = hdr sprintf(" %8s", W[i]); print hdr "  source fix"
      n = 0; for (k in kind) if (tot[k] > 0 || (k in fx)) keys[++n] = k
      # most first, then by name
      for (i = 1; i <= n; i++) for (j = i + 1; j <= n; j++) if (tot[keys[j]] > tot[keys[i]] || (tot[keys[j]] == tot[keys[i]] && keys[j] < keys[i])) { t = keys[i]; keys[i] = keys[j]; keys[j] = t }
      for (i = 1; i <= n; i++) {
        k = keys[i]; line = sprintf("%-44s %-6s", substr(k, 1, 44), kind[k])
        for (j = 1; j <= nw; j++) line = line sprintf(" %8d", c[k SUBSEP W[j]] + 0)
        st = "—"
        if ((k in fx) && kind[k] == "review") {
          # A review class is timed to the second: the 7 days before its fix against the 7 after.
          before = 0; after = 0; fe = fx[k] + 0
          for (j = 1; j <= na[k]; j++) { a = at[k, j]; if (a >= fe - 604800 && a < fe) before++; else if (a >= fe && a < fe + 604800) after++ }
          cmd = "date -u -r " fe " +%Y-%m-%d 2>/dev/null || date -u -d @" fe " +%Y-%m-%d"; cmd | getline fd; close(cmd)
          if (after > 0 && after >= before) st = "fixed " fd ": NOT FALLING (" before " in the 7 days before, " after " after) — rework the fix"
          else if (after == 0 && now - fe < 604800) st = "fixed " fd ": watching (" before " in the 7 days before, none since)"
          else if (after == 0) st = "fixed " fd ": stopped (" before " in the 7 days before, 0 after)"
          else st = "fixed " fd ": falling (" before " in the 7 days before, " after " after)"
        } else if (k in fx) {
          # A red check is counted by ISO week: the week before its fix against the last one since.
          cmd = "date -u -r " fx[k] " +%G-W%V 2>/dev/null || date -u -d @" fx[k] " +%G-W%V"; cmd | getline fw; close(cmd)
          before = c[k SUBSEP prevweek(fw)] + 0
          aw = (lastfull > fw) ? lastfull : ((cur > fw) ? cur : "")
          if (aw == "") st = fw ": fixed, watching (" before " the week before)"
          else { after = c[k SUBSEP aw] + 0
            if (after > 0 && after >= before) st = fw ": NOT FALLING (" before " the week before, " after " in " aw ") — rework the fix"
            else if (after == 0) st = fw ": stopped (" before " the week before, 0 in " aw ")"
            else st = fw ": falling (" before " the week before, " after " in " aw ")" }
        }
        print line "  " st
      }
      if (n == 0) print "(no class seen in the window)"
    }'
}

case "$CMD" in
  record) fc_record "$@" ;;
  fixed) fc_fixed "$@" ;;
  weekly) fc_weekly "$@" ;;
esac
