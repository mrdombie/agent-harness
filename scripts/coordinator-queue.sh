#!/usr/bin/env bash
# coordinator-queue.sh — the coordinator's queue: one JSON file in the state dir,
# in place of a hand-written markdown list.
#
#   coordinator-queue.sh seed <scope>[,<scope>…]  ADD each scope to those recorded and fill the queue
#   coordinator-queue.sh seed --replace <scope>[,…] the scopes become exactly these
#   coordinator-queue.sh drop <scope>      stop queueing one scope; its pinned entries stay
#   coordinator-queue.sh refresh           re-seed from the scopes already recorded
#   coordinator-queue.sh list              the queue in the order it runs, with each entry's scope
#   coordinator-queue.sh in-scope <n>      exit 0 when ticket n is under any recorded scope
#   coordinator-queue.sh add <n> [--class repair|approved-merge|new] [--note TEXT]
#   coordinator-queue.sh remove <n>
#
# A scope resolves the way /agent-harness:work resolves one: a bare number is
# that ticket; a label that exists is that label; otherwise `project:<scope>`.
# A comma list is the union of its scopes. If any one resolves to no label the
# whole seed is refused, naming it, never widened. Seeding adds: two sessions
# working two areas both land in the one queue, and neither empties the other's.
#
# The candidates and their order come from claimable-issues.sh, the one
# definition of what may be picked up. A [FINISH PR] row is class repair;
# everything else is new. An entry put there with `add` is pinned: it and every
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

label_exists() { # <name>
  swarm_gh label list --repo "$REPO_SLUG" --search "$1" --limit 100 --json name \
    -q '.[].name' 2>/dev/null | grep -qxF -- "$1"
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

recorded_scopes() { current | jq -r '.scope // empty'; }

seed() { # [--replace] <scope>[,<scope>…]
  local replace=0
  [ "${1:-}" = --replace ] && { replace=1; shift; }
  local scope="${1:?seed needs a scope}" s label labels="" members="" m claimable rows
  [ -n "$(scope_list "$scope")" ] || die "'$scope' names no scope — nothing seeded"
  # Add to what is recorded, unless told to replace it.
  [ "$replace" = 1 ] || scope=$(scope_list "$(recorded_scopes),$scope" | paste -sd, -)
  [ -n "$(scope_list "$scope")" ] || die "'$scope' names no scope — nothing seeded"
  while IFS= read -r s; do
    label=$(resolve "$s") || die "'$s' is neither a ticket number, a label, nor ${SWARM_PROGRAMME_PREFIX}$s — nothing seeded"
    labels="$labels$label"$'\n'
  done <<< "$(scope_list "$scope")"
  labels=$(printf '%s' "$labels" | awk 'NF && !seen[$0]++')
  while IFS= read -r label; do
    case "$label" in
      "ticket "*) m="${label#ticket }" ;;
      *) m=$(swarm_gh issue list --repo "$REPO_SLUG" --state open --label "$label" --limit 1000 \
               --json number -q '.[].number' 2>/dev/null) || die "could not list $label — queue left as it was" ;;
    esac
    # <n>\t<label>: the first scope a ticket falls under is the one it is listed under.
    members="$members$(printf '%s\n' "$m" | awk -v l="$label" 'NF{print $1 "\t" l}')"$'\n'
  done <<< "$labels"
  members=$(printf '%s' "$members" | awk -F'\t' 'NF && !seen[$1]++')
  claimable=$(bash "$CLAIMABLE" 2>/dev/null) || die "claimable-issues.sh failed — queue left as it was"
  rows=$(printf '%s\n' "$claimable" | awk -F'\t' 'NF>=1 && $1!=""{print $1 "\t" ($5=="[FINISH PR]" ? "repair" : "new")}' \
         | while IFS=$'\t' read -r n cls; do
             l=$(awk -F'\t' -v n="$n" '$1==n{print $2; exit}' <<<"$members")
             [ -n "$l" ] && printf '%s\t%s\t%s\n' "$n" "$cls" "$l"
           done)
  current | jq --arg scope "$scope" --arg labels "$labels" --arg at "$(swarm_stamp)" --arg rows "$rows" '
    (.tickets // []) as $old
    | ($labels | split("\n") | map(select(length > 0))) as $ls
    | ($old | map({key: (.n|tostring), value: .}) | from_entries) as $byn
    | ($rows | split("\n") | map(select(length > 0) | split("\t") | {n: (.[0]|tonumber), class: .[1], scope: .[2]})) as $fresh
    | ($fresh | map(($byn[(.n|tostring)] // {}) as $o
                     | . + {note: ($o.note // "")}
                     | if $o.pinned then .class = $o.class | .pinned = true else . end)) as $merged
    | ($old | map(select(.pinned) | select((.n) as $n | ($fresh | map(.n) | index($n)) == null))) as $kept
    | {scope: $scope, label: ($ls | join(", ")), labels: $ls, seeded_at: $at, tickets: ($merged + $kept)}' | write
  echo "seeded $(jq '.tickets | length' "$COORD_QUEUE") ticket(s) for $(jq -r '.label' "$COORD_QUEUE")"
}

drop() { # <scope> — the rest stay recorded; pinned entries stay queued
  local gone="${1:?drop needs a scope}" keep
  local s gl; gl=$(resolve "$gone" 2>/dev/null || printf '%s' "$gone")
  # A scope is dropped whether it is named as typed ("pulse") or as its label.
  keep=$(scope_list "$(recorded_scopes)" | while IFS= read -r s; do
           [ "$s" = "$gone" ] || [ "$(resolve "$s" 2>/dev/null)" = "$gl" ] || printf '%s\n' "$s"
         done | paste -sd, -)
  [ "$keep" != "$(recorded_scopes)" ] || die "'$gone' is not a recorded scope (recorded: $(recorded_scopes))"
  if [ -z "$keep" ]; then
    current | jq '.scope = null | .label = null | .labels = [] | .tickets = ((.tickets // []) | map(select(.pinned)))' | write
    echo "dropped $gone — no scope left; pinned entries kept"; return 0
  fi
  seed --replace "$keep"
}

refresh() {
  local scope; scope=$(current | jq -r '.scope // empty')
  [ -n "$scope" ] || die "no scope recorded — run 'seed <scope>' first"
  seed --replace "$scope"
}

# A queue seeded before scopes were lists holds one label in .label and no .labels.
scope_labels() { current | jq -r 'if (.labels | type) == "array" then .labels[] else (.label // empty) end'; }

in_scope() { # <n> — 0 under any scope, 1 outside every one, 2 unreadable
  case "${1:-}" in ''|*[!0-9]*) die "in-scope needs a ticket number" ;; esac
  local ls have l
  ls=$(scope_labels); [ -n "$ls" ] || die "no scope recorded — run 'seed <scope>' first"
  grep -qxF "ticket $1" <<<"$ls" && return 0
  have=$(swarm_gh issue view "$1" --repo "$REPO_SLUG" --json labels -q '.labels[].name' 2>/dev/null) \
    || { echo "coordinator-queue: #$1 could not be read" >&2; return 2; }
  while IFS= read -r l; do
    [ -n "$l" ] && grep -qxF -- "$l" <<<"$have" && return 0
  done <<< "$ls"
  return 1
}

add() {
  local n="" cls=new note=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --class) cls="${2:?--class needs a value}"; shift 2 ;;
      --note)  note="${2:-}"; shift 2 ;;
      -*)      die "unknown flag $1" ;;
      *)       n="$1"; shift ;;
    esac
  done
  case "$n" in ''|*[!0-9]*) die "add needs a ticket number" ;; esac
  case "$cls" in repair|approved-merge|new) ;; *) die "class must be repair, approved-merge or new" ;; esac
  current | jq --argjson n "$n" --arg c "$cls" --arg note "$note" '
    .tickets = ((.tickets // []) | map(select(.n != $n))) + [{n: $n, class: $c, note: $note, pinned: true}]' | write
  echo "queued #$n as $cls"
}

remove() {
  case "${1:-}" in ''|*[!0-9]*) die "remove needs a ticket number" ;; esac
  current | jq --argjson n "$1" '.tickets = ((.tickets // []) | map(select(.n != $n)))' | write
  echo "removed #$1"
}

list() {
  local n=0 t c sc note
  echo "scopes: $(current | jq -r '.label // "none"')"
  # The run order of coord_queue_ordered, plus each entry's scope. A pinned entry
  # put there by hand carries none and is shown as pinned.
  while IFS=$'\t' read -r t c sc note; do
    [ -n "${t:-}" ] || continue
    n=$((n+1)); printf '%2d. #%-7s %-15s %-24s %s\n' "$n" "$t" "$c" "$sc" "$note"
  done <<< "$( [ -s "$COORD_QUEUE" ] && jq -r '.tickets | to_entries
         | map(.value + {pos: .key, rank: ({"repair":0,"approved-merge":1,"new":2}[.value.class] // 3)})
         | sort_by(.rank, .pos) | .[]
         | [(.n|tostring), .class, (.scope // (if .pinned then "pinned" else "" end) | if . == "" then "-" else . end), (.note // "")] | @tsv' "$COORD_QUEUE" 2>/dev/null)"
  [ "$n" -gt 0 ] || echo "the queue is empty"
}

case "${1:-}" in
  seed)    shift; seed "$@" ;;
  drop)    shift; drop "$@" ;;
  refresh) refresh ;;
  in-scope) shift; in_scope "$@" ;;
  add)     shift; add "$@" ;;
  remove)  shift; remove "$@" ;;
  list)    list ;;
  -h|--help|"") sed -n '2,25p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' ;;
  *)       die "unknown command '$1'" ;;
esac
