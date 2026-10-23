#!/usr/bin/env bash
# steps/build.sh — the build step, and the one guarantee the driver makes with
# its own hands rather than by asking.
#
#   driver_step_build <ticket>
#
# TEST-FIRST, PROVED. The epic's headline measurement is that test-first was used
# 0 times in 161 runs while every instruction insisted on it. An instruction
# nothing checks is a wish. So the driver does not ask whether the test came
# first — it runs the test against the tree WITHOUT the change and requires it to
# FAIL, then against the tree WITH the change and requires it to PASS.
#
# That is why the build brief has to report, per item, the commit that added the
# test and the commit that made it pass: two commits are what make the claim
# checkable. A single squashed commit cannot be told from a test written
# afterwards, which is exactly the thing being prevented.
#
# It is also why this is not "did the agent say it did TDD". A test that is green
# before the change is the commonest failure in this repo's history — a test
# whose selector matches nothing, whose assertion is true of any tree, or which
# reads a file instead of running the code. All three are GREEN at the base
# commit, and all three fail here.
[ -n "${DRIVER_DIR:-}" ] || . "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/driver-env.sh" || exit 1
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/ai-step.sh" || exit 1
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/format.sh" || exit 1
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/git-actions.sh" || exit 1

# driver_prove_red_green <repo> <test-file> <test-commit> <impl-commit> <command>
#
#   0  it failed without the change and passed with it
#   1  it passed WITHOUT the change — the test does not test the change
#   2  it still failed WITH the change — the change does not do the job
#   3  the commits could not be read
#   4  a half ran out of time — a hang says nothing about the change
#   5  a proof tree could not be prepared — the measurement was never made
#   6  red then green, and the tree with the change does not type-check
#   7  the command cannot be run as given (a placeholder, no such program) — never run
#   8  it failed on a missing module from an install behind its lockfile, relinked and
#      taken again, and the install is still behind — the machine's, never the change's
#   9  a half could not reach the app (no server runs in a proof tree) — never run there
#
# BOTH trees are the reported test file copied into a checkout: the change's PARENT
# for the red half, the change itself for the green half. Two things follow from
# that and neither is incidental.
#
# Checking out the test commit itself would not do — on a branch where the test and
# the change are adjacent that tree is the same tree, and the proof would be of
# nothing.
#
# And the version has to be the REPORTED one in both halves. A test sharpened while
# the change was built is ordinary, and then the change's own tree holds an earlier
# version; running that one measures a different test in each half and attributes
# both answers to the change. A first version that asserts the opposite of the
# change is green before and red after, so the two readings disagree — and the
# wrong one says "still fails with the change" about a change that works.
#
# Unless the test came FIRST and the change edited it. A fix that changes behaviour
# rewrites the sibling cases asserting the old one, in the same file, and the test
# commit's version then fails at the change for those siblings alone. When the test
# commit is an ancestor of the change, the version that lands with the change is the
# one run in both halves: red at the change's parent, green at the change.
# The two proof trees need what the TICKET worktree was given, or a test command
# that resolves through the shared install — `npx x`, `./node_modules/.bin/x`,
# `npm test` — fails with 127 in both of them. 127 in the second reads as "the
# change does not do the job", the rework burns every try, and the ticket parks.
# On a project with a gitignored install that is every ticket, so this is not a
# nicety: without it the step's whole guarantee is unreachable there.
# 0 prepared · 1 this project's setup could not be run here.
#
# THE EXIT CODE IS READ. Wrapped in `>/dev/null 2>&1 || true` it re-opened the exact
# bug the prepare list exists to close: a failed generate leaves the test command
# resolving through a missing artifact, so it exits 127 in BOTH halves, the second
# 127 reads as "the change does not do the job", the rework loop burns every try, and
# the ticket parks blaming a change that works. The measurement was never made, and a
# measurement that could not be made is not a red.
_driver_proof_install() { # <repo> <tree>
  # The proof trees link from <repo>: a source install behind its lockfile is relinked
  # first, or every import of a package it lacks fails both halves as the change's fault.
  [ -z "${MAIN_REPO:-}" ] || driver_relink_if_behind "$MAIN_REPO" "$1" || true
  driver_link_install "$1" "$2" || { DRIVER_PREPARE_WHY="the shared install could not be linked into $2"; return 1; }
  [ -d "$1/.husky/_" ] && { mkdir -p "$2/.husky"; cp -R "$1/.husky/_" "$2/.husky/_"; }
  # >&2, because the caller is a command substitution: `why=$(driver_prove_red_green …)`.
  # Left on stdout, driver_prepare_worktree's own narration was captured into $why and
  # printed as part of the proof's verdict — and on the refusal path the park note was
  # the same sentence twice, naming a temp tree that had already been deleted.
  driver_prepare_worktree "$2" >&2 || return 1
  return 0
}

# driver_proof_typecheck_cmd — the compile check a proof runs beside the test, or
# nothing. `driver.proofTypecheck` names it outright ("" or "none" switches it off);
# otherwise it is this project's own typecheck gate, the first `gates.changed` (then
# `gates.local`) entry, or flat-map gate, whose command names typecheck or tsc. A
# project with no such gate compiles nothing, so there is nothing to run.
driver_proof_typecheck_cmd() {
  [ -n "${HARNESS_CFG:-}" ] && [ -f "$HARNESS_CFG" ] || return 0
  jq -r '
    def tc: type == "string" and test("typecheck|(^|[^a-z])tsc([^a-z]|$)");
    if (.driver.proofTypecheck | type) == "string" then
      (.driver.proofTypecheck | if . == "none" then "" else . end)
    else
      ([ ((.gates.changed // []) | if type == "array" then .[] | select(tc) else empty end),
         ((.gates.local   // []) | if type == "array" then .[] | select(tc) else empty end),
         ((.gates // {}) | if type == "object" then to_entries[]
            | select(.key | IN("changed","local","group","requiredChecks","formatChanged") | not)
            | select((.value | type) == "string")
            | select((.key | test("typecheck|tsc")) or (.value | tc)) | .value else empty end)
       ] | first // "")
    end' "$HARNESS_CFG" 2>/dev/null
}

# The compiler's own error lines when it printed any, else the tail.
_driver_typecheck_lines() { # <file>
  local l
  l=$(grep -E 'error TS[0-9]+|: error' "$1" 2>/dev/null | head -3)
  [ -n "$l" ] || l=$(tail -3 "$1" 2>/dev/null)
  printf '%s' "$l" | tr '\n' ' ' | cut -c1-600
}

# The runner's own failure lines when it printed any, else the tail. The first lines
# are a runner's banner — a config warning on every run of some runners — so a reason
# made of them named no case, and the fix round's one retry was handed nothing.
_driver_fail_lines() { # <file>
  local l
  l=$(grep -E '(^|[[:space:]])(FAIL|not ok|×|✗|✖)([[:space:]]|$)|AssertionError|Error:|[0-9]+ (case|test)\(?s?\)? failed' "$1" 2>/dev/null | head -6)
  [ -n "$l" ] || l=$(tail -5 "$1" 2>/dev/null)
  printf '%s' "$l" | tr '\n' ' ' | cut -c1-600
}

# NO APP SERVER RUNS IN A PROOF TREE. A Playwright spec named as a proof died on
# `page.goto: net::ERR_CONNECTION_REFUSED` in both halves, and the second was read as
# "still fails with the change" about a change nothing had measured. Unless the project
# says its e2e harness brings the app up (`tests.e2eProofs: true`), an e2e spec is
# turned back before a tree is built, and a half that could not reach the app is 9.
DRIVER_PROOF_UNREACHABLE_RE='net::ERR_CONNECTION_REFUSED|page\.goto: net::ERR_|ECONNREFUSED[^[:cntrl:]]{0,40}(localhost|127\.0\.0\.1|::1)'
DRIVER_PROOF_E2E_HOW='prove it with a unit or DOM test (vitest, a *.test.ts or *.dom.test.tsx) that goes red without the change; the e2e spec can still ship as extra coverage'
driver_proof_e2e_ok() { [ "$(driver_opt tests.e2eProofs false)" = true ]; }
# _driver_proof_unreachable <rc> <out-file> — 0 when a failing half could not reach the app.
_driver_proof_unreachable() {
  [ "$1" -ne 0 ] && ! driver_proof_e2e_ok && grep -qE -- "$DRIVER_PROOF_UNREACHABLE_RE" "$2" 2>/dev/null
}
_driver_proof_unreachable_why() { # <test-file> <out-file>
  printf '%s could not reach the app (%s): a proof tree runs no app server, so the test was never run there — %s\n' \
    "$1" "$(grep -oE -- "$DRIVER_PROOF_UNREACHABLE_RE" "$2" 2>/dev/null | head -1)" "$DRIVER_PROOF_E2E_HOW"
}

# driver_proof_cmd_check <tree> <command> [<test-file>] — 0 when the command can be
# run verbatim from the tree's root; else prints why and returns 1.
#
# A PLACEHOLDER IS NOT A RED. `DATABASE_URL=<throwaway postgres> npx vitest …` died
# in bash on `<throwaway` as a redirect from a missing file, in both halves, and the
# proof read the second as "still fails with the change" about a change that worked.
driver_proof_cmd_check() {
  local tree="$1" cmd="$2" tfile="${3:-<file>}" ph w lw first="" eg
  local -a words=()
  eg="give the exact command, run from the worktree root, e.g. npx vitest run $tfile"
  ph=$(printf '%s' "$cmd" | grep -oE '<[A-Za-z][^<>]*>' | head -1)
  if [ -n "$ph" ]; then
    printf "the command holds a placeholder '%s' and is run verbatim — %s\n" "$ph" "$eg"; return 1
  fi
  if ! driver_proof_e2e_ok && { printf '%s' "$tfile" | grep -qE '(^|/)e2e/.*\.spec\.[cm]?[jt]sx?$' \
       || printf '%s' "$cmd" | grep -qE '(^|[^a-z])playwright[[:space:]]+test'; }; then
    printf 'an e2e browser spec cannot prove a change here: a proof tree runs no app server, so every page load is refused on both sides — %s\n' "$DRIVER_PROOF_E2E_HOW"
    return 1
  fi
  # LOCAL ONLY IS THE ONE FILE. Under gates.localOnly a proof runs the test file it names,
  # never a command the local set leaves for CI (a test:changed, a suite).
  if driver_cmd_ci_only "$cmd"; then
    printf 'the command is one gates.localOnly keeps for CI (it is in gates.changed, not gates.local), and a proof runs only its own test file — %s\n' "$eg"
    return 1
  fi
  if [ "$tfile" != "<file>" ] && driver_gates_local_only && [[ "$cmd" != *"$(basename "$tfile")"* ]]; then
    printf 'the command does not name %s, and under gates.localOnly a proof runs that one test file and nothing more — %s\n' "$tfile" "$eg"
    return 1
  fi
  # read -a, not `for w in $cmd`: a bare `*.test.ts` would glob against the cwd.
  read -rd '' -a words <<<"$cmd" || true
  # The first word is judged only where a split on spaces finds it: past an
  # assignment holding quotes, `$(`, or a `;`, the shell's own parse is needed.
  local compound=0
  for w in ${words[@]+"${words[@]}"}; do
    case "$w" in
      [A-Za-z_]*=*) case "$w" in *[\"\'\`\;]*|*'$('*) compound=1; break ;; esac; continue ;;
    esac
    first="${w#[\"\']}"; first="${first%[\"\']}"
    while :; do case "$first" in [\(\{!]*) first="${first#?}" ;; *) break ;; esac; done
    case "$first" in *[\$\`]*|'') compound=1 ;; esac
    break
  done
  [ "${#words[@]}" -gt 0 ] || { printf 'the command is empty — %s\n' "$eg"; return 1; }
  if [ "$compound" -eq 0 ] && [ -n "$first" ] \
     && ! ( cd "$tree" 2>/dev/null && command -v -- "$first" >/dev/null 2>&1 ) && [ ! -e "$tree/$first" ]; then
    printf "the command's first word '%s' is not a program on PATH or a file in the tree — %s\n" "$first" "$eg"
    return 1
  fi
  for w in ${words[@]+"${words[@]}"}; do
    lw=$(printf '%s' "$w" | tr '[:upper:]' '[:lower:]')
    case "$lw" in
      '...'|*'…'*|throwaway|todo|tbd|fixme|placeholder|xxx)
        printf "the command holds a placeholder word '%s' and is run verbatim — %s\n" "$w" "$eg"; return 1 ;;
    esac
  done
  return 0
}

# A PROOF THAT FAILS ON A MISSING MODULE FROM A BEHIND INSTALL IS THE MACHINE'S.
# A private install missing a declared package made every import of it "Cannot find
# module", and the proof said the change does not type-check: a repair parked as not
# proved on a tree whose code was right. So a failing verdict (1, 2 or 6) that names a
# missing module, while the install the proof trees link from is behind its lockfile,
# is relinked and taken once more. Still behind, or the shared install itself behind,
# it is 8 — a machine fault, back on the queue, never "not proved".
DRIVER_PROOF_MISSING_RE="Cannot find (module|package)|ERR_MODULE_NOT_FOUND|Failed to resolve import|Failed to load url"
_driver_proof_machine() { # <proof fn> <repo> <args…>
  local fn="$1" repo="$2" out rc try=0 behind mod
  shift 2
  while :; do
    rc=0; out=$("$fn" "$repo" "$@") || rc=$?
    case "$rc" in 1|2|6) ;; *) break ;; esac
    grep -qE -- "$DRIVER_PROOF_MISSING_RE" <<<"$out" || break
    behind=$(bash "$KIT_ROOT/scripts/link-node-modules.sh" --behind "$repo" 2>/dev/null) || break
    mod=$(grep -oE -- "${DRIVER_PROOF_MISSING_RE}[^)]{0,80}" <<<"$out" | head -1)
    if [ "$try" -ge 1 ] || [ "$repo" -ef "${MAIN_REPO:-/nonexistent}" ] || ! driver_relink_if_behind "$MAIN_REPO" "$repo"; then
      printf 'machine fault, not the change: the proof failed on a missing module (%s) and the install it links from is behind its lockfile — %s\n' \
        "$mod" "${DRIVER_BEHIND_WHY:-$behind}"
      return 8
    fi
    try=1
    driver_say "   proof: it failed on a missing module ($mod) from an install behind its lockfile — relinked, taken once more" >&2
  done
  printf '%s\n' "$out"
  return "$rc"
}
driver_prove_red_green() { _driver_proof_machine _driver_prove_red_green_once "$@"; }
driver_prove_by_break()  { _driver_proof_machine _driver_prove_by_break_once "$@"; }

_driver_prove_red_green_once() {
  local repo="$1" tfile="$2" tsha="$3" isha="$4" cmd="$5"
  local base tmp rc_red rc_green

  # Checked before any tree is built: a command that cannot run proves nothing.
  local cwhy
  if ! cwhy=$(driver_proof_cmd_check "$repo" "$cmd" "$tfile"); then
    printf '%s, so the test was never run\n' "$cwhy"; return 7
  fi

  # TWO COMMITS HAVE TO BE TWO. Reported as one, the parent holds neither the test
  # nor the change, the test is copied in and goes red, and the commit makes it
  # green — so a squash that did no test-first at all reads as a clean proof.
  # Nothing about the trees can tell them apart; only the two shas can.
  if [ "$(git -C "$repo" rev-parse --verify "$tsha" 2>/dev/null)" \
     = "$(git -C "$repo" rev-parse --verify "$isha" 2>/dev/null)" ]; then
    printf 'the test and the change are the same commit (%s) — one commit cannot show which came first\n' \
      "$(printf '%s' "$isha" | cut -c1-8)"; return 3
  fi

  base=$(git -C "$repo" rev-parse --verify "$isha^" 2>/dev/null) || {
    printf 'the change commit %s has no parent to compare against\n' "$isha"; return 3; }
  git -C "$repo" cat-file -e "$tsha:$tfile" 2>/dev/null || {
    printf 'no %s in %s — the commit named as adding the test does not contain it\n' "$tfile" "$tsha"; return 3; }
  # AND IT HAS TO BE THERE WHEN THE CHANGE LANDS. The green half runs at $isha; if
  # the test was committed afterwards it is absent there, and a suite-wide command
  # then runs nothing and exits 0 — "then green" said about a run that never
  # executed the test, which is exactly test-written-afterwards.
  git -C "$repo" cat-file -e "$isha:$tfile" 2>/dev/null || {
    printf '%s is not in the change commit %s — a test committed after the change cannot have come before it\n' \
      "$tfile" "$(printf '%s' "$isha" | cut -c1-8)"; return 3; }

  # Two more trees with their installs: under the disk guard's floor the proof is never taken.
  local low
  if [ -f "$DRIVER_HOME/../scripts/disk-guard.sh" ] \
     && ! low=$(bash "$DRIVER_HOME/../scripts/disk-guard.sh" check "a red/green proof"); then
    printf '%s, so the test was never run\n' "$low"; return 5
  fi
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/driver-proof-XXXXXX")
  git -C "$repo" worktree add -q --detach "$tmp/before" "$base" 2>/dev/null || {
    rm -rf "$tmp"; printf 'could not check out %s\n' "$base"; return 3; }
  if ! _driver_proof_install "$repo" "$tmp/before"; then
    git -C "$repo" worktree remove --force "$tmp/before" >/dev/null 2>&1; rm -rf "$tmp"
    printf 'the tree without the change could not be prepared, so the test was never run there: %s\n' "$DRIVER_PREPARE_WHY"
    return 5
  fi
  # The version run in both halves: the change's own when the test commit came first
  # (the change may edit the test it names), else the reported one.
  local vsha="$tsha"
  git -C "$repo" merge-base --is-ancestor "$tsha" "$isha" 2>/dev/null && vsha="$isha"
  mkdir -p "$(dirname "$tmp/before/$tfile")"
  git -C "$repo" show "$vsha:$tfile" > "$tmp/before/$tfile"
  ( cd "$tmp/before" && driver_with_test_db "$tmp/before.db" "$tmp/before" driver_run_project "$DRIVER_CMD_TIMEOUT" "$cmd" ) >"$tmp/before.out" 2>&1
  rc_red=$?

  git -C "$repo" worktree add -q --detach "$tmp/after" "$isha" 2>/dev/null || {
    git -C "$repo" worktree remove --force "$tmp/before" >/dev/null 2>&1; rm -rf "$tmp"
    printf 'could not check out %s\n' "$isha"; return 3; }
  if ! _driver_proof_install "$repo" "$tmp/after"; then
    git -C "$repo" worktree remove --force "$tmp/before" >/dev/null 2>&1
    git -C "$repo" worktree remove --force "$tmp/after"  >/dev/null 2>&1; rm -rf "$tmp"
    printf 'the tree with the change could not be prepared, so the test was never run there: %s\n' "$DRIVER_PREPARE_WHY"
    return 5
  fi
  # The SAME version of the test in both trees. A test sharpened after the change is
  # ordinary, and then the change's own tree holds an EARLIER version: running that
  # one measures a different test in each half. One version, two trees.
  mkdir -p "$(dirname "$tmp/after/$tfile")"
  git -C "$repo" show "$vsha:$tfile" > "$tmp/after/$tfile"
  ( cd "$tmp/after" && driver_with_test_db "$tmp/after.db" "$tmp/after" driver_run_project "$DRIVER_CMD_TIMEOUT" "$cmd" ) >"$tmp/after.out" 2>&1
  rc_green=$?
  # GREEN UNDER A RUNNER IS NOT GREEN UNDER THE COMPILER. vitest strips types, so a
  # test whose calls do not type-check passed this proof and then failed self-check's
  # typecheck on the same file. Only once the test is green — a red half is allowed to
  # be a compile error.
  local tc_rc=0 tc_out="" tc
  tc=$(driver_proof_typecheck_cmd)
  if [ "$rc_red" -ne 0 ] && [ "$rc_red" -ne 124 ] && [ "$rc_green" -eq 0 ] && [ -n "$tc" ]; then
    ( cd "$tmp/after" && driver_run_project "$DRIVER_CMD_TIMEOUT" "$tc" ) >"$tmp/typecheck.out" 2>&1
    tc_rc=$?
    tc_out=$(_driver_typecheck_lines "$tmp/typecheck.out")
  fi

  # A DATABASE THAT COULD NOT BE MADE IS NOT A RED: the test never ran against one.
  local dbwhy=""
  [ -s "$tmp/before.db" ] && dbwhy="without the change: $(cat "$tmp/before.db")"
  [ -z "$dbwhy" ] && [ -s "$tmp/after.db" ] && dbwhy="with the change: $(cat "$tmp/after.db")"
  git -C "$repo" worktree remove --force "$tmp/before" >/dev/null 2>&1
  git -C "$repo" worktree remove --force "$tmp/after"  >/dev/null 2>&1
  if [ -n "$dbwhy" ]; then
    rm -rf "$tmp"; printf 'the test database could not be prepared %s, so the test was never run there\n' "$dbwhy"; return 5
  fi
  local red_out after_out uwhy=""
  if _driver_proof_unreachable "$rc_red" "$tmp/before.out"; then uwhy=$(_driver_proof_unreachable_why "$tfile" "$tmp/before.out")
  elif _driver_proof_unreachable "$rc_green" "$tmp/after.out"; then uwhy=$(_driver_proof_unreachable_why "$tfile" "$tmp/after.out"); fi
  [ -z "$uwhy" ] || { rm -rf "$tmp"; printf '%s' "$uwhy"; return 9; }
  red_out=$(_driver_fail_lines "$tmp/before.out")
  after_out=$(_driver_fail_lines "$tmp/after.out")
  rm -rf "$tmp"
  if [ "$tc_rc" -eq 124 ]; then
    printf 'the typecheck (%s) ran out of time (over %ss) in the tree with the change\n' "$tc" "$DRIVER_CMD_TIMEOUT"
    return 4
  fi
  if [ "$tc_rc" -ne 0 ]; then
    printf '%s passes with the change but the change does not type-check (%s, exit %s): %s\n' \
      "$tfile" "$tc" "$tc_rc" "$tc_out"
    return 6
  fi

  # A HANG IS NOT A RED. Out of time says nothing about the change, and it is
  # reported before the red/green reading so a watch-mode runner cannot be read as a
  # test that failed honestly.
  if [ "$rc_red" -eq 124 ] || [ "$rc_green" -eq 124 ]; then
    printf '%s ran out of time (over %ss) — a command that does not return cannot prove anything. A watch-mode runner is the usual cause.\n' \
      "$tfile" "$DRIVER_CMD_TIMEOUT"
    return 4
  fi
  if [ "$rc_red" -eq 0 ]; then
    printf '%s passes without the change — it does not test it. (%s)\n' "$tfile" "$red_out"
    return 1
  fi
  if [ "$rc_green" -ne 0 ]; then
    printf '%s still fails with the change (exit %s): %s\n' "$tfile" "$rc_green" "$after_out"
    return 2
  fi
  printf '%s: red (exit %s) at %s, then green at %s\n' \
    "$tfile" "$rc_red" "$(printf '%s' "$base" | cut -c1-8)" "$(printf '%s' "$isha" | cut -c1-8)"
  return 0
}


# driver_prove_by_break <repo> <test-file> <test-commit> <break-file> <find> <replace> <command>
#
# THE PROOF FOR A TASK WHOSE DELIVERABLE IS THE TEST. The code it covers already
# exists, so there is no tree without the change to be red at — the red/green proof
# above can only ever say "passes without the change" about it, and the 2026-09-30
# trial parked a test-only ticket for exactly that. Here the break is planted
# instead: the production code the test covers is broken in a throwaway tree, the
# test must FAIL, the break is removed, and the test must PASS. That is "plant the
# death, not the typo" run by the driver rather than asked of the model.
#
# The break is a literal find/replace, not a patch: a model's hand-written diff
# hunks are the usual reason `git apply` says no, and a refusal the model cannot
# fix is a rework loop about formatting.
#
# 0 red with the break, green without · 1 green with the break — the test does not
# cover that code · 2 red without the break · 3 the answer cannot be checked ·
# 4 out of time · 5 the tree could not be prepared · 6 it does not type-check ·
# 7 the command cannot be run as given · 8 a machine fault: an install behind its lockfile ·
# 9 a half could not reach the app — never run there
_driver_prove_by_break_once() {
  local repo="$1" tfile="$2" tsha="$3" bfile="$4" find="$5" repl="$6" cmd="$7"
  local tmp n rc_red rc_green red_out green_out cwhy

  if ! cwhy=$(driver_proof_cmd_check "$repo" "$cmd" "$tfile"); then
    printf '%s, so the test was never run\n' "$cwhy"; return 7
  fi
  git -C "$repo" cat-file -e "$tsha:$tfile" 2>/dev/null || {
    printf 'no %s in %s — the commit named as adding the test does not contain it\n' "$tfile" "$tsha"; return 3; }
  # THE BREAK IS IN THE CODE, NEVER IN THE TEST. Breaking the test itself proves the
  # test can be made to fail, which any test can.
  if [ "$bfile" = "$tfile" ]; then
    printf 'the break is planted in the test file %s itself — it has to break the code the test covers\n' "$tfile"; return 3
  fi
  git -C "$repo" cat-file -e "$tsha:$bfile" 2>/dev/null || {
    printf 'no %s in %s — the break names a file that is not there\n' "$bfile" "$(printf '%s' "$tsha" | cut -c1-8)"; return 3; }
  if [ -z "$find" ] || [ "$find" = "$repl" ]; then
    printf 'the break changes nothing in %s — find is empty or equal to replace\n' "$bfile"; return 3
  fi

  tmp=$(mktemp -d "${TMPDIR:-/tmp}/driver-break-XXXXXX")
  git -C "$repo" worktree add -q --detach "$tmp/tree" "$tsha" 2>/dev/null || {
    rm -rf "$tmp"; printf 'could not check out %s\n' "$tsha"; return 3; }
  _driver_break_done() { git -C "$repo" worktree remove --force "$tmp/tree" >/dev/null 2>&1; rm -rf "$tmp"; }
  if ! _driver_proof_install "$repo" "$tmp/tree"; then
    _driver_break_done
    printf 'the tree for the planted break could not be prepared, so the test was never run there: %s\n' "$DRIVER_PREPARE_WHY"
    return 5
  fi
  cp "$tmp/tree/$bfile" "$tmp/original"
  # Literal on both sides: no regex, no interpolation. The count is the assertion that
  # the substitution landed — a replace that matched nothing still "succeeds".
  n=$(BREAK_FIND="$find" BREAK_REPL="$repl" perl -0777 -i -pe \
        'BEGIN{$f=$ENV{BREAK_FIND};$r=$ENV{BREAK_REPL};$c=0} $c += s/\Q$f\E/$r/g; END{print STDERR $c}' \
        "$tmp/tree/$bfile" 2>&1 >/dev/null)
  if [ "${n:-0}" -eq 0 ] 2>/dev/null || ! [ "${n:-0}" -ge 0 ] 2>/dev/null; then
    _driver_break_done
    printf 'the break text is not in %s at %s — nothing was broken, so nothing would be measured\n' "$bfile" "$(printf '%s' "$tsha" | cut -c1-8)"
    return 3
  fi
  ( cd "$tmp/tree" && driver_with_test_db "$tmp/red.db" "$tmp/tree" driver_run_project "$DRIVER_CMD_TIMEOUT" "$cmd" ) >"$tmp/red.out" 2>&1
  rc_red=$?
  cp "$tmp/original" "$tmp/tree/$bfile"
  ( cd "$tmp/tree" && driver_with_test_db "$tmp/green.db" "$tmp/tree" driver_run_project "$DRIVER_CMD_TIMEOUT" "$cmd" ) >"$tmp/green.out" 2>&1
  rc_green=$?
  # The same compile check as the red/green proof, on the restored tree.
  local tc_rc=0 tc_out="" tc
  tc=$(driver_proof_typecheck_cmd)
  if [ "$rc_red" -ne 0 ] && [ "$rc_red" -ne 124 ] && [ "$rc_green" -eq 0 ] && [ -n "$tc" ]; then
    ( cd "$tmp/tree" && driver_run_project "$DRIVER_CMD_TIMEOUT" "$tc" ) >"$tmp/typecheck.out" 2>&1
    tc_rc=$?
    tc_out=$(_driver_typecheck_lines "$tmp/typecheck.out")
  fi
  local dbwhy=""
  [ -s "$tmp/red.db" ] && dbwhy="with the break: $(cat "$tmp/red.db")"
  [ -z "$dbwhy" ] && [ -s "$tmp/green.db" ] && dbwhy="with the code restored: $(cat "$tmp/green.db")"
  local uwhy=""
  if _driver_proof_unreachable "$rc_red" "$tmp/red.out"; then uwhy=$(_driver_proof_unreachable_why "$tfile" "$tmp/red.out")
  elif _driver_proof_unreachable "$rc_green" "$tmp/green.out"; then uwhy=$(_driver_proof_unreachable_why "$tfile" "$tmp/green.out"); fi
  red_out=$(_driver_fail_lines "$tmp/red.out")
  green_out=$(_driver_fail_lines "$tmp/green.out")
  _driver_break_done
  [ -z "$uwhy" ] || { printf '%s' "$uwhy"; return 9; }
  if [ -n "$dbwhy" ]; then
    printf 'the test database could not be prepared %s, so the test was never run there\n' "$dbwhy"; return 5
  fi
  if [ "$tc_rc" -eq 124 ]; then
    printf 'the typecheck (%s) ran out of time (over %ss) on the tree with the code restored\n' "$tc" "$DRIVER_CMD_TIMEOUT"
    return 4
  fi
  if [ "$tc_rc" -ne 0 ]; then
    printf '%s passes but does not type-check (%s, exit %s): %s\n' "$tfile" "$tc" "$tc_rc" "$tc_out"
    return 6
  fi

  if [ "$rc_red" -eq 124 ] || [ "$rc_green" -eq 124 ]; then
    printf '%s ran out of time (over %ss) — a command that does not return cannot prove anything. A watch-mode runner is the usual cause.\n' \
      "$tfile" "$DRIVER_CMD_TIMEOUT"
    return 4
  fi
  if [ "$rc_red" -eq 0 ]; then
    printf '%s still passes with %s broken — it does not test that code. (%s)\n' "$tfile" "$bfile" "$red_out"
    return 1
  fi
  if [ "$rc_green" -ne 0 ]; then
    printf '%s fails with the code intact (exit %s): %s\n' "$tfile" "$rc_green" "$green_out"
    return 2
  fi
  printf '%s: red (exit %s) with %s broken, then green with it restored, at %s\n' \
    "$tfile" "$rc_red" "$bfile" "$(printf '%s' "$tsha" | cut -c1-8)"
  return 0
}

driver_step_build() { # <ticket>
  local t="${1:?driver_step_build: need a ticket}"
  local repo tries rc ntasks bad task slot ans tfile tcmd tsha isha bfile why prc
  local want_task got_task pair seen_pairs="" seen_titles="" same merged=0
  export DRIVER_TICKET="$t"
  repo=$(driver_state_get "$t" worktree)
  [ -n "$repo" ] || repo="$MAIN_REPO"

  driver_check_timeout || true
  # A RUN THAT RESUMES A BUILD WHICH SPENT ITS TRIES STARTS A FRESH ROUND. The count
  # lives on the record across runs, so the run after a park opened at 6 of 5 and
  # parked again after one try (#13584).
  tries=$(driver_state_count "$t" build)
  if [ "${tries:-0}" -ge "$DRIVER_MAX_BUILD_TRIES" ]; then
    _driver_state_edit "$t" '.counters.build = 0'
    driver_say "   build: an earlier run spent its $DRIVER_MAX_BUILD_TRIES tries — this run starts a fresh round of $DRIVER_MAX_BUILD_TRIES"
  fi
  driver_state_bump "$t" build
  tries=$(driver_state_count "$t" build)

  # ONE CALL PER PLAN TASK, because that is what the brief and the contract say:
  # build.md opens "You are building **one** task from the plan", and
  # briefs/schemas/build.json carries ONE `task` string and ONE `testFirst` object.
  # This step used to read `.items[]` with `test_file` / `test_commit` / `impl_commit`
  # — four names the contract does not have and `additionalProperties: false`
  # forbids — so an answer meeting the contract was refused here and an answer this
  # could read was refused by the validator. The same defect as the plan step's, in
  # the step the trial never reached.
  #
  # Sequential, never parallel: inside a ticket the fan-out belongs to
  # superpowers:subagent-driven-development, which the brief invokes, with a fresh
  # helper per task. The driver never starts several agents on one ticket.
  ntasks=$(jq -r '[.tasks[]?] | length' "$(driver_state_dir "$t")/steps/plan.json" 2>/dev/null)
  if [ "${ntasks:-0}" -eq 0 ]; then
    driver_say "✋ build: the plan carries no task to build. A build that changed nothing is not a build that passed."
    return "$DRIVER_E_REFUSED"
  fi

  bad=0
  : > "$(driver_state_dir "$t")/steps/build.all.json"
  # A REWORK REBUILDS WHAT WAS SENT BACK, NOT THE PLAN. #13623 had six tasks proved and
  # one refused; the rework round rebuilt all seven (15:13–15:35Z), and the resume after
  # a usage stop rebuilt five already proved. A task proved on an earlier pass, whose
  # plan entry is unchanged and whose commits are still on the branch, is kept.
  local keep kept=0
  keep=$(_driver_build_keepable "$t" "$repo" "$ntasks")
  if [ -n "$keep" ]; then
    driver_say "   build: $(printf '%s' "$keep" | wc -w | tr -d ' ') of $ntasks task(s) kept from an earlier pass (proved, commits still on the branch); building the rest again"
  fi
  local i=0
  while [ "$i" -lt "$ntasks" ]; do
    task=$(jq -c --argjson i "$i" '.tasks[$i]' "$(driver_state_dir "$t")/steps/plan.json")
    i=$((i+1))
    slot="build-task-$i"
    ans="$(driver_state_dir "$t")/steps/$slot.json"
    local proved="$(driver_state_dir "$t")/steps/$slot.proved"

    if _driver_build_in "$i" "$keep"; then
      jq -c '.answer' "$proved" >> "$(driver_state_dir "$t")/steps/build.all.json"
      pair=$(jq -r '.pair' "$proved")
      if [ "$(jq -r '.merged' "$proved")" = true ]; then
        merged=$((merged+1))
      else
        seen_pairs="$seen_pairs $pair"
        seen_titles="$seen_titles$pair	$(jq -r '.title' "$proved")
"
      fi
      kept=$((kept+1))
      driver_say "   build $(jq -r '.title' "$proved") — kept: proved on an earlier pass"
      continue
    fi
    rm -f "$proved"

    # The one task this call builds, as the brief's own placeholder.
    driver_fact_put "$t" "$slot" PLAN_TASK "$(printf '%s' "$task" | jq .)"
    # What the driver said about the last try at this task, so a retry is not blind.
    if [ -s "$(driver_state_dir "$t")/steps/$slot.refused" ]; then
      driver_fact_put "$t" "$slot" LAST_TRY "$(cat "$(driver_state_dir "$t")/steps/$slot.refused")"
    else
      driver_fact_put "$t" "$slot" LAST_TRY "$(_driver_fact_none "this is the first try at this task, or the last one was proved")"
    fi
    rc=0; driver_ai_step "$t" build --as "$slot" || rc=$?
    if [ "$rc" -ne 0 ]; then
      # A question, a skipped Skill or a broken answer is not a rework loop: those
      # park, and they park with their OWN reason. Running them through the ceiling
      # would rewrite the model's question as "build refused (exit 24)" on the last
      # try, and the operator would be handed a code in place of the question they
      # have to answer. Only an UNPROVED build is worth another try.
      return "$rc"
    fi
    jq -c . "$ans" >> "$(driver_state_dir "$t")/steps/build.all.json"
    driver_git_actions "$t" "$repo" "$ans" "build $slot" || return "$DRIVER_E_REFUSED"
    # Formatted with the task, so a format check can never be the thing self-check
    # sends back. After the answer is read: the proof names its own two commits.
    driver_format_changed "$t" "$repo" "build $slot" || true
    # The tests this task reworded or removed, on the run's one ledger: the commits
    # stay on the branch across build tries and restarts, so their reports must too.
    jq -c '(.replacedTests // [])[]' "$ans" >> "$(driver_state_dir "$t")/steps/replaced.jsonl" 2>/dev/null || true

    # THE ANSWER MUST NOT BE ABOUT A DIFFERENT TASK. The proof re-runs whatever two
    # shas it is handed and cannot tell which task they belong to — so an answer that
    # returns ANOTHER task's title and commits proves red-then-green perfectly, `bad`
    # stays 0, and the step reports every task built while one was never touched. The
    # suite's own two-task case did exactly that and passed.
    #
    # IT IS NOT BYTE EQUALITY WITH THE TITLE ASKED FOR. Nothing in build.md told the
    # model the string had to be verbatim, so a restored full stop or a normalised dash
    # would have sent a perfectly built task round the rework loop five times and then
    # parked it saying "the tests still do not prove the change" — a sentence that is
    # false, about tests that are fine. Adding a checker without adding the prompt is
    # this repo's own named defect, so the brief now states the rule AND the check only
    # fires on the thing that is unambiguously wrong: a title belonging to a different
    # task in this same plan. A title matching none of them is said and allowed.
    want_task=$(printf '%s' "$task" | jq -r '.title // ""')
    got_task=$(jq -r '.task // ""' "$ans")
    if [ -n "$got_task" ] && [ "$got_task" != "$want_task" ]; then
      if jq -e --arg g "$got_task" --arg w "$want_task" \
           '[.tasks[]?.title] | index($g) != null and $g != $w' \
           "$(driver_state_dir "$t")/steps/plan.json" >/dev/null 2>&1; then
        driver_say "✋ build: this call was given '$want_task' and the answer builds '$got_task', which is another task in this plan. A task nobody built is a task that ships unbuilt."
        bad=1; continue
      fi
      driver_say "   build: the answer calls this task '$got_task'; the plan calls it '$want_task'"
    fi
    # A TASK WHOSE DELIVERABLE IS THE TEST is proved by a planted break, because the
    # code it covers is already there and nothing can be red before it. Dom's rule,
    # 2026-09-30: break the production code, show red, restore, show green.
    if jq -e '.testOnly | type == "object"' "$ans" >/dev/null 2>&1; then
      isha=""
      tfile=$(jq -r '.testOnly.test.file // ""' "$ans")
      tcmd=$(jq -r  '.testOnly.command // ""'   "$ans")
      tsha=$(jq -r  '.testOnly.testCommit // ""' "$ans")
      bfile=$(jq -r '.testOnly.break.file // ""' "$ans")
      if [ -z "$tfile" ] || [ -z "$tcmd" ] || [ -z "$tsha" ] || [ -z "$bfile" ]; then
        driver_say "✋ build '$(jq -r '.task // "?"' "$ans")' is test-only and names no break to prove it (testOnly needs test.file, command, testCommit and break)."
        bad=1; continue
      fi
      pair="$(git -C "$repo" rev-parse --verify -q "$tsha^{commit}" 2>/dev/null || printf '%s' "$tsha"):break:$bfile"
      if same=$(_driver_build_same_proof "$pair" "$seen_titles"); then
        driver_say "   build '$got_task' is proved by the same test commit and break as '$same' — one change, so the two are one task: merged, and proved once."
        _driver_build_mark_proved "$proved" "$task" "$ans" "$pair" "${got_task:-$want_task}" true "$tsha"
        merged=$((merged+1)); rm -f "$(driver_state_dir "$t")/steps/$slot.refused"; continue
      fi
      seen_pairs="$seen_pairs $pair"
      seen_titles="$seen_titles$pair	${got_task:-$want_task}
"
      why=""; prc=0
      why=$(driver_prove_by_break "$repo" "$tfile" "$tsha" "$bfile" "$(jq -r '.testOnly.break.find' "$ans")" "$(jq -r '.testOnly.break.replace' "$ans")" "$tcmd") || prc=$?
    else
    tfile=$(jq -r '.testFirst.test.file // ""' "$ans")
    tcmd=$(jq -r  '.testFirst.command // ""'   "$ans")
    tsha=$(jq -r  '.testFirst.testCommit // ""' "$ans")
    isha=$(jq -r  '.testFirst.implCommit // ""' "$ans")
    if [ -z "$tfile" ] || [ -z "$tcmd" ] || [ -z "$tsha" ] || [ -z "$isha" ]; then
      driver_say "✋ build '$(jq -r '.task // "?"' "$ans")' names no test to prove it (testFirst needs test.file, command, testCommit and implCommit)."
      bad=1; continue
    fi
    # AND ITS OWN COMMITS. A pair already proved for an earlier task proves that task
    # again, not this one — same hole as the title, reached by the other door.
    #
    # KEYED ON THE RESOLVED COMMIT, not on the string the model typed. The contract asks
    # for seven characters or more, so `a1b2c3d` and its full sha are two keys for one
    # commit — and that is a third door to the same hole.
    pair="$(git -C "$repo" rev-parse --verify -q "$tsha^{commit}" 2>/dev/null || printf '%s' "$tsha"):$(git -C "$repo" rev-parse --verify -q "$isha^{commit}" 2>/dev/null || printf '%s' "$isha")"
    # TWO TASKS ONE CHANGE PROVES ARE ONE TASK. Refused, the model was asked five times
    # to split a change that was rightly one, and the ticket parked on a proof that held
    # (#13584). So the later task is merged into the earlier one, said, and not re-proved.
    if same=$(_driver_build_same_proof "$pair" "$seen_titles"); then
      driver_say "   build '$got_task' is proved by the same two commits as '$same' ($(printf '%s' "$tsha" | cut -c1-8) then $(printf '%s' "$isha" | cut -c1-8)) — one change, so the two are one task: merged, and proved once."
      _driver_build_mark_proved "$proved" "$task" "$ans" "$pair" "${got_task:-$want_task}" true "$tsha" "$isha"
      merged=$((merged+1)); rm -f "$(driver_state_dir "$t")/steps/$slot.refused"; continue
    fi
    seen_pairs="$seen_pairs $pair"
    seen_titles="$seen_titles$pair	${got_task:-$want_task}
"
    why=""; prc=0
    why=$(driver_prove_red_green "$repo" "$tfile" "$tsha" "$isha" "$tcmd") || prc=$?
    fi
    if [ "$prc" -eq 0 ]; then
      rm -f "$(driver_state_dir "$t")/steps/$slot.refused"
      _driver_build_mark_proved "$proved" "$task" "$ans" "$pair" "${got_task:-$want_task}" false "$tsha" $isha
    else
      printf '%s\n' "$why" > "$(driver_state_dir "$t")/steps/$slot.refused"
    fi
    if [ "$prc" -eq 0 ]; then
      driver_say "   build $(jq -r '.task // "?"' "$ans") — $why"
    elif [ "$prc" -eq 8 ]; then
      # The install's, not the change's: back on the queue, no try spent, no park.
      driver_say "🛑 build $(jq -r '.task // "?"' "$ans") — $why"
      driver_state_set "$t" park_note "$why"
      return "$DRIVER_E_BUSY"
    elif [ "$prc" -eq 5 ]; then
      # Not a rework and not a red: the proof was never taken. Retrying it five times
      # would spend the whole ceiling on a tree this machine cannot build, and then
      # park accusing the change.
      driver_say "✋ build $(jq -r '.task // "?"' "$ans") — $why"
      driver_state_set "$t" park_note "$why"
      return "$DRIVER_E_REFUSED"
    elif [ "$prc" -eq 4 ]; then
      # A HANG IS NOT A FAILING TEST, so it does not go in the retry bucket. Folded in
      # with the rest it was tried five times — at the default ceiling that is five
      # attempts times two proof halves of waiting — and the ticket then parked blaming
      # the change, which is what this step's own header forbids. It returns its own
      # code so the orchestrator parks with the real reason immediately.
      driver_say "✋ build $(jq -r '.task // "?"' "$ans") — $why"
      return "$DRIVER_E_TIMEOUT"
    else
      driver_say "✋ build $(jq -r '.task // "?"' "$ans") — $why"
      bad=1
    fi
  done

  if [ "$bad" -eq 0 ]; then
    if [ "$kept" -gt 0 ]; then
      driver_say "   build: all $ntasks task(s) proved red before green — $kept kept from an earlier pass, $((ntasks - kept)) built on this one"
    elif [ "$merged" -gt 0 ]; then
      driver_say "   build: all $ntasks task(s) proved red before green, as $((ntasks - merged)) change(s) — $merged merged into the task proved by the same commits"
    else
      driver_say "   build: all $ntasks task(s) proved red before green"
    fi
    return "$DRIVER_OK"
  fi
  _driver_build_out_of_tries "$t" "$tries" && return "$DRIVER_E_REFUSED"
  return "$DRIVER_E_REWORK"
}

# _driver_build_in <n> <list> — 0 when <n> is one of the space-separated <list>.
_driver_build_in() { case " $2 " in *" $1 "*) return 0 ;; esac; return 1; }

# _driver_build_mark_proved <marker> <plan-task> <answer> <pair> <title> <merged> <sha…>
# — what a later pass needs to keep this task without building it again: the plan
# entry it was proved against, the answer, and the commits that have to stay on the branch.
_driver_build_mark_proved() {
  local m="$1" task="$2" ans="$3" pair="$4" title="$5" merged="$6"; shift 6
  jq -n --argjson task "$task" --slurpfile a "$ans" --arg pair "$pair" --arg title "$title" \
    --argjson merged "$merged" --args \
    '{task: $task, answer: $a[0], pair: $pair, title: $title, merged: $merged,
      commits: [$ARGS.positional[] | select(. != "")]}' "$@" > "$m" 2>/dev/null || rm -f "$m"
}

# _driver_build_keepable <ticket> <repo> <ntasks> — the task numbers a pass can keep,
# space-separated. A task is kept when it was proved on an earlier pass, against the
# same plan entry, and every commit that proved it is still on the branch. Everything
# else is built again — and so is each LATER task whose files overlap one being built
# again, because it was proved on top of the code that is about to change.
_driver_build_keepable() {
  local t="$1" repo="$2" n="$3" d i m ok c task touched="" files f keep="" redo
  d="$(driver_state_dir "$t")/steps"
  i=0
  while [ "$i" -lt "$n" ]; do
    task=$(jq -c --argjson i "$i" '.tasks[$i]' "$d/plan.json" 2>/dev/null)
    i=$((i+1))
    m="$d/build-task-$i.proved"
    ok=0
    if [ -s "$m" ] && jq -e --argjson task "$task" '(.task == $task) and (.commits | length > 0)' "$m" >/dev/null 2>&1; then
      ok=1
      for c in $(jq -r '.commits[]' "$m"); do
        git -C "$repo" merge-base --is-ancestor "$c" HEAD 2>/dev/null || { ok=0; break; }
      done
    fi
    files=$(printf '%s' "$task" | jq -r '(.files // [])[] | if type == "object" then (.path // empty) else . end' 2>/dev/null)
    redo=$((1 - ok))
    if [ "$redo" -eq 0 ] && [ -n "$touched" ]; then
      while IFS= read -r f; do
        [ -n "$f" ] || continue
        grep -Fxq -- "$f" <<<"$touched" && { redo=1; break; }
      done <<EOF
$files
EOF
    fi
    if [ "$redo" -eq 1 ]; then
      touched="$touched
$files"
    else
      keep="$keep $i"
    fi
  done
  printf '%s' "${keep# }"
}

# _driver_build_same_proof <pair> <seen> — the title of the earlier task <pair> proved
# (<seen>: one "pair<TAB>title" per line); 1 when no earlier task used it.
_driver_build_same_proof() {
  printf '%s' "$2" | awk -F'\t' -v p="$1" '$1 == p { print $2; f = 1; exit } END { exit !f }'
}

# True when this was the last try. Five, per the approved design's flowchart: a
# loop with no ceiling is a run that never parks and never finishes.
_driver_build_out_of_tries() {
  [ "$2" -ge "$DRIVER_MAX_BUILD_TRIES" ] || return 1
  driver_say "✋ build: $2 of $DRIVER_MAX_BUILD_TRIES tries used and the tests still do not prove the change. Parking."
  return 0
}
