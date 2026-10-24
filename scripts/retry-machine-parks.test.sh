#!/usr/bin/env bash
# retry-machine-parks.test.sh — a park the machine caused ("Needs: nothing from you") is
# retried once, fresh, after 30 minutes, on any host; the same failure again goes to the PM
# with both named; a fresh park waits; a person's or the PM's park is never touched.
# (2026-10-24: 13 such parks sat, some since 21 Oct, one a P0, until the PM requeued them.)
# Run: bash "$0"
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/tests/lib/suite.sh" || exit 1
for v in $(env | sed -n 's/^\(GIT_[A-Z_]*\)=.*/\1/p'); do unset "$v"; done
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../swarm/tests/fixture.sh"
swarm_fixture; on_exit_keep_status 'rm -rf "$FIX"'
S="$HERE/retry-machine-parks.sh"
printf '#!/usr/bin/env bash\necho "$*" >> "$FIX/queue.log"\n' > "$BIN/queue"; chmod +x "$BIN/queue"
export MACHINE_PARK_QUEUE="$BIN/queue" MACHINE_PARK_NOW=$(date -u -j -f '%Y-%m-%dT%H:%M:%SZ' 2026-10-24T12:00:00Z +%s 2>/dev/null || date -u -d 2026-10-24T12:00:00Z +%s)
park() { # <reason> <when> [needs] — a park comment as the driver writes it
  jq -n --arg r "$1" --arg w "$2" --arg nd "${3:-**Needs:** nothing from you. This is the driver, a gate or this project own configuration, so no hold label is on it.}" \
    '{body: "**Parked — \($r).**\n\n**Built:** nothing yet\n**Stopped at:** \($r)\n\($nd)\n**What stopped it:** x", createdAt: $w}'
}
note() { jq -n --arg b "$1" --arg w "$2" '{body: $b, createdAt: $w}'; }
ticket() { # <n> <labels csv> <comment json…>
  local n="$1" l="$2"; shift 2
  fix_issue "$n" OPEN "$l"
  jq -n --argjson n "$n" --arg l "$l" '{number: $n, labels: ($l | split(",") | map({name: .})), comments: $ARGS.positional}' --jsonargs "$@"
}
list() { jq -s . > "$FIX/gh/issue-list-status:parked.json"; }
run() { : > "$FIX/queue.log"; : > "$GH_LOG"; OUT=$(bash "$S" "$@" 2>&1); }

echo "--- a machine park over 30 minutes old is retried, once ---"
{ ticket 12988 "status:parked,P0" "$(park 'start refused: could not create a worktree at /Users/x/proj-wt/sh-12988-ab12cd' 2026-10-21T09:00:00Z)"
  ticket 501 "status:parked,P1" "$(park 'start refused: could not create a worktree' 2026-10-24T11:50:00Z)"
  ticket 502 "status:parked,P1,status:pm-decision" "$(park 'the PM must say which repo' 2026-10-24T09:00:00Z '**Needs (PM):** which repo')"
  ticket 503 "status:parked,P1,needs:human-approval" "$(park 'a person must choose' 2026-10-24T09:00:00Z '**Needs:** a person to choose')"
  ticket 504 "status:parked,P2" "$(park 'a question' 2026-10-24T09:00:00Z '**Needs:** an answer')"; } | list
run
want_in "the old machine park is retried"       '^retried #12988 — parked .* by the machine: start refused' "$OUT"
want_in "  set ready"                          'issue edit 12988 .*--add-label status:ready' "$(tr '\n' ' ' < "$GH_LOG")"
want_in "  told, with the attempt marked on the ticket" 'issue comment 12988 .*Retried:.*machine-park-retry: start refused could not create a worktree at -->' "$(tr '\n' ' ' < "$GH_LOG")"
want "  queued first at its priority"          "add 12988 --first" "$(cat "$FIX/queue.log")"
want_in "a fresh machine park waits"           '^waits: #501 — a machine park 10 min old' "$OUT"
want_not_in "  and is not touched"             'issue (edit|comment) 501' "$(cat "$GH_LOG")"
for n in 502 503 504; do want_not_in "#$n (a PM's or a person's park) is never touched" "#$n|issue (edit|comment) $n" "$OUT$(cat "$GH_LOG")"; done

echo "--- retried and not parked since: it waits for the run ---"
marker=$(grep -o 'machine-park-retry: [^>]*-->' "$GH_LOG" | head -1 | sed 's/ -->$//')
{ ticket 12988 "status:ready,P0" "$(park 'start refused: could not create a worktree at /Users/x/proj-wt/sh-12988-ab12cd' 2026-10-21T09:00:00Z)" "$(note "**Retried:** x
<!-- $marker -->" 2026-10-24T11:00:00Z)"; } | list
run
want "nothing is done again"                   "" "$OUT"

echo "--- parked again the same way: the PM, with both failures, and no retry ---"
{ ticket 12988 "status:parked,P0" "$(park 'start refused: could not create a worktree at /Users/x/proj-wt/sh-12988-ab12cd' 2026-10-21T09:00:00Z)" "$(note "**Retried:** x
<!-- $marker -->" 2026-10-24T11:00:00Z)" "$(park 'start refused: could not create a worktree at /Users/y/proj-wt/sh-12988-ef34ab' 2026-10-24T11:10:00Z)"; } | list
run
want_in "reported to the PM"                   '^reported #12988 to the PM — parked twice' "$OUT"
want_in "  with the PM-decision status"         'issue edit 12988 .*--add-label status:pm-decision' "$(tr '\n' ' ' < "$GH_LOG")"
want_in "  naming both failures"                'failed twice the same way.*/Users/x/proj-wt.*parked again on: start refused: could not create a worktree at /Users/y' "$(tr '\n' ' ' < "$GH_LOG")"
want "  and never queued again"                "" "$(cat "$FIX/queue.log")"

echo "--- parked again on another cause: that cause gets its own one retry ---"
{ ticket 12988 "status:parked,P0" "$(park 'start refused: could not create a worktree' 2026-10-21T09:00:00Z)" "$(note "**Retried:** x
<!-- $marker -->" 2026-10-24T11:00:00Z)" "$(park 'machine fault reviewer-silent' 2026-10-24T11:10:00Z)"; } | list
run
want_in "a new cause is retried"               '^retried #12988' "$OUT"

echo "--- --dry-run changes nothing ---"
{ ticket 12988 "status:parked,P0" "$(park 'start refused: could not create a worktree' 2026-10-21T09:00:00Z)"; } | list
run --dry-run
want_in "it says what it would do"             '^would retry #12988' "$OUT"
want "and does nothing"                        "" "$(grep -E 'issue (edit|comment)' "$GH_LOG")"

echo "--- housekeeping runs it, beside the unblocker ---"
want "coordinator-housekeeping calls it"       "1" "$(grep -c 'MACHINE_PARKS="${COORDINATOR_MACHINE_PARKS:-$SELF_DIR/retry-machine-parks.sh}"' "$HERE/coordinator-housekeeping.sh")"

echo "--- plants: each guard out of a copy, its case fails ---"
K="$FIX/kit"; rm -rf "$K"; mkdir -p "$K"; cp -R "$HERE" "$K/scripts"
plant() { # <label> <text> <replacement> <setup cmd> <grep that must now be absent or present> <want>
  cp "$HERE/retry-machine-parks.sh" "$K/scripts/retry-machine-parks.sh"
  python3 -I -c 'import sys; p,a,b=sys.argv[1:4]; s=open(p).read(); n=s.count(a); open(p,"w").write(s.replace(a,b,1)); sys.exit(0 if n==1 else 1)' "$K/scripts/retry-machine-parks.sh" "$2" "$3" \
    || { want "plant landed: $1" landed missed; return; }
  eval "$4"; : > "$FIX/queue.log"; : > "$GH_LOG"; OUT=$(bash "$K/scripts/retry-machine-parks.sh" 2>&1)
  want "planted ($1): the case now fails" "$6" "$(printf '%s' "$OUT" | grep -cE "$5")"
}
setup_age='{ ticket 501 "status:parked,P1" "$(park "start refused: could not create a worktree" 2026-10-24T11:50:00Z)"; } | list'
plant "the 30-minute wait" '[ "${age:-0}" -ge "$AFTER_MIN" ] ||' 'true ||' "$setup_age" '^retried #501' 1
setup_pm='{ ticket 502 "status:parked,P1,status:pm-decision" "$(park "start refused: could not create a worktree" 2026-10-24T09:00:00Z)"; } | list'
plant "a PM's park is left alone" 'select([.labels[]?.name] | any(. as $l | $people | index($l)) | not)' 'select(true)' "$setup_pm" '^retried #502' 1
setup_twice='{ ticket 12988 "status:parked,P0" "$(park "start refused: could not create a worktree" 2026-10-21T09:00:00Z)" "$(note "**Retried:** x
<!-- machine-park-retry: start refused could not create a worktree -->" 2026-10-24T11:00:00Z)" "$(park "start refused: could not create a worktree" 2026-10-24T11:10:00Z)"; } | list'
plant "the second identical failure is the PM's" 'elif $before > 0 then "retried" else "new" end' 'else "new" end' "$setup_twice" '^retried #12988' 1
plant "the needs-nothing reading" '| select($p != null and (($p.body // "") | test("\\*\\*Needs:\\*\\* nothing from you")))' '| select($p != null)' \
  '{ ticket 504 "status:parked,P2" "$(park "a question" 2026-10-24T09:00:00Z "**Needs:** an answer")"; } | list' '^retried #504' 1

suite_end "$FAILED"
