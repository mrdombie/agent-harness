#!/usr/bin/env bash
# fleet-jobs.sh — the one home for jobs, results and worker records passed between
# machines as refs on origin. Each ref is a parentless commit on the empty tree whose
# message is the JSON payload, pushed the way claim-lock.sh pushes a claim.
#
#   refs/fleet/jobs/<host>/<ticket>          a build the coordinator hands to <host>
#   refs/fleet/done/<host>/<ticket>-<runid>  the result of one run on <host>
#   refs/fleet/workers/<host>                <host>'s worker record
#
# USAGE (or source it and call the fleet_* functions)
#   fleet-jobs.sh put <host> <ticket> <json>       create the job; exit 10 if one exists
#   fleet-jobs.sh list <host>                      the tickets waiting for <host>
#   fleet-jobs.sh take <host> <ticket>             print the job and remove it; exit 10 if gone
#   fleet-jobs.sh done-put <host> <ticket> <runid> <exit> <final line>
#   fleet-jobs.sh done-all                         one JSON line per result, with its ref
#   fleet-jobs.sh done-ack <ref>                   remove a result once recorded
#   fleet-jobs.sh worker-put <host> <json>         push the record only when it changed
#   fleet-jobs.sh worker-read <host>               {"host","at","stale","record"}
#
# ENV  FLEET_REPO (a clone to push from; default cwd), FLEET_REMOTE (origin),
#      FLEET_STATE_DIR (hash on disk), FLEET_NOW (epoch), FLEET_WORKER_STALE_MIN
#      (else coordinator.workerStaleMin in .claude/harness.json, else 10).
#
# EXIT  0 ok · 10 lost the race or nothing to take · 11 not found · 1 error

FLEET_NS="refs/fleet"
FLEET_CACHE="refs/fleet-cache"

fleet__git() { git -C "${FLEET_REPO:-.}" "$@"; }
fleet__remote() { printf '%s' "${FLEET_REMOTE:-origin}"; }
fleet__now() { printf '%s' "${FLEET_NOW:-$(date +%s)}"; }
fleet__state() {
  local d="${FLEET_STATE_DIR:-${HOME}/.cache/agent-harness/fleet}"
  mkdir -p "$d" && printf '%s' "$d"
}

fleet__commit() { # <payload>
  local tree
  tree=$(fleet__git hash-object -t tree -w /dev/null) || return 1
  fleet__git commit-tree "$tree" -m "$1"
}

# Pre-push hooks run on every push, refs with no code in them included.
fleet__push_new() { # <sha> <ref>  — the CAS: the ref must not exist yet
  local out
  if out=$(fleet__git push -q --no-verify "$(fleet__remote)" "$1:$2" --force-with-lease="$2:" 2>&1); then
    return 0
  fi
  if grep -qiE 'stale info|already exists|non-fast-forward|rejected' <<<"$out"; then return 10; fi
  printf 'fleet-jobs: push failed for %s\n%s\n' "$2" "$out" >&2
  return 1
}

fleet__remote_sha() { # <ref>
  fleet__git ls-remote "$(fleet__remote)" "$1" | cut -f1
}

fleet__payload() { # <ref on origin>  — prints its message, or fails
  local cache="$FLEET_CACHE/${1#"$FLEET_NS"/}"
  fleet__git fetch -q --no-tags "$(fleet__remote)" "+$1:$cache" 2>/dev/null || return 11
  fleet__git log -1 --format=%B "$cache"
}

fleet__delete() { # <ref> <expected sha>
  fleet__git push -q --no-verify "$(fleet__remote)" --delete "$1" \
    --force-with-lease="$1:$2" >/dev/null 2>&1 || return 10
  fleet__git update-ref -d "$FLEET_CACHE/${1#"$FLEET_NS"/}" 2>/dev/null || true
}

fleet_job_put() { # <host> <ticket> <json>
  local sha
  sha=$(fleet__commit "$3") || return 1
  fleet__push_new "$sha" "$FLEET_NS/jobs/$1/$2"
}

fleet_job_list() { # <host>
  fleet__git ls-remote "$(fleet__remote)" "$FLEET_NS/jobs/$1/*" \
    | sed -n "s#^[0-9a-f]*	$FLEET_NS/jobs/$1/##p"
}

fleet_job_take() { # <host> <ticket>
  local ref="$FLEET_NS/jobs/$1/$2" sha body
  sha=$(fleet__remote_sha "$ref")
  [ -n "$sha" ] || return 10
  body=$(fleet__payload "$ref") || return 10
  fleet__delete "$ref" "$sha" || return 10
  printf '%s\n' "$body"
}

fleet_done_put() { # <host> <ticket> <runid> <exit> <final line>
  local payload sha
  payload=$(jq -cn --arg host "$1" --arg ticket "$2" --arg run "$3" --arg exit "$4" --arg final "$5" \
    '{host:$host, ticket:$ticket, run:$run, exit:($exit|tonumber? // $exit), final:$final}') || return 1
  sha=$(fleet__commit "$payload") || return 1
  fleet__push_new "$sha" "$FLEET_NS/done/$1/$2-$3"
}

fleet_done_all() {
  fleet__git fetch -q --no-tags --prune "$(fleet__remote)" \
    "+$FLEET_NS/done/*:$FLEET_CACHE/done/*" 2>/dev/null || return 1
  local cref
  fleet__git for-each-ref --format='%(refname)' "$FLEET_CACHE/done/" | while IFS= read -r cref; do
    fleet__git log -1 --format=%B "$cref" \
      | jq -c --arg ref "$FLEET_NS/${cref#"$FLEET_CACHE"/}" '. + {ref:$ref}' 2>/dev/null
  done
}

fleet_done_ack() { # <ref>
  local sha
  sha=$(fleet__remote_sha "$1")
  [ -n "$sha" ] || return 11
  fleet__delete "$1" "$sha"
}

fleet__stale_min() {
  if [ -n "${FLEET_WORKER_STALE_MIN:-}" ]; then printf '%s' "$FLEET_WORKER_STALE_MIN"; return; fi
  local top v=""
  top=$(fleet__git rev-parse --show-toplevel 2>/dev/null) || top=""
  [ -n "$top" ] && [ -f "$top/.claude/harness.json" ] \
    && v=$(jq -r '.coordinator.workerStaleMin // empty' "$top/.claude/harness.json" 2>/dev/null)
  printf '%s' "${v:-10}"
}

# A push per tick costs a GitHub call: an unchanged record is pushed again only once
# half the stale window has passed, so a live worker never reads stale.
fleet_worker_put() { # <host> <json>
  local ref="$FLEET_NS/workers/$1" now hash file last_hash last_at payload sha cur
  now=$(fleet__now)
  hash=$(jq -cS . <<<"$2" | git hash-object --stdin) || return 1
  file="$(fleet__state)/worker-$1"
  read -r last_hash last_at <"$file" 2>/dev/null || true
  if [ "${last_hash:-}" = "$hash" ] && [ $((now - ${last_at:-0})) -lt $(($(fleet__stale_min) * 30)) ]; then
    return 0
  fi
  payload=$(jq -cn --arg host "$1" --argjson at "$now" --argjson record "$2" \
    '{host:$host, at:$at, record:$record}') || return 1
  sha=$(fleet__commit "$payload") || return 1
  cur=$(fleet__remote_sha "$ref")
  fleet__git push -q --no-verify "$(fleet__remote)" "$sha:$ref" --force-with-lease="$ref:$cur" >/dev/null 2>&1 \
    || return 10
  printf '%s %s\n' "$hash" "$now" >"$file"
}

fleet_worker_read() { # <host>
  local body
  body=$(fleet__payload "$FLEET_NS/workers/$1") || return 11
  [ -n "$body" ] || return 11
  jq -c --argjson now "$(fleet__now)" --argjson min "$(fleet__stale_min)" \
    '. + {stale: (($now - .at) > ($min * 60))}' <<<"$body"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  set -uo pipefail
  cmd="${1:-}"; [ $# -gt 0 ] && shift
  case "$cmd" in
    put) fleet_job_put "$@" ;;
    list) fleet_job_list "$@" ;;
    take) fleet_job_take "$@" ;;
    done-put) fleet_done_put "$@" ;;
    done-all) fleet_done_all ;;
    done-ack) fleet_done_ack "$@" ;;
    worker-put) fleet_worker_put "$@" ;;
    worker-read) fleet_worker_read "$@" ;;
    *) sed -n '2,24p' "$0" >&2; exit 1 ;;
  esac
fi
