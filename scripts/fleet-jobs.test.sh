#!/usr/bin/env bash
# fleet-jobs.test.sh — jobs, results and worker records carried as refs on a bare origin.
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/tests/lib/suite.sh" || exit 1

SUT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fleet-jobs.sh"

SB=$(mktemp -d "${TMPDIR:-/tmp}/fleet-jobs-fixture-XXXXXX")
on_exit_keep_status 'rm -rf "$SB"'
fail=0
ok()  { echo "  ok   — $1"; }
bad() { echo "  FAIL — $1"; fail=1; }

for v in $(env | sed -n 's/^\(GIT_[A-Z_]*\)=.*/\1/p'); do unset "$v"; done
export GIT_AUTHOR_NAME=fixture GIT_AUTHOR_EMAIL=fixture@test.local
export GIT_COMMITTER_NAME=fixture GIT_COMMITTER_EMAIL=fixture@test.local

git init -q --bare -b main "$SB/origin.git"
git clone -q "$SB/origin.git" "$SB/a" 2>/dev/null
git clone -q "$SB/origin.git" "$SB/b" 2>/dev/null

fj() { # <clone> <args...>
  local c=$1; shift
  FLEET_REPO="$SB/$c" FLEET_STATE_DIR="$SB/state-$c" bash "$SUT" "$@"
}
remote_sha() { git -C "$SB/a" ls-remote origin "$1" | cut -f1; }

if suite_case "put, list and take a job ref"; then
  out=$(fj a put B 101 '{"ticket":101,"brief":"build it"}' 2>&1); rc=$?
  [ "$rc" -eq 0 ] && ok "put exits 0" || bad "put exited $rc: $out"
  [ -n "$(remote_sha refs/fleet/jobs/B/101)" ] && ok "ref is on origin" || bad "no refs/fleet/jobs/B/101 on origin"
  got=$(fj b list B)
  [ "$got" = "101" ] && ok "list B names 101" || bad "list B gave '$got'"
  [ -z "$(fj b list C)" ] && ok "list C is empty" || bad "list C not empty"
  body=$(fj b take B 101); rc=$?
  [ "$rc" -eq 0 ] && [ "$(jq -r .brief <<<"$body")" = "build it" ] \
    && ok "take prints the job" || bad "take rc=$rc body='$body'"
  [ -z "$(remote_sha refs/fleet/jobs/B/101)" ] && ok "take removes the ref" || bad "ref still on origin after take"
  fj b take B 101 >/dev/null 2>&1; rc=$?
  [ "$rc" -eq 10 ] && ok "a second take exits 10" || bad "second take exited $rc"
fi

if suite_case "a second put of the same ticket exits 10"; then
  fj a put B 202 '{"ticket":202,"brief":"first"}' >/dev/null 2>&1
  fj b put B 202 '{"ticket":202,"brief":"second"}' >/dev/null 2>&1; rc=$?
  [ "$rc" -eq 10 ] && ok "second put exits 10" || bad "second put exited $rc"
  body=$(fj b take B 202)
  [ "$(jq -r .brief <<<"$body")" = "first" ] && ok "the first job survives" || bad "job was overwritten: '$body'"
fi

if suite_case "done put, all and ack round trip"; then
  fj b done-put B 303 run-9 0 'PR opened' >/dev/null 2>&1; rc=$?
  [ "$rc" -eq 0 ] && ok "done-put exits 0" || bad "done-put exited $rc"
  [ -n "$(remote_sha refs/fleet/done/B/303-run-9)" ] && ok "done ref on origin" || bad "no done ref"
  rows=$(fj a done-all)
  [ "$(jq -s length <<<"$rows")" = 1 ] && ok "one result listed" || bad "done-all gave '$rows'"
  row=$(jq -c 'select(.ticket=="303")' <<<"$rows")
  [ "$(jq -r .exit <<<"$row")" = 0 ] && [ "$(jq -r .final <<<"$row")" = "PR opened" ] \
    && [ "$(jq -r .host <<<"$row")" = B ] && [ "$(jq -r .run <<<"$row")" = run-9 ] \
    && ok "result carries host, run, exit and final line" || bad "row '$row'"
  fj a done-ack "$(jq -r .ref <<<"$row")" >/dev/null 2>&1; rc=$?
  [ "$rc" -eq 0 ] && [ -z "$(remote_sha refs/fleet/done/B/303-run-9)" ] \
    && ok "ack removes the done ref" || bad "ack rc=$rc"
  [ -z "$(fj a done-all)" ] && ok "nothing left after ack" || bad "done-all not empty after ack"
fi

if suite_case "an unchanged worker record is not pushed again"; then
  FLEET_NOW=1000 fj b worker-put B '{"builders":1,"running":[]}' >/dev/null 2>&1
  s1=$(remote_sha refs/fleet/workers/B)
  [ -n "$s1" ] && ok "first record pushed" || bad "no worker ref"
  FLEET_NOW=1060 fj b worker-put B '{"builders":1,"running":[]}' >/dev/null 2>&1
  s2=$(remote_sha refs/fleet/workers/B)
  [ "$s1" = "$s2" ] && ok "unchanged record not pushed" || bad "unchanged record was pushed again"
  FLEET_NOW=1120 fj b worker-put B '{"builders":1,"running":[7]}' >/dev/null 2>&1
  s3=$(remote_sha refs/fleet/workers/B)
  [ -n "$s3" ] && [ "$s3" != "$s2" ] && ok "a changed record is pushed" || bad "changed record not pushed"
fi

if suite_case "a record past workerStaleMin reads stale"; then
  FLEET_NOW=5000 fj b worker-put C '{"builders":2}' >/dev/null 2>&1
  r=$(FLEET_NOW=5060 FLEET_WORKER_STALE_MIN=10 fj a worker-read C)
  [ "$(jq -r .stale <<<"$r")" = false ] && [ "$(jq -r .record.builders <<<"$r")" = 2 ] \
    && ok "fresh record reads fresh" || bad "fresh read '$r'"
  r=$(FLEET_NOW=$((5000 + 11 * 60)) FLEET_WORKER_STALE_MIN=10 fj a worker-read C)
  [ "$(jq -r .stale <<<"$r")" = true ] && ok "record past 10 min reads stale" || bad "stale read '$r'"
fi

suite_end "$fail"
