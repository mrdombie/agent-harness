#!/usr/bin/env bash
# close-ticket.test.sh — /finish closes a ticket whose PR merged, never a polish
# list: a list closes only when nothing is left on it. Both closers are held here:
# this script, and reconcile-claims.sh's "the PR merged and the close-out never ran".
# Run: bash "$0"
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/tests/lib/suite.sh" || exit 1
for v in $(env | sed -n 's/^\(GIT_[A-Z_]*\)=.*/\1/p'); do unset "$v"; done
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../swarm/tests/fixture.sh"
swarm_fixture; on_exit_keep_status 'rm -rf "$FIX"'
CT="$HERE/close-ticket.sh"

echo "--- /finish: an ordinary ticket closes ---"
fix_issue 501 OPEN "status:in-review,type:bug"
want "it says so"                          "closed #501" "$(bash "$CT" 501 41)"
want_in "and closes it"                    '^issue close 501 ' "$(cat "$GH_LOG")"

echo "--- /finish: a polish list is left open, back on the queue ---"
: > "$GH_LOG"; fix_issue 900 OPEN "polish-list,screen:inbox,P3,status:in-review"
want "it says so"                          "polish list #900 left open" "$(bash "$CT" 900 42)"
want_not_in "and never closes it"          '^issue close 900' "$(cat "$GH_LOG")"
want_in "it goes back to ready"            '^issue edit 900 .*--remove-label status:in-review --add-label status:ready' "$(cat "$GH_LOG")"

echo "--- /finish: one refused read is tried again, through the shared backoff ---"
# A gh that refuses the first label read, then answers.
cat > "$BIN/gh-flaky" <<'SH'
#!/usr/bin/env bash
if [ "$1 $2" = "issue view" ] && [ ! -f "$FIX/flaked" ]; then : > "$FIX/flaked"; printf '%s\n' "$*" >> "$GH_LOG"; exit 1; fi
exec "$BIN/gh" "$@"
SH
chmod +x "$BIN/gh-flaky"
: > "$GH_LOG"; rm -f "$FIX/flaked"; fix_issue 502 OPEN "status:in-review"
want "the second try closes an ordinary ticket" "closed #502" "$(SWARM_GH="$BIN/gh-flaky" CLOSE_TICKET_RETRY_SEC=0 bash "$CT" 502 44 2>/dev/null)"
want "it read twice"                       "2" "$(grep -c '^issue view 502' "$GH_LOG")"
want_in "and the read went through gh_call" 'close-ticket	issue view' "$(cat "$STATE/swarm/gh-calls.log" 2>/dev/null)"

echo "--- /finish: labels that cannot be read close nothing ---"
: > "$GH_LOG"
CLOSE_TICKET_RETRY_SEC=0 bash "$CT" 999 43 2>/dev/null; want "refused"  "1" "$?"
want "after every try"                     "3" "$(grep -c '^issue view 999' "$GH_LOG")"
want_not_in "nothing closed"               '^issue close' "$(cat "$GH_LOG")"

echo "--- /finish's Step 7 closes through this script, never gh issue close ---"
F="$HERE/../skills/finish/SKILL.md"
want_in "the close-out calls it"           'scripts/close-ticket.sh" "\$ISSUE_NUM" "\$PR_NUMBER"' "$(cat "$F")"
want_not_in "and no bare close of the ticket is left" 'gh issue close "\$ISSUE_NUM"' "$(cat "$F")"

echo "--- reconcile: a merged PR closes its ticket, never a polish list ---"
R="$HERE/reconcile-claims.sh"
git init -q --bare -b develop "$FIX/origin.git"
git -C "$REPO" remote add origin "$FIX/origin.git"
git -C "$REPO" add -f .claude/harness.json && git -C "$REPO" -c user.name=t -c user.email=t@t commit -qm init
git -C "$REPO" push -q origin HEAD:develop
# A gh for the reconciler: both tickets claimed, 801 a polish list, each branch's PR merged.
cat > "$BIN/gh-rc" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_LOG"
case "$1 $2" in
  "api repos/acme/widgets") echo acme/widgets ;;
  "issue view") case "$3" in 801) printf 'status:claimed\npolish-list\nscreen:inbox\n' ;; *) printf 'status:claimed\n' ;; esac ;;
  "pr list") case "$*" in *"--head tkt-80"*) echo '[{"number":9801,"state":"MERGED"}]' ;; *) printf '[]\n' ;; esac ;;
  *) : ;;
esac
exit 0
SH
mkdir -p "$FIX/rcbin"; mv "$BIN/gh-rc" "$FIX/rcbin/gh"; chmod +x "$FIX/rcbin/gh"
plant_claim() { # <ticket>
  local rec sha empty
  # A dead pid on this host: the run is gone, so the reconciler judges what it left.
  rec=$(jq -nc --arg i "$1" --arg h "$(hostname -s 2>/dev/null || hostname | cut -d. -f1)" \
    '{issue:$i, agent:"tester@fixture", pid:999999, branch:("tkt-" + $i + "/work"), worktree:"", host:$h, claimed_at:"2026-09-27T21:00:00Z"}')
  empty=$(git -C "$REPO" hash-object -t tree /dev/null)
  sha=$(printf '%s\n' "$rec" | git -C "$REPO" -c user.name=t -c user.email=t@t commit-tree "$empty")
  git -C "$REPO" update-ref "refs/claims/$1" "$sha" && git -C "$REPO" push -q origin "refs/claims/$1"
}
plant_claim 801; plant_claim 802
git -C "$REPO" push -q origin HEAD:refs/heads/tkt-801/work HEAD:refs/heads/tkt-802/work
: > "$GH_LOG"
out=$( cd "$REPO" && PATH="$FIX/rcbin:$PATH" SWARM_GH="$FIX/rcbin/gh" CLAIM_REPO="$REPO" CLAIM_REMOTE=origin NOTIFY=0 bash "$R" 2>&1 )
want_in "an ordinary ticket whose PR merged is closed" 'SHIPPED +#802' "$out"
want_in "and it is"                        '^issue close 802 ' "$(cat "$GH_LOG")"
want_in "a polish list whose PR merged is not" 'POLISH +#801 .*back to status:ready' "$out"
want_not_in "and is never closed"          '^issue close 801' "$(cat "$GH_LOG")"
want_in "it goes back to ready"            '^issue edit 801 .*--add-label status:ready' "$(cat "$GH_LOG")"

suite_end "$FAILED"
