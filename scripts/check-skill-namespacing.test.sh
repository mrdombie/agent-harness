#!/usr/bin/env bash
# Fixture test for check-skill-namespacing.sh.
#
# WHY THIS EXISTS
#   The kit is clean today, so running the gate on the kit proves nothing: a gate
#   that matches nothing and a gate that never ran print the same line. Every case
#   below builds a throwaway kit, PLANTS a bare reference, and asserts the gate
#   stops and names it — or plants one of the shapes that must NOT be flagged and
#   asserts it passes. Nothing here reads the real kit.
set -uo pipefail

SUT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/check-skill-namespacing.sh"
[ -f "$SUT" ] || { echo "missing $SUT"; exit 2; }

SB="${TMPDIR:-/tmp}/ns-gate-fixture-$$"
mkdir -p "$SB"
trap 'rm -rf "$SB"' EXIT
fail=0
ok()  { echo "  ok   — $1"; }
bad() { echo "  FAIL — $1"; fail=1; }

# A throwaway kit. $1 names it; the caller then writes files and calls check().
kit() {
  K="$SB/$1"; rm -rf "$K"
  mkdir -p "$K/scripts" "$K/.claude-plugin" "$K/skills/claim" "$K/skills/claim-status" \
           "$K/skills/finish" "$K/skills/queue" "$K/shared" "$K/agents"
  cp "$SUT" "$K/scripts/"
  printf '{"name":"agent-harness","version":"0.0.0"}\n' > "$K/.claude-plugin/plugin.json"
  for s in claim claim-status finish queue; do
    printf 'placeholder\n' > "$K/skills/$s/SKILL.md"
  done
  # Something namespaced, so the gate's own control probe is satisfied. Without it
  # every case below would exit 2 and the plants would never be reached.
  printf 'run /agent-harness:claim to start.\n' > "$K/shared/operator.md"
  git -C "$K" -c init.defaultBranch=main init -q
}
check() {
  git -C "$K" add scripts skills shared agents .claude-plugin >/dev/null 2>&1
  OUT=$(cd "$K" && bash "$K/scripts/check-skill-namespacing.sh" 2>&1); RC=$?
}

echo "check-skill-namespacing fixture"

# --- 1. THE PLANT: a bare reference to one of our own skills -------------------
kit plant
printf 'line one\nline two\nthen invoke /finish when the gates are green.\n' > "$K/shared/run.md"
check
[ "$RC" -eq 1 ] && ok "a bare /finish stops the gate" || bad "a bare /finish passed (rc $RC)"
printf '%s' "$OUT" | grep -q 'shared/run.md:3: /finish' \
  && ok "it names the file and the line" \
  || bad "it did not name shared/run.md:3 — got: $(printf '%s' "$OUT" | grep run.md)"

# --- 2. The line number is per FILE, not per batch ----------------------------
# A single perl pass over many files keeps counting unless ARGV is closed at eof,
# so the reported line was an offset into the concatenated stream — a number that
# points at the wrong line is worse than none.
kit lineno
printf 'a\nb\nc\nd\ne\nf\ng\nh\n' > "$K/shared/aaa.md"
printf 'x\ny\ninvoke /finish here\n' > "$K/shared/zzz.md"
check
printf '%s' "$OUT" | grep -q 'shared/zzz.md:3: /finish' \
  && ok "the line number is counted within its own file" \
  || bad "wrong line number: $(printf '%s' "$OUT" | grep zzz)"

# --- 3. Namespaced is what the gate is asking for -----------------------------
kit clean
printf 'then invoke /agent-harness:finish when the gates are green.\n' > "$K/shared/run.md"
check
[ "$RC" -eq 0 ] && ok "a namespaced reference passes" || bad "a namespaced reference failed: $OUT"

# --- 4. `# via /finish` is a hook marker, not an invocation --------------------
# The guard hooks grep for this exact string. Renaming it to satisfy a gate would
# break the hook it belongs to, so it is exempt by construction, not by a comment.
kit marker
printf 'gh pr create --base develop `# via /finish` --body x\n' > "$K/shared/run.md"
check
[ "$RC" -eq 0 ] && ok "the '# via /finish' hook marker is not a reference" \
                || bad "the hook marker was flagged: $OUT"

# --- 5. A path that merely contains a skill name is not a reference -----------
kit path
printf 'QUEUE="$(dirname "$0")/queue.sh"\nsee skills/claim/SKILL.md\n' > "$K/shared/run.md"
check
[ "$RC" -eq 0 ] && ok "/queue.sh and skills/claim/ are paths, not references" \
                || bad "a path was read as a reference: $OUT"

# --- 6. The longest name wins, so /claim-status is not /claim ------------------
kit longest
printf 'invoke /claim-status to see the fleet.\n' > "$K/shared/run.md"
check
printf '%s' "$OUT" | grep -q '/claim-status' \
  && ok "/claim-status is read as claim-status" || bad "not reported as claim-status: $OUT"
printf '%s' "$OUT" | grep -qE ': /claim$' \
  && bad "/claim-status was also reported as /claim" \
  || ok "and not also as /claim"

# --- 7. A skill the kit does NOT ship is none of its business -----------------
kit foreign
printf 'the project has its own /design and /critic — leave them bare.\n' > "$K/shared/run.md"
check
[ "$RC" -eq 0 ] && ok "a skill the kit does not ship is left alone" \
                || bad "a foreign skill was flagged: $OUT"

# --- 8. The escape works ------------------------------------------------------
kit escape
printf 'run /finish  <!-- harness:bare-ok: means the project own copy -->\n' > "$K/shared/run.md"
check
[ "$RC" -eq 0 ] && ok "harness:bare-ok on the line exempts it" || bad "the escape did not work: $OUT"

# --- 9. It refuses rather than reporting clean when it can see nothing --------
# The gate's silence must mean "looked and found none", never "found no files".
kit blind
rm -f "$K/shared/operator.md"
printf 'nothing namespaced anywhere\n' > "$K/shared/run.md"
check
[ "$RC" -eq 2 ] && ok "no namespaced reference at all is a refusal, not a pass" \
                || bad "it reported on a corpus it could not prove it had read (rc $RC)"
kit noskills
rm -rf "$K"/skills
check
[ "$RC" -eq 2 ] && ok "no skills/ directories is a refusal too" || bad "rc $RC with no skills"

echo
[ "$fail" -eq 0 ] && echo "check-skill-namespacing: all cases pass" || echo "check-skill-namespacing: FAILURES above"
exit $fail
