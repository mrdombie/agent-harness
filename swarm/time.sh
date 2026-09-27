#!/usr/bin/env bash
# time.sh — the two clock conversions, written once because the two `date`
# implementations disagree about the flag that does them.
#
# `date -r N` means "the time N, as seconds" on BSD and "the mtime of the FILE
# named N" on GNU. A script that knows only the first one silently answers with
# the CURRENT time on Linux, through its own `|| date -u` fallback — so a test
# that pins the clock passes on macOS and fails on a Linux runner for a reason
# the failure never mentions. That is exactly how this landed: every stamp in
# the suite came out as "now", the live view's snapshot read 21 minutes stale,
# and the stall alarm never fired.
#
# Sourced by swarm-env.sh AND by the test fixture, so the world a test builds
# and the code under test cannot drift apart on this.

# swarm_iso <epoch> — an epoch as 2026-09-26T17:00:00Z, on either date.
swarm_iso() {
  date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
    || date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
    || date -u +%Y-%m-%dT%H:%M:%SZ
}

# swarm_epoch <2026-09-26T17:00:00Z> — the reverse, on either date.
#
# The fraction is stripped first, because that is the shape it is actually given:
# the live view stamps `new Date().toISOString()`, which always carries
# milliseconds, and BSD's -f matched the format literally and failed on them. The
# `|| echo 0` then made a healthy snapshot look 56 years old, so swarm_snapshot
# discarded every one of them, swarm_live_count answered 99, and the scheduler
# held on a machine with room — all of it reported as success, because holding is
# what a busy machine is supposed to do.
swarm_epoch() {
  local t="${1%Z}"; t="${t%%.*}Z"
  date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$t" +%s 2>/dev/null \
    || date -u -d "$t" +%s 2>/dev/null \
    || echo 0
}

# swarm_clock <epoch> — LOCAL hours and minutes, as "HH MM". Local, not UTC:
# the reset time a usage wall prints is in the operator's own zone.
swarm_clock() {
  date -r "$1" '+%H %M' 2>/dev/null \
    || date -d "@$1" '+%H %M' 2>/dev/null \
    || date '+%H %M'
}
