#!/usr/bin/env bash
# rebuild-waste.test.sh — what the rebuild pass (scripts/rebuild.sh) does before it spends a
# fix round or parks, and what it never writes twice:
#   - a red PR is brought up to date with its base first, once per PR head and base tip, and
#     the round is spent only on a red that survives the update;
#   - a draft whose build is unfinished on this host is queued to be resumed: never a fix
#     round, never parked for its checks;
#   - the park for the PM after the fix rounds is written once per PR head;
#   - a ticket a person holds is left exactly as it is, also when the label went on after
#     the tick's own read.
# PLANT=<name> turns one rule off in a copy of rebuild.sh, so the case that pins it must fail.
# Run: bash "$0"
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/tests/lib/suite.sh" || exit 1
for v in $(env | sed -n 's/^\(GIT_[A-Z_]*\)=.*/\1/p'); do unset "$v"; done
# A driver run exports the host's state paths; left set, they win over the fixture's.
unset DRIVER_DIR RUNS_DIR STATE_DIR SWARM_DIR SWARM_LOGS COORD_DIR COORD_LOG COORD_QUEUE COORD_EVENTS COORD_ACTIONS COORD_NEEDS_YOU
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/fixture.sh"
swarm_fixture; on_exit_keep_status 'rm -rf "$FIX"'
KIT="$(cd "$HERE/../.." && pwd)"
export COORDINATOR_SHADOW=0 COORDINATOR_REBUILD_AFTER_MIN=0
unset COORDINATOR_FIX_ROUNDS COORDINATOR_DRAFT_RESUMES
C="$STATE/coordinator"; mkdir -p "$C"
QLOG="$FIX/queue.log"; export QLOG
cat > "$BIN/queue" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$QLOG"
SH
# A draft the machine made: nobody put it back to draft.
printf '#!/usr/bin/env bash\nexit 1\n' > "$BIN/person-stop"
# gh as the fixture has it, except `issue view <n>` answers from issue-<n>.now.json when that
# exists: what the ticket wears the moment it is read alone, after the tick's batched read.
cat > "$BIN/gh-now" <<'SH'
#!/usr/bin/env bash
if [ "$1 $2" = "issue view" ] && [ -f "$FIX/gh/issue-$3.now.json" ]; then
  printf '%s\n' "$*" >> "$GH_LOG"
  q=""; prev=""; for a in "$@"; do case "$prev" in -q|--jq) q="$a" ;; esac; prev="$a"; done
  if [ -n "$q" ]; then jq -r "$q" < "$FIX/gh/issue-$3.now.json"; else cat "$FIX/gh/issue-$3.now.json"; fi
  exit 0
fi
exec "$BIN/gh" "$@"
SH
chmod +x "$BIN/queue" "$BIN/person-stop" "$BIN/gh-now"
export QUEUE="$BIN/queue" OPEN_WORK_PERSON_STOP="$BIN/person-stop" SWARM_GH="$BIN/gh-now"
LIB="$KIT/scripts/rebuild.sh"
T0=1762160000

lib() {
  [ -n "${PLANT:-}" ] || { printf '%s' "$LIB"; return; }
  local p="$FIX/rebuild.planted.sh"
  cp "$LIB" "$p"
  case "$PLANT" in
    update-first)  perl -0pi -e 's/if \[ "\$kind" = red \] && rebuild_stale_update [^\n]*\n//' "$p" ;;
    update-pair)   perl -0pi -e 's/  \[ "\$uh" != "\$head" \] \|\| \[ "\$ub" != "\$tip" \] \|\| return 1\n//' "$p" ;;
    update-made)   perl -0pi -e 's/    \[ "\$after" != "\$head" \] \|\| return 1\n//' "$p" ;;
    update-wait)   perl -0pi -e 's/if \[ \$\(\(now - at\)\) -lt "\$REBUILD_UPDATE_WAIT_SEC" \]; then/if false; then/' "$p" ;;
    resume)        perl -0pi -e 's/    if rebuild_resume_draft "\$t" "\$pj"; then rebuild_clock_stop "\$pr"; continue; fi\n//' "$p" ;;
    resume-once)   perl -0pi -e 's/  case "\$note" in Resume:\*\)\n[^\n]*\n    return 0 ;;\n  esac\n//' "$p" ;;
    resume-cap)    perl -0pi -e 's/if \[ "\$tries" -ge "\$DRAFT_RESUME_MAX" \]; then/if false; then/' "$p" ;;
    resume-shipped) perl -0pi -e 's/ and index\("ship"\) == null then length/ then length/' "$p" ;;
    park-once)     perl -0pi -e 's/  if rebuild_parked_at "\$pr" "\$head"; then\n[^\n]*\n    return 0\n  fi\n//' "$p" ;;
    park-record)   perl -0pi -e 's/  rebuild_ledger_put "\$FIX_PARKS" "\$pr" "\$head" "\$\(swarm_now\)"\n//' "$p" ;;
    park-head)     perl -0pi -e 's/\$1 == p && \$2 == h \{ f = 1 \} END \{ exit !f \}. "\$FIX_PARKS"/\$1 == p { f = 1 } END { exit !f }\x27 "\$FIX_PARKS"/' "$p" ;;
    hold-park)     perl -0pi -e 's/    0\) say "rebuild: PR #\$pr left as it is — #\$t waits on a person \(\$REBUILD_HELD_BY\); not parked over it"; return 0 ;;\n//' "$p" ;;
    hold-resume)   perl -0pi -e 's/    0\) say "rebuild: PR #\$pr left as it is — #\$t waits on a person \(\$REBUILD_HELD_BY\); its build is not resumed"; return 0 ;;\n/    0) ;;\n/' "$p" ;;
    hold-fix)      perl -0pi -e 's/    0\) say "rebuild: PR #\$pr left as it is — #\$t waits on a person \(\$REBUILD_HELD_BY\); no fix round queued"; return 0 ;;\n/    0) ;;\n/' "$p" ;;
    hold-labels)   perl -0pi -e 's/REBUILD_HELD_BY="\$l"; return 0; fi/:; fi/' "$p" ;;
  esac
  cmp -s "$LIB" "$p" && { echo "plant $PLANT did not apply" >&2; exit 3; }
  printf '%s' "$p"
}
# pass — one rebuild pass over $FIX/gh/prs-all.json, as the tick runs it.
pass() {
  local l; l=$(lib) || exit 3
  OUT=$(cd "$REPO" && CLAIMED="${CLAIMED:-}" bash -c '
    . "$1/scripts/coordinator-env.sh" || exit 1
    . "$1/scripts/pr-red.sh" || exit 1
    . "$1/scripts/issue-status.sh" || exit 1
    . "$2" || exit 1
    PRS=$(cat "$3"); PRS_STALE=0
    rebuild_pass' _ "$KIT" "$l" "$FIX/gh/prs-all.json" 2>&1)
}
# pr <n> <ticket> <head> <mergeState> [name:CONCLUSION:run-id…] — the one open PR; DRAFT=1 makes it a draft.
pr() {
  local n="$1" t="$2" head="$3" ms="$4" c rows="[]" name concl rid; shift 4
  for c in "$@"; do
    IFS=: read -r name concl rid <<<"$c"
    rows=$(jq -c --arg n "$name" --arg c "$concl" --arg r "$rid" \
      '. + [{name: $n, status: "COMPLETED", conclusion: $c, completedAt: "2026-11-01T10:00:00Z",
             detailsUrl: "https://github.com/acme/widgets/actions/runs/\($r)/job/1"}]' <<<"$rows")
  done
  jq -n --argjson n "$n" --arg t "$t" --arg sha "$head" --arg ms "$ms" --argjson r "$rows" --argjson d "${DRAFT:-0}" \
    '[{number: $n, headRefName: "tkt-\($t)/work", headRefOid: $sha, baseRefName: "develop", isDraft: ($d == 1),
       mergeable: (if $ms == "DIRTY" then "CONFLICTING" else "MERGEABLE" end), mergeStateStatus: $ms,
       labels: [], statusCheckRollup: $r, updatedAt: "2026-11-01T10:00:00Z", title: "the change"}]' > "$FIX/gh/prs-all.json"
}
# base <tip> <name:conclusion>… — develop's newest commit and what each check's completed run there concluded.
base() {
  local tip="$1" c rows="[]" name concl; shift
  jq -n --arg s "$tip" '[{sha: $s}]' > "$FIX/gh/api-repos_acme_widgets_commits_sha_develop_per_page_5.json"
  for c in "$@"; do
    IFS=: read -r name concl <<<"$c"
    rows=$(jq -c --arg n "$name" --arg c "$concl" '. + [{name: $n, id: 1, status: "completed", conclusion: $c, completed_at: "2026-11-01T09:00:00Z"}]' <<<"$rows")
  done
  jq -n --argjson r "$rows" '{check_runs: $r}' > "$FIX/gh/api-repos_acme_widgets_commits_${tip}_check-runs_per_page_100_filter_all.json"
}
# record <ticket> <step…> — this host's driver record of the ticket's build: the steps it finished.
record() {
  local t="$1" d="$STATE/driver/$1"; shift; mkdir -p "$d/steps"
  jq -n --argjson t "$t" '{ticket: $t, done: $ARGS.positional, mode: "build"}' --args "$@" > "$d/state.json"
}
fresh() {
  : > "$GH_LOG"; : > "$QLOG"
  rm -f "$C"/rebuild-clock.* "$C"/base-red.* "$C"/fix-rounds.* "$C"/clash-updates.* "$C"/stale-updates.* "$C"/fix-parks.* "$C"/draft-resumes.* "$C"/queue.json \
        "$FIX"/gh/api-repos_acme_widgets_pulls_*_update-branch.json "$FIX"/gh/issue-*.now.json "$STATE/swarm/person-drafted.tsv"
  rm -rf "$STATE/driver" "$STATE/runs"; CLAIMED=""; DRAFT=0
  fix_issue 101 OPEN "status:in-review,P1"
}
age() { fix_at $(( T0 + $1 * 60 )); }
accepts() { printf '{"message":"Updating pull request branch."}\n' > "$FIX/gh/api-repos_acme_widgets_pulls_$1_update-branch.json"; }
# on_queue <ticket> <note> — the coordinator's queue holds that entry (the recorder above writes none).
on_queue() { jq -n --argjson n "$1" --arg note "$2" '{scope: "all", label: "all", tickets: [{n: $n, class: "new", note: $note, pinned: true, front: true}]}' > "$C/queue.json"; }
adds() { grep -c "^add $1 " "$QLOG"; }
fixes() { grep -c "^add $1 .*--note Fix: PR #" "$QLOG"; }
resumes() { grep -c "^add $1 .*--note Resume: PR #" "$QLOG"; }
rounds() { awk -F'\t' -v p="$1" '$1 == p { print $2 "/" $3 }' "$C/fix-rounds.did.tsv" 2>/dev/null; }
updates() { grep -c "^api repos/acme/widgets/pulls/$1/update-branch -X PUT" "$GH_LOG"; }
edits() { grep -c "^issue edit $1 " "$GH_LOG"; }
comments() { grep -c "^issue comment $1 " "$GH_LOG"; }
# named <ticket> <pr> — every gh call that names the ticket or its PR: reads and writes alike.
named() { grep -cE "^(issue|pr) [a-z]+ ($1|$2)( |\$)|/(issues|pulls)/($1|$2)(/| |\$)" "$GH_LOG"; }
spent() { printf '%s\t%s\t%s\tstarted\n' "$1" "$2" "$3" > "$C/fix-rounds.did.tsv"; }

fix_required unit lint
fresh

echo "--- a red PR is brought up to date with its base first: no builder, no round ---"
fresh; base dev1 unit:success lint:success; accepts 71
pr 71 101 head1 BLOCKED unit:FAILURE:7001 lint:SUCCESS:7002
age 0; pass
want "one update of its branch"                  "1" "$(updates 71)"
want_in "  for the head it read"                 'pulls/71/update-branch -X PUT -f expected_head_sha=head1' "$(cat "$GH_LOG")"
want "  nothing is queued"                       "0" "$(adds 101)"
want "  no round on the ledger"                  "" "$(rounds 71)"
want "  the ticket's labels are not touched"     "0" "$(edits 101)"
want_in "  it says so"                           'rebuild: PR #71 is red .* and was brought up to date with develop first — no builder sent, no fix round spent' "$OUT"
echo "  the same head read again before the update lands: it waits, and asks nothing more"
age 5; pass
want "  no second update"                        "1" "$(updates 71)"
want "  still nothing queued"                    "0" "$(adds 101)"
want_in "  it says it waits for the new head"    'rebuild: PR #71 is stuck .* — its update from develop was accepted and the new head is not read yet' "$OUT"
echo "  the update turned it green: no round was ever spent"
pr 71 101 head2 CLEAN unit:SUCCESS:7003 lint:SUCCESS:7004
age 10; pass
want "  nothing queued"                          "0" "$(adds 101)"
want "  no round"                                "" "$(rounds 71)"
want "  one update in all"                       "1" "$(updates 71)"

echo "--- still red on the head the update made: the round is spent then ---"
fresh; base dev1 unit:success; accepts 72
pr 72 101 head1 BLOCKED unit:FAILURE:7001
age 0; pass
want "updated first"                             "1/0" "$(updates 72)/$(adds 101)"
pr 72 101 head2 BLOCKED unit:FAILURE:7005
age 10; pass
want "red again on the updated head: a fix round is queued" "1" "$(fixes 101)"
want "  round 1, on that head"                   "1/head2" "$(rounds 72)"
want "  and no second update"                    "1" "$(updates 72)"
want_in "  it says the red is its own"           'rebuild: PR #72 is still red on the head its update from develop made' "$OUT"
echo "  the base moves on while that head stays red: still no second update"
base dev2 unit:success
age 15; pass
want "  no update for the new base tip"          "1" "$(updates 72)"
echo "  its builder pushes, red again and the base has moved: one more free update"
pr 72 101 head3 BLOCKED unit:FAILURE:7006; spent 72 1 head2; : > "$QLOG"
age 30; pass
want "  a second update, for the new head"       "2" "$(updates 72)"
want "  and no second round yet"                 "0" "$(fixes 101)"

echo "--- an update GitHub refuses (up to date, or a conflict): the round is spent at once, and the pair is never asked again ---"
fresh; base dev1 unit:success
pr 73 101 head1 BLOCKED unit:FAILURE:7001
age 0; pass
want "tried once"                                "1" "$(updates 73)"
want "  and the fix round queued the same tick"  "1" "$(fixes 101)"
want_in "  it says the red is its own"           'rebuild: PR #73 could not be brought up to date with develop' "$OUT"
age 5; pass; age 10; pass
want "the same head and base tip, twice more: never asked again" "1" "$(updates 73)"
echo "  an accepted update that never moved the head is not waited on for ever"
fresh; base dev1 unit:success; accepts 74
pr 74 101 head1 BLOCKED unit:FAILURE:7001
age 0; pass; age 11; pass
want "  11 minutes on, the same head: the round is spent" "1" "$(fixes 101)"
want "  with no second update"                   "1" "$(updates 74)"

echo "--- its rounds spent, red on a new head: the free update comes before the park ---"
fresh; base dev1 unit:success; accepts 75; spent 75 2 head0
pr 75 101 head1 BLOCKED unit:FAILURE:7001
age 0; pass
want "updated"                                   "1" "$(updates 75)"
want "  not parked"                              "0" "$(edits 101)"

echo "--- shadow: says it would update, asks nothing ---"
fresh; base dev1 unit:success; accepts 76
pr 76 101 head1 BLOCKED unit:FAILURE:7001
age 0; COORDINATOR_SHADOW=1 pass
want "no update in shadow"                       "0" "$(updates 76)"
want "  and none recorded"                       "" "$(cat "$C"/stale-updates.* 2>/dev/null)"
want_in "  it says it would"                     'rebuild: would bring PR #76 up to date with develop once' "$OUT"

echo "--- a draft whose build is unfinished here is resumed: no fix round, no park ---"
fresh; base dev1 unit:success; record 101 start plan
DRAFT=1 pr 80 101 head1 BLOCKED unit:FAILURE:7001
age 0; pass
want "queued once to be resumed"                 "1" "$(resumes 101)"
want_in "  first in its priority, the note naming the PR" '^add 101 --class new --first --note Resume: PR #80 is a draft part-way through its build \(2 step\(s\) done, not shipped\)' "$(cat "$QLOG")"
want "  never as a fix round"                    "0" "$(fixes 101)"
want "  no round on the ledger"                  "" "$(rounds 80)"
want "  its branch is not updated"               "0" "$(updates 80)"
want_in "  the ticket is set ready, so the entry can start" 'issue edit 101 .*--add-label status:ready' "$(cat "$GH_LOG")"
want "  never parked"                            "0" "$(grep -c 'status:parked' "$GH_LOG")"
want "  and nothing is posted on it"             "0" "$(comments 101)"
want_in "  it says so"                           'rebuild: PR #80 is a draft part-way through its build \(2 step\(s\) done\) — #101 is queued to resume it' "$OUT"
echo "  its resume still on the queue: not queued again"
on_queue 101 "Resume: PR #80 is a draft part-way through its build"
age 5; pass; age 10; pass
want "  one queue entry, however many ticks"     "1" "$(resumes 101)"
want_in "  it says the resume waits for a place" 'rebuild: PR #80 is a draft part-way through its build .* — its resume is queued and waits for a place' "$OUT"
echo "  its rounds already spent: resumed all the same, never parked for its checks"
fresh; base dev1 unit:success; record 101 start plan; spent 81 2 head1
DRAFT=1 pr 81 101 head1 DIRTY unit:FAILURE:7001
age 0; pass
want "  resumed"                                 "1" "$(resumes 101)"
want "  not parked"                              "0/0" "$(grep -c 'status:parked' "$GH_LOG")/$(comments 101)"
echo "  a person's hold put on since the tick's read: not resumed, nothing written"
fresh; base dev1 unit:success; record 101 start plan
DRAFT=1 pr 81 101 head1 BLOCKED unit:FAILURE:7001
fix_issue 101 OPEN "status:blocked,P1"; mv "$FIX/gh/issue-101.json" "$FIX/gh/issue-101.now.json"; fix_issue 101 OPEN "status:in-review,P1"
age 0; pass
want "  nothing queued, no label written"        "0/0" "$(adds 101)/$(edits 101)"
echo "  a fix round an older version queued for it is replaced by the resume"
fresh; base dev1 unit:success; record 101 start plan
on_queue 101 "Fix: PR #82 — red"
DRAFT=1 pr 82 101 head1 BLOCKED unit:FAILURE:7001
age 0; pass
want "  queued to resume, over the fix note"     "1" "$(resumes 101)"
echo "  resumed twice at one head with no step finished: treated as any stuck PR"
fresh; base dev1 unit:success; record 101 start plan
DRAFT=1 pr 83 101 head1 BLOCKED unit:FAILURE:7001
age 0; pass; age 30; pass
want "  two resumes"                             "2" "$(resumes 101)"
age 60; pass
want "  never a third"                           "2" "$(resumes 101)"
want "  it takes the fix path instead"           "1" "$(fixes 101)"
want_in "  it says so"                           'rebuild: PR #83 is a draft part-way through its build, resumed 2 time\(s\) with no step finished and no push' "$OUT"
echo "  a step finished since: it is resumed again"
fresh; base dev1 unit:success; record 101 start plan
DRAFT=1 pr 83 101 head1 BLOCKED unit:FAILURE:7001
age 0; pass; age 30; pass; record 101 start plan build; age 60; pass
want "  a third resume, for the new step count"  "3" "$(resumes 101)"

echo "--- not that: a shipped draft, a record on another host, a run that holds it, a ready PR ---"
fresh; base dev1 unit:success; record 101 start plan build review ship
DRAFT=1 pr 84 101 head1 BLOCKED unit:FAILURE:7001
age 0; pass
want "every step done, ship too: not resumed"    "0" "$(resumes 101)"
want "  the fix path has it, as before"          "1" "$(fixes 101)"
fresh; base dev1 unit:success
DRAFT=1 pr 85 101 head1 BLOCKED unit:FAILURE:7001
age 0; pass
want "no record on this host: not resumed"       "0" "$(resumes 101)"
want "  the fix path has it, as before"          "1" "$(fixes 101)"
want_in "  and it says the record could not be seen" "rebuild: PR #85 is a draft and #101's build record is not on this host — whether its build is unfinished could not be seen" "$OUT"
fresh; base dev1 unit:success; record 101 start plan; CLAIMED=101
DRAFT=1 pr 86 101 head1 BLOCKED unit:FAILURE:7001
age 0; pass
want "a claimed ticket: nothing is queued"       "0" "$(adds 101)"
fresh; base dev1 unit:success; record 101 start plan
pr 87 101 head1 BLOCKED unit:FAILURE:7001
age 0; pass
want "a PR that is not a draft: not resumed"     "0" "$(resumes 101)"
want "  the fix path has it"                     "1" "$(fixes 101)"
fresh; base dev1 unit:success; record 101 start plan
DRAFT=1 pr 88 101 head1 BLOCKED unit:FAILURE:7001
age 0; COORDINATOR_SHADOW=1 pass
want "shadow queues nothing"                     "0" "$(adds 101)"
want_in "  it says it would resume"              'rebuild: would queue #101 to resume its unfinished build of draft PR #88' "$OUT"

echo "--- the park for the PM is written once per PR head ---"
fresh; base dev1 unit:success; spent 90 2 head0
pr 90 101 head1 BLOCKED unit:FAILURE:7001
age 0; pass
want "its rounds spent and still red: parked"    "1" "$(grep -c 'issue edit 101 .*--add-label status:parked' "$GH_LOG")"
want "  told why, once"                          "1" "$(comments 101)"
want "  the head is on the park ledger"          "90/head1" "$(awk -F'\t' '{ print $1 "/" $2 }' "$C/fix-parks.did.tsv" 2>/dev/null)"
echo "  the park label is gone again (a PM answer set it ready) and the head has not moved"
: > "$GH_LOG"; age 5; pass
want "  the next tick writes nothing"            "0/0" "$(edits 101)/$(comments 101)"
want "  and makes no call naming the ticket or its PR" "0" "$(named 101 90)"
want_in "  one line says why"                    'rebuild: PR #90 is stuck .* — already parked for the PM at this head; nothing is written until it moves' "$OUT"
want "  that line and no other about it"         "1" "$(grep -c 'PR #90\|#101' <<<"$OUT")"
age 10; pass; age 15; pass
want "  nor do the two after it"                 "0" "$(named 101 90)"
echo "  a new head re-arms it"
pr 90 101 head2 BLOCKED unit:FAILURE:7002
: > "$GH_LOG"; age 20; pass
want "  red on the new head: parked again, once" "1/1" "$(grep -c 'issue edit 101 .*--add-label status:parked' "$GH_LOG")/$(comments 101)"
want "  the ledger holds the new head only"      "90/head2" "$(awk -F'\t' '{ print $1 "/" $2 }' "$C/fix-parks.did.tsv" 2>/dev/null)"
echo "  a park whose label could not be set is not recorded: tried again"
fresh; base dev1 unit:success; spent 91 2 head0
pr 91 101 head1 BLOCKED unit:FAILURE:7001
rm -f "$FIX/gh/issue-101.json"; printf '{"number":101,"state":"OPEN","title":"t","labels":[{"name":"P1"}]}\n' > "$FIX/gh/issue-101.json"
printf '#!/usr/bin/env bash\ncase "$1 $2" in "issue edit") printf "%%s\\n" "$*" >> "$GH_LOG"; exit 1 ;; esac\nexec "%s" "$@"\n' "$BIN/gh-now" > "$BIN/gh-noedit"; chmod +x "$BIN/gh-noedit"
age 0; SWARM_GH="$BIN/gh-noedit" pass
want "  no park on the ledger"                   "" "$(cat "$C"/fix-parks.* 2>/dev/null)"
want "  and nothing posted"                      "0" "$(comments 101)"

echo "--- a ticket a person holds is left exactly as it is ---"
fresh; base dev1 unit:success; spent 92 2 head0; fix_issue 101 OPEN "status:blocked,P1"
pr 92 101 head1 BLOCKED unit:FAILURE:7001
age 0; pass; age 5; pass
want "held with status:blocked, its rounds spent: no label written" "0" "$(edits 101)"
want "  no park note"                            "0" "$(comments 101)"
want "  no call naming the ticket or its PR"     "0" "$(named 101 92)"
want_in "  it says who it waits on"              'rebuild: PR #92 left as it is — #101 waits on a person \(status:blocked\)' "$OUT"
echo "  the hold went on after the tick's read: the park reads again first, and writes nothing"
fresh; base dev1 unit:success; spent 93 2 head0
pr 93 101 head1 BLOCKED unit:FAILURE:7001
fix_issue 101 OPEN "status:blocked,P1"; mv "$FIX/gh/issue-101.json" "$FIX/gh/issue-101.now.json"; fix_issue 101 OPEN "status:in-review,P1"
age 0; pass
want "  no label written over it"                "0" "$(edits 101)"
want "  no park note"                            "0" "$(comments 101)"
want "  no park recorded"                        "" "$(cat "$C"/fix-parks.* 2>/dev/null)"
want_in "  it says so"                           'rebuild: PR #93 left as it is — #101 waits on a person \(status:blocked\); not parked over it' "$OUT"
echo "  the same for a fix round: a held ticket is never set back to ready"
fresh; base dev1 unit:success
pr 94 101 head1 BLOCKED unit:FAILURE:7001
fix_issue 101 OPEN "status:blocked,P1"; mv "$FIX/gh/issue-101.json" "$FIX/gh/issue-101.now.json"; fix_issue 101 OPEN "status:in-review,P1"
age 0; pass
want "  no label written"                        "0" "$(edits 101)"
want "  no fix round queued"                     "0" "$(adds 101)"
want "  none on the ledger"                      "" "$(rounds 94)"
echo "  the hold removed: the park is written"
fresh; base dev1 unit:success; spent 95 2 head0
pr 95 101 head1 BLOCKED unit:FAILURE:7001
age 0; pass
want "  parked"                                  "1" "$(grep -c 'issue edit 101 .*--add-label status:parked' "$GH_LOG")"
want "  with one read of its labels, the one the label write uses" "1" "$(grep -c '^issue view 101 ' "$GH_LOG")"

echo "--- every CI runner offline: what does not wait on CI still runs ---"
RUNNERS="$FIX/gh/api-repos_acme_widgets_actions_runners_per_page_100.json"
printf '{"total_count":1,"runners":[{"id":1,"status":"offline"}]}\n' > "$RUNNERS"
echo "  a half-built draft is resumed"
fresh; base dev1 unit:success; record 101 start plan
DRAFT=1 pr 80 101 head1 BLOCKED unit:FAILURE:7001
age 0; pass
want "  queued once to be resumed"               "1" "$(resumes 101)"
echo "  a clash gets its one update from its base, and no fix round"
fresh; base dev1 unit:success; accepts 96
pr 96 101 head1 DIRTY unit:SUCCESS:7001
age 0; pass
want "  its branch is updated once"              "1" "$(updates 96)"
want "  no fix round queued"                     "0" "$(fixes 101)"
echo "  a red PR is not sent back to its builder"
fresh; base dev1 unit:success
pr 97 101 head1 BLOCKED unit:FAILURE:7001
age 0; pass
want "  no fix round queued"                     "0" "$(fixes 101)"
want "  no round on the ledger"                  "" "$(rounds 97)"
want_in "  it says CI is down"                   'rebuild: PR #97 waits — every CI runner is offline' "$OUT"
echo "  a ticket a person holds stops its clock"
fresh; base dev1 unit:success; fix_issue 101 OPEN "status:needs-human,P1"
printf '98\t%s\tred\n' "$T0" > "$C/rebuild-clock.did.tsv"
pr 98 101 head1 BLOCKED unit:FAILURE:7001
age 0; pass
want "  its clock is stopped"                    "" "$(awk -F'\t' '$1 == 98' "$C/rebuild-clock.did.tsv" 2>/dev/null)"
rm -f "$RUNNERS"

if [ -z "${PLANT:-}" ] && [ -z "${NO_PLANTS:-}" ]; then
  echo "--- every rule's plant fails its case ---"
  for p in update-first update-pair update-made update-wait resume resume-once resume-cap resume-shipped park-once park-record park-head hold-park hold-fix hold-resume hold-labels; do
    PLANT=$p bash "$0" >/dev/null 2>&1; rc=$?
    want "plant $p: the suite fails"             "1" "$([ "$rc" -ne 0 ] && [ "$rc" -ne 3 ] && echo 1 || echo "rc=$rc")"
  done
fi

suite_end "$FAILED"
