#!/usr/bin/env bash
# ci-evidence.sh — the screenshots of a pixel PR come from CI, not from the agent.
#
#   ci-evidence.sh status <pr>                 state=… sha=… head=… shots=N reason=…
#   ci-evidence.sh wait <pr> [<max-seconds>]   wait in the shell until CI has pinned shots
#   ci-evidence.sh shots <pr>                  the pinned links, one per line
#   ci-evidence.sh fetch <pr> <dir>            download them; one line each: name<TAB>path<TAB>theme<TAB>route
#   ci-evidence.sh at-head <verdict-sha> [<head>]   a verdict taken there still covers the head
#   ci-evidence.sh routes [<body-file>]        the body names the routes CI photographs
#   ci-evidence.sh local                       exit 0 only when local capture is switched on
#   ci-evidence.sh moved <pr> <from-sha> <head> exit 0 when something between the two changes
#                                              what this PR's own screens render (names it)
#
# THE OWNER'S CALL (2026-10-16): agents stop taking screenshots locally; CI takes
# them. Measured that day: one agent spent ~58 minutes and 72 tool calls on local
# capture for one ticket, its cold local API answering in 83s, so the page under
# test treated a feature as off and redirected; another ticket needed 5+ local
# re-capture rounds; two more were stuck because the shared local workspace's own
# content rules blocked the capture. The project's CI already boots the stack,
# photographs the routes the PR body names and pins the PNGs to the PR.
#
# THE SHAPE CI LEAVES, every part of it overridable under `evidence` in harness.json:
#   - a commit on the branch, one parent, every file under docs/evidence/
#     (evidence.dir)
#   - a block in the PR body between <!-- ci-evidence:begin --> and
#     <!-- ci-evidence:end --> (evidence.begin / evidence.end) naming the commit
#     as <!-- ci-evidence-head:<sha> --> and linking each PNG at that sha
#   - a check run that captures (evidence.captureCheck) and one that decides
#     whether there is anything to capture (evidence.decideCheck)
#
# STATES (status, and what wait returns on):
#   pinned   shots are pinned and nothing after them changes what renders   exit 0
#   failed   the capture or the decide check failed: read its log, fix, push  exit 1
#   none     CI decided nothing on this head needs a picture                  exit 4
#   stale    CI kept shots from before a merge that changed this PR's own      exit 6
#            screens (or a file one of them imports): they show other pixels
#   pending  a capture is queued or running, or has not started yet          wait keeps waiting
#   off      the PR is a draft: CI photographs only a PR marked ready         exit 5
#
# LOCAL CAPTURE is a fallback for when CI evidence is down, and it is OFF unless
# HARNESS_LOCAL_EVIDENCE=1 is set in the environment by a person. Nothing in the
# kit sets it.
set -uo pipefail

CFG="${HARNESS_CFG:-}"
cfg() { # <key> <default>
  local v=""
  [ -n "$CFG" ] && [ -f "$CFG" ] && v=$(jq -r --arg k "$1" 'getpath($k | split(".")) // empty' "$CFG" 2>/dev/null)
  printf '%s' "${v:-$2}"
}
EV_DIR=$(cfg evidence.dir "docs/evidence")
EV_BEGIN=$(cfg evidence.begin "<!-- ci-evidence:begin -->")
EV_END=$(cfg evidence.end "<!-- ci-evidence:end -->")
EV_HEADMARK=$(cfg evidence.headMarker "ci-evidence-head:")
EV_CAPTURE=$(cfg evidence.captureCheck "Capture and pin the evidence")
EV_DECIDE=$(cfg evidence.decideCheck "Does this diff need pixels?")
EV_ROUTES=$(cfg evidence.routesHeading "Evidence routes")
EV_SUBJECT=$(cfg evidence.commitSubject "chore(evidence):")
REPO="${CI_EVIDENCE_REPO:-${REPO_SLUG:-}}"
EVERY="${CI_EVIDENCE_EVERY:-30}"

die() { echo "ci-evidence: $*" >&2; exit 2; }
ghr() { gh "$@" ${REPO:+--repo "$REPO"}; }

# The block CI wrote, and nothing outside it: a hand-pinned link elsewhere in the
# body is not CI's evidence.
block() { awk -v b="$EV_BEGIN" -v e="$EV_END" 'index($0,b){f=1} f{print} index($0,e){f=0}'; }
links() { grep -oE "https://github\.com/[^ )\"<>]+/blob/[0-9a-f]{40}/[^ )\"<>]+\.(png|jpg|jpeg|webp)"; }

# ONLY WHAT CI WROTE IS CI'S EVIDENCE. A PR's evidence block listed five PNGs under
# "Captured by evidence run"; CI had written one, and the other four were a builder's,
# from older heads, no longer matching what renders. A shot counts only when it is
# linked at the sha the block names, that commit is CI's own (its subject starts
# evidence.commitSubject) and that commit wrote the file. Unreadable is none.
ci_files() { # <evsha> → the files CI's evidence commit wrote, one a line; 1 when it is not CI's
  local j
  j=$(ghr_api "repos/{repo}/commits/$1" 2>/dev/null) || return 1
  printf '%s' "$j" | jq -e --arg p "$EV_SUBJECT" '(.commit.message // "") | startswith($p)' >/dev/null 2>&1 || return 1
  # And CI's capture really ran, and passed, on the commit it photographed (its parent).
  local par runs
  par=$(printf '%s' "$j" | jq -r '.parents[0].sha // empty'); [ -n "$par" ] || return 1
  runs=$(ghr_api "repos/{repo}/commits/$par/check-runs?per_page=100" 2>/dev/null) || return 1
  [ "$(check "$runs" "$EV_CAPTURE")" = completed/success ] || return 1
  printf '%s' "$j" | jq -r '.files[]? | select(.status != "removed") | .filename'
}
ci_links() { # <evsha> — links on stdin; CI's own pass, every other is named on stderr
  local ev="$1" ok u sha path
  ok=$(ci_files "$ev") || { cat >/dev/null; echo "ci-evidence: ${ev:0:9} is not CI's evidence commit — no shot linked at it counts" >&2; return 0; }
  while IFS= read -r u; do
    [ -n "$u" ] || continue
    sha=$(sed -E 's#.*/blob/([0-9a-f]{40})/.*#\1#' <<<"$u"); path=$(sed -E 's#.*/blob/[0-9a-f]{40}/##' <<<"$u")
    if [ "$sha" = "$ev" ] && printf '%s\n' "$ok" | grep -qxF -- "$path"; then printf '%s\n' "$u"
    else echo "ci-evidence: not a CI capture of ${ev:0:9}, refused: $path" >&2; fi
  done
}

# A commit after the shots that changes nothing they show: one parent, and no
# file outside the evidence dir — CI's own evidence commit, or an empty trailer.
# A merge is never a carry here: what it brings in is code nobody judged.
carry() { # <sha> — local git
  local c="$1" parents files
  parents=$(git rev-list --parents -n1 "$c" 2>/dev/null | wc -w | tr -d ' ')
  [ "$parents" = 2 ] || return 1
  files=$(git diff-tree --no-commit-id --name-only -r "$c" 2>/dev/null)
  ! printf '%s\n' "$files" | grep -v '^$' | grep -vF "$EV_DIR/" >/dev/null
}

# Same question asked of the forge, for status, which may run with no clone.
carry_remote() { # <base-sha> <head-sha> → 0 when every commit between is a carry
  local r
  r=$(ghr_api "repos/{repo}/compare/$1...$2" 2>/dev/null) || return 1
  printf '%s' "$r" | jq -e --arg d "$EV_DIR/" '
    .status == "ahead"
    and ([.commits[] | select((.parents | length) != 1)] | length == 0)
    and ([.files[]?.filename | select(startswith($d) | not)] | length == 0)' >/dev/null
}
ghr_api() { local p="$1"; shift; p="${p//\{repo\}/${REPO:-\{owner\}/\{repo\}}}"; gh api "$p" "$@"; }

# moved <pr> <from> <head> — 0 (and the files, one a line) when a change between the two
# touches what this PR's own screens render: one of its screen files, or a file one of
# them imports by a relative path. A develop merge that brings other screens leaves the
# shots standing; one whose conflict resolution edits this PR's screen does not. Anything
# unreadable counts as moved: a shot of other pixels must never stand as evidence.
screens_of() { # paths on stdin → the screen ones
  local in out; in=$(cat)
  if out=$(printf '%s\n' "$in" | bash "$(dirname "${BASH_SOURCE[0]}")/approval-kept.sh" screens 2>/dev/null); then
    printf '%s\n' "$out"
  else
    printf '%s\n' "$in" | grep -vE '(^|/)(__tests__|__mocks__)/|\.(test|spec)\.[a-z]+$|\.md$|^docs/' || true
  fi
}
moved() { # <pr> <from> <head>
  local pr="$1" from="$2" head="$3" changed own scr hit="" f dir spec base c
  changed=$(ghr_api "repos/{repo}/compare/$from...$head" 2>/dev/null | jq -r '.files[]?.filename') || { echo "(the change since ${from:0:9} could not be read)"; return 0; }
  # GitHub lists at most 300 files of a comparison: a list that long may be cut, and a
  # cut list cannot say a screen is untouched.
  [ "$(printf '%s\n' "$changed" | grep -c .)" -lt 300 ] || { echo "(more files changed since ${from:0:9} than GitHub lists)"; return 0; }
  own=$(ghr_api "repos/{repo}/pulls/$pr/files?per_page=100" --paginate 2>/dev/null | jq -r '.[]?.filename') || { echo "(this PR's files could not be read)"; return 0; }
  scr=$(printf '%s\n' "$own" | grep -v '^$' | grep -vF "$EV_DIR/" | screens_of | grep -v '^$')
  [ -n "$scr" ] && [ -n "$changed" ] || return 1
  hit=$(printf '%s\n' "$changed" | grep -xF -f <(printf '%s\n' "$scr") || true)
  if [ -z "$hit" ]; then
    # One step out: a file this PR's screens import by a relative path.
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      dir=$(dirname "$f")
      while IFS= read -r spec; do
        [ -n "$spec" ] || continue
        # An alias import (`@/…`, `~/…`): matched by the path after the alias, anywhere.
        case "$spec" in
          @/*|'~/'*) c=$(printf '%s\n' "$changed" | awk -v b="/${spec#*/}" '{ s=$0; sub(/\.[A-Za-z]+$/, "", s); if (substr(s, length(s) - length(b) + 1) == b || substr(s, length(s) - length(b "/index") + 1) == b "/index") print }')
                   [ -n "$c" ] && hit="$hit$c"$'\n'; continue ;;
        esac
        base=$(python3 -I -c 'import os,sys; print(os.path.normpath(os.path.join(sys.argv[1], sys.argv[2])))' "$dir" "$spec" 2>/dev/null) || continue
        c=$(printf '%s\n' "$changed" | awk -v b="$base" '{ s=$0; sub(/\.[A-Za-z]+$/, "", s); if (s == b || s == b "/index") print }')
        [ -n "$c" ] && hit="$hit$c"$'\n'
      done < <(ghr_api "repos/{repo}/contents/$f?ref=$head" -H "Accept: application/vnd.github.raw" 2>/dev/null \
                 | grep -oE "(from|import)[[:space:]]*\(?['\"](\.{1,2}|@|~)/[^'\"]+['\"]" | sed -E "s/^[^'\"]*['\"]//; s/['\"]$//")
    done < <(printf '%s\n' "$scr" | head -40)
  fi
  hit=$(printf '%s' "$hit" | grep -v '^$' | sort -u)
  [ -n "$hit" ] || return 1
  printf '%s\n' "$hit"; return 0
}

check() { # <check-runs json> <name> → status/conclusion of its latest run, or nothing
  jq -r --arg n "$2" '[.check_runs[]? | select(.name == $n)] | sort_by(.started_at) | last
    | if . == null then "" else "\(.status // "")/\(.conclusion // "")" end' <<<"$1" 2>/dev/null
}

status() { # <pr>
  local pr="$1" j head body draft blk evsha n runs cap dec
  j=$(ghr pr view "$pr" --json headRefOid,body,isDraft 2>/dev/null) || { echo "state=failed"; echo "reason=could not read PR #$pr"; return; }
  head=$(jq -r .headRefOid <<<"$j"); body=$(jq -r .body <<<"$j" | tr -d '\r'); draft=$(jq -r .isDraft <<<"$j")
  blk=$(printf '%s\n' "$body" | block)
  evsha=$(printf '%s\n' "$blk" | grep -oE "${EV_HEADMARK}[0-9a-f]{40}" | head -1 | sed "s/^${EV_HEADMARK}//")
  n=0; [ -n "$evsha" ] && n=$(printf '%s\n' "$blk" | links | ci_links "$evsha" 2>/dev/null | grep -c . || true)
  printf 'head=%s\nsha=%s\nshots=%s\n' "$head" "$evsha" "$n"

  if [ -n "$evsha" ] && [ "$n" -gt 0 ]; then
    if [ "$evsha" = "$head" ] || carry_remote "$evsha" "$head"; then
      echo "state=pinned"; echo "reason=CI pinned $n shot(s) at ${evsha:0:9}; nothing after it changes what renders"; return
    fi
  fi

  [ "$draft" = true ] && { echo "state=off"; echo "reason=the PR is a draft — CI photographs a PR only once it is marked ready"; return; }

  runs=$(ghr_api "repos/{repo}/commits/$head/check-runs?per_page=100" 2>/dev/null); runs=${runs:-'{}'}
  cap=$(check "$runs" "$EV_CAPTURE"); dec=$(check "$runs" "$EV_DECIDE")
  case "$dec" in
    */failure|*/timed_out|*/startup_failure|*/action_required)
      echo "state=failed"; echo "reason='$EV_DECIDE' failed on ${head:0:9} — usually the body has no '## $EV_ROUTES' list; read the check's log"; return ;;
  esac
  case "$cap" in
    */failure|*/timed_out|*/startup_failure|*/action_required|*/cancelled)
      echo "state=failed"; echo "reason='$EV_CAPTURE' ${cap#*/} on ${head:0:9} — read the check's log"; return ;;
    completed/skipped)
      local mv
      if [ -n "$evsha" ] && [ "$n" -gt 0 ] && mv=$(moved "$pr" "$evsha" "$head"); then
        echo "state=stale"; echo "reason=CI kept the shots it pinned at ${evsha:0:9}, and since then $(printf '%s' "$mv" | head -3 | tr '\n' ' ')changed what this PR's screens render — they need a fresh capture"
      elif [ -n "$evsha" ] && [ "$n" -gt 0 ]; then
        echo "state=pinned"; echo "reason=CI kept the shots it pinned at ${evsha:0:9}: nothing since changes this PR's screens"
      else
        echo "state=none"; echo "reason=CI decided nothing on ${head:0:9} needs a picture"
      fi
      return ;;
    completed/success)
      # It pinned and pushed a new head; the next read finds the block.
      echo "state=pending"; echo "reason=the capture finished; its evidence commit is landing"; return ;;
  esac
  case "$dec" in
    completed/skipped)
      echo "state=none"; echo "reason='$EV_DECIDE' was skipped on ${head:0:9} — CI only captures a ready PR the project arms for merge; check the PR is ready and armed"; return ;;
  esac
  echo "state=pending"; echo "reason=capture ${cap:-not started yet} on ${head:0:9}"
}

case "${1:-}" in
  status)
    [ -n "${2:-}" ] || die "usage: status <pr>"
    status "$2" ;;

  wait)
    # The shell waits, so the model does not: one call, no tokens while CI works.
    # The default stays under a ten-minute tool limit; call it again on exit 3.
    [ -n "${2:-}" ] || die "usage: wait <pr> [<max-seconds>]"
    max="${3:-${CI_EVIDENCE_MAX:-540}}"; start=$(date +%s)
    while :; do
      out=$(status "$2"); st=$(sed -n 's/^state=//p' <<<"$out")
      case "$st" in
        pinned) printf '%s\n' "$out"; exit 0 ;;
        failed) printf '%s\n' "$out"; exit 1 ;;
        none)   printf '%s\n' "$out"; exit 4 ;;
        off)    printf '%s\n' "$out"; exit 5 ;;
        stale)  printf '%s\n' "$out"; exit 6 ;;
      esac
      if [ $(( $(date +%s) - start )) -ge "$max" ]; then
        printf '%s\n' "$out"; echo "still waiting after ${max}s — run the same wait again; do not capture locally"; exit 3
      fi
      sleep "$EVERY"
    done ;;

  shots)
    [ -n "${2:-}" ] || die "usage: shots <pr>"
    blk=$(ghr pr view "$2" --json body -q .body | tr -d '\r' | block)
    evsha=$(printf '%s\n' "$blk" | grep -oE "${EV_HEADMARK}[0-9a-f]{40}" | head -1 | sed "s/^${EV_HEADMARK}//")
    [ -n "$evsha" ] || exit 0
    printf '%s\n' "$blk" | links | ci_links "$evsha" ;;

  fetch)
    [ -n "${2:-}" ] && [ -n "${3:-}" ] || die "usage: fetch <pr> <dir>"
    mkdir -p "$3"; got=0
    body=$(ghr pr view "$2" --json body -q .body | tr -d '\r')
    evsha=$(printf '%s\n' "$body" | block | grep -oE "${EV_HEADMARK}[0-9a-f]{40}" | head -1 | sed "s/^${EV_HEADMARK}//")
    urls=""; [ -n "$evsha" ] && urls=$(printf '%s\n' "$body" | block | links | ci_links "$evsha")
    # Route per shot: CI names each file by the route's slug, so slug the routes
    # the body lists the same way and match.
    routes=$(printf '%s\n' "$body" | bash "$0" routes 2>/dev/null || true)
    [ -n "$urls" ] || { echo "ci-evidence: PR #$2 carries no CI-pinned shots — wait for them, do not capture" >&2; exit 1; }
    while IFS= read -r u; do
      sha=$(sed -E 's#.*/blob/([0-9a-f]{40})/.*#\1#' <<<"$u")
      path=$(sed -E 's#.*/blob/[0-9a-f]{40}/##' <<<"$u")
      name=$(basename "$path" | sed -E 's/\.[a-z]+$//')
      dest="$3/$(basename "$path")"
      if ghr_api "repos/{repo}/contents/$path?ref=$sha" -H "Accept: application/vnd.github.raw" > "$dest" 2>/dev/null && [ -s "$dest" ]; then
        theme=light; case "$name" in *dark*) theme=dark ;; esac
        route=$(printf '%s\n' "$routes" | while IFS= read -r r; do
                  [ "$(printf '%s' "$r" | sed -E 's/[^a-zA-Z0-9]+/-/g; s/^-+|-+$//g')" = "$name" ] && { printf '%s' "$r"; break; }
                done)
        printf '%s\t%s\t%s\t%s\n' "$name" "$dest" "$theme" "${route:-(route not named in the body)}"
        got=$((got + 1))
      else
        echo "ci-evidence: could not fetch $u" >&2
      fi
    done <<<"$urls"
    [ "$got" -gt 0 ] || exit 1 ;;

  at-head)
    # A verdict is about the commit it was taken at. It still covers the head when
    # every commit after it is a carry: CI's evidence commit, or an empty trailer.
    v="${2:-}"; h="${3:-HEAD}"
    [ -n "$v" ] || die "usage: at-head <verdict-sha> [<head>]"
    vs=$(git rev-parse --verify --quiet "$v^{commit}") || { echo "at-head: $v does not resolve here — fetch the branch first"; exit 1; }
    hs=$(git rev-parse --verify --quiet "$h^{commit}") || { echo "at-head: $h does not resolve here — fetch the branch first"; exit 1; }
    [ "$vs" = "$hs" ] && { echo "at-head: verdict is at the head (${hs:0:9})"; exit 0; }
    git merge-base --is-ancestor "$vs" "$hs" || { echo "at-head: ${vs:0:9} is not below the head ${hs:0:9} — the verdict is about other code"; exit 1; }
    for c in $(git rev-list --first-parent "$vs..$hs"); do
      carry "$c" || { echo "at-head: ${c:0:9} ($(git log -1 --format=%s "$c" | cut -c1-60)) changes code after the verdict at ${vs:0:9}"; exit 1; }
    done
    echo "at-head: verdict at ${vs:0:9} covers ${hs:0:9} — everything after it is CI's evidence or an empty trailer"
    exit 0 ;;

  routes)
    # The contiguous list under the heading, each line a route starting '/' —
    # the same reading CI makes, so a body this passes is one CI can photograph.
    body=$( { [ -n "${2:-}" ] && cat "$2"; } || cat ); body=$(tr -d '\r' <<<"$body")
    sec=$(printf '%s\n' "$body" | awk -v h="$EV_ROUTES" '$0 ~ "^##[[:space:]]+" h "[[:space:]]*$" {f=1; next} f && /^#/ {f=0} f')
    list=$(printf '%s\n' "$sec" | awk 'NF==0{if(s)exit; next}{s=1; print}' | sed -e 's/^[-*][[:space:]]*//' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' | grep -v '^$' || true)
    [ -n "$list" ] || { echo "routes: the body has no '## $EV_ROUTES' list — CI cannot guess which screens to photograph"; exit 1; }
    bad=$(printf '%s\n' "$list" | grep -v '^/' || true)
    [ -z "$bad" ] || { echo "routes: every route starts with '/'; these do not: $(tr '\n' ' ' <<<"$bad")"; exit 1; }
    printf '%s\n' "$list" ;;

  local)
    [ "${HARNESS_LOCAL_EVIDENCE:-0}" = 1 ] ;;

  moved)
    [ -n "${2:-}" ] && [ -n "${3:-}" ] && [ -n "${4:-}" ] || die "usage: moved <pr> <from-sha> <head>"
    moved "$2" "$3" "$4" ;;

  *) die "usage: ci-evidence.sh status|wait|shots|fetch|at-head|routes|local|moved …" ;;
esac
