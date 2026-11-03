#!/usr/bin/env bash
# review-eval.sh — the review step scored against a fixed set of past breakages, and
# its noise read back from the ledgers it already writes. A change to review is kept
# only when its score does not go down (Anthropic's practice for its own reviewer).
#
#   review-eval.sh run      [--set F] [--label L] [--jobs N] [--kit DIR]
#                           each item: its base and head in a scratch worktree, the review
#                           step's own hunter and check on that diff, scored. One dated
#                           result file, one summary line naming the run's cost.
#   review-eval.sh compare  (--base REF | --base-kit DIR) [--set F] [--jobs N]
#                           before and after, for a change to the review step. A side whose
#                           fingerprint already has a complete result is reused, not re-run.
#                           Exit 1 when the score went down.
#   review-eval.sh weekly   the scheduled run (swarm/install.sh review-eval): skipped when
#                           any full run finished in the last review.eval.minDays (6) days.
#   review-eval.sh needs    --base REF [--head REF] [--repo DIR] — 0 (and why) when the range
#                           changes the review step's brief, schema or code, or review.*
#                           settings in .claude/harness.json; 1 when it does not.
#   review-eval.sh guard    --base REF [--head REF] [--body-file F] — CI: a change that needs
#                           a comparison carries its `review-eval: compare` line in the PR
#                           body, and that line is not `worse`. No model call.
#   review-eval.sh noise    [--weeks N] — each finding's outcome per week, from the driver's
#                           own logs and ledgers. No model call.
#   review-eval.sh score    <answer.json> <expect.json> — one item's score (the runner's own).
#
# USAGE IS BOUNDED (the PM, 2026-11-03: "waste is the brake"). At most 20 items; one item is
# one review, the hunter plus the check (~$1.82), so a full run is ~$36. It runs when the
# review step's brief, schema, effort or settings change, and weekly; never daily.
#
# THE SET IS THE PROJECT'S, not the kit's: review.eval.set in harness.json (default
# .claude/review-eval.json), read from the trunk. Each item:
#   {id, pr, title, base, head, source, expect: {file, line, summary}}
#
# THE MATCH is the old vote tally's (_driver_review_tally, replaced 2026-11-03): same file
# (or one path ending in the other), a summary sharing at least 30% of the shorter one's
# words of four letters or more, and the line within review.eval.lineWindow (10).
set -uo pipefail

RE_SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
RE_KIT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# What changes the review: the paths a comparison is owed for, and the settings key.
RE_PATHS='^(briefs/review[^/]*|briefs/schemas/review[^/]*|driver/steps/review\.sh)$'
RE_MAX_ITEMS=20

re_die() { echo "review-eval: $*" >&2; exit 2; }

# ---- the match --------------------------------------------------------------------
# jq definitions: kept(answer) — the findings a review keeps (not a nit), and
# hit($f; $e; $win) — the tally's match.
RE_JQ='
def ws: ascii_downcase | [scan("[a-z0-9]+") | select(length >= 4)] | unique;
def overlap($a; $b): ($a | ws) as $x | ($b | ws) as $y
  | if ($x | length) == 0 or ($y | length) == 0 then 0
    else ([$x[] | . as $w | select($y | index($w))] | length) / ([($x | length), ($y | length)] | min) end;
def samefile($a; $b): ($a | sub("^\\./"; "") | sub(":[0-9]+$"; "")) as $x | ($b | sub("^\\./"; "")) as $y
  | $x == $y or ($x | endswith("/" + $y)) or ($y | endswith("/" + $x));
def kept: [(.findings // [])[] | select(type == "object" and (.grade // "") != "nit" and (.tag // "") != "nit")];
def hit($f; $e; $win):
  samefile($f.file // "" | tostring; $e.file // "" | tostring)
  and ((($f.line // 0) - ($e.line // 0)) | if . < 0 then -. else . end) <= $win
  and overlap($f.summary // "" | tostring; $e.summary // "" | tostring) >= 0.3;
'

# re_score <answer.json> <expect.json> [window] — {hit, kept, false}: a hit when a kept
# finding matches; every kept finding that does not match is a false finding.
re_score() {
  local win="${3:-${RE_WINDOW:-10}}"
  jq -c --slurpfile e "$2" --argjson win "$win" "$RE_JQ"'
    ($e[0]) as $x | kept as $k
    | [$k[] | select(hit(.; $x; $win))] as $m
    | {hit: (($m | length) > 0), kept: ($k | length), false: (($k | length) - ($m | length))}' "$1"
}

# ---- what changes the review --------------------------------------------------------
# re_needs <repo> <base> <head> — prints one reason a line, 0 when a comparison is owed.
re_needs() {
  local repo="$1" base="$2" head="$3" files why="" a b
  files=$(git -C "$repo" diff --name-only "$base...$head" 2>/dev/null) || { echo "review-eval: cannot diff $base...$head in $repo" >&2; return 2; }
  why=$(printf '%s\n' "$files" | grep -E "$RE_PATHS" | sed 's/^/changes /')
  if printf '%s\n' "$files" | grep -qx '.claude/harness.json'; then
    a=$(git -C "$repo" show "$(git -C "$repo" merge-base "$base" "$head"):.claude/harness.json" 2>/dev/null | jq -cS '(.review // {}) | del(.eval)' 2>/dev/null)
    b=$(git -C "$repo" show "$head:.claude/harness.json" 2>/dev/null | jq -cS '(.review // {}) | del(.eval)' 2>/dev/null)
    [ "$a" = "$b" ] || why="${why:+$why
}changes the review.* settings in .claude/harness.json"
  fi
  [ -n "$why" ] || return 1
  printf '%s\n' "$why"
}

re_cmd_needs() {
  local repo="." base="" head="HEAD"
  while [ $# -gt 0 ]; do
    case "$1" in
      --repo) repo="$2"; shift 2 ;; --base) base="$2"; shift 2 ;; --head) head="$2"; shift 2 ;;
      *) re_die "needs: unknown argument $1" ;;
    esac
  done
  [ -n "$base" ] || re_die "needs: --base is required"
  re_needs "$repo" "$base" "$head"
}

# guard: the CI seat. The comparison itself runs where the plan's login is (never on a
# hosted runner); CI only refuses a review change that does not carry its result.
re_cmd_guard() {
  local repo="." base="" head="HEAD" bodyf="" body why rc line
  while [ $# -gt 0 ]; do
    case "$1" in
      --repo) repo="$2"; shift 2 ;; --base) base="$2"; shift 2 ;; --head) head="$2"; shift 2 ;;
      --body-file) bodyf="$2"; shift 2 ;;
      *) re_die "guard: unknown argument $1" ;;
    esac
  done
  [ -n "$base" ] || re_die "guard: --base is required"
  rc=0; why=$(re_needs "$repo" "$base" "$head") || rc=$?
  [ "$rc" -ne 2 ] || return 2
  if [ "$rc" -ne 0 ]; then echo "review-eval guard: no review change — no comparison owed"; return 0; fi
  if [ -n "$bodyf" ]; then body=$(cat "$bodyf" 2>/dev/null)
  elif [ -n "${GITHUB_EVENT_PATH:-}" ] && [ -f "$GITHUB_EVENT_PATH" ]; then body=$(jq -r '.pull_request.body // ""' "$GITHUB_EVENT_PATH" 2>/dev/null)
  else body=""; fi
  line=$(printf '%s\n' "$body" | grep -E '^review-eval: compare ' | tail -1)
  if [ -z "$line" ]; then
    echo "review-eval guard: this change $(printf '%s' "$why" | head -3 | tr '\n' ';' | sed 's/;$//; s/;/; /g'), so it owes a before-and-after score."
    echo "  Run: bash scripts/review-eval.sh compare --base <this PR's base>   (about \$36, once; a side already scored is reused)"
    echo "  Then put the line it prints, starting 'review-eval: compare', in the PR body and re-run this check."
    return 1
  fi
  case "$line" in
    *"· worse"*) echo "review-eval guard: the comparison says the score went down — a change to review is kept only if its score does not:"; echo "  $line"; return 1 ;;
  esac
  echo "review-eval guard: comparison carried — $line"
}

# ---- the environment a model run needs ------------------------------------------------
re_env() { # the driver's environment, for the kit at $1
  local kit="$1"
  export KIT_ROOT="$kit" DRIVER_BRIEFS="$kit/briefs" DRIVER_SCHEMAS="$kit/briefs/schemas" DRIVER_VALIDATE="$kit/briefs/validate.sh"
  unset DRIVER_HOME HARNESS_KIT_ROOT
  # shellcheck disable=SC1091
  . "$kit/driver/driver-env.sh" || return 1
  declare -F driver_state_init >/dev/null || . "$kit/driver/state.sh" || return 1
  . "$kit/driver/steps/review.sh" || return 1
}

re_now() { printf '%s' "${REVIEW_EVAL_NOW:-$(date +%s)}"; }
re_dir() { printf '%s' "${REVIEW_EVAL_DIR:-$STATE_DIR/review-eval}"; }
re_opt() { local v; v=$(toolkit_cfg "review.eval.$1" 2>/dev/null) || v=""; printf '%s' "${v:-$2}"; }

# re_fingerprint <kit> — the review step as configured: its brief, schema and code in
# that kit, and this project's review.* settings (review.eval aside).
re_fingerprint() {
  local kit="$1" f
  { for f in $(cd "$kit" && ls -d briefs/review* briefs/schemas/review* driver/steps/review.sh 2>/dev/null | sort); do
      printf '== %s\n' "$f"; cat "$kit/$f"
    done
    printf '== settings\n'; jq -cS '(.review // {}) | del(.eval)' "${HARNESS_CFG:-/dev/null}" 2>/dev/null
  } | git hash-object --stdin | cut -c1-12
}

# re_set <out> [file] — the eval set, from --set or the trunk; refused past the cap.
re_set() {
  local out="$1" file="${2:-}" p n
  if [ -n "$file" ]; then cp "$file" "$out" 2>/dev/null || re_die "no eval set at $file"
  else
    p=$(re_opt set .claude/review-eval.json)
    if [ -f "$MAIN_REPO/$p" ]; then cp "$MAIN_REPO/$p" "$out"
    else git -C "$MAIN_REPO" show "origin/$INTEGRATION_BRANCH:$p" > "$out" 2>/dev/null \
      || git -C "$MAIN_REPO" show "$INTEGRATION_BRANCH:$p" > "$out" 2>/dev/null \
      || re_die "no eval set: $p is not on $INTEGRATION_BRANCH in $MAIN_REPO (review.eval.set)"
    fi
  fi
  n=$(jq '[.items[]? | select(.base and .head and .expect.file)] | length' "$out" 2>/dev/null) || re_die "the eval set is not JSON"
  [ "$(jq '.items | length' "$out")" = "$n" ] || re_die "every item needs base, head and expect.file"
  [ "$n" -gt 0 ] || re_die "the eval set has no items"
  [ "$n" -le "$RE_MAX_ITEMS" ] || re_die "the eval set holds $n items; the cap is $RE_MAX_ITEMS (one review each, ~\$1.82)"
}

# re_item <run dir> <item json> — one review of one past change. Writes items/<id>.json.
# Runs in a subshell of its own: the driver's functions and state are per-item.
re_item() {
  local run="$1" item="$2" id base head t wt d diff cap bytes effort rc spend out
  id=$(jq -r .id <<<"$item")
  base=$(jq -r .base <<<"$item"); head=$(jq -r .head <<<"$item")
  t="eval-$id"; wt="$run/trees/$id"; out="$run/items/$id.json"
  export DRIVER_TICKET="$t"
  driver_state_init "$t" --worktree "$wt" >/dev/null
  d="$(driver_state_dir "$t")/steps"; mkdir -p "$d"
  # The ask is the change's own title: the ticket it was built from is not the eval's.
  export DRIVER_TICKET_SNAP_RUN="review-eval-$id"
  jq -n --argjson i "$item" '{number: 0, state: "CLOSED", labels: [],
      title: ("#\($i.pr // "?") \($i.title // "a past change")"),
      body: "A past change, reviewed as it was merged. Judge the diff on its own."}' > "$(driver_ticket_snap_file "$t")"
  printf '%s\n' "$DRIVER_TICKET_SNAP_RUN" > "$(driver_ticket_snap_file "$t").open"
  diff=$(git -C "$wt" diff "$base" "$head" 2>/dev/null)
  cap=$(driver_opt review.diffBytes 400000); case "$cap" in ''|*[!0-9]*|0) cap=400000 ;; esac
  bytes=$(LC_ALL=C printf '%s' "$diff" | wc -c | tr -d ' ')
  if [ "${bytes:-0}" -gt "$cap" ]; then
    diff="$(LC_ALL=C printf '%s' "$diff" | LC_ALL=C head -c "$cap")

[TRUNCATED at $cap bytes of $bytes. Read the rest in the worktree — do NOT review the part above as if it were the whole change.]"
  fi
  effort=$(driver_opt review.effort high)
  case "$effort" in low|medium|high|xhigh|max) : ;; *) effort=high ;; esac
  driver_fact_put "$t" review DIFF "${diff:-(none)}"
  driver_fact_put "$t" review EFFORT "$effort"
  driver_fact_put "$t" review TARGET "$base"
  driver_fact_put "$t" review RENDERS "(none — this run took no renders, so judge no screen from them)"
  driver_fact_put "$t" review ROUND 1
  rc=0; _driver_review_hunt "$t" "$run/none" "$effort" >> "$run/log" 2>&1 || rc=$?
  [ "$rc" -ne 0 ] || _driver_review_check "$t" "$d/review.json" >> "$run/log" 2>&1 || rc=$?
  spend=$(jq -r '.spend // 0' "$(driver_state_dir "$t")/state.json" 2>/dev/null); spend=${spend:-0}
  if [ "$rc" -eq 0 ] && [ -s "$d/review.json" ]; then
    jq -c --argjson i "$item" --argjson s "$(re_score "$d/review.json" <(jq -c .expect <<<"$item"))" --argjson c "$spend" "$RE_JQ"'
      {id: $i.id, pr: $i.pr, rc: 0, cost: $c} + $s
      + {findings: [kept[] | {file, line, grade, tag, summary}]}' "$d/review.json" > "$out"
  else
    jq -nc --argjson i "$item" --argjson rc "$rc" --argjson c "$spend" \
      '{id: $i.id, pr: $i.pr, rc: $rc, cost: $c, hit: false, kept: 0, false: 0, findings: []}' > "$out"
  fi
}

# re_run <kit> <set.json> <label> <jobs> — every item, then one result file and one line.
# Prints the result file's path on fd 3 when it is open.
re_run() {
  local kit="$1" set="$2" label="$3" jobs="$4" run stamp n i k item id base head fp rc=0 res line
  stamp=$(date -u -r "$(re_now)" +%Y-%m-%dT%H%M%SZ 2>/dev/null || date -u -d "@$(re_now)" +%Y-%m-%dT%H%M%SZ)
  mkdir -p "$(re_dir)"
  run="$(re_dir)/runs/$stamp-$label"; while [ -e "$run" ]; do run="${run}x"; done
  mkdir -p "$run/items" "$run/trees" "$run/driver"
  export DRIVER_DIR="$run/driver" REVIEW_EVAL_RUN="$run"
  # Hermetic: no read of the change's own ticket, PR or comments reaches the reviewer.
  mkdir -p "$run/bin"
  cat > "$run/bin/gh" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in "api "*) echo '[]' ;; "pr list"|"issue list") echo '[]' ;; *) echo "gh is off during a review eval" >&2; exit 1 ;; esac
SH
  chmod +x "$run/bin/gh"
  export PATH="$run/bin:$PATH" SWARM_GH="$run/bin/gh"
  fp=$(re_fingerprint "$kit")
  n=$(jq '.items | length' "$set")
  # Worktrees first, one at a time: git locks its worktree list.
  for ((i = 0; i < n; i++)); do
    item=$(jq -c --argjson i "$i" '.items[$i]' "$set"); id=$(jq -r .id <<<"$item")
    base=$(jq -r .base <<<"$item"); head=$(jq -r .head <<<"$item")
    git -C "$MAIN_REPO" cat-file -e "$head^{commit}" 2>/dev/null && git -C "$MAIN_REPO" cat-file -e "$base^{commit}" 2>/dev/null \
      || driver_bounded 300 "git -C '$MAIN_REPO' fetch -q origin $base $head" >/dev/null 2>&1 || true
    git -C "$MAIN_REPO" worktree add -q --detach "$run/trees/$id" "$head" >/dev/null 2>&1 \
      || { echo "review-eval: $id — $head does not check out in $MAIN_REPO" >> "$run/log"; }
  done
  # Then the reviews, at most <jobs> at once.
  for ((i = 0; i < n; i += jobs)); do
    for ((k = i; k < i + jobs && k < n; k++)); do
      item=$(jq -c --argjson i "$k" '.items[$i]' "$set")
      ( re_item "$run" "$item" ) &
    done
    wait
    # The plan's usage limit stops the run: the rest would each fail the same way.
    if jq -s -e 'any(.[]; .rc == 27)' "$run"/items/*.json >/dev/null 2>&1; then
      echo "review-eval: stopped at the plan's usage limit after $((k)) of $n items" >> "$run/log"; rc=27; break
    fi
  done
  for ((i = 0; i < n; i++)); do
    id=$(jq -r --argjson i "$i" '.items[$i].id' "$set")
    git -C "$MAIN_REPO" worktree remove --force "$run/trees/$id" >/dev/null 2>&1 || true
  done
  git -C "$MAIN_REPO" worktree prune >/dev/null 2>&1 || true
  res="$(re_dir)/$(basename "$run").json"
  jq -s --arg at "$stamp" --arg label "$label" --arg fp "$fp" --arg setsha "$(git hash-object "$set")" \
     --argjson n "$n" --arg kit "$(jq -r '.version // "?"' "$kit/.claude-plugin/plugin.json" 2>/dev/null)" \
     --arg effort "$(driver_opt review.effort high)" --arg check "$(driver_opt review.checkEffort medium)" '
    {version: 1, at: $at, label: $label, kit: $kit, fingerprint: $fp, set: $setsha,
     effort: $effort, checkEffort: $check, items: .,
     of: $n, hits: ([.[] | select(.hit)] | length), falseFindings: ([.[].false] | add // 0),
     errors: ([.[] | select(.rc != 0)] | length), complete: (length == $n),
     cost: (([.[].cost] | add // 0) * 100 | round / 100)}' "$run"/items/*.json > "$res" 2>/dev/null \
    || jq -n --arg at "$stamp" --arg label "$label" --arg fp "$fp" --argjson n "$n" \
         '{version: 1, at: $at, label: $label, fingerprint: $fp, items: [], of: $n, hits: 0, falseFindings: 0, errors: $n, complete: false, cost: 0}' > "$res"
  line=$(jq -r '"review-eval: \(.label) — recall \(.hits)/\(.of) (\((.hits * 100 / .of) | floor)%), false findings \(.falseFindings), errors \(.errors)\(if .complete then "" else ", INCOMPLETE" end) · cost $\(.cost) · fingerprint \(.fingerprint)"' "$res")
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$(re_now)" "$label" \
    "$(jq -r .hits "$res")" "$n" "$(jq -r .falseFindings "$res")" "$(jq -r .cost "$res")" \
    "$fp" "$(jq -r '.set // ""' "$res")" "$(jq -r 'if .complete and .errors == 0 then "ok" else "partial" end' "$res")" "$res" >> "$(re_dir)/runs.tsv"
  echo "$line · $res"
  { true >&3; } 2>/dev/null && printf '%s\n' "$res" >&3
  return "$rc"
}

re_args_run() { # sets SET LABEL JOBS KIT from the shared flags
  SET=""; LABEL="run"; JOBS=""; KIT="$RE_KIT"; BASE=""; BASEKIT=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --set) SET="$2"; shift 2 ;; --label) LABEL="$2"; shift 2 ;; --jobs) JOBS="$2"; shift 2 ;;
      --kit) KIT="$2"; shift 2 ;; --base) BASE="$2"; shift 2 ;; --base-kit) BASEKIT="$2"; shift 2 ;;
      *) re_die "unknown argument $1" ;;
    esac
  done
  case "$LABEL" in *[!A-Za-z0-9_-]*|'') re_die "--label is letters, digits, - and _" ;; esac
}

re_cmd_run() {
  re_args_run "$@"
  ( re_env "$KIT" || exit 2
    [ -n "$JOBS" ] || JOBS=$(re_opt jobs 2); case "$JOBS" in ''|*[!0-9]*|0) JOBS=2 ;; esac
    local s; s="$(mktemp "${TMPDIR:-/tmp}/review-eval-set.XXXXXX")"
    re_set "$s" "$SET"; rc=0; re_run "$KIT" "$s" "$LABEL" "$JOBS" || rc=$?; rm -f "$s"; exit "$rc" )
}

# re_reuse <fingerprint> <set sha> — the newest complete result with that fingerprint.
re_reuse() {
  [ -s "$(re_dir)/runs.tsv" ] || return 1
  awk -F'\t' -v fp="$1" -v s="$2" '$7 == fp && $8 == s && $9 == "ok" { f = $10 } END { if (f == "") exit 1; print f }' "$(re_dir)/runs.tsv"
}

re_cmd_compare() {
  re_args_run "$@"
  [ -n "$BASE$BASEKIT" ] || re_die "compare: --base <ref> or --base-kit <dir> is required"
  ( re_env "$KIT" || exit 2
    [ -n "$JOBS" ] || JOBS=$(re_opt jobs 2); case "$JOBS" in ''|*[!0-9]*|0) JOBS=2 ;; esac
    local s bk="" made="" fpb fpa sha before after bcost=0 acost=0 bhow ahow v
    s="$(mktemp "${TMPDIR:-/tmp}/review-eval-set.XXXXXX")"; re_set "$s" "$SET"; sha=$(git hash-object "$s")
    if [ -n "$BASEKIT" ]; then bk="$BASEKIT"
    else
      bk="$(mktemp -d "${TMPDIR:-/tmp}/review-eval-base.XXXXXX")"; rmdir "$bk"; made=1
      git -C "$KIT" worktree add -q --detach "$bk" "$BASE" >/dev/null 2>&1 || re_die "compare: $BASE does not check out in $KIT"
    fi
    grep -q '^_driver_review_check()' "$bk/driver/steps/review.sh" 2>/dev/null \
      || re_die "compare: the base kit's review step has no hunter-and-check to score"
    fpb=$(re_fingerprint "$bk"); fpa=$(re_fingerprint "$KIT")
    if before=$(re_reuse "$fpb" "$sha"); then bhow="reused"
    else before=$( ( re_env "$bk" && re_run "$bk" "$s" before "$JOBS" 3>&1 >&2 ) | tail -1 ); bhow="ran"; fi
    if after=$(re_reuse "$fpa" "$sha"); then ahow="reused"
    else after=$( ( re_env "$KIT" && re_run "$KIT" "$s" after "$JOBS" 3>&1 >&2 ) | tail -1 ); ahow="ran"; fi
    [ -n "$made" ] && { git -C "$KIT" worktree remove --force "$bk" >/dev/null 2>&1 || true; }
    rm -f "$s"
    [ -s "$before" ] && [ -s "$after" ] || re_die "compare: a side produced no result (before: ${before:-none}, after: ${after:-none})"
    [ "$bhow" = reused ] || bcost=$(jq -r .cost "$before"); [ "$ahow" = reused ] || acost=$(jq -r .cost "$after")
    v=$(jq -rn --slurpfile b "$before" --slurpfile a "$after" '
      ($b[0]) as $b | ($a[0]) as $a
      | if $a.hits > $b.hits or ($a.hits == $b.hits and $a.falseFindings < $b.falseFindings) then "better"
        elif $a.hits < $b.hits or ($a.hits == $b.hits and $a.falseFindings > $b.falseFindings) then "worse"
        else "same" end')
    printf 'review-eval: compare before recall %s/%s, false %s (%s) → after recall %s/%s, false %s (%s) · %s · cost $%s\n' \
      "$(jq -r .hits "$before")" "$(jq -r .of "$before")" "$(jq -r .falseFindings "$before")" "$bhow" \
      "$(jq -r .hits "$after")" "$(jq -r .of "$after")" "$(jq -r .falseFindings "$after")" "$ahow" \
      "$v" "$(jq -rn --argjson x "$bcost" --argjson y "$acost" '($x + $y) * 100 | round / 100')"
    [ "$v" != worse ] )
}

re_cmd_weekly() {
  re_args_run "$@"
  ( re_env "$KIT" || exit 2
    local min last held
    min=$(re_opt minDays 6); case "$min" in ''|*[!0-9]*) min=6 ;; esac
    [ "$min" -ge 6 ] || min=6
    if held=$(swarm_held 2>/dev/null); then echo "review-eval: weekly — skipped, the swarm is held ($held) · cost \$0"; exit 0; fi
    last=$(awk -F'\t' '$9 == "ok" { t = $1 } END { print t + 0 }' "$(re_dir)/runs.tsv" 2>/dev/null); last=${last:-0}
    if [ "$last" -gt 0 ] && [ $(( $(re_now) - last )) -lt $((min * 86400)) ]; then
      echo "review-eval: weekly — skipped, a full run finished $(( ($(re_now) - last) / 86400 )) day(s) ago (under $min) · cost \$0"; exit 0
    fi
    exec bash "$RE_SELF" run --label weekly ${SET:+--set "$SET"} ${JOBS:+--jobs "$JOBS"} --kit "$KIT" )
}

# noise: what became of each finding, by week. Sources, all written already by the review
# and fix steps: each ticket's stamped log (found, judged not real, nit, pre-existing,
# repeated), and its posted ledger beside its fix answer (fixed or not, dated by the ledger).
re_cmd_noise() {
  local weeks=8
  while [ $# -gt 0 ]; do
    case "$1" in --weeks) weeks="$2"; shift 2 ;; *) re_die "noise: unknown argument $1" ;; esac
  done
  case "$weeks" in ''|*[!0-9]*|0) weeks=8 ;; esac
  ( . "$RE_KIT/swarm/swarm-env.sh" >/dev/null 2>&1 || true
    local dd="${DRIVER_DIR:-$STATE_DIR/driver}" t mt
    {
      for t in "$dd"/*/log; do
        [ -f "$t" ] || continue
        sed -nE \
          -e 's/^([0-9T:-]+Z) +review: hunter found ([0-9]+), check kept ([0-9]+) \(dropped ([0-9]+)\).*/\1 found \2\n\1 notreal \4/p' \
          -e 's/^([0-9T:-]+Z) +review: ([0-9]+) nit\(s\) dropped — style and cleanup never block.*/\1 nit \2/p' \
          -e 's/^([0-9T:-]+Z) +review: ([0-9]+) pre-existing finding\(s\) to the nightly sweep.*/\1 pre \2/p' \
          -e 's/^([0-9T:-]+Z) +review: ([0-9]+) finding\(s\) already raised on this change.*/\1 repeat \2/p' "$t"
      done
      for t in "$dd"/*/steps/review.posted.jsonl; do
        [ -s "$t" ] || continue
        mt=$(stat -f %m "$t" 2>/dev/null || stat -c %Y "$t" 2>/dev/null)
        jq -r --slurpfile fx <(cat "$(dirname "$t")/fix.json" 2>/dev/null || echo '{}') --arg mt "${mt:-0}" '
          . as $p | ($fx[0] // {}) as $f | ($mt | tonumber | strftime("%Y-%m-%dT%H:%M:%SZ")) as $at
          | if ([$f.cleared[]?.blockerId] | index($p.id)) != null then "\($at) fixed 1"
            elif ([$f.deferred[]?.blockerId] | index($p.id)) != null then "\($at) deferred 1"
            else "\($at) unfixed 1" end' "$t" 2>/dev/null
      done
    } | jq -R -s --argjson w "$weeks" --argjson now "$(date +%s)" '
      [split("\n")[] | select(length > 0) | split(" ") | {at: (.[0] | strptime("%Y-%m-%dT%H:%M:%SZ") | mktime), k: .[1], n: (.[2] | tonumber)}]
      | map(. + {wk: (.at - (((.at | gmtime | .[6]) + 6) % 7) * 86400 | strftime("%Y-%m-%d"))})
      | map(select(.at >= $now - $w * 7 * 86400))
      | group_by(.wk) | map({week: .[0].wk} + (group_by(.k) | map({(.[0].k): (map(.n) | add)}) | add))' \
      | jq -r '
      "review noise by week — from the driver'"'"'s own logs and ledgers, no model calls",
      "week of     found  not real  nit  pre-existing  repeat  fixed  deferred  not fixed",
      (.[] | "\(.week)  \(.found // 0 | tostring | . + "      " | .[0:5])  \(.notreal // 0 | tostring | . + "        " | .[0:8])  \(.nit // 0 | tostring | . + "   " | .[0:3])  \(.pre // 0 | tostring | . + "            " | .[0:12])  \(.repeat // 0 | tostring | . + "      " | .[0:6])  \(.fixed // 0 | tostring | . + "     " | .[0:5])  \(.deferred // 0 | tostring | . + "        " | .[0:8])  \(.unfixed // 0)"),
      (if length == 0 then "(no review in the window)" else empty end)' )
}

# Sourced (a suite reading one function), it defines and does nothing.
[ "${BASH_SOURCE[0]}" = "$0" ] || return 0 2>/dev/null
case "${1:-}" in
  run) shift; re_cmd_run "$@" ;;
  compare) shift; re_cmd_compare "$@" ;;
  weekly) shift; re_cmd_weekly "$@" ;;
  needs) shift; re_cmd_needs "$@" ;;
  guard) shift; re_cmd_guard "$@" ;;
  noise) shift; re_cmd_noise "$@" ;;
  score) shift; [ $# -ge 2 ] || re_die "score <answer.json> <expect.json> [window]"; re_score "$@" ;;
  -h|--help|"") sed -n '2,30p' "$RE_SELF" | sed 's/^# \{0,1\}//' ;;
  *) re_die "unknown command $1 (run, compare, weekly, needs, guard, noise, score)" ;;
esac
