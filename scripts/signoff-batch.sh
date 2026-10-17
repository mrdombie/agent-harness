#!/usr/bin/env bash
# signoff-batch.sh — which held pixel PRs are ready for the owner, and the owner's
# sign-off batches made from them. Reads `gh pr list --json
# number,headRefOid,isDraft,labels,mergeStateStatus,statusCheckRollup` on stdin.
#
#   signoff-batch.sh green              <pr> \t <sha7>, lowest number first
#   signoff-batch.sh batches <done>     <key> \t <pr> <pr> …  one row per FULL batch
#                                       of PRs whose pr:<n>:<sha7> is not in <done>
#
# Ready = green apart from the hold AND every reviewer's verdict on its head.
#
# Green apart from the hold: carries the hold label, not a draft, not clashing, and
# every gates.requiredChecks entry green on its newest run. With no required checks
# configured: every check settled and nothing failed but the hold's own gate
# (a check named like coordinator.holdCheck, default "approval") — that gate is red
# BY the hold, so counting it put no held PR in front of the owner, ever.
#
# Verdicts on the head: one record-verdict trailer per review.attest row —
# `<trailer>: SHIP (<who>) <fingerprint>` in an empty single-parent commit, the
# shape a project's recorder writes (the row's `trailer`, else its name; the key is
# matched without case) — found walking back from the head through what changes
# nothing a reviewer judged: an empty commit, a CI evidence commit (subject
# starting evidence.commitPrefix, default "chore(evidence):"), and a merge that
# only brings the trunk in (approval-kept.sh check from its first parent keeps an
# approval across it). The first other commit ends the walk: a verdict below it is
# about code nobody reviewed. The owner signs last (owner's rule, 2026-10-17): a PR
# sent before its reviews came back was changed under the sign-off, so it is not
# sent. With no review.attest rows there is no verdict to wait for. One batched
# read (gh_pr_commits_batch), made only when a full batch could form; a read that
# fails counts no PR.
#
# Batch size: coordinator.signoffBatch (COORDINATOR_SIGNOFF_BATCH), default 5.
# The key names its members, so the same set is the same key in every caller.
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../swarm" && pwd)/swarm-env.sh" || exit 1

BATCH="${COORDINATOR_SIGNOFF_BATCH:-$(swarm_opt coordinator.signoffBatch 5)}"
HOLD_CHECK="${COORDINATOR_HOLD_CHECK:-$(swarm_opt coordinator.holdCheck approval)}"
REQUIRED=$(jq -c '.gates.requiredChecks // empty | select(type == "array" and length > 0)' "${HARNESS_CFG:-/dev/null}" 2>/dev/null)
[ -n "$REQUIRED" ] || REQUIRED=null
VERDICTS=$(jq -c '[(.review.attest // {}) | objects | to_entries[]
                   | ((if (.value | type) == "object" then .value.trailer else null end) // .key) | ascii_downcase] | unique' \
           "${HARNESS_CFG:-/dev/null}" 2>/dev/null)
[ -n "$VERDICTS" ] || VERDICTS='[]'
EV_PREFIX=$(jq -r '.evidence.commitPrefix // empty' "${HARNESS_CFG:-/dev/null}" 2>/dev/null)
[ -n "$EV_PREFIX" ] || EV_PREFIX="chore(evidence):"
KEPT="${SIGNOFF_APPROVAL_KEPT:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/approval-kept.sh}"
case "$BATCH" in ''|*[!0-9]*|0) echo "signoff-batch: batch size '$BATCH' is not a positive number" >&2; exit 2 ;; esac

held_green() { # <pr> \t <sha7> \t <sha>
  jq -r --arg hold "$HOLD_LABEL" --arg gate "$HOLD_CHECK" --argjson req "$REQUIRED" '
    def settled: ((.status // "COMPLETED") == "COMPLETED") and (((.state // "") | test("PENDING|EXPECTED")) | not);
    def ok: (.conclusion // .state // "") | test("^(SUCCESS|NEUTRAL|SKIPPED)$");
    def named($r): .name == $r or .context == $r or (((.workflowName // "") + " / " + (.name // "")) == $r);
    [ .[] | select(.isDraft | not) | select(any(.labels[]?; .name == $hold))
      | select(.mergeStateStatus != "DIRTY")
      | (.statusCheckRollup // []) as $c
      | select(
          if $req != null then
            all($req[]; . as $r | ([ $c[] | select(named($r)) ] | last) as $x | $x != null and ($x | settled) and ($x | ok))
          else
            ($c | length) > 0 and all($c[]; settled)
            and all($c[]; ok or (((.name // .context // "") | ascii_downcase) | contains($gate | ascii_downcase)))
          end)
      | {n: .number, sha: (.headRefOid // "")} ]
    | sort_by(.n) | .[] | "\(.n)\t\(.sha[0:7])\t\(.sha)"'
}

# walk <pr-json> <clean-merges-json> — from the head down: "" when every verdict is
# there, "ask <merge> <first-parent>" when the walk reaches a merge not yet judged,
# else why the PR is not counted.
WALK_JQ='
  def carry($clean): (.parents == 1 and (.files == 0 or (.message | startswith($pre))))
                     or (.parents > 1 and (.oid as $o | $clean | index($o)));
  def verdicts: if .parents == 1 and .files == 0 then
      [ .message | split("\n")[] | capture("^(?<k>[A-Za-z0-9][A-Za-z0-9-]*):[ \t]*SHIP \\([^)]+\\) [0-9a-f]{6,}[ \t]*$")? | .k | ascii_downcase ]
    else [] end;
  . as $p
  | if $p == null then "its commits could not be read"
    elif ($p.commits | length) == 0 or ($p.commits | last | .oid) != $sha then "its head moved since the list was read"
    else
      (reduce ($p.commits | reverse)[] as $c ({stop: null, found: []};
         if .stop != null then . else .found += ($c | verdicts)
           | if ($c | carry($clean)) then . else .stop = $c end end)) as $w
      | ($keys - $w.found) as $missing
      | if ($missing | length) == 0 then ""
        elif $w.stop != null and $w.stop.parents > 1 and ($dirty | index($w.stop.oid) | not)
          then "ask \($w.stop.oid) \($w.stop.parentOids[0] // "")"
        else "no \($missing | join(" or ")) verdict on its head" end
    end'

on_head() { # rows of held_green on stdin; those whose verdicts are on the head
  local rows data
  rows=$(cat); [ -n "$rows" ] || return 0
  if [ "$VERDICTS" = '[]' ]; then printf '%s\n' "$rows"; return 0; fi
  # shellcheck disable=SC2046
  data=$(gh_pr_commits_batch $(printf '%s\n' "$rows" | cut -f1)) || data=""
  jq -e 'type == "object" and length > 0' >/dev/null 2>&1 <<<"$data" \
    || { echo "signoff-batch: the held PRs' commits could not be read — none counted" >&2; return 0; }
  printf '%s\n' "$rows" | while IFS=$'\t' read -r n s7 sha; do
    clean='[]'; dirty='[]'
    while :; do
      why=$(jq -r --arg n "$n" --arg sha "$sha" --argjson keys "$VERDICTS" --arg pre "$EV_PREFIX" \
              --argjson clean "$clean" --argjson dirty "$dirty" ".[\$n] | $WALK_JQ" <<<"$data" 2>/dev/null) \
        || { why="its commits could not be judged"; break; }
      case "$why" in
        "ask "*)
          set -- $why
          if [ -n "${3:-}" ] && bash "$KEPT" check "$3" "$2" >/dev/null 2>&1; then
            clean=$(jq -c --arg o "$2" '. + [$o]' <<<"$clean")
          else dirty=$(jq -c --arg o "$2" '. + [$o]' <<<"$dirty"); fi ;;
        *) break ;;
      esac
    done
    if [ -z "$why" ]; then printf '%s\t%s\t%s\n' "$n" "$s7" "$sha"
    else echo "signoff-batch: #$n is green apart from the hold, not counted: $why" >&2; fi
  done
}

case "${1:-}" in
  green) held_green | on_head | cut -f1,2 ;;
  batches)
    DONE="${2:?usage: signoff-batch.sh batches <done-file>}"
    [ -f "$DONE" ] || : > "$DONE"
    left=$(held_green | while IFS=$'\t' read -r n s7 sha; do
      grep -qxF "pr:$n:$s7" "$DONE" || printf '%s\t%s\t%s\n' "$n" "$s7" "$sha"
    done)
    # The verdict read is spent only when a full batch could form.
    [ "$(printf '%s' "$left" | grep -c .)" -ge "$BATCH" ] || exit 0
    printf '%s\n' "$left" | on_head | awk -F'\t' -v size="$BATCH" '
      { m[++k] = $1 "@" $2 }
      END {
        for (i = 1; i + size - 1 <= k; i += size) {
          key = "signoff-batch:"; prs = ""
          for (j = i; j < i + size; j++) { key = key (j > i ? "," : "") m[j]; split(m[j], p, "@"); prs = prs (j > i ? " " : "") p[1] }
          print key "\t" prs
        }
      }' ;;
  *) echo "usage: signoff-batch.sh green | batches <done-file>   (gh pr list JSON on stdin)" >&2; exit 2 ;;
esac
