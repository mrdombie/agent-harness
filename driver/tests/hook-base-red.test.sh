#!/usr/bin/env bash
# hook-base-red.test.sh — whatever a builder's local hooks enforce, the base-health check
# enforces too. The project's commit hook runs a lint-staged check (check:drift) the trunk
# is not held to, and the trunk fails it on a file no ticket touched. The coordinator's
# sweep runs every check the hooks run on the trunk head and notes the red for ONE
# develop-red ticket before any builder meets it; a suite's red is named by the checks its
# "N of M failed" line names. A step that asks about that hook red is read, not taken at
# its word: on files the trunk brought, red there too, it takes standard answer (g) and is
# never put to a person; on a file of the ticket's own, or a check green on the trunk, it
# parks, whatever kind the step gave. With the classifying line deleted, the base-red case
# parks again (planted below).
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
want "the hook's red on ui/Leads.tsx, red on the trunk too: (g)"   "g carry" "$(cls 801 "$QBASE" other)"
want "noted for the develop-red ticket"     "$SHA	check:drift	801" "$(cut -f1-3 "$PENDING" 2>/dev/null)"
want "and with no kind given, the same"     "g carry" "$(cls 801 "$QBASE")"

echo "--- a hook red on the ticket's own file still blocks, even while the trunk is red too ---"
reset; trunk -
ticket 802 Own.tsx -
want "ui/Own.tsx is this ticket's: it parks"            "park" "$(cls 802 "$QOWN" other)"
want "even when the step calls it base-red"             "park" "$(cls 802 "$QOWN" base-red)"
want "nothing noted for the develop-red ticket"         "0" "$(awk 'NF' "$PENDING" | wc -l | tr -d ' ')"

echo "--- a check green on the trunk is the ticket's, whatever file it names ---"
reset; trunk Leads
ticket 803 Card.tsx Card
want "check:drift is green on the trunk: it parks"      "park" "$(cls 803 "$QBASE" base-red)"

echo "--- planted: the classifying line deleted, the base-red case parks again ---"
if [ -z "${SUT_KIT:-}" ]; then
  PL="$FIX/planted-kit"; mkdir -p "$PL"; cp -R "$ROOT/." "$PL/"; rm -rf "$PL/.git"
  before=$(grep -c 'driver_hook_base_red "\$t"' "$PL/driver/standard-answer.sh")
  sed -i.bak '/driver_hook_base_red "\$t"/d' "$PL/driver/standard-answer.sh"
  want "the plant removed the line"         "1 0" "$before $(grep -c 'driver_hook_base_red "\$t"' "$PL/driver/standard-answer.sh")"
  reset; trunk -
  want "planted (no hook verdict): the base-red question parks" "park" "$(cls 801 "$QBASE" other "$PL")"
  want "planted (no hook verdict): the own file asked as base-red is taken as (g)" "g carry" "$(cls 802 "$QOWN" base-red "$PL")"
fi

suite_end "$FAILED"
