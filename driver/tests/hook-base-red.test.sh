#!/usr/bin/env bash
# hook-base-red.test.sh — whatever a builder's local hooks enforce, the base-health check
# enforces too. The project's commit hook runs a lint-staged check (check:drift) the trunk
# is not held to, and the trunk fails it on a file no ticket touched. The coordinator's
# sweep runs every check the hooks run on the trunk head and notes the red for ONE
# develop-red ticket before any builder meets it; a suite's red is named by the checks its
# "N of M failed" line names. A step that asks about that hook red is read, not taken at
# its word: red on the trunk too, and naming no file of the ticket's when run in its tree,
# it takes standard answer (g) and is never put to a person; naming a file of the
# ticket's, or green on the trunk, it parks, whatever kind the step gave or files the words
# name. A change the hook refused on that proven red is committed by the driver past that
# check only (the owner, 26 Oct): every other hook check still runs and can still refuse
# it; the ticket's own red is still refused; a proof from an earlier tree or parent covers
# nothing (in the driver, and in the project's copy of templates/hook-skip.sh). Planted
# below: the classifying line, the own-file read, the driver's commit, its stale-proof
# check and the wrapper's tree check, each deleted, and the case it guards goes wrong.
# Run: bash "$0"   ·   SUT_KIT=<another kit checkout> bash "$0" runs the cases against it.
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/tests/lib/suite.sh" || exit 1
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/fixture.sh"
driver_fixture; on_exit_keep_status 'rm -rf "$FIX"'
mkdir -p "$FIX/tmp"; export TMPDIR="$FIX/tmp" HARNESS_RELEASE_FETCH_SECS=0
. "$HERE/../state.sh" || exit 1
ROOT="$(cd "$HERE/../.." && pwd)"
KIT="${SUT_KIT:-$ROOT}"
mkdir -p "$STATE/swarm"
PENDING="$STATE/swarm/develop-red.tsv"

# The classifier stands in for the model: it answers park, so only a mechanical verdict passes.
printf '#!/usr/bin/env bash\ncat >/dev/null; echo park\n' > "$BIN/sa-claude"; chmod +x "$BIN/sa-claude"
export DRIVER_SA_CLAUDE="$BIN/sa-claude"
# npm [--silent] run <script> [args…], from the tree's package.json.
cat > "$BIN/npm" <<'SH'
#!/usr/bin/env bash
a=(); for x in "$@"; do case "$x" in --silent|-s|run) ;; *) a+=("$x") ;; esac; done
s=$(jq -r --arg n "${a[0]:-}" '.scripts[$n] // empty' package.json 2>/dev/null); [ -n "$s" ] || exit 127
eval "$s ${a[*]:1}"
SH
chmod +x "$BIN/npm"

# ---- the project: a commit hook running lint-staged, a push hook running a suite ----
mkdir -p "$REPO/.husky" "$REPO/scripts" "$REPO/ui"
printf 'npx lint-staged\n' > "$REPO/.husky/pre-commit"
printf '# the push suite\nnpm run --silent check:push\n' > "$REPO/.husky/pre-push"
cat > "$REPO/package.json" <<'JSON'
{ "name": "widgets",
  "scripts": { "check:drift": "sh scripts/drift.sh", "check:push": "sh scripts/push.sh", "check:roles": "sh scripts/roles.sh" },
  "lint-staged": { "ui/*.tsx": ["sh scripts/drift.sh --"] } }
JSON
# Every ui file needs a catalog line, whatever files it is handed.
cat > "$REPO/scripts/drift.sh" <<'SH'
rc=0; for f in ui/*.tsx; do [ -e "$f" ] || continue; n=$(basename "$f" .tsx)
  grep -qx "$n" catalog.txt 2>/dev/null || { echo "✗ $f has no catalog entry"; rc=1; }; done; exit $rc
SH
printf '[ -f roles-red ] && { echo "✗ roles"; exit 1; }; exit 0\n' > "$REPO/scripts/roles.sh"
printf 'sh scripts/roles.sh >/dev/null 2>&1 || { echo "✗ push — 1 of 2 failed: check:roles"; exit 1; }; exit 0\n' > "$REPO/scripts/push.sh"
# The project's copy of the kit's wrapper, and a second commit-hook check that always runs:
# it logs each run and refuses a staged file carrying BADSTYLE.
cp "$KIT/templates/hook-skip.sh" "$REPO/scripts/hook-skip.sh" 2>/dev/null
cat > "$REPO/scripts/style.sh" <<'SH'
echo ran >> "$(git rev-parse --path-format=absolute --git-common-dir)/style.log"
for f in $(git diff --cached --name-only); do grep -q BADSTYLE "$f" 2>/dev/null && { echo "✗ style: $f"; exit 1; }; done; exit 0
SH
printf 'export const Leads = 1\n' > "$REPO/ui/Leads.tsx"; : > "$REPO/catalog.txt"
git -C "$REPO" add -A; git -C "$REPO" commit -qm "chore: the project"
git init -q --bare "$FIX/origin"; git -C "$REPO" remote add origin "$FIX/origin"; git -C "$REPO" push -q origin develop

CFG0="$HARNESS_CFG_PATH"
jq '.release = {mergeFirst: true, done: false}' "$CFG0" > "$FIX/cfg.json"
export HARNESS_CFG="$FIX/cfg.json" HARNESS_CFG_PATH="$FIX/cfg.json"

trunk() { # <catalog line|-> [roles-red] — the trunk's catalog, and whether its roles check is red
  git -C "$REPO" checkout -q develop
  if [ "$1" = - ]; then : > "$REPO/catalog.txt"; else printf '%s\n' "$1" > "$REPO/catalog.txt"; fi
  rm -f "$REPO/roles-red"; [ -z "${2:-}" ] || : > "$REPO/roles-red"
  git -C "$REPO" add -A; git -C "$REPO" commit -qm "trunk: $*" --allow-empty; git -C "$REPO" push -q origin develop
  SHA=$(git -C "$REPO" rev-parse develop)
}
ticket() { # <n> <ui-file> <catalog line|-> — a branch that adds a ui file, its commit refused (left staged)
  git -C "$REPO" worktree add -q "$FIX/t$1" -b "tkt-$1/work" origin/develop
  printf 'export const X = 1\n' > "$FIX/t$1/ui/$2"
  [ "$3" = - ] || printf '%s\n' "$3" >> "$FIX/t$1/catalog.txt"
  git -C "$FIX/t$1" add -A
  driver_state_init "$1" --worktree "$FIX/t$1" --branch "tkt-$1/work" >/dev/null
}
# cls <ticket> <question> [kind] [kit] — the standard answer the kit's driver gives, or park.
cls() {
  bash -c 'unset DRIVER_DIR DRIVER_HOME KIT_ROOT HARNESS_KIT_ROOT
    . "$1/driver/driver-env.sh" && . "$1/driver/ai-step.sh" || exit 9
    if driver_standard_answer "$2" build "$3" "$4" >/dev/null 2>&1; then printf "%s %s" "$SA_CLASS" "$SA_ACTION"; else printf park; fi' \
    _ "${4:-$KIT}" "$1" "$2" "${3:-}" 2>/dev/null
}
reset() { : > "$PENDING"; rm -f "$STATE/swarm/base-checks.tsv" "$STATE/swarm/develop-hook-swept.tsv"; }

# What builders asked, in their words: the hook named, the check named, the file named.
QBASE="The pre-commit hook (lint-staged) refused the commit: check:drift says ✗ ui/Leads.tsx has no catalog entry. This ticket never touched ui/Leads.tsx. Commit with --no-verify, or wait?"
QOWN="The pre-commit hook (lint-staged) refused the commit: check:drift says ✗ ui/Own.tsx has no catalog entry. Commit with --no-verify, or wait?"
QBOTH="I staged ui/Card.tsx and its catalog line; the pre-commit hook's check:drift refused the commit on ui/Leads.tsx, which this ticket never touched. Wait, or --no-verify?"

echo "--- the hooks' checks are read from the project, or from gates.hookChecks ---"
got=$(bash -c 'unset DRIVER_DIR DRIVER_HOME KIT_ROOT HARNESS_KIT_ROOT; . "$1/driver/driver-env.sh" && . "$1/driver/hook-checks.sh" && driver_hook_checks "$2" "$3"' _ "$KIT" "$REPO" develop 2>/dev/null | sort | paste -sd, -)
want "the push hook's script and the lint-staged command that is a script's body" "check:drift,check:push" "$got"
jq '.gates.hookChecks = ["check:roles"]' "$FIX/cfg.json" > "$FIX/cfg-list.json"
got=$(HARNESS_CFG="$FIX/cfg-list.json" HARNESS_CFG_PATH="$FIX/cfg-list.json" bash -c 'unset DRIVER_DIR DRIVER_HOME KIT_ROOT HARNESS_KIT_ROOT; . "$1/driver/driver-env.sh" && . "$1/driver/hook-checks.sh" && driver_hook_checks "$2"' _ "$KIT" "$REPO" 2>/dev/null | paste -sd, -)
want "gates.hookChecks names them instead"  "check:roles" "$got"
jq '.gates.hookChecks = false' "$FIX/cfg.json" > "$FIX/cfg-off.json"
got=$(HARNESS_CFG="$FIX/cfg-off.json" HARNESS_CFG_PATH="$FIX/cfg-off.json" bash -c 'unset DRIVER_DIR DRIVER_HOME KIT_ROOT HARNESS_KIT_ROOT; . "$1/driver/driver-env.sh" && . "$1/driver/hook-checks.sh" && driver_hook_checks "$2"' _ "$KIT" "$REPO" 2>/dev/null | paste -sd, -)
want "and false is none"                    "" "$got"

echo "--- the sweep: every hook check on the trunk head, a red noted before any builder meets it ---"
reset; trunk - roles-red; S7=$(printf '%s' "$SHA" | cut -c1-7)
out=$(bash "$KIT/scripts/develop-hook-red.sh" sweep "$SHA" 2>&1); rc=$?
want "the sweep runs"                       "0" "$rc"
want_in "and says what is red"              "develop@$S7 is red on check:drift, check:roles" "$out"
want "one row: the lint-staged check, and the suite's red by the check it names" \
     "$SHA	check:drift,check:roles	" "$(cut -f1-3 "$PENDING" 2>/dev/null)"
bash "$KIT/scripts/develop-hook-red.sh" sweep "$SHA" >/dev/null 2>&1
want "a commit is swept once"               "1" "$(awk 'NF' "$PENDING" | wc -l | tr -d ' ')"
want "start finds nothing left to start"    "" "$(bash "$KIT/scripts/develop-hook-red.sh" start 2>&1)"
cat > "$FIX/fgh" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *"-X GET search/issues"*) echo '{"total_count":0,"items":[]}'; exit 0 ;;
  *"repos/acme/widgets/issues -X POST"*) printf '%s\0' "$@" > "$FIX/fgh.create"; echo 931; exit 0 ;;
esac
exit 0
SH
chmod +x "$FIX/fgh"
DEVELOP_RED_GH="$FIX/fgh" SWARM_GH="$FIX/fgh" DEVELOP_RED_QUEUE=off bash "$KIT/scripts/develop-red.sh" file >/dev/null 2>&1
want_in "develop-red files ONE ticket for it" "develop is red: check:drift, check:roles \(develop@$S7\)" "$(tr '\0' '\n' < "$FIX/fgh.create" 2>/dev/null)"
want_in "found by the sweep, no builder yet"  "No builder has hit it yet." "$(tr '\0' '\n' < "$FIX/fgh.create" 2>/dev/null)"
reset; trunk Leads
bash "$KIT/scripts/develop-hook-red.sh" sweep "$SHA" >/dev/null 2>&1
want "a green trunk notes nothing"          "0" "$(awk 'NF' "$PENDING" | wc -l | tr -d ' ')"
want "and is swept green"                   "green" "$(awk -F'\t' -v s="$SHA" '$1 == s { print $3 }' "$STATE/swarm/develop-hook-swept.tsv")"

echo "--- a hook red on a file the trunk brought: base-red, standard answer (g), never a question ---"
reset; trunk -
ticket 801 Card.tsx Card
want "the hook's red on ui/Leads.tsx, red on the trunk too: (g)"   "g commit-carry" "$(cls 801 "$QBASE" other)"
want "noted for the develop-red ticket"     "$SHA	check:drift	801" "$(cut -f1-3 "$PENDING" 2>/dev/null)"
want "and with no kind given, the same"     "g commit-carry" "$(cls 801 "$QBASE")"
want "naming the ticket's own staged file beside it, the same" "g commit-carry" "$(cls 801 "$QBOTH" other)"

echo "--- a hook red on the ticket's own file still blocks, even while the trunk is red too ---"
reset; trunk -
ticket 802 Own.tsx -
want "ui/Own.tsx is this ticket's: it parks"            "park" "$(cls 802 "$QOWN" other)"
want "even when the step calls it base-red"             "park" "$(cls 802 "$QOWN" base-red)"
want "nothing noted for the develop-red ticket"         "0" "$(awk 'NF' "$PENDING" | wc -l | tr -d ' ')"
want "and when the words name only the trunk's file, the run still finds the ticket's" \
     "park" "$(cls 802 "$QBASE" base-red)"

echo "--- a check green on the trunk is the ticket's, whatever file it names ---"
reset; trunk Leads
ticket 803 Card.tsx Card
want "check:drift is green on the trunk: it parks"      "park" "$(cls 803 "$QBASE" base-red)"

echo "--- the commit hook: past a proven base-red check only, every other check run, never on another tree ---"
HOOKF="$(git -C "$REPO" rev-parse --path-format=absolute --git-common-dir)/hooks/pre-commit"
STYLE_LOG="$(dirname "$HOOKF")/../style.log"
hook_with() { # <wrapper path> — the project's commit hook: drift through the wrapper, then style
  printf '#!/bin/sh\nsh %s check:drift sh scripts/drift.sh || exit 1\nsh scripts/style.sh || exit 1\n' "$1" > "$HOOKF"; chmod +x "$HOOKF"
}
# commit_as <ticket> <question> [kit] [between] — the standard answer, then the driver's commit
# from it; <between> runs in the tree after the proof and before the commit. Prints
# "<class> <action> rc=<commit rc>".
commit_as() {
  bash -c 'unset DRIVER_DIR DRIVER_HOME KIT_ROOT HARNESS_KIT_ROOT
    . "$1/driver/driver-env.sh" && . "$1/driver/ai-step.sh" || exit 9
    driver_standard_answer "$2" build "$3" other >/dev/null 2>&1 || { printf park; exit 0; }
    [ -z "$4" ] || ( cd "$(driver_state_get "$2" worktree)" && eval "$4" )
    rc=0; _driver_sa_commit "$2" build >/dev/null 2>&1 || rc=$?
    printf "%s %s rc=%s" "$SA_CLASS" "$SA_ACTION" "$rc"' _ "${3:-$KIT}" "$1" "$2" "${4:-}" 2>/dev/null
}
heads() { git -C "$FIX/t$1" rev-parse HEAD; }
reset; trunk -; hook_with scripts/hook-skip.sh; : > "$STYLE_LOG"
want "the hook refuses a plain commit on the trunk's red" "1" "$( (cd "$REPO" && git commit -q --allow-empty -m probe >/dev/null 2>&1); echo $? )"
ticket 811 Card.tsx Card; h0=$(heads 811)
want "a proven base-red: the driver commits past it"  "g commit-carry rc=0" "$(commit_as 811 "$QBASE")"
want "the commit landed"                              "moved" "$([ "$(heads 811)" != "$h0" ] && echo moved || echo same)"
want_in "saying what it went past"                    "past base-red check:drift" "$(git -C "$FIX/t811" log -1 --format=%s)"
want "and the other hook check still ran"             "1" "$(grep -c ran "$STYLE_LOG" 2>/dev/null)"
want "nothing left uncommitted"                       "" "$(git -C "$FIX/t811" status --porcelain -- . ':!node_modules')"
ticket 812 Card.tsx Card; printf 'BADSTYLE\n' > "$FIX/t812/notes.txt"; git -C "$FIX/t812" add notes.txt; h0=$(heads 812)
want "the other check red: still refused"             "g commit-carry rc=1" "$(commit_as 812 "$QBASE")"
want "nothing committed"                              "same" "$([ "$(heads 812)" != "$h0" ] && echo moved || echo same)"
ticket 813 Own.tsx -; h0=$(heads 813)
want "the ticket's own red: no answer, no commit"     "park" "$(commit_as 813 "$QOWN")"
want "and its own commit is still refused"            "1 same" "$( (cd "$FIX/t813" && git commit -q -m own >/dev/null 2>&1); echo "$? $([ "$(heads 813)" != "$h0" ] && echo moved || echo same)" )"
ticket 814 Card.tsx Card; h0=$(heads 814)
want "a proof from an earlier tree: refused"          "g commit-carry rc=1" "$(commit_as 814 "$QBASE" "" 'printf "later\n" > later.txt')"
want "nothing committed on the stale proof"           "same" "$([ "$(heads 814)" != "$h0" ] && echo moved || echo same)"
# The hook's own half: the skip names a tree, a parent and checks, and holds for nothing else.
ticket 815 Card.tsx Card; T815=$(git -C "$FIX/t815" write-tree); H815=$(heads 815)
skip_commit() { # <checks> <tree> <head> — a commit of 815's tree under that skip; its exit
  (cd "$FIX/t815" && HARNESS_HOOK_SKIP_CHECKS="$1" HARNESS_HOOK_SKIP_TREE="$2" HARNESS_HOOK_SKIP_HEAD="$3" git commit -q -m skip >/dev/null 2>&1); echo $?
}
printf 'later\n' > "$FIX/t815/later.txt"; git -C "$FIX/t815" add later.txt
want "the hook: a skip for an earlier tree is refused" "1" "$(skip_commit check:drift "$T815" "$H815")"
T815=$(git -C "$FIX/t815" write-tree)
want "the hook: a skip naming another check is refused" "1" "$(skip_commit check:other "$T815" "$H815")"
want "the hook: a skip on another parent is refused"  "1" "$(skip_commit check:drift "$T815" "$(git -C "$REPO" rev-parse develop~1)")"
want "the hook: the exact tree, parent and check go through" "0" "$(skip_commit check:drift "$T815" "$H815")"
want "the hook: the next commit carries no skip"      "1" "$(printf 'x\n' > "$FIX/t815/next.txt"; git -C "$FIX/t815" add next.txt; skip_commit check:drift "$T815" "$H815")"
rm -f "$HOOKF"

echo "--- planted: the classifying line deleted, the base-red case parks again ---"
if [ -z "${SUT_KIT:-}" ]; then
  PL="$FIX/planted-kit"; mkdir -p "$PL"; cp -R "$ROOT/." "$PL/"; rm -rf "$PL/.git"
  before=$(grep -c 'driver_hook_base_red "\$t"' "$PL/driver/standard-answer.sh")
  sed -i.bak '/driver_hook_base_red "\$t"/d' "$PL/driver/standard-answer.sh"
  want "the plant removed the line"         "1 0" "$before $(grep -c 'driver_hook_base_red "\$t"' "$PL/driver/standard-answer.sh")"
  reset; trunk -
  want "planted (no hook verdict): the base-red question parks" "park" "$(cls 801 "$QBASE" other "$PL")"
  want "planted (no hook verdict): the own file asked as base-red is taken as (g)" "g carry" "$(cls 802 "$QOWN" base-red "$PL")"
  # The other half: the run in the ticket's tree no longer reads the ticket's files.
  cp "$ROOT/driver/standard-answer.sh" "$PL/driver/standard-answer.sh"
  before=$(grep -c 'if grep -qF -- "\$f" "\$out"' "$PL/driver/hook-checks.sh")
  sed -i.bak 's/if grep -qF -- "\$f" "\$out"/if false/' "$PL/driver/hook-checks.sh"
  want "the second plant removed the own-file read" "1 0" "$before $(grep -c 'if grep -qF -- "\$f" "\$out"' "$PL/driver/hook-checks.sh")"
  reset; trunk -
  want "planted (no own-file read): the ticket's own red is taken as the trunk's" "g commit-carry" "$(cls 802 "$QBASE" other "$PL")"
  cp "$ROOT/driver/hook-checks.sh" "$PL/driver/hook-checks.sh"

  # The commit past a base-red, planted out three ways.
  reset; trunk -; hook_with scripts/hook-skip.sh
  before=$(grep -c 'SA_ACTION=commit-carry; SA_HOOK_SKIP=' "$PL/driver/standard-answer.sh")
  sed -i.bak '/SA_ACTION=commit-carry; SA_HOOK_SKIP=/d' "$PL/driver/standard-answer.sh"
  want "the third plant removed the driver's commit" "1 0" "$before $(grep -c 'SA_ACTION=commit-carry; SA_HOOK_SKIP=' "$PL/driver/standard-answer.sh")"
  ticket 821 Card.tsx Card; h0=$(heads 821)
  commit_as 821 "$QBASE" "$PL" >/dev/null
  want "planted (no driver commit): the proven base-red change stays uncommitted" "same" "$([ "$(heads 821)" != "$h0" ] && echo moved || echo same)"
  cp "$ROOT/driver/standard-answer.sh" "$PL/driver/standard-answer.sh"

  before=$(grep -c '\[ "\$tree" != "\$ptree" \] || \[ "\$head" != "\$phead" \]' "$PL/driver/hook-checks.sh")
  sed -i.bak 's/\[ "\$tree" != "\$ptree" \] || \[ "\$head" != "\$phead" \]/false/' "$PL/driver/hook-checks.sh"
  want "the fourth plant removed the driver's stale-proof check" "1 0" "$before $(grep -c '\[ "\$tree" != "\$ptree" \] || \[ "\$head" != "\$phead" \]' "$PL/driver/hook-checks.sh")"
  ticket 822 Card.tsx Card; h0=$(heads 822)
  commit_as 822 "$QBASE" "$PL" 'printf "later\n" > later.txt' >/dev/null
  want "planted (no stale-proof check): a later tree is committed on an earlier proof" "moved" "$([ "$(heads 822)" != "$h0" ] && echo moved || echo same)"
  cp "$ROOT/driver/hook-checks.sh" "$PL/driver/hook-checks.sh"

  cp "$ROOT/templates/hook-skip.sh" "$FIX/planted-skip.sh"
  before=$(grep -c '\[ "\$tree" = "\$HARNESS_HOOK_SKIP_TREE" \] && ' "$FIX/planted-skip.sh")
  sed -i.bak 's/\[ "\$tree" = "\$HARNESS_HOOK_SKIP_TREE" \] && //' "$FIX/planted-skip.sh"
  want "the fifth plant removed the hook's tree check" "1 0" "$before $(grep -c '\[ "\$tree" = "\$HARNESS_HOOK_SKIP_TREE" \] && ' "$FIX/planted-skip.sh")"
  hook_with "$FIX/planted-skip.sh"
  ticket 823 Card.tsx Card; T823=$(git -C "$FIX/t823" write-tree); H823=$(heads 823)
  printf 'later\n' > "$FIX/t823/later.txt"; git -C "$FIX/t823" add later.txt
  want "planted (no tree check in the hook): a skip for an earlier tree goes through" "0" \
       "$( (cd "$FIX/t823" && HARNESS_HOOK_SKIP_CHECKS=check:drift HARNESS_HOOK_SKIP_TREE="$T823" HARNESS_HOOK_SKIP_HEAD="$H823" git commit -q -m skip >/dev/null 2>&1); echo $? )"
  rm -f "$HOOKF"
fi

suite_end "$FAILED"
