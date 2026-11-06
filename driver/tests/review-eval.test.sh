#!/usr/bin/env bash
# review-eval.test.sh — the review step scored against a fixed set of past breakages
# (scripts/review-eval.sh). Usage is the brake (the PM, 2026-11-03): at most 20 items,
# one review each (the hunter plus the check the review step already runs), run when the
# review changes and weekly, never daily, and every run says what it cost.
#
# No model is called: the agent runner is the fixture's recorder, answering from
# $FIX/ai/<step>.jsonl. Each rule is planted dead in a copy of the kit, and its case
# must then fail.
# Run: bash "$0"
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/tests/lib/suite.sh" || exit 1
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
. "$HERE/fixture.sh"
driver_fixture; on_exit_keep_status 'rm -rf "$FIX"'
fix_real_briefs
unset DRIVER_REVIEW_CHECK
KIT="$FIX/kit"
export REVIEW_EVAL_DIR="$FIX/eval"

# ---- a past change: base, then a head that breaks src/a.ts line 45 -------------------
mkdir -p "$REPO/src"
seq 1 60 | sed 's/^/line /' > "$REPO/src/a.ts"
git -C "$REPO" add -A; git -C "$REPO" commit -qm "base"
BASE=$(git -C "$REPO" rev-parse HEAD)
sed -i.bak 's/^line 45$/line 45 drops the draft/' "$REPO/src/a.ts"; rm -f "$REPO/src/a.ts.bak"
git -C "$REPO" add -A; git -C "$REPO" commit -qm "head: the retry drops the draft"
HEAD_SHA=$(git -C "$REPO" rev-parse HEAD)
item() { # <id> <file> <line> <summary>
  jq -nc --arg id "$1" --arg b "$BASE" --arg h "$HEAD_SHA" --arg f "$2" --argjson l "$3" --arg s "$4" \
    '{id: $id, pr: 1, title: "a past change", base: $b, head: $h, source: "test", expect: {file: $f, line: $l, summary: $s}}'
}
SET="$FIX/set.json"
jq -n --argjson a "$(item e1 src/a.ts 40 'the retry handler drops the saved draft when the request times out')" \
      --argjson b "$(item e2 src/b.ts 10 'the label reads the wrong count')" '{version: 1, items: [$a, $b]}' > "$SET"

# ---- what the model "answers": the hunter's findings and the check's judgements -------
F1='{"id":"f1","file":"src/a.ts","line":45,"grade":"major","tag":"important","rule":"other","summary":"The retry handler drops the saved draft on timeout","reason":"the person loses the draft","fix":"keep it"}'
F2='{"id":"f2","file":"src/a.ts","line":2,"grade":"minor","tag":"important","rule":"other","summary":"The heading wording is vague","reason":"r","fix":"f"}'
F3='{"id":"f3","file":"src/a.ts","line":9,"grade":"major","tag":"important","rule":"other","summary":"A timer races the save","reason":"r","fix":"f"}'
FN='{"id":"n1","file":"src/a.ts","line":45,"grade":"nit","tag":"nit","rule":"other","summary":"retry handler drops saved draft","reason":"r","fix":"f"}'
answer() { jq -nc --argjson f "$1" '{step: "review", skills: ["code-review"], status: "reviewed", round: 1,
  verdict: (if any($f[]; .grade == "major" or .grade == "critical" or .grade == "minor") then "BLOCKED" else "SHIP" end),
  panel: {skill: "code-review", effort: "high"}, findings: $f}'; }
hunt() { # <answer> <cost>
  local f="$FIX/ai/review.jsonl"
  : > "$f"
  jq -nc '{type:"assistant", message:{content:[{type:"tool_use", id:"toolu_skill", name:"Skill", input:{skill:"code-review", args:"high"}}]}}' >> "$f"
  jq -nc '{type:"system", subtype:"task_started", task_id:"a1", tool_use_id:"toolu_skill", spawn_depth:1}' >> "$f"
  jq -nc --arg r "$1" --argjson c "$2" '{type:"result", subtype:"success", is_error:false, result:$r, structured_output:($r | fromjson), total_cost_usd:$c}' >> "$f"
}
check_says() { # <judgements> <cost>
  local a; a=$(jq -nc --argjson j "$1" '{step: "review-check", skills: [], judgements: $j}')
  jq -nc --arg r "$a" --argjson c "$2" '{type:"result", subtype:"success", is_error:false, result:$r, structured_output:($r | fromjson), total_cost_usd:$c}' > "$FIX/ai/review-check.jsonl"
}
# f3 is judged not real; f1 and f2 stand. Each item: hunter $1.25 + check $0.50.
hunt "$(answer "[$F1,$F2,$F3,$FN]")" 1.25
check_says '[{"id":"f1","real":true,"reason":"line 45"},{"id":"f2","real":true,"reason":"r"},{"id":"f3","real":false,"reason":"cancelled first"}]' 0.5
calls() { local n; n=$(grep -c . "$CLAUDE_LOG" 2>/dev/null); printf '%s' "${n:-0}"; }

kit_copy() { rm -rf "$KIT"; mkdir -p "$KIT"; cp -R "$ROOT/driver" "$ROOT/scripts" "$ROOT/swarm" "$ROOT/shared" "$ROOT/briefs" "$ROOT/.claude-plugin" "$KIT/"; }
ev() { bash "$KIT/scripts/review-eval.sh" "$@"; }   # the runner, from the copy of the kit
fresh() { : > "$CLAUDE_LOG"; : > "$GH_LOG"; rm -rf "$REVIEW_EVAL_DIR"; }

# ---- the cases, each one line R that a plant must change ---------------------------
score_of() { # <findings json> <expect json>
  printf '%s' "$(answer "$1")" > "$FIX/ans.json"; printf '%s' "$2" > "$FIX/exp.json"
  ev score "$FIX/ans.json" "$FIX/exp.json" | jq -r '"\(.hit) \(.kept) \(.false)"'
}
EXP='{"file":"src/a.ts","line":40,"summary":"the retry handler drops the saved draft when the request times out"}'
case_score() { # the tally's match: same file, a line within 10, a similar summary; a nit is not kept
  R="near=$(score_of "[$F1]" "$EXP" | tr ' ' ,)"
  R="$R far=$(score_of "[$(jq -c '.line = 51' <<<"$F1")]" "$EXP" | tr ' ' ,)"
  R="$R otherfile=$(score_of "[$(jq -c '.file = "src/b.ts"' <<<"$F1")]" "$EXP" | tr ' ' ,)"
  R="$R otherwords=$(score_of "[$(jq -c '.summary = "The heading wording is vague"' <<<"$F1")]" "$EXP" | tr ' ' ,)"
  R="$R prefixed=$(score_of "[$(jq -c '.file = "./src/a.ts"' <<<"$F1")]" "$EXP" | tr ' ' ,)"
  R="$R nit=$(score_of "[$FN]" "$EXP" | tr ' ' ,)"
}
case_run() { # a whole run: recall, false findings, calls, cost on the result line, hermetic gh
  fresh
  local out rc=0; out=$(ev run --set "$SET" --jobs 1 2>&1) || rc=$?
  R="rc=$rc calls=$(calls) gh=$([ -s "$GH_LOG" ] && echo some || echo none)"
  R="$R line=$(printf '%s\n' "$out" | grep -c '^review-eval: run — recall 1/2 (50%), false findings 3, errors 0 · cost \$3.5 · fingerprint ')"
  R="$R tsv=$(cut -f2-6,9 "$REVIEW_EVAL_DIR/runs.tsv" 2>/dev/null | tr '\t' ,)"
}
case_cap() { # a set past 20 items is refused before any model call
  fresh
  jq --argjson a "$(item e1 src/a.ts 40 s)" '.items = [range(0; 21) as $k | $a | .id = "x\($k)"]' "$SET" > "$FIX/big.json"
  # A runner that answers nothing keeps a lifted cap cheap to prove: the refusal is what is read.
  local out rc=0; out=$(DRIVER_CLAUDE=/usr/bin/false ev run --set "$FIX/big.json" 2>&1) || rc=$?
  R="rc=$rc calls=$(calls) said=$(printf '%s' "$out" | grep -c 'the cap is 20')"
}
# A scratch harness repo for the triggers: the review brief, its schema, its code, a brief
# that is not the review's, and a consuming project's harness.json.
TR="$FIX/triggers"
mkdir -p "$TR/briefs/schemas" "$TR/driver/steps" "$TR/.claude"
git -C "$TR" init -q -b main; git -C "$TR" config user.email t@example.invalid; git -C "$TR" config user.name Tester
for f in briefs/review.md briefs/review-check.md briefs/schemas/review.json briefs/plan.md driver/steps/review.sh driver/steps/fix.sh; do echo v1 > "$TR/$f"; done
# Written beside it and copied in: the project's settings file is a fixture here, never edited in place.
HJ="$TR/.claude/harness"".json"
echo '{"review": {"effort": "high", "eval": {"weekday": 0}}, "gates": {"lint": "x"}}' > "$FIX/h.json"; cp "$FIX/h.json" "$HJ"
git -C "$TR" add -A; git -C "$TR" commit -qm base; TB=$(git -C "$TR" rev-parse HEAD)
trig() { # <path> [harness.json] — a branch changing that path; prints needs' exit code
  git -C "$TR" checkout -q -B "c$RANDOM" "$TB"
  if [ -n "${2:-}" ]; then printf '%s\n' "$2" > "$FIX/h.json"; cp "$FIX/h.json" "$HJ"; else echo v2 >> "$TR/$1"; fi
  git -C "$TR" add -A; git -C "$TR" commit -qm change
  local rc=0; ev needs --repo "$TR" --base "$TB" >/dev/null 2>&1 || rc=$?; printf '%s' "$rc"
}
case_trigger() { # what owes a comparison, and what does not
  R="brief=$(trig briefs/review.md) check-brief=$(trig briefs/review-check.md) schema=$(trig briefs/schemas/review.json)"
  R="$R step=$(trig driver/steps/review.sh) plan=$(trig briefs/plan.md) fix=$(trig driver/steps/fix.sh)"
  R="$R effort=$(trig x '{"review": {"effort": "max", "eval": {"weekday": 0}}, "gates": {"lint": "x"}}')"
  R="$R evalonly=$(trig x '{"review": {"effort": "high", "eval": {"weekday": 3}}, "gates": {"lint": "x"}}')"
  R="$R gates=$(trig x '{"review": {"effort": "high", "eval": {"weekday": 0}}, "gates": {"lint": "y"}}')"
}
guard() { # <path> <body> — the CI guard's exit code on a branch changing that path
  git -C "$TR" checkout -q -B "g$RANDOM" "$TB"; echo v2 >> "$TR/$1"; git -C "$TR" add -A; git -C "$TR" commit -qm change
  printf '%s' "$2" > "$FIX/body.md"
  local rc=0; ev guard --repo "$TR" --base "$TB" --body-file "$FIX/body.md" >/dev/null 2>&1 || rc=$?; printf '%s' "$rc"
}
case_guard() { # CI: a review change carries a comparison that is not worse; nothing else owes one
  R="none=$(guard briefs/review.md 'no line') better=$(guard briefs/review.md $'Summary\nreview-eval: compare before recall 5/20, false 9 (reused) → after recall 6/20, false 9 (ran) · better · cost $36.4')"
  R="$R worse=$(guard briefs/review.md 'review-eval: compare before recall 6/20, false 9 (ran) → after recall 5/20, false 9 (ran) · worse · cost $72')"
  R="$R unrelated=$(guard briefs/plan.md 'no line')"
}
case_weekly() { # the schedule: one weekday, one hour; and the run skips inside six days
  local p cron n wd
  p=$(bash "$KIT/swarm/install.sh" --print review-eval 2>&1)
  n=$(printf '%s' "$p" | grep -c '<dict><key>Weekday</key><integer>[0-6]</integer><key>Hour</key><integer>[0-9]*</integer><key>Minute</key>')
  wd=$(printf '%s' "$p" | grep -c '<dict>.*<key>Hour</key>')
  printf '#!/usr/bin/env bash\ncase "${1:-}" in -l) cat "%s" 2>/dev/null ;; -) cat > "%s" ;; esac\n' "$FIX/crontab" "$FIX/crontab" > "$BIN/crontab"; chmod +x "$BIN/crontab"
  : > "$FIX/crontab"
  SWARM_UNAME=Linux SWARM_CRONTAB="$BIN/crontab" bash "$KIT/swarm/install.sh" review-eval >/dev/null 2>&1
  cron=$(grep 'review-eval.sh' "$FIX/crontab" | awk '{print $3 "," $4 "," $5}')
  R="plist-weekly=$n wakes=$wd interval=$(printf '%s' "$p" | grep -c 'StartInterval<') cron=$cron"
  # The run: a full run two days ago skips (no call, $0); eight days ago runs.
  fresh; mkdir -p "$REVIEW_EVAL_DIR"
  printf '%s\tweekly\t1\t2\t3\t3.5\tfp\tsha\tok\tf.json\n' "$(( $(date +%s) - 2 * 86400 ))" > "$REVIEW_EVAL_DIR/runs.tsv"
  local out; out=$(ev weekly --set "$SET" --jobs 1 2>&1)
  R="$R recent=$(calls),$(printf '%s' "$out" | grep -c 'skipped.*cost \$0')"
  printf '%s\tweekly\t1\t2\t3\t3.5\tfp\tsha\tok\tf.json\n' "$(( $(date +%s) - 8 * 86400 ))" > "$REVIEW_EVAL_DIR/runs.tsv"
  : > "$CLAUDE_LOG"; out=$(ev weekly --set "$SET" --jobs 1 2>&1)
  R="$R stale=$(calls),$(printf '%s' "$out" | grep -c '^review-eval: weekly — recall .* · cost \$')"
}
result() { # <label> <hits> <false> <fingerprint> <set sha> — a result already on file
  local f="$REVIEW_EVAL_DIR/$1.json"
  jq -n --arg l "$1" --argjson h "$2" --argjson x "$3" --arg fp "$4" '{label: $l, hits: $h, of: 2, falseFindings: $x, cost: 3.5, fingerprint: $fp, complete: true, errors: 0}' > "$f"
  printf '%s\t%s\t%s\t2\t%s\t3.5\t%s\t%s\tok\t%s\n' "$(date +%s)" "$1" "$2" "$3" "$4" "$5" "$f" >> "$REVIEW_EVAL_DIR/runs.tsv"
}
fp_of() { # <kit> — the fingerprint, read the way the runner reads it
  HARNESS_CFG="$HARNESS_CFG_PATH" bash -c '. "$1/scripts/review-eval.sh" >/dev/null 2>&1; re_fingerprint "$2"' _ "$KIT" "$1" 2>/dev/null
}
case_compare() { # before and after: each side reused when already scored, the verdict off the scores
  fresh; mkdir -p "$REVIEW_EVAL_DIR"
  rm -rf "$FIX/basekit"; cp -R "$KIT" "$FIX/basekit"; echo "an older line" >> "$FIX/basekit/briefs/review.md"
  local sha out rc
  sha=$(git hash-object "$SET")
  result before 1 3 "$(fp_of "$FIX/basekit")" "$sha"; result after 1 1 "$(fp_of "$KIT")" "$sha"
  rc=0; out=$(ev compare --base-kit "$FIX/basekit" --set "$SET" 2>&1) || rc=$?
  R="better=$rc,$(calls),$(printf '%s' "$out" | grep -c 'recall 1/2, false 3 (reused) → after recall 1/2, false 1 (reused) · better · cost \$0$')"
  : > "$REVIEW_EVAL_DIR/runs.tsv"; result before 1 1 "$(fp_of "$FIX/basekit")" "$sha"; result after 0 0 "$(fp_of "$KIT")" "$sha"
  rc=0; out=$(ev compare --base-kit "$FIX/basekit" --set "$SET" 2>&1) || rc=$?
  R="$R worse=$rc,$(printf '%s' "$out" | grep -c '· worse ·')"
  # A side with no result is run, and its cost counted.
  : > "$REVIEW_EVAL_DIR/runs.tsv"; result before 1 3 "$(fp_of "$FIX/basekit")" "$sha"; : > "$CLAUDE_LOG"
  rc=0; out=$(ev compare --base-kit "$FIX/basekit" --set "$SET" --jobs 1 2>&1) || rc=$?
  R="$R ran=$rc,$(calls),$(printf '%s' "$out" | grep -c '(reused) → after recall 1/2, false 3 (ran) · same · cost \$3.5$')"
}

case_noise() { # each finding's outcome per week, read back from what the review and fix steps wrote
  local nd="$FIX/noise" now; now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  rm -rf "$nd"; mkdir -p "$nd/801/steps"
  printf '%s    review: hunter found 3, check kept 2 (dropped 1)\n%s    review: 2 nit(s) dropped — style and cleanup never block\n%s    review: 1 pre-existing finding(s) to the nightly sweep — not this change'"'"'s, and never a ticket\n' "$now" "$now" "$now" > "$nd/801/log"
  printf '%s\n' '{"id":"F1","file":"a.ts","grade":"major"}' '{"id":"F2","file":"a.ts","grade":"minor"}' '{"id":"F3","file":"b.ts","grade":"minor"}' > "$nd/801/steps/review.posted.jsonl"
  echo '{"cleared":[{"blockerId":"F1"}],"deferred":[{"blockerId":"F2","reason":"r"}]}' > "$nd/801/steps/fix.json"
  : > "$CLAUDE_LOG"
  R="$(DRIVER_DIR="$nd" ev noise --weeks 2 2>&1 | tail -1 | awk '{print "found=" $2, "notreal=" $3, "nit=" $4, "pre=" $5, "repeat=" $6, "fixed=" $7, "deferred=" $8, "unfixed=" $9}') calls=$(calls)"
}

kit_copy
case_noise;   want "the unplanted kit: noise, from the ledgers alone" \
  "found=3 notreal=1 nit=2 pre=1 repeat=0 fixed=1 deferred=1 unfixed=1 calls=0" "$R"
case_score;   want "the unplanted kit: the scoring match" \
  "near=true,1,0 far=false,1,1 otherfile=false,1,1 otherwords=false,1,1 prefixed=true,1,0 nit=false,0,0" "$R"
case_run;     want "the unplanted kit: a run scores, costs and says so" \
  "rc=0 calls=4 gh=none line=1 tsv=run,1,2,3,3.5,ok" "$R"
case_cap;     want "the unplanted kit: 21 items are refused unpaid" "rc=2 calls=0 said=1" "$R"
case_trigger; want "the unplanted kit: what owes a comparison" \
  "brief=0 check-brief=0 schema=0 step=0 plan=1 fix=1 effort=0 evalonly=1 gates=1" "$R"
case_guard;   want "the unplanted kit: the CI guard" "none=1 better=0 worse=1 unrelated=0" "$R"
case_weekly;  want "the unplanted kit: at most weekly" \
  "plist-weekly=1 wakes=1 interval=0 cron=*,*,0 recent=0,1 stale=4,1" "$R"
case_compare; want "the unplanted kit: before and after" "better=0,0,1 worse=1,1 ran=0,4,1" "$R"

# The result file the run wrote is the record a later comparison reuses.
case_run
res=$(cut -f10 "$REVIEW_EVAL_DIR/runs.tsv")
want "the result file keeps each item's kept findings, by line" "45 2" "$(jq -r '.items[] | select(.id == "e1") | [.findings[].line] | join(" ")' "$res" 2>/dev/null)"
want "and the run's totals"                                    "1/2 3 3.5 true" "$(jq -r '"\(.hits)/\(.of) \(.falseFindings) \(.cost) \(.complete)"' "$res" 2>/dev/null)"

# plant <label> <file under the kit> <exact text> <replacement> <case> <the result the line prevents>
plant() {
  kit_copy
  python3 -I -c 'import sys; p, l, r = sys.argv[1], sys.argv[2], sys.argv[3]; s = open(p).read(); n = s.count(l); open(p, "w").write(s.replace(l, r, 1)); sys.exit(0 if n == 1 else 1)' "$KIT/$2" "$3" "$4" \
    || { want "plant landed: $1" "landed" "missed"; return; }
  "$5"; want "planted ($1): the case now fails" "$6" "$R"
}
plant "the line window is dropped" scripts/review-eval.sh \
  '| if . < 0 then -. else . end) <= $win' '| if . < 0 then -. else . end) <= 100000' case_score \
  "near=true,1,0 far=true,1,0 otherfile=false,1,1 otherwords=false,1,1 prefixed=true,1,0 nit=false,0,0"
plant "a nit counts as kept" scripts/review-eval.sh \
  'select(type == "object" and (.grade // "") != "nit" and (.tag // "") != "nit")' 'select(type == "object")' case_score \
  "near=true,1,0 far=false,1,1 otherfile=false,1,1 otherwords=false,1,1 prefixed=true,1,0 nit=true,1,0"
plant "the cost leaves the result line" scripts/review-eval.sh \
  ' · cost $\(.cost) · fingerprint' ' · fingerprint' case_run \
  "rc=0 calls=4 gh=none line=0 tsv=run,1,2,3,3.5,ok"
plant "the eval reads GitHub" scripts/review-eval.sh \
  'export PATH="$run/bin:$PATH" SWARM_GH="$run/bin/gh"' ':' case_run \
  "rc=0 calls=4 gh=some line=1 tsv=run,1,2,3,3.5,ok"
plant "the item cap is lifted" scripts/review-eval.sh \
  'RE_MAX_ITEMS=20' 'RE_MAX_ITEMS=200' case_cap "rc=0 calls=0 said=0"
plant "the review brief no longer triggers" scripts/review-eval.sh \
  "RE_PATHS='^(briefs/review[^/]*|" "RE_PATHS='^(" case_trigger \
  "brief=1 check-brief=1 schema=0 step=0 plan=1 fix=1 effort=0 evalonly=1 gates=1"
plant "a settings change no longer triggers" scripts/review-eval.sh \
  "    [ \"\$a\" = \"\$b\" ] || why=" "    true || why=" case_trigger \
  "brief=0 check-brief=0 schema=0 step=0 plan=1 fix=1 effort=1 evalonly=1 gates=1"
plant "the guard reads no comparison" scripts/review-eval.sh \
  '  if [ -z "$line" ]; then' '  if false; then' case_guard "none=0 better=0 worse=1 unrelated=0"
plant "a worse score passes the guard" scripts/review-eval.sh \
  '    *"· worse"*) echo' '    *"never"*) echo' case_guard "none=1 better=0 worse=0 unrelated=0"
plant "the weekly job loses its weekday" swarm/install.sh \
  '[ "$wd" = - ] || w="<key>Weekday</key><integer>$wd</integer>"' ':' case_weekly \
  "plist-weekly=0 wakes=1 interval=0 cron=*,*,0 recent=0,1 stale=4,1"
plant "the weekly crontab runs every day" swarm/install.sh \
  '* * ${wd:-*}"' '* * *"' case_weekly \
  "plist-weekly=1 wakes=1 interval=0 cron=*,*,* recent=0,1 stale=4,1"
plant "the weekly run never skips" scripts/review-eval.sh \
  '-lt $((min * 86400)) ]; then' '-lt 0 ]; then' case_weekly \
  "plist-weekly=1 wakes=1 interval=0 cron=*,*,0 recent=4,0 stale=4,1"
plant "a side already scored is run again" scripts/review-eval.sh \
  '    if after=$(re_reuse "$fpa" "$sha"); then ahow="reused"' '    if false; then ahow="reused"' case_compare \
  "better=0,4,0 worse=1,1 ran=0,4,1"
plant "the check's drops are not read" scripts/review-eval.sh \
  '\1 found \2\n\1 notreal \4/p' '\1 found \2/p' case_noise \
  "found=3 notreal=0 nit=2 pre=1 repeat=0 fixed=1 deferred=1 unfixed=1 calls=0"
plant "a fixed finding reads as not fixed" scripts/review-eval.sh \
  'if ([$f.cleared[]?.blockerId] | index($p.id)) != null' 'if false' case_noise \
  "found=3 notreal=1 nit=2 pre=1 repeat=0 fixed=0 deferred=1 unfixed=2 calls=0"
plant "a worse comparison exits 0" scripts/review-eval.sh \
  '    [ "$v" != worse ] )' '    true )' case_compare "better=0,0,1 worse=0,1 ran=0,4,1"

suite_end "$FAILED"
