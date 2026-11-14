#!/usr/bin/env bash
# person-hold.sh — the one home for "a person acts next" on a ticket.
#
#   . scripts/person-hold.sh          (after coordinator-env.sh)
#   person_hold_labels                the labels a person puts on or takes off, one a line
#   person_hold_check <ticket>        0 free; 1 held, printing "<label> put on by <login> at <iso>";
#                                     2 its labels could not be read
#   person-hold.sh check <ticket>     the same, as a command
#
# The labels are read fresh from GitHub on every check, never from a run's ticket snapshot:
# a hold put on while a build runs must be seen at the next step boundary.
# Parked, gated and batched are not here: they are the machine's own park states, and a
# resumed run starts wearing them.
if [ -z "${REPO_SLUG:-}" ] || ! declare -F gh_read >/dev/null; then
  . "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/coordinator-env.sh" || return 1 2>/dev/null || exit 1
fi

person_hold_labels() {
  # shellcheck disable=SC2086  # DECISION_LABELS is a space-separated list
  printf '%s\n' "${LBL_BLOCKED:-}" "${LBL_NEEDS_HUMAN:-}" "${LBL_OWNER_DECISION:-}" "${LBL_PM_DECISION:-}" \
    "${LBL_EXTERNAL_BLOCKED:-}" "${HOLD_LABEL:-}" ${DECISION_LABELS:-} | awk 'NF && !seen[$0]++'
}

person_hold_check() { # <ticket>
  local t="${1:?person_hold_check: which ticket}" labs l tl who
  labs=$(gh_read "#$t's labels" issue view "$t" --repo "$REPO_SLUG" --json labels -q '[.labels[].name] | join(",")') || return 2
  while read -r l; do
    [ -n "$l" ] || continue
    case ",$labs," in *",$l,"*) ;; *) continue ;; esac
    who="someone at an unknown time"
    if tl=$(gh_read "#$t's timeline" api "repos/${ISSUE_SLUG:-$REPO_SLUG}/issues/$t/timeline?per_page=100" --paginate); then
      who=$(jq -rs --arg l "$l" '[(.[] | if type == "array" then .[] else . end) | select(.event? == "labeled" and .label.name? == $l)]
              | last | if . == null then empty else "\(.actor.login // "someone") at \(.created_at)" end' <<<"$tl" 2>/dev/null)
      [ -n "$who" ] || who="someone at an unknown time"
    fi
    printf '%s put on by %s\n' "$l" "$who"
    return 1
  done <<< "$(person_hold_labels)"
  return 0
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  set -uo pipefail
  case "${1:-}" in
    check) case "${2:-}" in ''|*[!0-9]*) echo "usage: person-hold.sh check <ticket>" >&2; exit 64 ;; esac
           person_hold_check "$2"; exit $? ;;
    *) sed -n '4,8p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 64 ;;
  esac
fi
