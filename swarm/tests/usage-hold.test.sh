#!/usr/bin/env bash
# usage-hold.test.sh — the plan's usage hold reads only the CLI's own limit
# signals in a builder's log: a rejected rate_limit_event, or the CLI's error text.
# The same sentence quoted inside a tool result or a reply holds nothing. Every
# hold names its source. Then the plant: delete the exclusion and the quote holds.
# Run: bash "$0"
set -uo pipefail
for v in $(env | sed -n 's/^\(GIT_[A-Za-z_]*\)=.*/\1/p'); do unset "$v"; done
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/fixture.sh"
swarm_fixture; trap 'rm -rf "$FIX"' EXIT
FAILED=0
KIT="$HERE/../.."
LOG="$STATE/logs/claim-12554-20261016T092222Z-1.log"
SOON=$(( $(date +%s) + 7200 ))

hold()   { bash -c '. "$1/swarm/swarm-env.sh" >/dev/null || exit 9; swarm_usage_hold' _ "${1:-$KIT}"; }
source_of() { bash -c '. "$1/swarm/swarm-env.sh" >/dev/null || exit 9; swarm_usage_hold_source' _ "${1:-$KIT}"; }

# The shape measured on 2026-10-16: a builder ran `gh run view --log` and the CI
# log quoted the design critic's own account limit. The builder was never limited.
quoted_log() {
  local q="the critic's account has no capacity left right now… You've hit your weekly limit · resets Oct 20 at 9pm (Europe/London)"
  {
    printf '{"type":"rate_limit_event","rate_limit_info":{"status":"allowed","resetsAt":%s,"rateLimitType":"five_hour"}}\n' "$SOON"
    jq -nc --arg q "$q" '{type:"user",message:{role:"user",content:[{type:"tool_result",tool_use_id:"t1",content:("Code gates\tUNKNOWN STEP\t" + $q)}]}}'
    jq -nc --arg q "$q" '{type:"assistant",message:{model:"claude-opus",role:"assistant",content:[{type:"text",text:("CI says: " + $q)}]}}'
    jq -nc '{type:"result",is_error:false,result:"Done: PR is green apart from the design check."}'
  } > "$LOG"
}

echo "--- a quoted limit is not a wall ---"
quoted_log
if u=$(hold); then bad "a quoted sentence held: $u"; else ok "a tool result quoting the weekly limit holds nothing"; fi

echo "--- the CLI's own signals hold, and name their line ---"
quoted_log
printf '{"type":"rate_limit_event","rate_limit_info":{"status":"rejected","resetsAt":%s,"rateLimitType":"seven_day"}}\n' "$SOON" >> "$LOG"
u=$(hold) && ok "a rejected event with a future reset holds" || bad "a rejected event held nothing"
want_in "it holds until the event's reset" "seven_day window" "$u"
want "the source is the event and its line" "rate-limit event, $(basename "$LOG") line 5" "$(source_of)"

quoted_log
jq -nc '{type:"result",is_error:true,result:"You have hit your weekly limit · resets Oct 20 at 9pm (Europe/London)"}' >> "$LOG"
u=$(hold) && ok "the CLI's own error text holds" || bad "the CLI's own error text held nothing"
want "a dated wall holds on its time" "9pm" "$u"
want "the source is the error text and its line" "CLI error text, $(basename "$LOG") line 5" "$(source_of)"

printf '%s\tYou have hit your session limit\n' "$SOON" > "$STATE/usage-hold"
want_in "a window's record names the file and its words" "^file $STATE/usage-hold: You have hit your session limit" "$(source_of)"
rm -f "$STATE/usage-hold"

echo "--- plant: delete the exclusion and the quote holds ---"
P="$FIX/kit"; mkdir -p "$P"; cp -R "$KIT/swarm" "$KIT/scripts" "$P/"
python3 - "$P/swarm/swarm-env.sh" <<'PY' || bad "plant did not land"
import sys, re
p = sys.argv[1]; s = open(p).read()
a = s.index("swarm_usage_cli_events() { # <log>\n")
b = s.index("\n}\n", a)
n = s[:a] + "swarm_usage_cli_events() { # <log>\n  grep -n . \"$1\" | sed -E 's/^([0-9]+):/\\1\\terror\\t/'" + s[b:]
if n == s or "fromjson" in n[a:a + 200]: sys.exit(1)
open(p, "w").write(n)
PY
grep -q "fromjson" "$P/swarm/swarm-env.sh" && bad "plant: the exclusion is still in the copy"
quoted_log
if u=$(hold "$P"); then ok "planted: every line read as the CLI's → the quote holds ($u) → red"; else bad "planted: the exclusion deleted and the quote still holds nothing → the test cannot see it"; fi

exit $FAILED
