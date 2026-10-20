#!/usr/bin/env bash
# critic-judge.sh — the design verdict comes from a critic the build never launched.
#
#   critic-judge.sh run <pr>             judge CI's pinned shots of the PR's head and post the
#                                        design status on that head, naming the shot set
#   critic-judge.sh due                  the PRs owed a judgement now: pr \t head, one a line
#   critic-judge.sh sweep [--dry-run]    start `run` for each PR that is due, detached, up to
#                                        coordinator.critic.maxLive at once (default 3) while the
#                                        machine has room; a run past its time is stopped
#   critic-judge.sh shotset <dir>        the id of the shots in <dir> (12 hex)
#   critic-judge.sh self-verdicts <pr>   the commits on the PR that carry a design verdict a
#                                        builder wrote (sha \t subject); exit 1 when there are any
#
# WHY. On one PR the design status read SHIP for a UI fingerprint because the repair run
# that built the change also ran the critic, on what it chose to show it, and committed
# the verdict as a trailer. An independent critic on CI's own pinned shots of that same
# fingerprint said SLOP with four Majors: two regions of the approved picture had never
# been photographed, narration an earlier critic had flagged was still on the screen,
# and five rows read "Sam Member". A verdict written by the run whose work it judges is
# the same thing as an agent clearing its own sign-off.
#
# SO, in this order, and nothing a builder can reach:
#   1. A build run cannot call this: HARNESS_DRIVER_RUN refuses, `run` needs the
#      coordinator's launch (CRITIC_JUDGE_LAUNCHER=coordinator) or a person's
#      CRITIC_JUDGE_MANUAL=1, and hooks/no-self-design-verdict.sh denies it to any session.
#   2. Only CI's pinned shots of the head count (scripts/ci-evidence.sh). Stale shots,
#      from before a merge that changed this PR's screens, are a failure, not a pass.
#   3. The approved picture — every one the PR adds or changes, and the plan's designRef
#      on the ticket — must pass scripts/picture-evidence.py lint, and every region it
#      declares must be among the shots. A gap fails before any model is paid for.
#      A picture drawn before the region convention is not failed for carrying no
#      markers: its regions are derived (its frames, else the PR's `## Evidence routes`
#      at laptop/phone x light/dark), and the status description says which. Real data,
#      and a laptop and a phone frame, are owed only by a picture approved on or after
#      coordinator.critic.realDataFrom (2026-10-20): the date is the picture's own
#      data-picture-approved, else the earliest of its first commit and the ticket's
#      "Picture approved" comment; with no date known it is exempt. The critic still
#      grades real data on the built screen.
#   3a. Every changed screen file must render on an evidence route or capture-plan shot,
#      and one that shows only once opened (a drawer, a dialog) needs a shot whose setup
#      opens it (scripts/evidence-gaps.sh). A gap fails, as an evidence-gap finding, before
#      any model is paid for — and a repair is handed it as a task for the capture plan.
#   4. The critic is handed every shot, the approved picture(s), the regions and the
#      open findings for the screen (scripts/screen-findings.sh). Its answer must quote
#      the shot set's id, name every shot it judged, and close with a FINDINGS block of
#      live findings only; an answer missing any of them is refused.
#   5. It judges only what the change changed. Each finding names its scope: a region
#      of the picture, or "changed" / "untouched". A region's scope is read off its
#      data-evidence-files against the diff (picture-evidence.py scope), never the
#      critic's say; a region naming no files counts as changed. An untouched finding
#      goes to the screen's polish list (polish-list.sh add) and does not block; one
#      that cannot be listed still blocks, so nothing is dropped. A line that says a
#      finding is resolved ("none", "gone", "0") is no finding.
#   5a. It passes only on no PARITY: DRIFT and no blocking finding (a Nit aside), with
#      VERDICT: SHIP or every live finding outside the change. The verdict is kept in a ledger only this judge writes, keyed on
#      the shot set: the same pixels at a new head (a develop merge that changed no
#      screen) get the same verdict again, with no model call — a signed-off screen is
#      not re-judged into new work. A red verdict on a signed-off PR goes to the PM.
#   6. The verdict goes on the PR as a comment carrying the head, the shot set and the
#      findings, and as the design status on the head, its description naming the set.
# A design-verdict trailer on the branch counts for nothing here and is named in the
# comment as ignored: the builder that wrote it is the one thing that cannot judge.
#
# CONFIG (review.judge in harness.json): context ("Design critic"), trailer
# ("Design-Critic"), agent ("agent-harness:design-critic"), mockGlob
# (".design/*-mock.html"), turns (40). Under coordinator.critic: maxLive (3; the
# older review.judge.maxLive is read when it is unset), timeoutMin (20), realDataFrom
# (2026-10-20).
#
# PLACES. One judge place is always open; each place above it is taken only while the
# coordinator's own room test (coord_room) says the machine fits another agent. A run
# that passes timeoutMin is stopped, its place given back and the try counted, so one
# PR cannot hold a place; and the PRs owed a judgement are started least recently
# started first, so a PR that keeps coming back cannot keep the others waiting.
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SELF_DIR/../swarm/swarm-env.sh" || exit 2

CONTEXT=$(swarm_opt review.judge.context "Design critic")
TRAILER=$(swarm_opt review.judge.trailer "Design-Critic")
AGENT=$(swarm_opt review.judge.agent "agent-harness:design-critic")
MOCKGLOB=$(swarm_opt review.judge.mockGlob ".design/*-mock.html")
MAXLIVE="${CRITIC_JUDGE_MAX_LIVE:-$(swarm_opt coordinator.critic.maxLive "")}"
[ -n "$MAXLIVE" ] || MAXLIVE=$(swarm_opt review.judge.maxLive 3)
TIMEOUT_MIN="${CRITIC_JUDGE_TIMEOUT_MIN:-$(swarm_opt coordinator.critic.timeoutMin 20)}"
REAL_DATA_FROM="${CRITIC_JUDGE_REAL_DATA_FROM:-$(swarm_opt coordinator.critic.realDataFrom 2026-10-20)}"
TURNS=$(swarm_opt review.judge.turns 40)
MARK="${CRITIC_JUDGE_MARK:-critic-judge}"
PREFIX="Independent critic"
CLAUDE_BIN="${CRITIC_JUDGE_CLAUDE:-claude}"
EV="${CRITIC_JUDGE_EVIDENCE:-$SELF_DIR/ci-evidence.sh}"
PE="$SELF_DIR/picture-evidence.py"
SF="${CRITIC_JUDGE_FINDINGS:-$SELF_DIR/screen-findings.sh}"
PL="${CRITIC_JUDGE_POLISH:-$SELF_DIR/polish-list.sh}"
AK="${CRITIC_JUDGE_APPROVAL:-$SELF_DIR/approval-kept.sh}"
COVERAGE="${CRITIC_JUDGE_COVERAGE:-$SELF_DIR/evidence-gaps.sh}"
FIRST_LOOK="$SELF_DIR/check-first-look.sh"
JDIR="${CRITIC_JUDGE_DIR:-$STATE_DIR/swarm/critic-judge}"
LEDGER="$JDIR/verdicts.tsv"     # pr \t head \t set \t verdict \t state \t url — written only here
TRIES=2
VLINE='^[[:space:]>#*_]*VERDICT:[[:space:]]*\*{0,2}(SHIP|SLOP)'
mkdir -p "$JDIR"
case "$MAXLIVE" in ''|*[!0-9]*|0) MAXLIVE=3 ;; esac
case "$TIMEOUT_MIN" in ''|*[!0-9]*|0) TIMEOUT_MIN=20 ;; esac
case "$REAL_DATA_FROM" in [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) : ;; *) REAL_DATA_FROM=2026-10-20 ;; esac
. "$SELF_DIR/branch-ticket.sh" 2>/dev/null || true
. "$SELF_DIR/evidence-plan.sh" 2>/dev/null || true

die() { echo "critic-judge: $*" >&2; exit 2; }
say() { echo "critic-judge: $*"; swarm_log "$JDIR/judge.log" "$*" 2>/dev/null || true; }
clip() { printf '%s' "$*" | tr '\n' ' ' | sed 's/[[:space:]][[:space:]]*/ /g; s/^ //; s/ $//' | cut -c1-139; }
note_try() { printf '%s\t%s\t%s\n' "$1" "$2" "$(swarm_now)" >> "$JDIR/tried.tsv"; }

shotset() { # <dir> — names and bytes, so a re-capture of other pixels is another set
  local d="$1" f
  for f in "$d"/*.png "$d"/*.jpg "$d"/*.jpeg "$d"/*.webp; do
    [ -f "$f" ] || continue
    printf '%s\t%s\n' "$(basename "$f")" "$( (shasum -a 256 "$f" 2>/dev/null || sha256sum "$f") | cut -d' ' -f1)"
  done | LC_ALL=C sort | (shasum -a 256 2>/dev/null || sha256sum) | cut -c1-12
}

post_status() { # <head> <success|failure|pending> <description> [<url>]
  local a=(api -X POST "repos/$REPO_SLUG/statuses/$1" -f "state=$2" -f "context=$CONTEXT" -f "description=$(clip "$3")")
  [ -n "${4:-}" ] && a+=(-f "target_url=$4")
  swarm_gh "${a[@]}" >/dev/null 2>&1 || { echo "critic-judge: could not post the $CONTEXT status on ${1:0:9}" >&2; return 1; }
}

# pictures_only — paths on stdin that match the picture glob (a function: a case inside $( ) breaks bash 3.2).
pictures_only() {
  local f
  while IFS= read -r f; do
    # shellcheck disable=SC2254
    case "$f" in $MOCKGLOB) printf '%s\n' "$f" ;; esac
  done
}

self_verdicts() { # <pr> — commits on the PR carrying the design trailer
  swarm_gh api "repos/$REPO_SLUG/pulls/$1/commits?per_page=100" --paginate 2>/dev/null \
    | jq -rs --arg k "$TRAILER" '[.[][] | select(.commit.message | test("(^|\\n)" + $k + ":"; "i"))
        | "\(.sha[0:12])\t\(.commit.message | split("\n")[0])"] | .[]'
}

# THE LEDGER IS THE ONLY RECORD OF A VERDICT. A PR comment or a status description can
# be written by anyone on the token; neither is read back as a verdict.
ledger_set() { awk -F'\t' -v p="$1" -v s="$2" '$1 == p && $3 == s' "$LEDGER" 2>/dev/null | tail -1; }   # <pr> <set>
ledger_head() { awk -F'\t' -v p="$1" -v h="$2" '$1 == p && $2 == h' "$LEDGER" 2>/dev/null | tail -1; } # <pr> <head>

tried() { # <pr> <head> — attempts at this head that gave no usable answer
  awk -F'\t' -v p="$1" -v h="$2" '$1 == p && $2 == h' "$JDIR/tried.tsv" 2>/dev/null | grep -c . | tr -d ' '
}

# A line that says there is nothing: "none", "(none)", "0", "gone", "resolved", or a
# finding closed by "— gone" / "(fixed)". Read as live, one blocked a clean screen.
RESOLVED='^[[:space:]]*[-*]?[[:space:]]*\(?(none|nothing|n/?a|0|zero|gone|resolved|fixed|no (issues?|findings?))\)?[[:space:]]*[.!]?[[:space:]]*$|(—|–|:|\(|-)[[:space:]]*(now[[:space:]]+)?(gone|resolved|fixed)[[:space:]]*\)?[[:space:]]*[.!]?[[:space:]]*$'

# findings_of <answer> — the live findings: the lines of the FINDINGS block, each
# "- <Grade> · [<scope> · ]<finding>", Nits and resolved lines aside. 2 when the block
# is missing or malformed.
findings_of() {
  local blk bad
  grep -qE '^[[:space:]]*FINDINGS[[:space:]]*$' "$1" && grep -qE '^[[:space:]]*END FINDINGS[[:space:]]*$' "$1" || return 2
  blk=$(awk '/^[[:space:]]*FINDINGS[[:space:]]*$/{f=1; next} /^[[:space:]]*END FINDINGS[[:space:]]*$/{f=0} f && NF' "$1" \
          | RE="$RESOLVED" awk '{ t = $0; sub(/^- (Critical|Major|Minor|Nit) · /, "", t); sub(/^[a-z0-9-]+ · /, "", t); if (tolower(t) !~ ENVIRON["RE"]) print }')
  bad=$(printf '%s\n' "$blk" | grep -v '^$' | grep -vE '^- (Critical|Major|Minor|Nit) · .+')
  [ -z "$bad" ] || return 2
  printf '%s\n' "$blk" | grep -E '^- (Critical|Major|Minor) · .+' | sed 's/^- //' | cut -c1-400
  return 0
}

# split_scope <scope.tsv> — live findings on stdin, out as "changed|untouched \t Grade · finding".
# A region's scope comes from the picture against the diff; "unknown" and no scope are changed.
split_scope() {
  awk -F'\t' -v S="$1" 'BEGIN { while ((getline l < S) > 0) { split(l, a, "\t"); sc[a[1]] = a[2] } }
    { g = $0; sub(/ · .*/, "", g); r = $0; sub(/^[A-Za-z]+ · /, "", r); w = "changed"
      t = r; sub(/ · .*/, "", t); rest = r; sub(/^[a-z0-9-]+ · /, "", rest)
      if (t ~ /^[a-z0-9-]+$/ && rest != r) {
        if (t == "changed" || t == "untouched") { w = t; r = rest }
        else if (t in sc) { w = (sc[t] == "untouched") ? "untouched" : "changed"; r = rest } }
      printf "%s\t%s · %s\n", w, g, r }'
}

# polish_slug <ticket> <changed-files> <shots.tsv> — the screen an untouched finding is
# listed under: the ticket's screens, else the route of the first shot.
polish_slug() {
  local s
  s=$( [ -n "$1" ] && bash "$SF" screens "$1" "$2" 2>/dev/null | head -1)
  [ -n "$s" ] || s=$(awk -F'\t' '$4 ~ /^\// { print $4; exit }' "$3" | tr -c 'a-z0-9\n' '-' | sed 's/--*/-/g; s/^-//; s/-$//')
  printf '%s' "$s"
}

# pictures_for <pr> <head> <ticket> <dir> — every approved picture that binds the PR, fetched
# into <dir>: the ones its diff adds or changes, and the designRef the plan step recorded
# on the ticket (a picture approved in an earlier PR binds this one too). Prints their paths.
pictures_for() {
  local pr="$1" head="$2" t="$3" d="$4" list ref="" f
  list=$(swarm_gh api "repos/$REPO_SLUG/pulls/$pr/files?per_page=100" --paginate 2>/dev/null \
           | jq -r '.[]? | select(.status != "removed") | .filename' | pictures_only) || return 1
  if [ -n "$t" ]; then
    ref=$(swarm_gh api "repos/$REPO_SLUG/issues/$t/comments?per_page=100" --paginate 2>/dev/null \
            | jq -rs '[.[][] | select(.body | startswith("**Plan**"))] | last | .body // ""' \
            | awk '/^```json/{f=1; next} /^```/{f=0} f' | jq -r '.designRef // empty' 2>/dev/null)
    case "$ref" in *.html) : ;; *) ref="" ;; esac
  fi
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    swarm_gh api "repos/$REPO_SLUG/contents/$f?ref=$head" -H "Accept: application/vnd.github.raw" > "$d/pic-$(printf '%s' "$f" | tr '/' '_')" 2>/dev/null || return 1
    printf '%s\n' "$f"
  done <<<"$list"
  # The plan's designRef, when the PR does not carry it: read when it is in the tree.
  if [ -n "$ref" ] && ! printf '%s\n' "$list" | grep -qxF -- "$ref"; then
    swarm_gh api "repos/$REPO_SLUG/contents/$ref?ref=$head" -H "Accept: application/vnd.github.raw" > "$d/pic-$(printf '%s' "$ref" | tr '/' '_')" 2>/dev/null \
      && printf '%s\n' "$ref" || rm -f "$d/pic-$(printf '%s' "$ref" | tr '/' '_')"
  fi
}

pic_file() { printf '%s/pic-%s' "$1" "$(printf '%s' "$2" | tr '/' '_')"; } # <dir> <repo path>

# picture_date <repo path> <head> <ticket comments json> — the earliest date the picture
# is known to have been approved: its first commit, or the ticket's "Picture approved"
# comment. Nothing when neither is known (the picture is then exempt from real data).
picture_date() {
  local c="" t=""
  c=$(swarm_gh api "repos/$REPO_SLUG/commits?path=$1&sha=$2&per_page=100" --paginate 2>/dev/null \
        | jq -rs '[.[] | if type == "array" then .[] else empty end | .commit.committer.date // .commit.author.date // empty] | min // empty' 2>/dev/null)
  [ -f "$3" ] && t=$(jq -rs '[.[] | if type == "array" then .[] else empty end | select((.body // "") | test("picture approved"; "i")) | .created_at // empty] | min // empty' "$3" 2>/dev/null)
  printf '%s\n%s\n' "${c:0:10}" "${t:0:10}" | grep -E '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' | LC_ALL=C sort | head -1
}

# derivation_of — reads picture-evidence.py derivation; prints how the regions were found.
derivation_of() {
  awk -F'\t' 'NF >= 3 { if ($2 == "marked") m = "marked"; else if ($2 == "frames") f += $3; else if ($2 == "routes") r += $3 }
    END { s = m; if (f) s = s (s ? ", " : "") "derived from frames (" f ")"; if (r) s = s (s ? ", " : "") "derived from the PR routes (" r ")";
          if (!s) s = "none found"; print "regions " s }'
}

record() { # <pr> <head> <set> <verdict> <state> <url> <description>
  post_status "$2" "$5" "$7" "$6" || return 1
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "$5" "$6" >> "$LEDGER"
}

run() { # <pr>
  local pr="$1" j head draft st evsha W n set prev url mocks req miss lint rc pass verdict parity blocks why body ignored t signed=0 judged
  local deriv="" routes="" f d pf outside="" listed="" slug=""
  local -a popt=()
  [ -z "${HARNESS_DRIVER_RUN:-}" ] || die "a build run ($HARNESS_DRIVER_RUN) cannot judge screens: the verdict comes from a critic the build did not start"
  [ "${CRITIC_JUDGE_LAUNCHER:-}" = coordinator ] || [ "${CRITIC_JUDGE_MANUAL:-}" = 1 ] \
    || die "the independent critic is started by the coordinator (or by a person with CRITIC_JUDGE_MANUAL=1), never by a build"
  j=$(swarm_gh pr view "$pr" --repo "$REPO_SLUG" --json headRefOid,isDraft,state,headRefName,body 2>/dev/null) || die "could not read PR #$pr"
  head=$(jq -r .headRefOid <<<"$j"); draft=$(jq -r .isDraft <<<"$j")
  t=$(branch_ticket "$(jq -r '.headRefName // ""' <<<"$j")" 2>/dev/null)
  [ "$(jq -r .state <<<"$j")" = OPEN ] || { say "PR #$pr is not open — nothing to judge"; return 3; }
  [ "$draft" != true ] || { say "PR #$pr is a draft — CI photographs a PR only once it is ready"; return 3; }

  st=$(REPO_SLUG="$REPO_SLUG" CI_EVIDENCE_REPO="$REPO_SLUG" bash "$EV" status "$pr" 2>/dev/null)
  evsha=$(sed -n 's/^sha=//p' <<<"$st")
  case "$(sed -n 's/^state=//p' <<<"$st")" in
    pinned) : ;;
    stale)
      # Pending, not red: nothing on the branch is wrong, CI owes a fresh capture.
      post_status "$head" pending "$PREFIX: waiting for CI to photograph again — the pinned shots predate a change to this PR's screens"
      say "PR #$pr: $(sed -n 's/^reason=//p' <<<"$st")"; return 3 ;;
    none)
      # Nothing to judge is an answer, not a wait — but only CI's own record for this very head says so.
      if [ -n "$head" ] && [ "$(sed -n 's/^nothing=//p' <<<"$st")" = "$head" ]; then
        record "$pr" "$head" - none success "" "No rendered change: CI found nothing to photograph at ${head:0:9}" || return 2
        printf '%s\t%s\n' "$pr" "$head" >> "$JDIR/none.tsv"
        say "PR #$pr: CI found nothing to photograph at ${head:0:9} — design status set to success"; return 0
      fi
      say "PR #$pr: no CI record that ${head:0:9} has nothing to photograph ($(sed -n 's/^reason=//p' <<<"$st"))"; return 3 ;;
    *) say "PR #$pr: no pinned shots of ${head:0:9} yet ($(sed -n 's/^reason=//p' <<<"$st"))"; return 3 ;;
  esac

  W=$(mktemp -d "$JDIR/pr-$pr.XXXXXX"); mkdir -p "$W/shots" "$W/pictures"
  CI_EVIDENCE_REPO="$REPO_SLUG" bash "$EV" fetch "$pr" "$W/shots" > "$W/shots.tsv" 2>"$W/fetch.err" \
    || { say "PR #$pr: CI's shots could not be fetched — $(head -1 "$W/fetch.err")"; note_try "$pr" "$head"; return 2; }
  n=$(grep -c . "$W/shots.tsv"); set=$(shotset "$W/shots")
  [ -n "$set" ] || { say "PR #$pr: the fetched shots hash to nothing"; note_try "$pr" "$head"; return 2; }

  # THE SAME PIXELS WERE JUDGED ALREADY — at this head, or at an earlier one a merge
  # carried them from: the ledger's verdict again, no model call.
  prev=$(ledger_set "$pr" "$set")
  if [ -n "$prev" ]; then
    IFS=$'\t' read -r _ _ _ verdict pass url <<<"$prev"
    record "$pr" "$head" "$set" "$verdict" "$pass" "$url" "$PREFIX: $verdict on shots $set ($n) at ${evsha:0:9}" || return 2
    say "PR #$pr: shots $set were judged $verdict already — said again at ${head:0:9}"; rm -rf "$W"; return 0
  fi

  # What the change changed: the critic is shown it, and a region is scoped by it.
  swarm_gh api "repos/$REPO_SLUG/pulls/$pr/files?per_page=100" --paginate 2>/dev/null | jq -s 'add // []' > "$W/pr-files.json" 2>/dev/null || echo '[]' > "$W/pr-files.json"
  jq -r '.[]? | .filename' "$W/pr-files.json" > "$W/changed.txt" 2>/dev/null || : > "$W/changed.txt"
  : > "$W/scope.tsv"
  mocks=$(pictures_for "$pr" "$head" "$t" "$W/pictures") || { say "PR #$pr: its approved picture could not be read"; note_try "$pr" "$head"; return 2; }
  ignored=$(self_verdicts "$pr")
  req="(no approved picture binds this PR)"; miss=""; lint=""
  if [ -n "$mocks" ]; then
    # A picture with no region markers predates them: its regions are derived, from its
    # frames or else the routes the PR names, never failed closed for the missing markers.
    routes=$(jq -r '.body // ""' <<<"$j" | bash "$SELF_DIR/ci-evidence.sh" routes 2>/dev/null) || routes=""
    popt=(--derive)
    while IFS= read -r f; do [ -n "$f" ] && popt+=(--route "$f"); done <<<"$routes"
    [ -z "$t" ] || swarm_gh api "repos/$REPO_SLUG/issues/$t/comments?per_page=100" --paginate > "$W/ticket-comments.json" 2>/dev/null || true
    # Each picture is linted on its own approval date: real data is owed from REAL_DATA_FROM.
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      pf=$(pic_file "$W/pictures" "$f"); d=$(picture_date "$f" "$head" "$W/ticket-comments.json")
      lint="$lint"$'\n'"$(python3 -I "$PE" lint "${popt[@]}" --real-data-from "$REAL_DATA_FROM" --approved "${d:-none}" "$pf" 2>&1 >/dev/null | grep -v '^picture-evidence: note:')"
    done <<<"$mocks"
    lint=$(printf '%s\n' "$lint" | grep -v '^$')
    deriv=$(python3 -I "$PE" derivation "${popt[@]}" "$W/pictures"/* 2>/dev/null | derivation_of)
    say "PR #$pr: the approved picture's $deriv"
    rc=0; req=$(python3 -I "$PE" required "${popt[@]}" "$W/pictures"/* 2>/dev/null) || rc=$?
    if [ "$rc" -eq 0 ]; then
      rc=0; miss=$(python3 -I "$PE" missing "${popt[@]}" --shots "$W/shots.tsv" "$W/pictures"/* 2>/dev/null) || rc=$?
      [ "$rc" -le 1 ] || { say "PR #$pr: the picture's regions could not be checked"; note_try "$pr" "$head"; return 2; }
      python3 -I "$PE" scope "${popt[@]}" --files "$W/changed.txt" "$W/pictures"/* > "$W/scope.tsv" 2>/dev/null || : > "$W/scope.tsv"
    elif [ "$rc" -ne 3 ]; then say "PR #$pr: the approved picture could not be read for regions"; note_try "$pr" "$head"; return 2; fi
  fi

  # A CHANGED SCREEN FILE NO SHOT RENDERS was never seen either: a drawer the PR changed
  # with no capture step that opens it, a component on a route nobody photographed
  # (scripts/evidence-gaps.sh). Recorded as evidence-gap findings, so a repair is handed
  # them as tasks for the capture plan. Unreadable is no gap: the critic still judges.
  local gaps=""
  jq -r '.body // ""' <<<"$j" > "$W/body.md"
  # The plan is read where CI reads it (scripts/evidence-plan.sh), not under the ticket.
  gaps=$(bash "$COVERAGE" judge "$pr" "$head" "$(evidence_plan_key "$(jq -r '.headRefName // ""' <<<"$j")" "$pr")" "$W/body.md" 2>/dev/null | awk -F'\t' 'NF >= 4 { print $4 }')
  [ -z "$gaps" ] || say "PR #$pr: $(printf '%s\n' "$gaps" | grep -c .) changed screen file(s) no evidence route or capture step renders"

  local answer="$W/answer.md"
  if [ -n "$miss" ] || [ -n "$lint" ] || [ -n "$gaps" ]; then
    # The picture binds nothing it cannot name, and a region or a changed screen with
    # no shot was never seen: judged without a model, because there is nothing to look at.
    verdict=SLOP; parity=""
    blocks=$( { printf '%s\n' "$lint" | sed -n 's/^picture-evidence: //p' | grep -v '^ok' \
                  | sed 's/^/Major · the approved picture: /'
                printf '%s\n' "$miss" | awk -F'\t' 'NF { printf "Major · evidence gap: the approved picture declares %s (%s, %s, %s) and CI pinned no shot of it — nobody saw it\n", $1, $2, $3, $4 }'
                printf '%s\n' "$gaps" | sed '/^$/d; s/^/Major · /'
              } | grep -v '^$')
    printf 'VERDICT: SLOP — the evidence does not cover the %s.\n\nSHOTS: %s at %s\n\nFINDINGS\n%s\nEND FINDINGS\n' \
      "$( [ -n "$miss$lint" ] && echo "approved picture" || echo "change")" \
      "$set" "$evsha" "$(printf '%s\n' "$blocks" | sed 's/^/- /')" > "$answer"
  else
    local open; open=$( { bash "$SF" critic "$pr" 2>/dev/null; [ -n "$t" ] && bash "$SF" polish "$t" 2>/dev/null; } \
                         | awk -F'\t' 'NF { printf "- %s · %s (from %s)\n", $1, $3, $2 }')
    {
      echo "You are the independent design critic for pull request #$pr in $REPO_SLUG. The run that built it did not start you, and nothing it wrote is your input."
      echo
      echo "Judge CI's pinned shots of commit $evsha (the PR's head is $head). Mode: $( [ -n "$mocks" ] && echo "PARITY against the approved picture(s), then the slop read" || echo "SLOP")."
      echo
      echo "Your answer's FIRST line is exactly: SHOTS: $set at $evsha"
      echo "Your SECOND line is: JUDGED: followed by the name of every shot below, space-separated."
      echo "Then your output in the shape your instructions give, leading with VERDICT (and PARITY when in parity mode)."
      echo "END your answer with this block, listing ONLY findings still visible on the shots — one a line, nothing resolved, no counts, no 'none':"
      echo "FINDINGS"
      echo "- <Critical|Major|Minor|Nit> · <scope> · <the element, the failure, the fix>"
      echo "END FINDINGS"
      echo "An empty block means nothing is wrong."
      echo "<scope> is the region the finding sits in, by its name below, when the picture declares one; else 'changed' when it is on a part of the screen this change draws or alters, or 'untouched' when it was there before this change and the change does not draw it. A check judges only what the change changed: an untouched finding goes to the screen's polish list and does not block. When unsure, say 'changed'."
      echo
      echo "## The shots (name, file, theme, route)"; cat "$W/shots.tsv"
      echo; echo "## The approved picture(s)"
      if [ -n "$mocks" ]; then ls "$W/pictures"/*; else echo "(none binds this PR)"; fi
      echo; echo "## The regions the picture declares (name, route, viewport, theme, shows, setup)"
      [ -z "$deriv" ] || echo "(The picture's $deriv. A derived region is a frame the picture draws, not a name CI used: hold the shot of its route, width and theme to it.)"
      printf '%s\n' "$req"
      if [ -s "$W/scope.tsv" ]; then
        echo; echo "## Each region's scope, read off the picture against the diff (name, scope, the changed file that draws it)"
        echo "Name the region in a finding inside it; its scope is taken from here, not from the finding. 'unknown' counts as changed."
        cat "$W/scope.tsv"
      fi
      echo; echo "## What this change changed (the files in its diff)"
      if [ -s "$W/changed.txt" ]; then cat "$W/changed.txt"; else echo "(the diff could not be read: call every finding 'changed')"; fi
      jq -r '.[]? | select(.patch) | "--- \(.filename)\n\(.patch)"' "$W/pr-files.json" 2>/dev/null | head -"${CRITIC_JUDGE_PATCH_LINES:-600}" > "$W/patch.txt"
      [ ! -s "$W/patch.txt" ] || { echo; echo "## The diff (its first ${CRITIC_JUDGE_PATCH_LINES:-600} lines)"; cat "$W/patch.txt"; }
      echo; echo "## Open findings already known on this screen — in scope for this change"
      echo "Check each against the shots. Still visible: list it in FINDINGS at its grade and scope. Gone: leave it out."
      printf '%s\n' "${open:-(none)}"
      echo; echo "## Real data"
      echo "Hold the shots to how people will meet the screen: repeated display names told apart, the longest names, the empty state, the page scrolled on laptop and phone. Rows a person cannot tell apart are a Major."
    } > "$W/prompt.md"
    rc=0
    ( cd "$W" && "$CLAUDE_BIN" -p --agent "$AGENT" --max-turns "$TURNS" \
        --permission-mode "${CRITIC_JUDGE_PERMISSION_MODE:-${COORDINATOR_PERMISSION_MODE:-auto}}" \
        --add-dir "$W" --output-format text < "$W/prompt.md" ) > "$answer" 2>"$W/claude.err" || rc=$?
    if [ "$rc" -ne 0 ] || [ ! -s "$answer" ]; then
      note_try "$pr" "$head"; say "PR #$pr: the critic did not answer (exit $rc) — $(head -1 "$W/claude.err" 2>/dev/null)"; return 2
    fi
    # AN ANSWER THAT DOES NOT NAME WHAT IT JUDGED IS NOT A VERDICT.
    if ! grep -qF "SHOTS: $set" "$answer"; then
      note_try "$pr" "$head"; say "PR #$pr: the critic's answer does not name shot set $set — refused, not recorded"; return 1
    fi
    judged=$(grep -m1 -E '^[[:space:]]*JUDGED:' "$answer" | sed -E 's/^[[:space:]]*JUDGED:[[:space:]]*//')
    local s missing_judged=""
    while IFS=$'\t' read -r s _; do
      [ -n "$s" ] || continue
      printf ' %s ' "$judged" | tr ',' ' ' | grep -qE "[[:space:]]$s(\.png)?[[:space:]]" || missing_judged="$missing_judged $s"
    done < "$W/shots.tsv"
    if [ -n "$missing_judged" ]; then
      note_try "$pr" "$head"; say "PR #$pr: the critic did not say it judged:$missing_judged — refused, not recorded"; return 1
    fi
    if ! bash "$FIRST_LOOK" "$answer" > "$W/first-look.out" 2>&1; then
      note_try "$pr" "$head"; say "PR #$pr: $(head -1 "$W/first-look.out") — refused, not recorded"; return 1
    fi
    # Read off the marker line only: "VERDICT:" quoted in prose is not the verdict.
    verdict=$(grep -iE "$VLINE" "$answer" | head -1 | grep -oiE 'VERDICT:[[:space:]]*\*{0,2}(SHIP|SLOP)' | grep -oiE 'SHIP|SLOP' | tr '[:lower:]' '[:upper:]')
    [ -n "$verdict" ] || { note_try "$pr" "$head"; say "PR #$pr: no VERDICT line — refused"; return 1; }
    parity=$(grep -iE '^[[:space:]>#*_]*PARITY:[[:space:]]*\*{0,2}(MATCH|DRIFT)' "$answer" | head -1 | grep -oiE 'PARITY:[[:space:]]*\*{0,2}(MATCH|DRIFT)' | grep -oiE 'MATCH|DRIFT' | tr '[:lower:]' '[:upper:]')
    rc=0; blocks=$(findings_of "$answer") || rc=$?
    [ "$rc" -eq 0 ] || { note_try "$pr" "$head"; say "PR #$pr: the answer's FINDINGS block is missing or not one finding a line — refused"; return 1; }
    # JUDGE ONLY WHAT THE CHANGE CHANGED: a finding outside it goes to the screen's polish
    # list, and blocks only when it cannot be listed there — never dropped.
    blocks=$(printf '%s\n' "$blocks" | grep -v '^$' | split_scope "$W/scope.tsv")
    outside=$(printf '%s\n' "$blocks" | awk -F'\t' '$1 == "untouched" { print $2 }')
    blocks=$(printf '%s\n' "$blocks" | awk -F'\t' '$1 == "changed" { print $2 }')
    if [ -n "$outside" ]; then
      slug=$(polish_slug "$t" "$W/changed.txt" "$W/shots.tsv")
      while IFS= read -r f; do
        [ -n "$f" ] || continue
        if [ -n "$slug" ] && bash "$PL" add "$slug" "$f (seen by the design critic on PR #$pr, outside what it changed)" >/dev/null 2>&1; then
          listed="$listed$f"$'\n'
        else
          blocks="$blocks${blocks:+$'\n'}$f"
        fi
      done <<<"$outside"
      listed=$(printf '%s' "$listed" | grep -v '^$')
      [ -n "$listed" ] && say "PR #$pr: $(printf '%s\n' "$listed" | grep -c .) finding(s) outside the change listed on the $slug polish list" \
        || say "PR #$pr: findings outside the change could not be listed${slug:+ on $slug} — they block"
    fi
  fi
  pass=failure
  # SLOP for findings that are all outside the change is not this change's failure.
  [ "$parity" != DRIFT ] && [ -z "$blocks" ] && { [ "$verdict" = SHIP ] || [ -n "$listed" ]; } && pass=success
  if [ "$pass" = success ]; then verdict=SHIP; elif [ "$verdict" = SHIP ]; then verdict=SLOP; fi
  why=$(grep -m1 -iE "$VLINE" "$answer" | sed -E 's/.*VERDICT:[[:space:]]*\**[A-Za-z]+\**[[:space:]]*[—-]*[[:space:]]*//')
  if [ "$pass" = failure ] && [ -n "$t" ]; then
    bash "$AK" signed-head "$pr" >/dev/null 2>&1 && signed=1
  fi

  body="$W/comment.md"
  {
    echo "<!-- $MARK head=$head shots=$set verdict=$verdict -->"
    echo "## Design critic — $verdict (independent)"
    echo
    echo "Judged CI's pinned shots of \`${evsha:0:12}\` — shot set \`$set\`, $n shot(s) — for head \`${head:0:12}\`, by a critic the build did not start.${parity:+ Parity against the approved picture: $parity.}${deriv:+ The approved picture: $deriv.}"
    [ "$pass" = success ] || [ -z "$why" ] || { echo; echo "$why"; }
    [ "$signed" = 0 ] || { echo; echo "**This PR's screens are signed off**, so these findings are the PM's call, not a repair's: a fix would change pixels after the sign-off."; }
    echo; echo "### Findings"
    if [ -n "$blocks" ]; then printf '%s\n' "$blocks" | sed 's/^/- /'; else echo "(none that block)"; fi
    if [ -n "$listed" ]; then
      echo; echo "### Outside this change — on the \`$slug\` polish list, not blocking"
      printf '%s\n' "$listed" | sed 's/^/- /'
    fi
    echo; echo "### Shots judged"
    awk -F'\t' '{ printf "- `%s` (%s, %s)\n", $1, $3, $4 }' "$W/shots.tsv"
    [ -z "$mocks" ] || { echo; echo "### Approved picture"; printf '%s\n' "$mocks" | sed 's/^/- `/; s/$/`/'; }
    if [ -n "$ignored" ]; then
      echo; echo "### Ignored: design verdicts written on the branch"
      echo "Only this judge sets the design status. These commits carry a \`$TRAILER:\` verdict the builder wrote; they count for nothing:"
      printf '%s\n' "$ignored" | awk -F'\t' '{ printf "- `%s` %s\n", $1, $2 }'
    fi
    echo; echo "<details><summary>The critic's whole answer</summary>"; echo; sed 's/^/    /' "$answer"; echo; echo "</details>"
  } > "$body"
  url=$(swarm_gh pr comment "$pr" --repo "$REPO_SLUG" --body-file "$body" 2>/dev/null | grep -oE 'https://[^ ]+' | tail -1)
  [ -n "$url" ] || { say "PR #$pr: the verdict comment could not be posted, so no status is set"; note_try "$pr" "$head"; return 2; }
  # The driver's steps read the open findings from here, never from a PR comment.
  if [ "$pass" = success ]; then rm -f "$JDIR/findings-$pr.txt"; else printf '%s\n' "$blocks" > "$JDIR/findings-$pr.txt"; fi
  if [ "$pass" = success ]; then record "$pr" "$head" "$set" SHIP success "$url" "$PREFIX: SHIP on shots $set ($n) at ${evsha:0:9}${deriv:+ · $deriv}" || return 2
  else record "$pr" "$head" "$set" "$verdict" failure "$url" "$PREFIX: $verdict on shots $set ($n) at ${evsha:0:9} — $(printf '%s\n' "$blocks" | grep -c .) blocking${deriv:+ · $deriv}" || return 2; fi
  # A red verdict on a signed-off screen is the PM's to call: the ticket is held for it,
  # which every repairer reads as "do not send an agent".
  [ "$signed" = 0 ] || swarm_gh issue edit "$t" --repo "$REPO_SLUG" --add-label "$LBL_PM_DECISION" >/dev/null 2>&1 || true
  say "PR #$pr: $verdict at ${head:0:9} on shots $set ($n)${ignored:+; $(printf '%s\n' "$ignored" | grep -c .) builder-written verdict(s) ignored}"
  rm -rf "$W"
  [ "$pass" = success ]
}

# due — open, ready PRs carrying the design status whose head this judge has not
# recorded, or whose status no longer says what the judge recorded (a CI run, or a
# trailer, wrote over it). Read off the shared copy of the open PRs. A head CI recorded
# nothing to photograph on is remembered (none.tsv) and not asked about again.
due() {
  local prs pr head state rec
  prs=$(gh_open_prs "${CRITIC_JUDGE_PRS_MAX_AGE:-300}" 2>/dev/null) || return 0
  printf '%s' "$prs" | jq -r --arg c "$CONTEXT" '
        .[] | select(.isDraft | not)
        | ([.statusCheckRollup[]? | select(.context == $c)] | last) as $s
        | select($s != null)
        | "\(.number)\t\(.headRefOid)\t\($s.state // "" | ascii_downcase)"' \
    | while IFS=$'\t' read -r pr head state; do
        grep -qxF "$pr	$head" "$JDIR/none.tsv" 2>/dev/null && continue
        rec=$(ledger_head "$pr" "$head" | cut -f5)
        [ -n "$rec" ] && [ "$rec" = "$state" ] && continue
        printf '%s\t%s\n' "$pr" "$head"
      done
}

# A place: <pr>.pid holds "pid head started-epoch". The run leads its own session
# (detach.sh), so stopping its group stops the critic it started too.
pid_of() { local p h e; read -r p h e < "$1" 2>/dev/null; printf '%s' "$p"; }
live() { local n=0 p; for p in "$JDIR"/*.pid; do [ -f "$p" ] || continue; if kill -0 "$(pid_of "$p")" 2>/dev/null; then n=$((n+1)); else rm -f "$p"; fi; done; echo "$n"; }

# reap — a run past TIMEOUT_MIN is stopped and its place given back; the try counts,
# so a PR that never finishes is left for a person after TRIES, not retried for ever.
reap() {
  local f p h e pr now; now=$(date +%s)
  for f in "$JDIR"/*.pid; do
    [ -f "$f" ] || continue
    p=""; h=""; e=""; read -r p h e < "$f" 2>/dev/null
    kill -0 "$p" 2>/dev/null || continue
    # A place written before it carried its start: its file's age.
    case "$e" in ''|*[!0-9]*) e=$(stat -f %m "$f" 2>/dev/null || stat -c %Y "$f" 2>/dev/null) ;; esac
    case "$e" in ''|*[!0-9]*) continue ;; esac
    [ $(( now - e )) -ge $(( TIMEOUT_MIN * 60 )) ] || continue
    pr=$(basename "$f" .pid)
    kill -TERM -- "-$p" 2>/dev/null || kill -TERM "$p" 2>/dev/null || true
    rm -f "$f"; note_try "$pr" "${h:--}"
    say "PR #$pr: the judge ran past ${TIMEOUT_MIN} min at ${h:0:9} — stopped, its place given back"
  done
}

# room — the places the machine fits beyond the first, by the coordinator's own test.
room() {
  if [ -n "${CRITIC_JUDGE_ROOM:-}" ]; then printf '%s' "$CRITIC_JUDGE_ROOM"; return; fi
  ( . "$SELF_DIR/coordinator-env.sh" >/dev/null 2>&1 || { printf 0; exit 0; }
    r=$(coord_room 2>/dev/null) && printf '%s\n' "$r" | cut -f1 || printf 0 )
}

# by_last_start — the due list, least recently started first (never started first).
by_last_start() {
  awk -F'\t' -v L="$JDIR/launched.tsv" 'BEGIN { while ((getline l < L) > 0) { split(l, a, "\t"); last[a[1]] = a[3] } }
    NF >= 2 { printf "%s\t%s\t%d\t%d\n", $1, $2, (($1 in last) ? last[$1] : 0), NR }' | sort -t"$(printf '\t')" -k3,3n -k4,4n | cut -f1,2
}

sweep() { # [--dry-run]
  local dry=0 pr head slots cap r live_now
  [ "${1:-}" = --dry-run ] && dry=1
  [ "$dry" = 1 ] || reap
  live_now=$(live)
  # The first place is always open; every place above it needs room on the machine.
  r=$(room); case "$r" in ''|*[!0-9]*) r=0 ;; esac
  cap=$(( 1 + r )); [ "$cap" -le "$MAXLIVE" ] || cap=$MAXLIVE
  slots=$(( cap - live_now ))
  while IFS=$'\t' read -r pr head; do
    [ -n "${pr:-}" ] || continue
    [ -f "$JDIR/$pr.pid" ] && kill -0 "$(pid_of "$JDIR/$pr.pid")" 2>/dev/null && continue
    [ "$(tried "$pr" "$head")" -lt "$TRIES" ] || { say "PR #$pr: $TRIES tries at ${head:0:9} gave no usable verdict — left for a person"; continue; }
    [ "$slots" -gt 0 ] || { say "PR #$pr owed a judgement; $live_now of $cap judge place(s) in use (most $MAXLIVE, machine room for $r more)"; continue; }
    if [ "$dry" = 1 ]; then say "would judge PR #$pr at ${head:0:9}"; slots=$((slots - 1)); continue; fi
    CRITIC_JUDGE_LAUNCHER=coordinator bash "$SELF_DIR/../swarm/detach.sh" bash "$SELF_DIR/critic-judge.sh" run "$pr" >> "$JDIR/judge.out" 2>&1 < /dev/null &
    printf '%s %s %s\n' "$!" "$head" "$(date +%s)" > "$JDIR/$pr.pid"; slots=$((slots - 1)); live_now=$((live_now + 1))
    printf '%s\t%s\t%s\n' "$pr" "$head" "$(date +%s)" >> "$JDIR/launched.tsv"
    say "judging PR #$pr at ${head:0:9}"
  done <<<"$(due | by_last_start)"
  [ -f "$JDIR/launched.tsv" ] && tail -500 "$JDIR/launched.tsv" > "$JDIR/launched.tsv.$$" 2>/dev/null && mv -f "$JDIR/launched.tsv.$$" "$JDIR/launched.tsv"
  return 0
}

case "${1:-}" in
  run)     [ -n "${2:-}" ] || die "usage: run <pr>"; run "$2" ;;
  due)     due ;;
  sweep)   sweep "${2:-}" ;;
  shotset) [ -d "${2:-}" ] || die "usage: shotset <dir>"; shotset "$2" ;;
  self-verdicts) [ -n "${2:-}" ] || die "usage: self-verdicts <pr>"; out=$(self_verdicts "$2"); [ -z "$out" ] || { printf '%s\n' "$out"; exit 1; } ;;
  *) die "usage: critic-judge.sh run|due|sweep|shotset|self-verdicts …" ;;
esac
