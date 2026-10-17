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
   "$SUT_DIR/worktree-cache.sh" "$SUT_DIR/worktree-lib.sh" "$SUT_DIR/owner-question.sh" "$SUT/"
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
for mode in detached fg; do
  rm -f "$OUT/marker" "$OUT/installed" "$OUT/seen"
  if [ "$mode" = fg ]; then CANON="" run --fg 4950 >/dev/null; else CANON="" run 4950 >/dev/null; fi
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
CLAIM_CLASS=repair run 4247
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
rm -f "$OUT/seen"; run 4901; wait_seen
got=$(mcp_of "$(seen_args)")
[ -z "$got" ] && ok "a detached builder loads no MCP server when the list is empty" \
              || bad "a detached builder can load '$got', want none: $(seen args)"
rm -f "$OUT/seen" "$OUT/installed"; SPAWN_TEST_HANDOVER=1 CANON="" REGISTRY="$SB/registry.json" run 4902; wait_seen
[ -f "$OUT/installed" ] || bad "the re-exec case never reached the installed kit"
got=$(mcp_of "$(seen_args)")
[ -z "$got" ] && ok "re-exec'd into the installed kit, the builder still loads none" \
              || bad "after the re-exec the builder can load '$got', want none: $(seen args)"
jq '.swarm = {builderMcpServers: {railway: {command: "railway", args: ["mcp"]}}}' "$STORE/.claude/harness.json" > "$SB/cfg-mcp.json"
rm -f "$OUT/seen"; CFG="$SB/cfg-mcp.json" run 4903; wait_seen
got=$(mcp_of "$(seen_args)")
[ "$got" = railway ] && ok "a server on the list is loaded, and only that one" \
                     || bad "with railway listed the builder can load '$got': $(seen args)"
rm -f "$OUT/seen"; run --fg 4904
got=$(mcp_of "$(seen_args)")
[ "$got" = ALL ] && ok "an interactive session keeps every server" \
                 || bad "the --fg session was limited to '$got'"

echo
[ "$fail" -eq 0 ] && echo "spawn-claim: all cases pass" || echo "spawn-claim: FAILURES above"
exit $fail
