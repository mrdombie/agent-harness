#!/usr/bin/env bash
# simplify.test.sh — before review, the builder's own session runs /simplify once per
# change. Its clean-up stays only while the fast gates (gates.local) stay green.
# Run: bash "$0"
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/tests/lib/suite.sh" || exit 1
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/fixture.sh"
driver_fixture; on_exit_keep_status 'rm -rf "$FIX"'

echo "--- the default order puts simplify between self-check and review ---"
order=$(env -u DRIVER_STEPS -u DRIVER_DIR bash -c '. "$1/../driver-env.sh" >/dev/null 2>&1; printf "%s" "$DRIVER_STEPS"' _ "$HERE")
want_in "simplify straight after self-check, straight before review" ' self-check simplify review ' " $order "

. "$HERE/../steps/simplify.sh" || exit 1
fix_brief simplify simplify "Simplify the change against {{TARGET}}."

# The fast gates: green while a.sh carries no BROKEN line.
jq '.gates.local = ["! grep -q BROKEN a.sh"]' "$HARNESS_CFG" > "$FIX/sp-gates.json"
HARNESS_CFG="$FIX/sp-gates.json"

# The model stub, wrapped: $FIX/act (when present) runs in the step's tree first, which is
# how a "clean-up commit" lands while the model is called.
mv "$BIN/claude" "$BIN/claude.real"
cat > "$BIN/claude" <<'SH'
#!/usr/bin/env bash
[ ! -x "$FIX/act" ] || "$FIX/act"
exec "$BIN/claude.real" "$@"
SH
chmod +x "$BIN/claude"

# sp_tree <ticket> — a branch with one change, a.sh, and two build-task logs as the build
# step writes them (build --as build-task-N); task 2 ran last and names the session to resume.
sp_tree() {
  git -C "$REPO" worktree add -q "$FIX/sp$1" -b "tkt-$1/work" develop
  printf 'a\n' > "$FIX/sp$1/a.sh"; git -C "$FIX/sp$1" add -A; git -C "$FIX/sp$1" commit -qm "feat: a"
  driver_state_init "$1" --worktree "$FIX/sp$1" --branch "tkt-$1/work"
  fix_issue "$1" OPEN "status:claimed"
  mkdir -p "$(driver_state_dir "$1")/steps"
  printf '%s\n' '{"type":"system","subtype":"init","session_id":"sess-task1-'"$1"'"}' > "$(driver_state_dir "$1")/steps/build-task-1.log"
  printf '%s\n' '{"type":"system","subtype":"init","session_id":"sess-old"}' \
    '{"type":"system","subtype":"init","session_id":"sess-build-'"$1"'"}' > "$(driver_state_dir "$1")/steps/build-task-2.log"
  touch -t 202601010000 "$(driver_state_dir "$1")/steps/build-task-1.log"
  touch -t 202601010100 "$(driver_state_dir "$1")/steps/build-task-2.log"
}
# sp_ai [agents] — the simplify transcript: the Skill call, <agents> Agent spawns, an answer.
sp_ai() {
  local f="$FIX/ai/simplify.jsonl" i=0
  jq -nc '{type:"assistant", message:{content:[{type:"tool_use", id:"s1", name:"Skill", input:{skill:"simplify"}}]}}' > "$f"
  while [ "$i" -lt "${1:-0}" ]; do
    i=$((i+1))
    jq -nc --arg id "ag$i" '{type:"assistant", message:{content:[{type:"tool_use", id:$id, name:"Agent", input:{description:"look"}}]}}' >> "$f"
  done
  jq -nc '{type:"result", subtype:"success", is_error:false, result:"",
    structured_output:{step:"simplify", skills:["simplify"], changes:[{file:"a.sh", what:"dropped a dead branch"}]}}' >> "$f"
}
calls() { grep -c '^simplify$' "$CLAUDE_LOG"; }
head_of() { git -C "$FIX/sp$1" rev-parse HEAD; }

echo "--- one call, resuming the builder's session ---"
sp_tree 301; : > "$CLAUDE_LOG"; sp_ai 0; rm -f "$FIX/act"
rc=0; out=$(driver_step_simplify 301 2>&1) || rc=$?
want "the step finishes"                          "0" "$rc"
want "the model is called once"                   "1" "$(calls)"
want "it resumes the last build task's session"  "sess-build-301" "$(grep -A1 -x -- '--resume' "$FIX/claude-args-simplify.txt" | tail -1)"
want_not_in "and does not start a fresh one"      'starts a fresh one' "$out"
want_in "with the simplify brief"                 'Simplify the change against' "$(cat "$FIX/claude-stdin-simplify.txt")"
want_in "and says what it removed"                'a.sh: dropped a dead branch' "$out"

echo "--- the task that ran last is resumed, not the highest number: task 2 kept from an earlier pass ---"
sp_tree 307; : > "$CLAUDE_LOG"; sp_ai 0; rm -f "$FIX/act"
touch -t 202601010200 "$(driver_state_dir 307)/steps/build-task-1.log"
rc=0; out=$(driver_step_simplify 307 2>&1) || rc=$?
want "the step finishes"                          "0" "$rc"
want "it resumes task 1, rebuilt last"            "sess-task1-307" "$(grep -A1 -x -- '--resume' "$FIX/claude-args-simplify.txt" | tail -1)"

echo "--- a clean-up that turns a fast gate red is dropped ---"
sp_tree 302; : > "$CLAUDE_LOG"; sp_ai 0
printf '#!/usr/bin/env bash\nprintf "BROKEN\\n" >> a.sh; git add -A; git commit -qm "refactor: simplify"\n' > "$FIX/act"; chmod +x "$FIX/act"
before=$(head_of 302)
rc=0; out=$(driver_step_simplify 302 2>&1) || rc=$?
want "the step still finishes"                    "0" "$rc"
want "HEAD is back where it was"                  "$before" "$(head_of 302)"
want_in "saying the clean-up was dropped"         'dropped' "$out"

echo "--- a clean-up with green gates stays ---"
sp_tree 303; : > "$CLAUDE_LOG"; sp_ai 0
printf '#!/usr/bin/env bash\nprintf "b\\n" >> a.sh; git add -A; git commit -qm "refactor: simplify"\n' > "$FIX/act"; chmod +x "$FIX/act"
before=$(head_of 303)
rc=0; out=$(driver_step_simplify 303 2>&1) || rc=$?
want "the step finishes"                          "0" "$rc"
want "the clean-up commit stays"                  "$before" "$(git -C "$FIX/sp303" rev-parse HEAD~1)"
rm -f "$FIX/act"

echo "--- an edit the build left uncommitted is never swept into simplify, so a reset cannot erase it ---"
sp_tree 308; : > "$CLAUDE_LOG"; sp_ai 0
printf 'builder work\n' > "$FIX/sp308/b.sh"
printf '#!/usr/bin/env bash\nprintf "BROKEN\\n" >> a.sh; git add a.sh; git commit -qm "refactor: simplify"\n' > "$FIX/act"; chmod +x "$FIX/act"
before=$(head_of 308)
rc=0; out=$(driver_step_simplify 308 2>&1) || rc=$?
want "the step finishes"                          "0" "$rc"
want "the builder's edit is still in the tree"    "builder work" "$(cat "$FIX/sp308/b.sh" 2>/dev/null)"
want "the model is not called on a dirty tree"    "0" "$(calls)"
want "HEAD is where the build left it"            "$before" "$(head_of 308)"
want_in "saying why simplify skipped"             'uncommitted' "$out"
rm -f "$FIX/act"

echo "--- a clean-up that edits a file outside the change is dropped ---"
sp_tree 309; : > "$CLAUDE_LOG"; sp_ai 0
printf '#!/usr/bin/env bash\nprintf "x\\n" > stray.sh; git add stray.sh; git commit -qm "refactor: simplify"\n' > "$FIX/act"; chmod +x "$FIX/act"
before=$(head_of 309)
rc=0; out=$(driver_step_simplify 309 2>&1) || rc=$?
want "the step finishes"                          "0" "$rc"
want "HEAD is back where it was"                  "$before" "$(head_of 309)"
want_in "saying the clean-up went outside"        'outside' "$out"

echo "--- an uncommitted clean-up commits tracked edits only; a stray new file stays out ---"
sp_tree 310; : > "$CLAUDE_LOG"; sp_ai 0
printf '#!/usr/bin/env bash\nprintf "b\\n" >> a.sh; printf "x\\n" > stray.sh\n' > "$FIX/act"; chmod +x "$FIX/act"
before=$(head_of 310)
rc=0; out=$(driver_step_simplify 310 2>&1) || rc=$?
want "the step finishes"                          "0" "$rc"
want "the in-change clean-up is committed"        "$before" "$(git -C "$FIX/sp310" rev-parse HEAD~1)"
want "the stray file is not in it"                "a.sh" "$(git -C "$FIX/sp310" diff --name-only HEAD~1 HEAD)"
want "nor left behind in the tree"                "" "$(git -C "$FIX/sp310" status --porcelain)"
rm -f "$FIX/act"

echo "--- once per change: a second run, an empty diff and a repair call no model ---"
: > "$CLAUDE_LOG"; sp_ai 0
rc=0; out=$(driver_step_simplify 303 2>&1) || rc=$?
want "the second run finishes"                    "0" "$rc"
want "and calls no model"                         "0" "$(calls)"
want_in "saying simplify already ran"             'already ran on this change' "$out"
git -C "$REPO" worktree add -q "$FIX/sp304" -b "tkt-304/work" develop
driver_state_init 304 --worktree "$FIX/sp304" --branch "tkt-304/work"; fix_issue 304 OPEN "status:claimed"
rc=0; driver_step_simplify 304 >/dev/null 2>&1 || rc=$?
want "an empty diff finishes"                     "0" "$rc"
want "and calls no model"                         "0" "$(calls)"
sp_tree 305; driver_state_set 305 mode repair
rc=0; driver_step_simplify 305 >/dev/null 2>&1 || rc=$?
want "a repair finishes"                          "0" "$rc"
want "and calls no model"                         "0" "$(calls)"

echo "--- the subagents the call started are recorded ---"
sp_tree 306; : > "$CLAUDE_LOG"; sp_ai 3
rc=0; driver_step_simplify 306 >/dev/null 2>&1 || rc=$?
want "the step finishes"                          "0" "$rc"
want "simplify_agents counts the spawns"          "3" "$(driver_state_get 306 simplify_agents)"

echo "--- the pull request states the subagents simplify started on this change ---"
. "$HERE/../steps/ship.sh" || exit 1
want "the body line names the count"              "Simplify: 3 subagent(s) started on this change." "$(_driver_ship_simplify_line 306)"
want "a change simplify never ran on says nothing" "" "$(_driver_ship_simplify_line 305)"

suite_end "$FAILED"
