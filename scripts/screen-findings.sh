#!/usr/bin/env bash
# screen-findings.sh — what is already known to be wrong with the screens a change touches.
#
#   screen-findings.sh screens <ticket> [<file-list>]   the screen slugs: the ticket's
#                                                       <labels.screenPrefix><slug> labels, plus
#                                                       design.screenOf run over the files
#   screen-findings.sh polish <ticket> [<file-list>]    every free item on those screens' polish
#                                                       lists: grade \t list \t item; a list that ships
#                                                       alone (polish-list.sh lends) lends none
#   screen-findings.sh critic <pr>                      the graded findings of the independent
#                                                       critic's latest verdict on the PR, from
#                                                       its own record, when it did not pass:
#                                                       grade \t PR \t finding
#
# FIX WHAT YOU TOUCH (the owner, 2026-10-20). A change that touches a screen takes on
# what is already known to be wrong with it: its polish list and the critic's open
# findings. On one PR an earlier critic flagged narration on the screen, the builder
# left it because it had not added it, and the next critic failed the screen for it.
# Critical, Major and Minor block, and a Minor is fixed in the change; only a Nit drops.
#
# A grade is read off the item's own start — "[Major] …", "Major: …", "Major · …" — and
# an item that names none is a Minor: polish is what the lists were opened for. A
# critic's scope after the grade ("changed · …") is dropped. A line that says there is
# nothing — "none", "0", "gone", or a finding closed with "— gone" / "(fixed)" — is no
# finding: read as live, one blocked a clean screen.
#
# design.screenOf (harness.json) is a command that reads paths on stdin and prints the
# screen slug of each it knows, one a line. Absent, only the ticket's labels say which
# screens it touches.
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../swarm" && pwd)/swarm-env.sh" || exit 2
PL="${SCREEN_FINDINGS_POLISH:-$(dirname "${BASH_SOURCE[0]}")/polish-list.sh}"

die() { echo "screen-findings: $*" >&2; exit 2; }
RESOLVED='^[[:space:]]*[-*]?[[:space:]]*\(?(none|nothing|n/?a|0|zero|gone|resolved|fixed|no (issues?|findings?))\)?[[:space:]]*[.!]?[[:space:]]*$|(—|–|:|\(|-)[[:space:]]*(now[[:space:]]+)?(gone|resolved|fixed)[[:space:]]*\)?[[:space:]]*[.!]?[[:space:]]*$'
resolved() { local t; t=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]'); grep -qE "$RESOLVED" <<<"$t"; } # <text without its grade>

# grade_of <text> → "critical|major|minor \t text without the grade"
grade_of() {
  printf '%s\n' "$1" | awk '{
    s = $0; g = "minor"
    if (match(tolower(s), /^[[:space:]*]*\[?(critical|major|minor|nit)\]?[^a-z0-9]+/)) {
      w = tolower(substr(s, RSTART, RLENGTH)); gsub(/[^a-z]/, "", w); g = w; s = substr(s, RSTART + RLENGTH)
    }
    printf "%s\t%s\n", g, s
  }'
}

screens() { # <ticket> [<file-list>]
  local t="$1" files="${2:-}" cmd
  swarm_gh issue view "$t" --repo "$REPO_SLUG" --json labels -q '.labels[].name' 2>/dev/null \
    | while IFS= read -r l; do
        [ -n "$LBL_SCREEN_PREFIX" ] || continue
        case "$l" in "$LBL_SCREEN_PREFIX"?*) printf '%s\n' "${l#"$LBL_SCREEN_PREFIX"}" ;; esac
      done
  cmd=$(swarm_opt design.screenOf "")
  if [ -n "$cmd" ] && [ -n "$files" ] && [ -f "$files" ]; then
    ( cd "${MAIN_REPO:-.}" 2>/dev/null; sh -c "$cmd" < "$files" ) 2>/dev/null | grep -E '^[a-z0-9-]+$'
  fi
}

case "${1:-}" in
  screens)
    [ -n "${2:-}" ] || die "usage: screens <ticket> [<file-list>]"
    screens "$2" "${3:-}" | awk 'NF && !seen[$0]++' ;;
  polish)
    [ -n "${2:-}" ] || die "usage: polish <ticket> [<file-list>]"
    slugs=$(screens "$2" "${3:-}" | awk 'NF && !seen[$0]++')
    while IFS= read -r slug; do
      [ -n "$slug" ] || continue
      n=$(bash "$PL" for-screen "$slug" 2>/dev/null) || { echo "screen-findings: the polish list for $slug could not be read" >&2; exit 2; }
      [ -n "$n" ] || continue
      # A list that ships alone lends none (polish-list.sh lends): only to itself.
      bash "$PL" lends "$n" "$2" >/dev/null 2>&1; rc=$?
      [ "$rc" -eq 1 ] && continue
      [ "$rc" -eq 0 ] || { echo "screen-findings: polish list #$n could not be read" >&2; exit 2; }
      items=$(bash "$PL" items "$n" 2>/dev/null) || { echo "screen-findings: polish list #$n could not be read" >&2; exit 2; }
      while IFS= read -r it; do
        [ -n "$it" ] || continue
        g=$(grade_of "$it")
        resolved "${g#*$'\t'}" && continue
        printf '%s\t%s\t%s\n' "${g%%$'\t'*}" "$n" "$it"
      done <<<"$items"
    done <<<"$slugs" | awk -F'\t' '$1 != "nit" && !seen[$2 FS $3]++' ;;
  critic)
    [ -n "${2:-}" ] || die "usage: critic <pr>"
    # From the judge's own record on this machine, never from a PR comment: a comment
    # can be written by anyone on the token. Present only while its latest verdict failed.
    f="${CRITIC_JUDGE_DIR:-$STATE_DIR/swarm/critic-judge}/findings-$2.txt"
    [ -f "$f" ] || exit 0
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      g=$(grade_of "$line"); txt="${g#*$'\t'}"; txt="${txt#changed · }"
      resolved "$txt" && continue
      [ "${g%%$'\t'*}" = nit ] || printf '%s\t#%s\t%s\n' "${g%%$'\t'*}" "$2" "$txt"
    done < "$f" ;;
  *) die "usage: screen-findings.sh screens|polish|critic …" ;;
esac
