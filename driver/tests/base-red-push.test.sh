#!/usr/bin/env bash
# base-red-push.test.sh — a pre-push check red on the trunk commit a branch merged is the
# trunk's: the branch pushes past it (base-red), the run log and the PR say so, and ONE
# "develop is red" ticket is filed however many builders hit it. A second builder on the
# same red reuses the host's cached run of the check. A check red only on the branch still
# blocks. And a branch whose own pre-push predates HARNESS_LOCAL_GATES_HEAD runs the
# trunk's hook on a head gates.local passed on, so it is not refused at all.
# Run: bash "$0"
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/tests/lib/suite.sh" || exit 1
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/fixture.sh"
driver_fixture; on_exit_keep_status 'rm -rf "$FIX"'
. "$HERE/../steps/ship.sh" || exit 1
ROOT="$(cd "$HERE/../.." && pwd)"
export CHECK_LOG="$FIX/check.log"; : > "$CHECK_LOG"

# A check is red in any tree that carries red-<check>; every run is logged with who ran it.
cat > "$REPO/check.sh" <<'SH'
#!/bin/sh
printf '%s %s\n' "${2:-base}" "$1" >> "$CHECK_LOG"
[ -f "red-$1" ] && { echo "✗ $1 is red"; exit 1; }
exit 0
SH
git -C "$REPO" add check.sh; git -C "$REPO" commit -qm "chore: the checks"
git init -q --bare "$FIX/origin"; git -C "$REPO" remote add origin "$FIX/origin"; git -C "$REPO" push -q origin develop
jq '.gates = {lint: "echo lint-ok", checkCommand: "sh check.sh {check}"}' "$HARNESS_CFG_PATH" > "$FIX/cfg.json"

# The project's pre-push: skips a head the driver names, else runs both checks, suite summary last.
HOOKS="$(git -C "$REPO" rev-parse --path-format=absolute --git-common-dir)/hooks"; mkdir -p "$HOOKS"
cat > "$HOOKS/pre-push" <<'SH'
#!/usr/bin/env bash
while read -r l s r rs; do
  [ "$r" = refs/heads/develop ] && exit 0  # the suite's own trunk set-up, not a case
  [ "$s" = "${HARNESS_LOCAL_GATES_HEAD:-}" ] && { echo "gates.local already passed on this head"; exit 0; }
done
cd "$(git rev-parse --show-toplevel)" || exit 1
f=""; for c in chk-a chk-b; do sh check.sh "$c" hook || f="$f${f:+, }$c"; done
[ -z "$f" ] && exit 0
echo "✗ verify:push — $(printf '%s' "$f" | tr ',' '\n' | grep -c .) of 2 failed: $f"; exit 1
SH
chmod +x "$HOOKS/pre-push"; printf "exit 0\n" > "$FIX/hooks-ok.sh"; export DRIVER_ENSURE_HOOKS="$FIX/hooks-ok.sh"

trunk_set() { # <file>… — the trunk carries exactly these red-* markers
  git -C "$REPO" checkout -q develop; git -C "$REPO" rm -q --ignore-unmatch 'red-*' >/dev/null
  for m in "$@"; do : > "$REPO/$m"; git -C "$REPO" add "$m"; done
  git -C "$REPO" commit -qm "trunk: $*" --allow-empty; git -C "$REPO" push -q origin develop
}
ship_ready() { # <ticket> [marker] — a reviewed branch off the trunk, every step before ship done
  git -C "$REPO" worktree add -q "$FIX/t$1" -b "tkt-$1/work" develop
  printf 'a\n' > "$FIX/t$1/a$1.sh"; [ -z "${2:-}" ] || : > "$FIX/t$1/$2"
  git -C "$FIX/t$1" add -A; git -C "$FIX/t$1" commit -qm "feat: a"
  driver_state_init "$1" --worktree "$FIX/t$1" --branch "tkt-$1/work"
  fix_issue "$1" OPEN "status:claimed"
  driver_state_put "$1" review '{"verdict":"SHIP","findings":[]}'; driver_state_bump "$1" review
  driver_state_set "$1" claimed_at_sha "$(git -C "$REPO" rev-parse develop)"
  for st in start plan build self-check review record; do driver_state_done "$1" "$st"; done
}
ship() { # <ticket> — the ship step from ${SUT_KIT:-the kit}; R_RC its exit
  R_RC=0
  HARNESS_CFG="$FIX/cfg.json" HARNESS_CFG_PATH="$FIX/cfg.json" bash -c 'unset DRIVER_DIR DRIVER_HOME KIT_ROOT HARNESS_KIT_ROOT; . "$1/driver/driver-env.sh" && . "$1/driver/steps/ship.sh" && driver_step_ship "$2"' _ "${SUT_KIT:-$ROOT}" "$1" > "$FIX/ship-$1.out" 2>&1 || R_RC=$?
}
pushed() { git --git-dir="$FIX/origin" rev-parse -q --verify "refs/heads/tkt-$1/work" >/dev/null 2>&1 && echo pushed || echo "not pushed"; }
base_runs() { grep -c "^base $1\$" "$CHECK_LOG"; }
PENDING="$STATE/swarm/develop-red.tsv"

# The forge for develop-red.sh: the search, the create, the status labels.
cat > "$FIX/fgh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FIX/fgh.log"
case "$*" in
  *"-X GET search/issues"*) if [ -f "$FIX/fgh.found" ]; then printf '{"total_count":1,"items":[{"number":%s,"body":"%s"}]}\n' "$(cat "$FIX/fgh.found")" "$(cat "$FIX/fgh.found.body")"; else echo '{"total_count":0,"items":[]}'; fi; exit 0 ;;
  *"repos/acme/widgets/issues -X POST"*) n=$(( $(cat "$FIX/fgh.next" 2>/dev/null || echo 900) + 1 )); echo "$n" > "$FIX/fgh.next"; printf '%s\0' "$@" > "$FIX/fgh.create.$n"; echo "$n"; exit 0 ;;
esac
exit 0
SH
chmod +x "$FIX/fgh"
file_red() { # [kit] — develop-red.sh file from that kit; R_FILE its output
  R_FILE=$(DEVELOP_RED_GH="$FIX/fgh" SWARM_GH="$FIX/fgh" DEVELOP_RED_QUEUE=off HARNESS_CFG="$FIX/cfg.json" HARNESS_CFG_PATH="$FIX/cfg.json" \
    bash "${1:-$ROOT}/scripts/develop-red.sh" file 2>&1)
}
creates() { ls "$FIX"/fgh.create.* 2>/dev/null | wc -l | tr -d ' '; }

echo "--- the checks a refused pre-push named ---"
printf 'x\n✗ chk-a is red\n✗ verify:push — 2 of 9 failed: chk-a, check:b-c\nerror: failed to push some refs\n' > "$FIX/o1"
want "the suite's summary names them" "chk-a check:b-c" "$(. "$ROOT/driver/base-red.sh"; driver_base_red_checks "$FIX/o1" | tr '\n' ' ' | sed 's/ $//')"
printf '✗ chk-a  (required check: Code gates)\n✗ 1 entry ROSE\nerror: failed to push some refs\n' > "$FIX/o2"
want "without one, each ✗ line that names a check" "chk-a" "$(. "$ROOT/driver/base-red.sh"; driver_base_red_checks "$FIX/o2" | tr '\n' ' ' | sed 's/ $//')"

echo "--- a branch whose only red is red on the trunk commit it merged pushes, base-red ---"
trunk_set red-chk-a; SHA=$(git -C "$REPO" rev-parse develop); S7=$(printf '%s' "$SHA" | cut -c1-7)
ship_ready 601; : > "$GH_LOG"; ship 601
want "the ship finishes"                 "0" "$R_RC"
want "the branch is on origin"           "pushed" "$(pushed 601)"
want_in "the run log says base-red"      "base-red: chk-a on develop@$S7" "$(cat "$(driver_state_dir 601)/log")"
want_in "the pull request says so"       "pr comment 42 .*base-red: chk-a on develop@$SHA" "$(cat "$GH_LOG")"
want "the check ran once on the trunk commit" "1" "$(base_runs chk-a)"
want "never parked"                      "" "$(driver_state_get 601 park_note)"
want "one row for the coordinator"       "$SHA	chk-a	601" "$(cut -f1-3 "$PENDING")"

echo "--- a second builder on the same red reuses the cached run ---"
ship_ready 602; ship 602
want "it pushes too"                     "pushed" "$(pushed 602)"
want "the check did not run again"       "1" "$(base_runs chk-a)"

echo "--- the coordinator files ONE develop-red ticket for both ---"
file_red
want "one ticket"                        "1" "$(creates)"
want_in "titled for the trunk, the checks and the commit" "title=develop is red: chk-a \(develop@$S7\)" "$(tr '\0' '\n' < "$FIX/fgh.create.901")"
want_in "at P0"                          'labels\[\]=P0' "$(tr '\0' '\n' < "$FIX/fgh.create.901")"
want_in "with the process label"         'labels\[\]=process' "$(tr '\0' '\n' < "$FIX/fgh.create.901")"
want_in "naming both builders"           '#601, #602' "$(tr '\0' '\n' < "$FIX/fgh.create.901")"
file_red
want "a second pass files nothing"       "1" "$(creates)"
mv "$STATE/swarm/develop-red-filed.tsv" "$FIX/ledger.keep"
printf '901' > "$FIX/fgh.found"; printf '<!-- develop-red: checks=chk-a sha=%s -->' "$S7" > "$FIX/fgh.found.body"
file_red
want "another host's ledger: the forge's marker stops a second" "1" "$(creates)"
rm -f "$FIX/fgh.found"; cp "$FIX/ledger.keep" "$STATE/swarm/develop-red-filed.tsv"
# The red set changed (one check fixed, one still red): the open ticket covers it, as a comment.
# #14229 was filed and built in full beside the open #14215 on 2026-10-24.
printf '%s\tchk-a,chk-z\t604\t\n' "$SHA" > "$PENDING"; : > "$FIX/fgh.log"
printf '901' > "$FIX/fgh.found"; printf '<!-- develop-red: checks=chk-a sha=%s -->' "$S7" > "$FIX/fgh.found.body"
file_red
want "a changed red set files no second ticket" "1" "$(creates)"
want_in "  it comments on the open one"        'repos/acme/widgets/issues/901/comments -X POST .*now on: chk-a, chk-z' "$(cat "$FIX/fgh.log")"
want_in "  and says so"                        'is the open #901.s: added there as a comment' "$R_FILE"
file_red
want_not_in "  once: a second pass does not comment again" 'comments -X POST.*comments -X POST' "$(tr '\n' ' ' < "$FIX/fgh.log")"
rm -f "$FIX/fgh.found"; cp "$FIX/ledger.keep" "$STATE/swarm/develop-red-filed.tsv"

echo "--- a check red only on the branch still blocks ---"
trunk_set; : > "$PENDING"
ship_ready 603 red-chk-b; ship 603
want "the ship refuses"                 "refused" "$([ "$R_RC" -ne 0 ] && echo refused || echo shipped)"
want "the branch is not on origin"       "not pushed" "$(pushed 603)"
want_in "and says it is the branch's own" 'not base-red on develop@.* green there, so this branch.s own: chk-b' "$(cat "$FIX/ship-603.out")"
want "nothing for the coordinator"       "" "$(cat "$PENDING")"

echo "--- a branch's own pre-push older than the skip: the trunk's hook runs on a head gates.local passed ---"
R2="$FIX/r2"; git init -q -b develop "$R2"; git -C "$R2" config user.email t@example.invalid; git -C "$R2" config user.name T
mkdir -p "$R2/.husky"; printf 'echo "old full suite ran" >&2\nexit 1\n' > "$R2/.husky/pre-push"
git -C "$R2" add -A; git -C "$R2" commit -qm "old hook"; OLD=$(git -C "$R2" rev-parse HEAD)
cat > "$R2/.husky/pre-push" <<'SH'
while read -r l s r rs; do [ "$s" = "${HARNESS_LOCAL_GATES_HEAD:-}" ] && { echo "gates.local already passed on this head"; exit 0; }; done
echo "new full suite ran" >&2; exit 1
SH
git -C "$R2" add -A; git -C "$R2" commit -qm "the hook skips a passed head"
git init -q --bare "$FIX/o2.git"; git -C "$R2" remote add origin "$FIX/o2.git"; git -C "$R2" push -q origin develop
git -C "$R2" worktree add -q "$FIX/w2" -b tkt-610/work "$OLD"
printf 'b\n' > "$FIX/w2/b.sh"; git -C "$FIX/w2" add b.sh; git -C "$FIX/w2" commit -qm "feat: b"
jq '.gates = {localOnly: true, local: ["echo lint-ok"]}' "$FIX/cfg.json" > "$FIX/lg.json"
old_hook() { # from ${SUT_KIT:-the kit}: R the push's result
  driver_state_init 610 --worktree "$FIX/w2" --branch tkt-610/work
  driver_state_set 610 local_gates_head "$(git -C "$FIX/w2" rev-parse HEAD)"
  git --git-dir="$FIX/o2.git" update-ref -d refs/heads/tkt-610/work 2>/dev/null
  R=$(HARNESS_CFG="$FIX/lg.json" HARNESS_CFG_PATH="$FIX/lg.json" bash -c 'unset DRIVER_DIR DRIVER_HOME KIT_ROOT HARNESS_KIT_ROOT DRIVER_ENSURE_HOOKS; . "$1/driver/driver-env.sh" && . "$1/driver/state.sh" && bash "$1/scripts/ensure-hooks.sh" "$2" "$3" >/dev/null 2>&1 && driver_push 610 "$3" tkt-610/work ship >/dev/null 2>&1 && echo pushed || { echo refused; cat "$DRIVER_DIR/610/steps/ship-push.out" >&2; }' _ "${SUT_KIT:-$ROOT}" "$R2" "$FIX/w2" 2>"$FIX/old-hook.err")
}
old_hook
want "the push is not refused by the branch's stale hook" "pushed" "$R"
want_not_in "its old full suite never ran" 'old full suite ran' "$(cat "$FIX/old-hook.err")"

echo "--- plants: each line out of a copy of the kit, its case fails ---"
KIT="$FIX/kit"
kit_copy() { rm -rf "$KIT"; mkdir -p "$KIT"; cp -R "$ROOT/driver" "$ROOT/scripts" "$ROOT/swarm" "$ROOT/shared" "$KIT/"; }
plant() { # <label> <file under the kit> <exact text to delete>
  kit_copy
  python3 -I -c 'import sys; p, l = sys.argv[1], sys.argv[2]; s = open(p).read(); n = s.count(l); open(p, "w").write(s.replace(l, "", 1)); sys.exit(0 if n == 1 else 1)' "$KIT/$2" "$3" \
    || { want "plant landed: $1" "landed" "missed"; return 1; }
}
N=620
case_base() { N=$((N + 1)); trunk_set red-chk-a; : > "$PENDING"; : > "$CHECK_LOG"; rm -f "$STATE/swarm/base-checks.tsv"
  ship_ready "$N"; SUT_KIT="$KIT" ship "$N"; R="$(pushed "$N") rows=$(grep -c . "$PENDING")"; }
case_reuse() { N=$((N + 1)); ship_ready "$N"; SUT_KIT="$KIT" ship "$N"; R="runs=$(base_runs chk-a)"; }
case_own() { N=$((N + 1)); trunk_set; : > "$PENDING"; ship_ready "$N" red-chk-b; SUT_KIT="$KIT" ship "$N"; R="$(pushed "$N")"; }
case_file() { : > "$PENDING"; rm -f "$STATE/swarm/develop-red-filed.tsv" "$FIX"/fgh.create.* "$FIX/fgh.next"
  printf '%s\tchk-a\t1\t\t1\n%s\tchk-a\t2\t\t2\n' "$SHA" "$SHA" > "$PENDING"
  file_red "$KIT"; file_red "$KIT"; R="creates=$(creates)"; }
kit_copy
case_base;  want "the unplanted kit: a base-red pushes and is noted once" "pushed rows=1" "$R"
case_reuse; want "the unplanted kit: a second builder reuses the run"     "runs=1" "$R"
case_own;   want "the unplanted kit: a branch-only red blocks"            "not pushed" "$R"
case_file;  want "the unplanted kit: one ticket for two builders, twice filed" "creates=1" "$R"
plant "the base-red push" driver/steps/ship.sh ' \
    || _driver_ship_base_red "$t" "$wt" "$branch"' \
  && { case_base; want "planted (the base-red push): the push is refused" "not pushed rows=0" "$R"; }
plant "the shared cache" driver/base-red.sh '    [ "$v" = unknown ] || printf '"'"'%s\t%s\t%s\t%s\t%s\n'"'"' "$sha" "$c" "$v" "$(date +%s)" "$rc" >> "$BASE_CHECKS"
' && { case_base; case_reuse; want "planted (the shared cache): the second builder runs it again" "runs=2" "$R"; }
plant "the branch's own red blocks" driver/steps/ship.sh '  if [ -n "$own$unk" ]; then' \
  && { python3 -I -c 'import sys; p = sys.argv[1]; s = open(p).read(); o = "    return 1\n  fi\n  list=$(printf"; assert s.count(o) == 1; open(p, "w").write(s.replace(o, "  list=$(printf", 1))' "$KIT/driver/steps/ship.sh" \
       && { case_own; want "planted (the branch's own red blocks): it pushes" "pushed" "$R"; }; }
plant "the ledger" scripts/develop-red.sh '  [ -z "$n" ] || continue
' && { case_file; want "planted (the ledger): a second ticket" "creates=2" "$R"; }
plant "the trunk's hook" scripts/ensure-hooks.sh '  s=$HARNESS_PREPUSH_SCRIPT
' && { SUT_KIT="$KIT" old_hook; want "planted (the trunk's hook): the stale hook refuses it" "refused" "$R"; }
plant "the push names the trunk's hook" driver/driver-env.sh '  [ -z "$lg" ] || ! th=$(_driver_trunk_prepush "$wt") || penv+=("HARNESS_PREPUSH_SCRIPT=$th")
' && { SUT_KIT="$KIT" old_hook; want "planted (the push names the trunk's hook): the stale hook refuses it" "refused" "$R"; }

suite_end "$FAILED"
