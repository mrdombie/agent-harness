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
#   needsme-watch.sh open <pr>…             one review page for the batch, opened as one tab:
#                                           a numbered section per PR with every shot its
#                                           body pins at its newest pinned commit; prints
#                                           <n> \t <pr> \t <shown> \t <unloaded> \t <options> \t <title>
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

usage() { sed -n '4,20p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }

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
  swarm_gh pr view "$1" --repo "$REPO_SLUG" --json number,title,url,headRefOid,labels,body,commits 2>/dev/null
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

# A PR's shots are the images its own body links, pinned at the newest of the SHAs
# those links name (by place in the PR's commits). Never a commit's file list: a
# merge from the trunk carries every other ticket's evidence.
pinned_shots() { # <pr-json> — <sha> \t <path>, in body order
  local links newest
  links=$(evidence "$1" | grep -iE '\.(png|jpe?g)$' \
          | sed -nE 's#^https://github\.com/[^/]+/[^/]+/blob/([0-9a-f]{7,40})/(.*)$#\1	\2#p')
  [ -n "$links" ] || return 0
  newest=$(jq -r --arg l "$links" '
    [.commits[]?.oid] as $c
    | [$l | split("\n")[] | select(length > 0) | split("\t")[0]] | unique as $s
    | [$s[] as $x | {x: $x, i: ([$c | to_entries[] | select(.value | startswith($x)) | .key] | max // -1)}]
    | if any(.[]; .i >= 0) then (max_by(.i) | .x) else empty end' <<<"$1" 2>/dev/null)
  # No link names one of the PR's own commits: the last one the body names stands.
  [ -n "$newest" ] || newest=$(printf '%s\n' "$links" | tail -1 | cut -f1)
  printf '%s\n' "$links" | awk -F'\t' -v s="$newest" '$1 == s && !seen[$2]++'
}
html() { jq -Rr '@html' <<<"$1"; }
# Percent-decoded once, then each segment encoded: a link that already carries %20 is not encoded twice.
uri_path() { printf '%b' "$(printf '%s' "$1" | sed 's/%\([0-9A-Fa-f][0-9A-Fa-f]\)/\\x\1/g')" | jq -Rr 'split("/") | map(@uri) | join("/")'; }
shot_group() { # <path> — "<viewport> · <theme>", from the file name
  local n; n=$(basename "$1" | tr 'A-Z' 'a-z')
  case "$n" in *mobile*|*phone*|*-375*|*-390*|*-393*|*-414*|*-430*) printf 'phone' ;;
               *tablet*|*ipad*|*-768*|*-820*|*-1024*) printf 'tablet' ;; *) printf 'laptop' ;; esac
  case "$n" in *dark*) printf ' · dark' ;; *) printf ' · light' ;; esac
}
# What the owner may answer for one section. Nothing shown, or part not loaded, is not
# approvable; shots that would not load are not missing, so they are never sent back.
sign_options() { # <shown> <unloaded>
  if [ "$2" != 0 ]; then [ "$1" -gt 0 ] && printf 'Change,Skip' || printf 'Skip'
  elif [ "$1" -gt 0 ]; then printf 'Approve,Change'
  else printf 'Send back for shots,Skip'; fi
}
NEEDSME_PAGE_KEEP_DAYS="${NEEDSME_PAGE_KEEP_DAYS:-7}"

open_pr() { # <pr>…
  local base dir page i=0 pr j title url shots sha f k ext n bad g last links rows=""
  base="${NEEDSME_PAGE_DIR:-$COORD_DIR/review}"
  mkdir -p "$base" || { echo "needsme-watch: cannot write $base" >&2; return 1; }
  find "$base" -mindepth 1 -maxdepth 1 -type d -mtime +"$NEEDSME_PAGE_KEEP_DAYS" -exec rm -rf {} + 2>/dev/null
  dir="$base/$(date +%Y%m%dT%H%M%S)-$$"; mkdir -p "$dir" || return 1
  page="$dir/index.html"
  {
    printf '<!doctype html><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Sign-off</title>\n'
    printf '<style>body{font:15px/1.45 -apple-system,system-ui,sans-serif;margin:0 auto;max-width:1200px;padding:16px;background:#fafafa;color:#111}'
    printf 'section{border-top:1px solid #ddd;padding:16px 0}h2{margin:0 0 6px;font-size:20px}h3{margin:14px 0 4px;font-size:14px;color:#444}.n{display:inline-block;min-width:1.6em;margin-right:6px;color:#666}'
    printf '.flag{background:#fff3cd;border:1px solid #e0b000;padding:8px 10px;border-radius:6px}.shots{display:grid;grid-template-columns:repeat(auto-fill,minmax(320px,1fr));gap:12px}'
    printf 'figure{margin:0}img{width:100%%;border:1px solid #ccc;border-radius:4px;background:#fff}figcaption{font-size:12px;color:#555;word-break:break-all}</style>\n'
    printf '<h1>Sign-off: %s pull request(s)</h1>\n' "$#"
  } > "$page"
  for pr in "$@"; do
    i=$((i+1)); j=$(pr_json "$pr")
    if ! jq -e '.number' >/dev/null 2>&1 <<<"$j"; then
      printf '<section id="pr-%s"><h2><span class="n">%s</span>PR #%s</h2><p class="flag">Could not be read from GitHub.</p></section>\n' "$pr" "$i" "$pr" >> "$page"
      rows="$rows$i"$'\t'"$pr"$'\t'"0"$'\t'"-"$'\t'"$(sign_options 0 -)"$'\t'"(could not be read)"$'\n'; continue
    fi
    title=$(jq -r '.title // ""' <<<"$j"); url=$(jq -r '.url // ""' <<<"$j")
    shots=$(pinned_shots "$j"); sha=$(printf '%s\n' "$shots" | head -1 | cut -f1)
    {
      printf '<section id="pr-%s"><h2><span class="n">%s</span>%s</h2>\n' "$pr" "$i" "$(html "$title")"
      printf '<p><a href="%s">PR #%s</a>%s</p>\n' "$(html "$url")" "$pr" "${sha:+ · shots at ${sha:0:7}}"
      links=$(evidence "$j" | grep -viE '\.(png|jpe?g|webp|gif)$')
      [ -z "$links" ] || printf '%s\n' "$links" | while IFS= read -r u; do printf '<p><a href="%s">%s</a></p>\n' "$(html "$u")" "$(html "$u")"; done
    } >> "$page"
    k=0; n=0; bad=0; last=""
    # Grouped by viewport and theme; every shot shown, each loaded only as it scrolls in.
    while IFS=$'\t' read -r g sha f; do
      [ -n "$f" ] || continue
      k=$((k+1)); ext=$(printf '%s' "${f##*.}" | tr 'A-Z' 'a-z')
      if swarm_gh api "repos/$REPO_SLUG/contents/$(uri_path "$f")?ref=$sha" \
           -H 'Accept: application/vnd.github.raw' > "$dir/$i-$k.$ext" 2>/dev/null && [ -s "$dir/$i-$k.$ext" ]; then
        if [ "$g" != "$last" ]; then
          [ -z "$last" ] || printf '</div>\n' >> "$page"
          printf '<h3>%s</h3><div class="shots">\n' "$g" >> "$page"; last="$g"
        fi
        n=$((n+1))
        printf '<figure><a href="%s"><img src="%s" alt="%s" loading="lazy"></a><figcaption>%s</figcaption></figure>\n' \
          "$i-$k.$ext" "$i-$k.$ext" "$(html "$f")" "$(html "$f")" >> "$page"
      else rm -f "$dir/$i-$k.$ext"; bad=$((bad+1)); fi
    done < <(printf '%s\n' "$shots" | while IFS=$'\t' read -r s f; do [ -n "$f" ] && printf '%s\t%s\t%s\n' "$(shot_group "$f")" "$s" "$f"; done | sort -s -t$'\t' -k1,1)
    [ -z "$last" ] || printf '</div>\n' >> "$page"
    # A shot that would not load is not a missing shot: never "send it back" for a fetch that failed.
    [ "$bad" -eq 0 ] || printf '<p class="flag">Couldn'"'"'t load %s shot(s) — GitHub did not answer. Open the PR to see them.</p>\n' "$bad" >> "$page"
    [ "$k" -gt 0 ] || printf '<p class="flag">No screenshots linked in its description. Send it back for shots.</p>\n' >> "$page"
    printf '</section>\n' >> "$page"
    rows="$rows$i"$'\t'"$pr"$'\t'"$n"$'\t'"$bad"$'\t'"$(sign_options "$n" "$bad")"$'\t'"$title"$'\n'
  done
  page="file://$(uri_path "$page")"
  if [ -n "${NEEDSME_OPEN_CMD:-}" ]; then $NEEDSME_OPEN_CMD "$page"
  elif [ "$(uname)" = Darwin ]; then open -a "Google Chrome" "$page"
  else xdg-open "$page" >/dev/null 2>&1; fi
  echo "opened 1 page for $# PR(s): $page"
  printf '%s' "$rows"
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
  open)    [ $# -gt 0 ] || { echo "usage: needsme-watch.sh open <pr>…" >&2; exit 2; }; open_pr "$@" ;;
  *) usage ;;
esac
