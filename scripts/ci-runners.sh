#!/usr/bin/env bash
# ci-runners.sh — is any self-hosted CI runner, the repo's or its org's, online? Read once a tick.
# Only a runner that can run a self-hosted job counts: its labels cover that job's runs-on, read
# from the repo's .github/workflows, or coordinator.ciRunnerLabels (comma list) when set. A
# runs-on written as an expression is not read; with no self-hosted label set, every runner counts.
#
#   sourced by coordinator-env.sh (needs its swarm_gh, REPO_SLUG, COORD_DIR, coord_mode)
#   ci_runners_state          online | none | offline | unread
#
#   online   at least one self-hosted runner is online
#   none     no self-hosted runner, or none but left-overs (hosted CI): nothing to wait for
#   offline  it has runners and every one is offline: no check can run, so no red is the PR's
#   unread   the list could not be read: offline cannot be ruled out, and stderr names the repo and why
#
# A list GitHub refuses (403: a token without admin scope; 404) reads as none, said once
# (CI_RUNNERS_REFUSED): held as unread, it would stop every rebuild on a hosted-CI repo for ever.
# Nothing else is kept on disk between calls: every process sources this, and a shared file
# one of them clears under another turns that one's read into unread.
[ -z "${_CI_RUNNERS_SH:-}" ] || return 0
_CI_RUNNERS_SH=1

CI_RUNNERS_REFUSED="${COORD_DIR:?}/ci-runners-refused.$(coord_mode).tsv"   # endpoint whose refusal was said
# A runner offline this long is a left-over, not an outage (GitHub keeps a dead one 14 days):
# it is not counted, so one stale runner cannot hold every rebuild. Its first offline sighting
# is kept per runner (CI_RUNNERS_OFFLINE: <endpoint>#<id> \t epoch), dropped once it is online.
CI_RUNNERS_STALE_MIN="${COORDINATOR_CI_RUNNER_STALE_MIN:-$(swarm_opt coordinator.ciRunnerStaleMin 720)}"
case "$CI_RUNNERS_STALE_MIN" in ''|*[!0-9]*) CI_RUNNERS_STALE_MIN=720 ;; esac
CI_RUNNERS_OFFLINE="$COORD_DIR/ci-runners-offline.$(coord_mode).tsv"
CI_RUNNERS_LABELS="${COORDINATOR_CI_RUNNER_LABELS:-$(swarm_opt coordinator.ciRunnerLabels "")}"

# _ci_runners_needed — the label sets a self-hosted job asks for, as a JSON array of arrays.
_ci_runners_needed() {
  local root="${HARNESS_MAIN_REPO:-$PWD}" f
  if [ -n "$CI_RUNNERS_LABELS" ]; then
    jq -cn --arg l "$CI_RUNNERS_LABELS" '[$l | ascii_downcase | split(",") | map(gsub("^ +| +$"; "")) | map(select(. != ""))]'
    return
  fi
  for f in "$root"/.github/workflows/*.yml "$root"/.github/workflows/*.yaml; do
    [ -f "$f" ] && awk '
      function emit() { if (n && set !~ /\$\{\{/ && ("," set ",") ~ /,self-hosted,/) print set; n = 0; set = "" }
      function add(v) { gsub(/^[ \t"\047]+|[ \t"\047]+$/, "", v); if (v != "") { set = set (n ? "," : "") tolower(v); n++ } }
      inlist && /^[ \t]*-[ \t]*/ { v = $0; sub(/^[ \t]*-[ \t]*/, "", v); sub(/[ \t]+#.*$/, "", v); add(v); next }
      inlist { inlist = 0; emit() }
      /^[ \t]*runs-on:/ {
        v = $0; sub(/^[ \t]*runs-on:[ \t]*/, "", v); sub(/[ \t]+#.*$/, "", v)
        if (v == "") { inlist = 1; next }
        if (v ~ /^\[/) { gsub(/^\[|\][ \t]*$/, "", v); k = split(v, a, ","); for (i = 1; i <= k; i++) add(a[i]) }
        else if (v !~ /^\{/) add(v)
        emit()
      }
      END { if (inlist) emit() }' "$f"
  done | jq -Rcs 'split("\n") | map(select(. != "") | split(",")) | unique'
}

# _ci_runners_read <endpoint> — its runners as one JSON array. 0 read, 2 refused, 1 failed;
# stderr says why when it is not read.
_ci_runners_read() {
  local ep="$1" out err rc=0 r code who
  who="${ep%/actions/runners}"; case "$who" in repos/*) who="${who#repos/}" ;; orgs/*) who="the org ${who#orgs/}" ;; esac
  err=$(mktemp "${TMPDIR:-/tmp}/ci-runners.XXXXXX") || err=/dev/null
  # Pages concatenated: count across all of them.
  if out=$(swarm_gh api "$ep?per_page=100" --paginate 2>"$err") \
    && r=$(jq -cs 'if length == 0 or any(.[]; type != "object" or (.runners | type) != "array") then error("unread")
                   else [.[].runners[]] end' <<<"$out" 2>/dev/null) && [ -n "$r" ]; then
    printf '%s\n' "$r"
    awk -v e="$ep" '$0 != e' "$CI_RUNNERS_REFUSED" > "$CI_RUNNERS_REFUSED.$$" 2>/dev/null \
      && mv -f "$CI_RUNNERS_REFUSED.$$" "$CI_RUNNERS_REFUSED" 2>/dev/null; rm -f "$CI_RUNNERS_REFUSED.$$" 2>/dev/null
  else
    r=$(tr '\n' ' ' <"$err" 2>/dev/null | cut -c1-200 | sed 's/ *$//')
    code=$(printf '%s' "$r" | sed -nE 's/.*HTTP (40[34]).*/\1/p')
    if [ -n "$code" ]; then
      rc=2
      grep -qxF -- "$ep" "$CI_RUNNERS_REFUSED" 2>/dev/null || {
        printf '%s\n' "$ep" >> "$CI_RUNNERS_REFUSED" 2>/dev/null
        printf 'ci-runners: the runner list of %s is refused (HTTP %s) — counted as no self-hosted runners; give the token Administration read to hold rebuilds while CI is down\n' \
          "$who" "$code" >&2
      }
    else
      rc=1
      printf 'ci-runners: the runner list of %s could not be read%s\n' "$who" "${r:+: $r}" >&2
    fi
  fi
  [ "$err" = /dev/null ] || rm -f "$err"
  return "$rc"
}

ci_runners_state() {
  local ep r all='[]' failed="" read_eps='[]' seen res need
  need=$(_ci_runners_needed 2>/dev/null) || need='[]'
  [ -n "$need" ] || need='[]'
  # The repo's own runners and its org's: an org-wide outage is the usual shared setup.
  for ep in "repos/${REPO_SLUG:?}/actions/runners" "orgs/${REPO_SLUG%%/*}/actions/runners"; do
    if r=$(_ci_runners_read "$ep"); then
      all=$(jq -c --argjson r "$r" --arg ep "$ep" --argjson need "$need" '
        . + ($r | map(select(. as $x | ($need | length) == 0
                        or ([$x.labels[]?.name | ascii_downcase] as $l | any($need[]; all(.[]; IN($l[])))))
                      | . + {key: "\($ep)#\(.id)"}))' <<<"$all")
      read_eps=$(jq -c --arg ep "$ep" '. + [$ep]' <<<"$read_eps")
    elif [ $? -eq 1 ]; then failed=1; fi
  done
  seen=$(jq -Rn '[inputs | split("\t") | select(length >= 2 and (.[1] | test("^[0-9]+$"))) | {key: .[0], value: (.[1] | tonumber)}] | from_entries' \
    < "$CI_RUNNERS_OFFLINE" 2>/dev/null) || seen='{}'
  [ -n "$seen" ] || seen='{}'
  res=$(jq -c --argjson seen "$seen" --argjson eps "$read_eps" --argjson now "$(swarm_now)" --argjson cut "$((CI_RUNNERS_STALE_MIN * 60))" '
    (map(select(.status != "online")) | map({key, value: ($seen[.key] // $now)}) | from_entries) as $off
    | {off: (($seen | with_entries(select(.key as $k | $eps | any(. as $e | $k | startswith($e + "#")) | not))) + $off),
       live: map(select(.status == "online" or ($now - $off[.key]) < $cut))}' <<<"$all") || { echo unread; return 0; }
  jq -r '.off | to_entries[] | "\(.key)\t\(.value)"' <<<"$res" > "$CI_RUNNERS_OFFLINE.$$" 2>/dev/null \
    && mv -f "$CI_RUNNERS_OFFLINE.$$" "$CI_RUNNERS_OFFLINE" 2>/dev/null; rm -f "$CI_RUNNERS_OFFLINE.$$" 2>/dev/null
  # One online is enough; otherwise a list not read could hold the one that is.
  if jq -e '.live | any(.[]; .status == "online")' >/dev/null <<<"$res"; then echo online
  elif [ -n "$failed" ]; then echo unread
  elif jq -e '.live | length == 0' >/dev/null <<<"$res"; then echo none
  else echo offline; fi
}
