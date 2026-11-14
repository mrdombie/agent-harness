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

# push_refused <title> <message> <from> <bare> <push args…> — refused, named, and the bare repo untouched.
push_refused() {
  local title=$1 msg=$2 from=$3 bare=$4 rc=0 out before; shift 4
  before=$("$REAL_GIT" --git-dir="$bare" for-each-ref 2>/dev/null)
  out=$(PATH="$SHIM:$PATH" git -C "$from" push -q "$@" 2>&1) || rc=$?
  want "$title: the push exits 1 (${out:-no output})" "1" "$rc"
  want_in "$title: the refusal says '$msg'" "$msg" "$out"
  want "$title: the bare repo's refs are unchanged" "$before" \
    "$("$REAL_GIT" --git-dir="$bare" for-each-ref 2>/dev/null)"
}

if suite_case "a push to a remote with a host is refused"; then
  "$REAL_GIT" -C "$CLONE" remote set-url origin https://github.com/x/y.git
  push_refused "https origin" "remote has a host" "$CLONE" "$BARE" origin HEAD:refs/heads/main
  "$REAL_GIT" -C "$CLONE" remote set-url origin "$BARE"
  push_refused "scp form" "remote has a host" "$CLONE" "$BARE" git@github.com:x/y.git HEAD:refs/heads/main
  push_refused "ssh url" "remote has a host" "$CLONE" "$BARE" ssh://host/x HEAD:refs/heads/main
fi
if suite_case "a push to a repo outside the temp dir is refused"; then
  ROOT="$SCR/tmp-root"; mkdir -p "$ROOT"
  "$REAL_GIT" init -q --bare "$SCR/outside"
  "$REAL_GIT" clone -q "$BARE" "$ROOT/clone" 2>/dev/null
  "$REAL_GIT" -C "$ROOT/clone" -c user.email=t@example.invalid -c user.name=Tester commit -q --allow-empty -m one
  HARNESS_STEP_TMP_ROOTS="$ROOT" push_refused "outside temp" "remote is not inside the temp dir" \
    "$ROOT/clone" "$SCR/outside" "$SCR/outside" HEAD:refs/heads/main
fi
if suite_case "a push to a temp repo made before the step is refused"; then
  OLD="$SCR/old.git"; "$REAL_GIT" init -q --bare "$OLD"; touch -t 202001010000 "$OLD"
  push_refused "stale bare" "remote was not made during this step" "$CLONE" "$OLD" "$OLD" HEAD:refs/heads/main
fi
if suite_case "a push from the build worktree is refused"; then
  "$REAL_GIT" -C "$REPO" commit -q --allow-empty -m wt
  FRESH=$(mktemp -d "$SCR/fresh-XXXXXX"); "$REAL_GIT" init -q --bare "$FRESH"
  push_refused "from worktree" "pushing from the build worktree" "$REPO" "$FRESH" "$FRESH" HEAD:refs/heads/main
fi
if suite_case "a push with no remote is refused"; then
  push_refused "bare push" "no remote named" "$CLONE" "$BARE"
fi

suite_end "$FAILED"
