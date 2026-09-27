#!/usr/bin/env bash
# fixture.sh — the world every driver test runs against: a throwaway repo with a
# harness.json, a throwaway state dir, and recorders standing in for the agent
# runner, gh and the claim lock.
#
# Sourced by each suite. `driver_fixture` sets up and exports:
#   FIX       the temp root (removed by the caller's trap)
#   REPO      a real git repo holding .claude/harness.json — worktrees cut from it
#   STATE     the state dir: driver/, runs/, logs/
#   BIN       the stub directory, first on PATH
#   GH_LOG    one line per gh call
#   CLAUDE_LOG one line per agent invocation
#
# The stubs answer from files the test writes, so a suite never starts an agent:
#   $FIX/ai/<step>.jsonl   the stream-json transcript `claude -p` "produced"
#   $FIX/gh/issue-<n>.json what `gh issue view <n>` returns
#
# ONE THING DOES leave the machine: the contract check shells out to `npx --yes
# ajv-cli@5` once per schema case, because briefs/validate.sh is called rather than
# re-derived and that is the whole point of the call. With a warm npx cache it is
# about a second each; with no network the suite goes red, which is honest and is
# not the same as a suite that cannot run offline being broken. `BRIEFS_AJV` points
# it at an installed copy.
#
# The repo is REAL git, not a stub. The red-before-green proof is the driver's
# headline guarantee and it is made of commits and worktrees; a stubbed git
# would test the stub.
set -uo pipefail

driver_fixture() {
  FIX=$(mktemp -d)
  REPO="$FIX/repo"; STATE="$FIX/state"; BIN="$FIX/bin"
  GH_LOG="$FIX/gh.log"; CLAUDE_LOG="$FIX/claude.log"
  mkdir -p "$REPO/.claude" "$STATE/driver" "$STATE/runs" "$STATE/logs" "$BIN" "$FIX/gh" "$FIX/ai"
  : > "$GH_LOG"; : > "$CLAUDE_LOG"

  git -C "$REPO" init -q -b develop
  git -C "$REPO" config user.email t@example.invalid
  git -C "$REPO" config user.name  Tester
  cat > "$REPO/.claude/harness.json" <<'JSON'
{
  "repo": "acme/widgets",
  "integrationBranch": "develop",
  "branchPrefix": "tkt-",
  "stateDir": "/nonexistent-must-be-overridden",
  "sisterRepos": [],
  "gates": { "lint": "echo lint-ok", "test": "echo test-ok" },
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
  git -C "$REPO" add -A
  git -C "$REPO" commit -qm "root"

  # ---- stub: gh ---------------------------------------------------------------
  cat > "$BIN/gh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_LOG"
# Induced failure, so "GitHub said no" is a case a suite can build. Every write in
# this kit is wrapped in `|| true`, which means the difference between a completed
# hand-off and a total outage is invisible unless a test can produce the outage.
# $FIX/gh-fail holds one "<noun> <verb>" per line, e.g. `pr create`.
if [ -f "$FIX/gh-fail" ] && grep -qxF "$1 $2" "$FIX/gh-fail"; then
  echo "gh: refused $1 $2 (induced)" >&2; exit 1
fi
q=""; head=""; prev=""
for a in "$@"; do
  case "$prev" in -q|--jq) q="$a" ;; --head) head="$a" ;; esac
  prev="$a"
done
mark() { printf '%s' "$FIX/pr-created-$(printf '%s' "$1" | tr '/' '_')"; }
emit() { if [ -n "$q" ]; then jq -r "$q" "$1"; else cat "$1"; fi; }
case "$1 $2" in
  "issue view") f="$FIX/gh/issue-$3.json"; [ -f "$f" ] || exit 1; emit "$f" ;;
  "issue create") echo "https://github.com/acme/widgets/issues/999" ;;
  "pr create")  : > "$(mark "$head")"; echo "https://github.com/acme/widgets/pull/42" ;;
  "pr list")    f="$FIX/gh/prs.json"; [ -f "$f" ] || printf '[]\n' > "$f"; emit "$f" ;;
  "pr view")
    # A pull request exists only when one was created. `pr view` on a branch with
    # none exits non-zero, which is how a caller can tell a created PR from a
    # swallowed failure — the stub has to do the same or that check is untestable.
    # Keyed on a SUCCESSFUL create, not on the log. Every call is logged before the
    # induced-failure check, so reading the log made a refused create look like a
    # pull request that exists — and the very case being built then passed.
    # PER BRANCH. A suite-wide marker is set by the first case that creates a pull
    # request, so every later case reads as having one — which is how the very case
    # being built here passed against the defect twice.
    if [ -f "$(mark "$3")" ]; then
      f="$FIX/gh/pr-view.json"; [ -f "$f" ] || printf '{"number":42,"isDraft":true}\n' > "$f"; emit "$f"
    else
      echo "gh: no pull requests found" >&2; exit 1
    fi ;;
  *) : ;;
esac
exit 0
SH

  # ---- stub: the agent runner --------------------------------------------------
  # Answers with the transcript the test wrote for that step. The step name is
  # passed by the driver as --name, which is also how the stub finds its script.
  cat > "$BIN/claude" <<'SH'
#!/usr/bin/env bash
step=""; prev=""
for a in "$@"; do case "$prev" in --name) step="$a" ;; esac; prev="$a"; done
printf '%s\n' "$step" >> "$CLAUDE_LOG"
f="$FIX/ai/$step.jsonl"
[ -f "$f" ] || { echo "no transcript for step '$step'" >&2; exit 3; }
cat "$f"
SH

  chmod +x "$BIN/gh" "$BIN/claude"

  export FIX REPO STATE BIN GH_LOG CLAUDE_LOG
  export PATH="$BIN:$PATH"
  export HARNESS_REPO_ROOT="$REPO" HARNESS_MAIN_REPO="$REPO" HARNESS_STATE_DIR="$STATE"
  export HARNESS_CFG_PATH="$REPO/.claude/harness.json"
  export HARNESS_LOGIN=tester CLAIM_AGENT="tester@fixture"
  export SWARM_GH="$BIN/gh" SWARM_CURL=/usr/bin/false SWARM_LOAD=1
  export DRIVER_CLAUDE="$BIN/claude"
  export DRIVER_BRIEFS="$FIX/briefs"
  mkdir -p "$DRIVER_BRIEFS/schemas"
  # Anything the OPERATOR'S shell exports that would let a suite be answered by
  # the real world instead of this one. CLAIM_REPO is the dangerous one: the claim
  # lock resolves it ahead of the working directory, so a session that happens to
  # export it makes every `holds` and `acquire` in the suite operate on a real
  # repository — and the peer-claim refusals then measure that repo's refs rather
  # than the fixture's. A test that can be answered from outside its fixture is
  # not a test of the code; it is a test of the machine it ran on.
  unset GH_TOKEN CLAIM_REPO CLAIM_AGENT_PID CLAIM_RUN_ID CLAIM_RUN_LOG CLAIM_EXTRA
  unset HARNESS_SISTER_REPO HARNESS_CFG_REF HARNESS_INTEGRATION_BRANCH HARNESS_LEGACY_ENV_PREFIX
  # BRIEFS_AJV replaces the validator outright and BRIEFS_SCHEMAS moves the contracts,
  # so an operator exporting either answers the contract cases from outside the fixture.
  # `BRIEFS_AJV=/bin/true` makes every refusal case return 0.
  unset BRIEFS_AJV BRIEFS_SCHEMAS DRIVER_VALIDATE
  export CLAIM_REPO="$REPO"
}

# ---- writing an AI answer ----------------------------------------------------
# fix_ai <step> <json-result> [skill-invoked]
#
# Builds the stream-json transcript `claude -p --output-format stream-json` emits:
# assistant turns carrying content blocks, then one result line. When a skill is
# named, a Skill tool_use block goes in — which is the ONE thing the driver reads
# the transcript for.
fix_ai() {
  # One name per line: bash expands the whole `local` command before it assigns
  # any of it, so `f="…/$step.jsonl"` on the same line reads the OUTER step —
  # unset, and under `set -u` that aborts the suite inside the fixture.
  local step="$1" result="$2" skill="${3:-}"
  local f="$FIX/ai/$step.jsonl"
  : > "$f"
  if [ -n "$skill" ]; then
    jq -nc --arg s "$skill" \
      '{type:"assistant", message:{content:[{type:"tool_use", name:"Skill", input:{skill:$s}}]}}' >> "$f"
  fi
  jq -nc --arg r "$result" '{type:"result", subtype:"success", is_error:false, result:$r}' >> "$f"
}

# fix_brief <step> <skill-or-empty> [body] — a brief file the driver will read.
# The `skill:` front-matter line is how a brief names the Skill the driver then
# insists on seeing in the transcript.
fix_brief() {
  local step="$1" skill="${2:-}" body="${3:-Do the $1 step.}"
  { echo '---'
    echo "step: $step"
    [ -n "$skill" ] && echo "skill: $skill"
    echo '---'
    echo "$body"
  } > "$DRIVER_BRIEFS/$step.md"
}

# fix_schema <step> <json-schema> — the schema #10886 owns; absent is normal.
fix_schema() { printf '%s\n' "$2" > "$DRIVER_BRIEFS/schemas/$1.json"; }

# fix_gh_fail <noun verb…> — make those gh writes fail, the way an expired token,
# a protected base or a rate limit does. No call: everything succeeds.
fix_gh_fail() { printf '%s\n' "$@" > "$FIX/gh-fail"; }
fix_gh_ok()   { rm -f "$FIX/gh-fail"; }

# fix_issue <n> <state> <labels-csv>
fix_issue() {
  jq -n --arg s "$2" --arg l "${3:-}" --arg t "Ticket $1" \
    '{number:($ARGS.positional[0]|tonumber), state:$s, title:$t,
      labels:($l|split(",")|map(select(length>0)|{name:.})), body:"spec"}' \
    --args "$1" > "$FIX/gh/issue-$1.json"
}

# --- the tiny assertion kit every suite shares --------------------------------
FAILED=0
ok()   { printf 'OK       %s\n' "$1"; }
bad()  { printf 'MISMATCH %s\n' "$1"; FAILED=1; }
want() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 — wanted '$2', got '$3'"; fi; }
want_in() {
  if printf '%s' "$3" | grep -qE -- "$2"; then ok "$1"; else bad "$1 — no /$2/ in: $(printf '%s' "$3" | tr '\n' '|')"; fi
}
want_not_in() {
  if printf '%s' "$3" | grep -qE -- "$2"; then bad "$1 — found /$2/ in: $(printf '%s' "$3" | tr '\n' '|')"; else ok "$1"; fi
}
