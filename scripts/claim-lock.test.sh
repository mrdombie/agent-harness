#!/usr/bin/env bash
# Fixture for claim-lock.sh's repo resolution.
#
# WHY THIS EXISTS
#   `git rev-parse --is-inside-work-tree` prints "false" and EXITS 0 in a bare
#   repository. resolve_repo tested the exit code, so a shell sitting in a bare
#   clone took the work-tree branch and `--show-toplevel` then died with
#   "fatal: this operation must be run in a work tree" — before the CLAIM_REPO
#   fallback beneath it was ever reached, so setting CLAIM_REPO did not help.
#
#   The operator's shared clone is a bare repo, so this was every claim taken
#   from it. The same call succeeds from anywhere else, which is what made it
#   read as a broken script rather than a broken test.
#
#   The case below runs the real script from inside a real bare clone. Planting
#   the old exit-code test turns it red.
set -uo pipefail

SUT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/claim-lock.sh"
[ -f "$SUT" ] || { echo "missing $SUT"; exit 2; }

SB=$(mktemp -d "${TMPDIR:-/tmp}/claim-lock-fixture-XXXXXX")
trap 'rm -rf "$SB"' EXIT
fail=0
ok()  { echo "  ok   — $1"; }
bad() { echo "  FAIL — $1"; fail=1; }

# A git hook exports GIT_DIR / GIT_WORK_TREE to everything it runs; inherited,
# they would make every git call below act on the REAL checkout.
for v in $(env | sed -n 's/^\(GIT_[A-Z_]*\)=.*/\1/p'); do unset "$v"; done

# ---------------------------------------------------------------- the sandbox
# Invented project. Nothing here names a real one, and nothing touches a live
# claim: the "origin" is a bare repo in this directory.
git init -q --bare -b main "$SB/origin.git"
git clone -q "$SB/origin.git" "$SB/work" 2>/dev/null
mkdir -p "$SB/work/.claude" "$SB/state"
cat > "$SB/work/.claude/harness.json" <<JSON
{
  "repo": "acme/widgets",
  "integrationBranch": "main",
  "branchPrefix": "tkt-",
  "stateDir": "$SB/state",
  "sisterRepos": [],
  "labels": {
    "drafting": "st:drafting", "ready": "st:ready", "claimed": "st:claimed",
    "inReview": "st:review", "gated": "st:gated", "partial": "st:partial",
    "blocked": "st:blocked", "parked": "st:parked",
    "externalBlocked": "st:ext-blocked", "needsHuman": "st:needs-human",
    "pmDecision": "st:pm-decision", "pmTrack": "st:pm-track",
    "hold": "hold:human",
    "decision": ["st:pm-track", "st:pm-decision", "hold:human"]
  }
}
JSON
git -C "$SB/work" add -f .claude/harness.json
git -C "$SB/work" -c user.email=t@f.local -c user.name=f commit -qm init
git -C "$SB/work" push -q origin main

# The shape the operator actually has: a bare clone beside the work tree.
git clone -q --bare "$SB/origin.git" "$SB/bare.git" 2>/dev/null

run() { # <cwd> [env assignments handled by caller] -> RC
  local dir=$1; shift
  RC=0
  ( cd "$dir" && CLAIM_REPO="$SB/work" HARNESS_CFG_PATH="$SB/work/.claude/harness.json" \
      bash "$SUT" "$@" ) > "$SB/out" 2>&1 || RC=$?
}

echo "claim-lock fixture"

# --- 1. THE PLANT'S TARGET: a bare repo must not stop the resolver ------------
# 11 is "not claimed" — the script ANSWERED. 1 with "must be run in a work tree"
# is the defect. Asserting only "not 0" would pass on the defect.
run "$SB/bare.git" holds 1
[ "$RC" -eq 11 ] && ok "from a BARE clone it resolves and answers (rc 11)" \
                 || bad "from a BARE clone it resolves and answers (rc $RC: $(tail -1 "$SB/out"))"
grep -q 'must be run in a work tree' "$SB/out" \
  && bad "and does not die on --show-toplevel" \
  || ok "and does not die on --show-toplevel"

# --- 2. Control: the ordinary case is unchanged -------------------------------
# Without this the fix could be "always take the CLAIM_REPO branch".
run "$SB/work" holds 1
[ "$RC" -eq 11 ] && ok "from a WORK TREE it still answers (rc 11)" \
                 || bad "from a WORK TREE it still answers (rc $RC: $(tail -1 "$SB/out"))"

# --- 3. Control: it still refuses when there is genuinely no repo -------------
# A resolver that resolves everything is not a resolver.
mkdir -p "$SB/nowhere"
RC=0
( cd "$SB/nowhere" && CLAIM_REPO="$SB/nowhere" HARNESS_CFG_PATH="$SB/work/.claude/harness.json" \
    bash "$SUT" holds 1 ) > "$SB/out" 2>&1 || RC=$?
[ "$RC" -ne 0 ] && [ "$RC" -ne 11 ] && ok "no repo anywhere still refuses (rc $RC)" \
                                    || bad "no repo anywhere still refuses (rc $RC)"
grep -q 'not in a git repo' "$SB/out" \
  && ok "and names what to set" || ok "and refuses (message: $(tail -1 "$SB/out"))"

echo
[ "$fail" -eq 0 ] && echo "claim-lock fixture: all checks hold" \
                  || echo "claim-lock fixture: FAILURES"
exit "$fail"
