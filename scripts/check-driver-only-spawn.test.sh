#!/usr/bin/env bash
# check-driver-only-spawn.test.sh — the kit as it stands passes; each way back to an
# unattended prose claim, planted in a copy, fails by name.
# Run: bash "$0"
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/tests/lib/suite.sh" || exit 1
for v in $(env | sed -n 's/^\(GIT_[A-Z_]*\)=.*/\1/p'); do unset "$v"; done
HERE="$(cd "$(dirname "$0")" && pwd)"
KIT="$(cd "$HERE/.." && pwd)"
C="$HERE/check-driver-only-spawn.sh"
T=$(mktemp -d); on_exit_keep_status 'rm -rf "$T"'
FAILED=0
ok()  { echo "OK       $1"; }
bad() { echo "MISMATCH $1"; FAILED=1; }

out=$(bash "$C"); rc=$?
[ "$rc" = 0 ] && [ -z "$out" ] && ok "the kit passes: no unattended prose path" || bad "the kit was flagged (rc=$rc): $out"

copy() { rm -rf "$T/kit"; mkdir -p "$T/kit"; (cd "$KIT" && tar -cf - scripts swarm driver) | tar -xf - -C "$T/kit"; }

# 1. A second launcher of the prose claim, outside the spawner.
copy
printf '#!/usr/bin/env bash\nclaude -p "/agent-harness:claim $1" --permission-mode auto\n' > "$T/kit/swarm/fixer.sh"
out=$(bash "$C" "$T/kit"); rc=$?
[ "$rc" = 1 ] && printf '%s' "$out" | grep -q "swarm/fixer.sh:2: launches the prose claim" \
  && ok "a launcher of /agent-harness:claim in swarm/ is named" || bad "a second launcher passed (rc=$rc): $out"
printf '#!/usr/bin/env bash\n# runs /agent-harness:claim-status for the view\nclaude -p "/agent-harness:claim-status"\n' > "$T/kit/swarm/fixer.sh"
out=$(bash "$C" "$T/kit"); rc=$?
[ "$rc" = 0 ] && ok "a comment, and /agent-harness:claim-status, are not a launcher" || bad "flagged correct code: $out"

# 2. A prose fallback put back in an unattended branch of the spawner.
copy
perl -0pi -e 's/(  DRIVER_MODE=adopt\n)/  BUILDER=prose; DRIVER_MODE=build\n/' "$T/kit/scripts/spawn-claim.sh"
grep -q '^  BUILDER=prose; DRIVER_MODE=build$' "$T/kit/scripts/spawn-claim.sh" || bad "plant 2 did not land"
out=$(bash "$C" "$T/kit"); rc=$?
[ "$rc" = 1 ] && printf '%s' "$out" | grep -q 'sets BUILDER=prose without' \
  && ok "a prose fallback for the draft branch is named" || bad "the prose fallback passed (rc=$rc): $out"

# 3. The marker on the --fg default deleted: the plant of absence.
copy
sed -i.bak 's/ # prose: --fg only$//' "$T/kit/scripts/spawn-claim.sh"
grep -q 'prose: --fg only' "$T/kit/scripts/spawn-claim.sh" && bad "plant 3 did not land"
out=$(bash "$C" "$T/kit"); rc=$?
[ "$rc" = 1 ] && ok "an unmarked BUILDER=prose default fails" || bad "the unmarked default passed: $out"

# 4. The unattended pick-next refusal deleted.
copy
perl -0pi -e 's/if \[ -z "\$TICKET" \] && \[ "\$FG" -eq 0 \]; then\n.*?\n  exit 2\nfi\n//s' "$T/kit/scripts/spawn-claim.sh"
grep -q -- '-z "$TICKET" \] && \[ "$FG" -eq 0' "$T/kit/scripts/spawn-claim.sh" && bad "plant 4 did not land"
out=$(bash "$C" "$T/kit"); rc=$?
[ "$rc" = 1 ] && printf '%s' "$out" | grep -q 'no refusal of an unattended run with no ticket' \
  && ok "a spawner with no pick-next refusal fails" || bad "the missing refusal passed (rc=$rc): $out"

suite_end "$FAILED"
