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
#                                   came back with no data at all
#   gh_prs_by_head_batch <branch…>  {"<branch>": [{number,state}…]}, newest
#                                   first, same shape and exit as above
#
# Why: on 2026-10-16 a coordinator tick made 101 gh calls (59 of them one
# `gh issue view` per queued ticket) and its housekeeping 89 more, all on the
# token every builder and session shares. GitHub's secondary limits (requests
# and points per minute, not the hourly quota) then refused that token for
# everyone, and the tick, unable to read the open PRs, started nothing.
#
# Seams: SWARM_GH (the gh binary, default gh), SWARM_NOW (the clock),
# GH_BACKOFF_FILE (default $STATE_DIR/swarm/gh-backoff).

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

# gh_call <args…> — gh through the backoff. Stdout and stderr pass through.
gh_call() {
  local until e rc
  if until=$(gh_backoff_active); then
    echo "gh: GitHub is rate-limiting this token — backing off until $(date -u -r "$until" +%H:%M:%SZ 2>/dev/null || date -u -d "@$until" +%H:%M:%SZ 2>/dev/null)" >&2
    return 75
  fi
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
  local _o _r n q="" k=0 out="{}" part fail=0 nums="" one
  _gh_batch_repo || return 1
  _ghb_flush() {
    [ -n "$q" ] || return 0
    if part=$(_gh_graphql "query{repository(owner:\"$_o\",name:\"$_r\"){$q}}"); then
      part=$(jq -c --argjson acc "$out" '$acc + ([.data.repository | to_entries[] | .value | select(type == "object" and .number != null)
              | {key: (.number|tostring), value: {number, state, title: (.title // ""), updatedAt: (.updatedAt // null), labels: [.labels.nodes[]?.name]}}] | from_entries)' <<<"$part" 2>/dev/null) || part=""
      [ -n "$part" ] && out="$part" || fail=1
    else
      fail=1
      for one in $nums; do
        part=$(gh_call issue view "$one" --repo "$_o/$_r" --json number,state,title,labels,updatedAt 2>/dev/null) || continue
        part=$(jq -c --argjson acc "$out" --arg n "$one" 'select(type == "object" and .state != null)
                | $acc + {($n): {number: ($n|tonumber), state, title: (.title // ""), updatedAt: (.updatedAt // null), labels: [.labels[]?.name]}}' <<<"$part" 2>/dev/null)
        [ -z "$part" ] || out="$part"
      done
    fi
    q=""; k=0; nums=""
  }
  for n in "$@"; do
    case "$n" in ''|*[!0-9]*) continue ;; esac
    nums="$nums $n"
    q="$q i$n:issueOrPullRequest(number:$n){... on Issue{number state title updatedAt labels(first:50){nodes{name}}} ... on PullRequest{number state title updatedAt labels(first:50){nodes{name}}}}"
    k=$((k+1)); [ "$k" -lt 50 ] || _ghb_flush
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
