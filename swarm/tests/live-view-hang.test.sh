#!/usr/bin/env bash
# live-view-hang.test.sh — the live view keeps answering when what it refreshes
# from fails: a full disk under every cache write, a refresh whose child never
# lets go of its pipe.
#
# Measured 2026-10-20: the process was alive and every request timed out for an
# hour, from about when the disk filled. launchd restarts it only when it exits.
# Run: bash "$0"
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/tests/lib/suite.sh" || exit 1
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/fixture.sh"
swarm_fixture
on_exit_keep_status 'for p in $(cat "$FIX"/hold-pids "$FIX"/hold-kids 2>/dev/null); do kill -9 "$p" 2>/dev/null; done; rm -rf "$FIX"'
command -v node >/dev/null 2>&1 || { suite_skip "SKIP live-view-hang: node is not on PATH"; }
LV="$HERE/../live-view"

printf '{"run_id":"claim-501-a","ticket":"501","child_pid":%s,"started_at":"%s","log":"%s"}\n' \
  "$$" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$STATE/logs/claim-501.log" > "$STATE/runs/claim-501-a.json"
: > "$STATE/logs/claim-501.log"

# serve <live-view dir> <requests> <gap-ms> [enospc] — one line per request: its status
# and how many live rows it carried, or "none" when it did not answer within 3 s.
serve() {
  SWARM_RUNS_DIR="$STATE/runs" SWARM_REPO=acme/widgets SWARM_TITLES="$FIX/titles.json" SWARM_GH="$BIN/gh" \
  SWARM_PROGRESS_CACHE="$FIX/progress.json" SWARM_BOARD_FILE="$FIX/board.json" SWARM_TREND_FILE="$FIX/trend.json" \
  SWARM_PLAIN_TITLES="$FIX/plain.json" SWARM_SERVER_MJS="$1/server.mjs" N="$2" GAP="$3" ENOSPC="${4:-}" \
  node --input-type=module -e "
    import fs from 'node:fs'
    import { pathToFileURL } from 'node:url'
    if (process.env.ENOSPC) {
      const boom = (n) => () => { const e = new Error('ENOSPC: no space left on device, ' + n); e.code = 'ENOSPC'; throw e }
      for (const n of ['writeFileSync', 'appendFileSync', 'renameSync', 'mkdirSync']) fs[n] = boom(n)
    }
    const { serve } = await import(pathToFileURL(process.env.SWARM_SERVER_MJS).href)
    const srv = serve(0)
    srv.on('listening', async () => {
      const port = srv.address().port
      for (let i = 0; i < Number(process.env.N); i++) {
        try {
          const r = await fetch('http://127.0.0.1:' + port + '/api/agents', { signal: AbortSignal.timeout(3000) })
          const j = await r.json().catch(() => ({}))
          console.log(r.status, Array.isArray(j.live) ? j.live.length : 'no-live')
        } catch { console.log('none') }
        await new Promise((r) => setTimeout(r, Number(process.env.GAP)))
      }
      process.exit(0)
    })" 2>"${SERVE_ERR:-/dev/null}"
}

echo "--- every cache write failing with ENOSPC: the page still answers ---"
out=$(SWARM_PROGRESS_SYNC=1 serve "$LV" 3 100 enospc)
want "three answers, each with the live run" "200 1|200 1|200 1" "$(printf '%s' "$out" | paste -sd'|' -)"

# Plant: the progress cache write unguarded and its refresh called bare. The
# request must then fail, or the case above cannot see a failing write at all.
P="$FIX/lv-plant"; mkdir -p "$P"; cp "$LV"/*.mjs "$LV"/index.html "$P/"
python3 - "$P/server.mjs" <<'PY' || bad "plant did not land"
import sys
p = sys.argv[1]; s = open(p).read()
a = "      fs.writeFileSync(PROGRESS_CACHE, JSON.stringify(next))\n    } catch (e) { warn('progress cache', e) }"
b = "  guard('progress', () => refreshProgress("
if s.count(a) != 1 or s.count(b) != 1: sys.exit(1)
s = s.replace(a, "      fs.writeFileSync(PROGRESS_CACHE, JSON.stringify(next))\n    } finally {}")
s = s.replace("if (process.env.SWARM_PROGRESS_SYNC) { try { keep(gatherProgress(args)) } catch {} ; return }",
              "if (process.env.SWARM_PROGRESS_SYNC) { keep(gatherProgress(args)); return }")
open(p, "w").write(s.replace(b, "  ;((f) => f())(() => refreshProgress("))
PY
grep -q "keep(gatherProgress(args)); return" "$P/server.mjs" || bad "plant: the sync refresh is still guarded"
out=$(SWARM_PROGRESS_SYNC=1 serve "$P" 3 100 enospc)
[ "$(printf '%s' "$out" | paste -sd'|' -)" != "200 1|200 1|200 1" ] && ok "planted: the write unguarded → the page fails → red" \
  || bad "planted: the write unguarded and the page still answered → the test cannot see it"

echo "--- a refresh whose child never lets go is killed at its deadline, and runs one at a time ---"
# The hold script leaves a grandchild holding its stdout: execFile's own timeout
# kills the script and its callback still never comes.
cat > "$BIN/stuck-hold" <<'SH'
#!/usr/bin/env bash
echo $$ >> "$FIX/hold-pids"
sleep 600 &
echo $! >> "$FIX/hold-kids"
wait
SH
chmod +x "$BIN/stuck-hold"
stuck() { # <live-view dir> — "<starts> <first grandchild alive: 1|0> <answers>"
  : > "$FIX/hold-pids"; : > "$FIX/hold-kids"
  local out first
  out=$(SWARM_HOLD_SCRIPT="$BIN/stuck-hold" SWARM_HOLD_MS=100 SWARM_REFRESH_TIMEOUT_MS=1000 serve "$1" 14 250)
  first=$(head -1 "$FIX/hold-kids")
  if [ -n "$first" ] && kill -0 "$first" 2>/dev/null; then first=1; else first=0; fi
  printf '%s %s %s' "$(grep -c . "$FIX/hold-pids")" "$first" "$(printf '%s\n' "$out" | grep -c '^200')"
  for p in $(cat "$FIX"/hold-pids "$FIX"/hold-kids); do kill -9 "$p" 2>/dev/null; done
}
read -r starts first answers <<<"$(stuck "$LV")"
want "every request answered"                        14 "$answers"
want "the first child's grandchild is gone"          0 "$first"
[ "${starts:-99}" -le 6 ] && ok "one at a time: $starts starts in 3.5 s at a 1 s deadline" \
  || bad "one at a time — $starts starts in 3.5 s at a 1 s deadline"
# Plant: execFile back, its own timeout, no in-flight flag — the code as it was.
P2="$FIX/lv-plant2"; mkdir -p "$P2"; cp "$LV"/*.mjs "$LV"/index.html "$P2/"
python3 - "$P2/server.mjs" <<'PY' || bad "plant 2 did not land"
import sys
p = sys.argv[1]; s = open(p).read()
a = "  holding = true\n  runChild('hold', BASH, [HOLD_SCRIPT], { timeout: 20_000 }, (err, out) => { holding = false; if (!err) take(out) })"
if s.count(a) != 1: sys.exit(1)
i = "import { execFileSync, spawn } from 'node:child_process'"
if s.count(i) != 1: sys.exit(1)
s = s.replace(i, "import { execFile, execFileSync, spawn } from 'node:child_process'")
open(p, "w").write(s.replace(a, "  execFile(BASH, [HOLD_SCRIPT], { timeout: 1000 }, (err, out) => { if (!err) take(out) })"))
PY
read -r starts first answers <<<"$(stuck "$P2")"
{ [ "$first" = 1 ] || [ "${starts:-0}" -gt 6 ]; } && ok "planted: execFile's own timeout → grandchild kept ($first), $starts starts → red" \
  || bad "planted: the old refresh and the test still passed ($starts starts, grandchild $first)"

suite_end "$FAILED"
