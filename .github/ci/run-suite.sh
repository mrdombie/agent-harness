#!/usr/bin/env bash
# run-suite.sh — run one suite and pass it only if it reached its own end.
# Usage: run-suite.sh <suite>
# A suite's exit status alone cannot prove that: a cleanup that calls `exit` turns
# a crash into 0. So a pass needs exit 0 AND the suite's own last summary line
# (tests/lib/suite.sh: suite_end / suite_skip) saying PASS or SKIP.
t="${1:?usage: run-suite.sh <suite>}"
name=$(basename "$t")
log=$(mktemp)
# A file, not a pipe: a background child a suite leaves behind would hold a pipe open.
bash "$t" > "$log" 2>&1
rc=$?
cat "$log"
last=$(grep -E "^SUITE-END $name: " "$log" | tail -1)
rm -f "$log"
if [ -z "$last" ]; then
  echo "FAILED: $t stopped before its summary line (exit $rc) — it never reached suite_end"
  exit 1
fi
case "$last" in
  "SUITE-END $name: PASS" | "SUITE-END $name: SKIP"*)
    [ "$rc" -eq 0 ] && exit 0
    echo "FAILED: $t printed '$last' but exited $rc"; exit 1 ;;
esac
echo "FAILED: $t — $last (exit $rc)"
exit 1
