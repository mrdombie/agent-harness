#!/usr/bin/env bash
# local-gates.test.sh — under gates.localOnly the prose flow's local gates are gates.local
# and never gates.changed's tests; without it, gates.changed as before; the skills and
# the gate-runner read them through the helper, and the lint catches one that inlines jq.
# Run: bash "$0"
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/tests/lib/suite.sh" || exit 1
for v in $(env | sed -n 's/^\(GIT_[A-Z_]*\)=.*/\1/p'); do unset "$v"; done
KIT="$(cd "$(dirname "$0")/.." && pwd)"
LG="$KIT/scripts/local-gates.sh"
LINT="$KIT/scripts/check-local-gates-inline.sh"
T=$(mktemp -d); on_exit_keep_status 'rm -rf "$T"'
FAILED=0
ok()  { echo "OK       $1"; }
bad() { echo "MISMATCH $1"; FAILED=1; }
unset HARNESS_CFG_PATH

# Checked-in, read-only project configs: lo, nolo, loempty, none, site-lo, site-nolo.
F="$KIT/scripts/fixtures/local-gates"
GATES=$(jq -c '.gates | del(.localOnly)' "$F/nolo/.claude/harness.json")
cp -R "$F"/. "$T"/

echo "--- the helper ---"
out=$(cd "$T/lo" && bash "$LG"); rc=$?
[ "$rc" = 0 ] && [ "$out" = "$(jq -r '.local[]' <<<"$GATES")" ] && ok "localOnly prints gates.local, in order" || bad "localOnly: rc=$rc out=$out"
case "$out" in *test:changed*) bad "localOnly printed test:changed" ;; *) ok "localOnly never prints test:changed" ;; esac
out=$(cd "$T/lo" && bash "$LG" --joined)
[ "$out" = "npm run lint:changed && npm run typecheck:changed && npm run format:changed" ] && ok "--joined joins gates.local with &&" || bad "joined: $out"
out=$(cd "$T/nolo" && bash "$LG"); rc=$?
[ "$rc" = 0 ] && [ "$out" = "$(jq -r '.changed[]' <<<"$GATES")" ] && ok "without localOnly it prints gates.changed, as before" || bad "no localOnly: rc=$rc out=$out"
out=$(cd "$T/lo" && HARNESS_CFG_PATH="$T/nolo/.claude/harness.json" bash "$LG")
[ "$out" = "$(jq -r '.local[]' <<<"$GATES")" ] && ok "the checkout's own config, not HARNESS_CFG_PATH (a coordinator's copy)" || bad "HARNESS_CFG_PATH won: $out"
out=$(bash "$LG" "$T/nolo/.claude/harness.json")
[ "$out" = "$(jq -r '.changed[]' <<<"$GATES")" ] && ok "a path argument names the config" || bad "path arg: $out"
out=$(cd "$T/loempty" && bash "$LG" 2>&1); rc=$?
[ "$rc" = 2 ] && ! printf '%s' "$out" | grep -q 'test:changed' && printf '%s' "$out" | grep -q 'gates.localOnly' \
  && ok "localOnly with no gates.local refuses, rather than fall back to gates.changed" || bad "loempty: rc=$rc out=$out"
out=$(cd "$T/none" && bash "$LG"); rc=$?
[ "$rc" = 0 ] && [ -z "$out" ] && ok "no lists: empty, exit 0" || bad "none: rc=$rc out=$out"
out=$(cd "$T" && bash "$LG" 2>&1); rc=$?
[ "$rc" = 2 ] && ok "no config: exit 2" || bad "no config: rc=$rc"

echo "--- the call sites run what the helper says ---"
# site-*: gates.local marks "local"; gates.changed's test command marks "test".
blocks() { # <file> — every ```bash block mentioning local-gates.sh and machine-gate.sh, NUL-separated
  awk '/^[[:space:]]*```bash[[:space:]]*$/{inb=1; b=""; next}
       inb && /^[[:space:]]*```[[:space:]]*$/{inb=0; if (b ~ /local-gates\.sh/ && b ~ /machine-gate\.sh/) printf "%s%c", b, 0; next}
       inb{b=b $0 "\n"}' "$1"
}
site() { # <label> <file>
  local n=0 b
  while IFS= read -r -d '' b; do
    n=$((n+1))
    mkdir -p "$T/m-lo" "$T/m-nolo"; rm -f "$T/m-lo/"* "$T/m-nolo/"*
    (cd "$T/site-lo" && MARK="$T/m-lo" CLAUDE_PLUGIN_ROOT="$KIT" SWARM_LOAD=1 SWARM_IDLE=90 MACHINE_GATE_MAX_WAIT=1 bash -c "$b" >/dev/null 2>&1)
    [ -e "$T/m-lo/local" ] && [ ! -e "$T/m-lo/test" ] && ok "$1: block $n under localOnly runs gates.local and no test" \
      || bad "$1: block $n under localOnly (local=$([ -e "$T/m-lo/local" ] && echo ran || echo no) test=$([ -e "$T/m-lo/test" ] && echo ran || echo no))"
    (cd "$T/site-nolo" && MARK="$T/m-nolo" CLAUDE_PLUGIN_ROOT="$KIT" SWARM_LOAD=1 SWARM_IDLE=90 MACHINE_GATE_MAX_WAIT=1 bash -c "$b" >/dev/null 2>&1)
    [ -e "$T/m-nolo/local" ] && ok "$1: block $n without localOnly still runs gates.changed" || bad "$1: block $n without localOnly ran nothing"
  done < <(blocks "$2")
  [ "$n" -gt 0 ] || bad "$1: no bash block reads the gates through local-gates.sh"
}
site finish      "$KIT/skills/finish/SKILL.md"
site gate-runner "$KIT/agents/gate-runner.md"
grep -q 'scripts/local-gates.sh' "$KIT/skills/claim/SKILL.md" && ok "claim's build loop names the helper" || bad "claim's build loop does not name local-gates.sh"

echo "--- the lint ---"
printf 'Run:\n```bash\nCHANGED=$(jq -r %s .claude/harness.json)\n```\n' "'(.gates.changed // []) | join(\" && \")'" > "$T/inline.md"
printf 'G=$(jq -r %s .claude/harness.json)\n' "'.gates | .changed[0]'" > "$T/inline2.md"
printf 'Run `"${CLAUDE_PLUGIN_ROOT}/scripts/local-gates.sh"`; prose may say `gates.changed`.\n' > "$T/helper.md"
bash "$LINT" "$T/inline.md" >/dev/null; [ "$?" = 1 ] && ok "an inlined .gates.changed fails the lint" || bad "the inlined read passed"
bash "$LINT" "$T/inline2.md" >/dev/null; [ "$?" = 1 ] && ok "a piped .gates | .changed fails it too" || bad "the piped read passed"
out=$(bash "$LINT" "$T/helper.md"); rc=$?
[ "$rc" = 0 ] && ok "a helper call and prose naming gates.changed pass" || bad "flagged correct text: $out"
out=$(bash "$LINT"); rc=$?
[ "$rc" = 0 ] && printf '%s' "$out" | grep -qE 'control, call sites of local-gates.sh : [1-9]' \
  && ok "the kit's skills, agents and rules read the gates only through the helper" || bad "the kit: rc=$rc $out"

suite_end "$FAILED"
