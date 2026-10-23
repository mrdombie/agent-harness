#!/usr/bin/env bash
# clash-finding.sh — a finding that only says the branch clashes with, or is behind, its
# base is no finding. The clash is its PR's repair (the coordinator's finish pass queues
# one for a conflicting PR), never a fix-after-merge ticket and never a review block.
# Seen 2026-10-23: a ticket filed whose whole finding was "the branch conflicts with develop".
#
#   . scripts/clash-finding.sh
#   clash_finding_filter <in.jsonl> <out.jsonl>   copy every finding but the clash-only ones;
#                                                 prints the dropped ids, one line, comma-separated
#   CLASH_FINDING_JQ                              jq: `def clash_only:` on one finding object
#
# A clash-only finding names the branch's state, not its code: its summary says it conflicts
# with or is behind the base, needs a rebase or an update, or is CONFLICTING / DIRTY. One
# about conflict MARKERS left in a file is a real defect, and is kept.
[ -z "${_CLASH_FINDING_SH:-}" ] || return 0
_CLASH_FINDING_SH=1

CLASH_FINDING_JQ='def clash_only:
  ((.summary // "") | tostring) as $s
  | ($s | test("marker|<<<<<<<|>>>>>>>"; "i") | not)
    and ($s | test("merge conflict|conflict(s|ing)? with (origin/)?(develop|main|master|trunk|the (base|integration|target|trunk|default)( branch)?)|(is |are )?(out of date|behind|stale)( with| against| relative to)? (origin/)?(develop|main|master|trunk|the (base|integration|target|trunk))|needs? (to be )?(rebased|a rebase|updated with|an update from)|rebase (it )?(on|onto) |not up to date with|mergeable_?state|\\bCONFLICTING\\b|\\bDIRTY\\b|cannot be merged (cleanly|automatically)|has (merge )?conflicts"; "i"));'

clash_finding_filter() { # <in.jsonl> <out.jsonl>
  local in="$1" out="$2"
  jq -c "$CLASH_FINDING_JQ"' select(clash_only | not)' "$in" > "$out" 2>/dev/null || { cp "$in" "$out"; return 1; }
  jq -r "$CLASH_FINDING_JQ"' select(clash_only) | (.id // "?" | tostring)' "$in" 2>/dev/null | paste -sd, - | sed 's/,/, /g'
}
