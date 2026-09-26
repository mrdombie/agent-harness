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
#   $FIX/gh/prs-<key>.json   what a `gh pr list` matching <key> returns
#   $FIX/live.json           what the live view answers; ABSENT = no answer
set -uo pipefail

swarm_fixture() {
  FIX=$(mktemp -d)
  REPO="$FIX/repo"; STATE="$FIX/state"; BIN="$FIX/bin"
  GH_LOG="$FIX/gh.log"; SPAWNS="$FIX/spawns.log"
  mkdir -p "$REPO/.claude" "$STATE/runs" "$STATE/logs" "$STATE/swarm" "$BIN" "$FIX/gh"
  : > "$GH_LOG"; : > "$SPAWNS"

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
q=""; key=""; prev=""
for a in "$@"; do
  case "$prev" in -q|--jq) q="$a" ;; esac
  case "$a" in head:*) key="${a#head:}" ;; esac
  prev="$a"
done
key=${key//\//_}
emit() { # <file> — apply the -q expression if there was one
  if [ -n "$q" ]; then jq -r "$q" "$1"; else cat "$1"; fi
}
case "$1 $2" in
  "issue view")
    f="$FIX/gh/issue-$3.json"; [ -f "$f" ] || exit 1; emit "$f" ;;
  "pr list")
    f="$FIX/gh/prs-${key:-all}.json"; [ -f "$f" ] || f="$FIX/gh/prs-all.json"
    [ -f "$f" ] || { f="$FIX/gh/empty.json"; printf '[]\n' > "$f"; }
    emit "$f" ;;
  "issue list")
    f="$FIX/gh/issue-list.json"
    [ -f "$f" ] || { f="$FIX/gh/empty.json"; printf '[]\n' > "$f"; }
    emit "$f" ;;
  "issue create") echo "https://github.com/acme/widgets/issues/999" ;;
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
printf '%s\tbudget=%s\tbrief=%s\n' "$1" "${CLAIM_BUDGET_USD:-}" "${CLAIM_EXTRA:-}" >> "$SPAWNS"
echo "→ spawned claim-$1"
SH

  chmod +x "$BIN/gh" "$BIN/curl" "$BIN/spawn"

  export FIX REPO STATE BIN GH_LOG SPAWNS
  export PATH="$BIN:$PATH"
  export HARNESS_REPO_ROOT="$REPO" HARNESS_MAIN_REPO="$REPO" HARNESS_STATE_DIR="$STATE"
  export HARNESS_CFG_PATH="$REPO/.claude/harness.json"
  export HARNESS_LOGIN=tester CLAIM_AGENT="tester@fixture"
  export SWARM_SPAWN="$BIN/spawn" SWARM_GH="$BIN/gh" SWARM_CURL="$BIN/curl"
  export SWARM_LOAD=1
  unset GH_TOKEN
}

# An issue the stub can answer for: fix_issue <n> <state> <label,label…>
fix_issue() {
  local n=$1 st=$2 labels=${3:-}
  jq -n --arg s "$st" --arg l "$labels" --arg t "Ticket $n" \
    '{state:$s, title:$t, labels:($l|split(",")|map(select(length>0)|{name:.}))}' \
    > "$FIX/gh/issue-$n.json"
}

# fix_no_pr <ticket> — an empty open-PR answer for that ticket's branch
fix_no_pr() { printf '[]\n' > "$FIX/gh/prs-${BRANCH_PREFIX:-tkt-}$1_.json"; }

# A live-view answer: fix_live <programme> <count>  (no call = the view is down)
fix_live() {
  local p=$1 n=$2 i out="[]"
  out=$(jq -n --arg p "$p" --argjson n "$n" \
        '{live: [range($n) | {ticket:"x", project:$p, quietSec:10, startedAgoMin:5, steps:[]}], done: []}')
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
want_in() { # <label> <regex> <text>
  if printf '%s' "$3" | grep -qE "$2"; then ok "$1"; else bad "$1 — no /$2/ in: $(printf '%s' "$3" | tr '\n' '|')"; fi
}
want_not_in() { # <label> <regex> <text>
  if printf '%s' "$3" | grep -qE "$2"; then bad "$1 — found /$2/ in: $(printf '%s' "$3" | tr '\n' '|')"; else ok "$1"; fi
}
