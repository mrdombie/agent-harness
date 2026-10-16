#!/usr/bin/env bash
# check-signal-source.test.sh — the kit reads limit and error signals only in its
# marked readers. A sibling that greps a log for the phrase is caught by name; a
# marker cannot be planted to hide one; a reader cannot lose its markers. Then the
# plant: the phrase rule deleted from the check lets the sibling through.
set -uo pipefail
for v in $(env | sed -n 's/^\(GIT_[A-Za-z_]*\)=.*/\1/p'); do unset "$v"; done
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KIT="$(cd "$HERE/.." && pwd)"
C="$HERE/check-signal-source.sh"
SB=$(mktemp -d "${TMPDIR:-/tmp}/signal-source-XXXXXX"); trap 'rm -rf "$SB"' EXIT
fail=0
ok()  { echo "  ok   — $1"; }
bad() { echo "  FAIL — $1"; fail=1; }
copy() { rm -rf "$SB/kit"; mkdir -p "$SB/kit"; (cd "$KIT" && tar --exclude=.git --exclude=node_modules -cf - .) | tar -xf - -C "$SB/kit"; }

out=$(bash "$C" "$KIT" 2>&1) && ok "the kit as it stands is clean" || bad "the kit is flagged: $out"

# The sibling the first fix missed: limit_hit, grepping a whole builder log.
copy
python3 - "$SB/kit/scripts/coordinator-tick.sh" <<'PY' || bad "plant did not land"
import sys
p = sys.argv[1]; s = open(p).read()
a = 'limit_hit() { swarm_usage_log_limited "$1"; }'
if s.count(a) != 1: sys.exit(1)
open(p, "w").write(s.replace(a, '''limit_hit() { # <log>
  grep -qE 'hit your (session|weekly) limit' "$1" 2>/dev/null
}'''))
PY
out=$(bash "$C" "$SB/kit" 2>&1) && bad "a whole-log grep for the limit passed" \
  || { case "$out" in *"scripts/coordinator-tick.sh:"*"hit your"*) ok "a whole-log grep for the limit is caught by file and line" ;; *) bad "caught, but not named: $out" ;; esac; }
sibling="$SB/sibling-tick.sh"; cp "$SB/kit/scripts/coordinator-tick.sh" "$sibling"

copy
printf '%s\n' '# ---- cli-signal reader: begin' 'grep -q "API Error" "$log"' '# ---- cli-signal reader: end' >> "$SB/kit/swarm/report.sh"
out=$(bash "$C" "$SB/kit" 2>&1) && bad "a marker in an unlisted file hid a phrase" \
  || { case "$out" in *"swarm/report.sh:"*"outside the listed readers"*) ok "a marker outside the listed readers is refused" ;; *) bad "refused, but not named: $out" ;; esac; }

copy
python3 - "$SB/kit/swarm/swarm-env.sh" <<'PY' || bad "plant did not land"
import sys
p = sys.argv[1]; s = open(p).read()
n = "\n".join(l for l in s.split("\n") if "cli-signal reader:" not in l)
if n == s: sys.exit(1)
open(p, "w").write(n)
PY
out=$(bash "$C" "$SB/kit" 2>&1) && bad "a reader with its markers gone passed" \
  || { case "$out" in *"swarm/swarm-env.sh: a listed reader with no cli-signal reader markers"*) ok "a reader whose markers are gone is named" ;; *) bad "failed, but not named: $out" ;; esac; }

echo "plants"
copy; cp "$sibling" "$SB/kit/scripts/coordinator-tick.sh"
cp "$C" "$SB/check.sh"
python3 - "$SB/check.sh" <<'PY' || bad "plant did not land"
import sys
p = sys.argv[1]; s = open(p).read()
a = "    !inr && $0 ~ phr           { print f \":\" NR \": \" substr($0, 1, 140) }\n"
if s.count(a) != 1: sys.exit(1)
open(p, "w").write(s.replace(a, ""))
PY
grep -q '!inr && \$0 ~ phr' "$SB/check.sh" && bad "plant: the rule is still in the copy"
bash "$SB/check.sh" "$SB/kit" >/dev/null 2>&1 && ok "planted: the phrase rule deleted → the sibling passes → red" \
  || bad "planted: the phrase rule deleted and the sibling is still caught → the test cannot see it"
exit $fail
