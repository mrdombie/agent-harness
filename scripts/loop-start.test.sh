#!/usr/bin/env bash
# loop-start.sh — after a loop starts, the keep-working Stop hook holds it open
# while its scope has ready tickets; before, it stands down. Then the plants: the
# marker not written, and the owner written before the label — each must go red.
# The ready count is planted through the hook's cache file: no network.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KIT="$(cd "$HERE/.." && pwd)"
SB=$(mktemp -d "${TMPDIR:-/tmp}/loop-start-XXXXXX")
export TMPDIR="$SB/tmp"; mkdir -p "$TMPDIR"
trap 'rm -rf "$SB"' EXIT
for v in $(env | sed -n 's/^\(GIT_[A-Z_]*\)=.*/\1/p'); do unset "$v"; done
unset HARNESS_CFG_PATH STATE_DIR
export HARNESS_STATE_DIR="$SB/state" HARNESS_REPO_SLUG="acme/widgets"
# This shell is the "Claude session": alive, and the same id for both sides.
export CLAUDE_SESSION_PID_OVERRIDE="$$"
fail=0
ok()  { echo "  ok   — $1"; }
bad() { echo "  FAIL — $1"; fail=1; }

kw() { # <kit> <session> → rc of keep-working.sh, with 5 ready planted for the session
  mkdir -p "$TMPDIR/claude-keep-working"; printf 5 > "$TMPDIR/claude-keep-working/$2.ready"
  jq -nc --arg s "$2" '{session_id:$s,stop_hook_active:false,last_assistant_message:"Merged it."}' \
    | (cd "$SB" && bash "$1/hooks/keep-working.sh") >/dev/null 2>&1
}
started_nags() { # <kit> — a fresh state dir, start a loop, does the hook hold it open?
  rm -rf "$HARNESS_STATE_DIR" "$TMPDIR/claude-keep-working"; mkdir -p "$HARNESS_STATE_DIR"
  # An earlier loop's owner left behind: another session, written long ago.
  echo 1 > "$HARNESS_STATE_DIR/.session-label.owner"; touch -t 202001010000 "$HARNESS_STATE_DIR/.session-label.owner"
  (cd "$SB" && bash "$1/scripts/loop-start.sh" area:widgets) >/dev/null 2>&1 || return 1
  kw "$1" "s$RANDOM$RANDOM"; [ $? -eq 2 ]
}

echo "loop-start"
rm -rf "$HARNESS_STATE_DIR"; mkdir -p "$HARNESS_STATE_DIR"
kw "$KIT" s-before; [ $? -eq 0 ] && ok "no loop started: the hook stands down" || bad "the hook nagged with no loop running"
started_nags "$KIT" && ok "a started loop with ready tickets is held open" || bad "a started loop was let go with 5 ready"
[ "$(cut -f1 "$HARNESS_STATE_DIR/.session-label")" = "area:widgets" ] && ok "the scope is recorded" || bad "the scope is not in .session-label"
[ "$(cat "$HARNESS_STATE_DIR/.session-label.owner")" = "$$" ] && ok "the owner is this session" || bad "the owner is not this session"
echo "declared stop" > "$HARNESS_STATE_DIR/.stop-reason"
kw "$KIT" s-stopped; [ $? -eq 0 ] && ok "a declared stop ends it" || bad "a declared stop was ignored"
(cd "$SB" && bash "$KIT/scripts/loop-start.sh") >/dev/null 2>&1 && bad "no scope was accepted" || ok "no scope is refused"

plant() { # <desc> <old> <new>
  local d="$SB/kit"; rm -rf "$d"; mkdir -p "$d"; cp -R "$KIT/scripts" "$KIT/hooks" "$d/"
  python3 - "$d/scripts/loop-start.sh" "$2" "$3" <<'PY' || { bad "plant did not land: $1"; return; }
import sys
p, a, b = sys.argv[1:]
s = open(p).read()
if s.count(a) != 1: sys.exit(1)
open(p, "w").write(s.replace(a, b))
PY
  grep -qF -- "$3" "$d/scripts/loop-start.sh" || { bad "plant did not land: $1"; return; }
  if started_nags "$d"; then bad "planted: $1 → still green (the guard is decorative)"; else ok "planted: $1 → red"; fi
}
echo "plants"
plant "the loop marker is never written" 'touch "$SD/.loop-active" || exit 1' ': || exit 1'
plant "the owner is never written, so an earlier loop's owner stands" \
  'printf '"'"'%s\n'"'"' "$(claude_session_pid 2>/dev/null || true)" > "$SD/.session-label.owner" || exit 1' ': || exit 1'
exit $fail
