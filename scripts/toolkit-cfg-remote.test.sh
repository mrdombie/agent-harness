#!/usr/bin/env bash
# toolkit_cfg reads harness.json from origin's integration branch, not the working tree.
#
# WHY: a coordinator whose main repo was a stale checkout logged "merge lane:
# off — harness.json has no merge.method" for six hours after the key merged
# (2026-10-15). The working tree is any age; the remote branch is the shared truth.
#
# Sources the shipped toolkit-env.sh in a scratch project, then plants two deaths
# in a copy: the remote read removed, and the fetch removed. Both must fail.
set -uo pipefail
ENV_SH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/toolkit-env.sh"
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "  ok   — $1"; }
fail() { FAIL=$((FAIL+1)); echo "  FAIL — $1"; }

# Under a git hook GIT_* would aim every command here at the real repo; HARNESS_*
# would pin the config this test exists to resolve.
for v in $(env | sed -n 's/^\(GIT_[A-Za-z_]*\)=.*/\1/p; s/^\(HARNESS_[A-Za-z_]*\)=.*/\1/p'); do unset "$v"; done
TDIR=$(mktemp -d); trap 'rm -rf "$TDIR"' EXIT
export HOME="$TDIR/home" TMPDIR="$TDIR/tmp"; mkdir -p "$HOME" "$TMPDIR"
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null

cfg() { # <extra jq> — a complete harness.json
  jq -n "{repo:\"o/p\", integrationBranch:\"develop\", branchPrefix:\"t/\", stateDir:\"$TDIR/state\",
    labels:{drafting:\"s:d\",ready:\"s:r\",claimed:\"s:c\",inReview:\"s:i\",gated:\"s:g\",partial:\"s:p\",
      needsHuman:\"n\",pmDecision:\"pm\",pmTrack:\"pt\",blocked:\"b\",externalBlocked:\"eb\",parked:\"pk\",
      hold:\"h\",decision:[\"d\"]}} $1"
}
put() { cfg "$2" > "$TDIR/next.json" && cp "$TDIR/next.json" "$1/.claude/harness.json"; }
g() { git -c user.name=t -c user.email=t@t -C "$@"; }

git init -q --bare "$TDIR/origin.git"; git -C "$TDIR/origin.git" symbolic-ref HEAD refs/heads/develop
PUB="$TDIR/pub"; git init -q -b develop "$PUB"; mkdir -p "$PUB/.claude"
g "$PUB" remote add origin "$TDIR/origin.git"
put "$PUB" ''; g "$PUB" add .claude; g "$PUB" commit -qm one; g "$PUB" push -q origin develop
WORK="$TDIR/work"; git clone -q "$TDIR/origin.git" "$WORK"
# The key lands on origin AFTER the clone: the working tree lacks it and has not fetched it.
put "$PUB" '| .merge = {method:"squash"}'; g "$PUB" commit -qam two; g "$PUB" push -q origin develop

read_key() { # <toolkit-env.sh> <dir> <key> — "<value>|<source>" from a fresh shell
  (cd "$2" && KIT_ROOT="$(dirname "$(dirname "$1")")" . "$1" >/dev/null 2>&1 \
     && printf '%s|%s' "$(toolkit_cfg "$3" 2>/dev/null)" "${HARNESS_CFG_FROM:-}")
}

echo "--- a stale working tree: the remote's value wins, after a fetch ---"
[ -z "$(jq -r '.merge.method // empty' "$WORK/.claude/harness.json")" ] && ok "precondition: working tree lacks merge.method" \
  || fail "precondition: working tree already has merge.method"
out=$(read_key "$ENV_SH" "$WORK" merge.method)
[ "${out%%|*}" = squash ] && ok "toolkit_cfg merge.method → squash" || fail "toolkit_cfg merge.method gave '${out%%|*}', wanted squash"
case "${out#*|}" in origin/develop@*) ok "the source is named: ${out#*|}" ;; *) fail "source not named as origin/develop: '${out#*|}'" ;; esac

echo "--- no remote: the working tree is still read ---"
LONE="$TDIR/lone"; git init -q "$LONE"; mkdir -p "$LONE/.claude"; put "$LONE" '| .merge = {method:"rebase"}'
out=$(read_key "$ENV_SH" "$LONE" merge.method)
[ "${out%%|*}" = rebase ] && ok "no origin → working tree value" || fail "no origin gave '${out%%|*}', wanted rebase"
[ "${out#*|}" = "working tree" ] && ok "the source is named: working tree" || fail "source not named as working tree: '${out#*|}'"

echo "--- a pinned path still wins ---"
cfg '| .merge = {method:"pinned"}' > "$TDIR/pin.json"
out=$(HARNESS_CFG_PATH="$TDIR/pin.json" read_key "$ENV_SH" "$WORK" merge.method)
[ "${out%%|*}" = pinned ] && ok "HARNESS_CFG_PATH → pinned" || fail "HARNESS_CFG_PATH gave '${out%%|*}'"

plant() { # <name> <sed program> <must-not-match> — a copy of toolkit-env.sh with one death
  mkdir -p "$TDIR/$1/scripts"; sed "$2" "$ENV_SH" > "$TDIR/$1/scripts/toolkit-env.sh"
  if grep -qE "$3" "$TDIR/$1/scripts/toolkit-env.sh"; then fail "plant $1 did not land"; return 1; fi
  printf '%s' "$TDIR/$1/scripts/toolkit-env.sh"
}

echo "--- plant: the remote read removed, so the working tree is read again ---"
rm -rf "$TMPDIR"/harness.json.*; WORK2="$TDIR/work2"; git clone -q "$TDIR/origin.git" "$WORK2"; g "$WORK2" reset -q --hard HEAD~1
P=$(plant no-remote 's/^elif ! _toolkit_cfg_remote; then$/elif true; then/' '^elif ! _toolkit_cfg_remote; then$') && {
  out=$(read_key "$P" "$WORK2" merge.method)
  [ "${out#*|}" = "working tree" ] && ok "planted copy still sources, from the working tree" || fail "planted copy did not source: '$out'"
  [ "${out%%|*}" = squash ] && fail "remote read removed, yet the test still passes" || ok "remote read removed: merge.method is missing, as it must be"
}

echo "--- plant: the fetch removed, so a stale origin/develop is read ---"
rm -rf "$TMPDIR"/harness.json.*; WORK3="$TDIR/work3"; git clone -q "$TDIR/origin.git" "$WORK3"
g "$WORK3" update-ref refs/remotes/origin/develop HEAD~1; g "$WORK3" reset -q --hard HEAD~1
P=$(plant no-fetch '/ fetch -q origin /d' ' fetch -q origin ') && {
  out=$(read_key "$P" "$WORK3" merge.method)
  case "${out#*|}" in origin/develop@*) ok "planted copy still sources, from origin/develop" ;; *) fail "planted copy did not source: '$out'" ;; esac
  [ "${out%%|*}" = squash ] && fail "fetch removed, yet the test still passes" || ok "fetch removed: the stale ref is read, as it must be"
}
out=$(read_key "$ENV_SH" "$WORK3" merge.method)
[ "${out%%|*}" = squash ] && ok "the shipped file fetches past the stale ref" || fail "the shipped file read the stale ref: '${out%%|*}'"

echo; echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
