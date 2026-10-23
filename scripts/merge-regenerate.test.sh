#!/usr/bin/env bash
# merge-regenerate.test.sh — a generated tally file that clashes in a merge is recounted
# from the merged tree, with no model and no repair (merge.regenerate). A path with no
# command, and a command that fails, keep git's own conflict.
# Run: bash "$0"
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/tests/lib/suite.sh" || exit 1
for v in $(env | sed -n 's/^\(GIT_[A-Z_]*\)=.*/\1/p'); do unset "$v"; done
# The library commits a merge it finished: a runner with no git identity must still have one.
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@invalid
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/merge-regenerate.sh"
FIX=$(mktemp -d); on_exit_keep_status 'rm -rf "$FIX"'

FAILED=0
ok()   { printf 'OK       %s\n' "$1"; }
bad()  { printf 'MISMATCH %s\n' "$1"; FAILED=1; }
want() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 — wanted '$2', got '$3'"; fi; }
want_in() { if printf '%s' "$3" | grep -qE -- "$2"; then ok "$1"; else bad "$1 — no /$2/ in: $3"; fi; }
want_not_in() { if printf '%s' "$3" | grep -qE -- "$2"; then bad "$1 — found /$2/ in: $3"; else ok "$1"; fi; }
G() { git -C "$R" -c user.email=t@invalid -c user.name=t -c commit.gpgsign=false "$@"; }

# world <command> [other clashes too: 1] — tally.json lists every line of src-*.txt,
# sorted. The branch adds "alpha" to src-a.txt and the trunk "beta" to src-b.txt, so both
# recount tally.json and it clashes; with a second argument other.json clashes as well.
world() {
  R="$FIX/r$RANDOM$RANDOM"; mkdir -p "$R"; git init -q -b develop "$R"
  jq -n --arg c "$1" '{merge: {regenerate: [{path: "tally.json", command: $c}]}}' > "$FIX/cfg.json"
  export HARNESS_CFG="$FIX/cfg.json"
  printf 'one\n' > "$R/src-a.txt"; printf 'two\n' > "$R/src-b.txt"
  cat "$R"/src-*.txt | sort > "$R/tally.json"; printf '1\n' > "$R/other.json"
  G add -A; G commit -qm base
  G checkout -qb side; printf 'alpha\n' >> "$R/src-a.txt"; cat "$R"/src-*.txt | sort > "$R/tally.json"
  [ -z "${2:-}" ] || printf '2\n' > "$R/other.json"
  G commit -qam side
  G checkout -q develop; printf 'beta\n' >> "$R/src-b.txt"; cat "$R"/src-*.txt | sort > "$R/tally.json"
  [ -z "${2:-}" ] || printf '3\n' > "$R/other.json"
  G commit -qam trunk
  G checkout -q side
  G merge -q --no-edit develop >/dev/null 2>&1
}
RECOUNT='cat src-*.txt | sort > tally.json'

echo "--- only the tally clashed: recounted on the merged tree, the merge committed ---"
world "$RECOUNT"
want_in "the merge stopped on the tally"         'tally.json' "$(G diff --name-only --diff-filter=U)"
out=$(merge_regenerate_conflicts "$R" commit); rc=$?
want "the recount succeeds"                      "0" "$rc"
want_in "  and says so"                          '^tally.json	regenerated$' "$out"
want "  the tally lists both sides"              "alpha beta one two" "$(G show HEAD:tally.json | tr '\n' ' ' | sed 's/ $//')"
want "  it is the merge commit"                  "3" "$(G rev-list --parents -1 HEAD | wc -w | tr -d ' ')"
want "  nothing is left over"                    "" "$(G status --porcelain)"

echo "--- another file clashes too: the tally is recounted and staged, the rest stays ---"
world "$RECOUNT" 1
out=$(merge_regenerate_conflicts "$R" commit); rc=$?
want_in "  the tally is recounted"               '^tally.json	regenerated$' "$out"
want "  other.json is still git's conflict"     "other.json" "$(G diff --name-only --diff-filter=U)"
want "  and the merge is not committed"          "yes" "$(G rev-parse -q --verify MERGE_HEAD >/dev/null && echo yes)"
want "  the tally is staged, recounted"          "alpha beta one two" "$(G show :tally.json | tr '\n' ' ' | sed 's/ $//')"
G merge --abort

echo "--- a command that fails keeps git's own conflict ---"
world 'exit 3'
err=$(merge_regenerate_conflicts "$R" commit 2>&1 >/dev/null); rc=$?
want "  the call fails"                          "1" "$rc"
want_in "  naming the file and its command"      'tally.json	its regenerate command failed: exit 3' "$err"
want "  tally.json is still unmerged"            "tally.json" "$(G diff --name-only --diff-filter=U)"
want_in "  with git's markers"                   '^<<<<<<< ' "$(cat "$R/tally.json")"
G merge --abort
world 'printf "<<<<<<< x\n" > tally.json'
merge_regenerate_conflicts "$R" commit >/dev/null 2>&1; rc=$?
want "a recount that leaves a marker is no recount" "1 tally.json" "$rc $(G diff --name-only --diff-filter=U)"
G merge --abort

echo "--- seed max: a ratchet that reads its baseline and refuses a rise can recount ---"
# counts.json maps each src file to its line count; "update" refuses when a count rose over
# the file it reads (as check:complexity --update does), then writes the real counts.
ratchet() {
  R="$FIX/r$RANDOM$RANDOM"; mkdir -p "$R"; git init -q -b develop "$R"
  printf 'one\n' > "$R/src-a.txt"; printf 'two\n' > "$R/src-b.txt"; printf '{"src-a.txt":1,"src-b.txt":1}\n' > "$R/counts.json"
  cat > "$R/update.sh" <<'SH'
set -e
now=$(for f in src-*.txt; do printf '{"%s":%s}\n' "$f" "$(grep -c . "$f")"; done | jq -s add)
jq -e --argjson now "$now" 'to_entries | all(.value >= ($now[.key] // 0))' counts.json >/dev/null || { echo "refused: a count rose" >&2; exit 1; }
printf '%s\n' "$now" > counts.json
SH
  G add -A; G commit -qm base
  G checkout -qb side; printf 'alpha\n' >> "$R/src-a.txt"; printf '{"src-a.txt":2,"src-b.txt":1}\n' > "$R/counts.json"; G commit -qam side
  G checkout -q develop; printf 'beta\n' >> "$R/src-b.txt"; printf '{"src-a.txt":1,"src-b.txt":2}\n' > "$R/counts.json"; G commit -qam trunk
  G checkout -q side; G merge -q --no-edit develop >/dev/null 2>&1
  jq -n --arg s "${1:-}" '{merge: {regenerate: [{path: "counts.json", command: "bash update.sh"} + (if $s == "" then {} else {seed: $s} end)]}}' > "$FIX/cfg.json"
  export HARNESS_CFG="$FIX/cfg.json"
}
ratchet max
out=$(merge_regenerate_conflicts "$R" commit); rc=$?
want "seeded with the max of both sides, the update recounts" "0" "$rc"
want "  the merged tree's real counts"            '{"src-a.txt":2,"src-b.txt":2}' "$(G show HEAD:counts.json | jq -c .)"
ratchet
merge_regenerate_conflicts "$R" commit >/dev/null 2>&1; rc=$?
want "unseeded, the update cannot read the conflicted file: git's conflict stays" "1 counts.json" "$rc $(G diff --name-only --diff-filter=U)"
G merge --abort
ratchet max; jq '.merge.regenerate[0] |= del(.command)' "$FIX/cfg.json" > "$FIX/cfg3.json"
HARNESS_CFG="$FIX/cfg3.json" merge_regenerate_conflicts "$R" commit >/dev/null 2>&1; rc=$?
want "the seed alone resolves it"                 '0 {"src-a.txt":2,"src-b.txt":2}' "$rc $(G show HEAD:counts.json | jq -c .)"

echo "--- a path the setting does not name is left alone ---"
world "$RECOUNT"; jq '.merge.regenerate[0].path = "nothing.json"' "$FIX/cfg.json" > "$FIX/cfg2.json"
out=$(HARNESS_CFG="$FIX/cfg2.json" merge_regenerate_conflicts "$R" commit); rc=$?
want "  nothing is done"                         "0 " "$rc $out"
want "  the conflict is git's"                   "tally.json" "$(G diff --name-only --diff-filter=U)"
G merge --abort
want "no merge in progress: nothing to do"       "0" "$(merge_regenerate_conflicts "$R" commit >/dev/null 2>&1; echo $?)"

suite_end "$FAILED"
