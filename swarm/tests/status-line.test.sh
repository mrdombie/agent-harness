#!/usr/bin/env bash
# status-line.test.sh — the one line at the bottom of every Claude Code window.
#
# What this suite exists for: a status line that reads "no agents working" when
# it simply could not see is worse than no status line at all, because the
# operator reads it as an idle machine and starts more work on a full one. Every
# case below is about that distinction — a missing answer is never nothing.
#
# The second thing it pins is where the cost goes. A statusLine command runs on
# every render, and the parts of this answer measured 170 ms (sourcing the swarm
# env), 95 ms (the live view) and 581 ms (GitHub). So the render path must read a
# cache and nothing else, and the suite asserts GitHub was not called on it.
# Run: bash "$0"
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/fixture.sh"
swarm_fixture
trap 'rm -rf "$FIX"' EXIT
SL="$HERE/../status-line.sh"

# The clock every case sits at, so "stale" is a decision and never a race.
# It is REAL now, not a pinned constant: the cache is a real file and its mtime
# is real, so a clock pinned in the past makes every line this suite writes look
# like it came from the future and no staleness case tests anything.
NOW=$(date +%s)
fix_at "$NOW"

# The render path spawns its refresh detached, which a test must not race. Every
# case here drives the paths directly: --print computes and writes the cache,
# --render reads it.
print()  { bash "$SL" --print 2>&1; }
render() { SWARM_STATUS_NO_REFRESH=1 bash "$SL" --render 2>&1; }
cache()  { printf '%s/swarm/status-line.txt' "$STATE"; }
holds()  { printf '%s/swarm/hold-prs.count' "$STATE"; }
# Start a case from nothing cached. Without this the suite shares one hold count
# across every case and reads the FIRST case's answer for the rest of the run —
# which it did, intermittently, depending on whether two cases landed inside the
# same second. The cache is correct in production and wrong as a test premise.
fresh()  { rm -f "$(cache)" "$(holds)"; }
# Both `date`s again: -r is an epoch on BSD and a FILE on GNU, so the fallback
# is not optional — without it a Linux runner ages the cache to "now" and every
# staleness case below passes by testing nothing.
touch_at() { # <epoch> <file>
  local stamp
  # NOT -u: `touch -t` reads its stamp in LOCAL time, so a UTC one sets an mtime
  # off by the zone. At UTC-5 the "one hour old" cache below landed four hours in
  # the FUTURE, which the code deliberately treats as current — so the single
  # test that pins the honesty limit passed on CI (UTC) and failed in New York.
  stamp=$(date -r "$1" +%Y%m%d%H%M.%S 2>/dev/null) || stamp=$(date -d "@$1" +%Y%m%d%H%M.%S)
  touch -t "$stamp" "$2"
}
age_cache() { touch_at "$1" "$(cache)"; }

echo "--- the ordinary answer ---"
fresh
fix_live "" 3
printf '[{"number":1},{"number":2}]\n' > "$FIX/gh/prs-all.json"
out=$(print)
want "three agents"      "3 agents working · 2 need you" "$out"

echo "--- one is singular, in both halves ---"
fresh
fix_live "" 1
printf '[{"number":1}]\n' > "$FIX/gh/prs-all.json"
want "one of each"       "1 agent working · 1 needs you" "$(print)"

echo "--- an idle machine says so, and says nothing about approvals ---"
fresh
fix_live "" 0
printf '[]\n' > "$FIX/gh/prs-all.json"
want "nothing running"   "no agents working" "$(print)"

echo "--- THE CASE THIS EXISTS FOR: no answer is not zero ---"
fresh
fix_live_down
printf '[]\n' > "$FIX/gh/prs-all.json"
out=$(print)
want     "the warning, not a count" "swarm view not answering" "$out"
want_not_in "and never 'no agents'" "no agents working" "$out"

echo "--- a stale answer is not an answer either ---"
# The view is up and answering, but its snapshot was taken 20 minutes ago: the
# machine it describes has been through two full scheduler passes since.
fresh
fix_live "" 4
fix_at "$NOW"
jq --arg at "$(swarm_iso $((NOW - 1200)))" '.at = $at' "$FIX/live.json" > "$FIX/live.json.t" && mv "$FIX/live.json.t" "$FIX/live.json"
printf '[{"number":9}]\n' > "$FIX/gh/prs-all.json"
out=$(print)
want_in     "the warning"              "swarm view not answering" "$out"
want_not_in "never the stale count"    "4 agents"                 "$out"
want_in     "approvals still reported" "1 needs you"              "$out"

echo "--- a count GitHub has never given is unknown, not zero ---"
fix_live "" 2
fix_at "$NOW"
rm -f "$STATE/swarm/hold-prs.count"
# A gh that FAILS, which is a different world from a gh that answers zero — the
# fixture's own stub answers zero for a question it has no file for, and zero is
# a real answer. Only the failure is unknown.
printf '#!/usr/bin/env bash\nexit 1\n' > "$BIN/gh-down"; chmod +x "$BIN/gh-down"
out=$(SWARM_GH="$BIN/gh-down" bash "$SL" --print 2>&1)
want_in     "the agents half still lands" "2 agents working" "$out"
want_in     "and approvals are unknown"   "approvals unknown" "$out"
want_not_in "not silently none"           "needs you"         "$out"

echo "--- the render path reads the cache and calls nothing ---"
fresh
fix_live "" 3
fix_at "$NOW"
printf '[{"number":1},{"number":2}]\n' > "$FIX/gh/prs-all.json"
print >/dev/null
# Recorders for BOTH calls a compute must make. The earlier version of this case
# compared a gh log against itself after truncating it — 0 == 0 — and passed with
# the entire fast path deleted. The live view is the one a compute cannot avoid,
# so it is the one that proves the path was not taken.
CURL_LOG="$FIX/curl.log"; : > "$CURL_LOG"
cat > "$BIN/curl-rec" <<SH
#!/usr/bin/env bash
printf 'called\n' >> "$CURL_LOG"
exec "$BIN/curl" "\$@"
SH
chmod +x "$BIN/curl-rec"
: > "$GH_LOG"
out=$(SWARM_CURL="$BIN/curl-rec" SWARM_STATUS_NO_REFRESH=1 bash "$SL" --render 2>&1)
want "it prints the cached line"  "3 agents working · 2 need you" "$out"
want "the live view was not read" "0" "$(grep -c . "$CURL_LOG" | tr -d ' ')"
want "GitHub was not asked"       "0" "$(grep -c 'pr list' "$GH_LOG" | tr -d ' ')"

echo "--- the hold count is cached too, so a recompute does not re-ask ---"
fresh
fix_live "" 1
printf '[{"number":1},{"number":2},{"number":3}]\n' > "$FIX/gh/prs-all.json"
print >/dev/null
: > "$GH_LOG"
want "second compute agrees"  "1 agent working · 3 need you" "$(print)"
want "and asked GitHub again" "0" "$(grep -c 'pr list' "$GH_LOG" | tr -d ' ')"

echo "--- a cache older than the hard limit is stale, not current ---"
# Written deliberately, so the assertion below names the text that is actually
# there. Inherited from the previous case it said "1 agent working · 3 need you",
# and the old assertion looked for "3 agents" — a string that was never in it, so
# it passed whether or not the rule existed.
printf 'no agents working\n' > "$(cache)"
age_cache $((NOW - 3600))
out=$(render)
want_in     "the warning"           "not answering"     "$out"
want_not_in "never the stale line"  "no agents working" "$out"

echo "--- a MISSING cache is a cold start, not a stale answer ---"
fresh
fix_live "" 5
printf '[]\n' > "$FIX/gh/prs-all.json"
out=$(render)
# "approvals unknown" and not a count: a COLD render must not call the forge, so
# with nothing cached the honest word is unknown. The detached refresh fills it in.
want "it computes once, correctly" "5 agents working · approvals unknown" "$out"
want "and it wrote the cache"      "5 agents working · approvals unknown" "$(cat "$(cache)")"

echo "--- the other stat, which is the one CI runs ---"
# The same trick time.test.sh uses for `date`, for the same reason: this machine
# has one stat and the runner has the other, so the branch that matters here can
# only be reached through a stub.
#
# `stat -f %m` on GNU means file-SYSTEM. It treats %m as a filename, fails on it,
# and STILL prints six lines of filesystem blurb to stdout at exit 1 — so
# `stat -f %m || stat -c %Y` concatenated blurb with answer and `$(( now - … ))`
# died under set -u. A blank status line and exit 1 on every Linux render,
# measured in ubuntu:latest and green on macOS, which is how it nearly shipped.
mkdir -p "$FIX/gnu"
# The real stat, by absolute path: the stub shadows the name, so `command stat`
# inside it would re-enter the stub rather than reach the machine's own.
REAL_STAT=$(command -v stat)
# Which form this machine's stat really answers, decided HERE and baked in. The
# first version of this stub used `-f %m || -c %Y` inside itself and so reproduced
# the exact defect it exists to test: on Linux the -f form printed blurb to stdout
# at exit 1, the || ran anyway, and the stub answered blurb-plus-number.
if "$REAL_STAT" -c %Y "$HERE" >/dev/null 2>&1; then REAL_MT='-c %Y'; else REAL_MT='-f %m'; fi
cat > "$FIX/gnu/stat" <<SH
#!/usr/bin/env bash
R="$REAL_STAT"
case "\$1" in
  -f) # GNU: %m is read as a filename, and the blurb goes to STDOUT anyway
      echo "stat: cannot read file system information for '\$2'" >&2
      printf '  File: "%s"\\n    ID: 0 Namelen: 255 Type: overlayfs\\n' "\$3"
      exit 1 ;;
  -c) [ -e "\$3" ] || exit 1
      "\$R" $REAL_MT "\$3" ;;
  *)  exit 1 ;;
esac
SH
chmod +x "$FIX/gnu/stat"
# Proof the stub is in the way before anything is concluded from it.
if PATH="$FIX/gnu:$PATH" stat -f %m "$(cache)" >/dev/null 2>&1; then
  bad "the gnu stat stub is not in the way"
else
  ok "the stub refuses -f %m, as GNU stat does"
fi
fresh
fix_live "" 3
printf '[{"number":1}]\n' > "$FIX/gh/prs-all.json"
print >/dev/null
out=$(PATH="$FIX/gnu:$PATH" SWARM_STATUS_NO_REFRESH=1 bash "$SL" --render 2>&1)
want     "the cached line, under the other stat" "3 agents working · 1 needs you" "$out"
want_not_in "no shell error escaped"             "unbound variable|File:"         "$out"
want     "and it is still one line"              "1" "$(printf '%s\n' "$out" | wc -l | tr -d ' ')"

echo "--- a stat that answers nonsense is not an mtime ---"
# The ordering above is the fix; this is the guard behind it. A stat that answers
# something other than digits — a wrapper, a busybox, a locale — must not reach
# the arithmetic, where under set -u it is fatal rather than merely wrong.
mkdir -p "$FIX/oddstat"
cat > "$FIX/oddstat/stat" <<'SH'
#!/usr/bin/env bash
echo "mtime: not a number"
exit 0
SH
chmod +x "$FIX/oddstat/stat"
fresh
fix_live "" 2
printf '[]\n' > "$FIX/gh/prs-all.json"
print >/dev/null
out=$(PATH="$FIX/oddstat:$PATH" SWARM_STATUS_NO_REFRESH=1 bash "$SL" --render 2>&1)
want_not_in "no shell error"        "unbound variable|integer expression" "$out"
want        "still one line"        "1" "$(printf '%s\n' "$out" | wc -l | tr -d ' ')"
# An mtime of 0 makes the cache look ancient, which is the SAFE reading: the
# warning, not a count it cannot date.
want_in     "and it errs toward the warning" "not answering" "$out"

echo "--- a limit that is not a number falls back to the default ---"
# `[ "$age" -gt "120s" ]` returns 2, which a plain `if` reads as "not stale" — so
# one typo in an env var would show a stale count for as long as the window was
# open, with nothing said.
fresh
fix_live "" 4
printf '[]\n' > "$FIX/gh/prs-all.json"
print >/dev/null
age_cache $((NOW - 3600))
out=$(SWARM_STATUS_MAX_AGE=120s SWARM_STATUS_NO_REFRESH=1 bash "$SL" --render 2>&1)
want_in     "the default still applies" "not answering" "$out"
want_not_in "not the stale count"       "4 agents"      "$out"

echo "--- one line, always ---"
fix_live "" 3
fix_at "$NOW"
want "print is one line"  "1" "$(print | wc -l | tr -d ' ')"
want "render is one line" "1" "$(render | wc -l | tr -d ' ')"

echo "--- it names no ticket numbers ---"
fix_live "" 2
fix_at "$NOW"
jq '.live[0].ticket = "10932" | .live[0].title = "Status line in every window"' "$FIX/live.json" > "$FIX/live.json.t" && mv "$FIX/live.json.t" "$FIX/live.json"
out=$(print)
want_not_in "no ticket number" "10932" "$out"
want_not_in "no title"         "Status line" "$out"

echo "--- a 200 that is not a snapshot is not zero agents ---"
# `jq '.live | length'` answers 0 for a body with no `live` key, because in jq
# `null | length` is 0. So anything on the port returning 200 JSON that is not the
# snapshot shape — an older server, a proxy error body, another process — printed
# the exact sentence this file exists to forbid.
for body in '{"error":"live view broke"}' '{"at":"REPLACE","load":1}' '{"at":"REPLACE","live":{"a":1,"b":2}}'; do
  fresh
  printf '%s\n' "${body/REPLACE/$(swarm_iso "$NOW")}" > "$FIX/live.json"
  printf '[]\n' > "$FIX/gh/prs-all.json"
  out=$(print)
  want_not_in "not zero agents for: $body" "no agents working" "$out"
  want_in     "the warning instead"        "not answering"     "$out"
done

echo "--- the detached refresh runs one at a time ---"
fresh
fix_live "" 3
printf '[]\n' > "$FIX/gh/prs-all.json"
print >/dev/null
age_cache $((NOW - 60))          # older than TTL, younger than MAX_AGE
mkdir -p "$(cache).lock"          # a refresh already in flight
touch_at "$NOW" "$(cache).lock"
: > "$FIX/spawns2.log"
cat > "$BIN/detach-rec" <<SH
#!/usr/bin/env bash
printf 'spawn\n' >> "$FIX/spawns2.log"
SH
chmod +x "$BIN/detach-rec"
# The refresh is detached, so a fixed sleep is a race — and it lost one, reporting
# zero spawns for a child that had simply not written yet. Poll for the answer,
# bounded, and settle only when it stops moving.
spawns() { grep -c . "$FIX/spawns2.log" 2>/dev/null | tr -d ' '; }
bash_render() { # <expected spawns>
  SWARM_DETACH="$BIN/detach-rec" bash "$SL" --render >/dev/null 2>&1
  local i=0
  while [ "$(spawns)" != "${1:-0}" ] && [ $i -lt 50 ]; do sleep 0.1; i=$((i+1)); done
  sleep 0.2   # and a beat past it, so an EXTRA spawn is still visible
}
bash_render 0
want "a held lock blocks a second refresh" "0" "$(spawns)"
rmdir "$(cache).lock"
bash_render 1
want "and a free lock lets one through"    "1" "$(spawns)"

echo "--- a dead refresher's lock does not wedge it forever ---"
fresh; fix_live "" 3; printf '[]\n' > "$FIX/gh/prs-all.json"; print >/dev/null
age_cache $((NOW - 60))
mkdir -p "$(cache).lock"; touch_at $((NOW - 7200)) "$(cache).lock"
: > "$FIX/spawns2.log"
bash_render 1
want "a lock older than MAX_AGE is broken" "1" "$(spawns)"

echo "--- a cold render never calls the forge ---"
# It cannot: gh has no timeout we can set, and swarm-env.sh records it hanging on
# a keychain prompt. A render that hangs is a window with no status line at all.
fresh
fix_live "" 2
printf '[{"number":1},{"number":2},{"number":3}]\n' > "$FIX/gh/prs-all.json"
: > "$GH_LOG"
out=$(render)
want    "the agents half lands"  "2 agents working · approvals unknown" "$out"
want    "the forge was not read" "0" "$(grep -c 'pr list' "$GH_LOG" | tr -d ' ')"
# …and the detached refresh, which MAY call it, fills the count in.
want_in "a full compute has it"  "3 need you" "$(print)"

echo "--- install writes a statusLine the CLI will run ---"
SETTINGS="$FIX/settings.json"
printf '{"model":"opus"}\n' > "$SETTINGS"
CLAUDE_SETTINGS="$SETTINGS" bash "$SL" --install >/dev/null
want     "type is command"   "command" "$(jq -r '.statusLine.type' "$SETTINGS")"
want_in  "it points at us"   "status-line\.sh"  "$(jq -r '.statusLine.command' "$SETTINGS")"
want     "nothing else lost" "opus" "$(jq -r '.model' "$SETTINGS")"

echo "--- install is idempotent, and uninstall leaves the rest alone ---"
CLAUDE_SETTINGS="$SETTINGS" bash "$SL" --install >/dev/null
want "still one statusLine" "1" "$(jq '[paths|select(.[-1]=="statusLine")]|length' "$SETTINGS")"
CLAUDE_SETTINGS="$SETTINGS" bash "$SL" --uninstall >/dev/null
want "statusLine gone"      "null" "$(jq -r '.statusLine // "null"' "$SETTINGS")"
want "model kept"           "opus" "$(jq -r '.model' "$SETTINGS")"

echo "--- the command it installs survives a space in the kit's path ---"
# A kit under "Application Support" or a user's "My Kit" is ordinary. The
# unquoted version wrote `bash /a path/x.sh`, which resolves to nothing — and
# --install printed "now runs …" all the same, so the report of success was the
# only evidence anyone had.
SPACED="$FIX/my kit"; mkdir -p "$SPACED"
cp "$HERE/../status-line.sh" "$SPACED/status-line.sh"
printf '{}\n' > "$SETTINGS"
CLAUDE_SETTINGS="$SETTINGS" bash "$SPACED/status-line.sh" --install >/dev/null
CMD=$(jq -r '.statusLine.command' "$SETTINGS")
want_in "the path is quoted" "'" "$CMD"
# The real test is whether a shell can run it, which is what the CLI does.
sh -c "$CMD --help" >/dev/null 2>&1 && ok "a shell can run what was installed" \
  || bad "a shell cannot run what was installed: $CMD"

echo "--- the refresh writes the cache the RENDER path read ---"
# Two resolutions of one path: the render path reads the recorded state dir, and
# compute used to derive its own from the checkout's config. On a machine with two
# projects that put a window reading a cache nothing was refreshing, and after
# MAX_AGE it read "not answering" for good.
fresh
fix_live "" 7
printf '[]\n' > "$FIX/gh/prs-all.json"
OTHER="$FIX/other-project"; mkdir -p "$OTHER/swarm"
bash "$SL" --refresh "$OTHER/swarm/status-line.txt" >/dev/null 2>&1
want "it wrote the path it was given" "7 agents working" "$(cat "$OTHER/swarm/status-line.txt" 2>/dev/null)"
want "and not the one it derived"     ""                 "$(cat "$(cache)" 2>/dev/null)"

echo "--- install refuses to write settings it cannot parse ---"
printf '{oops\n' > "$SETTINGS"
CLAUDE_SETTINGS="$SETTINGS" bash "$SL" --install >/dev/null 2>&1 && bad "it should have refused" || ok "it refused"
want "and left the file alone" "{oops" "$(cat "$SETTINGS")"

exit "$FAILED"
