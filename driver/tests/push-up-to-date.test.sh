#!/usr/bin/env bash
# push-up-to-date.test.sh — a push of a branch origin already has at this head is a push
# with nothing in it, and is not made. git hands such a push's hook no refs, so a hook that
# skips "a head gates.local passed" had none to name and ran its whole suite: #14529
# (2026-10-24) parked twice on code gates develop does not require, its branch already on
# origin. A branch ahead of origin still pushes, through the hook, as before.
# Run: bash "$0"
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/tests/lib/suite.sh" || exit 1
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/fixture.sh"
driver_fixture; on_exit_keep_status 'rm -rf "$FIX"'
ROOT="$(cd "$HERE/../.." && pwd)"
. "$HERE/../state.sh" || exit 1
export SUITE_LOG="$FIX/suite.log"; : > "$SUITE_LOG"
git init -q --bare "$FIX/origin"; git -C "$REPO" remote add origin "$FIX/origin"; git -C "$REPO" push -q origin develop

# The project's pre-push, shaped like the one #14529 met: it runs nothing when every ref it
# is handed is the head the driver names, and its whole (red) suite otherwise.
HOOKS="$(git -C "$REPO" rev-parse --path-format=absolute --git-common-dir)/hooks"; mkdir -p "$HOOKS"
cat > "$HOOKS/pre-push" <<'SH'
#!/usr/bin/env bash
pushed=0; unpassed=0
while read -r l s r rs; do
  [ "$r" = refs/heads/develop ] && exit 0
  pushed=$((pushed + 1)); [ "$s" = "${HARNESS_LOCAL_GATES_HEAD:-}" ] || unpassed=$((unpassed + 1))
done
[ -n "${HARNESS_LOCAL_GATES_HEAD:-}" ] && [ "$pushed" -gt 0 ] && [ "$unpassed" -eq 0 ] && exit 0
echo suite >> "$SUITE_LOG"
echo "✗ check:composition  (required check: Code gates)"; exit 1
SH
chmod +x "$HOOKS/pre-push"

branch() { # <ticket> — a branch off the trunk with one commit
  git -C "$REPO" worktree add -q "$FIX/t$1" -b "tkt-$1/work" develop
  printf 'a\n' > "$FIX/t$1/a$1.txt"; git -C "$FIX/t$1" add -A; git -C "$FIX/t$1" -c user.email=t@e.invalid -c user.name=T commit -qm "feat: a"
  driver_state_init "$1" --worktree "$FIX/t$1" --branch "tkt-$1/work"
}
push() { # <ticket> [head to name] — driver_push from ${SUT_KIT:-the kit}; R_RC its exit
  R_RC=0
  R_OUT=$(bash -c 'unset DRIVER_DIR DRIVER_HOME KIT_ROOT HARNESS_KIT_ROOT; . "$1/driver/driver-env.sh" && . "$1/driver/state.sh" || exit 9
    [ -z "$4" ] || driver_state_set "$2" local_gates_head "$4"
    driver_push "$2" "$3" "tkt-$2/work" ship' _ "${SUT_KIT:-$ROOT}" "$1" "$FIX/t$1" "${2:-}" 2>&1) || R_RC=$?
}
suite_runs() { grep -c . "$SUITE_LOG"; }

N=900
case_uptodate() { N=$((N + 1)); : > "$SUITE_LOG"; branch "$N"
  git -C "$FIX/t$N" push -q --no-verify origin "refs/heads/tkt-$N/work:refs/heads/tkt-$N/work"  # origin already has it, as #14529's had
  push "$N"; R="rc=$R_RC suite=$(suite_runs)"; }
case_ahead() { N=$((N + 1)); : > "$SUITE_LOG"; branch "$N"
  push "$N"; R="rc=$R_RC suite=$(suite_runs) origin=$(git --git-dir="$FIX/origin" rev-parse -q --verify "refs/heads/tkt-$N/work" >/dev/null && echo has || echo lacks)"; }

echo "--- origin already has the branch at this head: nothing pushed, no hook run ---"
case_uptodate
want "it is not refused, and the hook's suite never ran" "rc=0 suite=0" "$R"
want_in "it says so"                                   'origin already has tkt-901/work at .* nothing to push' "$R_OUT"
want "the pushed head is on the record"                "$(git -C "$FIX/t$N" rev-parse HEAD)" "$(driver_state_get "$N" pushed_head)"

echo "--- a branch origin lacks still goes through the hook, as before ---"
case_ahead
want "the hook ran its suite and refused it"           "rc=1 suite=1 origin=lacks" "$R"

KIT="$FIX/kit"
kit_copy() { rm -rf "$KIT"; mkdir -p "$KIT"; cp -R "$ROOT/driver" "$ROOT/scripts" "$ROOT/swarm" "$ROOT/shared" "$KIT/"; }
plant() { # <label> <file under the kit> <exact text to delete>
  kit_copy
  python3 - "$KIT/$2" "$3" <<'PY' || { bad "plant ($1) did not land"; return 1; }
import sys
p, old = sys.argv[1], sys.argv[2]
s = open(p).read()
if s.count(old) != 1: sys.exit(1)
open(p, "w").write(s.replace(old, ""))
PY
}
kit_copy
SUT_KIT="$KIT" case_uptodate; want "the unplanted kit: an up-to-date push is not refused" "rc=0 suite=0" "$R"
plant "an up-to-date push is not made" driver/driver-env.sh '  if [ -n "$here" ] && [ "$here" = "$there" ]; then
    printf '"'"'origin already has refs/heads/%s at %s: nothing to push, so the pre-push was not run\n'"'"' "$branch" "$here" > "$f"
    DRIVER_PUSH_OUT="$f"; DRIVER_PUSH_WHY=""
    git -C "$wt" update-ref "refs/remotes/origin/$branch" "$here" >/dev/null 2>&1 \
      && git -C "$wt" branch -q --set-upstream-to "origin/$branch" "$branch" >/dev/null 2>&1 || true
    driver_say "   $slot: origin already has $branch at $(printf '"'"'%s'"'"' "$here" | cut -c1-10) — nothing to push"
    driver_state_set "$t" pushed_head "$here"
    return 0
  fi
' && { SUT_KIT="$KIT" case_uptodate; want "planted: the hook runs its suite on no refs and refuses it (#14529)" "rc=1 suite=1" "$R"; }

# The ship step's side (a refused head goes to fix, not a machine park): merge-first.test.sh.

suite_end "$FAILED"
