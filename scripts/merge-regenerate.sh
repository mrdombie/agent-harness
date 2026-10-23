#!/usr/bin/env bash
# merge-regenerate.sh — a generated tally file that clashes in a merge is regenerated from
# the merged tree, with no model call and no repair spawn (owner call 2026-10-23,
# "Recount on merge"). In develop's 181 merges over two days the most-edited files were
# generated baselines and suppression counts, and each clash on one was a builder run.
#
#   . scripts/merge-regenerate.sh
#   merge_regenerate_conflicts <tree> [commit]
#       for each unmerged path harness.json's merge.regenerate names, run its command at the
#       tree's root and stage the result when it exits 0 and leaves no conflict marker;
#       prints "<path>\tregenerated" a line. With `commit`, a merge left with nothing
#       unmerged is committed (--no-edit). 1 when a named file could not be regenerated:
#       that file keeps git's own conflict, exactly as without this.
#
# harness.json: "merge": {"regenerate": [{"path": "<glob>", "command": "<shell>", "seed": "max"}]}.
# `seed: "max"` first writes the file as the key-wise maximum of both sides' JSON (numbers
# deep in objects; a key on one side only is kept), so a ratchet's own update command, which
# reads the baseline and refuses a rise over it, can run: it then writes the merged tree's
# real counts. With no command the seed alone is the resolution.
#
# WHY NOT A GIT MERGE DRIVER. git runs a custom driver inside the merge, before the merged
# tree is on disk (merge-ort merges in memory), so a recount run there would count this
# side's files only, and a driver that "succeeds" cannot fall back to a conflict after the
# merge commits. So the merge runs as it always does, and a clash on a named file is
# recounted on the merged tree right after it. GitHub's own merges are untouched: this runs
# where the harness merges locally (the repair step, the driver's merges, keep-fresh).

_mr_cfg() { printf '%s' "${HARNESS_CFG:-.claude/harness.json}"; }
# merge_regenerate_rule <path> — "<seed>\t<command>" of the first rule whose glob matches it, or 1.
merge_regenerate_rule() {
  local p="$1" g sd c
  while IFS=$'\t' read -r g sd c; do
    [ -n "$g" ] || continue
    # shellcheck disable=SC2254  # the glob is the setting's
    case "$p" in $g) printf '%s\t%s' "$sd" "$c"; return 0 ;; esac
  done <<<"$(jq -r '(.merge.regenerate // [])[]? | select((.path | type) == "string" and (((.command // "") | type) == "string") and ((.command // "") != "" or .seed == "max"))
                   | [.path, (.seed // "-"), (.command // "")] | @tsv' "$(_mr_cfg)" 2>/dev/null)"
  return 1
}
_MR_MAX_JQ='def m($a; $b): if ($a | type) == "object" and ($b | type) == "object" then reduce (($a + $b) | keys_unsorted[]) as $k ({}; .[$k] = m($a[$k]; $b[$k]))
  elif ($a | type) == "number" and ($b | type) == "number" then ([$a, $b] | max) elif $a == null then $b else $a end; m(.[0]; .[1])'
# _mr_seed_max <tree> <path> — the file as the key-wise max of stages 2 (ours) and 3 (theirs).
_mr_seed_max() {
  local o th
  o=$(git -C "$1" show ":2:$2" 2>/dev/null) && th=$(git -C "$1" show ":3:$2" 2>/dev/null) || return 1
  printf '%s\n%s\n' "$o" "$th" | jq -s "$_MR_MAX_JQ" > "$1/$2.mr" 2>/dev/null && mv -f "$1/$2.mr" "$1/$2" || { rm -f "$1/$2.mr"; return 1; }
}

merge_regenerate_conflicts() { # <tree> [commit]
  local wt="$1" commit="${2:-}" p r sd c rc=0 done=""
  git -C "$wt" rev-parse -q --verify MERGE_HEAD >/dev/null 2>&1 || return 0
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    r=$(merge_regenerate_rule "$p") || continue
    sd=${r%%$'\t'*}; c=${r#*$'\t'}
    if { [ "$sd" != max ] || _mr_seed_max "$wt" "$p"; } && { [ -z "$c" ] || (cd "$wt" && bash -c "$c") >/dev/null 2>&1; } && [ -f "$wt/$p" ] \
       && ! grep -qE '^(<<<<<<<|>>>>>>>)( |$)' "$wt/$p" && git -C "$wt" add -- "$p" 2>/dev/null; then
      printf '%s\tregenerated\n' "$p"; done=1
    else
      # git's own conflict stays: the stages are untouched, the markers put back.
      git -C "$wt" checkout -m -- "$p" >/dev/null 2>&1 || true
      printf '%s\tits regenerate command failed: %s\n' "$p" "${c:-the max seed}" >&2; rc=1
    fi
  done <<<"$(git -C "$wt" diff --name-only --diff-filter=U 2>/dev/null)"
  if [ -n "$done" ] && [ -n "$commit" ] && [ -z "$(git -C "$wt" diff --name-only --diff-filter=U 2>/dev/null)" ]; then
    git -C "$wt" commit -q --no-edit --no-verify >/dev/null 2>&1 || rc=1
  fi
  return "$rc"
}
