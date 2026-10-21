#!/usr/bin/env bash
# format-json.test.sh — a JSON file the driver writes into a tree with no Prettier
# installed still passes the project's `prettier --check`. The evidence plan went out
# as Python's indent-2 JSON, Prettier folds a short array onto one line, and every
# screen ticket's first push failed the format check. Checked with a real, pinned
# Prettier: a replica of its rules can only agree with itself.
# Run: bash "$0"
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/tests/lib/suite.sh" || exit 1
HERE="$(cd "$(dirname "$0")" && pwd)"
KIT_ROOT="$(cd "$HERE/../.." && pwd)"; export KIT_ROOT
PRETTIER_PIN="${PRETTIER_PIN:-prettier@3.9.9}"
pass=0; fail=0
ok()  { pass=$((pass+1)); echo "  ok   $1"; }
bad() { fail=$((fail+1)); echo "  FAIL $1"; }
T=$(mktemp -d "${TMPDIR:-/tmp}/format-json-XXXXXX"); on_exit_keep_status 'rm -rf "$T"'

driver_say() { :; }
eval "$(sed -n '/^driver_format_cmd()/,/^}/p; /^driver_format_files()/,/^}/p' "$HERE/../format.sh")"
type driver_format_files >/dev/null 2>&1 || { echo "FAIL driver_format_files not found in format.sh"; exit 1; }

# The Prettier the check runs. Not found is a failure, never a skip: a skipped guard
# reports green on the machine that most needs it.
prettier_check() { ( cd "$1" && npx --yes "$PRETTIER_PIN" --check "$2" ) >"$T/check.out" 2>&1; }
( cd "$T" && npx --yes "$PRETTIER_PIN" --version ) >"$T/version.out" 2>&1 \
  || { echo "FAIL $PRETTIER_PIN could not be run: $(tail -2 "$T/version.out")"; exit 1; }
echo "--- with $(cat "$T/version.out") ---"

# A capture plan the shape the ship step writes, with arrays either side of the width.
plan() { # <width>
  python3 -I - "$1" <<'PY'
import json, sys
w = int(sys.argv[1])
shots = []
for i, (route, vp, theme) in enumerate([("/connect/[token]", "laptop", "light"), ("/login", "phone", "dark"),
                                        ("/settings/voice", "laptop", "dark")]):
    s = {"name": "shot-%d-%s-%s" % (i, vp, theme), "route": route, "viewport": vp, "theme": theme}
    if i == 1:
        s["setup"] = ["wait for the text \"Necessary cookies keep you signed in\""]
    if i == 2:
        s["setup"] = ["click the “Open” button", "press Meta+K"]
    shots.append(s)
# One-element arrays whose one line ends exactly at the width, and one past it, at the
# indent and key a setup line carries ('      "setup": ["' + text + '"],').
for n in (w, w + 1):
    pad = n - len('      "setup": [""],')
    shots.append({"name": "edge-%d" % n, "route": "/x", "viewport": "phone", "theme": "light",
                  "setup": ["a" * pad], "tags": []})
data = {"shots": shots, "meta": {}, "pairs": [["a", "b"], ["c", "d"]], "one": [["a", "b"]]}
print(json.dumps(data, indent=2))
PY
}

for width in 80 100; do
  d="$T/tree$width"; mkdir -p "$d/docs/evidence/1"
  [ "$width" = 80 ] || printf '{ "printWidth": %s, "tabWidth": 2, "useTabs": false }\n' "$width" > "$d/.prettierrc.json"
  plan "$width" > "$d/docs/evidence/1/plan.json"
  cp "$d/docs/evidence/1/plan.json" "$T/indent2-$width.json"
  # The absence: the file as Python writes it fails the same check, so a pass below is
  # the writer's doing and not a check that passes everything.
  if prettier_check "$d" docs/evidence/1/plan.json; then
    bad "width $width: indent-2 JSON already passes, so this check proves nothing"
  else
    ok "width $width: indent-2 JSON fails prettier --check"
  fi
  rc=0; driver_format_files "$d" docs/evidence/1/plan.json || rc=$?
  [ "$rc" = 0 ] && ok "width $width: the file is formatted" || bad "width $width: driver_format_files returned $rc"
  if prettier_check "$d" docs/evidence/1/plan.json; then
    ok "width $width: the written plan passes prettier --check"
  else
    bad "width $width: prettier --check fails: $(tr '\n' ' ' < "$T/check.out" | cut -c1-300)"
  fi
  [ "$(jq -S . "$d/docs/evidence/1/plan.json")" = "$(jq -S . "$T/indent2-$width.json")" ] \
    && ok "width $width: the data is unchanged" || bad "width $width: the data changed"
done

echo "pass=$pass fail=$fail"
suite_end "$fail"
