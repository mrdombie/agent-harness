#!/usr/bin/env bash
# step-push-guard.test.sh — a step's git shim refuses a push to the project, but a
# harness test run as a step's proof pushes between repos it made in the temp dir
# during the step, and that push must land.
# Run: bash "$0"
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/tests/lib/suite.sh" || exit 1
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/fixture.sh"
driver_fixture; on_exit_keep_status 'rm -rf "$FIX"'
. "$HERE/../ai-step.sh" || exit 1

# The real git, past any step shim this suite itself runs under.
REAL_GIT=""
IFS=: read -ra _dirs <<<"$PATH"
for _d in "${_dirs[@]}"; do
  case "$_d" in *.driver-shim*) continue ;; esac
  [ -x "$_d/git" ] && { REAL_GIT="$_d/git"; break; }
done
want "no GIT_* variable reaches the case" "0" "$(env | grep -c '^GIT_')"

SCR=$(mktemp -d); BARE=""; CLONE=""
on_exit_keep_status 'rm -rf "$FIX" "$SCR" ${BARE:+"$BARE"} ${CLONE:+"$CLONE"}'
SHIM="$SCR/shim"; mkdir -p "$SHIM"
driver_step_git_shim "$SHIM" "$REPO" "$REAL_GIT"
want "the shim is written" "1" "$([ -x "$SHIM/git" ] && echo 1 || echo 0)"

# Both made after the shim stamped the step's start.
BARE=$(mktemp -d); CLONE=$(mktemp -d)

"$REAL_GIT" init -q --bare "$BARE"
"$REAL_GIT" clone -q "$BARE" "$CLONE" 2>/dev/null
"$REAL_GIT" -C "$CLONE" -c user.email=t@example.invalid -c user.name=Tester commit -q --allow-empty -m one
head=$("$REAL_GIT" -C "$CLONE" rev-parse HEAD)

push_lands() { # <title> <remote>
  local rc=0 out
  "$REAL_GIT" --git-dir="$BARE" update-ref -d refs/heads/main 2>/dev/null || true
  out=$(PATH="$SHIM:$PATH" git -C "$CLONE" push -q "$2" HEAD:refs/heads/main 2>&1) || rc=$?
  want "$1: the push exits 0 (${out:-no output})" "0" "$rc"
  want "$1: the bare repo's main is the clone's HEAD" "$head" \
    "$("$REAL_GIT" --git-dir="$BARE" rev-parse -q --verify main 2>/dev/null)"
}

if suite_case "a temp-to-temp push lands by path"; then
  push_lands "path" "$BARE"
fi
if suite_case "a temp-to-temp push lands by file url"; then
  push_lands "file://" "file://$BARE"
fi
if suite_case "a temp-to-temp push lands by remote name"; then
  "$REAL_GIT" -C "$CLONE" remote add scratch "$BARE"
  push_lands "remote name" scratch
fi

suite_end "$FAILED"
