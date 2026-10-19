#!/usr/bin/env bash
# gh-open-prs.test.sh — the open PRs are still read when GitHub times out building
# the whole list in one request.
#
# On 2026-10-19 the tick's one `gh pr list --limit 200` with the check rollups
# came back `HTTP 504 Gateway Timeout` every time on 81 open PRs (30 at a time
# was fine), and with no earlier copy to fall back on it started nothing for
# hours. gh_open_prs now reads the ids, then the full fields a creation-time
# window at a time, and hands back the whole list or nothing.
# Run: bash "$0"
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
FIX=$(mktemp -d); trap 'rm -rf "$FIX"' EXIT
fails=0
ok()  { echo "ok   $1"; }
bad() { echo "FAIL $1"; fails=$((fails + 1)); }

# A fake gh over $FIX/prs.json. The full list 504s above $FAKE_ONESHOT_MAX PRs;
# a --search created:A..B window answers the PRs created in it, minus any number
# in $FAKE_SEARCH_DROP; $FAKE_REFUSE makes the first read a rate-limit refusal.
cat > "$FIX/gh" <<'SH'
#!/usr/bin/env bash
echo "$*" >> "$FIX/calls.log"
search="" json=""
while [ $# -gt 0 ]; do
  case "$1" in --search) search="$2"; shift ;; --json) json="$2"; shift ;; esac
  shift
done
if [ -n "${FAKE_REFUSE:-}" ]; then echo "GraphQL: API rate limit exceeded for user" >&2; exit 1; fi
if [ -n "$search" ]; then
  r=${search#created:}; a=${r%..*}; b=${r#*..}; a="${a%+00:00}Z"; b="${b%+00:00}Z"
  jq -c --arg a "$a" --arg b "$b" --argjson drop "${FAKE_SEARCH_DROP:-0}" \
    '[.[] | select(.createdAt >= $a and .createdAt <= $b and .number != $drop)]' "$FIX/prs.json"
elif [ "$json" = number,createdAt ]; then
  jq -c '[.[] | {number, createdAt}]' "$FIX/prs.json"
elif [ "$(jq length "$FIX/prs.json")" -gt "${FAKE_ONESHOT_MAX:-30}" ]; then
  echo "HTTP 504: 504 Gateway Timeout (https://api.github.com/graphql)" >&2; exit 1
else
  cat "$FIX/prs.json"
fi
SH
chmod +x "$FIX/gh"

# <count> open PRs, newest first as gh lists them; two share each creation
# minute, so a window edge can fall between a pair. Each rollup is ~2KB, as real
# ones are: 81 of them overflow a single argument, so the merge must not pass one.
seed() {
  jq -nc --argjson n "$1" '[range($n; 0; -1) as $i | {number: $i,
    createdAt: ("2026-10-01T10:\(((($i - 1) / 2 | floor) | tostring | if length < 2 then "0" + . else . end)):00Z"),
    headRefName: "b\($i)", statusCheckRollup: [{name: "ci", conclusion: "SUCCESS", detailsUrl: ("x" * 2048)}]}]' > "$FIX/prs.json"
}
read_prs() { # runs gh_open_prs 0 in a clean shell; prints its JSON, exits as it did
  rm -f "$FIX/calls.log" "$FIX/state/swarm/prs.json" "$FIX/state/swarm/gh-backoff"
  FIX="$FIX" SWARM_GH="$FIX/gh" GH_REPO=o/r STATE_DIR="$FIX/state" GH_CALLS_FILE="$FIX/state/swarm/gh-calls.log" \
    bash -c '. "$1"; gh_open_prs 0' _ "$HERE/gh-batch.sh"
}
calls() { [ -s "$FIX/calls.log" ] && wc -l < "$FIX/calls.log" | tr -d ' ' || echo 0; }
mkdir -p "$FIX/state/swarm"

# 1. A small list is still one request.
seed 10
out=$(read_prs); rc=$?
if [ "$rc" = 0 ] && [ "$(jq length <<<"$out")" = 10 ] && [ "$(calls)" = 1 ]; then ok "10 PRs: one request"
else bad "10 PRs: rc=$rc len=$(jq length <<<"$out" 2>/dev/null) calls=$(calls)"; fi

# 2. 81 PRs time out whole, and come back whole, in gh's order, with the full fields.
seed 81
out=$(read_prs); rc=$?
want=$(jq -c '[.[].number]' "$FIX/prs.json")
got=$(jq -c '[.[].number]' <<<"$out" 2>/dev/null)
if [ "$rc" = 0 ] && [ "$got" = "$want" ]; then ok "81 PRs after a 504: all 81, once each, newest first"
else bad "81 PRs after a 504: rc=$rc got=${got:0:80}"; fi
if [ "$(jq '[.[] | select(.statusCheckRollup == null)] | length' <<<"$out" 2>/dev/null)" = 0 ]; then ok "81 PRs: every one carries its check rollup"
else bad "81 PRs: some came back without the full fields"; fi
# the failed whole read, the ids, then ceil(81/25) = 4 windows
if [ "$(calls)" = 6 ]; then ok "81 PRs: 6 requests (whole, ids, 4 windows)"; else bad "81 PRs: $(calls) requests, wanted 6"; fi
if [ "$(jq length "$FIX/state/swarm/prs.json" 2>/dev/null)" = 81 ]; then ok "81 PRs: the shared copy is written"
else bad "81 PRs: shared copy not written"; fi

# 3. A window that loses a PR fails the read; no partial list is handed on or kept.
out=$(FAKE_SEARCH_DROP=40 read_prs); rc=$?
if [ "$rc" != 0 ] && [ -z "$out" ] && [ ! -s "$FIX/state/swarm/prs.json" ]; then ok "a lost PR fails the whole read"
else bad "a lost PR: rc=$rc len=$(jq length <<<"$out" 2>/dev/null)"; fi

# 4. A rate-limit refusal does not fan out into more requests on the refused token.
out=$(FAKE_REFUSE=1 read_prs); rc=$?
if [ "$rc" != 0 ] && [ "$(calls)" = 1 ]; then ok "a rate-limit refusal stops at one request"
else bad "a rate-limit refusal: rc=$rc calls=$(calls)"; fi

[ "$fails" = 0 ] && echo "all passed" || { echo "$fails failed"; exit 1; }
