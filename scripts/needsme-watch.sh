#!/usr/bin/env bash
# needsme-watch.sh — the shell half of `/agent-harness:needsme --watch`. It finds
# what is new for the owner without a model call; the window only wakes to ask.
#
#   needsme-watch.sh pending [--no-forge]   the board: one row per item not yet asked
#                                           <key> \t <kind> \t <text>
#   needsme-watch.sh wait [--every S] [--forge-every S]
#                                           block until `pending` has a row, print the
#                                           rows, exit 0. Run it in the background.
#   needsme-watch.sh done <key>…            asked and answered: never offer it again,
#                                           and tick its line in needs-you.md
#   needsme-watch.sh answer <key> "<answer>" a decision:<ticket>:* row answered: the
#                                           label off, the answer on the ticket, the
#                                           ticket requeued with it, the line ticked;
#                                           a failed step is retried by the next sync
#   needsme-watch.sh card <pr>              what the sign-off prompt shows for one PR
#   needsme-watch.sh open <pr>              open that PR's evidence in the browser
#
# A PR that rebuilds ONE part of a screen others are also rebuilding carries a
# `<!-- part:begin -->`…`<!-- part:end -->` block in its body (finish writes it):
#   Screen: Home · Part: 3 of 8 · Region: Team card · Anchor: team
#   Picture: <approved picture URL> · Siblings: #101 #102 …  · region shots (blob links)
# The card then leads with `banner` (card N of M of the new <screen>; the rest of
# the page is the old version), lists each sibling live or pending (closed issue =
# live), and puts the region shots, the preview and the picture at the anchor
# ahead of the full page.
#
# Two sources: unticked needs-you.md lines, and full batches of held pixel PRs
# green apart from the hold (signoff-batch.sh), read from the forge every
# --forge-every seconds (default 300) so a batch reaches the owner even when no
# tick is running. The asked file ($COORD_DIR/asked.keys) is on disk, so nothing is
# asked twice across window restarts. A batch member already answered drops out of
# its batch; a batch with none left is not offered.
# One watcher per state dir: a second exits 3 and names the first.
# NEEDSME_OPEN_CMD replaces the browser opener (default: Google Chrome on macOS).
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SELF_DIR/coordinator-env.sh" || exit 1
SIGNOFF="$SELF_DIR/signoff-batch.sh"
ASKED="$COORD_DIR/asked.keys"
touch "$ASKED"

usage() { sed -n '4,17p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }

asked() { grep -qxF -- "$1" "$ASKED"; }

# A needs-you line's words: no box, no stamp, no key.
line_text() { printf '%s' "$1" | sed -e 's/^- \[.\] //' -e 's/^[^ ]* — //' -e 's/ *<!-- key:.* -->[[:space:]]*$//'; }

# Unticked needs-you lines: <key> \t <text>. A line from before keys rode on it is
# keyed by its text, so it too is asked once.
needs_you_rows() {
  [ -f "$COORD_NEEDS_YOU" ] || return 0
  grep '^- \[ \] ' "$COORD_NEEDS_YOU" | while IFS= read -r l; do
    key=$(printf '%s' "$l" | sed -n 's/.*<!-- key:\(.*\) -->[[:space:]]*$/\1/p')
    text=$(line_text "$l")
    [ -n "$key" ] || key="line:$(printf '%s' "$text" | cksum | cut -d' ' -f1)"
    printf '%s\t%s\n' "$key" "$text"
  done
}

# A batch key's members still unanswered: "pr@sha pr@sha …".
batch_left() { # <key>
  local m n sha out=""
  for m in $(printf '%s' "${1#signoff-batch:}" | tr ',' ' '); do
    n=${m%@*}; sha=${m#*@}
    asked "pr:$n:$sha" || out="$out${out:+ }$m"
  done
  printf '%s' "$out"
}

row() { # <key> <text>
  local key="$1" text="$2" kind="${1%%:*}" left
  asked "$key" && return 0
  if [ "$kind" = signoff-batch ]; then
    left=$(batch_left "$key")
    [ -n "$left" ] || return 0
    text="Sign off: PR #$(printf '%s' "$left" | sed -e 's/@[^ ]*//g' -e 's/ /, #/g')"
  fi
  printf '%s\t%s\t%s\n' "$key" "$kind" "$text"
}

pending() { # [--no-forge]
  local forge=1 rows key text prs exclude
  [ "${1:-}" = --no-forge ] && forge=0
  # Pending answers retried, and decisions answered on the ticket itself ticked, before the rows are read.
  [ "$forge" = 1 ] && { bash "$SELF_DIR/owner-question.sh" sync >/dev/null 2>&1 || true; }
  rows=$(needs_you_rows)
  while IFS=$'\t' read -r key text; do
    [ -n "${key:-}" ] && row "$key" "$text"
  done <<<"$rows"
  [ "$forge" = 1 ] || return 0
  # Members of a batch already on the list are not batched again under a new key.
  exclude=$(mktemp)
  cat "$ASKED" > "$exclude"
  printf '%s\n' "$rows" | cut -f1 | grep '^signoff-batch:' | sed 's/^signoff-batch://' | tr ',' '\n' \
    | awk -F@ 'NF==2 {print "pr:" $1 ":" $2}' >> "$exclude"
  # The shared copy the tick refreshes; GitHub is asked only when it is older than this.
  prs=$(gh_open_prs "${NEEDSME_PRS_MAX_AGE:-300}")
  if jq -e 'type == "array"' >/dev/null 2>&1 <<<"$prs"; then
    printf '%s' "$prs" | bash "$SIGNOFF" batches "$exclude" | while IFS=$'\t' read -r key _; do
      [ -n "${key:-}" ] && row "$key" ""
    done
  else
    echo "needsme-watch: the open pull requests could not be read" >&2
  fi
  rm -f "$exclude"
}

done_keys() {
  local key m
  for key in "$@"; do
    asked "$key" || printf '%s\n' "$key" >> "$ASKED"
    if [ "${key%%:*}" = signoff-batch ]; then
      for m in $(printf '%s' "${key#signoff-batch:}" | tr ',' ' '); do
        asked "pr:${m%@*}:${m#*@}" || printf 'pr:%s:%s\n' "${m%@*}" "${m#*@}" >> "$ASKED"
      done
    fi
    [ -f "$COORD_NEEDS_YOU" ] || continue
    # Tick the line carrying this key; a text-keyed line is matched by its text's sum.
    local tmp; tmp=$(mktemp "$COORD_DIR/.needs.XXXXXX")
    while IFS= read -r l; do
      case "$l" in
        "- [ ] "*"<!-- key:$key -->"*) printf '%s\n' "- [x] ${l#- \[ \] }" ;;
        "- [ ] "*)
          t=$(line_text "$l")
          if [ "$key" = "line:$(printf '%s' "$t" | cksum | cut -d' ' -f1)" ]; then printf '%s\n' "- [x] ${l#- \[ \] }"
          else printf '%s\n' "$l"; fi ;;
        *) printf '%s\n' "$l" ;;
      esac
    done < "$COORD_NEEDS_YOU" > "$tmp" && mv "$tmp" "$COORD_NEEDS_YOU"
  done
}

pr_json() { # <pr>
  swarm_gh pr view "$1" --repo "$REPO_SLUG" --json number,title,url,headRefOid,labels,body 2>/dev/null
}

body_of() { jq -r '.body // ""' <<<"$1" | tr -d '\r'; }
block() { # <body> <name> — the lines between <!-- name:begin --> and <!-- name:end -->
  printf '%s\n' "$1" | awk -v b="<!-- $2:begin -->" -v e="<!-- $2:end -->" 'index($0,b){f=1;next} index($0,e){f=0} f'
}
shots() { grep -oE 'https://github\.com/[^ )>"]+/blob/[0-9a-f]{7,40}/[^ )>"]+\.(png|jpg|jpeg|webp|gif)'; }
field() { # <part-block> <Name> — the value after "Name:" on its line
  printf '%s\n' "$1" | sed -n "s/^[-* ]*$2:[[:space:]]*//p" | head -1 | sed 's/[[:space:]]*$//'
}
anchored() { # <url> <anchor> — the url opened at the anchor, unless it has one
  case "$1" in *'#'*|'') printf '%s' "$1" ;; *) printf '%s%s' "$1" "${2:+#$2}" ;; esac
}

# Evidence, in the order the owner should see it. A part of a screen: the region's
# own shots, the preview and the approved picture at the region's anchor, then the
# full page. Otherwise: the live preview when it answers, then every SHA-pinned
# image the body links (before and after both).
evidence() { evidence_raw "$1" 2>/dev/null | awk 'NF && !seen[$0]++'; }
evidence_raw() { # <pr-json>
  local body preview part anchor picture
  body=$(body_of "$1")
  part=$(block "$body" part)
  anchor=$(field "$part" Anchor)
  [ -n "$part" ] && printf '%s\n' "$part" | shots
  preview=$(block "$body" preview | grep -oE 'https://[^ )>"]+' | head -1)
  if [ -n "$preview" ] && "${NEEDSME_CURL:-curl}" -sfL -m 8 -o /dev/null "$preview" 2>/dev/null; then
    anchored "$preview" "$anchor"; echo
  fi
  picture=$(field "$part" Picture | grep -oE 'https://[^ )>"]+' | head -1)
  [ -n "$picture" ] && { anchored "$picture" "$anchor"; echo; }
  printf '%s\n' "$body" | shots
}

# A part of a screen: the banner, the region, the picture and every sibling's state.
part_lines() { # <pr-json>
  local part screen region nm n m s st title
  part=$(block "$(body_of "$1")" part)
  [ -n "$part" ] || return 0
  screen=$(field "$part" Screen); region=$(field "$part" Region); nm=$(field "$part" Part)
  n=$(printf '%s' "$nm" | sed -n 's/^\([0-9][0-9]*\) *of *[0-9][0-9]*.*/\1/p')
  m=$(printf '%s' "$nm" | sed -n 's/^[0-9][0-9]* *of *\([0-9][0-9]*\).*/\1/p')
  if [ -z "$n" ] || [ -z "$m" ] || [ -z "$screen" ]; then
    echo "needsme-watch: the part block needs Screen and 'Part: N of M'" >&2; return 0
  fi
  printf 'part\t%s of %s\nscreen\t%s\n' "$n" "$m" "$screen"
  [ -n "$region" ] && printf 'region\t%s\n' "$region"
  printf 'banner\tcard %s of %s of the new %s; the rest of the page is the old version%s\n' \
    "$n" "$m" "$screen" "${region:+. Compare only the $region}"
  s=$(field "$part" Picture | grep -oE 'https://[^ )>"]+' | head -1)
  [ -n "$s" ] && printf 'picture\t%s\n' "$(anchored "$s" "$(field "$part" Anchor)")"
  for s in $(field "$part" Siblings | grep -oE '#[0-9]+' | tr -d '#'); do
    st=$(swarm_gh issue view "$s" --repo "$REPO_SLUG" --json state -q .state 2>/dev/null)
    title=$(swarm_gh issue view "$s" --repo "$REPO_SLUG" --json title -q .title 2>/dev/null)
    case "$st" in CLOSED) st=live ;; OPEN) st=pending ;; *) st=unknown ;; esac
    printf 'sibling\t#%s\t%s\t%s\n' "$s" "$st" "$title"
  done
}

card() { # <pr>
  local j held
  j=$(pr_json "$1")
  jq -e '.number' >/dev/null 2>&1 <<<"$j" || { echo "needsme-watch: PR #$1 could not be read" >&2; return 1; }
  held=$(jq -r --arg h "$HOLD_LABEL" 'if any(.labels[]?; .name == $h) then "yes" else "no" end' <<<"$j")
  printf 'pr\t%s\ntitle\t%s\nurl\t%s\nsha\t%s\nheld\t%s\n' \
    "$1" "$(jq -r .title <<<"$j")" "$(jq -r .url <<<"$j")" "$(jq -r '.headRefOid // "" | .[0:7]' <<<"$j")" "$held"
  part_lines "$j"
  evidence "$j" | sed 's/^/evidence\t/'
}

open_pr() { # <pr>
  local j urls u n=0
  j=$(pr_json "$1")
  jq -e '.number' >/dev/null 2>&1 <<<"$j" || { echo "needsme-watch: PR #$1 could not be read" >&2; return 1; }
  urls=$(evidence "$j")
  [ -n "$urls" ] || urls=$(jq -r .url <<<"$j")
  while IFS= read -r u; do
    [ -n "$u" ] || continue
    if [ -n "${NEEDSME_OPEN_CMD:-}" ]; then $NEEDSME_OPEN_CMD "$u"
    elif [ "$(uname)" = Darwin ]; then open -a "Google Chrome" "$u"
    else xdg-open "$u" >/dev/null 2>&1; fi
    n=$((n+1))
  done <<<"$urls"
  echo "opened $n link(s) for PR #$1"
}

wait_new() {
  local every=15 forge_every=300 last_forge=0 now out loops=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --every) every="${2:?}"; shift 2 ;;
      --forge-every) forge_every="${2:?}"; shift 2 ;;
      *) usage ;;
    esac
  done
  LOCK="$COORD_DIR/watch.lock"
  coord_lock "$LOCK" watcher || { echo "needsme-watch: $COORD_LOCK_WHY — this window is not watching"; exit 3; }
  trap 'rm -rf "$LOCK"' EXIT
  while :; do
    now=$(date +%s)
    if [ $((now - last_forge)) -ge "$forge_every" ]; then out=$(pending); last_forge=$now
    else out=$(pending --no-forge); fi
    if [ -n "$out" ]; then printf '%s\n' "$out"; exit 0; fi
    loops=$((loops+1))
    [ -n "${NEEDSME_WATCH_MAX_LOOPS:-}" ] && [ "$loops" -ge "$NEEDSME_WATCH_MAX_LOOPS" ] && exit 4
    sleep "$every"
  done
}

cmd="${1:-}"; [ $# -gt 0 ] && shift
case "$cmd" in
  pending) pending "$@" ;;
  wait)    wait_new "$@" ;;
  done)    [ $# -gt 0 ] || usage; done_keys "$@" ;;
  answer)  [ $# -eq 2 ] || usage
           case "$1" in decision:*:*) ;; *) echo "needsme-watch: answer takes a decision:<ticket>:<slug> key; use done for '$1'" >&2; exit 2 ;; esac
           bash "$SELF_DIR/owner-question.sh" answer "$1" "$2"; rc=$?
           # Not asked again either way; a step that failed stays pending and the line open until sync lands it.
           asked "$1" || printf '%s\n' "$1" >> "$ASKED"
           exit "$rc" ;;
  card)    card "${1:?usage: needsme-watch.sh card <pr>}" ;;
  open)    open_pr "${1:?usage: needsme-watch.sh open <pr>}" ;;
  *) usage ;;
esac
