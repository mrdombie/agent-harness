#!/usr/bin/env bash
# test-db.test.sh — with tests.db configured, every proof half and every step that
# runs the project's tests gets its own throwaway, migrated database, dropped after.
#
# Measured: 19 of 615 proof commands carried a placeholder, several of them a
# stand-in for a database (`DATABASE_URL=<throwaway postgres with migrations
# applied>`), because a `*.db.test.ts` that is skipped without one reads green
# before the change and nothing could give the builder one.
#
# createdb and dropdb are stubs over a directory of "databases", so the suite needs
# no server and can see exactly what was created, set up, seen and dropped.
#
# Run: bash "$0"
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/tests/lib/suite.sh" || exit 1
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/fixture.sh"
driver_fixture; on_exit_keep_status 'rm -rf "$FIX"'
. "$HERE/../ai-step.sh" || exit 1
. "$HERE/../steps/build.sh" || exit 1
unset DATABASE_URL
export DRIVER_TICKET=701

DBS="$FIX/dbs"; mkdir -p "$DBS"
cat > "$BIN/createdb" <<SH
#!/usr/bin/env bash
printf 'createdb %s\n' "\$*" >> "$FIX/pg.log"
n="\${@: -1}"
[ ! -e "$DBS/\$n" ] || { echo "createdb: error: database \"\$n\" already exists" >&2; exit 1; }
[ ! -f "$FIX/createdb-fails" ] || { echo "createdb: error: connection refused" >&2; exit 1; }
: > "$DBS/\$n"
SH
cat > "$BIN/dropdb" <<SH
#!/usr/bin/env bash
printf 'dropdb %s\n' "\$*" >> "$FIX/pg.log"
rm -f "$DBS/\${@: -1}"
SH
chmod +x "$BIN/createdb" "$BIN/dropdb"
: > "$FIX/pg.log"; : > "$FIX/setup.log"; : > "$FIX/seen.log"

cfg_db() { # <json-or-null> — set tests.db in the fixture's harness.json
  jq --argjson d "$1" 'if $d == null then del(.tests) else .tests.db = $d end' "$HARNESS_CFG" > "$HARNESS_CFG.tmp" \
    && mv "$HARNESS_CFG.tmp" "$HARNESS_CFG"
}
SETUP="bash -c 'printf \"%s\\n\" \"\$DATABASE_URL\" >> $FIX/setup.log'"
cfg_db "$(jq -nc --arg s "$SETUP" '{urlTemplate:"postgresql://u:p@localhost:5432/{name}?schema=public", admin:"postgresql://u:p@localhost:5432/postgres", setup:$s}')"
reset_logs() { : > "$FIX/pg.log"; : > "$FIX/setup.log"; : > "$FIX/seen.log"; }
created() { sed -n 's/^createdb .* \(hp_[a-z0-9_]*\)$/\1/p' "$FIX/pg.log"; }
dropped() { sed -n 's/^dropdb .* \(hp_[a-z0-9_]*\)$/\1/p' "$FIX/pg.log"; }
left()    { ls "$DBS" | tr '\n' ' ' | sed 's/ $//'; }

c() { git -C "$1" -c user.email=t@e.invalid -c user.name=T commit -qm "$2"; git -C "$1" rev-parse HEAD; }

# A db test: it records the URL it was given, is SKIPPED (green) with none, and
# otherwise needs the change.
printf 'no\n' > "$REPO/feat.txt"; git -C "$REPO" add feat.txt; c "$REPO" base >/dev/null
cat > "$REPO/feat.db.test.sh" <<SH
#!/usr/bin/env bash
printf '%s\n' "\${DATABASE_URL:-}" >> "$FIX/seen.log"
[ -n "\${DATABASE_URL:-}" ] || { echo "skipped: no DATABASE_URL"; exit 0; }
grep -q yes feat.txt || { echo " FAIL  feat > is yes"; exit 1; }
SH
git -C "$REPO" add feat.db.test.sh; TS=$(c "$REPO" "test: feat")
printf 'yes\n' > "$REPO/feat.txt"; git -C "$REPO" add feat.txt; IS=$(c "$REPO" "feat: feat")

echo "--- a proof gets a fresh, set-up database in each half, and both are dropped ---"
out=$(driver_prove_red_green "$REPO" feat.db.test.sh "$TS" "$IS" "bash feat.db.test.sh" 2>&1); rc=$?
want "the db test proves red then green" "0" "$rc"
want "two databases were created" "2" "$(created | wc -l | tr -d ' ')"
want "two different ones" "2" "$(created | sort -u | wc -l | tr -d ' ')"
want_in "named under the prefix, for the ticket" '^hp_701_[0-9]+_[0-9]+$' "$(created | head -1)"
want_in "created through the admin URL" '^createdb --maintenance-db=postgresql://u:p@localhost:5432/postgres hp_' "$(head -1 "$FIX/pg.log")"
want "setup ran with each one's URL" "$(created | sed 's|^|postgresql://u:p@localhost:5432/|; s|$|?schema=public|')" "$(cat "$FIX/setup.log")"
want "the proof saw the same URL setup did" "$(cat "$FIX/setup.log")" "$(cat "$FIX/seen.log")"
want "every one was dropped" "$(created)" "$(dropped)"
want "none is left" "" "$(left)"

echo "--- a proof that fails still drops its databases ---"
reset_logs
out=$(driver_prove_red_green "$REPO" feat.db.test.sh "$TS" "$IS" "bash feat.db.test.sh && false" 2>&1); rc=$?
want "it is refused as still failing" "2" "$rc"
want "both were created" "2" "$(created | wc -l | tr -d ' ')"
want "and both dropped" "$(created)" "$(dropped)"
want "none is left" "" "$(left)"

echo "--- a proof that runs out of time still drops its database ---"
reset_logs
out=$(DRIVER_CMD_TIMEOUT=2 driver_prove_red_green "$REPO" feat.db.test.sh "$TS" "$IS" "sleep 20" 2>&1); rc=$?
want "it is out of time" "4" "$rc"
want "and dropped what it made" "$(created)" "$(dropped)"
want "none is left" "" "$(left)"

echo "--- the planted-break proof gets one too ---"
reset_logs
out=$(driver_prove_by_break "$REPO" feat.db.test.sh "$IS" feat.txt yes no "bash feat.db.test.sh" 2>&1); rc=$?
want "red with the break, green without" "0" "$rc"
want "each half saw a database" "2" "$(grep -c '^postgresql://' "$FIX/seen.log")"
want "both dropped" "$(created)" "$(dropped)"
want "none is left" "" "$(left)"

echo "--- a setup that fails is a tree not prepared, never a red ---"
reset_logs
cfg_db "$(jq -nc '{urlTemplate:"postgresql://u:p@localhost:5432/{name}", admin:"postgresql://u:p@localhost:5432/postgres", setup:"echo migration 42 failed >&2; exit 3"}')"
out=$(driver_prove_red_green "$REPO" feat.db.test.sh "$TS" "$IS" "bash feat.db.test.sh" 2>&1); rc=$?
want "it is exit 5" "5" "$rc"
want_in "saying the setup failed, and how" "setup \(echo migration 42 failed.*exit 3\) failed with exit 3: migration 42 failed" "$out"
want_not_in "never 'still fails' or 'passes without'" 'still fails|passes without' "$out"
want "the half-made database was dropped" "$(created)" "$(dropped)"
want "none is left" "" "$(left)"

echo "--- a setup that fails only in the tree with the change is still not a red ---"
reset_logs
cfg_db "$(jq -nc '{urlTemplate:"postgresql://u:p@localhost:5432/{name}", admin:"postgresql://u:p@localhost:5432/postgres", setup:"grep -q no feat.txt || { echo the new migration failed >&2; exit 4; }"}')"
out=$(driver_prove_red_green "$REPO" feat.db.test.sh "$TS" "$IS" "bash feat.db.test.sh" 2>&1); rc=$?
want "it is exit 5" "5" "$rc"
want_in "naming the half" 'could not be prepared with the change: .*the new migration failed' "$out"
want_not_in "never 'still fails with the change'" 'still fails' "$out"
want "both dropped" "$(created)" "$(dropped)"

echo "--- and so in the planted-break proof ---"
reset_logs
cfg_db "$(jq -nc '{urlTemplate:"postgresql://u:p@localhost:5432/{name}", admin:"postgresql://u:p@localhost:5432/postgres", setup:"exit 3"}')"
out=$(driver_prove_by_break "$REPO" feat.db.test.sh "$IS" feat.txt yes no "bash feat.db.test.sh" 2>&1); rc=$?
want "it is exit 5" "5" "$rc"
want_in "saying so" 'test database could not be prepared with the break' "$out"
want "both dropped" "$(created)" "$(dropped)"

echo "--- a database that cannot be created is the same ---"
reset_logs; touch "$FIX/createdb-fails"
cfg_db "$(jq -nc '{urlTemplate:"postgresql://u:p@localhost:5432/{name}", admin:"postgresql://u:p@localhost:5432/postgres"}')"
out=$(driver_prove_red_green "$REPO" feat.db.test.sh "$TS" "$IS" "bash feat.db.test.sh" 2>&1); rc=$?
want "it is exit 5" "5" "$rc"
want_in "naming createdb's reason" 'could not be created \(createdb exit 1\): createdb: error: connection refused' "$out"
want "the test never ran" "" "$(cat "$FIX/seen.log")"
want "nothing was dropped — nothing was made" "" "$(dropped)"
rm -f "$FIX/createdb-fails"

echo "--- it never touches a database it did not make ---"
reset_logs
: > "$DBS/appdb"; : > "$DBS/hp_someone_else_1"
rc=0; out=$(driver_test_db_drop appdb 2>&1) || rc=$?
want "a name outside the prefix is refused" "1" "$rc"
want_in "saying so" "refused to drop 'appdb' — not a hp_ test database" "$out"
rc=0; out=$(driver_test_db_drop 'hp_x; DROP DATABASE appdb' 2>&1) || rc=$?
want "so is a name that only starts with it" "1" "$rc"
rc=0; out=$(driver_test_db_drop hp_someone_else_1 2>&1) || rc=$?
want "a prefixed name this run did not create is refused" "1" "$rc"
want_in "saying so" "this run did not create it" "$out"
rc=0; driver_test_db_create appdb "$REPO" || rc=$?
want "creating outside the prefix is refused" "1" "$rc"
want_in "saying so" "refused to create 'appdb'" "$DRIVER_TEST_DB_WHY"
want "no createdb or dropdb ran" "" "$(cat "$FIX/pg.log")"
want "and both databases are still there" "appdb hp_someone_else_1" "$(left)"
# A name that already exists is never adopted, so it is never dropped either.
rc=0; out=$(driver_with_test_db "$FIX/clash.why" "$REPO" true 2>&1) || rc=$?
want "a fresh name each call, so the run creates its own" "0" "$rc"
rc=0; driver_test_db_create hp_someone_else_1 "$REPO" || rc=$?
want "an existing name cannot be created over" "1" "$rc"
rc=0; driver_test_db_drop hp_someone_else_1 >/dev/null 2>&1 || rc=$?
want "and is still not this run's to drop" "1" "$rc"
want "it survives" "appdb hp_someone_else_1" "$(left)"
rm -f "$DBS/appdb" "$DBS/hp_someone_else_1"

echo "--- a template with no {name} would point at someone's database: refused ---"
reset_logs
cfg_db "$(jq -nc '{urlTemplate:"postgresql://u:p@localhost:5432/appdb", admin:"postgresql://u:p@localhost:5432/postgres"}')"
out=$(driver_prove_red_green "$REPO" feat.db.test.sh "$TS" "$IS" "bash feat.db.test.sh" 2>&1); rc=$?
want "it is exit 5" "5" "$rc"
want_in "saying why" 'urlTemplate has no \{name\}' "$out"
want "nothing was created" "" "$(cat "$FIX/pg.log")"

echo "--- the steps that run tests get one too, dropped when the step ends ---"
reset_logs
cfg_db "$(jq -nc --arg s "$SETUP" '{urlTemplate:"postgresql://u:p@localhost:5432/{name}", admin:"postgresql://u:p@localhost:5432/postgres", setup:$s}')"
cat > "$FIX/claude-db" <<SH
#!/usr/bin/env bash
printf '%s\n' "\${DATABASE_URL:-}" >> "$FIX/seen.log"
exec "$BIN/claude" "\$@"
SH
chmod +x "$FIX/claude-db"
driver_state_init 701
fix_brief build ""; fix_ai build '{"ok":true}'
DRIVER_CLAUDE="$FIX/claude-db" driver_ai_step 701 build >/dev/null 2>&1 || true
want "the build step ran with a database" "1" "$(grep -c '^postgresql://.*/hp_701_' "$FIX/seen.log")"
want "the one setup ran on" "$(cat "$FIX/setup.log")" "$(cat "$FIX/seen.log")"
want "dropped after" "$(created)" "$(dropped)"
want "none is left" "" "$(left)"
reset_logs
fix_brief plan ""; fix_ai plan '{"ok":true}'
DRIVER_CLAUDE="$FIX/claude-db" driver_ai_step 701 plan >/dev/null 2>&1 || true
want "a step that runs no tests gets none" "" "$(cat "$FIX/seen.log")"
want "and creates none" "" "$(cat "$FIX/pg.log")"

echo "--- with no tests.db, nothing changes ---"
reset_logs
cfg_db null
out=$(driver_prove_red_green "$REPO" feat.db.test.sh "$TS" "$IS" "bash feat.db.test.sh" 2>&1); rc=$?
want "the skipped db test reads green before the change, as today" "1" "$rc"
want "no database was created" "" "$(cat "$FIX/pg.log")"
want "the test ran in both halves" "2" "$(wc -l < "$FIX/seen.log" | tr -d ' ')"
want "and saw no DATABASE_URL" "0" "$(grep -c . "$FIX/seen.log")"

suite_end "$FAILED"
