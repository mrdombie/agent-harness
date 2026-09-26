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
swarm_epoch() {
  date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$1" +%s 2>/dev/null \
    || date -u -d "$1" +%s 2>/dev/null \
    || echo 0
}

# swarm_clock <epoch> — LOCAL hours and minutes, as "HH MM". Local, not UTC:
# the reset time a usage wall prints is in the operator's own zone.
swarm_clock() {
  date -r "$1" '+%H %M' 2>/dev/null \
    || date -d "@$1" '+%H %M' 2>/dev/null \
    || date '+%H %M'
}
