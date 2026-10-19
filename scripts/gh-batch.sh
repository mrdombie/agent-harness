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

# gh_allowance_low — 0 while a resource is under GH_ALLOWANCE_LOW_PCT of its limit
# and its reset is still ahead; prints <resource> \t <remaining> \t <limit> \t <reset-epoch>.
gh_allowance_low() {
  local f; f=$(gh_allowance_file); [ -s "$f" ] || return 1
  awk -F'\t' -v now="$(gh_batch_now)" -v p="$GH_ALLOWANCE_LOW_PCT" '
    $4 + 0 > now + 0 && $3 + 0 > 0 && $2 * 100 < $3 * p { if (!found || $2 / $3 < best) { best = $2 / $3; row = $0; found = 1 } }
    END { if (found) { print row; exit 0 } exit 1 }' "$f"
}

# gh_limit_why — one sentence naming the rate limit and its reset, when that is why GitHub is refusing.
gh_limit_why() {
  local row until
  if row=$(gh_allowance_low); then
    printf "GitHub's hourly API allowance is spent: %s %s of %s left until %s" "$(cut -f1 <<<"$row" | sed 's/graphql/GraphQL/; s/core/REST/')" \
      "$(cut -f2 <<<"$row")" "$(cut -f3 <<<"$row")" "$(gh_batch_clock "$(cut -f4 <<<"$row")")"
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
GH_PRS_FIELDS="${GH_PRS_FIELDS:-number,headRefName,headRefOid,baseRefName,isDraft,labels,mergeStateStatus,statusCheckRollup,mergeable,closingIssuesReferences,title,updatedAt}"
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
    out=$(jq -c --argjson acc "$out" "\$acc + [.data.repository.pullRequests.nodes[] | {${proj#,}}]" <<<"$page") || { rm -f "$err"; return 1; }
    jq -e '.data.repository.pullRequests.pageInfo.hasNextPage == true' >/dev/null 2>&1 <<<"$page" || break
    after=$(jq -r '.data.repository.pullRequests.pageInfo.endCursor // ""' <<<"$page")
    [ -n "$after" ] || { rm -f "$err"; return 1; }
  done
  rm -f "$err"
  printf '%s\n' "$out"
}

# gh_call <args…> — gh through the backoff. Stdout and stderr pass through.
gh_call() {
  local until e rc
  if until=$(gh_backoff_active); then
    echo "gh: GitHub is rate-limiting this token — backing off until $(date -u -r "$until" +%H:%M:%SZ 2>/dev/null || date -u -d "@$until" +%H:%M:%SZ 2>/dev/null)" >&2
    return 75
  fi
  gh_calls_note "$@"
  e=$(mktemp "${TMPDIR:-/tmp}/ghcall.XXXXXX") || { "$(gh_batch_bin)" "$@"; return; }
  "$(gh_batch_bin)" "$@" 2>"$e"; rc=$?
  if [ "$rc" -ne 0 ] && [ -s "$e" ]; then gh_backoff_note "$(cat "$e")" || true; fi
  cat "$e" >&2; rm -f "$e"
  return "$rc"
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
  _ghb_flush() {
    [ -n "$q" ] || return 0
    if part=$(_gh_graphql "query{repository(owner:\"$_o\",name:\"$_r\"){$q}}"); then
      part=$(jq -c --argjson acc "$out" '$acc + ([.data.repository | to_entries[] | .value | select(type == "object" and .number != null)
              | {key: (.number|tostring), value: ({number, state, title: (.title // ""), updatedAt: (.updatedAt // null), labels: [.labels.nodes[]?.name]}
                                                   + (if has("body") then {body: (.body // "")} else {} end))}] | from_entries)' <<<"$part" 2>/dev/null) || part=""
      [ -n "$part" ] && out="$part" || fail=1
    else
      fail=1
      for one in $nums; do
        part=$(gh_call issue view "$one" --repo "$_o/$_r" --json "number,state,title,labels,updatedAt${b:+,body}" 2>/dev/null) || continue
        part=$(jq -c --argjson acc "$out" --arg n "$one" 'select(type == "object" and .state != null)
                | $acc + {($n): ({number: ($n|tonumber), state, title: (.title // ""), updatedAt: (.updatedAt // null), labels: [.labels[]?.name]}
                                 + (if has("body") then {body: (.body // "")} else {} end))}' <<<"$part" 2>/dev/null)
        [ -z "$part" ] || out="$part"
      done
    fi
    q=""; k=0; nums=""
  }
  for n in "$@"; do
    case "$n" in ''|*[!0-9]*) continue ;; esac
    nums="$nums $n"
    q="$q i$n:issueOrPullRequest(number:$n){... on Issue{number state title updatedAt$b labels(first:50){nodes{name}}} ... on PullRequest{number state title updatedAt$b labels(first:50){nodes{name}}}}"
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
      part=$(jq -c --argjson acc "$out" '$acc + ([.data.repository | to_entries[] | select(.key | test("^p[0-9]+$")) | select(.value | type == "object")
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
      part=$(jq -c --argjson acc "$out" --argjson map "$map" '$acc + ([.data.repository | to_entries[]
              | select($map[.key] != null)
              | {key: $map[.key], value: [.value.nodes[]? | {number, state}]}] | from_entries)' <<<"$part" 2>/dev/null) || part=""
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
