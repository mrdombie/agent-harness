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
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/feature-list.sh" || exit 1

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
#   8  it failed on a missing module from an install behind its lockfile, installed again and
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
# that resolves through the install — `npx x`, `./node_modules/.bin/x`,
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
  # Each proof tree gets its own install, cloned from the store for its lockfile: a
  # link to the ticket tree's would resolve its workspace packages to the ticket tree's
  # source, and the red half would run the change.
  driver_own_install "$2" || driver_own_install --fresh "$2" \
    || { DRIVER_PREPARE_WHY="the proof tree $2 could not be given its own install, even installed fresh"; return 1; }
  [ -d "$1/.husky/_" ] && { mkdir -p "$2/.husky"; cp -R "$1/.husky/_" "$2/.husky/_"; }
  _driver_proof_prepare "$2"
}
# _driver_proof_prepare <tree> — worktree.prepare, and once more on a fresh install when it
# fails: a stored install that is not its own lockfile's (no prisma bin, another prisma) is
# the machine's, and parking on it blamed a change the tree did not even hold.
_driver_proof_prepare() {
  # >&2, because the caller is a command substitution: `why=$(driver_prove_red_green …)`.
  # Left on stdout, driver_prepare_worktree's own narration was captured into $why and
  # printed as part of the proof's verdict — and on the refusal path the park note was
  # the same sentence twice, naming a temp tree that had already been deleted.
  driver_prepare_worktree "$1" >&2 && return 0
  local first="$DRIVER_PREPARE_WHY"
  driver_say "   proof: $1 could not be prepared on its install — installing it fresh, once (the driver's setup, not the change)" >&2
  if driver_own_install --fresh "$1" && driver_prepare_worktree "$1" >&2; then
    driver_say "   proof: $1 prepared on a fresh install" >&2
    return 0
  fi
  DRIVER_PREPARE_WHY="it failed again on a fresh install — ${DRIVER_PREPARE_WHY:-$first}"
  return 1
}

# PROOF TREES ARE REUSED ACROSS A RUN'S TASKS. Two fresh trees per proof, each with its
# own `worktree.prepare` (prisma:ensure), were ~30% of proof time on the origin project
# (21 proofs on 23 Oct: 1,672 of 5,676 s). Within one driver run (DRIVER_TICKET, this
# process) the before/after trees stay: a later proof checks the tree out at its commit
# (checkout -f, clean -fd: ignored installs and generated files stay), rebuilds only a
# stale install, and runs worktree.prepare again only when the prepare fingerprint at that
# commit moved — worktree.prepareFingerprint (path regexes), default every prisma file plus
# the lockfiles. driver.proofReuse false, or no ticket, builds fresh trees as before. The run's
# exit removes them (driver_proof_trees_drop, build-ticket's EXIT trap).
_driver_proof_reuse_dir() { # prints the run's proof-tree dir, or fails when reuse is off
  [ -n "${DRIVER_TICKET:-}" ] || return 1
  case "$(driver_opt driver.proofReuse true)" in false|0|no|off) return 1 ;; esac
  printf '%s/driver-proof-t%s-run%s' "${TMPDIR:-/tmp}" "$DRIVER_TICKET" "$$"
}
_driver_proof_fingerprint() { # <repo> <sha>
  local re
  re=$(jq -r '(.worktree.prepareFingerprint // empty) | if type == "array" then join("|") else . end' "${HARNESS_CFG:-/dev/null}" 2>/dev/null)
  [ -n "$re" ] || re='(^|/)prisma/|[.]prisma$|(^|/)(package-lock[.]json|pnpm-lock[.]yaml|yarn[.]lock)$'
  # The prepare commands are part of it: a changed worktree.prepare prepares again.
  { jq -c '.worktree.prepare // null' "${HARNESS_CFG:-/dev/null}" 2>/dev/null
    git -C "$1" ls-tree -r "$2" 2>/dev/null | awk -F'\t' -v re="$re" '$2 ~ re'; } | git hash-object --stdin
}
# _driver_proof_tree <repo> <tree> <sha> — <tree> checked out at <sha> and prepared.
# Reused when the run's dir holds it; 0 ready · 1 could not be checked out · 2 not prepared.
_driver_proof_tree() {
  local repo="$1" tree="$2" sha="$3" fp old
  fp=$(_driver_proof_fingerprint "$repo" "$sha")
  if [ -e "$tree/.git" ] && git -C "$tree" checkout -q --detach -f "$sha" 2>/dev/null && git -C "$tree" clean -fdq 2>/dev/null; then
    old=$(cat "$tree.fp" 2>/dev/null)
    # A failed rebuild leaves no install: prepare it, so the fresh retry gets its turn.
    driver_refresh_install "$tree" || old=""
    if [ -n "$fp" ] && [ "$fp" = "$old" ]; then
      driver_say "   proof: reused $tree at $(printf '%s' "$sha" | cut -c1-8) — the prepare fingerprint is unchanged, so worktree.prepare is skipped" >&2
      return 0
    fi
    rm -f "$tree.fp"
    _driver_proof_prepare "$tree" || return 2
    printf '%s' "$fp" > "$tree.fp"
    return 0
  fi
  git -C "$repo" worktree remove --force "$tree" >/dev/null 2>&1; rm -rf "$tree" "$tree.fp"; git -C "$repo" worktree prune 2>/dev/null
  mkdir -p "$(dirname "$tree")"
  git -C "$repo" worktree add -q --detach "$tree" "$sha" 2>/dev/null || return 1
  _driver_proof_install "$repo" "$tree" || return 2
  printf '%s' "$fp" > "$tree.fp"
}
# driver_proof_trees_drop — the run's proof trees removed (the run's exit).
driver_proof_trees_drop() {
  local d t; d=$(_driver_proof_reuse_dir) || return 0
  [ -d "$d" ] || return 0
  for t in "$d"/*; do [ -e "$t/.git" ] && git -C "$t" worktree remove --force "$t" >/dev/null 2>&1; done
  rm -rf "$d"
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
    elif .gates.localOnly == true then
      # Under gates.localOnly every other list is for CI: only gates.local names the check.
      ([(.gates.local // []) | if type == "array" then .[] | select(tc) else empty end] | first // "")
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

# _driver_proof_keep <command> <test-file> <red-rc> <red-out> <red-at> <green-rc> <green-out> <green-at>
# THE PROOF'S OWN OUTPUT OUTLIVES ITS TREES. The pull request carries the command the
# driver ran and what each half printed; the trees are gone by ship, so the tail of each
# half is written to $DRIVER_PROOF_KEEP when a caller names one. Bounded: last 40 lines, 2000 bytes.
_driver_proof_keep() {
  [ -n "${DRIVER_PROOF_KEEP:-}" ] || return 0
  jq -n --arg cmd "$1" --arg tf "$2" --argjson rr "$3" --arg ro "$(_driver_proof_tail "$4")" --arg ra "$5" \
        --argjson gr "$6" --arg go "$(_driver_proof_tail "$7")" --arg ga "$8" \
    '{command: $cmd, testFile: $tf, red: {exit: $rr, at: $ra, output: $ro}, green: {exit: $gr, at: $ga, output: $go}}' \
    > "$DRIVER_PROOF_KEEP" 2>/dev/null || rm -f "$DRIVER_PROOF_KEEP"
}
_driver_proof_tail() { tail -40 "$1" 2>/dev/null | LC_ALL=C tail -c 2000; }

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
# missing module, while the tree's install is behind its lockfile, is installed again
# and taken once more. Still behind, it is 8 — a machine fault, back on the queue,
# never "not proved".
DRIVER_PROOF_MISSING_RE="Cannot find (module|package)|ERR_MODULE_NOT_FOUND|Failed to resolve import|Failed to load url"
_driver_proof_machine() { # <proof fn> <repo> <args…>
  local fn="$1" repo="$2" out rc try=0 behind mod
  shift 2
  while :; do
    rc=0; out=$("$fn" "$repo" "$@") || rc=$?
    case "$rc" in 1|2|6) ;; *) break ;; esac
    grep -qE -- "$DRIVER_PROOF_MISSING_RE" <<<"$out" || break
    behind=$(bash "$KIT_ROOT/scripts/builder-install.sh" --behind "$repo" 2>/dev/null) || break
    mod=$(grep -oE -- "${DRIVER_PROOF_MISSING_RE}[^)]{0,80}" <<<"$out" | head -1)
    if [ "$try" -ge 1 ] || ! driver_reinstall_if_behind "$repo"; then
      printf 'machine fault, not the change: the proof failed on a missing module (%s) and the tree'"'"'s install is behind its lockfile — %s\n' \
        "$mod" "${DRIVER_BEHIND_WHY:-$behind}"
      return 8
    fi
    try=1
    driver_say "   proof: it failed on a missing module ($mod) from an install behind its lockfile — installed again, taken once more" >&2
  done
  printf '%s\n' "$out"
  return "$rc"
}
driver_prove_red_green() { _driver_proof_machine _driver_prove_red_green_once "$@"; }
driver_prove_by_break()  { _driver_proof_machine _driver_prove_by_break_once "$@"; }

# A FIX COMMITTED AFTER THE CHANGE COUNTS. A rework keeps reporting its first pair, so a
# green or typecheck failure at the change is proved once more at the latest branch commit
# touching the test's or the change's files; the red half stays at the change's parent.
_driver_prove_red_green_once() {
  local repo="$1" tfile="$2" tsha="$3" isha="$4" cmd="$5" out rc=0 lsha ffile
  local -a ffiles=()
  out=$(_driver_prove_red_green_at "$@") || rc=$?
  case "$rc" in 2|6) ;; *) printf '%s\n' "$out"; return "$rc" ;; esac
  if git -C "$repo" merge-base --is-ancestor "$isha" HEAD 2>/dev/null; then
    while IFS= read -r ffile; do [ -n "$ffile" ] && ffiles+=("$ffile"); done < <(
      { git -C "$repo" diff-tree --root --no-commit-id --name-only -r "$tsha"
        git -C "$repo" diff-tree --root --no-commit-id --name-only -r "$isha"; } 2>/dev/null | sort -u)
    [ "${#ffiles[@]}" -eq 0 ] \
      || lsha=$(git -C "$repo" log -1 --format=%H "$isha..HEAD" -- "${ffiles[@]}" 2>/dev/null)
  fi
  [ -n "${lsha:-}" ] || { printf '%s\n' "$out"; return "$rc"; }
  driver_say "   proof: green failed at $(printf '%s' "$isha" | cut -c1-8) — taken again at $(printf '%s' "$lsha" | cut -c1-8), the latest commit on the feature's files" >&2
  _driver_prove_red_green_at "$repo" "$tfile" "$tsha" "$isha" "$cmd" "$lsha"
}

# _driver_prove_red_green_at <repo> <test-file> <test-commit> <change-commit> <command> [green-commit]
_driver_prove_red_green_at() {
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
  # Reused across the run's tasks when it can be; the outputs go to a scratch dir of their own.
  local keep="" rd prc
  if rd=$(_driver_proof_reuse_dir); then keep=1; tmp="$rd"; mkdir -p "$tmp"; rm -f "$tmp"/*.out "$tmp"/*.db
  else tmp=$(mktemp -d "${TMPDIR:-/tmp}/driver-proof-XXXXXX"); fi
  _driver_proof_done() { # drop the trees unless the run keeps them
    [ -n "$keep" ] && return 0
    git -C "$repo" worktree remove --force "$tmp/before" >/dev/null 2>&1
    git -C "$repo" worktree remove --force "$tmp/after"  >/dev/null 2>&1
  }
  _driver_proof_rmtmp() { [ -n "$keep" ] && { rm -f "$tmp"/*.out "$tmp"/*.db; return 0; }; rm -rf "$tmp"; }
  prc=0
  if [ -n "$keep" ]; then _driver_proof_tree "$repo" "$tmp/before" "$base" || prc=$?
  else
    git -C "$repo" worktree add -q --detach "$tmp/before" "$base" 2>/dev/null || prc=1
    [ "$prc" -ne 0 ] || _driver_proof_install "$repo" "$tmp/before" || prc=2
  fi
  if [ "$prc" -eq 1 ]; then _driver_proof_done; _driver_proof_rmtmp; printf 'could not check out %s\n' "$base"; return 3; fi
  if [ "$prc" -ne 0 ]; then
    _driver_proof_done; _driver_proof_rmtmp
    # The base holds none of the change, so a tree of it that will not prepare is the driver's.
    printf 'a driver fault, not the change: the tree without the change could not be prepared, so the test was never run there: %s\n' "$DRIVER_PREPARE_WHY"
    return 5
  fi
  local asha="${6:-$isha}"
  # The version run in both halves: the green tree's own when the test commit came first
  # (later commits may edit the test it names), else the reported one.
  local vsha="$tsha"
  git -C "$repo" merge-base --is-ancestor "$tsha" "$asha" 2>/dev/null \
    && git -C "$repo" cat-file -e "$asha:$tfile" 2>/dev/null && vsha="$asha"
  mkdir -p "$(dirname "$tmp/before/$tfile")"
  git -C "$repo" show "$vsha:$tfile" > "$tmp/before/$tfile"
  ( cd "$tmp/before" && driver_with_test_db --for "$tfile" "$tmp/before.db" "$tmp/before" driver_run_project "$DRIVER_CMD_TIMEOUT" "$cmd" ) >"$tmp/before.out" 2>&1
  rc_red=$?

  prc=0
  if [ -n "$keep" ]; then _driver_proof_tree "$repo" "$tmp/after" "$asha" || prc=$?
  else
    git -C "$repo" worktree add -q --detach "$tmp/after" "$asha" 2>/dev/null || prc=1
    [ "$prc" -ne 0 ] || _driver_proof_install "$repo" "$tmp/after" || prc=2
  fi
  if [ "$prc" -eq 1 ]; then _driver_proof_done; _driver_proof_rmtmp; printf 'could not check out %s\n' "$asha"; return 3; fi
  if [ "$prc" -ne 0 ]; then
    _driver_proof_done; _driver_proof_rmtmp
    printf 'the tree with the change could not be prepared, so the test was never run there: %s\n' "$DRIVER_PREPARE_WHY"
    return 5
  fi
  # The SAME version of the test in both trees. A test sharpened after the change is
  # ordinary, and then the change's own tree holds an EARLIER version: running that
  # one measures a different test in each half. One version, two trees.
  mkdir -p "$(dirname "$tmp/after/$tfile")"
  git -C "$repo" show "$vsha:$tfile" > "$tmp/after/$tfile"
  ( cd "$tmp/after" && driver_with_test_db --for "$tfile" "$tmp/after.db" "$tmp/after" driver_run_project "$DRIVER_CMD_TIMEOUT" "$cmd" ) >"$tmp/after.out" 2>&1
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
  _driver_proof_done
  if [ -n "$dbwhy" ]; then
    _driver_proof_rmtmp; printf 'the test database could not be prepared %s, so the test was never run there\n' "$dbwhy"; return 5
  fi
  local red_out after_out uwhy=""
  if _driver_proof_unreachable "$rc_red" "$tmp/before.out"; then uwhy=$(_driver_proof_unreachable_why "$tfile" "$tmp/before.out")
  elif _driver_proof_unreachable "$rc_green" "$tmp/after.out"; then uwhy=$(_driver_proof_unreachable_why "$tfile" "$tmp/after.out"); fi
  [ -z "$uwhy" ] || { _driver_proof_rmtmp; printf '%s' "$uwhy"; return 9; }
  red_out=$(_driver_fail_lines "$tmp/before.out")
  after_out=$(_driver_fail_lines "$tmp/after.out")
  _driver_proof_keep "$cmd" "$tfile" "$rc_red" "$tmp/before.out" "$(printf '%s' "$base" | cut -c1-8)" \
    "$rc_green" "$tmp/after.out" "$(printf '%s' "$asha" | cut -c1-8)"
  _driver_proof_rmtmp
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
    "$tfile" "$rc_red" "$(printf '%s' "$base" | cut -c1-8)" "$(printf '%s' "$asha" | cut -c1-8)"
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
  ( cd "$tmp/tree" && driver_with_test_db --for "$tfile" "$tmp/red.db" "$tmp/tree" driver_run_project "$DRIVER_CMD_TIMEOUT" "$cmd" ) >"$tmp/red.out" 2>&1
  rc_red=$?
  cp "$tmp/original" "$tmp/tree/$bfile"
  ( cd "$tmp/tree" && driver_with_test_db --for "$tfile" "$tmp/green.db" "$tmp/tree" driver_run_project "$DRIVER_CMD_TIMEOUT" "$cmd" ) >"$tmp/green.out" 2>&1
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
  _driver_proof_keep "$cmd" "$tfile" "$rc_red" "$tmp/red.out" "$(printf '%s' "$tsha" | cut -c1-8) with $bfile broken" \
    "$rc_green" "$tmp/green.out" "$(printf '%s' "$tsha" | cut -c1-8) with it restored"
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

# driver_prove_no_code <repo> <head-before-the-task> <run url or id>
#
# THE PROOF FOR A TASK THAT CHANGES NO CODE (re-run a failed CI job). No commit, so no
# pair to run: the tree must be as the task found it, and the run it names is read
# here, never taken from the answer.
#
# 0 no diff, and the run concluded success on the branch's head · 1 the task changed
# the tree · 2 the run is missing, not green, or on another commit · 3 the claim
# cannot be checked
driver_prove_no_code() {
  local repo="$1" before="$2" run="$3" head id="" slug="" j rc=0 st con sha
  head=$(git -C "$repo" rev-parse --verify -q HEAD 2>/dev/null) || { printf 'the branch head could not be read\n'; return 3; }
  [ -n "$before" ] || { printf 'the head before this task was not recorded, so no diff could be measured\n'; return 3; }
  # Working tree against the head the task started from: committed or not, it is a diff.
  if ! git -C "$repo" diff --quiet "$before" -- 2>/dev/null; then
    printf 'the task is declared noCode and changed the tree since %s (%s) — a task with a diff proves it with testFirst or testOnly\n' \
      "$(printf '%s' "$before" | cut -c1-8)" "$(git -C "$repo" diff --name-only "$before" -- 2>/dev/null | head -3 | tr '\n' ' ' | sed 's/ $//')"
    return 1
  fi
  case "$run" in
    ''|*[!0-9]*)
      slug=$(printf '%s' "$run" | sed -nE 's#^https://github\.com/([^/]+/[^/]+)/actions/runs/[0-9]+(/.*)?$#\1#p')
      id=$(printf '%s' "$run" | sed -nE 's#^https://github\.com/[^/]+/[^/]+/actions/runs/([0-9]+)(/.*)?$#\1#p') ;;
    *) id="$run" ;;
  esac
  [ -n "$id" ] || { printf "noCode.run '%s' is not a CI run URL or id\n" "$run"; return 3; }
  if [ -n "$slug" ] && [ "$(printf '%s' "$slug" | tr '[:upper:]' '[:lower:]')" != "$(printf '%s' "$REPO_SLUG" | tr '[:upper:]' '[:lower:]')" ]; then
    printf 'CI run %s is a run of %s, not of this repo (%s)\n' "$id" "$slug" "$REPO_SLUG"; return 2
  fi
  j=$(GH_CALL_TIMEOUT="${GH_CALL_TIMEOUT:-30}" gh_read "CI run $id" api "repos/$REPO_SLUG/actions/runs/$id" 2>/dev/null) || rc=$?
  sha=$(jq -r '.head_sha // ""' <<<"$j" 2>/dev/null)
  if [ "$rc" -ne 0 ] || [ -z "$sha" ]; then
    printf 'CI run %s could not be read in %s — no such run there, or GitHub gave no answer\n' "$id" "$REPO_SLUG"; return 2
  fi
  st=$(jq -r '.status // "?"' <<<"$j"); con=$(jq -r '.conclusion // "none"' <<<"$j")
  if [ "$st" != completed ] || [ "$con" != success ]; then
    printf 'CI run %s is not green: status %s, conclusion %s\n' "$id" "$st" "$con"; return 2
  fi
  if [ "$sha" != "$head" ]; then
    printf "CI run %s concluded success on %s, not on the branch's head %s\n" "$id" "$(printf '%s' "$sha" | cut -c1-8)" "$(printf '%s' "$head" | cut -c1-8)"
    return 2
  fi
  printf 'no code changed since %s; CI run %s concluded success on the head %s\n' \
    "$(printf '%s' "$before" | cut -c1-8)" "$id" "$(printf '%s' "$head" | cut -c1-8)"
  return 0
}

# driver_prove_trunk_merge <repo> <head-the-task-started-from> <head-after-it> <merge-commit>
#
# THE PROOF FOR A TASK THAT ONLY MERGES THE TRUNK INTO THE BRANCH. The trunk's commits
# were proved where they landed, so there is no red to show: what is checked is that
# the commit is that merge and nothing more.
#
# 0 a clean trunk merge, made by this task and its only commit · 1 not a merge of the
# trunk, or its tree is not the clean merge result · 2 the merge predates the task, or
# the task changed something besides it · 3 the claim cannot be checked
driver_prove_trunk_merge() {
  local repo="$1" before="$2" after="$3" m="$4" sha p1 p2 r ontrunk="" tree mrc=0 got s8
  sha=$(git -C "$repo" rev-parse --verify -q "$m^{commit}" 2>/dev/null) || { printf "trunkMerge.commit '%s' is not a commit here\n" "$m"; return 3; }
  s8=$(printf '%s' "$sha" | cut -c1-8)
  [ -n "$before" ] && [ -n "$after" ] || { printf 'the head around this task was not recorded, so its commits could not be measured\n'; return 3; }
  p1=$(git -C "$repo" rev-parse --verify -q "$sha^1" 2>/dev/null); p2=$(git -C "$repo" rev-parse --verify -q "$sha^2" 2>/dev/null)
  if [ -z "$p2" ] || git -C "$repo" rev-parse --verify -q "$sha^3" >/dev/null 2>&1; then
    printf '%s is not a merge of two commits — a change is proved with testFirst or testOnly\n' "$s8"; return 1
  fi
  for r in "origin/${INTEGRATION_BRANCH:-develop}" "${INTEGRATION_BRANCH:-develop}"; do
    git -C "$repo" merge-base --is-ancestor "$p2" "$r" 2>/dev/null && { ontrunk=1; break; }
  done
  [ -n "$ontrunk" ] || { printf "%s merges %s, which is not on the trunk (%s)\n" "$s8" "$(printf '%s' "$p2" | cut -c1-8)" "${INTEGRATION_BRANCH:-develop}"; return 1; }
  # The merge git makes by itself, with no hand: a conflict or any other tree is an edit.
  tree=$(git -C "$repo" merge-tree --write-tree "$p1" "$p2" 2>/dev/null) || mrc=$?
  tree=$(printf '%s\n' "$tree" | head -1)
  if [ "$mrc" -eq 1 ]; then
    printf '%s merged the trunk with conflicts, so its resolution is a change by hand — prove it with testFirst or testOnly\n' "$s8"; return 1
  fi
  if [ "$mrc" -ne 0 ] || ! git -C "$repo" cat-file -e "$tree^{tree}" 2>/dev/null; then
    printf 'the clean merge of %s could not be computed here (git merge-tree exit %s)\n' "$s8" "$mrc"; return 3
  fi
  got=$(git -C "$repo" rev-parse --verify -q "$sha^{tree}" 2>/dev/null)
  if [ "$got" != "$tree" ]; then
    printf '%s is a trunk merge that carries edits beyond the clean merge (%s) — prove them with testFirst or testOnly\n' \
      "$s8" "$(git -C "$repo" diff --name-only "$tree" "$got" 2>/dev/null | head -3 | tr '\n' ' ' | sed 's/ $//')"
    return 1
  fi
  # The task made it: a merge already on the branch when the task started proves nothing done.
  if git -C "$repo" merge-base --is-ancestor "$sha" "$before" 2>/dev/null; then
    printf '%s was on the branch before this task started (at %s) — a task is proved by the merge it makes, never one it finds\n' \
      "$s8" "$(printf '%s' "$before" | cut -c1-8)"
    return 2
  fi
  # And it is all the task did.
  if [ "$after" != "$sha" ] || [ "$p1" != "$before" ]; then
    printf 'the task committed more than the trunk merge %s (%s) — a change is proved with testFirst or testOnly\n' \
      "$s8" "$(git -C "$repo" log --first-parent --no-merges --format=%h "$before..$after" 2>/dev/null | head -3 | tr '\n' ' ' | sed 's/ $//')"
    return 2
  fi
  if ! git -C "$repo" diff --quiet HEAD -- 2>/dev/null; then
    printf 'the task left uncommitted edits beside the trunk merge %s (%s)\n' "$s8" \
      "$(git -C "$repo" diff --name-only HEAD -- 2>/dev/null | head -3 | tr '\n' ' ' | sed 's/ $//')"
    return 2
  fi
  printf 'a trunk merge and nothing more: %s merges %s cleanly\n' "$s8" "$(printf '%s' "$p2" | cut -c1-8)"
  return 0
}

# _driver_build_task_start <file> <plan-task> <repo> — the head this task first started
# from, kept across its tries and a resume until it is proved. A retry measured from its
# own start would not see what an earlier try of the same task committed.
_driver_build_task_start() {
  local f="$1" task="$2" repo="$3" h
  h=$(jq -r --argjson task "$task" 'select(.task == $task) | .head // empty' "$f" 2>/dev/null)
  if [ -n "$h" ] && git -C "$repo" merge-base --is-ancestor "$h" HEAD 2>/dev/null; then printf '%s' "$h"; return 0; fi
  h=$(git -C "$repo" rev-parse --verify -q HEAD 2>/dev/null) || return 1
  jq -n --argjson task "$task" --arg h "$h" '{task: $task, head: $h}' > "$f" 2>/dev/null
  printf '%s' "$h"
}

driver_step_build() { # <ticket>
  local t="${1:?driver_step_build: need a ticket}"
  local repo tries rc ntasks bad task slot ans tfile tcmd tsha isha bfile why prc
  local want_task got_task pair seen_pairs="" seen_titles="" same merged=0 whole before after nocode=0 nmerge=0
  export DRIVER_TICKET="$t"
  whole=$(driver_state_get "$t" build_whole)
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
  # Sequential, never parallel: each task is a fresh session of its own, followed by the
  # review step. The driver never starts several agents on one ticket.
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
    driver_fact_put "$t" "$slot" PLAN_TASK "$(_driver_build_task_fact "$t" "$task" "$whole")"
    # What the driver said about the last try at this task, so a retry is not blind.
    if [ -s "$(driver_state_dir "$t")/steps/$slot.refused" ]; then
      driver_fact_put "$t" "$slot" LAST_TRY "$(cat "$(driver_state_dir "$t")/steps/$slot.refused")"
    else
      driver_fact_put "$t" "$slot" LAST_TRY "$(_driver_fact_none "this is the first try at this task, or the last one was proved")"
    fi
    # The head this task started from: what a noCode or trunkMerge answer is measured against.
    before=$(_driver_build_task_start "$(driver_state_dir "$t")/steps/$slot.started" "$task" "$repo")
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
    # Before the proof reads the branch: a task that left HEAD detached put its commits there.
    driver_heal_detached "$t" "$repo" "$(driver_state_get "$t" branch)" || true
    driver_git_actions "$t" "$repo" "$ans" "build $slot" || return "$DRIVER_E_REFUSED"
    # The task's own last commit, before the driver's formatting adds one.
    after=$(git -C "$repo" rev-parse --verify -q HEAD 2>/dev/null)
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
    # A TASK THAT CHANGES NO CODE has no commit to prove: no diff, and a green run on the head.
    if jq -e '.noCode | type == "object"' "$ans" >/dev/null 2>&1; then
      why=""; prc=0
      why=$(driver_prove_no_code "$repo" "$before" "$(jq -r '.noCode.run // ""' "$ans")") || prc=$?
      if [ "$prc" -eq 0 ]; then
        tsha=$(git -C "$repo" rev-parse --verify -q HEAD 2>/dev/null)
        rm -f "$(driver_state_dir "$t")/steps/$slot.refused" "$proved.proof" "$(driver_state_dir "$t")/steps/$slot.started"
        _driver_build_mark_proved "$proved" "$task" "$ans" "nocode:$tsha" "${got_task:-$want_task}" false "$tsha"
        nocode=$((nocode+1))
        driver_say "   build $(jq -r '.task // "?"' "$ans") — $why"
      else
        printf '%s\n' "$why" > "$(driver_state_dir "$t")/steps/$slot.refused"
        driver_say "✋ build $(jq -r '.task // "?"' "$ans") — $why"
        bad=1
      fi
      continue
    fi
    # A TASK THAT ONLY MERGES THE TRUNK changes nothing of its own: the commit is checked, not a test.
    if jq -e '.trunkMerge | type == "object"' "$ans" >/dev/null 2>&1; then
      why=""; prc=0
      why=$(driver_prove_trunk_merge "$repo" "$before" "$after" "$(jq -r '.trunkMerge.commit // ""' "$ans")") || prc=$?
      if [ "$prc" -eq 0 ]; then
        tsha=$(git -C "$repo" rev-parse --verify -q "$(jq -r '.trunkMerge.commit' "$ans")^{commit}" 2>/dev/null)
        rm -f "$(driver_state_dir "$t")/steps/$slot.refused" "$proved.proof" "$(driver_state_dir "$t")/steps/$slot.started"
        _driver_build_mark_proved "$proved" "$task" "$ans" "merge:$tsha" "${got_task:-$want_task}" false "$tsha"
        nmerge=$((nmerge+1))
        driver_say "   build $(jq -r '.task // "?"' "$ans") — $why"
      else
        printf '%s\n' "$why" > "$(driver_state_dir "$t")/steps/$slot.refused"
        driver_say "✋ build $(jq -r '.task // "?"' "$ans") — $why"
        bad=1
      fi
      continue
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
        printf 'the answer is test-only and names no break to prove it (testOnly needs test.file, command, testCommit and break)\n' > "$(driver_state_dir "$t")/steps/$slot.refused"
        driver_say "✋ build '$(jq -r '.task // "?"' "$ans")' is test-only and names no break to prove it (testOnly needs test.file, command, testCommit and break)."
        bad=1; continue
      fi
      pair="$(git -C "$repo" rev-parse --verify -q "$tsha^{commit}" 2>/dev/null || printf '%s' "$tsha"):break:$bfile$(_driver_build_item_key "$task" "$tfile" "$whole")"
      if same=$(_driver_build_same_proof "$pair" "$seen_titles"); then
        driver_say "   build '$got_task' is proved by the same test commit and break as '$same' — one change, so the two are one task: merged, and proved once."
        _driver_build_mark_proved "$proved" "$task" "$ans" "$pair" "${got_task:-$want_task}" true "$tsha"
        merged=$((merged+1)); rm -f "$(driver_state_dir "$t")/steps/$slot.refused" "$(driver_state_dir "$t")/steps/$slot.started"; continue
      fi
      seen_pairs="$seen_pairs $pair"
      seen_titles="$seen_titles$pair	${got_task:-$want_task}
"
      why=""; prc=0; rm -f "$proved.proof"
      why=$(DRIVER_PROOF_KEEP="$proved.proof" driver_prove_by_break "$repo" "$tfile" "$tsha" "$bfile" "$(jq -r '.testOnly.break.find' "$ans")" "$(jq -r '.testOnly.break.replace' "$ans")" "$tcmd") || prc=$?
    else
    tfile=$(jq -r '.testFirst.test.file // ""' "$ans")
    tcmd=$(jq -r  '.testFirst.command // ""'   "$ans")
    tsha=$(jq -r  '.testFirst.testCommit // ""' "$ans")
    isha=$(jq -r  '.testFirst.implCommit // ""' "$ans")
    if [ -z "$tfile" ] || [ -z "$tcmd" ] || [ -z "$tsha" ] || [ -z "$isha" ]; then
      printf 'the answer names no test to prove it (testFirst needs test.file, command, testCommit and implCommit)\n' > "$(driver_state_dir "$t")/steps/$slot.refused"
      driver_say "✋ build '$(jq -r '.task // "?"' "$ans")' names no test to prove it (testFirst needs test.file, command, testCommit and implCommit)."
      bad=1; continue
    fi
    # AND ITS OWN COMMITS. A pair already proved for an earlier task proves that task
    # again, not this one — same hole as the title, reached by the other door.
    #
    # KEYED ON THE RESOLVED COMMIT, not on the string the model typed. The contract asks
    # for seven characters or more, so `a1b2c3d` and its full sha are two keys for one
    # commit — and that is a third door to the same hole.
    pair="$(git -C "$repo" rev-parse --verify -q "$tsha^{commit}" 2>/dev/null || printf '%s' "$tsha"):$(git -C "$repo" rev-parse --verify -q "$isha^{commit}" 2>/dev/null || printf '%s' "$isha")$(_driver_build_item_key "$task" "$tfile" "$whole")"
    # TWO TASKS ONE CHANGE PROVES ARE ONE TASK. Refused, the model was asked five times
    # to split a change that was rightly one, and the ticket parked on a proof that held
    # (#13584). So the later task is merged into the earlier one, said, and not re-proved.
    if same=$(_driver_build_same_proof "$pair" "$seen_titles"); then
      driver_say "   build '$got_task' is proved by the same two commits as '$same' ($(printf '%s' "$tsha" | cut -c1-8) then $(printf '%s' "$isha" | cut -c1-8)) — one change, so the two are one task: merged, and proved once."
      _driver_build_mark_proved "$proved" "$task" "$ans" "$pair" "${got_task:-$want_task}" true "$tsha" "$isha"
      merged=$((merged+1)); rm -f "$(driver_state_dir "$t")/steps/$slot.refused" "$(driver_state_dir "$t")/steps/$slot.started"; continue
    fi
    seen_pairs="$seen_pairs $pair"
    seen_titles="$seen_titles$pair	${got_task:-$want_task}
"
    why=""; prc=0; rm -f "$proved.proof"
    why=$(DRIVER_PROOF_KEEP="$proved.proof" driver_prove_red_green "$repo" "$tfile" "$tsha" "$isha" "$tcmd") || prc=$?
    fi
    if [ "$prc" -eq 0 ]; then
      rm -f "$(driver_state_dir "$t")/steps/$slot.refused" "$(driver_state_dir "$t")/steps/$slot.started"
      DRIVER_PROOF_LINE="$why" _driver_build_mark_proved "$proved" "$task" "$ans" "$pair" "${got_task:-$want_task}" false "$tsha" $isha
      rm -f "$proved.proof"
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

  # A list kept here is this ticket's to pass, whatever the record says of build_whole: a
  # rebuild from before it was set left proved items false and parked asking a person.
  if [ -n "$whole" ] || _driver_build_own_list "$t"; then _driver_build_features "$t" || bad=1; fi

  if [ "$bad" -eq 0 ]; then
    [ "$nocode" -eq 0 ] || driver_say "   build: $nocode of $ntasks task(s) changed no code — accepted on a green CI run of the head, not a test pair"
    [ "$nmerge" -eq 0 ] || driver_say "   build: $nmerge of $ntasks task(s) only merged the trunk — accepted as a clean merge, not a test pair"
    if [ "$kept" -gt 0 ]; then
      driver_say "   build: all $ntasks task(s) proved red before green — $kept kept from an earlier pass, $((ntasks - kept)) built on this one"
    elif [ "$merged" -gt 0 ]; then
      driver_say "   build: all $ntasks task(s) proved red before green, as $((ntasks - merged)) change(s) — $merged merged into the task proved by the same commits"
    else
      driver_say "   build: all $ntasks task(s) proved red before green"
    fi
    return "$DRIVER_OK"
  fi
  _driver_build_out_of_tries "$t" "$tries" "$ntasks" && return "$DRIVER_E_REFUSED"
  return "$DRIVER_E_REWORK"
}

# _driver_build_task_fact <ticket> <task> <whole> — the task as the brief reads it. A task of
# a ticket building its whole list carries its item: the session sees no ticket and no list.
_driver_build_task_fact() {
  local list; list="$(driver_state_dir "$1")/features.json"
  if [ -n "$3" ] && [ -s "$list" ] && jq -e --slurpfile l "$list" --argjson task "$2" -n \
       '$l[0].items | any(.id == $task.item)' >/dev/null 2>&1; then
    jq --slurpfile l "$list" '. + {feature: (.item as $i | $l[0].items[] | select(.id == $i) | {id, behaviour, steps, test, rule: "This item passes only when a task of it proves `test`: when this task'"'"'s tests name that file, it is your testFirst.test.file. Never edit its steps."})}' <<<"$2"
  else
    printf '%s' "$2" | jq .
  fi
}

# _driver_build_item_key <task> <test-file> <whole> — what joins a list item's proof key. Two
# tasks one change proves are merged as one, and proved once; that must not pass an item
# whose own test never ran. So the same commits naming another test file are proved again.
_driver_build_item_key() {
  [ -n "$3" ] || return 0
  case "$(jq -r '.item // ""' <<<"$1")" in F[0-9]*) printf ':%s' "$2" ;; esac
}

# _driver_build_own_list <ticket> — 0 when the ticket keeps a feature list whose items are
# built here (no item filed as a part of its own).
_driver_build_own_list() {
  local list; list="$(driver_state_dir "$1")/features.json"
  [ -s "$list" ] && jq -e '(.items | length) > 0 and all(.items[]; .part == null)' "$list" >/dev/null 2>&1
}

# _driver_build_features <ticket> — an item passes once every task of it is proved and one of
# them proved the test file its steps run in. Re-derived on each pass, kept in the list, and
# posted when the whole list first passes. 1 while any item fails: an item whose tasks are all
# proved and whose test never ran sends its last task back, naming the file.
_driver_build_features() {
  local t="$1" d list id test i m last all hit pass fails=0 before total
  d="$(driver_state_dir "$t")/steps"; list="$(driver_state_dir "$t")/features.json"
  [ -s "$list" ] || return 0
  before=$(jq -c '[.items[].passes]' "$list")
  total=$(jq '.items | length' "$list")
  for id in $(jq -r '.items[].id' "$list"); do
    test=$(jq -r --arg id "$id" '.items[] | select(.id == $id) | .test' "$list")
    last=""; all=1; hit=""
    for i in $(jq -r --arg id "$id" '.tasks | to_entries[] | select(.value.item == $id) | .key + 1' "$d/plan.json"); do
      last="$i"; m="$d/build-task-$i.proved"
      if [ ! -s "$m" ]; then all=""; continue; fi
      jq -e --arg f "$test" '((.answer.testFirst.test.file // .answer.testOnly.test.file // "") | ltrimstr("./")) == ($f | ltrimstr("./"))' "$m" >/dev/null 2>&1 && hit=1
    done
    pass=false
    if [ -n "$last" ] && [ -n "$all" ]; then
      if [ -n "$hit" ]; then pass=true
      else
        printf '%s passes only when its steps pass in %s, and no task of it proved that file: prove it in testFirst.test.file\n' "$id" "$test" > "$d/build-task-$last.refused"
        rm -f "$d/build-task-$last.proved"
        driver_say "✋ build: $(cat "$d/build-task-$last.refused")"
      fi
    fi
    [ "$pass" = true ] || fails=$((fails+1))
    feature_list_set_pass "$list" "$id" "$pass" > "$list.tmp" && mv "$list.tmp" "$list"
  done
  if [ "$fails" -gt 0 ]; then
    driver_say "   build: $((total - fails)) of $total feature list item(s) pass"
    return 1
  fi
  driver_say "   build: all $total feature list item(s) pass"
  [ "$before" = "$(jq -c '[.items[].passes]' "$list")" ] || \
    swarm_gh issue comment "$t" --repo "$REPO_SLUG" --body "$(feature_list_comment "$list")" >/dev/null 2>&1 || true
  return 0
}

# _driver_build_in <n> <list> — 0 when <n> is one of the space-separated <list>.
_driver_build_in() { case " $2 " in *" $1 "*) return 0 ;; esac; return 1; }

# _driver_build_mark_proved <marker> <plan-task> <answer> <pair> <title> <merged> <sha…>
# — what a later pass needs to keep this task without building it again: the plan
# entry it was proved against, the answer, and the commits that have to stay on the branch.
_driver_build_mark_proved() {
  local m="$1" task="$2" ans="$3" pair="$4" title="$5" merged="$6" proof="null"; shift 6
  # The command the driver ran and what each half printed (_driver_proof_keep), for ship.
  [ ! -s "$m.proof" ] || proof=$(jq -c --arg l "${DRIVER_PROOF_LINE:-}" '. + {line: $l}' "$m.proof" 2>/dev/null) || proof="null"
  jq -n --argjson task "$task" --slurpfile a "$ans" --arg pair "$pair" --arg title "$title" \
    --argjson merged "$merged" --argjson proof "${proof:-null}" --args \
    '{task: $task, answer: $a[0], pair: $pair, title: $title, merged: $merged, proof: $proof,
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
# The park note names each unproved task and its last refusal: the .refused files stay on
# the building machine, which the PM host may not reach.
_driver_build_out_of_tries() {
  [ "$2" -ge "$DRIVER_MAX_BUILD_TRIES" ] || return 1
  local d i=0 title why reasons="" line
  d="$(driver_state_dir "$1")/steps"
  while [ "$i" -lt "${3:-0}" ]; do
    i=$((i+1))
    [ -s "$d/build-task-$i.refused" ] && [ ! -s "$d/build-task-$i.proved" ] || continue
    title=$(jq -r --argjson i "$((i-1))" '.tasks[$i].title // empty' "$d/plan.json" 2>/dev/null)
    why=$(tr '\n' ' ' < "$d/build-task-$i.refused" | sed 's/  */ /g; s/ $//')
    [ "${#why}" -le 300 ] || why="$(printf '%s' "$why" | cut -c1-297)..."
    reasons="$reasons; task $i (${title:-untitled}): $why"
  done
  line="$2 of $DRIVER_MAX_BUILD_TRIES tries used and the tests still do not prove the change"
  [ -z "$reasons" ] || line="$line. Last refusal per unproved task${reasons#;}"
  driver_say "✋ build: $line. Parking."
  driver_state_set "$1" park_note "$line"
  return 0
}
