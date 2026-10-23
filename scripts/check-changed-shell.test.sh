#!/usr/bin/env bash
# check-changed-shell.test.sh — a changed script with a shellcheck error is refused,
# an unbounded network command the change adds is refused, a bounded one passes,
# and nothing the change did not touch is ever flagged.
# Run: bash "$0"
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/tests/lib/suite.sh" || exit 1
for v in $(env | sed -n 's/^\(GIT_[A-Z_]*\)=.*/\1/p'); do unset "$v"; done
unset CHECK_SHELL_BASE CHECK_SHELL_SEVERITY CHECK_SHELL_SHELLCHECK
HERE="$(cd "$(dirname "$0")" && pwd)"
C="$HERE/check-changed-shell.sh"
T=$(mktemp -d); on_exit_keep_status 'rm -rf "$T"'
FAILED=0
ok()  { echo "OK       $1"; }
bad() { echo "MISMATCH $1"; FAILED=1; }
g() { git -C "$T/r" -c user.name=t -c user.email=t@t -c commit.gpgsign=false "$@"; }

# CI must prove the shellcheck half; a laptop without it proves the rest.
HAVE_SC=1
if ! command -v shellcheck >/dev/null 2>&1; then
  [ -z "${CI:-}" ] || { echo "MISMATCH shellcheck is not installed on CI, so the shellcheck half is unproven"; suite_end 1; exit 1; }
  HAVE_SC=0; echo "SKIP     shellcheck is not installed here — its cases are skipped"
fi

mkdir -p "$T/r"; git -C "$T/r" init -q -b main
# Already on the trunk: a shellcheck error and an unbounded curl that nobody touches.
cat > "$T/r/old.sh" <<'X'
#!/usr/bin/env bash
curl -s "$1"
[ -f *.txt ] && echo yes
X
cat > "$T/r/edited.sh" <<'X'
#!/usr/bin/env bash
curl -s "$1"
echo one
X
cp "$T/r/edited.sh" "$T/r/untouched-net.sh"
g add -A; g commit -qm base
BASE=$(g rev-parse HEAD)
run() { ( cd "$T/r" && bash "$C" --base "$BASE" "$@" ) > "$T/out" 2> "$T/err"; echo $?; }

# Nothing changed: nothing flagged, the old file's faults included.
rc=$(run)
[ "$rc" = 0 ] && ! grep -q 'old.sh' "$T/out" && ok "a branch that changes no script passes and flags no old file" || bad "no-change rc=$rc: $(cat "$T/out" "$T/err")"

# A changed line in a file whose OLD line is unbounded: the old line is not this change's.
printf 'echo two\n' >> "$T/r/edited.sh"; g commit -qam edit
rc=$(run)
[ "$rc" = 0 ] && ! grep -q 'edited.sh:2' "$T/out" && ok "an edit next to an old unbounded curl does not flag the old line" || bad "edited rc=$rc: $(cat "$T/out")"

# An unbounded curl the change adds is refused by file:line and rule.
cat > "$T/r/net.sh" <<'X'
#!/usr/bin/env bash
u=$1
body=$(curl -fsS "$u")
echo "$body"
X
g add -A; g commit -qm net
rc=$(run)
[ "$rc" = 1 ] && grep -q '^net.sh:3: unbounded-network: .curl.' "$T/out" && ok "an unbounded curl is refused as net.sh:3 unbounded-network" || bad "unbounded curl rc=$rc: $(cat "$T/out")"
! grep -q 'untouched-net.sh\|^old.sh' "$T/out" && ok "unchanged files are never flagged" || bad "flagged an unchanged file: $(cat "$T/out")"

# Every command the rule names, in command position, inside "$( )" and after a shebang
# with no .sh — and each one refused.
mkdir -p "$T/r/bin"
cat > "$T/r/bin/tool" <<'X'
#!/bin/bash
wget -q "$1"
out="$(gh api "repos/$2")"
git -C "$3" fetch -q origin
npm ci
if ! npx --yes prettier --check .; then echo no; fi
docker build .
X
g add -A; g commit -qm tool
rc=$(run)
n=$(grep -c '^bin/tool:[0-9]*: unbounded-network' "$T/out")
[ "$rc" = 1 ] && [ "$n" = 6 ] && ok "wget, gh api, git fetch, npm, npx and docker are each refused in a shebang file with no .sh" || bad "tool rc=$rc n=$n: $(cat "$T/out")"
g rm -q bin/tool net.sh; g commit -qm drop

# Bounded calls, data and comments pass.
cat > "$T/r/bounded.sh" <<'X'
#!/usr/bin/env bash
timeout 30 curl -fsS "$1"
curl --max-time 10 -fsS "$1"
curl -m 5 "$1"
driver_bounded 60 git fetch -q origin
git -c http.lowSpeedLimit=1000 -c http.lowSpeedTime=10 fetch -q origin
echo "run npm ci to install"
# curl "$1" in a comment
gh api user  # unbounded-ok: the caller times the whole step out
awk '
  /^(npm exec|npx next)/ { print }
' "$2"
cat <<EOF
curl $1
EOF
X
g add -A; g commit -qm bounded
rc=$(run)
[ "$rc" = 0 ] && ! grep -q unbounded "$T/out" && ok "timeout, --max-time, -m, a bounded wrapper, lowSpeedTime, strings, comments, an awk program and a heredoc pass" || bad "bounded rc=$rc: $(cat "$T/out")"

# A test suite fetches from fixtures: held to shellcheck, not to the network rule.
printf '#!/usr/bin/env bash\ngit -C "$1" fetch -q origin\n' > "$T/r/x.test.sh"
g add -A; g commit -qm suite
rc=$(run)
[ "$rc" = 0 ] && ok "a test suite's fixture fetch is not refused" || bad "suite rc=$rc: $(cat "$T/out")"

if [ "$HAVE_SC" = 1 ]; then
  cat > "$T/r/sc.sh" <<'X'
#!/usr/bin/env bash
if [ -f *.log ]; then echo found; fi
X
  g add -A; g commit -qm sc
  rc=$(run)
  [ "$rc" = 1 ] && grep -q '^sc.sh:2: SC2144 (error): ' "$T/out" && ok "a shellcheck error in a changed script is refused as sc.sh:2 SC2144" || bad "sc rc=$rc: $(cat "$T/out" "$T/err")"
  ! grep -q '^old.sh' "$T/out" && ok "the unchanged file's own shellcheck error is not reported" || bad "old.sh reported: $(cat "$T/out")"
  printf 'disable=SC2144\n' > "$T/r/.shellcheckrc"
  rc=$(run)
  [ "$rc" = 0 ] && ok "the project's .shellcheckrc is honoured" || bad "shellcheckrc rc=$rc: $(cat "$T/out")"
  rm -f "$T/r/.shellcheckrc"
  # A warning is not an error at the default severity.
  printf '#!/usr/bin/env bash\necho $1\n' > "$T/r/warn.sh"
  rc=$(run)
  ! grep -q '^warn.sh' "$T/out" && ok "a style or warning finding does not refuse at the default severity" || bad "warn flagged: $(cat "$T/out")"
  rm -f "$T/r/warn.sh"
fi

# No shellcheck installed: one line said, never a failure — the network half still runs.
rc=$( ( cd "$T/r" && CHECK_SHELL_SHELLCHECK=/nonexistent/shellcheck bash "$C" --base "$BASE" ) > "$T/out" 2> "$T/err"; echo $?)
[ "$rc" = 0 ] && grep -q 'shellcheck is not installed' "$T/err" && ok "no shellcheck is a log line and a skip, not a failure" || bad "no-shellcheck rc=$rc: $(cat "$T/out" "$T/err")"
printf '#!/usr/bin/env bash\ncurl "$1"\n' > "$T/r/late.sh"
rc=$( ( cd "$T/r" && CHECK_SHELL_SHELLCHECK=/nonexistent/shellcheck bash "$C" --base "$BASE" ) > "$T/out" 2> "$T/err"; echo $?)
[ "$rc" = 1 ] && grep -q '^late.sh:2: unbounded-network' "$T/out" && ok "an uncommitted new script is checked, and the network half runs without shellcheck" || bad "untracked rc=$rc: $(cat "$T/out")"
rm -f "$T/r/late.sh"

# No base to diff against is a refusal, never a quiet pass.
rc=$( ( cd "$T/r" && bash "$C" ) > "$T/out" 2> "$T/err"; echo $?)
[ "$rc" = 2 ] && grep -q 'no base' "$T/err" && ok "no base found refuses (exit 2) rather than checking nothing" || bad "no-base rc=$rc: $(cat "$T/err")"

suite_end "$FAILED"
