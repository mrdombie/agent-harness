#!/usr/bin/env bash
# gh-batch.sh — GitHub reads in one request instead of one per ticket, and a
# backoff every caller shares once GitHub starts refusing the token.
#
#   . "$KIT_ROOT/scripts/gh-batch.sh"
#
#   gh_call <gh args…>              gh, refused at once while the backoff holds;
#                                   a rate-limit refusal starts (or lengthens) it
#   gh_backoff_active               0, printing the epoch it ends, while it holds
#   gh_issues_batch <n…>            {"<n>": {number,state,title,updatedAt,labels:[name…]}}
#                                   plus milestone (its title) when it has one,
#                                   for every number GitHub resolved, in one
#                                   GraphQL request per 50; exit 1 when a request
#                                   came back with no data at all. GH_BATCH_BODY=1
#                                   adds each body (a polish list's items)
#   gh_prs_by_head_batch <branch…>  {"<branch>": [{number,state}…]}, newest
#                                   first, same shape and exit as above
#   gh_pr_commits_batch <n…>        {"<n>": {headRefOid, commits:[{oid,message,files,
#                                   parents,parentOids}…]}}, the newest 50 commits, oldest
#                                   first, five PRs a request; files is null when
#                                   GitHub could not count
#   gh_open_prs [max-age-sec]       the open PRs, from one shared copy (prs.json)
#                                   every reader takes while it is young enough
#   gh_prs_paged <fields> [base]    every open PR in `gh pr list --json` shape, read
#                                   GH_PRS_PAGE (25) a request; exit 1 on any failed page
#   gh_allowance_read / _low        what is left of the hourly allowance (free reads);
#                                   _low holds below GH_ALLOWANCE_LOW_PCT (10)
#   gh_limit_why                    the rate limit and its reset, as a sentence
#   gh_calls_tally <since> [caller] who spent it, from gh-calls.log
#
# Why: on 2026-10-16 a coordinator tick made 101 gh calls (59 of them one
# `gh issue view` per queued ticket) and its housekeeping 89 more, all on the
# token every builder and session shares. GitHub's secondary limits (requests
# and points per minute, not the hourly quota) then refused that token for
# everyone, and the tick, unable to read the open PRs, started nothing.
#
# Seams: SWARM_GH (the gh binary, default gh), SWARM_NOW (the clock),
# GH_BACKOFF_FILE (default $STATE_DIR/swarm/gh-backoff); GH_PRS_FILE, GH_CALLS_FILE
# and GH_ALLOWANCE_FILE sit beside it.

gh_batch_bin()  { printf '%s' "${SWARM_GH:-gh}"; }
gh_batch_now()  { if [ -n "${SWARM_NOW:-}" ]; then printf '%s' "$SWARM_NOW"; else date +%s; fi; }
gh_backoff_file() { printf '%s' "${GH_BACKOFF_FILE:-${STATE_DIR:-${HARNESS_STATE_DIR:-/tmp}}/swarm/gh-backoff}"; }

# The refusals GitHub sends for both kinds of limit, primary and secondary.
GH_RATE_LIMIT_RE='rate limit|secondary rate|abuse detection|RATE_LIMITED|exceeded a secondary'

# gh_backoff_active — 0 and the end epoch while a backoff holds.
gh_backoff_active() {
  local f until
  f=$(gh_backoff_file); [ -s "$f" ] || return 1
  until=$(cut -f1 "$f" 2>/dev/null)
  case "$until" in ''|*[!0-9]*) return 1 ;; esac
  [ "$until" -gt "$(gh_batch_now)" ] || return 1
  printf '%s' "$until"
}

# gh_backoff_note <stderr text> — starts a backoff when the text is a rate-limit
# refusal: 4 minutes, doubled for each refusal within 30 minutes of the last
# one, capped at 32. Returns 0 when it was one.
gh_backoff_note() {
  printf '%s' "$1" | grep -qiE -- "$GH_RATE_LIMIT_RE" || return 1
  local f now lvl=0 last=0 mins
  f=$(gh_backoff_file); now=$(gh_batch_now)
  mkdir -p "$(dirname "$f")" 2>/dev/null
  if [ -s "$f" ]; then
    lvl=$(cut -f2 "$f" 2>/dev/null); last=$(cut -f3 "$f" 2>/dev/null)
    case "$lvl" in ''|*[!0-9]*) lvl=0 ;; esac
    case "$last" in ''|*[!0-9]*) last=0 ;; esac
    if [ $(( now - last )) -lt 1800 ]; then lvl=$(( lvl + 1 )); else lvl=0; fi
  fi
  [ "$lvl" -le 3 ] || lvl=3
  mins=$(( 4 << lvl ))
  printf '%s\t%s\t%s\n' "$(( now + mins * 60 ))" "$lvl" "$now" > "$f.$$" && mv -f "$f.$$" "$f"
  return 0
}

# ---- who spends the allowance ------------------------------------------------
# One line per call that reached GitHub: <epoch> \t <caller> \t <verb>. The caller
# is GH_CALLER when a parent set it (the tick sets it for everything it runs),
# else the script's own name.
gh_calls_file() { printf '%s' "${GH_CALLS_FILE:-$(dirname "$(gh_backoff_file)")/gh-calls.log}"; }
gh_calls_note() { # <args…>
  local f; f=$(gh_calls_file)
  mkdir -p "$(dirname "$f")" 2>/dev/null
  printf '%s\t%s\t%s %s\n' "$(gh_batch_now)" "${GH_CALLER:-$(basename "${0:-?}" .sh)}" "${1:-}" "${2:-}" >> "$f" 2>/dev/null || true
}
# gh_calls_tally <since-epoch> [caller] — "caller N, caller N" (most first), or the count for one caller.
gh_calls_tally() {
  local f; f=$(gh_calls_file); [ -s "$f" ] || { [ -n "${2:-}" ] && printf '0'; return 0; }
  if [ -n "${2:-}" ]; then
    awk -F'\t' -v s="$1" -v c="$2" '$1 >= s && $2 == c { n++ } END { printf "%d", n }' "$f"
  else
    awk -F'\t' -v s="$1" '$1 >= s { n[$2]++ } END { for (k in n) printf "%d\t%s\n", n[k], k }' "$f" \
      | sort -rn | awk -F'\t' '{ printf "%s%s %s", (NR > 1 ? ", " : ""), $2, $1 }'
  fi
}
# Keeps the last two hours, so the tally stays a cheap read.
gh_calls_trim() {
  local f; f=$(gh_calls_file); [ -s "$f" ] || return 0
  awk -F'\t' -v s="$(( $(gh_batch_now) - 7200 ))" '$1 >= s' "$f" > "$f.$$" 2>/dev/null && mv -f "$f.$$" "$f"
}

# ---- how much of the allowance is left ---------------------------------------
# Both readings cost nothing against the allowance and answer while it is spent.
# GraphQL's own rateLimit, never `gh api rate_limit`'s graphql entry: measured
# 2026-10-17 they disagreed (285 used vs 1190) and only the first moved with gh calls.
gh_allowance_file() { printf '%s' "${GH_ALLOWANCE_FILE:-$(dirname "$(gh_backoff_file)")/gh-allowance}"; }
GH_ALLOWANCE_LOW_PCT="${GH_ALLOWANCE_LOW_PCT:-10}"

# gh_allowance_read — writes and prints <resource> \t <remaining> \t <limit> \t <reset-epoch>, one row each.
gh_allowance_read() {
  local g c rows="" f
  g=$("$(gh_batch_bin)" api graphql -i -f query='query{rateLimit{remaining}}' 2>/dev/null \
      | tr -d '\r' | awk -F': *' 'tolower($1) == "x-ratelimit-remaining" { r = $2 } tolower($1) == "x-ratelimit-limit" { l = $2 }
                                 tolower($1) == "x-ratelimit-reset" { t = $2 } END { if (r != "" && l != "" && t != "") printf "graphql\t%s\t%s\t%s", r, l, t }')
  c=$("$(gh_batch_bin)" api rate_limit --jq '.resources.core | "core\t\(.remaining)\t\(.limit)\t\(.reset)"' 2>/dev/null)
  for r in "$g" "$c"; do
    printf '%s' "$r" | grep -qE '^[a-z]+	[0-9]+	[0-9]+	[0-9]+$' && rows="$rows$r"$'\n'
  done
  [ -n "$rows" ] || return 1
  f=$(gh_allowance_file); mkdir -p "$(dirname "$f")" 2>/dev/null
  printf '%s' "$rows" > "$f.$$" && mv -f "$f.$$" "$f"
  printf '%s' "$rows"
}

# Every host on the account spends the one token's allowance: the other hosts'
# readings ride on their heartbeats, kept in the coordinator's fleet file.
gh_allowance_fleet_file() { printf '%s' "${GH_FLEET_FILE:-${COORDINATOR_DIR:-${STATE_DIR:-${HARNESS_STATE_DIR:-/tmp}}/coordinator}/fleet.json}"; }

# gh_allowance_rows — <resource> \t <remaining> \t <limit> \t <reset-epoch> \t <host>, one row a
# resource: the freshest of this host's reading and every host's heartbeat. Inside one
# hourly window what is left only falls, so the lowest of the newest window is the newest.
gh_allowance_rows() {
  { awk -F'\t' 'NF >= 4 { print $1 "\t" $2 "\t" $3 "\t" $4 "\there" }' "$(gh_allowance_file)" 2>/dev/null
    jq -r '.hosts[]? | (.host // "?") as $h | (.gh // [])[]?
           | select((.remaining | type) == "number" and (.limit | type) == "number" and (.reset | type) == "number")
           | "\(.resource)\t\(.remaining)\t\(.limit)\t\(.reset)\t\($h)"' "$(gh_allowance_fleet_file)" 2>/dev/null
    true   # no fleet file is no reading, never a failure: callers run under pipefail
  } | awk -F'\t' -v now="$(gh_batch_now)" '
    $4 + 0 > now + 0 { n++; K[n] = $1; L[n] = $0; Rm[n] = $2 + 0; Rs[n] = $4 + 0; if (Rs[n] > top[$1]) top[$1] = Rs[n] }
    END { for (i = 1; i <= n; i++) { k = K[i]
            if (Rs[i] >= top[k] - 300 && (!(k in best) || Rm[i] < best[k])) { best[k] = Rm[i]; row[k] = L[i] } }
          for (k in row) print row[k] }'
}

# _gh_allowance_short <resource> — 0 while that resource is under the low mark on any host.
_gh_allowance_short() {
  gh_allowance_rows | awk -F'\t' -v r="$1" -v p="$GH_ALLOWANCE_LOW_PCT" '$1 == r && $3 + 0 > 0 && $2 * 100 < $3 * p { f = 1 } END { exit !f }'
}

# gh_allowance_low — 0 while a resource is under GH_ALLOWANCE_LOW_PCT of its limit
# and its reset is still ahead, by the freshest reading on any host (gh_allowance_rows);
# prints <resource> \t <remaining> \t <limit> \t <reset-epoch> \t <host it was read on>.
gh_allowance_low() {
  gh_allowance_rows | awk -F'\t' -v p="$GH_ALLOWANCE_LOW_PCT" '
    $3 + 0 > 0 && $2 * 100 < $3 * p { if (!found || $2 / $3 < best) { best = $2 / $3; row = $0; found = 1 } }
    END { if (found) { print row; exit 0 } exit 1 }'
}

# gh_limit_why — one sentence naming the rate limit and its reset, when that is why GitHub is refusing.
gh_limit_why() {
  local row until
  if row=$(gh_allowance_low); then
    printf "GitHub's hourly API allowance is spent: %s %s of %s left until %s%s" "$(cut -f1 <<<"$row" | sed 's/graphql/GraphQL/; s/core/REST/')" \
      "$(cut -f2 <<<"$row")" "$(cut -f3 <<<"$row")" "$(gh_batch_clock "$(cut -f4 <<<"$row")")" \
      "$(h=$(cut -f5 <<<"$row"); [ -z "$h" ] || [ "$h" = here ] || printf ', as %s read it' "$h")"
    return 0
  fi
  if until=$(gh_backoff_active); then
    printf 'GitHub is rate-limiting this token until %s' "$(gh_batch_clock "$until")"; return 0
  fi
  return 1
}
gh_batch_clock() { date -u -r "$1" +%H:%MZ 2>/dev/null || date -u -d "@$1" +%H:%MZ 2>/dev/null; }

# ---- the open pull requests, read once and shared ----------------------------
# Every reader takes this file while it is younger than the age it can bear; past
# that, the first one to ask reads GitHub for all of them. Its mtime is its time.
GH_PRS_FIELDS="${GH_PRS_FIELDS:-number,headRefName,headRefOid,baseRefName,isDraft,labels,mergeStateStatus,statusCheckRollup,mergeable,closingIssuesReferences,title,updatedAt,body}"
gh_prs_file() { printf '%s' "${GH_PRS_FILE:-$(dirname "$(gh_backoff_file)")/prs.json}"; }
gh_prs_age() { # seconds since it was written; 1 when there is none
  local f m; f=$(gh_prs_file); [ -s "$f" ] || return 1
  # GNU first: GNU `stat -f %m` prints filesystem blurb to stdout and still succeeds in part.
  m=$(stat -c %Y "$f" 2>/dev/null); case "$m" in ''|*[!0-9]*) m=$(stat -f %m "$f" 2>/dev/null) ;; esac
  case "$m" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s' $(( $(gh_batch_now) - m ))
}

# gh_open_prs [max-age-sec] — the open PRs as a JSON array. 0 asks GitHub now (the
# tick); otherwise the shared copy while it is that young. Below the allowance
# floor only a 0 asks, and every other reader takes the copy whatever its age.
gh_open_prs() {
  local max="${1:-${GH_PRS_MAX_AGE:-300}}" age f slug prs
  f=$(gh_prs_file)
  if age=$(gh_prs_age); then
    if [ "$max" -gt 0 ] && { [ "$age" -le "$max" ] || gh_allowance_low >/dev/null; }; then cat "$f"; return 0; fi
  fi
  slug="${GH_REPO:-${REPO_SLUG:-}}"; [ -n "$slug" ] || return 1
  prs=$(gh_prs_paged "$GH_PRS_FIELDS" 2>/dev/null) || return 1
  jq -e 'type == "array"' >/dev/null 2>&1 <<<"$prs" || return 1
  mkdir -p "$(dirname "$f")" 2>/dev/null
  printf '%s\n' "$prs" > "$f.$$" && mv -f "$f.$$" "$f"
  printf '%s\n' "$prs"
}

# gh_prs_paged <fields> [base] — every open PR (on <base> when given) as ONE JSON
# array in the shape `gh pr list --json <fields>` prints, read GH_PRS_PAGE (25) a
# request. Any page that fails fails the whole read: exit 1, never a partial list.
# A read whose size grows with the repo is paged: `gh pr list --limit 200` asks
# for 100 a request, and with statusCheckRollup on 81 open PRs GitHub answered
# 504 every time while 50 came back. A page that times out is asked again at half
# the size (GH_PRS_PAGE_TRIES, 3), since the timeout tracks the work per request.
GH_PRS_PAGE="${GH_PRS_PAGE:-25}"
gh_prs_paged() {
  local fields="${1:?gh_prs_paged: need fields}" base="${2:-}" _o _r f sel="" proj="" q
  local after="" size="$GH_PRS_PAGE" tries page out="[]" pages=0 rc err
  _gh_batch_repo || return 1
  for f in $(printf '%s' "$fields" | tr ',' ' '); do
    case "$f" in
      number|title|headRefName|headRefOid|baseRefName|isDraft|mergeStateStatus|mergeable|updatedAt|createdAt|body|url|state|reviewDecision)
        sel="$sel $f"; proj="$proj,$f:.$f" ;;
      labels)
        sel="$sel labels(first:100){nodes{id name description color}}"
        proj="$proj,labels:[.labels.nodes[]? | {id, name, description:(.description // \"\"), color}]" ;;
      closingIssuesReferences)
        sel="$sel closingIssuesReferences(first:100){nodes{id number url repository{id name owner{id login}}}}"
        proj="$proj,closingIssuesReferences:[.closingIssuesReferences.nodes[]?]" ;;
      statusCheckRollup) # gh prints a missing time as Go's zero time and a missing string as ""
        sel="$sel statusCheckRollup:commits(last:1){nodes{commit{statusCheckRollup{contexts(first:100){nodes{__typename ... on StatusContext{context state targetUrl createdAt} ... on CheckRun{name status conclusion startedAt completedAt detailsUrl checkSuite{workflowRun{workflow{name}}}}}}}}}}"
        proj="$proj,statusCheckRollup:[.statusCheckRollup.nodes[0].commit.statusCheckRollup.contexts.nodes[]? | if .__typename == \"StatusContext\" then {__typename, context, state, targetUrl:(.targetUrl // \"\"), startedAt:(.createdAt // \"0001-01-01T00:00:00Z\")} else {__typename, completedAt:(.completedAt // \"0001-01-01T00:00:00Z\"), conclusion:(.conclusion // \"\"), detailsUrl:(.detailsUrl // \"\"), name, startedAt:(.startedAt // \"0001-01-01T00:00:00Z\"), status, workflowName:(.checkSuite.workflowRun.workflow.name // \"\")} end]" ;;
      autoMergeRequest|author)
        local who="__typename login ... on User{id name} ... on Bot{id} ... on Organization{id name} ... on Mannequin{id} ... on EnterpriseUserAccount{id name}"
        local whoj="{id:(.id // \"\"), is_bot:(.__typename == \"Bot\"), login, name:(.name // \"\")}"
        if [ "$f" = author ]; then
          sel="$sel author{$who}"; proj="$proj,author:(.author | if . == null then null else $whoj end)"
        else
          sel="$sel autoMergeRequest{authorEmail commitBody commitHeadline mergeMethod enabledAt enabledBy{$who}}"
          proj="$proj,autoMergeRequest:(.autoMergeRequest | if . == null then null else {authorEmail, commitBody, commitHeadline, mergeMethod, enabledAt, enabledBy:(.enabledBy | if . == null then null else $whoj end)} end)"
        fi ;;
      '') ;;
      *) echo "gh_prs_paged: no paged reading for the field '$f' — add it here rather than reading every PR in one request" >&2; return 1 ;;
    esac
  done
  [ -n "$sel" ] || return 1
  err=$(mktemp "${TMPDIR:-/tmp}/ghprs.XXXXXX") || return 1
  q="query OpenPullRequests(\$owner:String!,\$name:String!,\$first:Int!,\$after:String,\$base:String){repository(owner:\$owner,name:\$name){pullRequests(states:OPEN,first:\$first,after:\$after,baseRefName:\$base,orderBy:{field:CREATED_AT,direction:DESC}){pageInfo{hasNextPage endCursor} nodes{$sel}}}}"
  while :; do
    pages=$((pages+1))
    [ "$pages" -le "${GH_PRS_MAX_PAGES:-60}" ] || { echo "gh_prs_paged: more than ${GH_PRS_MAX_PAGES:-60} pages of open PRs" >&2; rm -f "$err"; return 1; }
    tries=0
    while :; do
      tries=$((tries+1)); rc=0
      page=$(gh_call api graphql -f query="$q" -f owner="$_o" -f name="$_r" -F first="$size" \
               ${after:+-f after="$after"} ${base:+-f base="$base"} 2>"$err") || rc=$?
      if [ "$rc" -eq 0 ] && jq -e '(.errors // [] | length) == 0 and (.data.repository.pullRequests.nodes | type == "array")' >/dev/null 2>&1 <<<"$page"; then
        break
      fi
      cat "$err" >&2
      # Only a timeout is asked again, smaller; anything else, or past the tries, fails whole.
      grep -qiE 'HTTP 50[234]|gateway|time-?out|timed out' "$err" && [ "$tries" -lt "${GH_PRS_PAGE_TRIES:-3}" ] \
        || { rm -f "$err"; return 1; }
      size=$(( size / 2 )); [ "$size" -ge 5 ] || size=5
      sleep "${GH_PRS_RETRY_SEC:-2}"
    done
    out=$(_gh_jq_acc "$out" "\$acc + [.data.repository.pullRequests.nodes[] | {${proj#,}}]" <<<"$page") || { rm -f "$err"; return 1; }
    jq -e '.data.repository.pullRequests.pageInfo.hasNextPage == true' >/dev/null 2>&1 <<<"$page" || break
    after=$(jq -r '.data.repository.pullRequests.pageInfo.endCursor // ""' <<<"$page")
    [ -n "$after" ] || { rm -f "$err"; return 1; }
  done
  rm -f "$err"
  printf '%s\n' "$out"
}

# gh_call <args…> — gh through the backoff. Stdout and stderr pass through.
# EVERY COMMENT THE HARNESS POSTS CARRIES THE MACHINE MARKER, so person-stop.sh can tell
# the driver's words from a person's when both post on one token. It goes before a
# closing marker line (approval-kept.sh reads its marker as the body's last line).
GH_MACHINE_MARK='<!-- harness:machine -->'
_gh_mark_body() { # <body> — the body with the marker in it
  local b="$1" last
  case "$b" in *"$GH_MACHINE_MARK"*) printf '%s' "$b"; return 0 ;; esac
  b="${b%"${b##*[!$'\n']}"}"
  last="${b##*$'\n'}"
  if [ "$last" != "$b" ] && [[ "$last" =~ ^[[:space:]]*\<!--.*--\>[[:space:]]*$ ]]; then
    printf '%s\n%s\n%s' "${b%$'\n'*}" "$GH_MACHINE_MARK" "$last"
  else
    printf '%s\n\n%s' "$b" "$GH_MACHINE_MARK"
  fi
}
_gh_mark_args() { # <gh args…> — sets _GH_MARKED to them, each comment body marked;
  # a body file is copied, marked, into a temp file listed in _GH_MARK_TMP
  _GH_MARKED=(); _GH_MARK_TMP=()
  local a next="" mf
  for a in "$@"; do
    case "$next:$a" in
      body:*) _GH_MARKED+=("$(_gh_mark_body "$a")"); next=""; continue ;;
      file:*) if mf=$(mktemp "${TMPDIR:-/tmp}/ghmark.XXXXXX"); then
                _GH_MARK_TMP+=("$mf")
                if { if [ "$a" = - ]; then cat; else cat -- "$a"; fi; } > "$mf.in" 2>/dev/null \
                   && _gh_mark_body "$(cat "$mf.in")" > "$mf"; then _GH_MARKED+=("$mf"); else _GH_MARKED+=("$a"); fi
                rm -f "$mf.in"
              else _GH_MARKED+=("$a"); fi
              next=""; continue ;;
    esac
    case "$a" in
      --body|-b) next=body; _GH_MARKED+=("$a") ;;
      --body-file|-F) next=file; _GH_MARKED+=("$a") ;;
      --body=*) _GH_MARKED+=("--body=$(_gh_mark_body "${a#--body=}")") ;;
      *) _GH_MARKED+=("$a") ;;
    esac
  done
}

gh_call() {
  local until e rc
  if until=$(gh_backoff_active); then
    echo "gh: GitHub is rate-limiting this token — backing off until $(date -u -r "$until" +%H:%M:%SZ 2>/dev/null || date -u -d "@$until" +%H:%M:%SZ 2>/dev/null)" >&2
    return 75
  fi
  gh_calls_note "$@"
  local -a _GH_MARKED=() _GH_MARK_TMP=()
  case "${1:-} ${2:-}" in "issue comment"|"pr comment") _gh_mark_args "$@"; set -- "${_GH_MARKED[@]}" ;; esac
  e=$(mktemp "${TMPDIR:-/tmp}/ghcall.XXXXXX") || { "$(gh_batch_bin)" "$@"; rc=$?; [ "${#_GH_MARK_TMP[@]}" -eq 0 ] || rm -f "${_GH_MARK_TMP[@]}"; return "$rc"; }
  "$(gh_batch_bin)" "$@" 2>"$e"; rc=$?
  [ "${#_GH_MARK_TMP[@]}" -eq 0 ] || rm -f "${_GH_MARK_TMP[@]}"
  if [ "$rc" -ne 0 ] && [ -s "$e" ]; then gh_backoff_note "$(cat "$e")" || true; fi
  cat "$e" >&2; rm -f "$e"
  return "$rc"
}

# _gh_jq_acc <acc-json> <filter> [jq args…] — jq -c on stdin with $acc bound to
# <acc-json>, handed over in a file, never as an argument: Linux caps one argument
# at 128KB (MAX_ARG_STRLEN), and 25 open PRs with their check rollups pass it, so
# `--argjson acc` failed the second page of gh_prs_paged every time (2026-10-19;
# macOS has no per-argument cap, which is why it passed there).
_gh_jq_acc() {
  local acc="$1" filter="$2" f rc; shift 2
  f=$(mktemp "${TMPDIR:-/tmp}/ghacc.XXXXXX") || return 1
  printf '%s' "$acc" > "$f"
  jq -c --slurpfile _acc "$f" "$@" "\$_acc[0] as \$acc | $filter"; rc=$?
  rm -f "$f"; return "$rc"
}

_gh_batch_repo() { # sets _o and _r from REPO_SLUG / GH_REPO
  local slug="${GH_REPO:-${REPO_SLUG:-}}"
  _o="${slug%%/*}"; _r="${slug#*/}"
  [ -n "$_o" ] && [ -n "$_r" ] && [ "$_o" != "$slug" ]
}

# _gh_graphql <query> — the response body on stdout; 1 when it carries no data.
# A query naming a number that does not exist still answers the rest, with an
# error beside them and a non-zero exit, so the body decides, not the exit.
_gh_graphql() {
  local body
  body=$(gh_call api graphql -f query="$1" 2>/dev/null)
  printf '%s' "$body" | jq -e '.data.repository | type == "object"' >/dev/null 2>&1 || return 1
  printf '%s' "$body"
}

# A request that came back with no data is asked again one number at a time, so a
# gh that cannot batch still answers; under a backoff each of those fails at once.
gh_issues_batch() {
  local _o _r n q="" k=0 out="{}" part fail=0 nums="" one b=""
  [ "${GH_BATCH_BODY:-0}" = 1 ] && b=" body"
  _gh_batch_repo || return 1
  # GraphQL under its low mark on any host while REST still has room: one REST read a
  # ticket costs the allowance that is left, not the one that is spent.
  local rest_only=0
  _gh_allowance_short graphql && ! _gh_allowance_short core && rest_only=1
  _ghb_flush() {
    [ -n "$q" ] || return 0
    if [ "$rest_only" = 0 ] && part=$(_gh_graphql "query{repository(owner:\"$_o\",name:\"$_r\"){$q}}"); then
      part=$(_gh_jq_acc "$out" '$acc + ([.data.repository | to_entries[] | .value | select(type == "object" and .number != null)
              | {key: (.number|tostring), value: ({number, state, title: (.title // ""), updatedAt: (.updatedAt // null), labels: [.labels.nodes[]?.name]}
                                                   + (if has("body") then {body: (.body // "")} else {} end)
                                                   + (if .stateReason then {stateReason} else {} end)
                                                   + (if (.milestone.title? // "") != "" then {milestone: .milestone.title} else {} end))}] | from_entries)' <<<"$part" 2>/dev/null) || part=""
      [ -n "$part" ] && out="$part" || fail=1
    else
      fail=1
      if [ "$rest_only" = 1 ]; then
        fail=0
        for one in $nums; do
          # REST, not `gh issue view`: that is GraphQL, the allowance that is spent.
          part=$(gh_call api "repos/$_o/$_r/issues/$one" 2>/dev/null) || { fail=1; continue; }
          part=$(_gh_jq_acc "$out" 'select(type == "object" and .state != null)
                  | $acc + {($n): ({number: ($n|tonumber), state: (.state | ascii_upcase), title: (.title // ""),
                                    updatedAt: (.updated_at // .updatedAt // null), labels: [.labels[]? | if type == "object" then .name else . end]}
                                   + (if $b != "" then {body: (.body // "")} else {} end)
                                   + (if (.state_reason // "") != "" then {stateReason: (.state_reason | ascii_upcase)} else {} end)
                                   + (if (.milestone.title? // "") != "" then {milestone: .milestone.title} else {} end))}' \
                  --arg n "$one" --arg b "$b" <<<"$part" 2>/dev/null)
          [ -z "$part" ] || out="$part"
        done
      else
      for one in $nums; do
        part=$(gh_call issue view "$one" --repo "$_o/$_r" --json "number,state,title,labels,updatedAt,milestone${b:+,body}" 2>/dev/null) || continue
        part=$(_gh_jq_acc "$out" 'select(type == "object" and .state != null)
                | $acc + {($n): ({number: ($n|tonumber), state, title: (.title // ""), updatedAt: (.updatedAt // null), labels: [.labels[]?.name]}
                                 + (if has("body") then {body: (.body // "")} else {} end)
                                 + (if (.milestone.title? // "") != "" then {milestone: .milestone.title} else {} end))}' --arg n "$one" <<<"$part" 2>/dev/null)
        [ -z "$part" ] || out="$part"
      done
      fi
    fi
    q=""; k=0; nums=""
  }
  for n in "$@"; do
    case "$n" in ''|*[!0-9]*) continue ;; esac
    nums="$nums $n"
    q="$q i$n:issueOrPullRequest(number:$n){... on Issue{number state stateReason title updatedAt$b milestone{title} labels(first:50){nodes{name}}} ... on PullRequest{number state title updatedAt$b labels(first:50){nodes{name}}}}"
    k=$((k+1)); [ "$k" -lt 50 ] || _ghb_flush
  done
  _ghb_flush
  printf '%s\n' "$out"
  return "$fail"
}

gh_pr_commits_batch() {
  local _o _r n q="" k=0 out="{}" part fail=0
  _gh_batch_repo || return 1
  _ghb_flush() {
    [ -n "$q" ] || return 0
    if part=$(_gh_graphql "query{repository(owner:\"$_o\",name:\"$_r\"){$q}}"); then
      part=$(_gh_jq_acc "$out" '$acc + ([.data.repository | to_entries[] | select(.key | test("^p[0-9]+$")) | select(.value | type == "object")
              | {key: (.key | ltrimstr("p")), value: {headRefOid: (.value.headRefOid // ""),
                 commits: [.value.commits.nodes[]?.commit | {oid, message: (.message // ""), files: .changedFilesIfAvailable,
                   parents: (.parents.totalCount // 0), parentOids: [.parents.nodes[]?.oid]}]}}] | from_entries)' <<<"$part" 2>/dev/null) || part=""
      [ -n "$part" ] && out="$part" || fail=1
    else fail=1; fi
    q=""; k=0
  }
  for n in "$@"; do
    case "$n" in ''|*[!0-9]*) continue ;; esac
    # Five a request: fifty commits with their messages each is a heavy node count.
    q="$q p$n:pullRequest(number:$n){headRefOid commits(last:50){nodes{commit{oid message changedFilesIfAvailable parents(first:2){totalCount nodes{oid}}}}}}"
    k=$((k+1)); [ "$k" -lt 5 ] || _ghb_flush
  done
  _ghb_flush
  printf '%s\n' "$out"
  return "$fail"
}

gh_prs_by_head_batch() {
  local _o _r b q="" k=0 i=0 out="{}" part fail=0 map="{}"
  _gh_batch_repo || return 1
  _ghb_flush() {
    [ -n "$q" ] || return 0
    if part=$(_gh_graphql "query{repository(owner:\"$_o\",name:\"$_r\"){$q}}"); then
      part=$(_gh_jq_acc "$out" '$acc + ([.data.repository | to_entries[]
              | select($map[.key] != null)
              | {key: $map[.key], value: [.value.nodes[]? | {number, state}]}] | from_entries)' --argjson map "$map" <<<"$part" 2>/dev/null) || part=""
      [ -n "$part" ] && out="$part" || fail=1
    else fail=1; fi
    q=""; k=0; map="{}"
  }
  for b in "$@"; do
    [ -n "$b" ] || continue
    i=$((i+1))
    map=$(jq -c --arg k "b$i" --arg v "$b" '. + {($k): $v}' <<<"$map")
    q="$q b$i:pullRequests(headRefName:$(jq -Rn --arg v "$b" '$v'),first:20,states:[OPEN,MERGED,CLOSED],orderBy:{field:CREATED_AT,direction:DESC}){nodes{number state}}"
    k=$((k+1)); [ "$k" -lt 50 ] || _ghb_flush
  done
  _ghb_flush
  printf '%s\n' "$out"
  return "$fail"
}
