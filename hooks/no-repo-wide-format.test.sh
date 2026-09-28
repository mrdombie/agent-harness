#!/usr/bin/env bash
# Self-test for no-repo-wide-format.sh — the formatter half and the
# whole-app-check half, each with the allow case that proves it discriminates.
D="$(cd "$(dirname "$0")" && pwd)"; H="$D/no-repo-wide-format.sh"; fail=0
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
# A package.json whose plain names are WHOLE-APP, so `full()` answers truthfully
# rather than on whatever repo the suite happens to run in.
cat > "$TMP/package.json" <<'PKG'
{"scripts":{"lint":"eslint .","typecheck":"tsc -b","test":"vitest run",
            "lint:changed":"sh s.sh","typecheck:changed":"sh s.sh","test:changed":"sh s.sh"}}
PKG

run(){ ( cd "$TMP"; printf '{"tool_input":{"command":%s}}' "$(jq -Rn --arg c "$1" '$c')" \
           | bash "$H" >/dev/null 2>&1; echo $? ); }
check(){ want=$1; shift; cmd=$1; shift; desc=$*
  rc=$(run "$cmd"); got=allow; [ "$rc" -eq 2 ] && got=block
  if [ "$got" = "$want" ]; then printf 'ok   %-5s %s\n' "$want" "$desc"
  else printf 'FAIL %-5s got %s — %s\n' "$want" "$got" "$desc"; fail=1; fi; }

echo "--- formatter (always on) ---"
unset CLAIM_RUN_LOG
check block 'npx prettier --write apps/'        'prettier over a folder'
check block 'npx prettier --write .'            'prettier over the repo'
check block "npx prettier --write 'src/**/*.ts'" 'prettier over a glob'
check block 'npm run format'                    'the whole-repo format script'
check allow 'npx prettier --write src/one.ts'   'prettier on one named file'
check allow 'npm run format:changed'            'the changed-only format script'
check allow "echo 'npx prettier --write apps/'" 'the same words inside a string'

echo "--- whole-app checks (unattended runs only) ---"
export CLAIM_RUN_LOG=/tmp/fake.log
check block 'npm run typecheck'                 'whole-app typecheck from a spawned agent'
check block 'npm test'                          'the whole suite from a spawned agent'
check block 'npm run lint'                      'whole-repo lint from a spawned agent'
check allow 'npm run typecheck:changed'         'the changed-only typecheck'
check allow 'npm run test:changed'              'the changed-only suite'
check allow 'npx vitest run src/a.test.ts'      'one named test file'
unset CLAIM_RUN_LOG
check allow 'npm run typecheck'                 'an interactive session is untouched'

echo "--- the message names the CONFIGURED commands ---"
out=$( cd "$TMP"; printf '{"tool_input":{"command":"npm run typecheck"}}' \
       | CLAIM_RUN_LOG=/tmp/f HARNESS_GATES_CHANGED='just check' bash "$H" 2>&1 >/dev/null )
if printf '%s' "$out" | grep -q 'just check'; then echo "ok   the configured changed-only command is quoted back"
else echo "FAIL the message ignored HARNESS_GATES_CHANGED"; fail=1; fi

[ "$fail" -eq 0 ] && echo "no-repo-wide-format: all cases pass"
exit $fail
