#!/usr/bin/env bash
# Self-test for lib/python.sh, through the two guards that use it (#40).
#
# The failure this pins: on Windows `python3` is a Store stub that exits 49, and
# the guards exec'd it, so every command passed unjudged. Each case puts stubs
# first on PATH, so it runs the same on a machine that has no stub at all.
D="$(cd "$(dirname "$0")/.." && pwd)"; fail=0
. "$D/lib/python.sh"
harness_python || { echo "FAIL no working Python on this machine to test with"; exit 1; }
# An ABSOLUTE path to it, plus its arguments ("py -3"): the cases below put stubs
# first on PATH, and a wrapper that ran a bare name would find the stub (#43 review).
REAL=$(command -v "${HARNESS_PY[0]}") || { echo "FAIL cannot locate ${HARNESS_PY[0]}"; exit 1; }
REAL_ARGS="${HARNESS_PY[*]:1}"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

stub(){ printf '#!/usr/bin/env bash\necho "Python was not found; run without arguments to install from the Microsoft Store" >&2\nexit 49\n' > "$1/$2"; chmod +x "$1/$2"; }
ok(){ printf 'ok   %s\n' "$1"; }
no(){ printf 'FAIL %s\n' "$1"; fail=1; }
hook(){ # <bin dir> <guard> <command> → prints "<exit code>|<stderr>"
  local err rc
  err=$(printf '{"tool_input":{"command":%s}}' "$(jq -Rn --arg c "$3" '$c')" \
        | env -u HARNESS_PYTHON PATH="$1:$PATH" bash "$D/$2.sh" 2>&1 >/dev/null); rc=$?
  printf '%s|%s' "$rc" "$err"; }

echo "--- only stubs: every guard refuses, none passes ---"
ONLY="$TMP/only-stubs"; mkdir -p "$ONLY"
for n in python3 python py; do stub "$ONLY" "$n"; done
for g in no-repo-wide-format no-broad-kill; do
  r=$(hook "$ONLY" "$g" 'ls')
  if [ "${r%%|*}" = 2 ] && printf '%s' "$r" | grep -q "the $g guard cannot run"; then ok "$g refuses when no Python runs"
  else no "$g with only stubs gave '${r%%|*}' — ${r#*|}"; fi
done

echo "--- a stub in front of a real Python: the guard still judges ---"
BEHIND="$TMP/stub-in-front"; mkdir -p "$BEHIND"
# python3 and py are stubs, so the ONLY interpreter that runs is the `python`
# wrapper around the real one — no fallback can make a case pass on any OS.
stub "$BEHIND" python3; stub "$BEHIND" py
printf '#!/usr/bin/env bash\nexec %q %s "$@"\n' "$REAL" "$REAL_ARGS" > "$BEHIND/python"; chmod +x "$BEHIND/python"
r=$(hook "$BEHIND" no-repo-wide-format 'npx prettier --write .')
if [ "${r%%|*}" = 2 ] && printf '%s' "$r" | grep -q 'reflows files'; then ok "repo-wide format still blocked past the stub"
else no "repo-wide format past the stub gave '${r%%|*}' — ${r#*|}"; fi
r=$(hook "$BEHIND" no-repo-wide-format 'npx prettier --write src/one.ts')
if [ "${r%%|*}" = 0 ]; then ok "one named file still allowed past the stub"
else no "one named file past the stub gave '${r%%|*}' — ${r#*|}"; fi
r=$(hook "$BEHIND" no-broad-kill "pkill -f node")
# The judge's own words, not just exit 2: the refusal exits 2 as well.
if [ "${r%%|*}" = 2 ] && printf '%s' "$r" | grep -q 'matches processes of every agent'; then ok "broad kill still blocked past the stub"
else no "broad kill past the stub gave '${r%%|*}' — ${r#*|}"; fi

[ "$fail" -eq 0 ] && echo "lib/python: all cases pass"
exit $fail
