#!/usr/bin/env bash
# prune-set-aside-bundles.test.sh — the rebuild set-aside's bundles: the newest per open
# ticket stays, older copies go, and a closed ticket keeps none. Dry run removes nothing.
# Run: bash "$0"
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/tests/lib/suite.sh" || exit 1
for v in $(env | sed -n 's/^\(GIT_[A-Z_]*\)=.*/\1/p'); do unset "$v"; done
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../swarm/tests/fixture.sh"
swarm_fixture; on_exit_keep_status 'rm -rf "$FIX"'
S="$HERE/prune-set-aside-bundles.sh"
D="$STATE/driver"; mkdir -p "$D"
issue() { jq -n --argjson n "$1" --arg s "$2" '{number:$n, state:$s, title:"T", labels:[]}' > "$FIX/gh/issue-$1.json"; }
bundle() { printf 'x%.0s' $(seq 1 "${3:-10}") > "$D/$1.local-$2.bundle"; touch -t "$2" "$D/$1.local-$2.bundle"; }
lay() {
  rm -f "$D"/*.bundle
  bundle 501 202611010000; bundle 501 202611020000; bundle 501 202611030000   # open: keep the newest
  bundle 502 202611010000; bundle 502 202611020000                            # closed: keep none
  bundle 503 202611010000                                                     # open, one copy: kept
  printf 'state\n' > "$D/501.set-aside-1"                                     # not a bundle: never touched
}
left() { (cd "$D" && ls | sort | tr '\n' ' '); }
issue 501 OPEN; issue 502 CLOSED; issue 503 OPEN

echo "--- dry run: the count first, nothing removed ---"
lay; out=$(bash "$S" --dry-run 2>&1); rc=$?
want "it exits 0"                        "0" "$rc"
want_in "the count leads"                '^set-aside bundles: would remove 4 file\(s\)' "$(printf '%s\n' "$out" | head -1)"
want "every file is still there"         "7" "$(ls "$D" | grep -c .)"

echo "--- for real: newest per open ticket, none for a closed one ---"
lay; out=$(bash "$S" 2>&1); rc=$?
want "it exits 0"                        "0" "$rc"
want "what is left" "501.local-202611030000.bundle 501.set-aside-1 503.local-202611010000.bundle " "$(left)"
want_in "it says why a closed one went"  'removed .*502\.local-202611020000\.bundle — #502 is closed' "$out"
want_in "and why an older copy went"     'removed .*501\.local-202611010000\.bundle — a newer bundle for #501 is kept' "$out"

echo "--- offline, or GitHub unreadable: only the older copies go ---"
lay; out=$(bash "$S" --offline 2>&1); rc=$?
want "offline exits 0"                   "0" "$rc"
want "  the closed ticket's newest stays" "yes" "$([ -f "$D/502.local-202611020000.bundle" ] && echo yes || echo no)"
want "  its older one goes"              "no" "$([ -f "$D/502.local-202611010000.bundle" ] && echo yes || echo no)"
lay; rm -f "$FIX/gh/issue-50"*.json
out=$(bash "$S" 2>&1); rc=$?
issue 501 OPEN; issue 502 CLOSED; issue 503 OPEN
want "  a ticket whose state is not read keeps its newest" "yes" "$([ -f "$D/502.local-202611020000.bundle" ] && [ -f "$D/503.local-202611010000.bundle" ] && echo yes || echo no)"

echo "--- nothing to prune: silent ---"
rm -f "$D"/*.bundle
out=$(bash "$S" 2>&1); rc=$?
want "exits 0"                           "0" "$rc"
want "says nothing"                      "" "$out"

echo "--- the coordinator's housekeeping runs it, dry under shadow ---"
want "housekeeping calls it" "1" "$(grep -c 'PRUNE_BUNDLES="${COORDINATOR_PRUNE_BUNDLES:-$SELF_DIR/prune-set-aside-bundles.sh}"' "$HERE/coordinator-housekeeping.sh")"
want_in "and dry under shadow" 'coord_shadow.*"\$PRUNE_BUNDLES" .*--dry-run' "$(cat "$HERE/coordinator-housekeeping.sh")"

suite_end "$FAILED"
