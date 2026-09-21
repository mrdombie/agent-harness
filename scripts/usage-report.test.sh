#!/usr/bin/env bash
# Plant tests for usage-report.sh: a fixture state dir with three runs. Exit 1 on
# any mismatch. Run: bash "$0"
set -u
S="$(cd "$(dirname "$0")" && pwd)/usage-report.sh"
D=$(mktemp -d); trap 'rm -rf "$D"' EXIT
mkdir -p "$D/runs" "$D/logs"
mk(){ # <run_id> <ticket> <started> <operator> [result-json]
  local id=$1 t=$2 st=$3 op=$4 res=${5:-}
  printf '{"run_id":"%s","ticket":"%s","started_at":"%s","budget_usd":15,"operator":"%s","log":"%s/logs/%s.log"}\n' "$id" "$t" "$st" "$op" "$D" "$id" > "$D/runs/$id.json"
  { echo '{"type":"system","subtype":"init"}'; [ -n "$res" ] && echo "$res"; } > "$D/logs/$id.log"
}
mk claim-101-a 101 2026-09-20T19:10:13Z a@mac '{"type":"result","subtype":"success","total_cost_usd":10.47,"num_turns":52,"is_error":false}'
mk claim-102-b 102 2026-09-14T09:00:00Z b@laptop '{"type":"result","subtype":"error_max_budget_usd","total_cost_usd":15.0,"num_turns":80,"is_error":true}'
mk claim-103-c 103 2026-09-21T11:00:00Z a@mac
fail=0; t(){ local want=$1; shift; if "$@" | grep -qE "$want"; then echo "OK       $want"; else echo "MISMATCH $want"; "$@" | sed 's/^/    | /'; fail=1; fi; }
echo "--- rows ---"
t '101.*a@mac.*52.*10\.47.*done'          bash "$S" --state-dir "$D"
t '102.*b@laptop.*80.*15\.00.*budget'    bash "$S" --state-dir "$D"
t '103.*a@mac.*died'                     bash "$S" --state-dir "$D"
t 'total.*25\.47'                        bash "$S" --state-dir "$D"
t '1 run.* no result line'               bash "$S" --state-dir "$D"
echo "--- --since ---"
t '101'                                  bash "$S" --state-dir "$D" --since 2026-09-20
if bash "$S" --state-dir "$D" --since 2026-09-20 | grep -q '^102'; then echo "MISMATCH 102 should be filtered"; fail=1; else echo "OK       102 filtered by --since"; fi
echo "--- --by ---"
t 'a@mac.*2.*10\.47'                     bash "$S" --state-dir "$D" --by operator
t '2026-W38.*2.*25\.47'                bash "$S" --state-dir "$D" --by week
t '2026-W39.*1.*died'                    bash "$S" --state-dir "$D" --by week
t '101.*10\.47'                          bash "$S" --state-dir "$D" --by ticket
echo "--- refusals ---"
if bash "$S" --state-dir "$D/nope" >/dev/null 2>&1; then echo "MISMATCH missing dir must refuse"; fail=1; else echo "OK       missing dir refuses"; fi
exit $fail
