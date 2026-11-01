#!/usr/bin/env bash
# coordinator-keys.test.sh — a coordinator key that is documented or set is read by some
# code, and the removed 3/4 build, 1/4 heal split stays removed (owner call 2026-10-24:
# the open-work cap decides building vs healing). Its keys sat in a consumer's config and
# in the README for days after the cap made them dead.
# Run: bash "$0"
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/tests/lib/suite.sh" || exit 1
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; REPO="$(cd "$HERE/.." && pwd)"
CK="$HERE/coordinator-keys.sh"
TMP=$(mktemp -d); on_exit_keep_status 'rm -rf "$TMP"'
FAIL=0
ok()  { echo "  ok   $1"; }
bad() { echo "  FAIL $1"; FAIL=$((FAIL+1)); }
want() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 — wanted '$2', got '$3'"; fi; }

echo "--- the checker, on a tree of its own ---"
T="$TMP/tree"; mkdir -p "$T/scripts" "$T/docs"
cat > "$T/README.md" <<'MD'
| Key (under `coordinator`) | Default | What it is |
|---|---|---|
| `foo` | 1 | read by code |
| `bar` | 2 | named only in a comment |
| `sheet.owner` · `sheet.label` | unset | nested, read through jq |
| `baz` | 3 | named only in a doc and a test |

Not the table: `qux`.
MD
cat > "$T/scripts/a.sh" <<'SH'
FOO=$(swarm_opt coordinator.foo 1)
  # coordinator.bar is documented here but never read
OWNER=$(jq -r '.coordinator.sheet.owner' cfg.json); LABEL=$(cfg coordinator.sheet.label x)
FOOBAR=$(swarm_opt coordinator.fooBar 0)
SH
echo 'coordinator.baz' > "$T/docs/notes.txt"; echo 'swarm_opt coordinator.baz 3' > "$T/scripts/a.test.sh"
out=$(COORDINATOR_KEYS_ROOT="$T" bash "$CK" documented); rc=$?
want "documented: a key named only in a comment, a doc or a test is unread" "unread: bar
unread: baz" "$out"
want "  and it exits 1" "1" "$rc"
printf '{"coordinator":{"foo":1,"fo":2,"sheet":{"owner":"x"},"bar":2}}\n' > "$TMP/cfg.json"
out=$(COORDINATOR_KEYS_ROOT="$T" bash "$CK" config "$TMP/cfg.json"); rc=$?
want "config: a set key no code reads is unread; a prefix of a read key is not a read" "unread: bar
unread: fo" "$out"
want "  and it exits 1" "1" "$rc"
printf '{"coordinator":{"foo":1,"sheet":{}}}\n' > "$TMP/clean.json"
out=$(COORDINATOR_KEYS_ROOT="$T" bash "$CK" config "$TMP/clean.json"); rc=$?
want "config: every key read is clean" "0:" "$rc:$out"
COORDINATOR_KEYS_ROOT="$T" bash "$CK" config "$TMP/missing.json" 2>/dev/null; want "a missing config is refused, not clean" "2" "$?"
printf '| nothing |\n' > "$TMP/empty-readme"; mkdir -p "$TMP/t2"; cp "$TMP/empty-readme" "$TMP/t2/README.md"
COORDINATOR_KEYS_ROOT="$TMP/t2" bash "$CK" documented 2>/dev/null; want "a README with no coordinator table is refused, not clean" "2" "$?"

echo "--- this repo: every documented coordinator key is read ---"
out=$(bash "$CK" documented); rc=$?
want "no documented key is unread" "0:" "$rc:$out"

echo "--- a consumer config still carrying the removed keys is told which ---"
# A consumer's coordinator block as of 2026-11-01: the split's keys and the retired pace block.
cat > "$TMP/consumer.json" <<'JSON'
{"coordinator":{"cap":6,"screensFirst":true,"focusAreas":[],"releaseScopeOnly":{"on":true},
 "healAllAt":10,"healingShare":0.25,"pace":{"on":0,"weekHeadroom":1},"paceToWindow":{"on":false},
 "sheet":{"owner":"x"}}}
JSON
out=$(bash "$CK" config "$TMP/consumer.json")
want "healAllAt, healingShare and the retired pace are unread; the rest are read" "unread: healAllAt
unread: healingShare
unread: pace" "$out"

echo "--- the removed split stays removed ---"
hits=$(grep -rnIE 'healingShare|healAllAt|HEALING_SHARE|HEAL_ALL_AT|COORD_HEAL_SHARE|coord_healing_slots|coord_heal_all|heal-all' "$REPO" \
  --exclude-dir=.git --exclude-dir=reference --exclude=coordinator-keys.test.sh | sed "s|^$REPO/||")
want "no code, test or doc names the split or its keys" "" "$hits"

suite_end "$FAIL"
