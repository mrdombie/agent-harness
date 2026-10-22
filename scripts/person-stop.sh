#!/usr/bin/env bash
# person-stop.sh — has a person stopped this ticket or pull request? A person's stop
# wins over the machine: no driver re-check, review or ship lands work a person held.
#
#   person-stop.sh check <ticket> [<pr>] [--since <iso>]
#       0  nothing stops it
#       1  stopped: one sentence per stop on stdout, each naming who, when and what
#       2  could not be read: the caller holds, as for a stop
#
# THREE STOPS, and mergeFirst relaxes none of them:
#   do-not-merge   the PR carries labels.doNotMerge ("do-not-merge").
#   draft          the PR is a draft and the last convert_to_draft on its timeline was
#                  a person's. Nothing in the harness converts a PR to draft (the driver
#                  opens its drafts as drafts), so a conversion by a person's login is
#                  a person saying "not yet". A bot (type Bot, or a login ending [bot])
#                  and the logins in driver.accounts are the machine.
#   a Critical     a comment by a person on the ticket or the PR, or a review on the PR,
#                  newer than the driver's last hand-off (or --since), that names a
#                  Critical — the grade word, not a count of none ("0 Critical",
#                  "Critical: 0") or the list of grades ("Critical, Major and Minor") —
#                  or is a PM answer/review that says it blocks the merge. It stays open
#                  until a later comment by a person clears it: a "## PM answer" that
#                  names no stop of its own, or one that begins "Cleared:".
#
# A PERSON is told from the machine the way approval-kept.sh does it (a user that is not
# a bot), and a comment is the machine's when it carries the marker gh_call adds to every
# comment the harness posts, or opens the way the driver's comments open. The driver and
# the PM can share one token, so the login alone cannot tell them apart.
#
# 22 Oct: a PM named a Critical (a same-name colleague key: erasing one member deletes
# another's facts) and put the PR back to draft; a driver re-check readied it and it
# merged with the Critical in it.
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SELF_DIR/toolkit-env.sh" || exit 2
. "$SELF_DIR/gh-batch.sh" || exit 2
REPO="${GH_REPO:-$REPO_SLUG}"

usage() { sed -n '5,9p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }

# The machine marker gh_call puts in the comments the harness posts.
PERSON_STOP_MARK='<!-- harness:machine -->'

# jq definitions every read shares.
PS_JQ='
  def human: (.type // "User") != "Bot" and ((.login // "") | endswith("[bot]") | not)
             and ((.login // "") as $l | ($drivers | index($l)) == null);
  def machine_body: (. // "") as $b
    | ($b | contains($mark))
      or ($b | test("^\\s*(\\*\\*Parked|\\*\\*Plan\\*\\*|\\*\\*Waiting on the owner\\*\\*|\\*\\*The owner answered\\*\\*|\\*\\*Claim released|\\*\\*Shipped\\.\\*\\*|Re-checked by the driver|Repaired by the driver|Handed off at|Kept fresh:|Merge lane:|Set to merge into|Unblocked:|Blocked until)"));
  def handoff: (. // "") | test("^\\s*(Handed off at|Re-checked by the driver|Repaired by the driver)");
  def crit_line:
    test("(?<![/\\w])Critical(?![/\\w])")
    and (test("(?i)\\b(0|no|zero|none|any)\\s+\\**Critical") | not)
    and (test("Critical\\**\\s*[:=]\\s*\\**\\s*(0|none)\\b"; "i") | not)
    and (test("Critical\\**\\s*(,|/|or|and)\\s*\\**(Major|Minor|Nit)") | not)
    and (test("(Major|Minor|Nit)\\**\\s*(,|/|or|and)\\s*\\**Critical") | not);
  def pm_marker: test("(?m)^\\s*#*\\s*\\**PM (answer|review)");
  def blocks_line: test("(?i)\\b(must not merge|do not merge|must be fixed|blocks? (the )?merge|blocking finding)");
  def stop_line: (. // "") as $b
    | ([$b | split("\n")[] | select(crit_line)] | first)
      // (if ($b | pm_marker) then ([$b | split("\n")[] | select(blocks_line)] | first) else null end);
  def clears: (. // "") | (test("(?m)^\\s*#*\\s*PM answer") or test("^\\s*Cleared:")) and (stop_line == null);
'

ps_read() { # <endpoint> — every page as one array, or exit 1
  local out
  out=$(gh_call api --paginate "$1" 2>/dev/null) || return 1
  printf '%s' "$out" | jq -cs 'if all(.[]; type == "array") then add // [] else error("not a list") end' 2>/dev/null
}

check() {
  local t="" pr="" since=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --since) since="${2:-}"; shift 2 ;;
      -*) usage ;;
      *) if [ -z "$t" ]; then t="$1"; elif [ -z "$pr" ]; then pr="$1"; else usage; fi; shift ;;
    esac
  done
  case "$t" in ''|*[!0-9]*) usage ;; esac
  case "$pr" in *[!0-9]*) usage ;; esac
  local dnm drivers tc="[]" pc="[]" rv="[]" tl="[]" pj="{}"
  dnm="${LBL_DO_NOT_MERGE:-do-not-merge}"
  drivers=$(jq -c '.driver.accounts // [] | if type == "array" then map(tostring) else [] end' "$HARNESS_CFG" 2>/dev/null) || drivers='[]'
  tc=$(ps_read "repos/$REPO/issues/$t/comments?per_page=100") || { echo "could not read the comments on #$t"; return 2; }
  if [ -n "$pr" ]; then
    pj=$(gh_call api "repos/$REPO/pulls/$pr" 2>/dev/null) && jq -e '.number' >/dev/null 2>&1 <<<"$pj" \
      || { echo "could not read pull request #$pr"; return 2; }
    pc=$(ps_read "repos/$REPO/issues/$pr/comments?per_page=100") || { echo "could not read the comments on #$pr"; return 2; }
    rv=$(ps_read "repos/$REPO/pulls/$pr/reviews?per_page=100") || { echo "could not read the reviews on #$pr"; return 2; }
    tl=$(ps_read "repos/$REPO/issues/$pr/timeline?per_page=100") || { echo "could not read the timeline of #$pr"; return 2; }
  fi
  local f; f=$(mktemp "${TMPDIR:-/tmp}/person-stop.XXXXXX") || return 2
  jq -n --argjson tc "$tc" --argjson pc "$pc" --argjson rv "$rv" --argjson tl "$tl" --argjson pj "$pj" \
    '{tc: $tc, pc: $pc, rv: $rv, tl: $tl, pj: $pj}' > "$f" 2>/dev/null || { rm -f "$f"; echo "could not read what GitHub answered"; return 2; }
  local out rc=0
  out=$(jq -r --arg t "$t" --arg pr "$pr" --arg since "$since" --arg dnm "$dnm" --arg mark "$PERSON_STOP_MARK" \
          --argjson drivers "$drivers" "$PS_JQ"'
    def day: (. // "") | .[0:10];
    def oneline: gsub("[\\r\\n]+"; " ") | gsub("\\s+"; " ") | gsub("^ | $"; "") | .[0:240];
    ( [ (.tc[] | {at: .created_at, user: .user, body: (.body // ""), where: "#\($t)"}),
        (.pc[] | {at: .created_at, user: .user, body: (.body // ""), where: "PR #\($pr)"}),
        (.rv[] | select((.body // "") != "") | {at: (.submitted_at // ""), user: .user, body: .body, where: "a review on PR #\($pr)"}) ]
      | sort_by(.at) ) as $all
    | [ $all[] | select((.user | human) and (.body | machine_body | not)) ] as $people
    | (if $since != "" then $since
       else ([ $all[] | select(.body | handoff) | .at ] | max // "") end) as $cut
    | [
        ( if $pr != "" and any(.pj.labels[]?; .name == $dnm)
          then "PR #\($pr) carries the `\($dnm)` label: nothing merges it, and no run readies or arms it, until a person takes the label off." else empty end ),
        ( if $pr != "" and (.pj.draft == true) then
            ([ .tl[] | select(.event == "convert_to_draft") ] | last) as $c
            | if $c != null and ($c.actor | human) then
                ([ $people[] | select(.at >= $c.created_at) ] | first // ([ $people[] | select(.at <= $c.created_at) ] | last)) as $why
                | "a person (\($c.actor.login)) put this back to draft on \($c.created_at | day): \(($why.body // "no comment") | oneline)"
              else empty end
          else empty end ),
        ( [ $people[] | select(.at > $cut) ] as $new
          | range(0; $new | length) as $i | $new[$i] as $c
          | ($c.body | stop_line) as $line
          | select($line != null)
          | select(([ $new[$i + 1:][] | select(.body | clears) ] | length) == 0)
          | "\($c.user.login) named a blocking finding on \($c.where) on \($c.at | day): \($line | oneline)" )
      ] | .[]' "$f" 2>/dev/null) || rc=$?
  rm -f "$f"
  [ "$rc" -eq 0 ] || { echo "could not read the comments and the timeline as JSON"; return 2; }
  [ -n "$out" ] || return 0
  printf '%s\n' "$out"
  return 1
}

case "${1:-}" in
  check) shift; check "$@" ;;
  *) usage ;;
esac
