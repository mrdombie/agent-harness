#!/usr/bin/env bash
# base-wait.sh — a red the base branch has too is the base's to fix, never the PR's.
# Sourced by the repair and self-check steps, the coordinator tick and repair-watch,
# after toolkit-env.sh (REPO_SLUG, STATE_DIR, CHECK_NEWEST_JQ).
#
# The standing answer (the PM, 2026-10-21): "a red from a test this PR does not touch
# that also fails on develop waits for develop's fix and is never repaired in the PR."
# A red check is BASE-ONLY when all of these are read, never assumed:
#   - its CI job log on the PR names the tests that failed, and none of them is a file the
#     PR's diff touches (a suffix match either way counts as touched)
#   - the same check's newest completed run on the base branch settled red
#   - that run's log names every one of those tests failing too
# One unreadable piece and the red is the PR's own.
#
#   base_red_tests_in_log <file>                    failing test paths a test runner printed, one per line
#   base_red_classify <tree> <trunk> <pr-head> <names ", "> <workdir>
#                                                   one line per red: name \t base|own \t tests or why
#   base_wait_note <ticket> <pr> <head> <base> <checks> <tests> [<brief-file>]   the ticket waits for the base
#   base_wait_holds <ticket> [<pr-head>]            0 while it waits (on that head, when given)
#   base_wait_clear <ticket>
#   base_wait_release <queue-script> [dry]          queues each wait the base turned green on, or
#                                                   that is BASE_WAIT_HOURS old; prints what it did
#
#   base-waits.tsv  <ticket> \t <pr> \t <head> \t <base> \t <checks> \t <tests> \t <since epoch> \t <brief-file>
#   The brief file holds what a caller sent with the repair that waited; its words go back
#   on the queue with the note that ends the wait, so a brief is never lost to it.

BASE_WAITS="${BASE_WAITS_FILE:-${STATE_DIR:-${TMPDIR:-/tmp}}/swarm/base-waits.tsv}"
BASE_WAIT_HOURS="${BASE_WAIT_HOURS:-$(jq -r '.coordinator.baseWaitHours // 6' "${HARNESS_CFG:-/dev/null}" 2>/dev/null || echo 6)}"
case "$BASE_WAIT_HOURS" in ''|*[!0-9]*) BASE_WAIT_HOURS=6 ;; esac
BASE_RED_DEPTH="${BASE_RED_DEPTH:-5}"
# The first line of the brief a released wait sends: a repair carrying it is not a person's brief.
BASE_WAIT_NOTE_PREFIX="Base-red wait over"
BASE_WAIT_BRIEF_MARK="The brief this repair was sent with: "

_base_gh() { if type swarm_gh >/dev/null 2>&1; then swarm_gh "$@"; else gh "$@"; fi; }
_base_now() { if type swarm_now >/dev/null 2>&1; then swarm_now; else date +%s; fi; }

# base_red_tests_in_log <file> — the test files a runner printed on a failure line.
base_red_tests_in_log() {
  perl -ne 's/\e\[[0-9;]*[A-Za-z]//g;
    next unless /(\bFAIL(ED)?\b|\bfailed\b|\bFailed\b|\bnot ok\b|\xe2\x9c\x97|\xc3\x97|\xe2\x9c\x95|\xe2\x9c\x98)/;
    while (m{((?:[\w@.+-]+/)*(?:[\w@+-][\w.@+-]*\.(?:test|spec)\.[A-Za-z]+|[\w@+-][\w.@+-]*_test\.(?:go|py)|test_\w+\.py))}g) {
      my $p = $1; $p =~ s{^(\./)+}{}; print "$p\n" }' "$1" 2>/dev/null | sort -u
}

# _base_runs <ref> — that commit's check runs as rollup entries, every run of each check.
_base_runs() {
  _base_gh api "repos/${REPO_SLUG:?}/commits/$1/check-runs?per_page=100&filter=all" 2>/dev/null \
    | jq -c '[.check_runs[]? | {name, id, status: ((.status // "") | ascii_upcase),
              conclusion: ((.conclusion // "") | ascii_upcase), completedAt: (.completed_at // ""),
              startedAt: (.started_at // ""), detailsUrl: (.details_url // "")}]' 2>/dev/null
}

# _base_newest_done <runs-json> <name> — the newest COMPLETED run of that check, or nothing.
_base_newest_done() {
  printf '%s' "$1" | jq -c --arg n "$2" "$CHECK_NEWEST_JQ"'
    [ .[] | select(.status == "COMPLETED") ] | newest_runs | map(select(.name == $n)) | first // empty' 2>/dev/null
}

# _base_latest_done <base> <name> <cache-dir> — the check's newest completed run on the
# base: at its head, else the commit before, up to BASE_RED_DEPTH back. Nothing when none.
_base_latest_done() {
  local base="$1" n="$2" c="$3" shas sha runs hit
  if [ ! -f "$c/base-shas" ]; then
    _base_gh api "repos/${REPO_SLUG:?}/commits?sha=$base&per_page=$BASE_RED_DEPTH" 2>/dev/null \
      | jq -r '.[]?.sha // empty' > "$c/base-shas" 2>/dev/null || : > "$c/base-shas"
  fi
  shas=$(cat "$c/base-shas")
  for sha in $shas; do
    [ -f "$c/runs-$sha" ] || _base_runs "$sha" > "$c/runs-$sha"
    runs=$(cat "$c/runs-$sha"); [ -n "$runs" ] || continue
    hit=$(_base_newest_done "$runs" "$n")
    [ -n "$hit" ] && { printf '%s' "$hit" | jq -c --arg s "$sha" '. + {sha: $s}'; return 0; }
  done
  return 1
}

# _base_job_tests <run-json> <out> — the failing tests that run's job log names, into <out>.
_base_job_tests() {
  local id; id=$(printf '%s' "$1" | jq -r '.id // empty')
  [ -n "$id" ] || return 1
  _base_gh api "repos/${REPO_SLUG:?}/actions/jobs/$id/logs" > "$2.log" 2>/dev/null || return 1
  [ -s "$2.log" ] || return 1
  base_red_tests_in_log "$2.log" > "$2"
}

# _base_touched <test> <diff-file> — 0 when the PR's diff touches that test file.
_base_touched() {
  awk -v t="$1" 'NF { n = length($0); m = length(t)
    if ($0 == t) f = 1
    else if (m > n && substr(t, m - n) == "/" $0) f = 1
    else if (n > m && substr($0, n - m) == "/" t) f = 1 }
    END { exit f ? 0 : 1 }' "$2"
}

base_red_classify() { # <tree> <trunk> <pr-head> <names ", "> <workdir>
  local wt="$1" trunk="$2" head="$3" names="$4" c="$5" mb prruns n pr br t miss tests i=0
  mkdir -p "$c" || return 1
  mb=$(git -C "$wt" merge-base "$trunk" HEAD 2>/dev/null) || mb=""
  if [ -n "$mb" ]; then git -C "$wt" diff --name-only "$mb" HEAD > "$c/diff" 2>/dev/null; else : > "$c/diff"; fi
  prruns=$(_base_runs "$head")
  while IFS= read -r n; do
    n=$(printf '%s' "$n" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//'); [ -n "$n" ] || continue
    i=$((i+1))
    if [ -z "$mb" ]; then printf '%s\town\tthe PR diff against %s could not be read\n' "$n" "$trunk"; continue; fi
    pr=$(_base_newest_done "${prruns:-[]}" "$n")
    if [ -z "$pr" ] || ! _base_job_tests "$pr" "$c/pr-$i"; then printf '%s\town\tits log on the PR could not be read\n' "$n"; continue; fi
    if [ ! -s "$c/pr-$i" ]; then printf '%s\town\tits log on the PR names no failing test file\n' "$n"; continue; fi
    t=""; while IFS= read -r tests; do _base_touched "$tests" "$c/diff" && t="$t$tests "; done < "$c/pr-$i"
    if [ -n "$t" ]; then printf '%s\town\tfails in %sthat this PR changes\n' "$n" "$t"; continue; fi
    br=$(_base_latest_done "${INTEGRATION_BRANCH:-${trunk#origin/}}" "$n" "$c")
    if [ -z "$br" ]; then printf '%s\town\tno completed run of it on the base to compare\n' "$n"; continue; fi
    if ! printf '%s' "$br" | jq -r '.conclusion' | grep -qE 'FAILURE|ERROR|TIMED_OUT'; then
      printf '%s\town\tit passes on the base (%s)\n' "$n" "$(printf '%s' "$br" | jq -r '.sha[0:9]')"; continue
    fi
    if ! _base_job_tests "$br" "$c/base-$i"; then printf '%s\town\tits log on the base could not be read\n' "$n"; continue; fi
    miss=$(grep -vxF -f "$c/base-$i" "$c/pr-$i" 2>/dev/null)
    if [ -n "$miss" ] || [ ! -s "$c/base-$i" ]; then
      printf '%s\town\t%s fails on the PR and not on the base\n' "$n" "$(printf '%s' "${miss:-$(cat "$c/pr-$i")}" | tr '\n' ' ' | sed 's/ $//')"; continue
    fi
    printf '%s\tbase\t%s\n' "$n" "$(tr '\n' ' ' < "$c/pr-$i" | sed 's/ $//')"
  done <<EOS
$(printf '%s' "$names" | awk 'BEGIN { RS = ", " } { sub(/\n$/, ""); print }')
EOS
}

base_wait_clear() { # <ticket>
  [ -f "$BASE_WAITS" ] || return 0
  awk -F'\t' -v t="$1" '$1 != t' "$BASE_WAITS" > "$BASE_WAITS.$$" && mv -f "$BASE_WAITS.$$" "$BASE_WAITS"
}
base_wait_note() { # <ticket> <pr> <head> <base> <checks> <tests> [<brief-file>]
  mkdir -p "$(dirname "$BASE_WAITS")" 2>/dev/null
  base_wait_clear "$1"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "$(printf '%s' "$5" | tr '\t\n' '  ')" \
    "$(printf '%s' "$6" | tr '\t\n' '  ')" "$(_base_now)" "${7:-}" >> "$BASE_WAITS"
}
base_wait_holds() { # <ticket> [<pr-head>]
  [ -n "${1:-}" ] && [ -f "$BASE_WAITS" ] || return 1
  awk -F'\t' -v t="$1" -v h="${2:-}" '$1 == t && (h == "" || $3 == h) { f = 1 } END { exit f ? 0 : 1 }' "$BASE_WAITS"
}

# _base_green <base> <checks ", "> — 0 when each check's newest completed run on the base passed.
_base_green() {
  local c n r rc=0
  c=$(mktemp -d "${TMPDIR:-/tmp}/base-green.XXXXXX") || return 1
  while IFS= read -r n; do
    [ -n "$n" ] || continue
    r=$(_base_latest_done "$1" "$n" "$c") || { rc=1; break; }
    printf '%s' "$r" | jq -r '.conclusion' | grep -qE '^(SUCCESS|NEUTRAL|SKIPPED)$' || { rc=1; break; }
  done <<EOS
$(printf '%s' "$2" | awk 'BEGIN { RS = ", " } { sub(/\n$/, ""); print }')
EOS
  rm -rf "$c"
  return "$rc"
}

base_wait_release() { # <queue-script> [dry]
  local q="$1" dry="${2:-}" t pr head base checks tests since bf why note now carried
  [ -s "$BASE_WAITS" ] || return 0
  now=$(_base_now)
  while IFS=$'\t' read -r t pr head base checks tests since bf; do
    [ -n "${t:-}" ] || continue
    why=""
    if _base_green "$base" "$checks"; then why="$checks went green on $base"
    elif [ $(( now - ${since:-0} )) -ge $(( BASE_WAIT_HOURS * 3600 )) ]; then why="$BASE_WAIT_HOURS hours passed"; fi
    [ -n "$why" ] || continue
    note="$BASE_WAIT_NOTE_PREFIX ($why): PR #$pr was red on $checks, in ${tests:-tests} outside this PR that failed on $base too. Repair it again: merge $base when it carries the fix; a red still shared with $base waits again."
    carried=""; [ -n "${bf:-}" ] && [ -s "$bf" ] && carried=$(tr '\t\n' '  ' < "$bf" | sed 's/[[:space:]]*$//' | cut -c1-3000)
    [ -z "$carried" ] || note="$note $BASE_WAIT_BRIEF_MARK$carried"
    if [ -n "$dry" ]; then printf 'would queue #%s as a repair: %s\n' "$t" "$why"; continue; fi
    if bash "$q" add "$t" --class repair --note "$note" --first >/dev/null 2>&1; then
      base_wait_clear "$t"; printf 'queued #%s as a repair: %s\n' "$t" "$why"
    else
      printf 'could not queue #%s (%s) — trying again next tick\n' "$t" "$why"
    fi
  done < "$BASE_WAITS"
}
