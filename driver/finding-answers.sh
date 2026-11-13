#!/usr/bin/env bash
# finding-answers.sh — every finding a review posts ends with one answer: fixed by a commit,
# or closed with a reason. One append-only ledger, steps/review.answers.jsonl, keyed as the
# posted ledger is (scripts/finding-key.jq finding_key), and never truncated: a later fix
# round adds to it, it does not replace it.
#
#   driver_finding_answer <ticket> <finding-json> fixed <sha> | closed <reason> [deferred]
#   driver_finding_answer_id <ticket> <review.json> <id> fixed <sha> | closed <reason>
#   driver_findings_answer_all <ticket> <findings json array> closed <reason>
#   driver_findings_unanswered <ticket>        a posted key with no answer row, one per line
#   driver_findings_unanswered_lines <ticket>  the same, as `file:line — summary`
#   driver_findings_answered_section <ticket> [--without-deferred]  the PR's "## Review findings, answered"
[ -n "${_DRIVER_FINDING_ANSWERS_SH:-}" ] && return 0
_DRIVER_FINDING_ANSWERS_SH=1

_driver_fa_keydef() { cat "$KIT_ROOT/scripts/finding-key.jq" 2>/dev/null; }
_driver_fa_dir() { printf '%s' "$(driver_state_dir "$1")/steps"; }

# [deferred]: the close is a deferral the PR lists under its own section.
driver_finding_answer() { # <ticket> <finding-json> <fixed|closed> <sha|reason> [deferred]
  local t="$1" f="$2" how="$3" what="${4:-}" df="${5:-}" keydef d
  case "$how" in fixed|closed) ;; *) return 1 ;; esac
  [ -n "$(printf '%s' "$what" | tr -d '[:space:]')" ] || return 1
  keydef=$(_driver_fa_keydef) || return 1
  d=$(_driver_fa_dir "$t"); mkdir -p "$d" || return 1
  jq -ec --arg a "$how" --arg w "$what" --arg df "$df" "$keydef"' {key: finding_key, id: (.id // null), answer: $a}
      + (if $a == "fixed" then {commit: $w} else {reason: $w} end)
      + (if $df == "deferred" then {deferred: true} else {} end)' <<<"$f" >> "$d/review.answers.jsonl" 2>/dev/null
}

# One finding of <review.json> by its id; nothing found, nothing written.
driver_finding_answer_id() { # <ticket> <review.json> <id> <fixed|closed> <sha|reason>
  local x
  x=$(jq -c --arg b "$3" '[.findings[]? | select((.id // "" | tostring) == $b)] | first // empty' "$2" 2>/dev/null)
  [ -n "$x" ] || return 0
  driver_finding_answer "$1" "$x" "$4" "$5"
}

driver_findings_answer_all() { # <ticket> <findings json array> <fixed|closed> <sha|reason>
  local x
  while IFS= read -r x; do
    [ -n "$x" ] && driver_finding_answer "$1" "$x" "$3" "$4"
  done < <(jq -c '.[]?' <<<"$2" 2>/dev/null)
  return 0
}

# _driver_fa_open <ticket> — the posted ledger's entries (one per key) with no answer row.
_driver_fa_open() {
  local d; d=$(_driver_fa_dir "$1")
  [ -s "$d/review.posted.jsonl" ] || return 0
  local a="$d/review.answers.jsonl"; [ -f "$a" ] || a=/dev/null
  jq -cs --slurpfile a "$a" '([$a[] | .key]) as $done | unique_by(.key)[] | select(.key as $k | $done | index($k) | not)' \
    "$d/review.posted.jsonl" 2>/dev/null
}

driver_findings_unanswered() { _driver_fa_open "$1" | jq -r '.key'; }

driver_findings_unanswered_lines() {
  _driver_fa_open "$1" | jq -r '"\(.file // "?"):\(.line // "?") — \(.summary // "")"'
}

# Each posted finding once, with its last answer. No posted ledger, no section.
# --without-deferred: a deferral is left out, the PR naming it under its deferred section;
# nothing left, no section.
driver_findings_answered_section() { # <ticket> [--without-deferred]
  local d a rows; d=$(_driver_fa_dir "$1")
  [ -s "$d/review.posted.jsonl" ] || return 0
  a="$d/review.answers.jsonl"; [ -f "$a" ] || a=/dev/null
  rows=$(jq -rs --slurpfile a "$a" --arg skip "${2:-}" '
      (reduce $a[] as $r ({}; .[$r.key] = $r)) as $last
      | unique_by(.key) | sort_by(.round // 0)[]
      | $last[.key] as $r
      | select($skip != "--without-deferred" or ($r.deferred // false) != true)
      | "- \(.file // "?"):\(.line // "?") — \(.summary // ""): "
        + (if $r == null then "unanswered"
           elif $r.answer == "fixed" then "fixed (\($r.commit[0:7]))"
           else "closed: \($r.reason)" end)' "$d/review.posted.jsonl" 2>/dev/null)
  [ -n "$rows" ] || return 0
  printf '## Review findings, answered\n%s\n' "$rows"
}
