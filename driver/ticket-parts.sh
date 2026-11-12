#!/usr/bin/env bash
# ticket-parts.sh — what a ticket body names as its own deliverables, read without a model,
# and whether a branch delivered them.
#
#   . driver/ticket-parts.sh
#   ticket_parts_paths <body-file>        each file path the body names as created or changed, one a line
#   ticket_parts_items <body-file>        each numbered change item (C<n>) and acceptance item (A<n>):
#                                         `<id><TAB><text>`, one a line
#   ticket_parts_check <tree> <body-file> <ticket> [features.json]
#                                         one line per part not delivered, `path|item<TAB><what><TAB><why>`;
#                                         exit 1 when any
#
# CONSERVATIVE BY DESIGN. A path counts only in backticks, under a change, build, files,
# description or acceptance heading, with a slash and an extension — or on the driver's own
# `**Files:**` line of a split part. A path named as context elsewhere never counts, and one
# its line marks read-only is skipped. An item is a top-level numbered line under a change
# heading, or a checkbox or numbered line under an acceptance heading; bullets never count.
[ -z "${_DRIVER_TICKET_PARTS:-}" ] || return 0
_DRIVER_TICKET_PARTS=1

# One awk pass, two outputs: `P<TAB>path` and `I<TAB>C|A<TAB>text`.
_ticket_parts_scan() { # <body-file>
  tr -d '\r' < "$1" | awk '
    function kind(t,   l) {
      l = tolower(t); gsub(/^[ \t]+|[ \t:]+$/, "", l)
      if (l ~ /acceptance|definition of done|^done when/) return "A"
      if (l ~ /^(the )?(change|changes|fix|fixes|build|work)( |$)/ || l ~ /^what (to build|changes)/ \
          || l ~ /^description$/) return "C"
      if (l == "files") return "F"
      return ""
    }
    function readonly(s,   l) {
      l = tolower(s)
      return l ~ /read[- ]only|do not (edit|change|touch)|don.t (edit|change|touch)|unchanged|untouched|for reference|as context/
    }
    function pathlike(p) {
      sub(/^\.\//, "", p); sub(/:[0-9]+(:[0-9]+)?$/, "", p)
      if (p ~ /[ *?<>{}$|]/ || p ~ /:\/\// || p !~ /\// || p !~ /\.[A-Za-z0-9]+$/) return ""
      return p
    }
    function backticked(s,   rest, i, j, tok, p) {
      rest = s
      while ((i = index(rest, "`")) > 0) {
        rest = substr(rest, i + 1); j = index(rest, "`"); if (j == 0) break
        tok = substr(rest, 1, j - 1); rest = substr(rest, j + 1)
        if ((p = pathlike(tok)) != "") print "P\t" p
      }
    }
    BEGIN { sec = ""; fence = 0 }
    /^[ \t]*```/ { fence = !fence; next }
    fence { next }
    /^[ \t]*<!--/ { next }
    /^#+[ \t]/ { h = $0; sub(/^#+[ \t]+/, "", h); sec = kind(h); next }
    /^\*\*[^*]+\*\*/ {
      lab = $0; sub(/^\*\*/, "", lab); sub(/\*\*.*$/, "", lab); sec = kind(lab)
      rest = $0; sub(/^\*\*[^*]+\*\*:?[ \t]*/, "", rest)
      if (sec == "F") {
        n = split(rest, parts, /,[ \t]*/)
        for (k = 1; k <= n; k++) { gsub(/`/, "", parts[k]); if ((p = pathlike(parts[k])) != "") print "P\t" p }
        sec = ""; next
      }
      if (sec != "" && rest != "" && !readonly(rest)) backticked(rest)
      next
    }
    sec == "" { next }
    {
      line = $0
      if (sec == "C" && line ~ /^ ?[0-9]+[.)][ \t]/) { t = line; sub(/^ ?[0-9]+[.)][ \t]+/, "", t); print "I\tC\t" t }
      else if (sec == "A" && line ~ /^ ?([-*]|[0-9]+[.)])[ \t]+\[[ xX]\][ \t]/) { t = line; sub(/^ ?([-*]|[0-9]+[.)])[ \t]+\[[ xX]\][ \t]+/, "", t); print "I\tA\t" t }
      else if (sec == "A" && line ~ /^ ?[0-9]+[.)][ \t]/) { t = line; sub(/^ ?[0-9]+[.)][ \t]+/, "", t); print "I\tA\t" t }
      if (!readonly(line)) backticked(line)
    }'
}

ticket_parts_paths() { # <body-file>
  _ticket_parts_scan "$1" | awk -F'\t' '$1 == "P" && !seen[$2]++ { print $2 }'
}

ticket_parts_items() { # <body-file>
  _ticket_parts_scan "$1" | awk -F'\t' '$1 == "I" { n[$2]++; print $2 n[$2] "\t" $3 }'
}

# _ticket_parts_on_branch <tree> <path> <touched-file> — on the branch, whole or as a suffix
# at a slash, or touched (a deletion included) by the branch's diff.
_ticket_parts_on_branch() {
  local wt="$1" p="$2" touched="$3"
  [ -e "$wt/$p" ] && return 0
  grep -qxF -- "$p" "$touched" 2>/dev/null && return 0
  git -C "$wt" ls-files 2>/dev/null | grep -qE "(^|/)$(printf '%s' "$p" | sed 's/[][\.*^$+?(){}|]/\\&/g')\$" && return 0
  grep -qE "(^|/)$(printf '%s' "$p" | sed 's/[][\.*^$+?(){}|]/\\&/g')\$" "$touched" 2>/dev/null
}

ticket_parts_check() { # <tree> <body-file> <ticket> [features.json]
  local wt="$1" body="$2" t="$3" list="${4:-}" touched base r p id text miss=0 cov parent own
  touched=$(mktemp "${TMPDIR:-/tmp}/ticket-parts.XXXXXX") || return 2
  for r in "origin/${INTEGRATION_BRANCH:-develop}" "${INTEGRATION_BRANCH:-develop}"; do
    base=$(git -C "$wt" merge-base "$r" HEAD 2>/dev/null) && [ -n "$base" ] && break
  done
  [ -z "${base:-}" ] || git -C "$wt" diff --name-only "$base" HEAD > "$touched" 2>/dev/null
  # A split part's files were listed under its parent's number; any path keyed by that number
  # (a folder, a changelog fragment, an evidence plan) is the part's own under its number.
  parent=$(sed -nE 's/.*<!-- harness:feature-item parent=([0-9]+) .*/\1/p' "$body" | tail -1)
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    _ticket_parts_on_branch "$wt" "$p" "$touched" && continue
    if [ -n "$parent" ] && [ -n "$t" ] && [ "$parent" != "$t" ]; then
      own=$(printf '%s' "$p" | awk -v a="$parent" -v b="$t" '{
        o = ""; s = $0
        while ((i = index(s, a)) > 0) {
          pre = substr(s, i - 1, 1); post = substr(s, i + length(a), 1)
          if ((i == 1 || pre !~ /[0-9]/) && post !~ /[0-9]/) { o = o substr(s, 1, i - 1) b }
          else { o = o substr(s, 1, i - 1 + length(a)) }
          s = substr(s, i + length(a))
        }
        print o s }')
      [ "$own" != "$p" ] && _ticket_parts_on_branch "$wt" "$own" "$touched" && continue
    fi
    printf 'path\t%s\tthe ticket names `%s`, and it is neither on the branch nor touched by its diff\n' "$p" "$p"
    miss=1
  done <<EOF
$(ticket_parts_paths "$body")
EOF
  rm -f "$touched"
  # A list written before items were mapped carries no `covers`: nothing to read it by.
  if [ -n "$list" ] && [ -s "$list" ] && jq -e '[.items[]? | has("covers")] | any' "$list" >/dev/null 2>&1; then
    while IFS='	' read -r id text; do
      [ -n "$id" ] || continue
      jq -e --arg i "$id" '[.outside[]? | .item // empty] | index($i) != null' "$list" >/dev/null 2>&1 && continue
      jq -e --arg i "$id" '[.items[] | select(.passes == true and ((.covers // []) | index($i) != null))] | length > 0' "$list" >/dev/null 2>&1 && continue
      cov=$(jq -r --arg i "$id" '[.items[] | select((.covers // []) | index($i) != null) | .id] | join(", ")' "$list" 2>/dev/null)
      if [ -n "$cov" ]; then
        printf 'item\t%s\t%s (“%s”) maps to %s, which does not pass\n' "$id" "$id" "$(printf '%s' "$text" | cut -c1-140)" "$cov"
      else
        printf 'item\t%s\t%s (“%s”) maps to no feature list item\n' "$id" "$id" "$(printf '%s' "$text" | cut -c1-140)"
      fi
      miss=1
    done <<EOF
$(ticket_parts_items "$body")
EOF
  fi
  return "$miss"
}
