#!/usr/bin/env bash
# signoff-batch.sh — which held pixel PRs are green apart from the hold, and the
# owner's sign-off batches made from them. Reads `gh pr list --json
# number,headRefOid,isDraft,labels,mergeStateStatus,statusCheckRollup` on stdin.
#
#   signoff-batch.sh green              <pr> \t <sha7>, lowest number first
#   signoff-batch.sh batches <done>     <key> \t <pr> <pr> …  one row per FULL batch
#                                       of PRs whose pr:<n>:<sha7> is not in <done>
#
# Green apart from the hold: carries the hold label, not a draft, not clashing, and
# every gates.requiredChecks entry green on its newest run. With no required checks
# configured: every check settled and nothing failed but the hold's own gate
# (a check named like coordinator.holdCheck, default "approval") — that gate is red
# BY the hold, so counting it put no held PR in front of the owner, ever.
# Batch size: coordinator.signoffBatch (COORDINATOR_SIGNOFF_BATCH), default 5.
# The key names its members, so the same set is the same key in every caller.
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../swarm" && pwd)/swarm-env.sh" || exit 1

BATCH="${COORDINATOR_SIGNOFF_BATCH:-$(swarm_opt coordinator.signoffBatch 5)}"
HOLD_CHECK="${COORDINATOR_HOLD_CHECK:-$(swarm_opt coordinator.holdCheck approval)}"
REQUIRED=$(jq -c '.gates.requiredChecks // empty | select(type == "array" and length > 0)' "${HARNESS_CFG:-/dev/null}" 2>/dev/null)
[ -n "$REQUIRED" ] || REQUIRED=null
case "$BATCH" in ''|*[!0-9]*|0) echo "signoff-batch: batch size '$BATCH' is not a positive number" >&2; exit 2 ;; esac

green() {
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
      | {n: .number, sha: (.headRefOid // "" | .[0:7])} ]
    | sort_by(.n) | .[] | "\(.n)\t\(.sha)"'
}

case "${1:-}" in
  green) green ;;
  batches)
    DONE="${2:?usage: signoff-batch.sh batches <done-file>}"
    [ -f "$DONE" ] || : > "$DONE"
    green | while IFS=$'\t' read -r n sha; do
      grep -qxF "pr:$n:$sha" "$DONE" || printf '%s@%s\n' "$n" "$sha"
    done | awk -v size="$BATCH" '
      { m[++k] = $0 }
      END {
        for (i = 1; i + size - 1 <= k; i += size) {
          key = "signoff-batch:"; prs = ""
          for (j = i; j < i + size; j++) { key = key (j > i ? "," : "") m[j]; split(m[j], p, "@"); prs = prs (j > i ? " " : "") p[1] }
          print key "\t" prs
        }
      }' ;;
  *) echo "usage: signoff-batch.sh green | batches <done-file>   (gh pr list JSON on stdin)" >&2; exit 2 ;;
esac
