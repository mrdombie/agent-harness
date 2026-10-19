#!/usr/bin/env bash
# fixture.sh — the world every swarm test runs against: a throwaway repo with a
# harness.json, a throwaway state dir, and recorders standing in for gh, curl and
# the spawner.
#
# Sourced by each suite. `swarm_fixture` sets it up and exports:
#   FIX      the temp root (removed by the caller's trap)
#   REPO     a real git repo holding .claude/harness.json
#   STATE    the state dir: runs/, logs/, swarm/
#   BIN      the stub directory, first on PATH
#   GH_LOG   one line per gh call
#   SPAWNS   one line per ticket the spawner was asked to launch
#
# The stubs answer from files the test writes, so a suite never touches the
# network and never starts an agent:
#   $FIX/gh/issue-<n>.json   what `gh issue view <n>` returns
#   $FIX/gh/prs-<key>.json   what a `gh pr list` matching <key> returns; prs-all.json
#                            also answers the paged open-PR read (gh_open_prs)
#   $FIX/gh/api-<endpoint>.json  what `gh api <endpoint>` returns; / ? & = -> _
#   $FIX/gh/pr-commits-<n>.json  PR <n>'s node in a batched commits read (gh_pr_commits_batch)
#   $FIX/live.json           what the live view answers; ABSENT = no answer
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/time.sh" || exit 1

swarm_fixture() {
  FIX=$(mktemp -d)
  REPO="$FIX/repo"; STATE="$FIX/state"; BIN="$FIX/bin"
  GH_LOG="$FIX/gh.log"; SPAWNS="$FIX/spawns.log"
  export GH_OPEN_PRS_FAKE; GH_OPEN_PRS_FAKE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/scripts/fixtures/gh-open-prs.sh"
  mkdir -p "$REPO/.claude" "$STATE/runs" "$STATE/logs" "$STATE/swarm" "$BIN" "$FIX/gh"
  : > "$GH_LOG"; : > "$SPAWNS"
  # The integration branch is green unless a test says otherwise (fix_trunk).
  printf '{"check_runs":[{"name":"build","conclusion":"success"}]}\n' \
    > "$FIX/gh/api-repos_acme_widgets_commits_develop_check-runs_per_page_100.json"

  git -C "$REPO" init -q
  cat > "$REPO/.claude/harness.json" <<'JSON'
{
  "repo": "acme/widgets",
  "integrationBranch": "develop",
  "branchPrefix": "tkt-",
  "stateDir": "/nonexistent-must-be-overridden",
  "sisterRepos": [],
  "labels": {
    "drafting": "status:drafting",
    "ready": "status:ready",
    "claimed": "status:claimed",
    "inReview": "status:in-review",
    "gated": "status:gated",
    "partial": "status:partial",
    "blocked": "status:blocked",
    "externalBlocked": "status:external-blocked",
    "parked": "status:parked",
    "needsHuman": "status:needs-human",
    "pmDecision": "status:pm-decision",
    "pmTrack": "status:pm-track",
    "hold": "needs:human-approval",
    "decision": ["status:pm-decision"]
  }
}
JSON

  # ---- stub: gh ---------------------------------------------------------------
  cat > "$BIN/gh" <<'SH'
#!/usr/bin/env bash
# Records every call, answers from $FIX/gh/. An unknown call answers empty at
# exit 0 so a script under test is never blocked by a question this stub has not
# been taught — the assertion is on the recorded line, not on the stub's wit.
printf '%s\n' "$*" >> "$GH_LOG"
# What is left of the allowance, as GitHub's headers say it, even while it refuses:
# $FIX/gh/allowance holds "<remaining> <limit> <reset-epoch>"; absent, the reading fails.
case "$1 $2 $*" in "api graphql "*rateLimit*)
  [ -s "$FIX/gh/allowance" ] || exit 1
  read -r left lim reset < "$FIX/gh/allowance"
  printf 'HTTP/2.0 200 OK\r\nX-Ratelimit-Limit: %s\r\nX-Ratelimit-Remaining: %s\r\nX-Ratelimit-Reset: %s\r\nX-Ratelimit-Resource: graphql\r\n\r\n{"data":{}}\n' "$lim" "$left" "$reset"
  [ -f "$FIX/gh/ratelimit" ] && exit 1; exit 0 ;;
esac
# $FIX/gh/ratelimit present: GitHub refusing the token, as it does for a secondary limit.
if [ -f "$FIX/gh/ratelimit" ]; then
  echo "GraphQL: API rate limit already exceeded for user ID 1." >&2; exit 1
fi
q=""; key=""; labels=""; prev=""
for a in "$@"; do
  case "$prev" in -q|--jq) q="$a" ;; --label) labels="$labels${labels:+,}$a" ;; esac
  case "$a" in head:*) key="${a#head:}" ;; esac
  prev="$a"
done
key=${key//\//_}
emit() { # <file> — apply the -q expression if there was one
  if [ -n "$q" ]; then jq -r "$q" < "$1"; else cat "$1"; fi
}
case "$1 $2" in
  "issue view")
    f="$FIX/gh/issue-$3.json"; [ -f "$f" ] || exit 1; emit "$f" ;;
  "pr list")
    f="$FIX/gh/prs-${key:-all}.json"; [ -f "$f" ] || f="$FIX/gh/prs-all.json"
    [ -f "$f" ] || { f="$FIX/gh/empty.json"; printf '[]\n' > "$f"; }
    emit "$f" ;;
  "issue list")
    # Keyed by the --label arguments, so the "what is ready" question and the
    # "who is in this programme" question can be given different answers.
    f="$FIX/gh/issue-list-$labels.json"
    [ -f "$f" ] || f="$FIX/gh/issue-list.json"
    [ -f "$f" ] || { f="$FIX/gh/empty.json"; printf '[]\n' > "$f"; }
    emit "$f" ;;
  "label list")
    f="$FIX/gh/labels.json"; [ -f "$f" ] || { f="$FIX/gh/empty.json"; printf '[]\n' > "$f"; }
    emit "$f" ;;
  "issue create") echo "https://github.com/acme/widgets/issues/999" ;;
  "api graphql")
    # The open-PR read (gh_open_prs), paged, answered from prs-all.json.
    case "$*" in *'pullRequests(states:[OPEN]'*) exec bash "$GH_OPEN_PRS_FAKE" "$FIX/gh/prs-all.json" "$@" ;; esac
    # A batched issue read (scripts/gh-batch.sh): each iN alias answered from
    # issue-N.json, an unknown number null, the way GitHub answers one.
    query=""; for a in "$@"; do case "$a" in query=*) query="${a#query=}" ;; esac; done
    nums=$(printf '%s' "$query" | grep -oE 'i[0-9]+:issueOrPullRequest' | sed 's/^i//; s/:.*//')
    heads=$(printf '%s' "$query" | grep -oE 'b[0-9]+:pullRequests\(headRefName:"[^"]*"' | sed 's/:pullRequests(headRefName:"/ /; s/"$//')
    # A batched PR-commits read: each pN alias answered from pr-commits-N.json, absent null.
    pcs=$(printf '%s' "$query" | grep -oE 'p[0-9]+:pullRequest\(number:' | sed 's/^p//; s/:.*//')
    [ -n "$nums$heads$pcs" ] || exit 1
    # $FIX/gh/graphql-fail-N: a request naming PR N fails whole, as one chunk.
    for n in $pcs; do [ -f "$FIX/gh/graphql-fail-$n" ] && exit 1; done
    out='{}'
    for n in $pcs; do
      f="$FIX/gh/pr-commits-$n.json"
      if [ -f "$f" ]; then out=$(jq -c --arg k "p$n" --slurpfile p "$f" '. + {($k): $p[0]}' <<<"$out")
      else out=$(jq -c --arg k "p$n" '. + {($k): null}' <<<"$out"); fi
    done
    # A batched PR read: each bN alias answered from the file `pr list --head` would read.
    while read -r alias head; do
      [ -n "$alias" ] || continue
      f="$FIX/gh/prs-${head//\//_}.json"; [ -f "$f" ] || f="$FIX/gh/prs-all.json"
      if [ -f "$f" ]; then
        out=$(jq -c --arg k "$alias" --slurpfile p "$f" '. + {($k): {nodes: [$p[0][] | {number, state}]}}' <<<"$out")
      else out=$(jq -c --arg k "$alias" '. + {($k): {nodes: []}}' <<<"$out"); fi
    done <<<"$heads"
    for n in $nums; do
      f="$FIX/gh/issue-$n.json"
      if [ -f "$f" ]; then
        out=$(jq -c --arg k "i$n" --argjson n "$n" --slurpfile i "$f" \
          '. + {($k): ($i[0] | {number: $n, state, title: (.title // ""), labels: {nodes: (.labels // [])}} + (if has("body") then {body} else {} end))}' <<<"$out")
      else out=$(jq -c --arg k "i$n" '. + {($k): null}' <<<"$out"); fi
    done
    jq -c '{data: {repository: .}}' <<<"$out" ;;
  "api "*|"api")
    # Keyed by the endpoint with every / and ? flattened, so "the commits on the
    # trunk" and "the branch compared with the trunk" can answer differently.
    f="$FIX/gh/api-$(printf '%s' "$2" | tr '/?&=' '____').json"
    [ -f "$f" ] || exit 1
    emit "$f" ;;
  *) : ;;
esac
exit 0
SH

  # ---- stub: curl (the live view) --------------------------------------------
  cat > "$BIN/curl" <<'SH'
#!/usr/bin/env bash
# Answers with $FIX/live.json when it exists. When it does NOT, it fails the way
# a down live view fails — empty output, non-zero — which is the case the
# scheduler has to read as "busy", never as "no agents running".
[ -f "$FIX/live.json" ] || exit 7
cat "$FIX/live.json"
SH

  # ---- stub: the spawner ------------------------------------------------------
  cat > "$BIN/spawn" <<'SH'
#!/usr/bin/env bash
# The brief is flattened onto ONE line: a run is one row, so `grep -c .` counts
# spawns rather than the lines of whatever brief they carried.
printf '%s\tbudget=%s\tbrief=%s\n' "$1" "${CLAIM_BUDGET_USD:-}" \
  "$(printf '%s' "${CLAIM_EXTRA:-}" | tr '\n' ' ')" >> "$SPAWNS"
echo "→ spawned claim-$1"
SH

  # ---- stub: gh whose issue edits stick ---------------------------------------
  # The stub above, except an --add-label / --remove-label changes what the next
  # `issue view` of that ticket reads. For suites where a label IS the state.
  cat > "$BIN/gh-labels" <<'SH'
#!/usr/bin/env bash
if [ "$1 $2" = "issue edit" ] && [ -f "$FIX/gh/issue-$3.json" ]; then
  f="$FIX/gh/issue-$3.json"; prev=""
  for a in "$@"; do
    case "$prev" in
      --add-label)    jq --arg l "$a" '.labels = (((.labels // []) + [{name:$l}]) | unique_by(.name))' "$f" > "$f.t" && mv "$f.t" "$f" ;;
      --remove-label) jq --arg l "$a" '.labels = ((.labels // []) | map(select(.name != $l)))' "$f" > "$f.t" && mv "$f.t" "$f" ;;
    esac
    prev="$a"
  done
fi
exec "$BIN/gh" "$@"
SH

  chmod +x "$BIN/gh" "$BIN/curl" "$BIN/spawn" "$BIN/gh-labels"

  export FIX REPO STATE BIN GH_LOG SPAWNS
  export PATH="$BIN:$PATH"
  export HARNESS_REPO_ROOT="$REPO" HARNESS_MAIN_REPO="$REPO" HARNESS_STATE_DIR="$STATE"
  export HARNESS_CFG_PATH="$REPO/.claude/harness.json"
  export HARNESS_LOGIN=tester CLAIM_AGENT="tester@fixture"
  export SWARM_SPAWN="$BIN/spawn" SWARM_GH="$BIN/gh" SWARM_CURL="$BIN/curl"
  export SWARM_LOAD=1 SWARM_IDLE=90
  # Each case writes its own PRs: the shared copy is read fresh unless a case says otherwise.
  export NEEDSME_PRS_MAX_AGE=0 SWARM_PRS_MAX_AGE=0 SWARM_STATUS_PRS_MAX_AGE=0
  unset GH_TOKEN
}

# An issue the stub can answer for: fix_issue <n> <state> <label,label…>
fix_issue() {
  local n=$1 st=$2 labels=${3:-}
  jq -n --argjson n "$n" --arg s "$st" --arg l "$labels" --arg t "Ticket $n" \
    '{number:$n, state:$s, title:$t, labels:($l|split(",")|map(select(length>0)|{name:.}))}' \
    > "$FIX/gh/issue-$n.json"
}

# fix_no_pr <ticket> — an empty open-PR answer for that ticket's branch
fix_no_pr() { printf '[]\n' > "$FIX/gh/prs-${BRANCH_PREFIX:-tkt-}$1_.json"; }

# A live-view answer: fix_live <programme> <count>  (no call = the view is down)
fix_live() { # <programme> <count> [taken-at ISO]
  local p=$1 n=$2 at=${3:-$(swarm_iso "${SWARM_NOW:-$(date +%s)}")} out
  out=$(jq -n --arg p "$p" --argjson n "$n" --arg at "$at" \
        '{at: $at, live: [range($n) | {ticket:"x", project:$p, quietSec:10, startedAgoMin:5, steps:[]}], done: []}')
  printf '%s\n' "$out" > "$FIX/live.json"
}
fix_live_down() { rm -f "$FIX/live.json"; }

# A live run record for <ticket> owned by a pid that is alive (this shell).
fix_running() { # <ticket>
  printf '{"run_id":"claim-%s-t","ticket":"%s","child_pid":%s,"started_at":"%s"}\n' \
    "$1" "$1" "$$" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$STATE/runs/claim-$1-t.json"
}

# --- the tiny assertion kit every suite shares --------------------------------
FAILED=0
ok()   { printf 'OK       %s\n' "$1"; }
bad()  { printf 'MISMATCH %s\n' "$1"; FAILED=1; }
want() { # <label> <expected> <actual>
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 — wanted '$2', got '$3'"; fi
}
# `--` before the pattern: a pattern that starts with a dash is a pattern, not
# a grep flag, and without it `want_in "…" '--push'` reports a usage error as a
# failed assertion — a test that cannot see its subject looks like a bug in it.
# A here-string, not a pipe: under pipefail grep -q's early exit SIGPIPEs printf.
want_in() { # <label> <regex> <text>
  if grep -qE -- "$2" <<<"$3"; then ok "$1"; else bad "$1 — no /$2/ in: $(printf '%s' "$3" | tr '\n' '|')"; fi
}
want_not_in() { # <label> <regex> <text>
  if grep -qE -- "$2" <<<"$3"; then bad "$1 — found /$2/ in: $(printf '%s' "$3" | tr '\n' '|')"; else ok "$1"; fi
}

# fix_issue_list <label,label…> <json array> — what `gh issue list --label …`
# answers for exactly that label set.
fix_issue_list() { printf '%s\n' "$2" > "$FIX/gh/issue-list-$1.json"; }

# fix_ready <programme> <ticket…> — the two answers a scheduler pass needs:
# the ready list (which claimable-issues.sh reads) and the programme's members.
fix_ready() {
  local p=$1; shift
  local arr; arr=$(printf '%s\n' "$@" | jq -R 'tonumber' | jq -s --arg p "$p" \
    'map({number: ., title: "Ticket \(.)", labels: [{name:"status:ready"},{name:"P1"},{name:"area:OPS"},{name:("project:"+$p)}]})')
  fix_issue_list "status:ready" "$arr"
  fix_issue_list "project:$p" "$arr"
  fix_issue_list "status:in-review" "[]"
  local t; for t in "$@"; do fix_issue "$t" OPEN "status:ready,project:$p"; done
}

# fix_trunk <green|red|unreadable> — what the integration branch's newest commit reports.
fix_trunk() {
  local f="$FIX/gh/api-repos_acme_widgets_commits_develop_check-runs_per_page_100.json"
  case "$1" in
    green) printf '{"check_runs":[{"name":"build","conclusion":"success"}]}\n' > "$f" ;;
    red)   printf '{"check_runs":[{"name":"build","conclusion":"failure"},{"name":"lint","conclusion":"success"}]}\n' > "$f" ;;
    unreadable) rm -f "$f" ;;
  esac
}

# ---- pull requests, comments and finished runs -------------------------------
# The repair watcher reads three things the queue never does: the open pull
# requests, an issue's comments, and the runs that have already ENDED.

# fix_prs <tsv…> — one row per open PR:
#   <pr> <ticket> <sha> <mergeState> <pendingChecks> <failedCheckName-or-->
# mergeState CLEAN + 0 pending + "-" failed is a healthy PR nothing should touch.
fix_prs() {
  local out="[]" pr t sha ms pend fail row
  for row in "$@"; do
    set -- $row; pr=$1; t=$2; sha=$3; ms=$4; pend=$5; fail=${6:--}
    out=$(printf '%s' "$out" | jq \
      --argjson n "$pr" --arg br "${BRANCH_PREFIX:-tkt-}$t/work" --arg sha "$sha" \
      --arg ms "$ms" --argjson pend "$pend" --arg fail "$fail" '
      . + [{
        number: $n, headRefName: $br, headRefOid: $sha, isDraft: false,
        mergeStateStatus: $ms,
        statusCheckRollup: (
          [range($pend) | {name:"pending", status:"IN_PROGRESS", conclusion:null}]
          + (if $fail == "-" then [] else [{name:$fail, status:"COMPLETED", conclusion:"FAILURE"}] end)
          + [{name:"green", status:"COMPLETED", conclusion:"SUCCESS"}])
      }]')
  done
  printf '%s\n' "$out" > "$FIX/gh/prs-all.json"
}

# fix_pr_status <pr> <context> <state> — add a commit status (StatusContext) to a PR
# fix_prs wrote: it carries a state and no status or conclusion, as GitHub returns it.
fix_pr_status() {
  local f="$FIX/gh/prs-all.json"
  jq --argjson n "$1" --arg c "$2" --arg s "$3" \
    'map(if .number == $n then .statusCheckRollup += [{__typename:"StatusContext", context:$c, state:$s}] else . end)' \
    "$f" > "$f.tmp" && mv "$f.tmp" "$f"
}

# fix_comments <ticket> <body…> — the comments `gh issue view --json comments` returns
fix_comments() {
  local n=$1; shift
  local c; c=$(printf '%s\n' "$@" | jq -R '{body: .}' | jq -s '.')
  local f="$FIX/gh/issue-$n.json"
  [ -f "$f" ] || fix_issue "$n" OPEN ""
  jq --argjson c "$c" '.comments = $c' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
}

# fix_done <ticket> <endedAgoMin> <summary> [infra] — a finished run in the live
# view's `done` list, which is where an infrastructure death is visible.
fix_done() {
  [ -f "$FIX/live.json" ] || fix_live "" 0
  jq --arg t "$1" --argjson a "$2" --arg s "$3" --argjson i "${4:-false}" \
    '.done += [{ticket:$t, endedAgoMin:$a, summary:$s, exit:1, infra:$i}]' \
    "$FIX/live.json" > "$FIX/live.json.tmp" && mv "$FIX/live.json.tmp" "$FIX/live.json"
}

# fix_at <epoch> — move the clock AND re-stamp the live view, so a test that
# jumps forward does not accidentally assert on the staleness rule instead.
#
# It stamps through the SAME helper the code under test reads the clock with
# (swarm/time.sh). Written twice, the two would disagree on Linux — where
# `date -r <epoch>` reads a file — and every jumped-forward case would quietly
# become a staleness case, green on one runner and red on the other.
fix_at() {
  export SWARM_NOW="$1"
  if [ -f "$FIX/live.json" ]; then
    jq --arg at "$(swarm_iso "$1")" '.at = $at' "$FIX/live.json" \
      > "$FIX/live.json.tmp" && mv "$FIX/live.json.tmp" "$FIX/live.json"
  fi
}
