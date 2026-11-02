#!/usr/bin/env bash
# code-sweep.test.sh — the nightly sweep files ONE ticket per class of copied defect,
# never one per instance, never twice, never more than the nightly cap; it rotates
# through the repo one area a night and reads the reviewer's pre-existing queue.
# 187 finding tickets were filed in one day before this; the cap and the dedupe are why.
# Run: bash "$0"
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/tests/lib/suite.sh" || exit 1
for v in $(env | sed -n 's/^\(GIT_[A-Z_]*\)=.*/\1/p'); do unset "$v"; done
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../swarm/tests/fixture.sh"
swarm_fixture
on_exit_keep_status 'rm -rf "$FIX"'
FAILED=0
S="${SWEEP_SUT:-$HERE/code-sweep.sh}"
SD="$STATE/swarm/code-sweep"
fixture_path REPO "$FIX"

# ---- the repo: an origin with a tree the sweep can read --------------------------
G() { git -c user.email=t@e.invalid -c user.name=T "$@"; }
ORIGIN="$FIX/origin.git"; git init -q --bare "$ORIGIN"
mkdir -p "$REPO/a" "$REPO/b/one" "$REPO/b/two" "$REPO/c" "$REPO/docs"
for f in a/x.ts a/y.ts b/one/p.ts b/one/q.ts b/two/r.ts b/top.ts c/z.py; do echo "export const v = 1" > "$REPO/$f"; done
echo "# notes" > "$REPO/docs/readme.md"; echo "root" > "$REPO/root.sh"
G -C "$REPO" checkout -q -b develop
G -C "$REPO" add -A && G -C "$REPO" commit -qm init
G -C "$REPO" remote add origin "$ORIGIN" && G -C "$REPO" push -q origin develop
G -C "$REPO" fetch -q origin

# The config the sweep reads is a copy outside the repo, so a case can change it.
cp "$HARNESS_CFG_PATH" "$FIX/cfg.json"; export HARNESS_CFG_PATH="$FIX/cfg.json"
cfg() { # <jq expression> — edit the sweep block of that config
  jq "$1" "$FIX/cfg.json" > "$FIX/cfg.next" && mv "$FIX/cfg.next" "$FIX/cfg.json"
}
cfg '.sweep = {areas: ["a", "b", "c"], minInstances: 3, maxTickets: 3}'

# ---- stand-ins: gh and claude, each recording what it was asked --------------------
mkdir -p "$FIX/gh" "$FIX/bodies"
printf '[]\n' > "$FIX/gh/sweep-open.json"; printf '[]\n' > "$FIX/gh/sweep-closed.json"
printf '[{"number":17807,"title":"337 server routes hand-copy the same sign-in check"}]\n' > "$FIX/gh/all-open.json"
cat > "$BIN/gh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_LOG"
[ -f "$FIX/gh/hang" ] && exec sleep 600
case "$1 $2" in
  "issue list")
    case "$*" in
      *"--state closed"*) f=sweep-closed ;;
      *"--label sweep:class"*) f=sweep-open ;;
      *) f=all-open ;;
    esac
    [ -f "$FIX/gh/$f.fail" ] && { echo "HTTP 502: Bad Gateway" >&2; exit 1; }
    cat "$FIX/gh/$f.json" ;;
  "issue create")
    [ -f "$FIX/gh/create.fail" ] && { echo "HTTP 422: label does not exist" >&2; exit 1; }
    n=$(( 9000 + $(ls "$FIX/bodies" | wc -l) ))
    prev=""; for a in "$@"; do [ "$prev" = --body-file ] && cp "$a" "$FIX/bodies/$n.md"; prev="$a"; done
    printf '%s\n' "$*" > "$FIX/bodies/$n.args"
    echo "https://github.com/acme/widgets/issues/$n" ;;
  "issue comment") echo "https://github.com/acme/widgets/issues/1#issuecomment-1" ;;
  *) echo "{}" ;;
esac
SH
cat > "$BIN/claude" <<'SH'
#!/usr/bin/env bash
n=$(( $(ls "$FIX/calls" 2>/dev/null | wc -l) + 1 )); mkdir -p "$FIX/calls"
{ echo "cwd=$(pwd -P)"; echo "args=$*"; echo "---"; cat; } > "$FIX/calls/$n"
[ -f "$FIX/claude-hang" ] && exec sleep 600
cat "$FIX/answer"
SH
chmod +x "$BIN/gh" "$BIN/claude"
export SWARM_GH="$BIN/gh" SWEEP_CLAUDE="$BIN/claude" SWEEP_TIMEOUT_SEC=20 SWEEP_GH_TIMEOUT=20

answer() { # <classes JSON array> [fence]
  if [ "${2:-}" = fence ]; then printf 'Here is what I found.\n```json\n{"classes": %s}\n```\n' "$1" > "$FIX/answer"
  else printf '{"classes": %s}\n' "$1" > "$FIX/answer"; fi
}
cls() { # <key> <instances> [count] [existing]
  local i inst="[]"
  for i in $(seq 1 "$2"); do inst=$(jq -c --arg p "a/x.ts:$i" '. + [$p]' <<<"$inst"); done
  jq -nc --arg k "$1" --argjson i "$inst" --argjson c "${3:-$2}" --argjson e "${4:-null}" \
    '{key:$k, title:("Class " + $k), why:"It drifts.", sourceFix:"One shared helper.", guard:"A lint rule refuses the copy.", count:$c, instances:$i, existing:$e}'
}
run() { bash "$S" "$@" > "$FIX/out" 2>&1; echo $?; }
writes() { grep -cE '^issue (create|comment|edit)' "$GH_LOG"; }
creates() { grep -c '^issue create' "$GH_LOG"; }
reset() { : > "$GH_LOG"; rm -rf "$FIX/calls" "$FIX/bodies"; mkdir -p "$FIX/bodies"; }
calls() { ls "$FIX/calls" 2>/dev/null | wc -l | tr -d ' '; }
last_call() { cat "$FIX/calls/$(calls)"; }

echo "--- the answer is read by its contract ---"
answer "[$(cls good-one 4),$(cls too-few 2),$(cls 'Bad Key!' 5)]" fence
jq '.classes += [{"key":"no-fix","title":"t","why":"w","guard":"g","count":4,"instances":["a:1","a:2","a:3","a:4"]}]' \
  <(sed -n '/^```json/,/^```/p' "$FIX/answer" | sed '1d;$d') > "$FIX/a2" && { printf '```json\n'; cat "$FIX/a2"; printf '```\n'; } > "$FIX/answer"
reset; rc=$(run --file --force)
want "a fenced answer is read" 0 "$rc"
want "only the class that meets the contract is filed" 1 "$(creates)"
want_in "it is the good one" 'Class good-one' "$(cat "$FIX"/bodies/*.args)"
want_in "a class under the minimum is dropped, by name" 'too-few.*2 instances' "$(cat "$FIX/out")"
want_in "a key that is not a slug is dropped" 'Bad Key' "$(cat "$FIX/out")"
want_in "a class with no source fix is dropped" 'no-fix.*source fix' "$(cat "$FIX/out")"

echo "--- prose, or a cut-off answer, files nothing and moves nothing ---"
rm -f "$SD/last-area"
printf 'I looked around and things seem fine.\n' > "$FIX/answer"
reset; rc=$(run --file --force)
want "prose exits 2" 2 "$rc"
want "and writes nothing to GitHub" 0 "$(writes)"
want_in "it says why" 'not the JSON contract' "$(cat "$FIX/out")"
want "the rotation did not move" "" "$(cat "$SD/last-area" 2>/dev/null)"
printf '{"classes": [{"key": "cut-off", "title": "t' > "$FIX/answer"
reset; rc=$(run --file --force)
want "a truncated answer exits 2 too" 2 "$rc"

echo "--- one area a night, rotating through them all ---"
answer '[]'; rm -f "$SD/last-area"; seen=""
for i in 1 2 3 4; do reset; run --force >/dev/null; seen="$seen $(sed -n 's/^area=//p' "$SD/last-area")"; done
want "a then b then c then back to a" " a b c a" "$seen"
echo "zzz-removed" > "$SD/last-area"; reset; run --force >/dev/null
want "a last area since removed starts again at the first" "a" "$(cat "$SD/last-area" | sed -n 's/^area=//p')"
want_in "the agent is told its area" 'Your area: `a`' "$(last_call)"

echo "--- with no areas configured, the code files in runs that cover all of it ---"
cfg 'del(.sweep.areas) | .sweep.maxAreaFiles = 2'
reset; out=$(bash "$S" --areas 2>&1)
want "runs of about two, files with no code skipped" "a/x.ts .. a/y.ts|b/one/p.ts .. b/one/q.ts|b/top.ts .. b/two/r.ts|c/z.py .. root.sh" \
  "$(printf '%s\n' "$out" | paste -sd'|' -)"
rm -f "$SD/last-area"; seen=""
for i in 1 2 3 4 5; do reset; run --force >/dev/null; seen="$seen|$(grep -c . "$SD/run/area-files.txt")@$(head -1 "$SD/run/area-files.txt")"; done
want "night by night, then round again" "|2@a/x.ts|2@b/one/p.ts|2@b/top.ts|2@c/z.py|2@a/x.ts" "$seen"
want_in "the agent is told its run" 'Your area: `a/x.ts .. a/y.ts`' "$(last_call)"
cfg '.sweep.maxAreaFiles = 3'
printf 'file=b/one/p.ts\n' > "$SD/last-area"; reset; run --force >/dev/null
want "a run finishes the folder it is in when that is near" "b/one/q.ts b/top.ts b/two/r.ts" "$(paste -sd' ' - < "$SD/run/area-files.txt")"
printf 'file=b/gone.ts\n' > "$SD/last-area"; reset; run --force >/dev/null
want "a last file since deleted carries on after its place" "b/one/p.ts" "$(head -1 "$SD/run/area-files.txt")"
before=$(cat "$SD/last-area"); reset; rc=$(run --force --area b/one)
want "a named folder is swept as it is" "b/one/p.ts b/one/q.ts" "$(paste -sd' ' - < "$SD/run/area-files.txt")"
want "and the rotation does not move" "$before" "$(cat "$SD/last-area")"
reset; run --force --area 'b/*' >/dev/null
want "a folder's own files" "b/top.ts" "$(paste -sd' ' - < "$SD/run/area-files.txt")"
cfg '.sweep.areas = ["a", "b", "c"] | del(.sweep.maxAreaFiles)'

echo "--- once a night: a second wake the same day does nothing ---"
answer '[]'; reset; run >/dev/null
reset; rc=$(run)
want "the second wake exits 0" 0 "$rc"
want "and calls no agent" 0 "$(calls)"
want_in "and says it already swept" 'already swept' "$(cat "$FIX/out")"

echo "--- a busy machine waits for the next wake ---"
rm -f "$SD/last-run"; reset
rc=$(SWARM_IDLE=5 bash "$S" > "$FIX/out" 2>&1; echo $?)
want "busy exits 0" 0 "$rc"
want "and calls no agent" 0 "$(calls)"
want_in "and names the reading" 'busy' "$(cat "$FIX/out")"
want "and has not marked the night swept" "" "$(cat "$SD/last-run" 2>/dev/null)"

echo "--- the agent reads a detached tree of the trunk, read-only ---"
answer '[]'; reset; run --force >/dev/null
c=$(last_call)
want_in "it runs the sweeper agent" '--agent agent-harness:code-sweeper' "$c"
want_in "with writing tools refused" '--disallowed-tools Edit Write NotebookEdit' "$c"
want_in "with a turn cap" '--max-turns [0-9]' "$c"
cwd=$(printf '%s\n' "$c" | sed -n 's/^cwd=//p')
want_not_in "never in the operator's clone" "^$(cd "$REPO" && pwd -P)\$" "$cwd"
if [ -n "$cwd" ] && [ ! -e "$cwd" ]; then ok "the tree is removed afterwards"; else bad "the tree $cwd was left behind"; fi
want "and the operator's clone keeps no extra worktree" 1 "$(git -C "$REPO" worktree list | wc -l | tr -d ' ')"

echo "--- shadow by default: it reports and writes nothing ---"
answer "[$(cls shadow-class 4)]"; reset; rc=$(run --force)
want "shadow exits 0" 0 "$rc"
want "and makes no GitHub write" 0 "$(writes)"
want_in "it says what it would file" 'would file.*shadow-class' "$(cat "$FIX/out")"

echo "--- a filed ticket carries the class, its fix and its marker ---"
answer "[$(cls copied-guard 4 337)]"; reset; run --file --force >/dev/null
b=$(cat "$FIX"/bodies/*.md 2>/dev/null)
want_in "the dedupe marker" '<!-- sweep-class: copied-guard -->' "$b"
want_in "the whole count" '337' "$b"
want_in "the instances" 'a/x.ts:4' "$b"
want_in "the fix at the source" 'One shared helper' "$b"
want_in "what stops the next copy" 'A lint rule refuses the copy' "$b"
want_in "the sweep label" '--label sweep:class' "$(cat "$FIX"/bodies/*.args)"

echo "--- an open ticket owns its class: recounted, never refiled ---"
jq -n '[{number: 4242, title: "Class copied-guard", body: "x\n<!-- sweep-class: copied-guard -->\n", labels: [{name: "sweep:class"}]}]' > "$FIX/gh/sweep-open.json"
reset; run --file --force >/dev/null
want "no new ticket" 0 "$(creates)"
want "the count it was filed with is no comment" 0 "$(writes)"
answer "[$(cls copied-guard 4 340)]"; reset; run --file --force >/dev/null
want "a moved count is still no new ticket" 0 "$(creates)"
want_in "a recount on the open one" '^issue comment 4242' "$(cat "$GH_LOG")"
reset; run --file --force >/dev/null
want "the same count again is no second comment" 0 "$(writes)"
printf '[]\n' > "$FIX/gh/sweep-open.json"

echo "--- a class closed as not planned is never refiled ---"
jq -n '[{number: 4243, body: "<!-- sweep-class: copied-guard -->", stateReason: "NOT_PLANNED"}]' > "$FIX/gh/sweep-closed.json"
reset; run --file --force >/dev/null
want "nothing filed" 0 "$(creates)"
printf '[]\n' > "$FIX/gh/sweep-closed.json"

echo "--- a class an open ticket already covers is left to it ---"
answer "[$(cls sign-in-copies 4 337 17807)]"; reset; run --file --force >/dev/null
want "nothing filed" 0 "$(creates)"
want_in "it names the ticket" '#17807' "$(cat "$FIX/out")"
want_in "the agent saw the open tickets" '17807' "$(cat "$SD"/run/open-tickets.tsv 2>/dev/null || last_call)"

echo "--- one key twice in one answer is one ticket ---"
answer "[$(cls twice 4),$(cls twice 5)]"; reset; run --file --force >/dev/null
want "one create" 1 "$(creates)"

echo "--- the nightly cap: five classes, three tickets ---"
answer "[$(cls c-one 4),$(cls c-two 4),$(cls c-three 4),$(cls c-four 4),$(cls c-five 4)]"; reset; run --file --force >/dev/null
want "three created" 3 "$(creates)"
want_in "the rest wait, by name" 'cap.*c-four' "$(cat "$FIX/out")"
cfg '.sweep.maxTickets = 1'; reset; run --file --force >/dev/null
want "the cap comes from the config" 1 "$(creates)"
cfg '.sweep.maxTickets = 3'

echo "--- a failed write stops the night, and the rotation stays put ---"
answer "[$(cls will-fail 4)]"; printf 'area=b\n' > "$SD/last-area"; rm -f "$SD/last-run"
touch "$FIX/gh/create.fail"; reset; rc=$(run --file)
want_not_in "it exits non-zero" '^0$' "$rc"
want "the rotation did not move" "area=b" "$(cat "$SD/last-area")"
want "the night is not marked swept" "" "$(cat "$SD/last-run" 2>/dev/null)"
rm -f "$FIX/gh/create.fail"

echo "--- a failed read is unknown, never 'no tickets' ---"
touch "$FIX/gh/sweep-open.fail"; answer "[$(cls after-bad-read 4)]"; reset; rc=$(run --file --force)
want_not_in "it exits non-zero" '^0$' "$rc"
want "and files nothing" 0 "$(creates)"
want "and calls no agent" 0 "$(calls)"
rm -f "$FIX/gh/sweep-open.fail"

echo "--- the reviewer's pre-existing queue ---"
Q="$STATE/review/pre-existing.jsonl"; rm -f "$Q"
answer '[]'; reset; rc=$(run --file --force)
want "no queue file is an empty queue" 0 "$rc"
want_in "and the agent is told so" 'Pre-existing findings: none' "$(last_call)"
mkdir -p "$(dirname "$Q")"
printf '{"file":"b/one/p.ts","line":3,"summary":"swallowed error read as empty"}\n{"file":"c/z.py","line":1,"summary":"unbounded call"}\n' > "$Q"
reset; run --force >/dev/null
want_in "the queue reaches the agent" 'swallowed error read as empty' "$(last_call)"
reset; run --force >/dev/null
want_in "shadow leaves it queued" 'swallowed error read as empty' "$(last_call)"
reset; run --file --force >/dev/null
want_in "a filing night reads it" 'unbounded call' "$(last_call)"
reset; run --file --force >/dev/null
want_not_in "and the next night does not read it again" 'swallowed error read as empty' "$(last_call)"
printf '{"file":"a/x.ts","line":9,"summary":"appended later"}\n' >> "$Q"
reset; run --file --force >/dev/null
want_in "a line appended later is read" 'appended later' "$(last_call)"
printf '{"file":"a/y.ts","line":1,"summary":"after a rotation"}\n' > "$Q"
reset; run --file --force >/dev/null
want_in "a file rotated shorter is read from its start" 'after a rotation' "$(last_call)"

echo "--- every outside call has a time limit ---"
touch "$FIX/claude-hang"; rm -f "$SD/last-run"; reset
start=$SECONDS; rc=$(SWEEP_TIMEOUT_SEC=2 bash "$S" --file > "$FIX/out" 2>&1; echo $?)
want "a hung agent is stopped" 124 "$rc"
[ $(( SECONDS - start )) -lt 30 ] && ok "inside its limit" || bad "it took $(( SECONDS - start ))s"
want "and the night is not marked swept" "" "$(cat "$SD/last-run" 2>/dev/null)"
rm -f "$FIX/claude-hang"
touch "$FIX/gh/hang"; reset
start=$SECONDS; rc=$(SWEEP_GH_TIMEOUT=2 bash "$S" --file --force > "$FIX/out" 2>&1; echo $?)
want_not_in "a hung gh fails the night" '^0$' "$rc"
[ $(( SECONDS - start )) -lt 30 ] && ok "inside its limit" || bad "it took $(( SECONDS - start ))s"
rm -f "$FIX/gh/hang"

suite_end "$FAILED"
