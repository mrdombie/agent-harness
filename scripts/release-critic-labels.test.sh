#!/usr/bin/env bash
# release-critic-labels.test.sh — review.judge.duringReleaseLabels: while the release
# pause holds the critic, a ticket or PR carrying a listed label keeps it, run and
# blocking; any other stays paused; one whose labels cannot be read keeps it. With the
# key absent every answer is the old one, and no label is read.
# Run: bash "$0"
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/tests/lib/suite.sh" || exit 1
for v in $(env | sed -n 's/^\(GIT_[A-Z_]*\)=.*/\1/p'); do unset "$v"; done
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../swarm/tests/fixture.sh"
swarm_fixture; on_exit_keep_status 'rm -rf "$FIX"'
CFG="$HARNESS_CFG_PATH"; cp "$CFG" "$FIX/cfg.base"
PAUSE='.release = {nonBlockingChecks: ["Lesson / Every fix ships a lesson", "Design critic"], done: false}'
cfg()        { jq "$1" "$FIX/cfg.base" > "$CFG"; }
cfg_scoped() { cfg "$PAUSE"' | .review.judge.duringReleaseLabels = ["project:keep"]'; }
cfg_plain()  { cfg "$PAUSE"; }
export REPO_SLUG=acme/widgets
lib() { HARNESS_CFG="$CFG" bash -c '. "$1"; shift; "$@"' _ "$HERE/release-checks.sh" "$@"; }
rc()  { lib "$@" >/dev/null 2>&1; echo $?; }
reads() { grep -c 'issueOrPullRequest' "$GH_LOG"; }

fix_issue 101 OPEN "project:keep,P1"     # keeps the critic
fix_issue 102 OPEN "screen:new,P1"       # another screen ticket
                                          # 103: no answer — its labels cannot be read
for n in 11 12 13 41 42 55; do fix_issue "$n" OPEN ""; done   # the PRs, which carry no label of their own

echo "--- the predicate ---"
cfg_scoped
L101=$(lib release_labels_of 101); L102=$(lib release_labels_of 102); L103=$(lib release_labels_of 103)
want    "a ticket's labels, read"                         "P1,project:keep" "$L101"
want    "an unreadable ticket says so"                    "(unreadable)" "$L103"
want    "a read that fails whole says so"                 "(unreadable)" "$(REPO_SLUG= lib release_labels_of 101)"
want    "a listed label: the critic is not paused"        "1" "$(rc release_critic_paused "$L101")"
want    "another screen ticket: paused"                   "0" "$(rc release_critic_paused "$L102")"
want    "labels that cannot be read: not paused"          "1" "$(rc release_critic_paused "$L103")"
want    "no item (a sweep): the global answer, paused"    "0" "$(rc release_critic_paused)"
want    "a listed label: its check blocks"                "1" "$(rc release_check_nonblocking "Design critic" "$L101")"
want    "another ticket: its check warns"                 "0" "$(rc release_check_nonblocking "Design critic" "$L102")"
want    "other listed checks still warn for it"           "0" "$(rc release_check_nonblocking "Lesson / Every fix ships a lesson" "$L101")"
want    "the required list keeps the critic for it"       '["Code gates","Design critic"]' "$(lib release_blocking_required '["Code gates","Design critic"]' "$L101")"
want    "and loses it for another"                        '["Code gates"]' "$(lib release_blocking_required '["Code gates","Design critic"]' "$L102")"
want    "the critic is required of it"                    '["Design critic"]' "$(lib release_critic_required "$L101")"
want    "and not of another"                              '[]' "$(lib release_critic_required "$L102")"
want    "a PR and its ticket in one read"                 "1" "$(: > "$GH_LOG"; lib release_labels_of 55 101 >/dev/null; reads)"
cfg_scoped; cfg "$PAUSE"' | .release.done = true | .review.judge.duringReleaseLabels = ["project:keep"]'
want    "release done: nothing is added to the required list" '[]' "$(lib release_critic_required "$L101")"

echo "--- the key absent: exactly as today ---"
cfg_plain; : > "$GH_LOG"
want    "no label is read"                                "" "$(lib release_labels_of 101)"
want    "and nothing was asked of GitHub"                 "0" "$(reads)"
want    "a listed label's ticket stays paused"            "0" "$(rc release_critic_paused "P1,project:keep")"
want    "an unreadable one too"                           "0" "$(rc release_critic_paused "(unreadable)")"
want    "the non-blocking list is the global one" "$(lib release_nonblocking_json)" "$(lib release_nonblocking_json "P1,project:keep")"
want    "nothing is required of it"                       '[]' "$(lib release_critic_required "P1,project:keep")"

echo "--- the merge gate's red: a red critic is red for a ticket that keeps it ---"
fix_required "Code gates"
critic_red() { # <pr> <ticket>
  jq -nc --argjson n "$1" --arg br "tkt-$2/work" '{number:$n, headRefName:$br, headRefOid:"h", baseRefName:"develop",
    isDraft:false, mergeable:"MERGEABLE", mergeStateStatus:"CLEAN", labels:[],
    statusCheckRollup:[{__typename:"CheckRun", name:"Code gates", status:"COMPLETED", conclusion:"SUCCESS", startedAt:"2026-10-21T10:00:00Z"},
                       {__typename:"StatusContext", context:"Design critic", state:"FAILURE", createdAt:"2026-10-21T10:00:00Z"}]}'
}
verdict() { # <pr> <ticket>
  HARNESS_CFG="$CFG" bash -c '. "$1/release-checks.sh"; . "$1/pr-red.sh"
    cl=$(release_labels_of "$3" "$4")
    pr_red_verdict "$2" approval "$(release_nonblocking_json "$cl")" "$(release_critic_required "$cl")" | cut -f1' _ "$HERE" "$(critic_red "$1" "$2")" "$1" "$2"
}
cfg_scoped
want    "the ticket keeps the critic: red"                "red" "$(verdict 11 101)"
want    "another ticket: green"                           "green" "$(verdict 12 102)"
want    "its labels unreadable: red"                      "red" "$(verdict 13 103)"
cfg_plain
want    "the key absent: green, as today"                 "green" "$(verdict 11 101)"

echo "--- the driver: the critic's findings are blockers for a ticket that keeps it ---"
cat > "$FIX/findings.sh" <<'SH'
#!/usr/bin/env bash
printf 'major\t1\tThe header narrates\n'
SH
chmod +x "$FIX/findings.sh"
crit() { # <ticket>
  KIT="$HERE/.." DRIVER_LOOKUP_RETRY_SEC=0 bash -c '
    . "$KIT/driver/driver-env.sh" >/dev/null 2>&1 || exit 9
    . "$KIT/driver/facts.sh" || exit 9
    driver_state_get() { case "$2" in pr) echo 11 ;; *) echo "" ;; esac; }
    DRIVER_SCREEN_FINDINGS="$1" driver_fact_critic_findings "$2"' _ "$FIX/findings.sh" "$1" 2>&1
}
cfg_scoped
want_in "the ticket keeps it: its findings block"         '^The independent design critic failed PR #11 on these' "$(crit 101)"
want_in "another ticket: off until the release"           '^\(none — design critic: off until the release' "$(crit 102)"
want_in "a ticket that cannot be read: its findings block" '^The independent design critic failed PR #11 on these' "$(crit 103)"
cfg_plain
want_in "the key absent: off for every ticket, as today"  '^\(none — design critic: off until the release' "$(crit 101)"

echo "--- the sweep judges only the PRs that keep it ---"
J="$HERE/critic-judge.sh"
jq -n '[[41,101],[42,102]] | map({number:.[0], headRefName:"tkt-\(.[1])-x", headRefOid:("a" * 40), isDraft:false, body:"", labels:[],
        mergeStateStatus:"CLEAN", statusCheckRollup:[{context:"Design critic", state:"PENDING"}]})' > "$FIX/gh/prs-all.json"
export CRITIC_JUDGE_DIR="$FIX/judge" CRITIC_JUDGE_ROOM=5 CRITIC_JUDGE_PRS_MAX_AGE=0
starts() { bash "$J" sweep --dry-run 2>/dev/null | grep -o 'would judge PR #[0-9]*' | grep -o '[0-9]*$' | tr '\n' ' '; }
cfg_scoped
want    "the PR whose ticket keeps it is judged, the other not" "41 " "$(starts)"
want    "and the sweep is not reported paused"            "1" "$(bash "$J" paused >/dev/null 2>&1; echo $?)"
# `pr view` answers from the open-PR copy, so a run reads its PR's branch and ticket.
mkdir -p "$FIX/bin-pr"; cat > "$FIX/bin-pr/gh" <<'SH'
#!/usr/bin/env bash
if [ "$1 $2" = "pr view" ]; then printf '%s\n' "$*" >> "$GH_LOG"; jq -c --argjson n "$3" '.[] | select(.number == $n) | . + {state: "OPEN"}' "$FIX/gh/prs-all.json"; exit 0; fi
exec "$BIN/gh" "$@"
SH
chmod +x "$FIX/bin-pr/gh"
judge() { SWARM_GH="$FIX/bin-pr/gh" CRITIC_JUDGE_LAUNCHER=coordinator bash "$J" run "$1" 2>&1; }
want_in     "a run on the other PR stops, paused"         'PR #42: design critic: paused until the release' "$(judge 42)"
want_not_in "a run on the kept PR goes on past the pause" 'paused until the release' "$(judge 41)"
cfg_plain
want    "the key absent: no judge, as today"              "" "$(starts)"
want    "and paused, as today"                            "0" "$(bash "$J" paused >/dev/null 2>&1; echo $?)"

suite_end "$FAILED"
