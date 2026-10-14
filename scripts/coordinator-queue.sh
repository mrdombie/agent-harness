#!/usr/bin/env bash
# coordinator-queue.sh — the coordinator's queue: one JSON file in the state dir,
# in place of a hand-written markdown list.
#
#   coordinator-queue.sh seed <scope>      resolve the scope and fill the queue
#   coordinator-queue.sh refresh           re-seed from the scope already recorded
#   coordinator-queue.sh list              the queue in the order it runs
#   coordinator-queue.sh add <n> [--class repair|approved-merge|new] [--note TEXT]
#   coordinator-queue.sh remove <n>
#
# A scope resolves the way /agent-harness:work resolves one: a bare number is
# that ticket; a label that exists is that label; otherwise `project:<scope>`.
# A scope that resolves to no label is refused, never widened.
#
# The candidates and their order come from claimable-issues.sh, the one
# definition of what may be picked up. A [FINISH PR] row is class repair;
# everything else is new. An approved-merge entry and every note are kept
# across a re-seed, because nothing on the forge can rebuild them.
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

seed() { # <scope>
  local scope="${1:?seed needs a scope}" label members claimable rows
  label=$(resolve "$scope") || die "'$scope' is neither a ticket number, a label, nor ${SWARM_PROGRAMME_PREFIX}$scope — nothing seeded"
  case "$label" in
    "ticket "*) members="${label#ticket }" ;;
    *) members=$(swarm_gh issue list --repo "$REPO_SLUG" --state open --label "$label" --limit 1000 \
                   --json number -q '.[].number' 2>/dev/null | sort -u) ;;
  esac
  claimable=$(bash "$CLAIMABLE" 2>/dev/null)
  rows=$(printf '%s\n' "$claimable" | awk -F'\t' 'NF>=1 && $1!=""{print $1 "\t" ($5=="[FINISH PR]" ? "repair" : "new")}' \
         | while IFS=$'\t' read -r n cls; do
             grep -qx "$n" <<<"$members" && printf '%s\t%s\n' "$n" "$cls"
           done)
  current | jq --arg scope "$scope" --arg label "$label" --arg at "$(swarm_stamp)" --arg rows "$rows" '
    (.tickets // []) as $old
    | ($old | map({key: (.n|tostring), value: .}) | from_entries) as $byn
    | ($rows | split("\n") | map(select(length > 0) | split("\t") | {n: (.[0]|tonumber), class: .[1]})) as $fresh
    | ($fresh | map(. + {note: ($byn[(.n|tostring)].note // "")}
                     | if $byn[(.n|tostring)].class == "approved-merge" then .class = "approved-merge" else . end)) as $merged
    | ($old | map(select(.class == "approved-merge") | select((.n) as $n | ($fresh | map(.n) | index($n)) == null))) as $kept
    | {scope: $scope, label: $label, seeded_at: $at, tickets: ($merged + $kept)}' | write
  echo "seeded $(jq '.tickets | length' "$COORD_QUEUE") ticket(s) for $label"
}

refresh() {
  local scope; scope=$(current | jq -r '.scope // empty')
  [ -n "$scope" ] || die "no scope recorded — run 'seed <scope>' first"
  seed "$scope"
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
    .tickets = ((.tickets // []) | map(select(.n != $n))) + [{n: $n, class: $c, note: $note}]' | write
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
  add)     shift; add "$@" ;;
  remove)  shift; remove "$@" ;;
  list)    list ;;
  -h|--help|"") sed -n '2,19p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' ;;
  *)       die "unknown command '$1'" ;;
esac
