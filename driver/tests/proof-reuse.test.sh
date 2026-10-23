#!/usr/bin/env bash
# proof-reuse.test.sh — the before/after proof trees are made once per run and reused by
# every later task (the owner, 2026-10-23: two fresh trees, each running worktree.prepare,
# were ~30% of proof time — 1,672 of 5,676 s over 21 proofs on the origin project).
# A later proof checks the tree out at its commit and skips worktree.prepare while the
# prepare fingerprint (prisma files, lockfiles, the prepare commands) is unchanged; it
# prepares again when that moves. The run's exit removes the trees.
# Run: bash "$0"
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/tests/lib/suite.sh" || exit 1
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
. "$HERE/fixture.sh"
driver_fixture; on_exit_keep_status 'rm -rf "$FIX"'
. "$HERE/../steps/build.sh" || exit 1
# worktree.prepare counts its runs, so a skipped prepare is visible.
jq --arg log "$FIX/prepare.log" '.worktree = ((.worktree // {}) + {prepare: ["pwd >> \($log)"]})' "$HARNESS_CFG_PATH" > "$FIX/cfg.json"
export HARNESS_CFG="$FIX/cfg.json" HARNESS_CFG_PATH="$FIX/cfg.json" DRIVER_TICKET=401
: > "$FIX/prepare.log"

task() { # <n> [schema line] — one task: a test commit, then the change it proves
  printf '#!/usr/bin/env bash\ngrep -q "f%s=yes" f%s.txt\n' "$1" "$1" > "$REPO/f$1.test.sh"
  printf 'f%s=no\n' "$1" > "$REPO/f$1.txt"
  [ -z "${2:-}" ] || { mkdir -p "$REPO/prisma"; printf '%s\n' "$2" >> "$REPO/prisma/schema.prisma"; }
  git -C "$REPO" add -A; git -C "$REPO" commit -qm "test: f$1"; TS=$(git -C "$REPO" rev-parse HEAD)
  printf 'f%s=yes\n' "$1" > "$REPO/f$1.txt"; git -C "$REPO" add -A; git -C "$REPO" commit -qm "feat: f$1"; IS=$(git -C "$REPO" rev-parse HEAD)
}
prove() { OUT=$(driver_prove_red_green "$REPO" "f$1.test.sh" "$TS" "$IS" "bash f$1.test.sh" 2>&1); RC=$?; }
preps() { grep -c . "$FIX/prepare.log"; }
D=$(_driver_proof_reuse_dir)

echo "--- the first task makes the two trees and prepares each ---"
task 1; prove 1
want "it proves"                               "0" "$RC"
want "worktree.prepare ran in both trees"      "2" "$(preps)"
want "the trees stay for the next task"        "2" "$(git -C "$REPO" worktree list | grep -c "$(basename "$D")/")"

echo "--- the second task reuses them, and skips the prepare ---"
task 2; prove 2
want "it proves"                               "0" "$RC"
want_in "it says the tree was reused"          'proof: reused .*/before .* worktree.prepare is skipped' "$OUT"
want "no prepare ran again"                    "2" "$(preps)"
want "still the same two trees"                "2" "$(git -C "$REPO" worktree list | grep -c "$(basename "$D")/")"
want "the tree is at the task's change"        "$IS" "$(git -C "$D/after" rev-parse HEAD)"
want "and holds no file the last task left"    "" "$(git -C "$D/after" status --porcelain)"

echo "--- a schema change moves the fingerprint: the prepare runs again ---"
task 3 'model Thing { id Int @id }'; prove 3
want "it proves"                               "0" "$RC"
want "the prepare ran in the tree whose schema moved" "1" "$(( $(preps) > 2 ? 1 : 0 ))"

echo "--- a red is still a red in a reused tree ---"
printf '#!/usr/bin/env bash\ngrep -q "f4=yes" f4.txt\n' > "$REPO/f4.test.sh"; printf 'f4=yes\n' > "$REPO/f4.txt"
git -C "$REPO" add -A; git -C "$REPO" commit -qm "test: f4"; TS=$(git -C "$REPO" rev-parse HEAD)
printf 'x\n' > "$REPO/other.txt"; git -C "$REPO" add -A; git -C "$REPO" commit -qm "feat: unrelated"; IS=$(git -C "$REPO" rev-parse HEAD)
prove 4
want "a test green without the change is refused" "1" "$RC"

echo "--- the run's exit removes them ---"
driver_proof_trees_drop
want "no tree left"                            "0" "$(git -C "$REPO" worktree list | grep -c "$(basename "$D")" || true)"
want "nor the dir"                             "no" "$([ -e "$D" ] && echo yes || echo no)"
# Read with grep on the file: a whole build-ticket piped into grep -q dies on SIGPIPE under pipefail.
want "build-ticket drops them on exit"         "1" "$(grep -cE "^trap .*driver_proof_trees_drop.* EXIT$" "$ROOT/driver/build-ticket")"

echo "--- driver.proofReuse false builds fresh trees, as before ---"
jq '.driver = ((.driver // {}) + {proofReuse: false})' "$FIX/cfg.json" > "$FIX/off.json"; : > "$FIX/prepare.log"
task 5; HARNESS_CFG="$FIX/off.json" prove 5
want "it proves"                               "0" "$RC"
task 6; HARNESS_CFG="$FIX/off.json" prove 6
want "every proof prepares both trees"         "4" "$(preps)"
want "and leaves none"                         "0" "$(git -C "$REPO" worktree list | grep -c driver-proof || true)"

echo "--- plant: the fingerprint compare out, every task prepares again ---"
_driver_proof_fingerprint() { date +%s%N; }
: > "$FIX/prepare.log"; task 7; prove 7; task 8; prove 8
want "planted: the second task prepares again" "4" "$(preps)"
driver_proof_trees_drop

suite_end "$FAILED"
