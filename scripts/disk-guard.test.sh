#!/usr/bin/env bash
# Fixture test for disk-guard.sh — owner call 2026-10-20, "Auto-clean and stop below 30 GB".
#
# On 2026-10-20 the data volume reached 0.1 GB free and nothing could start a shell. The guard holds
# starts from under 30 GB until 50 GB is free. Its clean pass is gone (each builder's run removes
# its own tree's install and caches), and a case below holds it gone.
#
# Free space is a fake reader that answers a planted figure.
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/tests/lib/suite.sh" || exit 1
for v in $(env | sed -n 's/^\(GIT_[A-Z_]*\)=.*/\1/p'); do unset "$v"; done
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUT="$HERE/disk-guard.sh"
[ -f "$SUT" ] || { echo "missing $SUT"; exit 2; }

SB=$(mktemp -d "${TMPDIR:-/tmp}/disk-guard-test-XXXXXX"); SB=$(cd "$SB" && pwd -P)
on_exit_keep_status 'rm -rf "$SB"'
fail=0
ok()  { echo "  ok   — $1"; }
bad() { echo "  FAIL — $1"; fail=1; }
want()        { [ "$2" = "$3" ] && ok "$1" || bad "$1 — wanted '$2', got '$3'"; }
want_in()     { printf '%s' "$3" | grep -qE -- "$2" && ok "$1" || { bad "$1 — no /$2/ in:"; printf '%s\n' "$3" | sed 's/^/        /' | head -40; }; }
want_not_in() { printf '%s' "$3" | grep -qE -- "$2" && { bad "$1 — /$2/ found in:"; printf '%s\n' "$3" | sed 's/^/        /' | head -40; } || ok "$1"; }
G() { git -c user.email=t@example.com -c user.name=tester -c commit.gpgsign=false -c init.defaultBranch=develop "$@"; }

BIN="$SB/bin"; STATE="$SB/state"
mkdir -p "$BIN" "$STATE/coordinator" "$STATE/runs"
cat > "$BIN/dgfree" <<'SH'
#!/usr/bin/env bash
cat "$DG_BASE"
SH
chmod +x "$BIN"/*
MAIN="$SB/main"; G init -q "$MAIN"
printf '{"repo":"example/thing","integrationBranch":"develop","branchPrefix":"tkt-","sisterRepos":[]}\n' > "$SB/cfg.json"

guard() { # <args…> — the SUT with every root in the fixture
  PATH="$BIN:$PATH" HOME="$SB" HARNESS_MAIN_REPO="$MAIN" HARNESS_REPO_ROOT="$MAIN" HARNESS_CFG_PATH="$SB/cfg.json" \
  HARNESS_STATE_DIR="$STATE" COORDINATOR_DF="$BIN/dgfree" DG_BASE="$SB/base" \
  DISK_GUARD_HOLD_FILE="$STATE/coordinator/disk-hold" \
  bash "${GUARD_SUT:-$SUT}" "$@" 2>&1
}
free_is() { printf '%s\n' "$1" > "$SB/base"; }

echo "--- the hold: under 30 GB it holds, and only 50 GB lets it go ---"
rm -f "$STATE/coordinator/disk-hold"
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

echo "--- the clean is gone: the guard only holds, it never removes anything ---"
free_is 5; out=$(guard clean --apply); rc=$?
want "clean is no longer a command" "2" "$rc"
want_not_in "and nothing says it cleaned" 'disk-clean:' "$out"

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

suite_end "$fail"
