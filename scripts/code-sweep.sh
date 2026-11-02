#!/usr/bin/env bash
# code-sweep.sh — the nightly sweep of code that has already landed. One area of the
# repo a night, read by a review agent; each class of copied defect it proves becomes
# ONE ticket carrying the fix at the source (a shared helper, a lint rule, a hook),
# never one ticket per instance, never a second ticket for an open class, never more
# than sweep.maxTickets in a night. 187 finding tickets were filed in one day before.
#
#   code-sweep.sh                 shadow: sweep tonight's area, print what it would file
#   code-sweep.sh --file          and file it (CODE_SWEEP_SHADOW=0 means the same)
#   code-sweep.sh --force         again tonight, busy machine or not
#   code-sweep.sh --area <path>   this folder ("<dir>/*" its own files, "*" the root's);
#                                 the rotation does not move
#   code-sweep.sh --areas         print the areas it rotates through, and stop
#
# Installed by `swarm/install.sh code-sweep`: launchd wakes it each hour of the night
# window; the first wake on an idle machine sweeps, the rest find the night done.
#
# The night, in order — anything that fails stops it with the rotation unmoved:
#   1. the rotation: sweep.areas by name, else the trunk's code files in path order,
#      about sweep.maxAreaFiles a night, each run starting after the last file read.
#      Either way an area or a file added or removed never stalls it.
#   2. the open tickets: the sweep's own (sweep.labels[0]) by the body marker
#      <!-- sweep-class: <key> -->, the ones closed as not planned (never refiled),
#      and every open title for the agent to check against. A failed read is unknown,
#      never "none": nothing is filed that night.
#   3. the reviewer's pre-existing queue, $STATE_DIR/review/pre-existing.jsonl, one
#      JSON finding a line, read from where the last filing night stopped. No file is
#      an empty queue. A file shorter than that point was rotated: read from its start.
#   4. the agent (agent-harness:code-sweeper) in a detached tree of origin/<trunk>,
#      writing tools refused, under a turn cap and sweep.timeoutMin.
#   5. its answer, held to the contract: a slug key, a title, a source fix, at least
#      sweep.minInstances instances. Prose or a cut-off answer exits 2.
#   6. each class: open → a recount comment when the count moved; closed not planned
#      or covered by another open ticket → left; else filed, until the cap.
#   7. only then the rotation, the night and the queue point move.
#
# Every gh call runs under SWEEP_GH_TIMEOUT seconds and the agent under the sweep's
# limit: a hung call once stopped the coordinator for two hours.
#
# Config (harness.json `sweep`, all optional): areas, maxAreaFiles (400), extensions,
# minInstances (3), maxTickets (3), labels (["sweep:class"]), turns (80),
# timeoutMin (45), minCpuIdle (50), maxQueue (40), budgetUsd (none).
# Seams: SWEEP_CLAUDE, SWARM_GH, SWEEP_TIMEOUT_SEC, SWEEP_GH_TIMEOUT, SWEEP_QUEUE.
# Exit: 0 swept or nothing to do · 1 a read or write failed · 2 the answer broke the
# contract, or usage · 124 the agent ran past its limit.
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SELF_DIR/../swarm/swarm-env.sh" || exit 1

say() { echo "code-sweep: $*"; }
die() { echo "code-sweep: $*" >&2; exit "${2:-1}"; }

FILE=0 FORCE=0 AREA="" LIST=0
[ "${CODE_SWEEP_SHADOW:-1}" = 0 ] && FILE=1
while [ $# -gt 0 ]; do
  case "$1" in
    --file) FILE=1 ;;
    --force) FORCE=1 ;;
    --area) AREA="${2:?--area needs a path}"; shift ;;
    --areas) LIST=1 ;;
    *) die "usage: code-sweep.sh [--file] [--force] [--area <path>] [--areas]" 2 ;;
  esac
  shift
done

opt() { swarm_opt "sweep.$1" "$2"; }
num() { case "$1" in ''|*[!0-9]*) printf '%s' "$2" ;; *) printf '%s' "$1" ;; esac; }
MIN=$(num "$(opt minInstances 3)" 3)
CAP=$(num "$(opt maxTickets 3)" 3)
MAXF=$(num "$(opt maxAreaFiles 400)" 400)
TURNS=$(num "$(opt turns 80)" 80)
IDLE_FLOOR=$(num "$(opt minCpuIdle 50)" 50)
MAXQ=$(num "$(opt maxQueue 40)" 40)
BUDGET=$(opt budgetUsd "")
LIMIT=$(num "${SWEEP_TIMEOUT_SEC:-$(( $(num "$(opt timeoutMin 45)" 45) * 60 ))}" 2700)
GH_LIMIT=$(num "${SWEEP_GH_TIMEOUT:-90}" 90)
LABELS=$(opt labels sweep:class)
LABEL=${LABELS%% *}
EXTS=$(opt extensions "ts tsx js jsx mjs cjs py sh rb go rs java kt swift php cs sql vue svelte")
TRUNK="origin/$INTEGRATION_BRANCH"
SD="$SWARM_DIR/code-sweep"
RUN="$SD/run"; TREE="$SD/tree"
QUEUE="${SWEEP_QUEUE:-$STATE_DIR/review/pre-existing.jsonl}"
mkdir -p "$SD" || die "cannot write $SD"
LOG="$SWARM_LOGS/code-sweep.log"
note() { swarm_log "$LOG" "$*"; say "$*"; }

# Every gh call through a time limit: the backoff wrapper calls this in gh's place.
REAL_GH="${SWARM_GH:-gh}"
mkdir -p "$RUN"
cat > "$RUN/gh-bounded" <<SH
#!/usr/bin/env bash
exec perl -e '\$t = shift; \$p = fork; die "fork" unless defined \$p;
  if (\$p == 0) { setpgrp(0, 0); exec @ARGV or exit 127 }
  \$SIG{ALRM} = sub { print STDERR "gh: no answer in \$t s, stopped\\n"; kill "TERM", -\$p; sleep 1; kill "KILL", -\$p; exit 124 };
  alarm \$t; waitpid(\$p, 0); exit(\$? & 127 ? 128 + (\$? & 127) : \$? >> 8)' $(printf '%q' "$GH_LIMIT") $(printf '%q' "$REAL_GH") "\$@"
SH
chmod +x "$RUN/gh-bounded"
SWARM_GH="$RUN/gh-bounded"; export SWARM_GH

# ---- 1. the rotation -----------------------------------------------------------
# Configured areas rotate by name. Without them the trunk's code files, in path order,
# are read in runs of about maxAreaFiles: a run ends at a folder's end when that is near
# (within half a run), and the next night starts after the last file read. So the whole
# repo is covered, files added anywhere join their place, and nothing stalls.
code_files() { # the trunk's code files, one path a line, in path order
  local re
  re=$(printf '%s\n' $EXTS | sed 's/[^A-Za-z0-9]//g' | grep . | paste -sd'|' -)
  git -C "$MAIN_REPO" ls-tree -r --name-only "$TRUNK" | grep -E "\.(${re})\$" | LC_ALL=C sort
}
chunk() { # <after-path> <all:0|1> — stdin: code files. The run after <after-path>, or every run
  LC_ALL=C awk -v c="$1" -v all="$2" -v m="$MAXF" '
    function dir(p,   d) { d = p; if (sub(/\/[^\/]*$/, "", d) == 0) d = ""; return d }
    function run_end(s,   e, x) {
      e = s + m - 1; if (e > n) e = n
      x = 0; while (e < n && x < m / 2 && dir(f[e + 1]) == dir(f[e])) { e++; x++ }
      return e
    }
    { f[++n] = $0 }
    END {
      if (n == 0) exit
      if (all == 1) { s = 1; while (s <= n) { e = run_end(s); print f[s] " .. " f[e]; s = e + 1 }; exit }
      s = 1; if (c != "") { for (s = 1; s <= n && f[s] <= c; s++) ; if (s > n) s = 1 }
      e = run_end(s); for (i = s; i <= e; i++) print f[i]
    }'
}
CONFIGURED=$(opt areas "")

GIT_TERMINAL_PROMPT=0 swarm_bounded "$GH_LIMIT" git -C "$MAIN_REPO" fetch -q origin \
  "+refs/heads/$INTEGRATION_BRANCH:refs/remotes/$TRUNK" >/dev/null 2>&1 \
  || say "could not fetch $TRUNK; sweeping the copy this clone has"
git -C "$MAIN_REPO" rev-parse -q --verify "$TRUNK^{commit}" >/dev/null 2>&1 || die "no $TRUNK in $MAIN_REPO"

if [ "$LIST" = 1 ]; then
  if [ -n "$CONFIGURED" ]; then printf '%s\n' $CONFIGURED | LC_ALL=C sort -u; else code_files | chunk "" 1; fi
  exit 0
fi

TODAY=$(date +%Y-%m-%d)
if [ "$FORCE" = 0 ] && [ -z "$AREA" ]; then
  if [ "$(cat "$SD/last-run" 2>/dev/null)" = "$TODAY" ]; then say "already swept tonight ($TODAY)"; exit 0; fi
  if held=$(swarm_held); then note "the swarm is held ($held): no sweep this wake"; exit 0; fi
  if swarm_usage_hold >/dev/null 2>&1; then note "the plan's usage is on hold: no sweep this wake"; exit 0; fi
  if reading=$(swarm_busy "$IDLE_FLOOR" "$SWARM_MAX_LOAD"); then note "machine busy ($reading): next wake"; exit 0; fi
fi

# Tonight's area: AREA (a label for people), FILES (its files), NEXT (the rotation's new line).
LAST=$(head -1 "$SD/last-area" 2>/dev/null)
NEXT="" FILES=""
if [ -n "$AREA" ]; then
  # A folder, "<dir>/*" for only the files directly in it, or "*" for the root's own files.
  FILES=$(git -C "$MAIN_REPO" ls-tree -r --name-only "$TRUNK" | awk -v a="$AREA" '
    a == "*" { if (index($0, "/") == 0) print; next }
    a ~ /\/\*$/ { d = substr(a, 1, length(a) - 1); if (index($0, d) == 1 && index(substr($0, length(d) + 1), "/") == 0) print; next }
    { d = a; sub(/\/$/, "", d); if ($0 == d || index($0, d "/") == 1) print }')
elif [ -n "$CONFIGURED" ]; then
  AREA=$(printf '%s\n' $CONFIGURED | LC_ALL=C sort -u | LC_ALL=C awk -v l="${LAST#area=}" \
    'NR == 1 { first = $0 } l != "" && $0 > l { print; found = 1; exit } END { if (!found) print first }')
  FILES=$(git -C "$MAIN_REPO" ls-tree -r --name-only "$TRUNK" -- "$AREA")
  NEXT="area=$AREA"
else
  case "$LAST" in file=*) LAST="${LAST#file=}" ;; *) LAST="" ;; esac
  FILES=$(code_files | chunk "$LAST" 0)
  [ -n "$FILES" ] || die "no areas: sweep.areas is unset and $TRUNK has no code files"
  AREA="$(printf '%s\n' "$FILES" | head -1) .. $(printf '%s\n' "$FILES" | tail -1)"
  NEXT="file=$(printf '%s\n' "$FILES" | tail -1)"
fi
[ -n "$FILES" ] || die "the area \`$AREA\` holds no files on $TRUNK"

# One sweep at a time: a second wake while one runs leaves it be.
LOCK="$SD/lock"
if ! mkdir "$LOCK" 2>/dev/null; then
  p=$(cat "$LOCK/pid" 2>/dev/null)
  if [ -n "$p" ] && kill -0 "$p" 2>/dev/null; then say "a sweep is already running (pid $p)"; exit 0; fi
  rm -rf "$LOCK"; mkdir "$LOCK" 2>/dev/null || die "cannot take $LOCK"
fi
echo $$ > "$LOCK/pid"
cleanup() {
  if [ -d "$TREE" ]; then git -C "$MAIN_REPO" worktree remove --force "$TREE" >/dev/null 2>&1 || rm -rf "$TREE"; fi
  git -C "$MAIN_REPO" worktree prune >/dev/null 2>&1
  rm -rf "$LOCK"
}
trap cleanup EXIT

# ---- 2. the open tickets -------------------------------------------------------
gh_read "the open sweep tickets" issue list --repo "$ISSUE_SLUG" --state open --label "$LABEL" \
  --limit 500 --json number,title,body > "$RUN/sweep-open.json" || die "nothing filed tonight"
gh_read "the sweep tickets closed" issue list --repo "$ISSUE_SLUG" --state closed --label "$LABEL" \
  --limit 500 --json number,body,stateReason > "$RUN/sweep-closed.json" || die "nothing filed tonight"
gh_read "the open tickets" issue list --repo "$ISSUE_SLUG" --state open --limit 2000 \
  --json number,title > "$RUN/all-open.json" || die "nothing filed tonight"
MARK_RE='<!-- sweep-class: (?<k>[a-z0-9-]+) -->'
jq -r --arg re "$MARK_RE" '.[] | ((.body // "") | capture($re)? | .k) as $k | select($k) | [$k, .number, .title] | @tsv' \
  "$RUN/sweep-open.json" > "$RUN/open-keys.tsv" || die "the open sweep tickets could not be read as JSON"
jq -r --arg re "$MARK_RE" '.[] | select((.stateReason // "") | ascii_upcase == "NOT_PLANNED") | ((.body // "") | capture($re)? | .k) // empty' \
  "$RUN/sweep-closed.json" > "$RUN/closed-keys.txt" || die "the closed sweep tickets could not be read as JSON"
jq -r '.[] | [.number, .title] | @tsv' "$RUN/all-open.json" > "$RUN/open-tickets.tsv" || die "the open tickets could not be read as JSON"

# ---- 3. the reviewer's pre-existing queue ---------------------------------------
OFF=$(num "$(cat "$SD/queue-offset" 2>/dev/null)" 0)
: > "$RUN/queue.jsonl"; QNEXT=$OFF
if [ -f "$QUEUE" ]; then
  size=$(wc -c < "$QUEUE" | tr -d ' ')
  [ "$size" -ge "$OFF" ] || OFF=0
  # Whole lines only, at most maxQueue: a line still being written waits for the next night.
  tail -c +"$(( OFF + 1 ))" "$QUEUE" > "$RUN/queue.raw"
  head -n "$MAXQ" "$RUN/queue.raw" > "$RUN/queue.jsonl"
  [ -z "$(tail -c 1 "$RUN/queue.jsonl")" ] || sed -i.bak '$d' "$RUN/queue.jsonl"
  QNEXT=$(( OFF + $(wc -c < "$RUN/queue.jsonl" | tr -d ' ') ))
fi

# ---- 4. the agent ----------------------------------------------------------------
if [ -d "$TREE" ]; then git -C "$MAIN_REPO" worktree remove --force "$TREE" >/dev/null 2>&1 || rm -rf "$TREE"; fi
git -C "$MAIN_REPO" worktree prune >/dev/null 2>&1
git -C "$MAIN_REPO" worktree add -q --detach "$TREE" "$TRUNK" >/dev/null 2>&1 || die "could not cut a tree of $TRUNK"
printf '%s\n' "$FILES" > "$RUN/area-files.txt"
{
  echo "Sweep of $(git -C "$TREE" rev-parse --short HEAD) on $TRUNK, $TODAY."
  echo
  echo "Your area: \`$AREA\` ($(grep -c . "$RUN/area-files.txt") files, listed in $RUN/area-files.txt)."
  echo "Minimum instances for a class (min): $MIN. Report at most $(( CAP * 2 )) classes."
  echo "Open tickets, number and title: $RUN/open-tickets.tsv"
  echo
  echo "Classes already open (key, ticket, title):"
  if [ -s "$RUN/open-keys.tsv" ]; then sed 's/^/- /' "$RUN/open-keys.tsv"; else echo "- none"; fi
  if [ -s "$RUN/closed-keys.txt" ]; then echo; echo "Classes the owner closed as not planned (never report these):"; sed 's/^/- /' "$RUN/closed-keys.txt"; fi
  echo
  if [ -s "$RUN/queue.jsonl" ]; then
    echo "Pre-existing findings reviewers queued for you (one JSON object a line):"
    cat "$RUN/queue.jsonl"
  else
    echo "Pre-existing findings: none."
  fi
  echo
  echo "End with the JSON answer only."
} > "$RUN/prompt.md"

CLAUDE_BIN="${SWEEP_CLAUDE:-claude}"
set -- -p --agent "${SWEEP_AGENT:-agent-harness:code-sweeper}" --max-turns "$TURNS" \
  --permission-mode "${SWEEP_PERMISSION_MODE:-${COORDINATOR_PERMISSION_MODE:-auto}}" \
  --disallowed-tools Edit Write NotebookEdit --add-dir "$RUN" --output-format text
[ -n "$BUDGET" ] && set -- "$@" --max-budget-usd "$BUDGET"
note "sweeping \`$AREA\` ($(grep -c . "$RUN/area-files.txt") files, $(grep -c . "$RUN/queue.jsonl") queued findings, $([ "$FILE" = 1 ] && echo filing || echo shadow))"
rc=0
(cd "$TREE" && swarm_bounded "$LIMIT" "$CLAUDE_BIN" "$@" < "$RUN/prompt.md") > "$RUN/answer" 2> "$RUN/claude.err" || rc=$?
[ "$rc" = 124 ] && { note "the agent ran past ${LIMIT}s and was stopped; the night is not marked swept"; exit 124; }
[ "$rc" = 0 ] || die "the agent failed (exit $rc): $(head -1 "$RUN/claude.err" 2>/dev/null)"

# ---- 5. the answer, held to its contract ---------------------------------------------
if grep -q '^[[:space:]]*```json' "$RUN/answer"; then
  sed -n '/^[[:space:]]*```json/,/^[[:space:]]*```[[:space:]]*$/p' "$RUN/answer" | sed '1d;$d' > "$RUN/answer.json"
else
  cp "$RUN/answer" "$RUN/answer.json"
fi
jq -e '.classes | type == "array"' "$RUN/answer.json" >/dev/null 2>&1 \
  || die "the agent's answer is not the JSON contract ({\"classes\": [...]}); nothing filed: $(head -c 200 "$RUN/answer" | tr '\n' ' ')" 2
jq -c --argjson min "$MIN" '
  .classes[] | . as $c
  | (if (.key | type) != "string" or (.key | test("^[a-z0-9][a-z0-9-]{2,59}$") | not) then "a key that is not a slug"
     elif ((.title // "") | type) != "string" or (.title // "") == "" then "no title"
     elif ((.sourceFix // "") | type) != "string" or (.sourceFix // "") == "" then "no source fix"
     elif ((.instances // []) | type) != "array" or ((.instances // []) | length) < $min then "\((.instances // []) | length) instances, under \($min)"
     else "" end) as $why
  | if $why == "" then {ok: true, c: ($c | .count = ([(.count // 0), (.instances | length)] | max))}
    else {ok: false, key: ($c.key // "?" | tostring), why: $why} end' "$RUN/answer.json" > "$RUN/checked.jsonl" \
  || die "the agent's answer is not the JSON contract; nothing filed" 2
while IFS= read -r l; do
  say "dropped $(jq -r '.key' <<<"$l"): $(jq -r '.why' <<<"$l")"
done < <(jq -c 'select(.ok | not)' "$RUN/checked.jsonl")
# One key twice in one answer is one class: the first, in the agent's order of harm.
jq -c 'select(.ok) | .c' "$RUN/checked.jsonl" \
  | jq -sc 'reduce .[] as $c ([]; if any(.[]; .key == $c.key) then . else . + [$c] end) | .[]' > "$RUN/classes.jsonl"

# ---- 6. each class ----------------------------------------------------------------
body() { # <class json> → the ticket body
  jq -r --arg area "$AREA" --arg day "$TODAY" '
    "## Why\n\(.why // "")\n\n## The class\n\(.count) places in the repo repeat this (found sweeping `\($area)`). One ticket for the whole class: fix it once at the source, never place by place.\n\n## Fix at the source\n\(.sourceFix)\n\n## Stop the next copy\n\(.guard // "Name the lint rule, hook or check that refuses a new copy.")\n\n## Instances (\(.instances | length) of \(.count))\n" + ([.instances[:50][] | "- `\(.)`"] | join("\n")) + "\n\nFiled by the nightly code sweep, \($day).\n\n<!-- sweep-class: \(.key) -->"' <<<"$1"
}
COUNTS="$SD/counts.tsv"; touch "$COUNTS"
filed=0 held_over="" failed=0
while IFS= read -r c; do
  key=$(jq -r '.key' <<<"$c"); title=$(jq -r '.title | .[:120]' <<<"$c"); count=$(jq -r '.count' <<<"$c")
  existing=$(jq -r '.existing // empty | tostring' <<<"$c")
  open=$(awk -F'\t' -v k="$key" '$1 == k { print $2; exit }' "$RUN/open-keys.tsv")
  if [ -n "$open" ]; then
    was=$(awk -F'\t' -v k="$key" '$1 == k { v = $2 } END { print v }' "$COUNTS")
    if [ "$was" = "$count" ]; then say "$key: #$open already owns it, still $count"; continue; fi
    if [ "$FILE" = 1 ]; then
      gh_call issue comment "$open" --repo "$ISSUE_SLUG" --body "Nightly code sweep, $TODAY: $count places now (was ${was:-not counted}), found sweeping \`$AREA\`." >/dev/null \
        || { failed=1; say "$key: the recount on #$open failed"; break; }
      printf '%s\t%s\n' "$key" "$count" >> "$COUNTS"
    fi
    say "$key: #$open owns it; recounted $count"
    continue
  fi
  if grep -qxF "$key" "$RUN/closed-keys.txt" 2>/dev/null; then say "$key: closed as not planned; left"; continue; fi
  if [ -n "$existing" ] && grep -q "^$existing	" "$RUN/open-tickets.tsv"; then say "$key: open ticket #$existing already covers it; left"; continue; fi
  if [ "$filed" -ge "$CAP" ]; then held_over="$held_over $key"; continue; fi
  body "$c" > "$RUN/body-$key.md"
  if [ "$FILE" = 1 ]; then
    lab=(); for l in $LABELS; do lab+=(--label "$l"); done
    url=$(gh_call issue create --repo "$ISSUE_SLUG" --title "$title" --body-file "$RUN/body-$key.md" "${lab[@]}") \
      || { failed=1; say "$key: filing failed"; break; }
    printf '%s\t%s\n' "$key" "$count" >> "$COUNTS"
    say "filed $key ($count places): $url"
  else
    say "would file $key ($count places): $title"
  fi
  filed=$(( filed + 1 ))
done < "$RUN/classes.jsonl"
[ -z "$held_over" ] || say "over tonight's cap of $CAP, found again on a later night:$held_over"
[ "$failed" = 0 ] || die "a GitHub write failed; the rotation stays on \`$LAST\`"

# ---- 7. the night is done ---------------------------------------------------------
[ -z "$NEXT" ] || printf '%s\n' "$NEXT" > "$SD/last-area"
[ "$FORCE" = 1 ] || printf '%s\n' "$TODAY" > "$SD/last-run"
[ "$FILE" = 1 ] && printf '%s\n' "$QNEXT" > "$SD/queue-offset"
note "swept \`$AREA\`: $filed $([ "$FILE" = 1 ] && echo filed || echo 'would be filed'), $(grep -c . "$RUN/classes.jsonl") classes found"
exit 0
