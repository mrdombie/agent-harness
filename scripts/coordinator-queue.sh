#!/usr/bin/env bash
# coordinator-queue.sh — the coordinator's queue: one JSON file in the state dir,
# in place of a hand-written markdown list.
#
#   coordinator-queue.sh seed <scope>[,<scope>…]  resolve each scope and fill the queue
#   coordinator-queue.sh refresh           re-seed from the scopes already recorded
#   coordinator-queue.sh list              the queue in the order it runs
#   coordinator-queue.sh in-scope <n>      exit 0 when ticket n is under any recorded scope
#   coordinator-queue.sh add <n> [--class repair|approved-merge|new] [--note TEXT] [--front|--first]
#   coordinator-queue.sh remove <n>
#
# A scope resolves the way /agent-harness:work resolves one: a bare number is
# that ticket; a label that exists is that label; otherwise `project:<scope>`.
# A comma list is the union of its scopes. If any one resolves to no label the
# whole seed is refused, naming it, never widened.
#
# The candidates and their order come from claimable-issues.sh, the one
# definition of what may be picked up. A [FINISH PR] row is class repair, the rest
# new. Priority orders the whole queue (P0 first, no priority last); within one
# priority repair, approved-merge, then new; within a class product work before
# our own tooling (coordinator.toolingLabels); then new work half-built, feature,
# other, polish, newest first; repairs keep claimable order. Each entry keeps its
# priority (prin), kind and polish flag. An entry the PM put there with `add --front`
# stays first overall across re-seeds; `add --first` (a resume, an owner's answer, a
# requeue) is first only within its own priority, so it never jumps higher-priority
# work. A `new` entry whose note is a REPAIR brief is class repair. A row nobody can
# start (closed, batched, parked, blocked, held) is dropped. An entry put there with `add` is pinned: it and every
# note survive a re-seed, because nothing on the forge can rebuild them. The
# tick removes an entry once it has spawned it. A seed whose reads fail changes
# nothing.
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/coordinator-env.sh" || exit 1

die() { echo "coordinator-queue: $*" >&2; exit 2; }
CLAIMABLE="${COORDINATOR_CLAIMABLE:-$KIT_ROOT/scripts/claimable-issues.sh}"

empty_queue() { jq -n '{scope: null, label: null, seeded_at: null, tickets: []}'; }
current()     { if [ -s "$COORD_QUEUE" ]; then cat "$COORD_QUEUE"; else empty_queue; fi; }
write()       { local tmp; tmp=$(mktemp "$COORD_DIR/.queue.XXXXXX") && cat > "$tmp" && mv "$tmp" "$COORD_QUEUE"; }

# Read whole, then matched: `gh … | grep -q` under pipefail fails when grep quits on
# an early match while gh is still writing (SIGPIPE), reporting a real label missing.
label_exists() { # <name>
  local names
  names=$(swarm_gh label list --repo "$REPO_SLUG" --search "$1" --limit 100 --json name -q '.[].name' 2>/dev/null)
  grep -qxF -- "$1" <<<"$names"
}

resolve() { # <scope> — echoes the label, or "ticket <n>"
  case "$1" in
    ''|*[!0-9]*) ;;
    *) printf 'ticket %s' "$1"; return 0 ;;
  esac
  if label_exists "$1"; then printf '%s' "$1"; return 0; fi
  if label_exists "${SWARM_PROGRAMME_PREFIX}$1"; then printf '%s%s' "$SWARM_PROGRAMME_PREFIX" "$1"; return 0; fi
  return 1
}

scope_list() { # <comma list> — one trimmed scope per line, empties dropped, de-duplicated
  printf '%s\n' "$1" | tr ',' '\n' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | awk 'NF && !seen[$0]++'
}

seed() { # <scope>[,<scope>…]
  local scope="${1:?seed needs a scope}" s label labels=""
  [ -n "$(scope_list "$scope")" ] || die "'$scope' names no scope — nothing seeded"
  while IFS= read -r s; do
    label=$(resolve "$s") || die "'$s' is neither a ticket number, a label, nor ${SWARM_PROGRAMME_PREFIX}$s — nothing seeded"
    labels="$labels$label"$'\n'
  done <<< "$(scope_list "$scope")"
  labels=$(printf '%s' "$labels" | awk 'NF && !seen[$0]++')
  fill "$scope" "$labels"
}

# A ticket is in scope when it is a named ticket or carries a scope label. The
# claimable list already holds every candidate's labels (its 7th column), so
# membership is read from there: listing each scope label's members was one
# `gh issue list` per scope per refresh, for candidates the list already had.
# A claimable list without that column (an older or stand-in one) falls back to
# listing each scope label's members.
# Polish lists join every scope of labels (PM call 2026-10-19): a screen's list must
# reach the queue to ship once it is full, whatever area or project was seeded. A
# scope of named tickets stays exactly those tickets.
with_lists() { # <scope labels, one a line> — plus the polish-list label when any is a label
  if grep -v '^ticket ' <<<"$1" | grep . >/dev/null; then
    printf '%s\n%s\n' "$1" "$LBL_POLISH_LIST" | awk 'NF && !seen[$0]++'
  else printf '%s\n' "$1"; fi
}
fill() { # <scope> <resolved labels, one a line> — the members, the claimable rows, the write
  local scope="$1" labels="$2" claimable rows label members="" m match
  match=$(with_lists "$labels")
  claimable=$(CLAIMABLE_WITH_LABELS=1 bash "$CLAIMABLE" 2>/dev/null) || die "claimable-issues.sh failed — queue left as it was"
  if printf '%s\n' "$claimable" | awk -F'\t' 'NF && $1 != "" && NF < 7 { bad = 1 } END { exit !bad }'; then
    while IFS= read -r label; do
      case "$label" in
        "ticket "*) m="${label#ticket }" ;;
        *) m=$(swarm_gh issue list --repo "$REPO_SLUG" --state open --label "$label" --limit 1000 \
                 --json number -q '.[].number' 2>/dev/null) || die "could not list $label — queue left as it was" ;;
      esac
      members="$members$m"$'\n'
    done <<< "$match"
    members=$(printf '%s' "$members" | awk 'NF' | sort -u | paste -sd, -)
  fi
  # Through the environment: BSD awk refuses a -v value with a newline in it.
  rows=$(printf '%s\n' "$claimable" | Q_SCOPES="$match" Q_MEMBERS="$members" awk -F'\t' '
           BEGIN { n = split(ENVIRON["Q_SCOPES"], s, "\n"); for (i = 1; i <= n; i++) if (s[i] != "") {
                     if (s[i] ~ /^ticket /) tk[substr(s[i], 8)] = 1; else lb[s[i]] = 1 }
                   n = split(ENVIRON["Q_MEMBERS"], mm, ","); for (i = 1; i <= n; i++) tk[mm[i]] = 1 }
           NF >= 1 && $1 != "" {
             inside = ($1 in tk)
             if (!inside && NF >= 7) { m = split($7, l, ","); for (j = 1; j <= m; j++) if (l[j] in lb) { inside = 1; break } }
             if (inside) print $1 "\t" ($5 == "[FINISH PR]" ? "repair" : "new") "\t" $2 "\t" $5 "\t" $7 "\t" $6
           }')
  # The pinned rows the board did not offer, read in one batch: a closed, batched,
  # parked, blocked or held one is dropped rather than shown as work.
  local pinned_nums pins='{}'
  pinned_nums=$(current | jq -r --arg rows "$rows" '($rows | split("\n") | map(split("\t")[0])) as $f
                  | (.tickets // [])[] | select(.pinned) | (.n|tostring) | select(. as $n | $f | index($n) | not)' 2>/dev/null)
  if [ -n "$pinned_nums" ]; then
    # shellcheck disable=SC2086  # a list of numbers, split on purpose
    pins=$(gh_issues_batch $pinned_nums 2>/dev/null) && jq -e 'type == "object"' >/dev/null 2>&1 <<<"$pins" || pins='{}'
  fi
  current | coord_jq --arg scope "$scope" --arg labels "$labels" --arg at "$(swarm_stamp)" --arg rows "$rows" --argjson pins "$pins" "$COORD_TICKET_JQ"'
    (.tickets // []) as $old
    | ($labels | split("\n") | map(select(length > 0))) as $ls
    | ($old | map({key: (.n|tostring), value: .}) | from_entries) as $byn
    | ($rows | split("\n") | map(select(length > 0) | split("\t")
        | {n: (.[0]|tonumber), class: .[1], pri: (.[2] // ""), mode: (.[3] // ""),
           ls: ((.[4] // "") | split(",")), title: ((.[5] // "") | ascii_downcase)}
        # The kind of work, owner call 2026-10-18: half-built screens first, then
        # features, then other bugs and chores, then polish. Hard-coded, not config.
        | .kind = coord_kind(.ls; .mode; .pri; .title)
        | .prin = coord_prin(.ls; .pri)
        | .polish = coord_polish(.ls; .pri; .title)
        | .plist = ((.ls | index($plist)) != null)
        | .tooling = coord_tooling(.ls; .title)
        | {n, class, kind, prin, polish, plist, tooling, ls})) as $fresh
    | ($fresh | map(($byn[(.n|tostring)] // {}) as $o
                     | . + {note: ($o.note // "")}
                     | if $o.pinned then .class = $o.class | .pinned = true else . end
                     | .class = coord_class(.class; .note)
                     | if $o.front then .front = true else . end
                     | if $o.top then .top = true else . end)
                | map(select(coord_stopped(.ls; .class; "OPEN") | not) | del(.ls))) as $merged
    # A pinned row the board no longer offers stays only while its ticket is open and
    # unstopped; one that could not be read stays (a failed read drops nothing).
    | ($old | map(select(.pinned) | select((.n) as $n | ($fresh | map(.n) | index($n)) == null)
                  | .class = coord_class(.class; .note)
                  | ($pins[(.n|tostring)] // null) as $p
                  | select($p == null or (coord_stopped($p.labels // []; .class; $p.state) | not)))) as $kept
    | ($old | to_entries | map({key: (.value.n|tostring), value: .key}) | from_entries) as $oldpos
    # Priority first, across classes (coord_queue_ordered sorts the same way): an
    # entry the PM put on top (.top) stays first in the order it was put; then
    # priority, and within one priority a front entry (.front) first;
    # within one priority repair, approved-merge, then new; product before tooling;
    # then new by kind, newest first;
    # repair and approved-merge keep the claimable order.
    | ($merged + $kept) | to_entries
    | sort_by(.value as $t | .key as $i
        | if $t.top then [0, ($oldpos[($t.n|tostring)] // $i), 0, 0, 0, 0, 0, 0, 0]
          else [1, 0, ($t.prin // 9),
                (if $t.front then 0 else 1 end), (if $t.front then ($oldpos[($t.n|tostring)] // $i) else 0 end),
                ({"repair":0,"approved-merge":1,"new":2}[$t.class] // 3),
                (if $t.tooling then 1 else 0 end),
                (if $t.class == "new" then ({"half-built":0, feature:1, other:2, polish:3}[$t.kind // ""] // 9) else 0 end),
                (if $t.class == "new" then -$t.n else $i end)] end)
    | map(.value)
    | {scope: $scope, label: ($ls | join(", ")), labels: $ls, seeded_at: $at, tickets: .}' | write
  echo "seeded $(jq '.tickets | length' "$COORD_QUEUE") ticket(s) for $(jq -r '.label' "$COORD_QUEUE")"
}

# The scopes were resolved to labels when seeded; re-resolving them asked GitHub
# one `label list` per scope on every tick, for an answer that does not move.
refresh() {
  local scope labels; scope=$(current | jq -r '.scope // empty')
  [ -n "$scope" ] || die "no scope recorded — run 'seed <scope>' first"
  labels=$(current | jq -r 'if (.labels | type) == "array" then .labels[] else empty end')
  if [ -n "$labels" ]; then fill "$scope" "$labels"; else seed "$scope"; fi
}

# A queue seeded before scopes were lists holds one label in .label and no .labels.
scope_labels() { current | jq -r 'if (.labels | type) == "array" then .labels[] else (.label // empty) end'; }

in_scope() { # <n> — 0 under any scope, 1 outside every one, 2 unreadable
  case "${1:-}" in ''|*[!0-9]*) die "in-scope needs a ticket number" ;; esac
  local ls have l
  ls=$(scope_labels); [ -n "$ls" ] || die "no scope recorded — run 'seed <scope>' first"
  grep -qxF "ticket $1" <<<"$ls" && return 0
  ls=$(with_lists "$ls")
  have=$(swarm_gh issue view "$1" --repo "$REPO_SLUG" --json labels -q '.labels[].name' 2>/dev/null) \
    || { echo "coordinator-queue: #$1 could not be read" >&2; return 2; }
  while IFS= read -r l; do
    [ -n "$l" ] && grep -qxF -- "$l" <<<"$have" && return 0
  done <<< "$ls"
  return 1
}

add() {
  local n="" cls=new note="" front=false top=false
  while [ $# -gt 0 ]; do
    case "$1" in
      --class) cls="${2:?--class needs a value}"; shift 2 ;;
      --front) top=true; shift ;;
      --first) front=true; shift ;;
      --note)  note="${2:-}"; shift 2 ;;
      -*)      die "unknown flag $1" ;;
      *)       n="$1"; shift ;;
    esac
  done
  case "$n" in ''|*[!0-9]*) die "add needs a ticket number" ;; esac
  case "$cls" in repair|approved-merge|new) ;; *) die "class must be repair, approved-merge or new" ;; esac
  # What the seed would know of it, read now: `list` and the live view rank it
  # the way the tick does. Unread, it ranks as no priority until the tick reads it.
  local meta
  meta=$(swarm_gh issue view "$n" --repo "$REPO_SLUG" --json labels,title 2>/dev/null \
    | coord_jq -c "$COORD_TICKET_JQ"'[.labels[]?.name] as $ls
        | {prin: coord_prin($ls; null), kind: coord_kind($ls; ""; null; .title), polish: coord_polish($ls; null; .title),
           plist: (($ls | index($plist)) != null), tooling: coord_tooling($ls; .title)}' 2>/dev/null)
  jq -e 'type == "object"' >/dev/null 2>&1 <<<"$meta" || meta='{}'
  cls=$(coord_jq -rn --arg c "$cls" --arg note "$note" "$COORD_TICKET_JQ"'coord_class($c; $note)')
  current | jq --argjson n "$n" --arg c "$cls" --arg note "$note" --argjson front "$front" --argjson top "$top" --argjson meta "$meta" '
    # What the queue already knew of it stands where this read came back empty.
    (((.tickets // []) | map(select(.n == $n)) | first // {} | del(.front, .top))
      + {n: $n, class: $c, note: $note, pinned: true} + $meta
      + (if $top then {top: true} elif $front then {front: true} else {} end)) as $e
    | ((.tickets // []) | map(select(.n != $n))) as $rest
    | .tickets = (if $top or $front then [$e] + $rest else $rest + [$e] end)' | write
  echo "queued #$n as $cls"
}

remove() {
  case "${1:-}" in ''|*[!0-9]*) die "remove needs a ticket number" ;; esac
  current | jq --argjson n "$1" '.tickets = ((.tickets // []) | map(select(.n != $n)))' | write
  echo "removed #$1"
}

list() {
  local n=0 t c note
  echo "scope: $(current | jq -r '.label // "none"')"
  while IFS=$'\t' read -r t c note; do
    [ -n "${t:-}" ] || continue
    n=$((n+1)); printf '%2d. #%-7s %-15s %s\n' "$n" "$t" "$c" "$note"
  done <<< "$(coord_queue_ordered)"
  [ "$n" -gt 0 ] || echo "the queue is empty"
}

case "${1:-}" in
  seed)    shift; seed "$@" ;;
  refresh) refresh ;;
  in-scope) shift; in_scope "$@" ;;
  add)     shift; add "$@" ;;
  remove)  shift; remove "$@" ;;
  list)    list ;;
  -h|--help|"") sed -n '2,30p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' ;;
  *)       die "unknown command '$1'" ;;
esac
