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
[ -f "$SUT_DIR/spawn-claim.sh" ] || { echo "missing $SUT_DIR/spawn-claim.sh"; exit 2; }

SB="${TMPDIR:-/tmp}"; SB="${SB%/}/spawn-claim-fixture-$$"
mkdir -p "$SB"
# Only ever $SB. The spawn root and the materialised scripts/ land inside it
# because every run below sets TMPDIR="$SB" — a glob for harness-spawn-* in the
# real temp dir would delete the cwd of a live agent on the same machine, which
# this suite did once.
trap 'rm -rf "$SB"' EXIT
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
# The branch's OWN copy of the spawner. Deliberately a marker, not a spawner: a
# run that re-execs it leaves a trace that no other code path can leave.
cat > "$UP/scripts/spawn-claim.sh" <<'MARK'
#!/usr/bin/env bash
printf 'branch copy ran\n' > "$SPAWN_TEST_MARKER"
MARK
chmod +x "$UP/scripts/spawn-claim.sh"
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
cp "$SUT_DIR/spawn-claim.sh" "$SUT_DIR/toolkit-env.sh" "$SUT/"
printf '#!/usr/bin/env bash\necho "reconcile stub"\n' > "$SUT/reconcile-claims.sh"
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
STUB
chmod +x "$SB/bin/claude"

run() { # [args...] — invoke the spawner from the STALE tree, as the operator does
  RC=0
  SPAWN_TEST_SEEN="$OUT/seen" SPAWN_TEST_MARKER="$OUT/marker" \
  PATH="$SB/bin:$PATH" \
  HARNESS_MAIN_REPO="$STORE" HARNESS_REPO_ROOT="$STORE" \
  HARNESS_CFG_PATH="$STORE/.claude/harness.json" \
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

# --- 5. The spawner refreshes ITSELF, not only the agent's tree ---------------
# The operator's shell function points at one copy on disk, and that copy is what
# went stale first. Re-exec the branch's own copy once.
rm -f "$OUT/marker" "$OUT/seen"
CANON="" run --fg 4246
[ -f "$OUT/marker" ] \
  && ok "the spawner re-execs the integration branch's copy of itself" \
  || bad "the invoked copy ran its own logic instead of the branch's"

# --- 6. The detached path — the default — lands in the same place -------------
# The two paths cd separately; testing only --fg would leave the one the swarm
# actually uses uncovered.
rm -f "$OUT/seen"
run 4247
for _ in $(seq 1 60); do [ -f "$OUT/seen" ] && break; sleep 0.5; done
if [ -f "$OUT/seen" ]; then
  [ "$(seen claude.md)" = "CURRENT BRANCH" ] \
    && ok "the detached path starts in the branch's checkout too" \
    || bad "detached CLAUDE.md was '$(seen claude.md)'"
  [ "$(seen rule-c)" = yes ] \
    && ok "the detached path sees the current guard rules" \
    || bad "the detached path missed the current guard rules"
else
  bad "the detached spawn never started the agent"
fi

echo
[ "$fail" -eq 0 ] && echo "spawn-claim: all cases pass" || echo "spawn-claim: FAILURES above"
exit $fail
