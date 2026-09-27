#!/usr/bin/env bash
# report.sh — one answer to "what is the swarm doing, and what is stuck".
#
#   report.sh            one screen, for a person
#   report.sh --json     the same thing as JSON, redacted, ready to send
#   report.sh --push     send that JSON to swarm.reportUrl
#
# This is the one reporter. It replaces three scripts that each answered part of
# the question and disagreed: a status screen that read the run records, a
# watcher that tailed them for events, and a pusher that scraped the logs a
# second time to decide what was stuck. Three derivations of one state is three
# chances to be wrong about it, and the pusher's copy was the one on the public
# page.
#
# NOTHING LEAVES THIS MACHINE THAT A PERSON HAS NOT ALREADY SEEN. --json and
# --push emit the same shape the screen draws: a ticket number, a title, a
# programme, how long, and the step labels. Never a command, never its output,
# never a raw log line. Anything token-shaped is replaced, and a step whose text
# is a bare shell command becomes "Running a command in its workspace" — the
# description is the label, and a step with no description is not one.
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/swarm-env.sh" || exit 1

MODE=screen
case "${1:-}" in
  --json) MODE=json ;;
  --push) MODE=push ;;
  -h|--help) sed -n '2,25p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
  "") ;;
  *) echo "report: unknown argument '$1'" >&2; exit 2 ;;
esac

QUIET_SEC="${SWARM_QUIET_SEC:-$(swarm_opt swarm.quietSec 1200)}"
SECRET_FILE="${SWARM_REPORT_SECRET_FILE:-$SWARM_DIR/report-secret}"

# ---- what is stuck, from the logs the swarm itself wrote ---------------------
# Each line is "<kind>\t<detail>". The two logs are the swarm's own, written by
# the scheduler and the repair watcher in this same directory; no other script
# is scraped, and no log text is carried through — only these sentences.
stuck_lines() {
  local last stops silent
  last=$(tail -1 "$SWARM_LOGS/scheduler.log" 2>/dev/null)
  case "$last" in
    *"usage limit — holding until"*) printf 'holding\tthe plan'"'"'s usage limit, until %s\n' "${last##*until }" ;;
    *"above"*"— holding")            printf 'holding\tthe machine'"'"'s load is above the ceiling\n' ;;
    *"— holding")                    printf 'holding\tevery slot is full\n' ;;
  esac
  stops=$(grep "^$(swarm_day)" "$SWARM_LOGS/repair-watch.log" 2>/dev/null \
            | grep -oE 'STOP #[0-9]+' | sort -u | grep -c . | tr -d ' ')
  [ "${stops:-0}" -gt 0 ] && printf 'stopped\t%s fix(es) stopped after 3 repairs today — a person must look\n' "$stops"
  silent=$(swarm_snapshot | jq -r --argjson q "$QUIET_SEC" \
    '.live[]? | select(.quietSec > $q) | "silent\tno activity for \(.quietSec/60|floor) min on #\(.ticket)"' 2>/dev/null)
  [ -n "$silent" ] && printf '%s\n' "$silent"
  [ -n "$(swarm_snapshot)" ] || printf 'blind\tthe live view %s, so the count is unknown\n' "$(swarm_snapshot_why)"
  return 0
}

# ---- the shape that may leave this machine ----------------------------------
# A step's text is a LABEL. When it is a bare shell command it had no label, and
# a command is exactly what must not travel, so it is replaced rather than
# trimmed. The redaction below is the second fence, not the first.
REDACT='
  def scrub: tostring
    | gsub("github_pat_[A-Za-z0-9_]{20,}"; "[redacted]")
    | gsub("gh[pousr]_[A-Za-z0-9]{20,}"; "[redacted]")
    | gsub("sk-ant-[A-Za-z0-9_-]{10,}"; "[redacted]")
    | gsub("sk-[A-Za-z0-9_-]{16,}"; "[redacted]")
    | gsub("AKIA[0-9A-Z]{16}"; "[redacted]")
    | gsub("xox[abposr]-[A-Za-z0-9-]{10,}"; "[redacted]")
    | gsub("eyJ[A-Za-z0-9_-]{5,}\\.[A-Za-z0-9_-]{5,}\\.[A-Za-z0-9_-]{5,}"; "[redacted]")
    | gsub("[0-9a-fA-F]{32,}"; "[redacted]");
  def command_shaped:
    test("^(cd|git|gh|npm|npx|pnpm|yarn|node|bun|deno|tsx|python3?|pip|bash|sh|zsh|curl|wget|ls|cat|head|tail|grep|rg|sed|awk|find|echo|printf|rm|mkdir|cp|mv|touch|chmod|jq|docker|psql|make|wc|sort|uniq|diff|export|set|source|env|sleep|kill|pkill|ps|lsof|timeout|xargs|test|for|if|while|until)(\\s|$)")
    or test("^[.~]?/") or test("&&|\\|\\||\\s\\|\\s|\\$\\(");
  def step_label: if (.kind != "say") and ((.text // "") | command_shaped)
             then "Running a command in its workspace" else (.text // "") end;
'

report_json() {
  local snap queued
  snap=$(swarm_snapshot); [ -n "$snap" ] || snap='{"live":[],"done":[]}'
  queued=$(awk -F'\t' 'NF>=3{print $3"\t"$2}' "$SWARM_DIR/queue.tsv" 2>/dev/null \
             | jq -R 'split("\t") | {ticket: .[0], project: .[1]}' | jq -s '.')
  printf '%s' "$snap" | jq --argjson queued "${queued:-[]}" \
    --arg at "$(swarm_stamp)" --slurpfile stuck <(stuck_lines | jq -R 'split("\t") | {kind: .[0], detail: .[1]}') "
    $REDACT
    {
      at: \$at,
      live: [.live[]? | {
        ticket: (.ticket | tostring), title: (.title | scrub), short: ((.short // .title) | scrub),
        project: (.project // \"\"),
        startedAgoMin: .startedAgoMin, quietSec: .quietSec,
        steps: [.steps[]? | {kind: (if .kind == \"say\" then \"say\" else \"do\" end), text: (step_label | scrub)}],
        progress: .progress
      }],
      plans: [.plans[]? | {id, name: (.name | scrub), pct, done, jobs, working, unestimated}],
      queued: \$queued,
      stuck: [\$stuck[]? | {kind: .kind, detail: (.detail | scrub)}]
    }"
}

case "$MODE" in
  json) report_json; exit 0 ;;
  push)
    [ -n "$SWARM_REPORT_URL" ] || { echo "report: no swarm.reportUrl — nothing to push to"; exit 0; }
    [ -s "$SECRET_FILE" ] || { echo "report: no secret at $SECRET_FILE — refusing to push unauthenticated" >&2; exit 1; }
    body=$(report_json)
    swarm_curl -sS -m 8 -X POST "$SWARM_REPORT_URL" \
      -H 'content-type: application/json' -H "x-swarm-secret: $(cat "$SECRET_FILE")" \
      --data-binary "$body" >/dev/null && echo "pushed to $SWARM_REPORT_URL"
    exit $?
    ;;
esac

# ---- the screen --------------------------------------------------------------
J=$(report_json)
printf 'load %s · %s running · %s queued\n' "$(swarm_load)" \
  "$(printf '%s' "$J" | jq '.live | length')" "$(printf '%s' "$J" | jq '.queued | length')"

printf '%s' "$J" | jq -r '
  if (.live | length) == 0 then "\n  nothing running"
  else "\n" + ([.live[] |
    "  #\(.ticket)  \(.title)"
    + "\n      \(.project // "—") · running \(.startedAgoMin) min · last active \(.quietSec // "?")s ago"
    + (if .progress then "\n      step \(.progress.step) of \(.progress.of): \(.progress.steps[(.progress.step - 1)].name)"
         + (if (.progress.unreadable | length) > 0 then " · cannot read: \(.progress.unreadable | join(", "))" else "" end)
       else "" end)
    + ((.steps | map(select(.kind == "do")) | last) as $doing
       | if $doing then "\n      now: \($doing.text)" else "" end)
  ] | join("\n")) end'

printf '%s' "$J" | jq -r '
  if (.queued | length) == 0 then "" else
    "\nwaiting\n" + ([.queued[] | "  #\(.ticket)  \(.project // "—")"] | join("\n")) end'

printf '%s' "$J" | jq -r '
  if (.stuck | length) == 0 then "\nnothing stuck" else
    "\nstuck\n" + ([.stuck[] | "  \(.kind): \(.detail)"] | join("\n")) end'
