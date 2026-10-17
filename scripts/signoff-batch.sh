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
# Verdicts on the head: one `<trailer>: SHIP…` commit trailer per review.attest row
# (the row's `trailer`, else its name; the key is matched without case), found
# walking back from the head through commits that change nothing — an empty trailer
# commit, or the evidence commit the PR body names (evidence.headMarker) — and the
# first commit that does change something. A verdict below a later change is about
# code nobody reviewed. The owner signs last (owner's rule, 2026-10-17): a PR sent
# before its reviews came back was changed under the sign-off, so it is not sent.
# With no review.attest rows there is no verdict to wait for. One batched read
# (gh_pr_commits_batch), made only when a full batch could form; a read that fails
# counts no PR.
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
EV_MARK=$(jq -r '.evidence.headMarker // empty' "${HARNESS_CFG:-/dev/null}" 2>/dev/null)
[ -n "$EV_MARK" ] || EV_MARK="ci-evidence-head:"
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

on_head() { # rows of held_green on stdin; those whose verdicts are on the head
  local rows data
  rows=$(cat); [ -n "$rows" ] || return 0
  if [ "$VERDICTS" = '[]' ]; then printf '%s\n' "$rows"; return 0; fi
  # shellcheck disable=SC2046
  data=$(gh_pr_commits_batch $(printf '%s\n' "$rows" | cut -f1)) || data=""
  jq -e 'type == "object" and length > 0' >/dev/null 2>&1 <<<"$data" \
    || { echo "signoff-batch: the held PRs' commits could not be read — none counted" >&2; return 0; }
  printf '%s\n' "$rows" | while IFS=$'\t' read -r n s7 sha; do
    why=$(jq -rn --argjson d "$data" --arg n "$n" --arg sha "$sha" --argjson keys "$VERDICTS" --arg mark "$EV_MARK" '
      def carry($ev): .parents == 1 and (.files == 0 or .oid == $ev);
      $d[$n] as $p
      | if $p == null then "its commits could not be read"
        elif ($p.commits | length) == 0 or ($p.commits | last | .oid) != $sha then "its head moved since the list was read"
        else
          ([$p.body | split($mark) | .[1:][] | capture("^(?<s>[0-9a-f]{7,40})")? | .s] | last // "") as $ev
          | (reduce ($p.commits | reverse)[] as $c ({stop: false, msgs: []};
               if .stop then . else .msgs += [$c.message] | .stop = (($c | carry($ev)) | not) end) | .msgs) as $msgs
          | [ $msgs[] | split("\n")[] | capture("^(?<k>[A-Za-z0-9][A-Za-z0-9-]*):[ \t]*(?<v>.*)$")?
              | select(.v | test("^SHIP\\b"; "i")) | .k | ascii_downcase ] as $found
          | ($keys - $found) as $missing
          | if ($missing | length) == 0 then "" else "no \($missing | join(" or ")) verdict on its head" end
        end' 2>/dev/null) || why="its commits could not be judged"
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
