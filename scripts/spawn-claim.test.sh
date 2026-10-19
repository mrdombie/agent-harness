#!/usr/bin/env bash
# Fixture test for spawn-claim.sh — WHERE a spawned agent starts.
#
# WHY THIS EXISTS
#   Claude Code resolves a project's skills, its hookify guard rules, its
#   reviewer subagents and its CLAUDE.md from the cwd. The spawner used to cd
#   into the shared object-store clone, whose loose working tree nothing ever
#   updates. Measured 2026-09-27: that tree was 210 commits behind, so every
#   spawned run loaded a /finish of 682 lines against the branch's 1,170, six of
#   twenty guard rules, and two reviewer briefs 45 and 20 lines short. Nothing
#   failed; the agents simply ran month-old tooling.
#
#   A stale tree and a current one are indistinguishable from the outside, so
#   every case below PLANTS a file on the integration branch AFTER the invoking
#   tree was checked out, and asserts the agent's cwd can see it. Asserting that
#   the cwd "is a checkout" would pass on the stale tree too.
#
#   Nothing here touches the real repo, the real state directory, or the network.
set -uo pipefail

SUT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# A git hook exports GIT_DIR / GIT_WORK_TREE; inherited, every git call below
# would act on the real checkout.
for v in $(env | sed -n 's/^\(GIT_[A-Z_]*\)=.*/\1/p'); do unset "$v"; done
[ -f "$SUT_DIR/spawn-claim.sh" ] || { echo "missing $SUT_DIR/spawn-claim.sh"; exit 2; }

SB="${TMPDIR:-/tmp}"; SB="${SB%/}/spawn-claim-fixture-$$"
mkdir -p "$SB"
# Only ever $SB. The spawn root and the materialised scripts/ land inside it
# because every run below sets TMPDIR="$SB" — a glob for harness-spawn-* in the
# real temp dir would delete the cwd of a live agent on the same machine, which
# this suite did once.
SB_REAL=$(cd "$SB" && pwd -P)
# Stand-in servers a failing case left running sit in $SB: stop those, nothing else.
cleanup() {
  for p in $(lsof -a -d cwd -Fpn 2>/dev/null | awk -v t="$SB_REAL/" '/^p/{p=substr($0,2)} /^n/{if (index(substr($0,2) "/", t) == 1) print p}'); do kill "$p" 2>/dev/null; done
  rm -rf "$SB"
}
trap cleanup EXIT
fail=0
ok()  { echo "  ok   — $1"; }
bad() { echo "  FAIL — $1"; fail=1; }

G() { git -c user.email=t@example.com -c user.name=tester -c commit.gpgsign=false -c init.defaultBranch=develop "$@"; }

# ---------------------------------------------------------------- the fixture --
# upstream: the integration branch. store: a clone whose WORKING TREE is left at
# an old commit while origin/develop moves on — the shape of the real defect.
UP="$SB/upstream"; STORE="$SB/store"; STATE="$SB/state"; OUT="$SB/out"; SUT="$SB/sut"
mkdir -p "$UP/.claude/skills/finish" "$STATE" "$OUT" "$SUT"

cat > "$UP/.claude/harness.json" <<'JSON'
{
  "repo": "example/thing",
  "integrationBranch": "develop",
  "branchPrefix": "tk-",
  "sisterRepos": [],
  "labels": {
    "drafting": "status:drafting", "ready": "status:ready", "claimed": "status:claimed",
    "inReview": "status:in-review", "gated": "status:gated", "partial": "status:partial",
    "needsHuman": "status:needs-human", "pmDecision": "status:pm-decision",
    "pmTrack": "status:pm-track", "blocked": "status:blocked",
    "externalBlocked": "status:external-blocked", "parked": "status:parked",
    "hold": "needs:human-approval", "decision": ["needs:human-approval"]
  }
}
JSON
printf 'STALE TREE\n' > "$UP/CLAUDE.md"
printf 'rule A\n' > "$UP/.claude/hookify.rule-a.local.md"
printf 'finish v1\n' > "$UP/.claude/skills/finish/SKILL.md"
mkdir -p "$UP/scripts"
# The PROJECT's own fork of the spawner, as the origin project carried one: it
# builds its prompt from a bare /claim. A marker too, so a run handed to it leaves
# a trace no other code path can leave. The kit must never hand a builder to it.
cat > "$UP/scripts/spawn-claim.sh" <<'MARK'
#!/usr/bin/env bash
printf 'project copy ran\n' > "$SPAWN_TEST_MARKER"
t=""; for a in "$@"; do case "$a" in -*) ;; *) t="$a" ;; esac; done
claude -p "/claim${t:+ $t}" --permission-mode auto
exit 0
MARK
chmod +x "$UP/scripts/spawn-claim.sh"

# The copy of the kit Claude Code has installed NOW, newer than the one invoked.
# The spawner re-execs this one, and a marker shows it did.
mkdir -p "$SB/installed/scripts"
cat > "$SB/installed/scripts/spawn-claim.sh" <<'MARK'
#!/usr/bin/env bash
printf 'installed kit ran\n' > "$SPAWN_TEST_INSTALLED_MARKER"
# An older install: none of this PR's rules, but it appends CLAIM_EXTRA as every copy does.
[ -n "${SPAWN_TEST_EXTRA:-}" ] && printf '%s' "${CLAIM_EXTRA:-}" > "$SPAWN_TEST_EXTRA"
[ -n "${SPAWN_TEST_HANDOVER:-}" ] && claude -p "/agent-harness:claim re-exec" --permission-mode auto
exit 0
MARK
chmod +x "$SB/installed/scripts/spawn-claim.sh"
G -C "$UP" init -q . 2>/dev/null || G -C "$UP" init -q
G -C "$UP" add -A && G -C "$UP" commit -qm c1
G -C "$UP" branch -M develop 2>/dev/null

G clone -q "$UP" "$STORE"
G -C "$STORE" checkout -q develop 2>/dev/null || true
STALE_SHA=$(G -C "$STORE" rev-parse --short HEAD)
STORE_REAL=$(cd "$STORE" && pwd -P)

# The branch moves AFTER the clone's tree was written. Nothing updates that tree.
printf 'rule B\n' > "$UP/.claude/hookify.rule-b.local.md"
printf 'finish v2\n' > "$UP/.claude/skills/finish/SKILL.md"
printf 'CURRENT BRANCH\n' > "$UP/CLAUDE.md"
G -C "$UP" add -A && G -C "$UP" commit -qm c2
G -C "$STORE" fetch -q origin develop
[ "$(G -C "$STORE" rev-parse --short HEAD)" = "$STALE_SHA" ] \
  && ok "fixture: the invoking tree is stale while origin/develop has moved" \
  || bad "fixture: the invoking tree should still be at $STALE_SHA"

# The spawner under test, with a reconcile stub beside it so the detached path
# cannot reach the real one.
cp "$SUT_DIR/spawn-claim.sh" "$SUT_DIR/toolkit-env.sh" "$SUT_DIR/stop-dev-servers.sh" "$SUT_DIR/builder-mcp.sh" \
   "$SUT_DIR/worktree-cache.sh" "$SUT_DIR/worktree-lib.sh" "$SUT_DIR/owner-question.sh" "$SUT_DIR/gh-batch.sh" "$SUT_DIR/branch-ticket.sh" "$SUT/"
mkdir -p "$SB/shared"; cp "$SUT_DIR/../shared/signoff-last.md" "$SB/shared/"
# A claim-lock stub: the claim list the post-exit stop falls back to.
cat > "$SUT/claim-lock.sh" <<'STUB'
#!/usr/bin/env bash
[ "$1" = list ] || exit 1
if [ -n "${SPAWN_TEST_CLAIM_WT:-}" ]; then
  printf '[{"issue":1,"run_id":"%s","worktree":"%s"}]\n' "$(cat "$SPAWN_TEST_RUNID")" "$SPAWN_TEST_CLAIM_WT"
else echo '[]'; fi
exit 1   # the real list --json exits 1 with every claim printed
STUB
cat > "$SUT/reconcile-claims.sh" <<'STUB'
#!/usr/bin/env bash
echo "reconcile stub"
# What the post-exit reconcile is handed: the wrapper is the claim's recorded
# session and still alive while it runs, so it must be named as exited.
[ -n "${SPAWN_TEST_RECONCILE:-}" ] &&
  printf 'exited=%s session=%s\n' "${CLAIM_EXITED_PID:-}" "${CLAIM_SESSION_PID:-}" > "$SPAWN_TEST_RECONCILE"
exit 0
STUB
chmod +x "$SUT"/*.sh

# The stub agent: it records where it was started and what that directory holds.
mkdir -p "$SB/bin"
cat > "$SB/bin/claude" <<'STUB'
#!/usr/bin/env bash
{ printf 'cwd=%s\n' "$PWD"
  printf 'claude.md=%s\n' "$(cat CLAUDE.md 2>/dev/null)"
  printf 'finish=%s\n' "$(cat .claude/skills/finish/SKILL.md 2>/dev/null)"
  printf 'rules=%s\n' "$(ls .claude 2>/dev/null | grep -c 'hookify\..*\.local\.md')"
  printf 'rule-b=%s\n' "$([ -f .claude/hookify.rule-b.local.md ] && echo yes || echo no)"
  printf 'rule-c=%s\n' "$([ -f .claude/hookify.rule-c.local.md ] && echo yes || echo no)"
  printf 'step_budget=%s\n' "${DRIVER_STEP_BUDGET_USD:-}"
  printf 'args=%s\n' "$*"
} > "$SPAWN_TEST_SEEN"
[ -n "${SPAWN_TEST_RUNID:-}" ] && printf '%s' "$CLAIM_RUN_ID" > "$SPAWN_TEST_RUNID"
# Leave a stand-in dev server behind in each named worktree, as an agent does.
for wt in ${SPAWN_TEST_SERVE:-}; do
  mkdir -p "$wt/apps/web"
  (cd "$wt/apps/web" && exec -a next-server sleep 600) >/dev/null 2>&1 &
  printf '%s\n' "$!" >> "$SPAWN_TEST_SRVPIDS"
done
# What claim-lock acquire notes for a spawned run.
[ -n "${SPAWN_TEST_NOTE:-}" ] && printf '%s\n' "$SPAWN_TEST_NOTE" >> "$HARNESS_STATE_DIR/runs/$CLAIM_RUN_ID.worktrees"
exit "${SPAWN_TEST_EXIT:-0}"
STUB
chmod +x "$SB/bin/claude"
# The stub step driver: the agent stub's behaviour, with its own name first in the args.
mkdir -p "$SB/driver"
cat > "$SB/driver/build-ticket" <<'STUB'
#!/usr/bin/env bash
exec "$(dirname "$0")/../bin/claude" build-ticket "$@"
STUB
chmod +x "$SB/driver/build-ticket"
# A stub caffeinate: records what it was asked to hold awake.
cat > "$SB/bin/caffeinate" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" > "$SPAWN_TEST_CAFF"
STUB
chmod +x "$SB/bin/caffeinate"

run() { # [args...] — invoke the spawner from the STALE tree, as the operator does
  RC=0
  SPAWN_TEST_SEEN="$OUT/seen" SPAWN_TEST_MARKER="$OUT/marker" SPAWN_TEST_RECONCILE="$OUT/reconcile" SPAWN_TEST_CAFF="$OUT/caff" \
  SPAWN_TEST_INSTALLED_MARKER="$OUT/installed" SWARM_PLUGIN_REGISTRY="${REGISTRY:-$SB/no-registry.json}" \
  PATH="$SB/bin:$PATH" \
  HARNESS_MAIN_REPO="$STORE" HARNESS_REPO_ROOT="$STORE" \
  HARNESS_CFG_PATH="${CFG:-$STORE/.claude/harness.json}" \
  HARNESS_STATE_DIR="$STATE" HARNESS_LOGIN=tester \
  SPAWN_CLAIM_CANONICAL="${CANON-1}" TMPDIR="$SB" \
  bash "$SUT/spawn-claim.sh" "$@" 2>&1 || RC=$?
}
seen() { sed -n "s/^$1=//p" "$OUT/seen" 2>/dev/null; }

echo "spawn-claim fixture"

# --- 1. THE PLANT: a file committed after the invoking tree was written --------
rm -f "$OUT/seen"
out=$(run --fg 4242)
[ -f "$OUT/seen" ] && ok "the agent started" || bad "the agent never started: $out"
[ "$(seen cwd)" != "$STORE_REAL" ] \
  && ok "the agent does NOT start in the tree the spawner was invoked from" \
  || bad "the agent started in the stale invoking tree ($STORE_REAL)"
[ "$(seen claude.md)" = "CURRENT BRANCH" ] \
  && ok "its CLAUDE.md is the branch's, not the stale tree's" \
  || bad "CLAUDE.md was '$(seen claude.md)', want 'CURRENT BRANCH'"
[ "$(seen finish)" = "finish v2" ] \
  && ok "the skill it would load is the branch's copy" \
  || bad "the skill was '$(seen finish)', want 'finish v2'"
[ "$(seen rule-b)" = yes ] \
  && ok "a guard rule added after the tree was written reaches the spawn" \
  || bad "the guard rule added on the branch was not visible"
[ "$(seen rules)" = 2 ] \
  && ok "it sees every guard rule on the branch (2), not the tree's subset (1)" \
  || bad "it saw $(seen rules) guard rules, want 2"
FIRST_CWD=$(seen cwd)
case "$FIRST_CWD" in
  "$SB"/*|/private"$SB"/*) ok "the checkout it built is inside this fixture's sandbox" ;;
  *) bad "the fixture built a checkout OUTSIDE its sandbox ($FIRST_CWD) — its cleanup would reach a real one" ;;
esac

# --- 2. The same branch commit is one checkout, shared ------------------------
# Immutable by SHA: two spawns at one commit must not each build a tree, and must
# never rewrite a directory a live agent is sitting in.
rm -f "$OUT/seen"; run --fg 4243
[ "$(seen cwd)" = "$FIRST_CWD" ] \
  && ok "a second spawn at the same commit reuses the one checkout" \
  || bad "a second spawn built a different tree ($(seen cwd) vs $FIRST_CWD)"

# --- 3. A rule merged now reaches the NEXT spawn ------------------------------
printf 'rule C\n' > "$UP/.claude/hookify.rule-c.local.md"
G -C "$UP" add -A && G -C "$UP" commit -qm c3
rm -f "$OUT/seen"; run --fg 4244
[ "$(seen rule-c)" = yes ] \
  && ok "a rule merged after the previous spawn reaches the next one" \
  || bad "the newly merged rule did not reach the next spawn"
[ "$(seen cwd)" != "$FIRST_CWD" ] \
  && ok "a new commit gets its own checkout, so no running agent's tree moves" \
  || bad "the new commit reused the previous commit's checkout"

# --- 4. It refuses rather than falling back to a tree it cannot vouch for -----
# A silent fallback is the whole defect: the agent runs, everything looks fine,
# and the tooling is a month old.
BARE="$SB/nobranch"; mkdir -p "$BARE"; G -C "$BARE" init -q
rm -f "$OUT/seen"
RC=0
SPAWN_TEST_SEEN="$OUT/seen" SPAWN_TEST_MARKER="$OUT/marker" PATH="$SB/bin:$PATH" \
HARNESS_MAIN_REPO="$BARE" HARNESS_REPO_ROOT="$BARE" \
HARNESS_CFG_PATH="$STORE/.claude/harness.json" \
HARNESS_STATE_DIR="$STATE" HARNESS_LOGIN=tester SPAWN_CLAIM_CANONICAL=1 TMPDIR="$SB" \
bash "$SUT/spawn-claim.sh" --fg 4245 >"$OUT/refuse.log" 2>&1 || RC=$?
[ "$RC" -ne 0 ] && ok "no resolvable integration branch stops the spawn" \
                || bad "it spawned anyway (rc 0)"
[ ! -f "$OUT/seen" ] && ok "and the agent is never started" \
                     || bad "the agent ran despite the refusal"
grep -q 'develop' "$OUT/refuse.log" \
  && ok "the refusal names the branch it could not resolve" \
  || bad "the refusal does not name the branch: $(cat "$OUT/refuse.log")"

# --- 5. The spawner refreshes ITSELF from the installed kit -------------------
# A caller can hold an older install of the kit. Re-exec the copy installed now,
# found the way run-current.sh finds it: the registry's user-scope installPath.
VDIR=$(dirname "$SB"); KIT_ID="$(basename "$VDIR")@$(basename "$(dirname "$VDIR")")"
jq -n --arg id "$KIT_ID" --arg p "$SB/installed" '{plugins: {($id): [{scope: "user", installPath: $p}]}}' > "$SB/registry.json"
rm -f "$OUT/marker" "$OUT/installed" "$OUT/seen"
CANON="" REGISTRY="$SB/registry.json" run --fg 4246
[ -f "$OUT/installed" ] \
  && ok "the spawner re-execs the kit copy the plugin registry names" \
  || bad "the invoked copy did not re-exec the installed kit: $(cat "$OUT/seen" 2>/dev/null | head -1)"
[ ! -f "$OUT/marker" ] \
  && ok "and never the project's own spawner" \
  || bad "the spawner handed the run to the project's own copy"

# --- 5b. A spawned builder runs the kit's claim, never a bare /claim -----------
# THE GUARD. Until 2026-10-17 the spawner handed every run to the project's own
# scripts/spawn-claim.sh, which built "/claim N" — the project's fork of the skill,
# not the kit's. The project copy above does exactly that, so a hand-over shows here.
bare_claim() { printf '%s' "$1" | perl -ne 'print "$1\n" while /(?<![A-Za-z0-9_.:\-])(\/claim)\b(?![\/\-.])/g' | head -1; }
# A named ticket detached goes to the step driver by default; the prose path is what this guards.
jq '.swarm = {builder: "prose"}' "$STORE/.claude/harness.json" > "$SB/cfg-prose.json"
for mode in detached fg; do
  rm -f "$OUT/marker" "$OUT/installed" "$OUT/seen"
  if [ "$mode" = fg ]; then CFG="$SB/cfg-prose.json" CANON="" run --fg 4950 >/dev/null; else CFG="$SB/cfg-prose.json" CANON="" run 4950 >/dev/null; fi
  for _ in $(seq 1 60); do [ -f "$OUT/seen" ] && break; sleep 0.5; done
  a=$(sed -n '/^args=/,$p' "$OUT/seen" 2>/dev/null | sed '1s/^args=//' | tr '\n' ' ')
  [ -n "$a" ] || { bad "$mode: the builder never started"; continue; }
  printf '%s' "$a" | grep -q '/agent-harness:claim 4950' \
    && ok "$mode: the builder's command is /agent-harness:claim 4950" \
    || bad "$mode: the builder's command does not run /agent-harness:claim 4950: $a"
  [ -z "$(bare_claim "$a")" ] \
    && ok "$mode: and nothing in it names a bare /claim" \
    || bad "$mode: the builder was told to run a bare /claim: $a"
  [ ! -f "$OUT/marker" ] && ok "$mode: the project's own spawner never ran" \
                         || bad "$mode: the run was handed to the project's own spawner"
done

# --- 5c. The owner rule reaches a builder through whatever copy is re-exec'd ---
# The re-exec runs the installed kit, which can be an older install without this
# rule; only what rides in CLAIM_EXTRA reaches its prompt.
rm -f "$OUT/marker" "$OUT/installed" "$OUT/extra"
CANON="" REGISTRY="$SB/registry.json" SPAWN_TEST_EXTRA="$OUT/extra" CLAIM_EXTRA="Resume brief: carry on." run 4249 >/dev/null
[ -f "$OUT/installed" ] && ok "fixture: the detached spawn re-exec'd the installed kit" \
  || bad "fixture: the detached spawn did not re-exec the installed kit"
extra=$(cat "$OUT/extra" 2>/dev/null)
oq=$(printf '%s' "$extra" | sed -n 's/.*bash "\([^"]*owner-question\.sh\)" ask <ticket> <slug>.*/\1/p')
[ -n "$oq" ] && [ -f "$oq" ] && case "$oq" in /*) true ;; *) false ;; esac \
  && ok "the re-exec'd copy is handed the rule, with an absolute path that resolves ($oq)" \
  || bad "the re-exec'd copy's CLAIM_EXTRA carries no resolvable owner-question.sh path: '${extra:-empty}'"
printf '%s' "$extra" | grep -q 'never add needs:human-approval' \
  && ok "the rule says a question never carries the sign-off hold" \
  || bad "the rule does not forbid the hold label on a question"
printf '%s' "$extra" | grep -q 'Resume brief: carry on.' \
  && ok "the caller's own CLAIM_EXTRA is kept ahead of it" \
  || bad "the caller's CLAIM_EXTRA was lost"

# --- 6. The detached path — the default — lands in the same place -------------
# The two paths cd separately; testing only --fg would leave the one the swarm
# actually uses uncovered.
rm -f "$OUT/seen"
# The prose prompt is what this case reads; a repair runs on the driver unless the project says prose.
CFG="$SB/cfg-prose.json" CLAIM_CLASS=repair run 4247
for _ in $(seq 1 60); do [ -f "$OUT/seen" ] && break; sleep 0.5; done
if [ -f "$OUT/seen" ]; then
  [ "$(seen claude.md)" = "CURRENT BRANCH" ] \
    && ok "the detached path starts in the branch's checkout too" \
    || bad "detached CLAUDE.md was '$(seen claude.md)'"
  [ "$(seen rule-c)" = yes ] \
    && ok "the detached path sees the current guard rules" \
    || bad "the detached path missed the current guard rules"
  # A builder in print mode has no question tool: the owner's channel is the only way a question reaches anyone.
  grep -qF "bash \"$SUT/owner-question.sh\" ask <ticket> <slug>" "$OUT/seen" \
    && ok "the detached prompt sends an owner question to the kit's owner-question.sh, by absolute path" \
    || bad "the detached prompt does not route an owner question to $SUT/owner-question.sh"
  [ "$(grep -c 'Owner questions:' "$OUT/seen")" = 1 ] && ok "the rule is in the prompt once" \
    || bad "the owner rule is in the prompt $(grep -c 'Owner questions:' "$OUT/seen") times, want 1"
  # Sign-off comes last: the repair brief's first line, before anything else it reads.
  [ "$(seen args)" = "-p $(head -1 "$SUT_DIR/../shared/signoff-last.md")" ] \
    && ok "the detached prompt's first line is the sign-off-comes-last rule" \
    || bad "the detached prompt starts '$(seen args | cut -c1-80)', not the sign-off rule"
else
  bad "the detached spawn never started the agent"
fi

# The coordinator counts live runs by class, so the record carries the one it was spawned for.
cls=$(jq -r '.class // empty' "$STATE"/runs/claim-4247-*.json 2>/dev/null | head -1)
[ "$cls" = repair ] && ok "the run record carries the class it was spawned for" \
                    || bad "the run record's class was '${cls:-absent}', want repair"

# --- 6b. The detached agent keeps the machine awake for its own life ---------
# An idle Mac slept under a running agent and cost one repair four hours.
for _ in $(seq 1 60); do [ -s "$OUT/caff" ] && break; sleep 0.5; done
caff=$(cat "$OUT/caff" 2>/dev/null)
if printf '%s' "$caff" | grep -Eq -- '-is -w [0-9]+$'; then ok "the agent is held awake, and only for its own life"
else bad "nothing kept the machine awake for the agent: '${caff:-caffeinate never ran}'"; fi

# --- 7. The post-exit reconcile is told its own session has exited ------------
# spawn-claim records its wrapper subshell as the claim's session, and runs the
# reconcile inside it — so without CLAIM_EXITED_PID the holder reads alive and a
# crashed agent's claim is never released.
for _ in $(seq 1 60); do [ -s "$OUT/reconcile" ] && break; sleep 0.5; done
rec=$(cat "$OUT/reconcile" 2>/dev/null)
ex=$(printf '%s' "$rec" | sed -n 's/^exited=\([0-9][0-9]*\) .*/\1/p')
se=$(printf '%s' "$rec" | sed -n 's/.* session=\([0-9][0-9]*\)$/\1/p')
if [ -n "$ex" ] && [ "$ex" = "$se" ]; then ok "the post-exit reconcile names the wrapper session as exited"
else bad "the post-exit reconcile was not told its session exited: '${rec:-nothing recorded}'"; fi

# --- 8. The agent's dev servers are stopped when it exits, however it exits ---
# A detached agent that ended any way but /finish left its servers up: 63 on one
# machine, swap 49.7 of 50 GB. The wrapper stops the run's worktree's servers.
G init -q "$SB/wt-801"; G init -q "$SB/wt-802"
mkdir -p "$SB/wt-801/apps/web/.next" "$SB/wt-802/apps/web/.next"
printf 'x\n' > "$SB/wt-801/apps/web/.next/out"; printf 'x\n' > "$SB/wt-802/apps/web/.next/out"
alive() { kill -0 "$1" 2>/dev/null && ! ps -o stat= -p "$1" 2>/dev/null | grep -q Z; }
spawn_and_wait() { # a detached spawn under the caller's env; waits for its post-exit stop
  rm -f "$OUT/srvpids" "$OUT/runid" "$OUT/reconcile"
  run "$TKT" >/dev/null
  for _ in $(seq 1 60); do [ -s "$OUT/reconcile" ] && break; sleep 0.5; done
  sleep 1
}
srv() { sed -n "${1}p" "$OUT/srvpids" 2>/dev/null; }
export SPAWN_TEST_SRVPIDS="$OUT/srvpids" SPAWN_TEST_RUNID="$OUT/runid"

# 8a. the run's noted worktree: its server stops, a sibling worktree's does not.
TKT=4801 SPAWN_TEST_SERVE="$SB/wt-801 $SB/wt-802" SPAWN_TEST_NOTE="$SB/wt-801" spawn_and_wait
s1=$(srv 1); s2=$(srv 2); RID=$(cat "$OUT/runid" 2>/dev/null)
if [ -n "$s1" ] && [ -n "$s2" ]; then
  alive "$s1" && bad "the run's own worktree server survived the agent's exit" \
              || ok "the agent's exit stops the dev server in its own worktree"
  alive "$s2" && ok "a worktree the run never claimed keeps its server" \
              || bad "the post-exit stop reached a worktree the run never claimed"
else bad "fixture: the stand-in servers never started"; fi
grep -q 'post-exit dev-server stop' "$STATE/logs/$RID.log" 2>/dev/null \
  && ok "the stop is logged in the run's log" || bad "the run's log does not show the stop"
[ ! -e "$SB/wt-801/apps/web/.next" ] && ok "the agent's exit removes its worktree's build cache" \
  || bad "the run's own worktree kept its build cache after the agent exited"
[ -f "$SB/wt-802/apps/web/.next/out" ] && ok "a worktree the run never claimed keeps its cache" \
  || bad "the post-exit cache pass reached a worktree the run never claimed"
grep -q 'cleaned apps/web/.next' "$STATE/logs/$RID.log" 2>/dev/null \
  && ok "the cache removal is logged in the run's log" || bad "the run's log does not show the cache removal"
kill "$s2" 2>/dev/null

# 8a'. however it exits: a crashed agent's worktree is cleaned the same way.
mkdir -p "$SB/wt-801/apps/web/.next"; printf 'x\n' > "$SB/wt-801/apps/web/.next/out"
TKT=4805 SPAWN_TEST_EXIT=3 SPAWN_TEST_NOTE="$SB/wt-801" spawn_and_wait
[ ! -e "$SB/wt-801/apps/web/.next" ] && ok "an agent that crashed still has its build cache removed" \
  || bad "a crashed agent's worktree kept its build cache"

# 8b. nothing recorded: nothing stopped, and the log says why.
TKT=4802 SPAWN_TEST_SERVE="$SB/wt-801" spawn_and_wait
s1=$(srv 1); RID=$(cat "$OUT/runid" 2>/dev/null)
alive "$s1" && ok "with no worktree recorded for the run, no server is stopped" \
            || bad "a server was stopped though the run recorded no worktree"
grep -q "no worktree recorded for $RID" "$STATE/logs/$RID.log" 2>/dev/null \
  && ok "and the log says why nothing was stopped" || bad "the log does not say why nothing was stopped"
kill "$s1" 2>/dev/null

# 8c. no local note, but a claim still held names the run: that claim's worktree.
TKT=4803 SPAWN_TEST_SERVE="$SB/wt-801" SPAWN_TEST_CLAIM_WT="$SB/wt-801" spawn_and_wait
s1=$(srv 1)
alive "$s1" && bad "a claim naming the run did not lead to its worktree's server" \
            || ok "with no local note, a held claim naming the run gives the worktree"

# 8d. a noted path that is not a checkout's top level stops nothing beneath it.
mkdir -p "$SB/notacheckout"; G init -q "$SB/notacheckout/wt-803"
TKT=4804 SPAWN_TEST_SERVE="$SB/notacheckout/wt-803" SPAWN_TEST_NOTE="$SB/notacheckout" spawn_and_wait
s1=$(srv 1)
alive "$s1" && ok "a noted parent folder, not a checkout, stops no server beneath it" \
            || bad "a noted parent folder stopped a server in a worktree beneath it"
kill "$s1" 2>/dev/null

# --- 9. A builder loads only the MCP servers on the builder list ---------------
# Each builder started its own ms365, Railway and Playwright servers, 434-538 MB a
# builder, and used none of them. The list is swarm.builderMcpServers, {} unless set.
mcp_of() { # <args line> — what the run can load: ALL when not strict, else the config's server names
  local a="$1" f
  case " $a " in *" --strict-mcp-config "*) ;; *) echo ALL; return ;; esac
  f=$(printf '%s' "$a" | sed -n 's/.*--mcp-config \([^ ]*\).*/\1/p')
  [ -f "$f" ] || { echo "no config at '$f'"; return; }
  jq -r '.mcpServers | keys | join(",")' "$f"
}
# The whole argv: a detached prompt runs over several lines, and the flags follow it.
seen_args() { sed -n '/^args=/,$p' "$OUT/seen" 2>/dev/null | sed '1s/^args=//' | tr '\n' ' '; }
wait_seen() { for _ in $(seq 1 60); do [ -f "$OUT/seen" ] && break; sleep 0.5; done; }
rm -f "$OUT/seen"; CFG="$SB/cfg-prose.json" run 4901; wait_seen
got=$(mcp_of "$(seen_args)")
[ -z "$got" ] && ok "a detached builder loads no MCP server when the list is empty" \
              || bad "a detached builder can load '$got', want none: $(seen args)"
rm -f "$OUT/seen" "$OUT/installed"; SPAWN_TEST_HANDOVER=1 CANON="" REGISTRY="$SB/registry.json" run 4902; wait_seen
[ -f "$OUT/installed" ] || bad "the re-exec case never reached the installed kit"
got=$(mcp_of "$(seen_args)")
[ -z "$got" ] && ok "re-exec'd into the installed kit, the builder still loads none" \
              || bad "after the re-exec the builder can load '$got', want none: $(seen args)"
jq '.swarm = {builder: "prose", builderMcpServers: {railway: {command: "railway", args: ["mcp"]}}}' "$STORE/.claude/harness.json" > "$SB/cfg-mcp.json"
rm -f "$OUT/seen"; CFG="$SB/cfg-mcp.json" run 4903; wait_seen
got=$(mcp_of "$(seen_args)")
[ "$got" = railway ] && ok "a server on the list is loaded, and only that one" \
                     || bad "with railway listed the builder can load '$got': $(seen args)"
rm -f "$OUT/seen"; run --fg 4904
got=$(mcp_of "$(seen_args)")
[ "$got" = ALL ] && ok "an interactive session keeps every server" \
                 || bad "the --fg session was limited to '$got'"

# --- 10. Who builds: the step driver for a new ticket, prose for the rest ------
# Dom, 2026-10-17: every new ticket build runs on driver/build-ticket. Each case
# reads the argv the agent stub was started with, so a branch that stops choosing
# its builder shows as the wrong program running, not as a missing line.
record_of() { jq -r ".$2 // empty" "$STATE"/runs/claim-"$1"-*.json 2>/dev/null | head -1; }
builder_case() { # <ticket> [run args...] — spawn detached, wait for the agent, return its argv
  local t="$1"; shift
  rm -f "$OUT/seen"; run "$@" >/dev/null; wait_seen
  BARGS=$(seen_args)
}

builder_case 4960 4960
case "$BARGS" in
  "build-ticket 4960 "*|"build-ticket 4960") ok "default: a named ticket runs driver/build-ticket 4960" ;;
  *) bad "default: the builder was not build-ticket 4960: '${BARGS:-never started}'" ;;
esac
printf '%s' "$BARGS" | grep -q '/agent-harness:claim' \
  && bad "default: the prose claim ran as well as or instead of the driver" \
  || ok "default: no prose claim prompt reaches it"
[ "$(seen step_budget)" = 150 ] && ok "default: the run's budget caps each driver step" \
  || bad "default: the driver was handed step budget '$(seen step_budget)', want 150"
[ "$(record_of 4960 builder)" = driver ] && ok "default: the run record says builder driver" \
  || bad "default: the run record's builder was '$(record_of 4960 builder)'"

CFG="$SB/cfg-prose.json" builder_case 4961 4961
case "$BARGS" in
  build-ticket*) bad "swarm.builder=prose: the driver ran: '$BARGS'" ;;
  *) printf '%s' "$BARGS" | grep -q -- '/agent-harness:claim 4961' \
       && printf '%s' "$BARGS" | grep -q -- '-p ' \
       && ok "swarm.builder=prose: claude -p runs /agent-harness:claim 4961" \
       || bad "swarm.builder=prose: the prose claim did not run: '${BARGS:-never started}'" ;;
esac

builder_case next
case "$BARGS" in
  build-ticket*) bad "pick-next: the driver ran with no ticket: '$BARGS'" ;;
  *) printf '%s' "$BARGS" | grep -Eq -- '/agent-harness:claim( |$)' \
       && ! printf '%s' "$BARGS" | grep -Eq -- '/agent-harness:claim [0-9]' \
       && ok "pick-next: no ticket stays on the prose claim, with no number" \
       || bad "pick-next: the prose pick-next claim did not run: '${BARGS:-never started}'" ;;
esac

# No unattended run falls back to prose (the operator, 2026-10-17): a briefed run and
# a healing run stay on the driver, and take their brief with them.
CLAIM_EXTRA="Merge lane: PR #9 left the lane — fix it on its branch." builder_case 4962 4962
case "$BARGS" in
  "build-ticket 4962 --brief "*) ok "a run with a caller's brief runs build-ticket --brief, not prose" ;;
  *) bad "a briefed run did not go to build-ticket --brief: '${BARGS:-never started}'" ;;
esac

CLAIM_CLASS=approved-merge builder_case 4963 4963
case "$BARGS" in
  "build-ticket 4963 --repair-class approved-merge"*) ok "an approved-merge run works its open PR on the driver (--repair-class)" ;;
  *) bad "an approved-merge run did not go to build-ticket --repair-class: '${BARGS:-never started}'" ;;
esac

rm -f "$OUT/seen"
jq '.swarm = {builder: "steps"}' "$STORE/.claude/harness.json" > "$SB/cfg-bad.json"
CFG="$SB/cfg-bad.json" run 4964 >"$OUT/bad.log"
[ "$RC" = 2 ] && grep -q "swarm.builder is 'steps'" "$OUT/bad.log" \
  && ok "an unknown swarm.builder refuses by name" \
  || bad "an unknown swarm.builder did not refuse (rc $RC): $(cat "$OUT/bad.log")"

mv "$SB/driver/build-ticket" "$SB/driver/build-ticket.away"
rm -f "$OUT/seen"; run 4965 >"$OUT/nodriver.log"
mv "$SB/driver/build-ticket.away" "$SB/driver/build-ticket"
[ "$RC" = 1 ] && grep -q 'swarm.builder' "$OUT/nodriver.log" && [ ! -f "$OUT/seen" ] \
  && ok "a missing driver refuses and names the prose switch, starting nothing" \
  || bad "a missing driver did not refuse cleanly (rc $RC): $(cat "$OUT/nodriver.log")"

# --- 11. The driver run, as the coordinator reads it, and its brief channel ---
# The coordinator reads four things off a spawn: the run record, the .child pid,
# the .ended exit code, and the log's last result line. A driver run that skips any
# of them reads as something it is not. And every brief reaches the driver verbatim:
# dropped, a red PR's repair would rebuild the ticket; refused, it would never run.
cat > "$SB/bin/build-ticket-stub" <<'STUB'
#!/usr/bin/env bash
b=""; case "${2:-}" in --repair|--brief) b=$(tr '\n' '|' < "$3" | sed 's/|$//') ;; esac
printf 'cwd=%s\nargs=%s\nclaude.md=%s\nrun=%s\nbrief=%s\n' "$PWD" "$*" "$(cat CLAUDE.md 2>/dev/null)" "${CLAIM_RUN_ID:-}" "$b" > "$SPAWN_TEST_DRIVER_SEEN"
echo "build-ticket: walking #$1"
echo "  step build: green"
echo "⏸ #$1 parked: the spec needs a decision"
echo
exit "${SPAWN_TEST_DRIVER_EXIT:-20}"
STUB
chmod +x "$SB/bin/build-ticket-stub"
export SPAWN_TEST_DRIVER_SEEN="$OUT/driver-seen"
dseen() { sed -n "s/^$1=//p" "$OUT/driver-seen" 2>/dev/null; }
rec_of() { ls "$STATE"/runs/claim-"$1"-*.json 2>/dev/null | head -1; }
# The coordinator's own reader of a run's last word, lifted from the tick itself.
eval "$(sed -n '/^final_line() {/,/^}/p' "$SUT_DIR/coordinator-tick.sh")"
dcase() { # <ticket> [run args…] — a detached spawn on the stub driver, waited out
  rm -f "$OUT/seen" "$OUT/driver-seen" "$OUT/reconcile"
  SPAWN_CLAIM_DRIVER="$SB/bin/build-ticket-stub" run "$@" >"$OUT/run.out"
  local r=""
  for _ in $(seq 1 60); do r=$(rec_of "$1"); [ -n "$r" ] && [ -f "${r%.json}.ended" ] && [ -s "$OUT/reconcile" ] && break; sleep 0.5; done
  sleep 1
}

# 11a. a new build: the record, the pid, the exit code, the verdict line.
dcase 4970 4970
REC=$(rec_of 4970); RID=$(basename "${REC:-none}" .json)
[ "$(dseen args)" = 4970 ] && ok "a new build runs build-ticket with the ticket alone" || bad "build-ticket args were '$(dseen args)', want 4970"
[ "$(dseen claude.md)" = "CURRENT BRANCH" ] && ok "from the branch's spawn root" || bad "build-ticket ran from '$(dseen cwd)'"
[ "$(jq -r '.exit_code' "$STATE/runs/$RID.ended" 2>/dev/null)" = 20 ] && ok "the .ended carries the driver's exit code (20 parked)" \
  || bad "the .ended exit code was '$(jq -r '.exit_code' "$STATE/runs/$RID.ended" 2>/dev/null)', want 20"
[ -s "$OUT/reconcile" ] && ok "the post-exit reconcile runs after a driver run" || bad "no reconcile after the driver run"
[ -n "$(cat "$STATE/runs/$RID.child" 2>/dev/null)" ] && [ "$(cat "$STATE/runs/$RID.child")" = "$(jq -r '.child_pid' "$REC")" ] \
  && ok "the driver's pid is the run's .child and the record's child_pid" || bad "the driver's pid was not recorded as the child"
[ "$(dseen run)" = "$RID" ] && ok "the driver inherits the run id" || bad "the driver saw run id '$(dseen run)'"
[ "$(jq -r '.driver_mode // empty' "$REC")" = build ] && ok "the record names the driver mode" || bad "driver_mode was '$(jq -r '.driver_mode // empty' "$REC")'"
[ "$(jq -c '.progress_paths' "$REC" 2>/dev/null)" = "[\"$STATE/driver/4970\"]" ] \
  && ok "the record names the driver's per-ticket state dir as progress" \
  || bad "progress_paths was '$(jq -c '.progress_paths' "$REC" 2>/dev/null)'"
LOGF="$STATE/logs/$RID.log"
[ "$(final_line "$LOGF")" = "⏸ #4970 parked: the spec needs a decision" ] \
  && ok "the coordinator reads the driver's last line as the run's verdict" \
  || bad "the coordinator would read '$(final_line "$LOGF")' as the verdict"
rl=$(grep -n '"type":"result"' "$LOGF" 2>/dev/null | head -1 | cut -d: -f1)
pl=$(grep -n 'post-exit' "$LOGF" 2>/dev/null | head -1 | cut -d: -f1)
[ -n "$rl" ] && [ -n "$pl" ] && [ "$rl" -lt "$pl" ] && ok "the verdict line is written before the post-exit sections" \
  || bad "result line at ${rl:-none}, post-exit at ${pl:-none}"
CFG="$SB/cfg-prose.json" dcase 4979 4979
[ "$(jq -r 'has("progress_paths") or has("driver_mode")' "$(rec_of 4979)" 2>/dev/null)" = false ] \
  && ok "a prose run's record carries no driver fields" || bad "a prose run's record carries driver fields"

# 11b. a caller's brief, no healing class: --brief, verbatim, without the prose-only owner rule.
CLAIM_EXTRA="The owner answered q1: ship the narrow version." dcase 4971 4971
case "$(dseen args)" in "4971 --brief "*) ok "a briefed run is build-ticket --brief" ;; *) bad "a briefed run ran build-ticket '$(dseen args)'" ;; esac
[ "$(dseen brief)" = "The owner answered q1: ship the narrow version." ] && ok "the brief is the caller's words, verbatim" \
  || bad "the brief build-ticket read was '$(dseen brief)'"
printf '%s' "$(dseen brief)" | grep -q 'Owner questions:' && bad "the prose claim's owner rule leaked into the driver's brief" \
  || ok "the prose claim's owner rule is not part of it"
[ ! -f "$OUT/seen" ] && ok "no prose claim ran" || bad "a briefed driver spawn also ran claude"
HARNESS_OWNER_RULE="RULE-Z" CLAIM_EXTRA="$(printf 'Fix the clash.\n\nRULE-Z')" dcase 4978 4978
[ "$(dseen brief)" = "Fix the clash." ] && ok "re-exec'd with the rule already appended, the brief is still the caller's alone" \
  || bad "a re-exec'd copy handed the driver '$(dseen brief)'"

# 11c. healing classes: --repair with the note, or --repair-class with none.
CLAIM_CLASS=repair CLAIM_EXTRA="REPAIR on PR #7 at abc: CI went red on: unit" dcase 4972 4972
case "$(dseen args)" in "4972 --repair "*) ok "a noted repair is build-ticket --repair" ;; *) bad "a noted repair ran build-ticket '$(dseen args)'" ;; esac
[ "$(dseen brief)" = "REPAIR on PR #7 at abc: CI went red on: unit" ] && ok "with its note verbatim" || bad "the repair brief was '$(dseen brief)'"
CLAIM_CLASS=repair dcase 4973 4973
[ "$(dseen args)" = "4973 --repair-class repair" ] && ok "a repair with no note is --repair-class repair — never a fresh build" \
  || bad "a note-less repair ran build-ticket '$(dseen args)'"
CLAIM_CLASS=new dcase 4975 4975
[ "$(dseen args)" = 4975 ] && ok "a new-class run with no brief is a plain build" || bad "a new-class run ran build-ticket '$(dseen args)'"

# 11f. a draft PR the driver never built is not a repair: the prose claim resumes it.
# Readied by a repair, auto-merge would land work its author left unfinished.
cat > "$SB/bin/gh-prs" <<'STUB'
#!/usr/bin/env bash
case "$1 $2 $*" in "api graphql "*'pullRequests(states:[OPEN]'*) exec bash "$GH_OPEN_PRS_FAKE" "$SPAWN_TEST_PRS" "$@" ;; esac
case "$1 $2" in "pr list") cat "$SPAWN_TEST_PRS" 2>/dev/null || echo '[]' ;; *) exit 1 ;; esac
STUB
chmod +x "$SB/bin/gh-prs"
export SWARM_GH="$SB/bin/gh-prs" SWARM_PRS_MAX_AGE=0 SPAWN_TEST_PRS="$OUT/prs.json" GH_OPEN_PRS_FAKE="$HERE/fixtures/gh-open-prs.sh"
echo '[{"number":81,"headRefName":"tk-4981-x","isDraft":true},{"number":82,"headRefName":"tk-4982-x","isDraft":false},{"number":83,"headRefName":"tk-4983-x","isDraft":true}]' > "$OUT/prs.json"
CLAIM_CLASS=repair CLAIM_EXTRA="REPAIR on PR #81: red" dcase 4981 4981
[ ! -f "$OUT/driver-seen" ] && [ -f "$OUT/seen" ] && ok "a repair of a draft the driver never built runs the prose claim" \
  || bad "a repair of an unbuilt draft ran build-ticket '$(dseen args)'"
grep -q 'draft the driver did not build' "$STATE"/logs/claim-4981-*.log && ok "and the run log says why" || bad "the run log does not say why it is prose"
CLAIM_EXTRA="The owner answered: B" dcase 4983 4983
[ ! -f "$OUT/driver-seen" ] && ok "a briefed run on an unbuilt draft is prose too" || bad "a briefed run on an unbuilt draft ran build-ticket '$(dseen args)'"
CLAIM_CLASS=repair CLAIM_EXTRA="REPAIR on PR #82: red" dcase 4982 4982
case "$(dseen args)" in "4982 --repair "*) ok "a ready PR is still the driver's repair" ;; *) bad "a ready PR's repair ran '$(dseen args)'" ;; esac
mkdir -p "$STATE/driver/4983"; echo '{"mode":"build","done":["start","plan"]}' > "$STATE/driver/4983/state.json"
CLAIM_EXTRA="The owner answered: B" dcase 4983 4983
case "$(dseen args)" in "4983 --brief "*) ok "a draft the driver's own build left stays on the driver" ;; *) bad "the driver's own draft ran '$(dseen args)'" ;; esac
unset SWARM_GH SWARM_PRS_MAX_AGE SPAWN_TEST_PRS

# 11e. --fg with a ticket runs the step driver in this terminal (the operator, 2026-10-17);
# pick-next stays the interactive prose claim. The same brief channel as a detached run.
rm -f "$OUT/seen" "$OUT/driver-seen"
SPAWN_CLAIM_DRIVER="$SB/bin/build-ticket-stub" run --fg 4990 >"$OUT/fg.out"
[ "$(dseen args)" = 4990 ] && [ ! -f "$OUT/seen" ] && ok "--fg 4990 runs build-ticket 4990 in the foreground, not prose" \
  || bad "--fg 4990 did not run the driver: $(cat "$OUT/fg.out" | head -3)"
grep -q 'parked' "$OUT/fg.out" && ok "and its output is the terminal's" || bad "the foreground driver's output did not reach the terminal"
rm -f "$OUT/driver-seen"
CLAIM_CLASS=repair CLAIM_EXTRA="REPAIR on PR #3: red" SPAWN_CLAIM_DRIVER="$SB/bin/build-ticket-stub" run --fg 4991 >/dev/null
case "$(dseen args)" in "4991 --repair "*) ok "--fg carries a repair's brief the same way" ;; *) bad "--fg repair ran build-ticket '$(dseen args)'" ;; esac
[ "$(dseen brief)" = "REPAIR on PR #3: red" ] && ok "verbatim" || bad "--fg repair brief was '$(dseen brief)'"
rm -f "$OUT/seen" "$OUT/driver-seen"
SPAWN_CLAIM_DRIVER="$SB/bin/build-ticket-stub" run --fg >/dev/null
[ ! -f "$OUT/driver-seen" ] && [ -f "$OUT/seen" ] && ok "--fg with no ticket stays the interactive prose claim" \
  || bad "--fg pick-next did not run the prose claim"

# 11d. swarm.builder = prose is the escape hatch: everything, brief and repair alike, on prose.
CFG="$SB/cfg-prose.json" CLAIM_CLASS=repair CLAIM_EXTRA="REPAIR on PR #8: red" dcase 4976 4976
for _ in $(seq 1 20); do [ -f "$OUT/seen" ] && break; sleep 0.5; done
[ ! -f "$OUT/driver-seen" ] && grep -q '/agent-harness:claim 4976' "$OUT/seen" 2>/dev/null && grep -q 'REPAIR on PR #8: red' "$OUT/seen" 2>/dev/null \
  && ok "swarm.builder=prose: a noted repair runs the prose claim, brief in its prompt" \
  || bad "swarm.builder=prose did not send the repair to prose: $(cat "$OUT/seen" 2>/dev/null | head -3)"

echo
[ "$fail" -eq 0 ] && echo "spawn-claim: all cases pass" || echo "spawn-claim: FAILURES above"
exit $fail
