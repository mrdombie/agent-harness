#!/usr/bin/env bash
# Fixture test for disk-guard.sh — owner call 2026-10-20, "Auto-clean and stop below 30 GB".
#
# On 2026-10-20 the data volume reached 0.1 GB free and nothing could start a shell. The guard holds
# starts from under 30 GB until 50 GB is free, and frees space in a fixed order until it is.
#
# Free space is a fake reader: a base figure plus the GB "weight" of each planted folder that is
# gone, so a removal frees exactly what the case says. lsof is a fake that answers from a file.
# Every folder that only one keep-rule protects is checked to survive, so deleting that rule
# deletes a folder this suite then finds missing.
set -uo pipefail
for v in $(env | sed -n 's/^\(GIT_[A-Z_]*\)=.*/\1/p'); do unset "$v"; done
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUT="$HERE/disk-guard.sh"
[ -f "$SUT" ] || { echo "missing $SUT"; exit 2; }

SB=$(mktemp -d "${TMPDIR:-/tmp}/disk-guard-test-XXXXXX"); SB=$(cd "$SB" && pwd -P)
trap 'rm -rf "$SB"' EXIT
fail=0
ok()  { echo "  ok   — $1"; }
bad() { echo "  FAIL — $1"; fail=1; }
want()        { [ "$2" = "$3" ] && ok "$1" || bad "$1 — wanted '$2', got '$3'"; }
want_in()     { printf '%s' "$3" | grep -qE -- "$2" && ok "$1" || { bad "$1 — no /$2/ in:"; printf '%s\n' "$3" | sed 's/^/        /' | head -40; }; }
want_not_in() { printf '%s' "$3" | grep -qE -- "$2" && { bad "$1 — /$2/ found in:"; printf '%s\n' "$3" | sed 's/^/        /' | head -40; } || ok "$1"; }
G() { git -c user.email=t@example.com -c user.name=tester -c commit.gpgsign=false -c init.defaultBranch=develop "$@"; }

BIN="$SB/bin"; STATE="$SB/state"; TMPR="$SB/tmp"; WT="$SB/wt"; SCR="$SB/scratch"
mkdir -p "$BIN" "$STATE/coordinator" "$STATE/runs"

# free = base + the weight of every listed path that no longer exists.
cat > "$BIN/dgfree" <<'SH'
#!/usr/bin/env bash
base=$(cat "$DG_BASE"); add=0
while IFS=$'\t' read -r p w; do [ -n "$p" ] && [ ! -e "$p" ] && add=$((add + w)); done < "$DG_WEIGHTS"
echo $((base + add))
SH
# lsof: the planted table, whatever it is asked.
cat > "$BIN/lsof" <<'SH'
#!/usr/bin/env bash
cat "$DG_LSOF" 2>/dev/null
SH
# The orphan sweep: records its call and removes the folder it would have found.
cat > "$BIN/sweep" <<'SH'
#!/usr/bin/env bash
echo "sweep $*" >> "$DG_SWEEP_LOG"
[ "${1:-}" = --apply ] && rm -rf "$DG_ORPHAN"
echo "removed orphan"
SH
# The claim list (claim-lock.sh list --json): the planted file; unreadable when it is missing.
cat > "$BIN/claimlist" <<'SH'
#!/usr/bin/env bash
cat "$DG_CLAIMS"
SH
chmod +x "$BIN"/*

ORIGIN="$SB/origin.git"; MAIN="$SB/main"
G init -q --bare "$ORIGIN"
G clone -q "$ORIGIN" "$MAIN" 2>/dev/null
printf 'one\n' > "$MAIN/a.txt"; printf 'node_modules\n.next\ndist\n' > "$MAIN/.gitignore"
G -C "$MAIN" add -A; G -C "$MAIN" commit -qm base; G -C "$MAIN" push -q origin HEAD:develop 2>/dev/null
G -C "$MAIN" fetch -q origin
printf '{"repo":"example/thing","integrationBranch":"develop","branchPrefix":"tkt-","sisterRepos":[]}\n' > "$SB/cfg.json"

guard() { # <args…> — the SUT with every root in the fixture
  PATH="$BIN:$PATH" HOME="$SB" HARNESS_MAIN_REPO="$MAIN" HARNESS_REPO_ROOT="$MAIN" HARNESS_CFG_PATH="$SB/cfg.json" \
  HARNESS_STATE_DIR="$STATE" COORDINATOR_DF="$BIN/dgfree" DG_BASE="$SB/base" DG_WEIGHTS="$SB/weights" DG_LSOF="$SB/lsof.txt" \
  DG_SWEEP_LOG="$SB/sweep.log" DG_ORPHAN="$SB/orphan" WT_CLAIM_LIST="$BIN/claimlist" DG_CLAIMS="$SB/claims.json" \
  DISK_GUARD_TMP="$TMPR" DISK_GUARD_BUILD_ROOT="$WT" DISK_GUARD_SCRATCH_ROOT="$SCR" DISK_GUARD_SWEEP="$BIN/sweep" \
  DISK_GUARD_HOLD_FILE="$STATE/coordinator/disk-hold" DISK_GUARD_SCRATCH_MB=1 \
  bash "${GUARD_SUT:-$SUT}" "$@" 2>&1
}
free_is() { printf '%s\n' "$1" > "$SB/base"; }
weigh() { printf '%s\t%s\n' "$1" "$2" >> "$SB/weights"; }
old() { find "$@" -exec touch -h -t 202001010000 {} + 2>/dev/null; }
wt_at() { G -C "$MAIN" worktree add -q --detach "$1" origin/develop; }

# ---------------------------------------------------------------- the world --
build_world() {
  rm -rf "$TMPR" "$WT" "$SCR" "$SB/orphan"; G -C "$MAIN" worktree prune
  mkdir -p "$TMPR" "$WT" "$SCR/proj/sess1/scratchpad" "$SCR/proj/sess2/scratchpad" "$SB/orphan"
  : > "$SB/weights"; : > "$SB/lsof.txt"; : > "$SB/sweep.log"; rm -f "$STATE/coordinator/disk-hold"
  printf '[]\n' > "$SB/claims.json"
  for r in $(G -C "$MAIN" ls-remote origin 'refs/claims/*' | cut -f2); do G -C "$MAIN" push -q origin ":$r" 2>/dev/null; done
  # a. driver proofs: one finished, one in use, one recent, one holding a plant.
  wt_at "$TMPR/driver-proof-done/before"; G -C "$MAIN" show HEAD:a.txt > "$TMPR/driver-proof-done/before/copy.txt"
  wt_at "$TMPR/driver-proof-busy/before"
  wt_at "$TMPR/driver-proof-fresh/before"
  wt_at "$TMPR/driver-proof-plant/before"; printf 'planted, in no commit\n' > "$TMPR/driver-proof-plant/before/a.txt"
  weigh "$TMPR/driver-proof-done" 3
  # b. spawn checkouts: an old one, the current one, one with a commit nothing else holds.
  wt_at "$TMPR/harness-spawn-old"; : > "$TMPR/harness-spawn-old.ready"
  wt_at "$TMPR/harness-spawn-lost"
  printf 'two\n' > "$TMPR/harness-spawn-lost/a.txt"; G -C "$TMPR/harness-spawn-lost" commit -qam "work on no branch"
  wt_at "$TMPR/harness-spawn-current"
  weigh "$TMPR/harness-spawn-old" 3
  # c. build folders: an idle one, one a process sits in, one with uncommitted work.
  for b in idle busy dirty; do
    G -C "$MAIN" worktree add -q "$WT/$b" -B "tkt-$b" origin/develop
    mkdir -p "$WT/$b/node_modules/pkg" "$WT/$b/.next"; printf 'x\n' > "$WT/$b/node_modules/pkg/i.js"; printf 'x\n' > "$WT/$b/.next/o"
  done
  printf 'not committed\n' > "$WT/dirty/new.txt"
  # A build whose ticket holds a claim on origin, one another host's claim names by path, one just
  # touched: each keeps its install however idle the rest of it looks.
  for b in sh-13621-claimed listed fresh; do
    G -C "$MAIN" worktree add -q "$WT/$b" -B "tkt-$b" origin/develop
    mkdir -p "$WT/$b/node_modules/pkg"; printf 'x\n' > "$WT/$b/node_modules/pkg/i.js"
  done
  G -C "$MAIN" push -q origin develop:refs/claims/13621 2>/dev/null
  jq -n --arg w "$WT/listed" '[{issue: 4242, worktree: $w, branch: "tkt-4242/x", host: "other-mac"}]' > "$SB/claims.json"
  weigh "$WT/idle/node_modules" 4
  # d. the orphan sweep frees 2.
  weigh "$SB/orphan" 2
  # e. scratchpads: a stale big folder, a big one in use, a small one.
  mkdir -p "$SCR/proj/sess1/scratchpad/big" "$SCR/proj/sess2/scratchpad/inuse" "$SCR/proj/sess1/scratchpad/small"
  dd if=/dev/zero of="$SCR/proj/sess1/scratchpad/big/blob" bs=1024 count=2048 2>/dev/null
  dd if=/dev/zero of="$SCR/proj/sess2/scratchpad/inuse/blob" bs=1024 count=2048 2>/dev/null
  printf 'x\n' > "$SCR/proj/sess1/scratchpad/small/f"
  weigh "$SCR/proj/sess1/scratchpad/big" 5
  old "$TMPR" "$WT" "$SCR"
  touch -t 202001020000 "$TMPR/harness-spawn-current"
  touch "$TMPR/driver-proof-fresh/before/a.txt" "$WT/fresh/a.txt"
  printf 'p4242\nn%s/node_modules/pkg/i.js\np4243\nn%s/before\np4244\nn%s/blob\n' \
    "$WT/busy" "$TMPR/driver-proof-busy" "$SCR/proj/sess2/scratchpad/inuse" > "$SB/lsof.txt"
}
order_of() { printf '%s\n' "$1" | sed -nE 's/.*disk-clean: (removed [a-z]+ [a-z]+|cleaned node_modules|orphan-worktree sweep).*/\1/p' | awk '!seen[$0]++' | tr '\n' '|'; }

echo "--- the hold: under 30 GB it holds, and only 50 GB lets it go ---"
build_world
free_is 40; out=$(guard tick); rc=$?
want "40 GB, nothing held before: not held" "0" "$rc"
free_is 29; out=$(guard tick); rc=$?
want "29 GB: held" "1" "$rc"
want_in "with the hold reason and the free figure first" '^29	disk low: 29 GB free, under 30 GB' "$out"
[ -f "$STATE/coordinator/disk-hold" ] && ok "the hold is written down" || bad "no hold file after going under the floor"
free_is 31; out=$(guard tick); rc=$?
want "31 GB, back over the floor but under the resume mark: still held" "1" "$rc"
free_is 49; out=$(guard tick); rc=$?
want "49 GB: still held" "1" "$rc"
free_is 50; out=$(guard tick); rc=$?
want "50 GB: let go" "0" "$rc"
want_in "and it says starts resume" 'at or above 50 GB — starts resume' "$out"
[ -f "$STATE/coordinator/disk-hold" ] && bad "the hold file outlived the resume" || ok "the hold file is gone"
free_is 31; out=$(guard tick); rc=$?
want "31 GB with no hold before: not held (the band only keeps a hold)" "0" "$rc"
out=$(COORDINATOR_DISK_STOP_BELOW_GB=40 COORDINATOR_DISK_RESUME_AT_GB=60 guard limits)
want "the floor and the mark are settings" "40 60" "$out"
out=$(COORDINATOR_DISK_STOP_BELOW_GB=40 COORDINATOR_DISK_RESUME_AT_GB=20 guard limits)
want "a resume mark under the floor is raised to it" "40 40" "$out"

echo "--- check: a long one-off job refuses under the floor ---"
free_is 29; out=$(guard check "a build"); rc=$?
want "29 GB: refused" "1" "$rc"
want_in "saying how much is free and what it needs" '^disk low: 29 GB free, under the 30 GB a build needs' "$out"
free_is 30; out=$(guard check "a build"); rc=$?
want "30 GB: goes ahead" "0" "$rc"
free_is 5; out=$(HARNESS_DISK_GUARD=off guard check "a build"); rc=$?
want "the operator's off switch lets it through" "0" "$rc"

echo "--- the clean: in order, until 50 GB, keeping what is in use, recent or holds work ---"
build_world; free_is 20
out=$(guard clean --apply)
want "the passes ran in order" "removed driver proof|removed spawn checkout|cleaned node_modules|orphan-worktree sweep|removed scratchpad folder|" "$(order_of "$out")"
[ -d "$TMPR/driver-proof-done" ] && bad "a finished proof survived" || ok "a finished proof is removed (its copied test is content git holds)"
[ -d "$TMPR/driver-proof-busy" ] && ok "a proof a process has open is kept" || bad "a proof in use was removed"
want_in "  and says why" 'keep .*driver-proof-busy — in use \(pid 4243' "$out"
[ -d "$TMPR/driver-proof-fresh" ] && ok "a proof changed in the last 30 min is kept" || bad "a recent proof was removed"
[ -d "$TMPR/driver-proof-plant" ] && ok "a proof holding a change git does not hold is kept" || bad "a proof with a plant was removed"
want_in "  and names the change" 'driver-proof-plant — uncommitted change: a.txt' "$out"
[ -d "$TMPR/harness-spawn-old" ] && bad "an old spawn checkout survived" || ok "an old spawn checkout is removed"
[ -e "$TMPR/harness-spawn-old.ready" ] && bad "its .ready marker was left behind" || ok "with its .ready marker"
[ -d "$TMPR/harness-spawn-current" ] && ok "the current spawn checkout is kept" || bad "the current spawn checkout was removed"
[ -d "$TMPR/harness-spawn-lost" ] && ok "a spawn checkout with a commit nothing holds is kept" || bad "unpushed work was removed"
want_in "  and says why" 'harness-spawn-lost — 1 commit\(s\) on no remote' "$out"
[ -d "$WT/idle/node_modules" ] && bad "an idle build folder kept its install" || ok "an idle build folder's node_modules goes"
[ -d "$WT/idle/.next" ] && bad "and its .next stayed" || ok "and its build cache"
[ -f "$WT/idle/a.txt" ] && ok "and never its files" || bad "a build folder lost a tracked file"
[ -d "$WT/busy/node_modules" ] && ok "a build folder a process has open keeps its install" || bad "a busy build folder lost its install"
[ -d "$WT/dirty/node_modules" ] && ok "a build folder with uncommitted work is left whole" || bad "a dirty build folder was touched"
[ -d "$WT/sh-13621-claimed/node_modules" ] && ok "a build folder whose ticket holds a claim keeps its install" || bad "a claimed build folder lost its install"
want_in "  and says which claim" 'keep .*/sh-13621-claimed — claim #13621' "$out"
[ -d "$WT/listed/node_modules" ] && ok "a build folder another host's claim names keeps its install" || bad "a build folder claimed by path lost its install"
[ -d "$WT/fresh/node_modules" ] && ok "a build folder touched in the last 30 min keeps its install" || bad "a recently touched build folder lost its install"
want "the sweep ran with --apply" "sweep --apply" "$(cat "$SB/sweep.log")"
[ -d "$SCR/proj/sess1/scratchpad/big" ] && bad "a stale big scratchpad folder survived" || ok "a stale big scratchpad folder is removed"
[ -d "$SCR/proj/sess2/scratchpad/inuse" ] && ok "a scratchpad folder with a file open is kept" || bad "a scratchpad folder in use was removed"
[ -d "$SCR/proj/sess1/scratchpad/small" ] && ok "a small scratchpad folder is left alone" || bad "a small scratchpad folder was removed"
[ -d "$SCR/proj/sess1/scratchpad" ] && ok "the scratchpad itself is never removed" || bad "a whole scratchpad went"
want_in "each removal logs its size and the free space before and after" 'removed driver proof .*driver-proof-done \([0-9]+ MB\) — 20 GB free before, 23 GB after' "$out"
want_in "  the next one from where that left it" 'removed spawn checkout .*harness-spawn-old \([0-9]+ MB\) — 23 GB free before, 26 GB after' "$out"
want_in "  a build folder too" 'build folder .*/idle — 26 GB free before, 30 GB after' "$out"
want_in "  and the sweep" 'orphan-worktree sweep — 30 GB free before, 32 GB after' "$out"
want_in "it ends on the free space it reached" '37 GB free after every pass \(from 20 GB\) — still under 50 GB' "$out"
want "a removed proof's worktree record is pruned" "" "$(G -C "$MAIN" worktree list | grep driver-proof-done)"

echo "--- it stops as soon as the resume mark is reached ---"
build_world; free_is 20
out=$(COORDINATOR_DISK_STOP_BELOW_GB=25 COORDINATOR_DISK_RESUME_AT_GB=26 guard clean --apply)
want_in "it says where it stopped" '26 GB free, at or above 26 GB — stopping \(from 20 GB\)' "$out"
[ -d "$WT/idle/node_modules" ] && ok "the build folders were never reached" || bad "it went on cleaning past the mark"
want "nor the sweep" "" "$(cat "$SB/sweep.log")"
[ -d "$SCR/proj/sess1/scratchpad/big" ] && ok "nor the scratchpads" || bad "a scratchpad was cleaned past the mark"

echo "--- a dry run removes nothing ---"
build_world; free_is 20
out=$(guard clean)
want_in "it says what it would remove" 'would remove driver proof .*driver-proof-done' "$out"
[ -d "$TMPR/driver-proof-done" ] && [ -d "$WT/idle/node_modules" ] && [ -d "$SCR/proj/sess1/scratchpad/big" ] \
  && ok "and everything is still there" || bad "a dry run removed something"
want "the sweep ran dry" "sweep " "$(cat "$SB/sweep.log")"

echo "--- without lsof nobody can tell who is using what, so nothing goes ---"
build_world; free_is 20
mkdir -p "$SB/nolsof"; for t in git jq awk sed find du df date dirname basename cat rm mkdir rmdir tr wc head tail sort cut grep id ps stat touch printf env bash sh sleep mktemp ls uname hostname readlink xargs perl python3 tee; do
  p=$(command -v "$t" 2>/dev/null) && [ "$p" != "$BIN/$t" ] && case "$p" in /*) ln -sf "$p" "$SB/nolsof/$t" ;; esac
done
out=$(PATH="$SB/nolsof" HOME="$SB" HARNESS_MAIN_REPO="$MAIN" HARNESS_REPO_ROOT="$MAIN" HARNESS_CFG_PATH="$SB/cfg.json" \
  HARNESS_STATE_DIR="$STATE" COORDINATOR_DF="$BIN/dgfree" DG_BASE="$SB/base" DG_WEIGHTS="$SB/weights" \
  DISK_GUARD_TMP="$TMPR" DISK_GUARD_BUILD_ROOT="$WT" DISK_GUARD_SCRATCH_ROOT="$SCR" DISK_GUARD_SWEEP="$BIN/sweep" \
  DISK_GUARD_HOLD_FILE="$STATE/coordinator/disk-hold" "$SB/nolsof/bash" "$SUT" clean --apply 2>&1)
want_in "it says so" 'no lsof here' "$out"
[ -d "$TMPR/driver-proof-done" ] && ok "and removes nothing" || bad "it removed a folder it could not see the users of"

echo "--- the claim list unreadable: nothing is removed anywhere ---"
build_world; free_is 20; rm -f "$SB/claims.json"
out=$(guard clean --apply)
want_in "it says so" 'the claim list could not be read .*cleaning nothing' "$out"
[ -d "$TMPR/driver-proof-done" ] && [ -d "$TMPR/harness-spawn-old" ] && [ -d "$WT/idle/node_modules" ] \
  && [ -d "$SCR/proj/sess1/scratchpad/big" ] && ok "and removes nothing, not even the idle folders" || bad "it removed something with the claims unread"
want "nor runs the sweep" "" "$(cat "$SB/sweep.log")"
build_world; free_is 20; G -C "$MAIN" remote set-url origin "$SB/no-such-origin.git"
out=$(guard clean --apply); G -C "$MAIN" remote set-url origin "$ORIGIN"
[ -d "$WT/idle/node_modules" ] && [ -d "$TMPR/driver-proof-done" ] && ok "origin's claim refs unreadable: nothing is removed either" \
  || bad "it removed something with origin unreachable"

echo "--- a recency test that errors keeps everything (bfs rejects a timestamp and prints nothing) ---"
build_world; free_is 20
mkdir -p "$SB/badfind"; printf '#!/usr/bin/env bash\necho "find: Invalid timestamp" >&2; exit 1\n' > "$SB/badfind/find"; chmod +x "$SB/badfind/find"
out=$(PATH="$SB/badfind:$PATH" guard clean --apply)
[ -d "$TMPR/driver-proof-done" ] && [ -d "$WT/idle/node_modules" ] && ok "a failing find removes nothing" || bad "a failing find let the idle test pass"

echo "--- plant the absence: the claim rule, deleted, loses the claimed build's install ---"
mkdir -p "$SB/kitc"; cp -R "$HERE" "$SB/kitc/scripts"
python3 -I - "$SB/kitc/scripts/worktree-lib.sh" <<'PY2'
import sys
p = sys.argv[1]; s = open(p).read()
t = [l for l in s.splitlines(True) if 'case "$WT_CLAIM_NUMS" in' in l]
assert len(t) == 1; open(p, "w").write(s.replace(t[0], "", 1))
PY2
grep -qF 'case "$WT_CLAIM_NUMS" in' "$SB/kitc/scripts/worktree-lib.sh" && bad "the claim plant did not land" || {
  build_world; free_is 20; GUARD_SUT="$SB/kitc/scripts/disk-guard.sh" guard clean --apply >/dev/null
  [ -d "$WT/sh-13621-claimed/node_modules" ] && bad "planted (claim by ticket): the claimed install survived, so this suite cannot see the rule" \
    || ok "planted (claim by ticket): the claimed build loses its install, so the rule is what kept it"
}
python3 -I - "$SB/kitc/scripts/disk-guard.sh" <<'PY2'
import sys
p = sys.argv[1]; s = open(p).read()
t = [l for l in s.splitlines(True) if 'if ! wt_claims_load "$CLAIM_REPO"' in l]
assert len(t) == 1; open(p, "w").write(s.replace(t[0], "", 1))
PY2
cp "$HERE/worktree-lib.sh" "$SB/kitc/scripts/worktree-lib.sh"
grep -qF 'if ! wt_claims_load "$CLAIM_REPO"' "$SB/kitc/scripts/disk-guard.sh" && bad "the unreadable plant did not land" || {
  build_world; free_is 20; rm -f "$SB/claims.json"; GUARD_SUT="$SB/kitc/scripts/disk-guard.sh" guard clean --apply >/dev/null
  [ -d "$SCR/proj/sess1/scratchpad/big" ] && bad "planted (claims unread): the scratchpad folder survived, so this suite cannot see the rule" \
    || ok "planted (claims unread): a folder goes, so the stop is what kept everything"
}

echo "--- plant the absence: each keep-rule, deleted, loses the folder it alone protects ---"
# In a copy of the kit's scripts, never the tree under test.
echo "--- WSL: the lower of Linux's disk and the Windows drive under it, and which bound ---"
# Live 2026-10-20: Linux's df showed 831 GB free on the virtual disk while Windows C:, which
# holds it, had 37 GB (99% full). df here answers per path; every path it is asked is logged.
WB="$SB/wslbin"; WP="$SB/proc"; mkdir -p "$WB"
cat > "$WB/df" <<'SH'
#!/usr/bin/env bash
p="${*: -1}"; printf '%s\n' "$p" >> "$DF_LOG"
kb=$DF_LINUX_KB; [ "$p" = "$DF_HOST_PATH" ] && kb=$DF_HOST_KB
printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\n/dev/x 1 1 %s 99%% %s\n' "$kb" "$p"
SH
chmod +x "$WB/df"
wsl_guard() { # <linux GB> <host GB> <args…> — the SUT reading the planted df, no free-space seam
  local l="$1" h="$2"; shift 2
  env -u COORDINATOR_DF -u COORDINATOR_FREE_GB PATH="$WB:$PATH" HOME="$SB" HARNESS_STATE_DIR="$STATE" \
    HARNESS_MAIN_REPO="$MAIN" HARNESS_REPO_ROOT="$MAIN" HARNESS_CFG_PATH="$SB/cfg.json" \
    DISK_GUARD_PROC="$WP" DISK_GUARD_HOLD_FILE="$SB/wsl-hold" DF_LOG="$SB/df.log" WSL_DISTRO_NAME="${WSL_DISTRO_NAME:-}" \
    DF_LINUX_KB=$(( l * 1048576 )) DF_HOST_KB=$(( h * 1048576 )) DF_HOST_PATH="${DF_HOST_PATH:-/mnt/c}" \
    bash "$SUT" "$@" 2>&1
}
proc_is() { rm -rf "$WP"; mkdir -p "$WP/sys/fs/binfmt_misc"; printf '%s\n' "$1" > "$WP/version"; }
proc_is 'Linux version 6.6.36.6-microsoft-standard-WSL2 (gcc) #1 SMP'
rm -f "$SB/wsl-hold"
want "WSL by /proc/version: free is the Windows host's 37, not Linux's 831" "37" "$(wsl_guard 831 37 free)"
want "the tick names the drive that bound, and what Linux shows" \
  "37	disk: 37 GB free on the Windows host (Linux shows 831)" "$(wsl_guard 831 37 tick)"
out=$(wsl_guard 831 12 check "a build"); rc=$?
want "12 GB on the host: a build is refused though Linux shows 831" "1" "$rc"
want "and the refusal says where" "disk low: 12 GB free on the Windows host (Linux shows 831), under the 30 GB a build needs" "$out"
out=$(wsl_guard 831 12 tick); rc=$?
want "and the coordinator's hold holds on the host figure" "1" "$rc"
rm -f "$SB/wsl-hold"
want "Linux the lower: Linux binds, and says so" \
  "70	disk: 70 GB free on Linux (the Windows host shows 400)" "$(wsl_guard 70 400 tick)"
proc_is 'Linux version 6.1.0 (gcc) #1 SMP generic'
: > "$WP/sys/fs/binfmt_misc/WSLInterop"
want "WSL by WSLInterop alone" "37" "$(wsl_guard 831 37 free)"
proc_is 'Linux version 6.1.0 (gcc) #1 SMP generic'
want "WSL by WSL_DISTRO_NAME alone" "37" "$(WSL_DISTRO_NAME=Ubuntu wsl_guard 831 37 free)"
want "coordinator.disk.hostPath picks the drive read" "41" \
  "$(DF_HOST_PATH=/mnt/d COORDINATOR_DISK_HOST_PATH=/mnt/d WSL_DISTRO_NAME=Ubuntu wsl_guard 831 41 free)"
want "and host names it" "/mnt/d" "$(COORDINATOR_DISK_HOST_PATH=/mnt/d WSL_DISTRO_NAME=Ubuntu wsl_guard 1 1 host)"

echo "--- not WSL: one reading, the line as before ---"
proc_is 'Linux version 6.1.0 (gcc) #1 SMP generic'; : > "$SB/df.log"; rm -f "$SB/wsl-hold"
want "free is the one volume's"      "831" "$(wsl_guard 831 37 free)"
want "the tick line carries no host" "831	disk: 831 GB free" "$(wsl_guard 831 37 tick)"
want_not_in "and no Windows drive is read" '^/mnt/c$' "$(cat "$SB/df.log")"
want "host is empty" "" "$(wsl_guard 1 1 host)"

mkdir -p "$SB/kit"; cp -R "$HERE" "$SB/kit/scripts"; PSUT="$SB/kit/scripts/disk-guard.sh"
plant() { # <label> <exact line> <folder that must then be removed>
  cp "$PSUT" "$SB/sut.bak"
  python3 - "$PSUT" "$2" <<'PY' || { bad "plant did not land: $1"; cp "$SB/sut.bak" "$PSUT"; return; }
import sys
p, line = sys.argv[1], sys.argv[2]
s = open(p).read()
assert s.count(line) == 1, "line not found once"
open(p, "w").write(s.replace(line, "", 1))
PY
  grep -qF -- "$2" "$PSUT" && { bad "plant did not land: $1"; cp "$SB/sut.bak" "$PSUT"; return; }
  build_world; free_is 20; GUARD_SUT="$PSUT" guard clean --apply >/dev/null
  [ -d "$3" ] && bad "planted ($1): the folder survived, so this suite cannot see the rule" \
              || ok "planted ($1): the folder is lost, so the rule is what kept it"
  cp "$SB/sut.bak" "$PSUT"
}
plant "in use"     '  if pid=$(holder "$real"); then printf '"'"'in use (pid %s has a file or its cwd there)'"'"' "$pid"; return 0; fi' "$TMPR/driver-proof-busy"
plant "recent"     '  if recent "$d" "$2"; then printf '"'"'changed in the last %s min'"'"' "$2"; return 0; fi' "$TMPR/driver-proof-fresh"
plant "lost work"  '    if why=$(lost_work "$c"); then printf '"'"'%s in %s'"'"' "$why" "${c#"$d"/}"; return 0; fi' "$TMPR/driver-proof-plant"
plant "current"    '  [ "$d" = "$CURRENT" ] && { keep "$d" "the current spawn checkout"; continue; }' "$TMPR/harness-spawn-current"
build_world; free_is 20; out=$(GUARD_SUT="$PSUT" guard clean --apply)
[ -d "$TMPR/driver-proof-busy" ] && [ -d "$TMPR/driver-proof-plant" ] && [ -d "$TMPR/harness-spawn-current" ] \
  && ok "the copy, restored, keeps all four again" || bad "the planted copy was not restored"

exit $fail
