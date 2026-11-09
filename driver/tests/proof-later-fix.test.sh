#!/usr/bin/env bash
# proof-later-fix.test.sh — a fix committed after a feature's change commit counts.
# A rework keeps reporting its first test/change pair; when green or the typecheck fails
# at the change, the proof is taken again at the latest branch commit touching the test's
# or the change's files, so a later commit that clears a compile error is seen. The red half stays at the
# change's parent, and a later commit on other files does not move green.
# Run: bash "$0"
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/tests/lib/suite.sh" || exit 1
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/fixture.sh"
driver_fixture; on_exit_keep_status 'rm -rf "$FIX"'
. "$HERE/../steps/build.sh" || exit 1
# The proof's typecheck fails while bad.txt or any test holds 'cast'.
printf '#!/usr/bin/env bash\n! grep -qs cast bad.txt ./*.test.sh\n' > "$REPO/tc.sh"
git -C "$REPO" add -A; git -C "$REPO" commit -qm "tc"
jq '.driver = ((.driver // {}) + {proofTypecheck: "bash tc.sh"})' "$HARNESS_CFG_PATH" > "$FIX/on.json"
jq '.driver = (.driver + {proofReuse: false})' "$FIX/on.json" > "$FIX/off.json"
export HARNESS_CFG="$FIX/on.json" HARNESS_CFG_PATH="$FIX/on.json" DRIVER_TICKET=402

feature() { # <n> — a test commit, then a change that passes it but does not type-check
  printf '#!/usr/bin/env bash\ngrep -q "f%s=yes" f%s.txt\n' "$1" "$1" > "$REPO/f$1.test.sh"
  printf 'f%s=no\n' "$1" > "$REPO/f$1.txt"
  git -C "$REPO" add -A; git -C "$REPO" commit -qm "test: f$1"; TS=$(git -C "$REPO" rev-parse HEAD)
  printf 'f%s=yes\n' "$1" > "$REPO/f$1.txt"; printf 'cast\n' > "$REPO/bad.txt"
  git -C "$REPO" add -A; git -C "$REPO" commit -qm "feat: f$1"; IS=$(git -C "$REPO" rev-parse HEAD)
}
later_fix() { : > "$REPO/bad.txt"; git -C "$REPO" add -A; git -C "$REPO" commit -q --allow-empty -m "fix: type error"; }
prove() { OUT=$(driver_prove_red_green "$REPO" "f$1.test.sh" "$TS" "$IS" "bash f$1.test.sh" 2>&1); RC=$?; }
short() { git -C "$REPO" rev-parse HEAD | cut -c1-8; }

echo "--- reused trees: the test commit does not type-check, a later commit fixes only the test ---"
printf '#!/usr/bin/env bash\n# cast\ngrep -q "f1=yes" f1.txt\n' > "$REPO/f1.test.sh"; printf 'f1=no\n' > "$REPO/f1.txt"
git -C "$REPO" add -A; git -C "$REPO" commit -qm "test: f1"; TS=$(git -C "$REPO" rev-parse HEAD)
printf 'f1=yes\n' > "$REPO/f1.txt"; git -C "$REPO" add -A; git -C "$REPO" commit -qm "feat: f1"; IS=$(git -C "$REPO" rev-parse HEAD)
prove 1
want "round 1 refuses on the typecheck"         "6" "$RC"
printf '#!/usr/bin/env bash\ngrep -q "f1=yes" f1.txt\n' > "$REPO/f1.test.sh"
git -C "$REPO" add -A; git -C "$REPO" commit -qm "test: f1 without the cast"; prove 1
want "round 2 with the same pair proves"        "0" "$RC"
want_in "green is taken at the fixing commit"   "then green at $(short)" "$OUT"
driver_proof_trees_drop

echo "--- fresh trees (driver.proofReuse false): the same two rounds ---"
feature 2; HARNESS_CFG="$FIX/off.json" prove 2
want "round 1 refuses on the typecheck"         "6" "$RC"
later_fix; HARNESS_CFG="$FIX/off.json" prove 2
want "round 2 with the same pair proves"        "0" "$RC"
want_in "green is taken at the fixing commit"   "then green at $(short)" "$OUT"

echo "--- a later commit on other files does not make a named non-fix prove ---"
printf '#!/usr/bin/env bash\ngrep -qs "f5=yes" f5.txt\n' > "$REPO/f5.test.sh"
git -C "$REPO" add -A; git -C "$REPO" commit -qm "test: f5"; TS=$(git -C "$REPO" rev-parse HEAD)
printf 'noise\n' > "$REPO/noise.txt"; git -C "$REPO" add -A; git -C "$REPO" commit -qm "feat: not the fix"; IS=$(git -C "$REPO" rev-parse HEAD)
printf 'f5=yes\n' > "$REPO/f5.txt"; git -C "$REPO" add -A; git -C "$REPO" commit -qm "fix: the real fix, unreported"
HARNESS_CFG="$FIX/off.json" prove 5
want "still fails with the named change"        "2" "$RC"

echo "--- a change not on the branch is still proved at that commit ---"
printf '#!/usr/bin/env bash\ngrep -q "f3=yes" f3.txt\n' > "$REPO/f3.test.sh"; printf 'f3=no\n' > "$REPO/f3.txt"
git -C "$REPO" add -A; git -C "$REPO" commit -qm "test: f3"; TS=$(git -C "$REPO" rev-parse HEAD)
git -C "$REPO" switch -q -c side
printf 'f3=yes\n' > "$REPO/f3.txt"; git -C "$REPO" add -A; git -C "$REPO" commit -qm "feat: f3"; IS=$(git -C "$REPO" rev-parse HEAD)
git -C "$REPO" switch -q develop
HARNESS_CFG="$FIX/off.json" prove 3
want "the off-branch change proves"             "0" "$RC"
want_in "green is taken at the change itself"   "then green at $(printf '%s' "$IS" | cut -c1-8)" "$OUT"

echo "--- a test green without the change is still refused at the change's parent ---"
printf '#!/usr/bin/env bash\ngrep -q "f4=yes" f4.txt\n' > "$REPO/f4.test.sh"; printf 'f4=yes\n' > "$REPO/f4.txt"
git -C "$REPO" add -A; git -C "$REPO" commit -qm "test: f4"; TS=$(git -C "$REPO" rev-parse HEAD)
printf 'x\n' > "$REPO/other.txt"; git -C "$REPO" add -A; git -C "$REPO" commit -qm "feat: unrelated"; IS=$(git -C "$REPO" rev-parse HEAD)
later_fix; HARNESS_CFG="$FIX/off.json" prove 4
want "a test green without the change is refused" "1" "$RC"

suite_end "$FAILED"
