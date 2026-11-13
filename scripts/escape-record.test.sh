#!/usr/bin/env bash
# escape-record.test.sh — a merged change that is reverted, or that a person marks broken on
# UAT, gets ONE record naming the check that should have caught it and ONE ticket to that
# check; never twice, never for a machine's own issue, never for a layer outside the five or
# a fix that only names a screen, never more than escapes.perPass a pass, nothing in shadow.
# Run: bash "$0"
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/tests/lib/suite.sh" || exit 1
for v in $(env | sed -n 's/^\(GIT_[A-Z_]*\)=.*/\1/p'); do unset "$v"; done
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../swarm/tests/fixture.sh"
swarm_fixture
on_exit_keep_status 'rm -rf "$FIX"'
FAILED=0
S="$HERE/escape-record.sh"
LEDGER="$STATE/swarm/escapes.jsonl"

cp "$HARNESS_CFG_PATH" "$FIX/cfg.json"; export HARNESS_CFG_PATH="$FIX/cfg.json"
cfg() { jq "$1" "$FIX/cfg.json" > "$FIX/cfg.next" && mv "$FIX/cfg.next" "$FIX/cfg.json"; }

# ---- stand-ins: gh and claude, each answering from files and recording the ask ------------
cat > "$BIN/gh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_LOG"
case "$1 $2" in
  "api graphql") cat "$FIX/gh/reverts.json" ;;
  "issue list")
    case "$*" in
      *"--label broken-on-uat"*) cat "$FIX/gh/uat.json" ;;
      *"--label escaped-layer"*) cat "$FIX/gh/filed.json" ;;
      *) echo '[]' ;;
    esac ;;
  "pr view")
    [ -f "$FIX/gh/pr-$3.json" ] || { echo "HTTP 404: Not Found" >&2; exit 1; }
    cat "$FIX/gh/pr-$3.json" ;;
  "issue create")
    n=$(( 9000 + $(ls "$FIX/bodies" | grep -c '\.md$') ))
    prev=""; for a in "$@"; do [ "$prev" = --body-file ] && cp "$a" "$FIX/bodies/$n.md"; prev="$a"; done
    printf '%s\n' "$*" > "$FIX/bodies/$n.args"
    echo "https://github.com/acme/widgets/issues/$n" ;;
  "label create") echo ok ;;
  *) echo '{}' ;;
esac
SH
cat > "$BIN/claude" <<'SH'
#!/usr/bin/env bash
n=$(( $(ls "$FIX/calls" 2>/dev/null | wc -l) + 1 )); mkdir -p "$FIX/calls"
{ echo "args=$*"; echo "---"; cat; } > "$FIX/calls/$n"
cat "$FIX/answer"
SH
chmod +x "$BIN/gh" "$BIN/claude"
export ESCAPE_CLAUDE="$BIN/claude" ESCAPE_TIMEOUT_SEC=20

pr() { # <n> <title> [compare line] [mergedAt] — a merged PR's view
  jq -nc --argjson n "$1" --arg t "$2" --arg b "${3:-Change tier: screen — new screen. Picture, compare, CI evidence, design critic and sign-off apply.}" \
    '{number:$n, title:$t, body:$b, state:"MERGED", mergedAt:"2026-11-10T10:00:00Z",
      files:[{path:"app/voices/page.tsx"}], reviews:[{state:"APPROVED", author:{login:"rev"}}],
      statusCheckRollup:[{name:"build", conclusion:"SUCCESS"}], comments:[]}' > "$FIX/gh/pr-$1.json"
}
reverts() { # <json array of {number,title,body}>
  jq -c '{data:{search:{pageInfo:{hasNextPage:false}, nodes:[.[] | . + {mergedAt:"2026-11-12T10:00:00Z"}]}}}' <<<"$1" > "$FIX/gh/reverts.json"
}
answer() { # <layer> [fix file]
  jq -nc --arg l "$1" --arg f "${2:-scripts/critic-judge.sh}" \
    '{layer:$l, check:"hold a screen change that carries no proof shots", why:"Compare was off and no shots were taken, so nothing looked at the page.", fix:"Refuse a screen change whose PR has no proof screenshots.", fixFiles:[$f]}' > "$FIX/answer"
}
run() { bash "$S" scan > "$FIX/out" 2>&1; echo $?; }
creates() { grep -c '^issue create' "$GH_LOG"; }
calls() { ls "$FIX/calls" 2>/dev/null | wc -l | tr -d ' '; }
rows() { if [ -f "$LEDGER" ]; then grep -c . "$LEDGER"; else echo 0; fi; }
reset() { : > "$GH_LOG"; rm -rf "$FIX/calls" "$FIX/bodies" "$LEDGER"; mkdir -p "$FIX/bodies"; }
check() { # <name> <want> <got>
  if [ "$2" = "$3" ]; then echo "  ok   $1"; else echo "  FAIL $1 — want '$2', got '$3'"; sed 's/^/       | /' "$FIX/out"; FAILED=1; fi
}

blank() { reverts '[]'; echo '[]' > "$FIX/gh/uat.json"; echo '[]' > "$FIX/gh/filed.json"; }
export COORDINATOR_SHADOW=0

if suite_case "a merged revert yields one record and one issue to the layer's check, once, never twice"; then
  reset; blank
  pr 700 "Voices screen" "Change tier: screen, existing screen — x. Baseline route: CI diffs its shots. No picture, compare or design critic."
  reverts '[{"number":701,"title":"Revert \"#701 Voices screen\"","body":"This reverts PR #700: the Voices screen shipped broken."}]'
  answer picture
  check "the scan exits 0" 0 "$(run)"
  check "one record" 1 "$(rows)"
  check "the record names PR 700" 700 "$(jq -r '.pr' "$LEDGER" 2>/dev/null)"
  check "its cause is revert" revert "$(jq -r '.cause' "$LEDGER" 2>/dev/null)"
  check "its layer is the model's" picture "$(jq -r '.layer' "$LEDGER" 2>/dev/null)"
  check "it carries the PR's compare state" off "$(jq -r '.facts.compare' "$LEDGER" 2>/dev/null)"
  check "it carries the proof shot count" 0 "$(jq -r '.facts.screenshots' "$LEDGER" 2>/dev/null)"
  check "one issue opened" 1 "$(creates)"
  args=$(cat "$FIX"/bodies/*.args 2>/dev/null)
  case "$args" in *"--title compare step: "*) t=yes ;; *) t=no ;; esac
  check "the title names the layer's check" yes "$t"
  case "$args" in *"--label escaped-layer"*) t=yes ;; *) t=no ;; esac
  check "labelled escaped-layer" yes "$t"
  grep -q '#700' "$FIX"/bodies/*.md 2>/dev/null && grep -q 'Compare was off' "$FIX"/bodies/*.md && t=yes || t=no
  check "the body names PR #700 and why the layer missed it" yes "$t"
  grep -q '^label create escaped-layer' "$GH_LOG" && t=yes || t=no
  check "the label is created on first use" yes "$t"
  check "a second scan exits 0" 0 "$(run)"
  check "still one record" 1 "$(rows)"
  check "still one issue" 1 "$(creates)"
  check "the model was asked once" 1 "$(calls)"
fi

if suite_case "a revert of a commit that is no merged PR is not counted"; then
  reset; blank
  reverts '[{"number":705,"title":"Revert \"design verdict\"","body":"This reverts commit abc1234."}]'
  answer picture
  run >/dev/null
  check "no record" 0 "$(rows)"
  check "no issue" 0 "$(creates)"
fi

if suite_case "a person's broken-on-uat issue naming a merged PR yields a record with cause uat; the machine's does not"; then
  reset; blank
  pr 700 "Voices screen"; pr 702 "Ideas screen"
  jq -nc '[{number:900, title:"Voices is blank on UAT", body:"Broken since #700 merged.", author:{login:"dom", is_bot:false}},
           {number:901, title:"Ideas is blank on UAT", body:"Broken since #702 merged.", author:{login:"harness-bot[bot]", is_bot:true}}]' > "$FIX/gh/uat.json"
  answer review
  run >/dev/null
  check "one record" 1 "$(rows)"
  check "it is #700's" 700 "$(jq -r '.pr' "$LEDGER" 2>/dev/null)"
  check "its cause is uat" uat "$(jq -r '.cause' "$LEDGER" 2>/dev/null)"
  check "one issue" 1 "$(creates)"
fi

if suite_case "a layer outside the five, or a fix naming only a screen file, opens no issue and records unjudged"; then
  reset; blank
  pr 700 "Voices screen"
  reverts '[{"number":701,"title":"Revert \"Voices\"","body":"Reverts acme/widgets#700"}]'
  answer taste
  run >/dev/null
  check "a record" 1 "$(rows)"
  check "it is unjudged" unjudged "$(jq -r '.verdict' "$LEDGER" 2>/dev/null)"
  check "no issue for a layer outside the five" 0 "$(creates)"
  reset; blank
  pr 700 "Voices screen"
  reverts '[{"number":701,"title":"Revert \"Voices\"","body":"Reverts acme/widgets#700"}]'
  answer picture app/voices/page.tsx
  run >/dev/null
  check "a record for the screen-only fix" 1 "$(rows)"
  check "it is unjudged" unjudged "$(jq -r '.verdict' "$LEDGER" 2>/dev/null)"
  check "no issue for a screen-only fix" 0 "$(creates)"
fi

if suite_case "at most escapes.perPass are judged a pass; the rest wait"; then
  reset; blank
  for n in 710 711 712 713 714; do pr "$n" "Screen $n"; done
  reverts "$(jq -nc '[range(710; 715) | {number: (. + 100), title: "Revert \"x\"", body: "Reverts acme/widgets#\(.)"}]')"
  answer ci
  run >/dev/null
  check "three judged the first pass" 3 "$(calls)"
  check "three records" 3 "$(rows)"
  run >/dev/null
  check "the other two the next" 5 "$(rows)"
  cfg '.escapes = {perPass: 1}'; reset
  run >/dev/null
  check "perPass 1 judges one" 1 "$(rows)"
  cfg 'del(.escapes)'
fi

if suite_case "shadow writes nothing and opens nothing"; then
  reset; blank
  pr 700 "Voices screen"
  reverts '[{"number":701,"title":"Revert \"Voices\"","body":"Reverts acme/widgets#700"}]'
  answer picture
  COORDINATOR_SHADOW=1 bash "$S" scan > "$FIX/out" 2>&1
  check "no record" 0 "$(rows)"
  [ -e "$LEDGER" ] && t=written || t=absent
  check "the ledger is not even made" absent "$t"
  check "no issue" 0 "$(creates)"
  check "no model call" 0 "$(calls)"
  grep -q 'would judge #700' "$FIX/out" && t=yes || t=no
  check "it says what it would judge" yes "$t"
fi

if suite_case "finding-class weekly prints an escapes row per layer"; then
  reset; blank
  now=$(date +%s)
  wk=$(date -u -r "$now" +%G-W%V 2>/dev/null || date -u -d "@$now" +%G-W%V)
  jq -nc --arg w "$wk" '{pr:700, cause:"revert", layer:"picture", verdict:"judged", week:$w}, {pr:702, cause:"uat", layer:"ci", verdict:"judged", week:$w}' > "$LEDGER"
  out=$(FINDING_CLASS_LEDGER="$STATE/swarm/finding-classes.jsonl" FINDING_CLASS_SHARE=off DEVELOP_RED_COUNT=off \
        bash "$HERE/finding-class.sh" weekly 2>&1)
  printf '%s\n' "$out" | grep -qE '^escape:picture +escape( +0)* +1( |$)' && t=yes || t=no
  check "a picture row" yes "$t"
  printf '%s\n' "$out" | grep -qE '^escape:ci +escape( +0)* +1( |$)' && t=yes || t=no
  check "a ci row" yes "$t"
fi

suite_end "$FAILED"
