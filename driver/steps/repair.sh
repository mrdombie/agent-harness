#!/usr/bin/env bash
# steps/repair.sh — a red or clashing pull request, fixed on its own branch.
#
#   driver_step_repair <ticket>
#
# It runs after `reenter`, in the PR's own tree at origin's head. Three things can be
# wrong, and the driver does what needs no thinking itself:
#
#   A CLASH  the integration branch is merged in. A clean merge is a commit and the
#            step is done with it, with no model call. A conflicted merge is left in
#            progress, with the files named, for the one model call this step makes.
#            The merge is the driver's: after the answer it merges the trunk again
#            as it stands (a peer's fetch moves it), keeps the model's resolution of
#            a file the trunk has not changed since, and hands any other marked
#            file back once. The head that leaves this step has the trunk in it.
#   A RED    the PR's checks that settled red, read from its status rollup and handed
#            over with the brief that sent the repair. A rollup nobody could read is
#            said to be unreadable. It is not read as green.
#   NOTHING  nothing red and nothing clashing, so there is no model call. The steps
#            after this one still run every gate and the review, so an approved
#            merge sent here is judged like any other.
#
# THE ANSWER IS NOT THE EVIDENCE. What comes back is checked against the tree:
#   - no unmerged path and no merge in progress, and for a clash the trunk is an
#     ancestor of the head
#   - no conflict marker in any file that conflicted
#   - nothing uncommitted, and the head has moved past where the repair started
#   - each fix carries its proof. A TEST is re-run at its fix's parent and at the
#     fix, by the same proof build and fix use, when the fix is this repair's own; a
#     pair the branch carried from before it started is noted, not re-proved, and any
#     other commit is refused. A GATE (a fix no test can pin, such as a lint rule, a type error
#     or a lockfile) has its command run at the head, read by its exit code. The
#     self-check step after this one runs every gate regardless.
[ -n "${DRIVER_DIR:-}" ] || . "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/driver-env.sh" || exit 1
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/ai-step.sh" || exit 1
# driver_prove_red_green lives with the build step: one proof, read by every step.
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/build.sh" || exit 1
# driver_claim_held_elsewhere lives with reenter: one claim rule for the way in and the model call.
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/reenter.sh" || exit 1
# A red the base branch has too: read, classified, and waited out (base-wait.sh).
. "$KIT_ROOT/scripts/base-wait.sh" || exit 1
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/base-red.sh" || exit 1

# _driver_repair_claim_busy <ticket> <when> — 0 (and the step returns DRIVER_E_BUSY) when
# another live run holds the claim: the repair waits on the queue, it never asks about it.
_driver_repair_claim_busy() {
  local held
  held=$(driver_claim_held_elsewhere "$1") || return 1
  driver_say "✋ repair: $held, $2. Never adopt a live claim; back on the queue to wait it out."
  driver_state_set "$1" park_note "$held"
  driver_state_set "$1" claim_elsewhere 1
  return 0
}

# _driver_repair_clashes <tree> <trunk> <mergeStateStatus> <mergeable> — 0 when the
# branch clashes with the trunk: GitHub says DIRTY or CONFLICTING, or a trial merge
# conflicts. GitHub computes mergeability lazily, so UNKNOWN is not clean. The trial
# runs in a throwaway detached tree, so nothing in the ticket's own tree (an
# untracked file included) can stop it or be touched by it.
_driver_repair_clashes() {
  local wt="$1" trunk="$2" u tmp
  [ "$3" = DIRTY ] && return 0
  [ "$4" = CONFLICTING ] && return 0
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/repair-trial.XXXXXX") || return 1
  rmdir "$tmp"
  git -C "$wt" worktree add -q --detach "$tmp" HEAD >/dev/null 2>&1 || return 1
  git -C "$tmp" -c user.email=trial@invalid -c user.name=trial merge --no-commit --no-ff -q "$trunk" >/dev/null 2>&1
  u=$(git -C "$tmp" diff --name-only --diff-filter=U 2>/dev/null)
  git -C "$wt" worktree remove --force "$tmp" >/dev/null 2>&1 || rm -rf "$tmp"
  git -C "$wt" worktree prune >/dev/null 2>&1
  [ -n "$u" ]
}

# _driver_repair_deleted_on_base <tree> <path> — 0 when the merge in progress deletes
# <path> on the trunk side: it is at a merge base and not at MERGE_HEAD.
_driver_repair_deleted_on_base() {
  local wt="$1" p="$2" mb
  git -C "$wt" rev-parse -q --verify MERGE_HEAD >/dev/null 2>&1 || return 1
  git -C "$wt" cat-file -e "MERGE_HEAD:$p" 2>/dev/null && return 1
  for mb in $(git -C "$wt" merge-base --all HEAD MERGE_HEAD 2>/dev/null); do
    git -C "$wt" cat-file -e "$mb:$p" 2>/dev/null && return 0
  done
  return 1
}

# _driver_repair_branch_kept <tree> <path> — 0 when the branch never changed <path>:
# HEAD's blob is every merge base's.
_driver_repair_branch_kept() {
  local wt="$1" p="$2" h mb n=0
  h=$(git -C "$wt" rev-parse -q --verify "HEAD:$p" 2>/dev/null) || return 1
  for mb in $(git -C "$wt" merge-base --all HEAD MERGE_HEAD 2>/dev/null); do
    [ "$(git -C "$wt" rev-parse -q --verify "$mb:$p" 2>/dev/null)" = "$h" ] || return 1; n=$((n+1))
  done
  [ "$n" -gt 0 ]
}

# _driver_repair_take_listed <ticket> <tree> <answer> — runs the `git rm` of each path the
# answer's takeBaseDeletions lists, then the merge commit once nothing is unmerged. The
# model's permission mode refuses git rm, so the driver does it. All or none: a path the
# trunk did not delete in this merge is refused (1) and nothing is removed.
_driver_repair_take_listed() {
  local t="$1" wt="$2" ans="$3" p bad="" list
  list=$(jq -r '(.takeBaseDeletions // [])[]' "$ans" 2>/dev/null)
  [ -n "$list" ] || return 0
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    _driver_repair_deleted_on_base "$wt" "$p" || bad="$bad$p "
  done <<<"$list"
  if [ -n "$bad" ]; then
    driver_say "✋ repair: takeBaseDeletions names ${bad}— not deleted on the trunk side of this merge, so the driver removes nothing."
    driver_state_set "$t" park_note "the repair asked the driver to take a deletion the trunk never made: $bad"
    return 1
  fi
  while IFS= read -r p; do
    [ -n "$p" ] && git -C "$wt" rm -q -f --ignore-unmatch -- "$p" >/dev/null 2>&1
  done <<<"$list"
  driver_say "   repair: took the trunk's deletion of $(printf '%s' "$list" | tr '\n' ' ')as the answer listed"
  if [ -z "$(git -C "$wt" diff --name-only --diff-filter=U 2>/dev/null)" ]; then
    git -C "$wt" commit -q --no-edit >/dev/null 2>&1 || true
  fi
  return 0
}

# _driver_repair_put_back <ticket> <tree> <answer.json> <dirty-before> — put back every
# tracked file changed in the tree since <dirty-before> (the model's turn began) that the
# answer does not name: a tool's rewrite, not the repair (Next rewrites AGENTS.md
# while checks run). Each change is kept as a patch first; a named file is left for the check.
_driver_repair_put_back() {
  local t="$1" wt="$2" ans="$3" before="$4" named p back="" patch
  named=$(driver_answer_paths "$ans")
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    printf '%s\n' "$before" | grep -qxF -- "$p" && continue
    printf '%s\n' "$named" | grep -qxF -- "$p" && continue
    back="$back$p"$'\n'
  done <<<"$(git -C "$wt" diff --name-only --diff-filter=MDT 2>/dev/null)"
  [ -n "$back" ] || return 0
  patch="$(driver_state_dir "$t")/steps/put-back-$(date -u +%Y%m%dT%H%M%SZ).patch"
  local -a paths=(); while IFS= read -r p; do [ -n "$p" ] && paths+=(":(literal)$p"); done <<<"$back"
  git -C "$wt" diff -- "${paths[@]}" > "$patch" 2>/dev/null || { driver_say "   repair: could not keep a patch of $(printf '%s' "$back" | tr '\n' ' ')— nothing put back"; return 0; }
  git -C "$wt" checkout -- "${paths[@]}" >/dev/null 2>&1 || return 0
  driver_say "   repair: put back $(printf '%s' "$back" | tr '\n' ' ')— changed in the tree during the repair and named by no part of its answer, so a tool's edit, not the repair's; the change is kept at $patch"
}

# _driver_repair_evidence_left <ticket> <tree> <trunk> <base> <plan> <pr> — what the
# repair left of the evidence it owed: the plan untouched since <base>, or the changed
# screen files still no route or capture step renders. Nothing when it is all answered.
_driver_repair_evidence_left() {
  local t="$1" wt="$2" trunk="$3" base="$4" plan="$5" pr="$6" mb body gaps
  if git -C "$wt" diff --quiet "$base" HEAD -- "$plan" 2>/dev/null; then
    printf 'the capture plan %s is unchanged' "$plan"; return 0
  fi
  if ! python3 -I "$KIT_ROOT/scripts/evidence-gaps.py" check-plan "$wt/$plan" >/dev/null 2>&1; then
    printf 'the capture plan %s is not one CI can read (python3 -I %s check-plan %s)' "$plan" "$KIT_ROOT/scripts/evidence-gaps.py" "$plan"; return 0
  fi
  mb=$(git -C "$wt" merge-base "$trunk" HEAD 2>/dev/null) || return 0
  body=$(mktemp "${TMPDIR:-/tmp}/evidence-body.XXXXXX") || return 0
  swarm_gh pr view "$pr" --repo "$REPO_SLUG" --json body -q .body > "$body" 2>/dev/null || : > "$body"
  gaps=$(bash "${DRIVER_EVIDENCE_GAPS:-$KIT_ROOT/scripts/evidence-gaps.sh}" coverage "$wt" "$mb" HEAD "$(basename "${plan%/plan.json}")" "$body" 2>/dev/null | cut -f2 | paste -sd' ' -)
  rm -f "$body"
  [ -z "$gaps" ] || printf 'still on no evidence route or capture step: %s' "$gaps"
}

# THE LESSON CHECK READS THE BODY, NOT THE TREE. #13321 parked on a red lesson check a
# code-only repair could never clear. When it is red, the answer's `lesson` is written
# into the PR body as `## Lesson`, the check is re-run on that body here, and only a
# guard the PR's diff carries, or one this repair proved red-then-green, is named.
#
# _driver_repair_reds <failing> <pattern> <in|out> — the ", " list of red check names
# that match the pattern (in), or the ones that do not (out), case-insensitively.
_driver_repair_reds() {
  printf '%s' "$1" | awk -v p="$(printf '%s' "$2" | tr '[:upper:]' '[:lower:]')" -v want="$3" 'BEGIN { RS = ", " }
    { sub(/\n$/, "") } $0 == "" { next }
    { hit = index(tolower($0), p) > 0 } (want == "in" && hit) || (want == "out" && !hit) { o = o (o == "" ? "" : ", ") $0 }
    END { printf "%s", o }'
}

# _driver_repair_body <pr> <out> — the PR body as GitHub holds it now; 1 when unreadable.
_driver_repair_body() {
  gh_read "PR #$1's body" api "repos/$REPO_SLUG/pulls/$1" --jq '.body // ""' > "$2"
}

# _driver_repair_lesson_run <tree> <trunk> <body-file> <row> — the lesson check, run
# here on that body exactly as CI runs it on the PR; prints its output, returns its exit.
_driver_repair_lesson_run() {
  local wt="$1" trunk="$2" body="$3" row="$4" cl rc=0 mb
  mb=$(git -C "$wt" merge-base "$trunk" HEAD 2>/dev/null) || mb="$trunk"
  cl=$(mktemp "${TMPDIR:-/tmp}/repair-lesson-closing.XXXXXX") || return 2
  printf '%s' "$row" | jq -c '[.closingIssuesReferences[]? | {number}]' > "$cl" 2>/dev/null || printf '[]' > "$cl"
  bash "${DRIVER_CHECK_LESSON:-$KIT_ROOT/scripts/check-lesson.sh}" --repo "$wt" --base "$mb" --head HEAD \
    --body-file "$body" --class repair --closing-file "$cl" \
    --labels "$(printf '%s' "$row" | jq -r '[.labels[]?.name] | join(",")' 2>/dev/null)" \
    --title "$(printf '%s' "$row" | jq -r '.title // ""' 2>/dev/null)" \
    --branch "$(printf '%s' "$row" | jq -r '.headRefName // ""' 2>/dev/null)" 2>&1 || rc=$?
  rm -f "$cl"
  return "$rc"
}

# _driver_repair_with_lesson <section-file> — stdin's body with its `## Lesson` section
# replaced by the file's, or the section added before a closing "Generated with" line.
_driver_repair_with_lesson() {
  SECTION="$(cat "$1")" perl -0777 -ne '
    my $s = $ENV{SECTION}; $s =~ s/\s+\z//;
    my @l = split /\n/, $_, -1; pop @l if @l && $l[-1] eq "";
    my ($i) = grep { $l[$_] =~ /^\s*##\s*Lesson\s*$/i } 0..$#l;
    if (defined $i) {
      my $j = $i + 1; $j++ while $j <= $#l && $l[$j] !~ /^\s*#{1,2}\s/ && $l[$j] !~ /Generated with \[Claude/;
      splice @l, $i, $j - $i, (split(/\n/, $s), "");
    } else {
      my ($g) = grep { $l[$_] =~ /Generated with \[Claude/ } reverse 0..$#l;
      if (defined $g) { splice @l, $g, 0, (split(/\n/, $s), "") } else { push @l, "", split(/\n/, $s) }
    }
    print join("\n", @l), "\n";'
}

# _driver_repair_write_lesson <ticket> <tree> <trunk> <base> <pr> <answer> <row> — the
# answer's lesson, judged, written into the body by the REST API and judged again there.
_driver_repair_write_lesson() {
  local t="$1" wt="$2" trunk="$3" base="$4" pr="$5" ans="$6" row="$7" d guard mb out rc=0 k v
  d="$(driver_state_dir "$t")/steps"
  guard=$(jq -r '.lesson.guard // ""' "$ans" | tr -d '`' | sed 's#^\./##; s/^[[:space:]]*//; s/[[:space:]]*$//')
  if [ -z "$guard" ]; then
    driver_say "✋ repair: the lesson check is red and the answer wrote no lesson."
    driver_state_set "$t" park_note "the lesson check is red and the repair wrote no lesson for the PR body"
    return "$DRIVER_E_REFUSED"
  fi
  mb=$(git -C "$wt" merge-base "$trunk" "$base" 2>/dev/null) || mb="$trunk"
  if ! git -C "$wt" diff --name-only "$mb" "$base" 2>/dev/null | grep -qxF -- "$guard" \
     && ! jq -e --arg g "$guard" '[.fixes[]? | select(.proof == "test") | .test.file // "" | ltrimstr("./")] | index($g) != null' "$ans" >/dev/null 2>&1; then
    driver_say "✋ repair: the lesson names \`$guard\` as its guard, and that is neither in PR #$pr's diff nor a test this repair proved red-then-green."
    driver_state_set "$t" park_note "the repair's lesson named a guard ($guard) that is neither in the PR's diff nor proved by the repair"
    return "$DRIVER_E_REFUSED"
  fi
  {
    printf '## Lesson\n'
    for k in principle:Principle guard:Guard beforeAfter:Before/after reach:Reach; do
      v=$(jq -r --arg k "${k%%:*}" '.lesson[$k] // ""' "$ans" | tr '\r\n' '  ' | sed 's/[[:space:]]*$//')
      [ "${k%%:*}" = guard ] && v="\`$guard\`"
      printf -- '- %s: %s\n' "${k#*:}" "$v"
    done
  } > "$d/repair-lesson.md"
  if ! _driver_repair_body "$pr" "$d/repair-body-was.md"; then
    driver_say "✋ repair: could not read PR #$pr's body, so the lesson could not be written into it."
    driver_state_set "$t" park_note "could not read the body of #$pr to write its lesson"
    return "$DRIVER_E_UNREAD"
  fi
  _driver_repair_with_lesson "$d/repair-lesson.md" < "$d/repair-body-was.md" > "$d/repair-body.md"
  out=$(_driver_repair_lesson_run "$wt" "$trunk" "$d/repair-body.md" "$row") || rc=$?
  if [ "$rc" -ne 0 ] || ! printf '%s\n' "$out" | head -1 | grep -q '^lesson: complete'; then
    driver_say "✋ repair: the lesson it wrote does not pass the lesson check here — $(printf '%s' "$out" | head -1)"
    driver_state_set "$t" park_note "the repair's lesson fails the lesson check before it is written: $(printf '%s' "$out" | head -1)"
    return "$DRIVER_E_REFUSED"
  fi
  # gh pr edit is refused by a hook on some machines; the REST call is not.
  if ! swarm_gh api -X PATCH "repos/$REPO_SLUG/pulls/$pr" -F "body=@$d/repair-body.md" >/dev/null 2>&1; then
    driver_say "✋ repair: the lesson passes here and PR #$pr's body could not be updated with it."
    driver_state_set "$t" park_note "could not write the lesson into the body of #$pr"
    return "$DRIVER_E_REFUSED"
  fi
  # COUNTED ON THE BODY GITHUB NOW HOLDS, not on the copy that was sent.
  rc=0
  if ! _driver_repair_body "$pr" "$d/repair-body-now.md"; then
    driver_say "✋ repair: the lesson was sent and PR #$pr's body could not be read back to judge it."
    return "$DRIVER_E_UNREAD"
  fi
  out=$(_driver_repair_lesson_run "$wt" "$trunk" "$d/repair-body-now.md" "$row") || rc=$?
  if [ "$rc" -ne 0 ] || ! printf '%s\n' "$out" | head -1 | grep -q '^lesson: complete'; then
    driver_say "✋ repair: PR #$pr's body, read back, still fails the lesson check — $(printf '%s' "$out" | head -1)"
    driver_state_set "$t" park_note "the lesson was written into #$pr and the body read back still fails the lesson check: $(printf '%s' "$out" | head -1)"
    return "$DRIVER_E_REFUSED"
  fi
  driver_say "   repair: wrote the lesson into PR #$pr's body — $(printf '%s' "$out" | head -1)"
  return "$DRIVER_OK"
}

# A SUPERSEDED RUN IS NOT RED. #13629 refused a lesson-only repair over a CANCELLED run of a
# check whose re-run had passed: each check is read by its latest run alone.
_DRIVER_REPAIR_LATEST='def latest: .statusCheckRollup | newest_runs | .[];'

# _driver_repair_nothing_owed <tree> <trunk> <pr> — 0 when a fresh read of the PR says
# nothing is owed: its head is this tree's and contains the trunk, GitHub reads it
# MERGEABLE, no check on that head settled red (pending is not red), and it is ready
# with auto-merge armed, so it lands with nobody's help. Otherwise prints why not.
_driver_repair_nothing_owed() {
  local wt="$1" trunk="$2" pr="$3" v h red
  v=$(swarm_gh pr view "$pr" --repo "$REPO_SLUG" --json headRefOid,mergeable,isDraft,autoMergeRequest,statusCheckRollup 2>/dev/null)
  if ! printf '%s' "$v" | jq -e 'type == "object"' >/dev/null 2>&1; then
    printf 'PR #%s could not be read afresh' "$pr"; return 1
  fi
  h=$(printf '%s' "$v" | jq -r '.headRefOid // ""')
  if [ -z "$h" ] || [ "$h" != "$(git -C "$wt" rev-parse HEAD 2>/dev/null)" ]; then
    printf 'the head of PR #%s on GitHub (%s) is not this tree head' "$pr" "$(printf '%s' "$h" | cut -c1-10)"; return 1
  fi
  if ! git -C "$wt" merge-base --is-ancestor "$trunk" "$h" 2>/dev/null; then
    printf 'the head %s does not contain %s' "$(printf '%s' "$h" | cut -c1-10)" "$trunk"; return 1
  fi
  if [ "$(printf '%s' "$v" | jq -r '.mergeable // ""')" != MERGEABLE ]; then
    printf 'GitHub reads it as %s, not MERGEABLE' "$(printf '%s' "$v" | jq -r '.mergeable // "unknown"')"; return 1
  fi
  red=$(printf '%s' "$v" | jq -r --argjson nb "$(release_nonblocking_json)" "$RELEASE_NB_JQ$_DRIVER_REPAIR_LATEST"'[latest | select((.conclusion // .state // "") | test("FAILURE|ERROR|TIMED_OUT|CANCELLED|ACTION_REQUIRED|STARTUP_FAILURE"))
    | select(release_nb($nb) | not) | (.name // .context // "?")] | join(", ")')
  if [ -n "$red" ]; then printf 'red on the head: %s' "$red"; return 1; fi
  if [ "$(printf '%s' "$v" | jq -r '(.isDraft == false) and (.autoMergeRequest != null)')" != true ]; then
    printf 'it is a draft or auto-merge is not armed, so nothing lands it'; return 1
  fi
  return 0
}

# _driver_repair_asked_merge <ticket> <tree> <trunk> <answer> <head> — 0 when the answer's
# question asks to merge the trunk and the driver merged it cleanly: never a question,
# so it is taken as yes, once, on a tree left clean at <head>; a head with the trunk in parks.
_driver_repair_asked_merge() {
  local wt="$2" trunk="$3" q
  q=$(jq -r '.question // ""' "$4" 2>/dev/null)
  printf '%s' "$q" | grep -qiE "merg(e|ing)[^.?]*(origin/)?($INTEGRATION_BRANCH|base|trunk)" || return 1
  git -C "$wt" merge-base --is-ancestor "$trunk" HEAD 2>/dev/null && return 1
  [ "$(git -C "$wt" rev-parse HEAD)" = "$5" ] && [ -z "$(git -C "$wt" status --porcelain 2>/dev/null)" ] || return 1
  [ ! -f "$(git -C "$wt" rev-parse --git-path MERGE_HEAD 2>/dev/null)" ] || return 1
  if ! git -C "$wt" merge --no-edit "$trunk" >/dev/null 2>&1; then
    git -C "$wt" merge --abort >/dev/null 2>&1; return 1
  fi
  driver_say "   repair: asked \"$q\" — merging $trunk is never a question; merged at $(git -C "$wt" rev-parse --short HEAD), and the push re-runs CI"
  return 0
}

# _driver_repair_bad_cmds <tree> <answer> — one line per fix whose command cannot be
# run as given, with why; nothing when every one can.
_driver_repair_bad_cmds() {
  local n i c f w why
  n=$(jq -r '[.fixes[]?] | length' "$2" 2>/dev/null); i=0
  while [ "$i" -lt "${n:-0}" ]; do
    c=$(jq -r --argjson i "$i" '.fixes[$i].command // ""' "$2")
    f=$(jq -r --argjson i "$i" '.fixes[$i].test.file // ""' "$2")
    w=$(jq -r --argjson i "$i" '.fixes[$i].what // "a fix"' "$2"); i=$((i+1))
    why=$(driver_proof_cmd_check "$1" "$c" "${f:-<file>}") || printf -- "- %s: \`%s\` — %s\n" "$w" "$c" "$why"
  done
}

# AN EARLIER ROUND'S FIX IS NOT THIS ROUND'S, AND NOT A SPOOF EITHER. #12858 was refused
# whole because its answer listed pairs a parked round had committed on the branch
# before this one started, throwing away this round's proved fixes with them.
#
# _driver_repair_fix_kind <tree> <base> <trunk> <implCommit> — own (made after <base>),
# earlier (on the branch at or before <base>, not on the trunk), or foreign (refused).
# A test fix with no testCommit never gets here: the answer's schema sends it back.
_driver_repair_fix_kind() {
  local wt="$1" base="$2" trunk="$3" fx b
  fx=$(git -C "$wt" rev-parse --verify -q "${4:-none}^{commit}" 2>/dev/null) || { echo foreign; return; }
  b=$(git -C "$wt" rev-parse --verify -q "$base^{commit}" 2>/dev/null) || { echo foreign; return; }
  git -C "$wt" merge-base --is-ancestor "$fx" HEAD 2>/dev/null || { echo foreign; return; }
  if [ "$fx" != "$b" ] && git -C "$wt" merge-base --is-ancestor "$b" "$fx" 2>/dev/null; then
    echo own; return
  fi
  if git -C "$wt" merge-base --is-ancestor "$fx" "$b" 2>/dev/null \
     && ! git -C "$wt" merge-base --is-ancestor "$fx" "$trunk" 2>/dev/null; then
    echo earlier; return
  fi
  echo foreign
}

# _driver_repair_stale_answers <tree> <base> <trunk> <answer> <owes 0|1> — a line when
# this round owes a fix and every fix it named is an earlier round's; nothing otherwise.
_driver_repair_stale_answers() {
  local wt="$1" base="$2" trunk="$3" ans="$4" owes="$5" n i k own=0 old=""
  n=$(jq -r '[.fixes[]?] | length' "$ans" 2>/dev/null); i=0
  while [ "$i" -lt "${n:-0}" ]; do
    if [ "$(jq -r --argjson i "$i" '.fixes[$i].proof // ""' "$ans")" != test ]; then own=$((own+1)); i=$((i+1)); continue; fi
    k=$(_driver_repair_fix_kind "$wt" "$base" "$trunk" "$(jq -r --argjson i "$i" '.fixes[$i].implCommit // ""' "$ans")")
    case "$k" in
      own) own=$((own+1)) ;;
      earlier) old="$old $(jq -r --argjson i "$i" '.fixes[$i].implCommit // ""' "$ans" | cut -c1-10)" ;;
    esac
    i=$((i+1))
  done
  if [ "$owes" -eq 1 ] && [ "$own" -eq 0 ] && [ -n "$old" ]; then
    printf -- "- every fix named (%s) was committed at or before %s, where this repair started: an earlier round's, proved then. What this round owes needs a fix of its own, committed after it, with its own test.\n" "${old# }" "$(printf '%s' "$base" | cut -c1-8)"
  fi
}

# _driver_repair_marked <ticket> <tree> — with a merge in progress, each conflicted
# file (git's unmerged paths and the record's) that still carries a conflict marker.
_driver_repair_marked() {
  local wt="$2" p
  git -C "$wt" rev-parse -q --verify MERGE_HEAD >/dev/null 2>&1 || return 0
  printf '%s\n%s\n' "$(git -C "$wt" diff --name-only --diff-filter=U 2>/dev/null)" "$(driver_state_get "$1" repair_conflicted)" \
    | sed '/^$/d' | sort -u | while IFS= read -r p; do
      [ -f "$wt/$p" ] && grep -qE '^(<<<<<<<|>>>>>>>)( |$)' "$wt/$p" 2>/dev/null && printf '%s\n' "$p"
    done
}

# _driver_repair_own_trunk <ticket> <tree> <trunk-sha> <answer> — the driver's own merge
# of the trunk. 0: the head has <trunk-sha> as an ancestor (already, or by a merge
# commit made here with both parents). 2: the merge is left in progress and the files
# in DRIVER_REPAIR_LEFT still need the model. 1: git refused it. A merge left in
# progress is committed only with nothing unmerged and no marker. A head that lacks the trunk is merged with --no-ff; each
# file it conflicts in takes the model's resolution (the tree's copy of a file on the
# record, with no marker) when the trunk has not changed that file since the model
# resolved it, and every other conflicted file is handed back.
_driver_repair_own_trunk() {
  local t="$1" wt="$2" tsha="$3" ans="$4" at rec p saved left="" took=""
  DRIVER_REPAIR_LEFT=""
  [ -n "$tsha" ] || return 1
  if git -C "$wt" rev-parse -q --verify MERGE_HEAD >/dev/null 2>&1; then
    left=$(printf '%s\n%s\n' "$(_driver_repair_marked "$t" "$wt")" "$(git -C "$wt" diff --name-only --diff-filter=U 2>/dev/null)" | sed '/^$/d' | sort -u)
    [ -z "$left" ] || { DRIVER_REPAIR_LEFT="$left"; return 2; }
    git -C "$wt" commit -q --no-edit >/dev/null 2>&1 || return 1
  fi
  git -C "$wt" merge-base --is-ancestor "$tsha" HEAD 2>/dev/null && return 0
  at=$(driver_state_get "$t" repair_trunk_sha); rec=$(driver_state_get "$t" repair_conflicted)
  saved=$(mktemp -d "${TMPDIR:-/tmp}/repair-own-trunk.XXXXXX")
  while IFS= read -r p; do
    [ -n "$p" ] && [ -f "$wt/$p" ] || continue
    grep -qE '^(<<<<<<<|>>>>>>>)( |$)' "$wt/$p" 2>/dev/null && continue
    mkdir -p "$saved/$(dirname "$p")" && cp -p "$wt/$p" "$saved/$p" || continue
    git -C "$wt" diff --quiet HEAD -- ":(literal)$p" 2>/dev/null || git -C "$wt" checkout -q HEAD -- ":(literal)$p" 2>/dev/null
  done <<<"$rec"
  git -C "$wt" -c merge.conflictStyle=merge merge --no-ff --no-commit "$tsha" >"$(driver_state_dir "$t")/steps/repair-own-merge.out" 2>&1
  if ! git -C "$wt" rev-parse -q --verify MERGE_HEAD >/dev/null 2>&1; then
    git -C "$wt" merge-base --is-ancestor "$tsha" HEAD 2>/dev/null && { rm -rf "$saved"; return 0; }
    driver_say "   repair: the driver's merge of $(printf '%s' "$tsha" | cut -c1-10) did not start — $(tail -2 "$(driver_state_dir "$t")/steps/repair-own-merge.out" | tr '\n' ' ')"
    rm -rf "$saved"; return 1
  fi
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    if [ -f "$saved/$p" ] && [ -n "$at" ] && git -C "$wt" diff --quiet "$at" "$tsha" -- ":(literal)$p" 2>/dev/null; then
      cp -p "$saved/$p" "$wt/$p" && git -C "$wt" add -- ":(literal)$p" && { took="$took$p "; continue; }
    fi
    left="$left$p"$'\n'
  done <<<"$(git -C "$wt" diff --name-only --diff-filter=U 2>/dev/null)"
  rm -rf "$saved"
  [ -z "$took" ] || driver_say "   repair: the driver merged $(printf '%s' "$tsha" | cut -c1-10) itself and kept the model's resolution of ${took}"
  if [ -n "$left" ]; then DRIVER_REPAIR_LEFT="$left"; return 2; fi
  git -C "$wt" commit -q --no-edit >/dev/null 2>&1 || return 1
  driver_say "   repair: the driver made the merge of $(printf '%s' "$tsha" | cut -c1-10) at $(git -C "$wt" rev-parse --short HEAD), both parents kept"
  return 0
}

# _driver_repair_hand_back <ticket> <tree> <trunk> <answer> <files> — asks the model once
# more to resolve only <files>, marked in the driver's merge in progress. The first
# answer's fixes stay; the second's conflicts and gitActions are taken.
_driver_repair_hand_back() {
  local t="$1" wt="$2" trunk="$3" ans="$4" files="$5" d rc=0
  d=$(driver_state_dir "$t")
  files=$(printf '%s\n' "$files" | sed '/^$/d' | sort -u)
  driver_state_set "$t" repair_conflicted "$(printf '%s\n%s\n' "$(driver_state_get "$t" repair_conflicted)" "$files" | sed '/^$/d' | sort -u)"
  driver_state_set "$t" repair_trunk_sha "$(git -C "$wt" rev-parse -q --verify MERGE_HEAD 2>/dev/null)"
  driver_say "↩ repair: the driver's merge of $trunk is in progress with markers in $(printf '%s' "$files" | tr '\n' ' ')— handed back to the model"
  cp "$ans" "$d/steps/repair-first.json"
  driver_fact_put "$t" repair CONFLICTS "the driver merged $trunk into this branch itself; the merge is in progress and still conflicts in: $(printf '%s' "$files" | tr '\n' ' ')— resolve only those files with the Edit tool, never a script, leave every other file as it is, then list \`commitMerge\` in \`gitActions\`. Never abort, reset or commit the merge yourself."
  driver_fact_put "$t" repair BRIEF "THE MERGE IS THE DRIVER'S. It merged $trunk itself and these files still carry conflict markers: $(printf '%s' "$files" | tr '\n' ' '). Resolve only them, keeping both sides' intent, and answer with \`commitMerge\` in \`gitActions\`; the commits and fixes you already made stay."
  driver_ai_step "$t" repair || rc=$?
  [ "$rc" -eq 0 ] || return "$rc"
  jq -s '.[0] + {gitActions: (.[1].gitActions // []), conflicts: ((.[0].conflicts // []) + (.[1].conflicts // []))}' \
    "$d/steps/repair-first.json" "$ans" > "$d/steps/repair-merged.json" 2>/dev/null \
    && mv "$d/steps/repair-merged.json" "$ans"
  return 0
}

driver_step_repair() { # <ticket>
  local t="${1:?driver_step_repair: need a ticket}"
  local d wt branch pr base trunk row mstate failing="" unreadable=0 conflicted="" conflicts_fact merged=0
  local need=0 rc ans i n proof bid tfile tcmd tsha isha why prc grc dirty briefs_text
  export DRIVER_TICKET="$t"
  d=$(driver_state_dir "$t")
  wt=$(driver_state_get "$t" worktree); branch=$(driver_state_get "$t" branch)
  pr=$(driver_state_get "$t" pr); base=$(driver_state_get "$t" repair_base)
  if [ -z "$wt" ] || [ ! -d "$wt" ] || [ -z "$base" ]; then
    driver_say "✋ repair: there is no re-entered worktree on the record for #$t — reenter runs first."
    return "$DRIVER_E_REFUSED"
  fi
  _driver_repair_claim_busy "$t" "before the repair touches its tree" && return "$DRIVER_E_BUSY"
  trunk="origin/$INTEGRATION_BRANCH"
  git -C "$wt" fetch -q origin "+refs/heads/$INTEGRATION_BRANCH:refs/remotes/$trunk" 2>/dev/null || true
  git -C "$wt" rev-parse --verify -q "$trunk" >/dev/null 2>&1 || trunk="$INTEGRATION_BRANCH"

  # The PR as GitHub sees it now (the shared copy), not as the brief that sent this saw it.
  local mergeable=""
  if row=$(driver_open_prs); then
    row=$(printf '%s' "$row" | jq -c --argjson n "${pr:-0}" '[.[] | select(.number == $n)] | first // empty')
  else
    unreadable=1; row=""
  fi
  if [ -n "$row" ]; then
    mstate=$(printf '%s' "$row" | jq -r '.mergeStateStatus // ""')
    mergeable=$(printf '%s' "$row" | jq -r '.mergeable // ""')
    # The sign-off hold's own check is red BY the hold: no repair turns it green.
    # A check in release.nonBlockingChecks warns until the release: not this repair's to answer.
    failing=$(printf '%s' "$row" | jq -r --arg gate "$(driver_opt coordinator.holdCheck approval)" --argjson nb "$(release_nonblocking_json)" "$RELEASE_NB_JQ$_DRIVER_REPAIR_LATEST"'[latest | select((.conclusion // .state // "") | test("FAILURE|ERROR|TIMED_OUT|CANCELLED|ACTION_REQUIRED"))
      | select(release_nb($nb) | not)
      | select(((.name // .context // "") | ascii_downcase) | contains($gate | ascii_downcase) | not) | (.name // .context // "?")] | join(", ")')
    local nb_warn; nb_warn=$(release_warn_reds "$(printf '%s' "$row" | jq -c '.statusCheckRollup // []')")
    [ -z "$nb_warn" ] || driver_say "   repair: warning, not blocking — $nb_warn red on PR #$pr; listed in release.nonBlockingChecks, so this repair does not answer it"
  else
    mstate=$(driver_state_get "$t" merge_state); unreadable=1
  fi

  # A STALE RED IS RE-RUN, NOT ASKED ABOUT. #12612 parked on a lesson check that failed
  # on 18 Oct against a PR body fixed since. A failing Actions check that finished before
  # the PR's last update, or more than DRIVER_STALE_CHECK_HOURS (12) ago, is re-run
  # (each run once per record) and leaves the red list; a fresh red stays on it.
  if [ -n "$failing" ] && [ -n "$row" ]; then
    local stale sname srun rerun_done rerun_names=""
    rerun_done=$(driver_state_get "$t" reran_runs)
    stale=$(printf '%s' "$row" | jq -r --argjson h "${DRIVER_STALE_CHECK_HOURS:-12}" --argjson nb "$(release_nonblocking_json)" "$RELEASE_NB_JQ$_DRIVER_REPAIR_LATEST"'
      (.updatedAt // "") as $upd | ((now - $h * 3600) | todate) as $cut
      | latest | select(.__typename == "CheckRun") | select(release_nb($nb) | not)
      | select((.conclusion // "") | test("FAILURE|ERROR|TIMED_OUT|CANCELLED|ACTION_REQUIRED"))
      | select((.completedAt // "") != "" and ((.completedAt < $upd) or (.completedAt < $cut)))
      | ((.detailsUrl // "") | ((capture("/actions/runs/(?<r>[0-9]+)") | .r) // "")) as $run
      | select($run != "") | "\(.name)\t\($run)"' 2>/dev/null)
    while IFS=$'\t' read -r sname srun; do
      [ -n "$srun" ] || continue
      case " $rerun_done " in *" $srun "*) continue ;; esac
      if swarm_gh run rerun "$srun" --failed --repo "$REPO_SLUG" >/dev/null 2>&1; then
        rerun_done="$rerun_done $srun"
        driver_say "   repair: '$sname' failed on an older run ($srun) — re-run rather than asked about"
        rerun_names="$rerun_names|$sname|"
      fi
    done <<EOS
$stale
EOS
    driver_state_set "$t" reran_runs "${rerun_done# }"
    if [ -n "$rerun_names" ]; then
      failing=$(printf '%s' "$failing" | awk -v k="$rerun_names" 'BEGIN { RS = ", " }
        { sub(/\n$/, "") } $0 != "" && index(k, "|" $0 "|") == 0 { o = o (o == "" ? "" : ", ") $0 } END { printf "%s", o }')
    fi
  fi

  # The lesson check's red is the PR body's to answer; every other red is the tree's.
  local lesson_pat lesson_red code_failing
  lesson_pat=$(driver_opt lesson.check lesson)
  lesson_red=$(_driver_repair_reds "$failing" "$lesson_pat" in)

  # ---- the clash ---------------------------------------------------------------
  # A RED ON A BRANCH BEHIND THE TRUNK MERGES THE TRUNK FIRST. #13285 parked on the owner
  # asking "merge origin/develop and re-run?": merging the base is always allowed, so a
  # red on a head that lacks the trunk is merged and re-run by CI, never asked about.
  local resumed_merge=0 marked behind_red
  behind_red=$(_driver_repair_reds "$failing" "$lesson_pat" out)
  if [ -f "$(git -C "$wt" rev-parse --git-path MERGE_HEAD 2>/dev/null)" ]; then
    # A resumed pass finds the merge it left for the model. What it conflicted in is
    # the record's list as well as git's: a file staged unresolved is no longer a U
    # path, and the merge is still not finished.
    resumed_merge=1
    conflicted=$(printf '%s\n%s\n' "$(git -C "$wt" diff --name-only --diff-filter=U 2>/dev/null)" "$(driver_state_get "$t" repair_conflicted)" | sed '/^$/d' | sort -u)
    [ -n "$conflicted" ] || conflicted=$(git -C "$wt" diff --cached --name-only 2>/dev/null)
    driver_say "   repair: resuming the merge of $trunk an earlier pass left in progress"
    driver_state_set "$t" repair_trunk_sha "$(git -C "$wt" rev-parse -q --verify MERGE_HEAD 2>/dev/null)"
  elif ! git -C "$wt" merge-base --is-ancestor "$trunk" HEAD 2>/dev/null \
       && { [ -n "$behind_red" ] || _driver_repair_clashes "$wt" "$trunk" "$mstate" "$mergeable"; }; then
    driver_state_set "$t" repair_trunk_sha "$(git -C "$wt" rev-parse -q --verify "$trunk^{commit}" 2>/dev/null)"
    if git -C "$wt" merge --no-ff --no-edit "$trunk" >"$d/steps/repair-merge.out" 2>&1; then
      merged=1
      driver_say "   repair: merged $trunk into $branch cleanly at $(git -C "$wt" rev-parse --short HEAD)"
      if [ -n "$behind_red" ]; then
        failing=$(_driver_repair_reds "$failing" "$lesson_pat" in)
        driver_say "   repair: the red ($behind_red) is on a head behind $trunk — the push re-runs CI on the merge rather than asking"
      fi
      # The trunk can bring packages the tree's install was never linked with.
      driver_refresh_install "$MAIN_REPO" "$wt" || driver_say "   repair: relinking the install after the merge failed — self-check tries again."
    else
      conflicted=$(git -C "$wt" diff --name-only --diff-filter=U 2>/dev/null)
      if [ -z "$conflicted" ]; then
        git -C "$wt" merge --abort >/dev/null 2>&1
        driver_say "✋ repair: merging $trunk failed with nothing conflicted — $(tail -3 "$d/steps/repair-merge.out" | tr '\n' ' ')"
        return "$DRIVER_E_REFUSED"
      fi
      driver_say "   repair: merging $trunk conflicted in $(printf '%s' "$conflicted" | tr '\n' ' ')— handed to the model"
    fi
  fi
  # A DELETION ON THE TRUNK IS TAKEN BY THE DRIVER, never left to the model: its
  # permission mode refuses `git rm`, and #13139 parked three times asking for one.
  local p took="" rest="" retired=""
  if [ -n "$conflicted" ]; then
    while IFS= read -r p; do
      [ -n "$p" ] || continue
      if _driver_repair_deleted_on_base "$wt" "$p"; then
        if _driver_repair_branch_kept "$wt" "$p" && git -C "$wt" rm -q -f --ignore-unmatch -- "$p" >/dev/null 2>&1; then
          took="$took$p "; continue
        fi
        retired="$retired$p "
      fi
      rest="$rest$p"$'\n'
    done <<<"$conflicted"
    conflicted=$(printf '%s' "$rest" | sed '/^$/d')
    if [ -n "$took" ]; then
      driver_say "   repair: took $trunk's deletion of ${took}— the branch never changed them"
      if [ -z "$conflicted" ] && [ -z "$(git -C "$wt" diff --name-only --diff-filter=U 2>/dev/null)" ] \
         && git -C "$wt" commit -q --no-edit >/dev/null 2>&1; then
        merged=1; resumed_merge=0; driver_state_set "$t" repair_conflicted ""
        driver_say "   repair: merged $trunk into $branch at $(git -C "$wt" rev-parse --short HEAD) with nothing left conflicted"
        driver_refresh_install "$MAIN_REPO" "$wt" || driver_say "   repair: relinking the install after the merge failed — self-check tries again."
      fi
    fi
  fi
  if [ -n "$conflicted" ]; then
    conflicts_fact="merging $trunk into $branch conflicted, and the merge is left in progress for you in: $(printf '%s' "$conflicted" | tr '\n' ' ')— resolve each with the Edit tool, then list \`commitMerge\` in \`gitActions\` and the driver stages and commits the merge"
    [ -n "$retired" ] && conflicts_fact="$conflicts_fact
$trunk DELETED ${retired}and this branch edited them. When the trunk retired a file and the branch's edits only served that retired purpose, take the deletion: never run \`git rm\` yourself (your permission mode refuses it) — list each path in \`takeBaseDeletions\`, resolve and stage the rest, and the driver runs the \`git rm\` and the merge commit. When the edit is still wanted, keep it and say why in \`conflicts\`."
    driver_state_set "$t" repair_conflicted "$conflicted"
  elif [ "$merged" -eq 1 ]; then
    conflicts_fact="merged $trunk cleanly; nothing conflicted"
  else
    conflicts_fact="not needed: the branch does not clash with $trunk"
  fi

  # A MARKER ALREADY COMMITTED is caught on every pass, before anything decides
  # there is nothing to do: an interrupted pass may have left one, and with CI green
  # nothing else would ever look.
  if [ "$resumed_merge" -eq 0 ]; then
    marked=$(driver_conflict_markers "$wt" "$trunk")
    if [ -n "$marked" ]; then
      driver_say "✋ repair: a conflict marker is committed on $branch in $(printf '%s' "$marked" | tr '\n' ' ')— an earlier pass concluded a merge that was never resolved."
      driver_state_set "$t" park_note "conflict markers are committed on $branch in: $(printf '%s' "$marked" | tr '\n' ' ')"
      return "$DRIVER_E_REFUSED"
    fi
  fi
  # WORK AN EARLIER ROUND MADE AND NEVER PUSHED. A repair that parks is not pushed, so
  # the next round re-enters a tree ahead of the PR: the trunk already merged, fixes
  # already committed. GitHub still reads the old head as clashing and red, the model
  # rightly finds nothing to do, and #12840 parked ten times on "committed nothing".
  # Those commits are this repair's: the PR's red and its clash belong to the older
  # head, and the gates, the review and the push after this step take the new one.
  local prhead carried=0 old_red=""
  prhead=$(printf '%s' "$row" | jq -r '.headRefOid // ""' 2>/dev/null)
  if [ -n "$prhead" ] && [ -z "$conflicted" ] \
     && [ "$(git -C "$wt" rev-parse HEAD)" != "$prhead" ] \
     && git -C "$wt" merge-base --is-ancestor "$prhead" HEAD 2>/dev/null \
     && git -C "$wt" merge-base --is-ancestor "$trunk" HEAD 2>/dev/null; then
    carried=$(git -C "$wt" rev-list --count "$prhead"..HEAD 2>/dev/null || echo 0)
    old_red="$failing"; failing=""
    driver_say "   repair: this tree is $carried commit(s) ahead of PR #$pr's head with $trunk merged in — an earlier round's work, never pushed. ${old_red:+The red (${old_red}) is on the older head; }the gates, the review and the push take this one."
    base=$prhead; driver_state_set "$t" repair_base "$prhead"
  fi
  # A LESSON RED IS RE-RUN HERE BEFORE IT IS OWED. GitHub's check run may be on an older
  # head or an older body; the push takes this tree and the body as it is now.
  if [ -n "$lesson_red" ] && [ -n "$row" ]; then
    local fbody="$d/steps/repair-body-fresh.md" fout frc=0
    if _driver_repair_body "$pr" "$fbody"; then
      fout=$(_driver_repair_lesson_run "$wt" "$trunk" "$fbody" "$row") || frc=$?
      if [ "$frc" -eq 0 ]; then
        driver_say "   repair: '$lesson_red' reads red on GitHub, and run here on PR #$pr's body now and this tree's diff it passes ($(printf '%s\n' "$fout" | head -1)) — not owed"
        lesson_red=""
        failing=$(_driver_repair_reds "$failing" "$lesson_pat" out)
      fi
    fi
  fi
  code_failing=$(_driver_repair_reds "$failing" "$lesson_pat" out)
  # A RED THE BASE HAS TOO IS THE BASE'S, NEVER A QUESTION. #13365, #13314 and #8476 each
  # parked asking "this test is outside the PR and fails on develop too — fix it here?",
  # which the PM's standing answer settles: it waits for develop's fix. Read, not assumed
  # (base-wait.sh): the failing tests from the PR's CI log are outside its diff, and the
  # base's newest completed run of the same check fails on them too.
  local base_only="" base_tests="" cname ckind cwhy
  driver_state_set "$t" base_red_tests ""
  if [ -n "$code_failing" ] && [ -n "$prhead" ] && [ -z "$conflicted" ] && [ "$merged" -eq 0 ]; then
    while IFS=$'\t' read -r cname ckind cwhy; do
      [ -n "$cname" ] || continue
      if [ "$ckind" = base ]; then
        base_only="$base_only${base_only:+, }$cname"; base_tests="$base_tests${base_tests:+ }$cwhy"
        driver_say "   repair: '$cname' is red on $cwhy — outside this PR, and red on $trunk's latest completed run too: the base's to fix, not this repair's"
      else
        driver_say "   repair: '$cname' is this PR's own red — $cwhy"
      fi
    done <<EOS
$(base_red_classify "$wt" "$trunk" "$prhead" "$code_failing" "$d/steps/base-red")
EOS
    if [ -n "$base_only" ]; then
      failing=$(printf '%s' "$failing" | awk -v k="|$(printf '%s' "$base_only" | sed 's/, /|/g')|" 'BEGIN { RS = ", " }
        { sub(/\n$/, "") } $0 != "" && index(k, "|" $0 "|") == 0 { o = o (o == "" ? "" : ", ") $0 } END { printf "%s", o }')
      code_failing=$(_driver_repair_reds "$failing" "$lesson_pat" out)
      driver_state_set "$t" base_red_tests "$base_tests"
      # The trunk's red gets its one ticket, whichever step met it first.
      local brsha; brsha=$(driver_base_red_sha "$wt") \
        && driver_base_red_note "$t" "$brsha" "$(printf '%s' "$base_tests" | tr ' ' '\n' | sed '/^$/d' | sort -u | paste -sd, -)" "$pr"
    fi
  fi
  # What only a fix of this round's own answers: a red in the tree, unread checks, a caller's brief.
  local owes=0
  { [ -n "$code_failing" ] || [ "$unreadable" -eq 1 ] || [ "$(driver_state_get "$t" repair_brief_source)" = caller ]; } && owes=1
  [ -n "$conflicted" ] && need=1
  [ -n "$failing" ] && need=1
  [ -n "$lesson_red" ] && need=1
  [ "$unreadable" -eq 1 ] && need=1
  # A CALLER'S BRIEF IS ALWAYS READ. An owner's answer on a ticket with an open PR
  # arrives as a repair with a note; read only when something is red, it would be
  # dropped on a green PR. The brief written for a note-less healing run is not one.
  [ "$(driver_state_get "$t" repair_brief_source)" = caller ] && need=1
  # AN ADOPTED DRAFT IS UNFINISHED WORK: the model reads the adoption brief and finishes it.
  [ "$(driver_state_get "$t" repair_brief_source)" = adopt ] && need=1
  # EVIDENCE OWED IS WORK, though nothing red says so. Three repairs were told to add
  # shots and pushed without touching the capture plan: the PR could never pass the
  # critic. The judge's evidence-class findings and the changed screen files no route or
  # capture step renders are tasks, and a repair that leaves them open is refused.
  local ev_tasks="" plan_rel left=""
  plan_rel=$(driver_evidence_plan "$t")
  [ -n "$pr" ] && ev_tasks=$(driver_evidence_tasks "$t" "$wt" "$trunk" "$pr")
  [ -n "$ev_tasks" ] && { need=1; driver_say "   repair: PR #$pr owes evidence — $(printf '%s\n' "$ev_tasks" | grep -c .) task(s) for the capture plan"; }
  # EVERY RED THE BASE'S: the repair waits for the base. No model, no label, no question.
  # A brief a caller sent is never lost to the wait: it rides on the ledger and comes
  # back in the note that ends the wait (a finished wait's own note carries the one before).
  if [ -n "$base_only" ] && [ -z "$failing" ] && [ -z "$lesson_red" ] && [ -z "$conflicted" ] \
     && [ "$unreadable" -eq 0 ] && [ -z "$ev_tasks" ]; then
    local bw_brief="$d/base-wait-brief.md"
    : > "$bw_brief"
    if [ "$(driver_state_get "$t" repair_brief_source)" = caller ]; then
      sed '1s/^Coordinator note ([a-z-]*): //' "$(driver_state_get "$t" repair_brief)" > "$bw_brief.tmp" 2>/dev/null
      if head -1 "$bw_brief.tmp" 2>/dev/null | grep -q "^$BASE_WAIT_NOTE_PREFIX"; then
        sed -n "s/.*$BASE_WAIT_BRIEF_MARK//p" "$bw_brief.tmp" > "$bw_brief"
      else
        cat "$bw_brief.tmp" > "$bw_brief"
      fi
      rm -f "$bw_brief.tmp"
    fi
    driver_state_set "$t" base_wait_checks "$base_only"
    driver_state_set "$t" base_wait_head "$prhead"
    driver_state_set "$t" base_wait_brief "$bw_brief"
    driver_say "⏸ repair: every red on PR #$pr ($base_only) is in tests outside it that fail on $trunk too — waiting for $INTEGRATION_BRANCH's fix, never repaired in the PR"
    return "$DRIVER_E_BASE_WAIT"
  fi
  if [ "$need" -eq 0 ]; then
    if [ "$merged" -eq 1 ]; then driver_say "   repair: the clash is merged, and nothing is red"
    else driver_say "   repair: nothing red and nothing clashing on PR #$pr — no fix to make; the gates and the review still run"; fi
    return "$DRIVER_OK"
  fi

  # ---- the one model call ------------------------------------------------------
  _driver_repair_claim_busy "$t" "before the model is handed the repair" && return "$DRIVER_E_BUSY"
  briefs_text=$(cat "$(driver_state_get "$t" repair_brief)" 2>/dev/null)
  driver_fact_put "$t" repair BRIEF "$DRIVER_BRIEF_PREFACE

${briefs_text:-(no brief came with this repair — it was sent as a healing spawn with no note)}"
  driver_fact_put "$t" repair PR "#$pr on $branch, repaired from $(printf '%s' "$base" | cut -c1-12), merge state ${mstate:-unknown}"
  if [ "$unreadable" -eq 1 ]; then
    driver_fact_put "$t" repair FAILING "the pull request's checks could not be read from GitHub — read them yourself (gh pr checks $pr) before deciding anything is green"
  else
    # Built apart: an apostrophe inside ${var:+...} breaks bash 3.2's parse.
    local base_fact=""
    [ -z "$base_only" ] || base_fact="

Not yours to fix: $base_only is red in $base_tests, tests outside this PR that fail on the latest completed run of $trunk too. It waits for the fix on $INTEGRATION_BRANCH and is never repaired in this PR: touch nothing for it, ask nothing about it, and leave it out of your fixes. This check is red on $INTEGRATION_BRANCH itself; the develop-red ticket owns it; carry on."
    driver_fact_put "$t" repair FAILING "${failing:-none settled red}$(driver_failing_log_tails "$(printf '%s' "$row" | jq -c '.statusCheckRollup // []' 2>/dev/null)" "$code_failing")$base_fact"
  fi
  driver_fact_put "$t" repair CONFLICTS "$conflicts_fact"
  local lfact="it is not red, so answer no \`lesson\`." lbody lout lhow
  if [ -n "$lesson_red" ]; then
    lhow="It reads the pull request BODY, so no code change turns it green. Answer \`lesson\`: the driver writes it into the body as \`## Lesson\`, re-runs the check on that body, and only then counts it. The principle is one sentence naming the class of mistake, read off this PR's own diff and tests. \`guard\` is one test the diff already adds or changes in substance. When the fix has no test, add one and prove it though the fix is already in: commit the new test with the fix reverted (red), then a commit restoring the fix (green), and report it under \`fixes\` with proof test, \`testCommit\` the first and \`implCommit\` the second. With no other red and the guard already in the diff, \`lesson\` alone with nothing committed is the whole repair. A guard neither in the PR's diff nor proved by this repair is refused: never name a guard that is not there."
    lbody="$d/steps/repair-body-before.md"
    if _driver_repair_body "$pr" "$lbody"; then
      lout=$(_driver_repair_lesson_run "$wt" "$trunk" "$lbody" "$row")
      lfact="red ($lesson_red). $lhow
Run here on the body as it stands, it says:
$(printf '%s\n' "$lout" | head -3)
The body's current lesson section: $(perl -ne 'if (/^\s*##\s*Lesson\s*$/i) { $in = 1 } elsif ($in && /^\s*#{1,2}\s/) { $in = 0 } print if $in' "$lbody" | head -12)"
    else
      lfact="red ($lesson_red). $lhow
The body could not be read here: read it yourself (gh pr view $pr --json body)."
    fi
  fi
  driver_fact_put "$t" repair LESSON "$lfact"
  local diff; diff=$(driver_handover_diff "$wt" "$trunk"...HEAD $conflicted)
  driver_fact_put "$t" repair DIFF "${diff:-(none — the branch carries no change against $trunk)}"

  # NO COMMIT ON A RED PR IS NOT A REPAIR, whatever the answer calls itself. #13317
  # answered 'repaired' and then 'unchanged', committing nothing both times, with five
  # checks red, and parked twice as "the driver's" fault. So it is asked once more,
  # the red checks named in front of its brief; a second empty answer parks with them.
  local pre_model pre_dirty attempt=1 reask st lesson_only=0
  # Once, before the first ask: a re-ask must not adopt a tool's edit from the first.
  pre_dirty=$(git -C "$wt" diff --name-only 2>/dev/null)
  while :; do
    pre_model=$(git -C "$wt" rev-parse HEAD)
    rc=0; driver_ai_step "$t" repair || rc=$?
    if [ "$rc" -eq "$DRIVER_E_QUESTION" ] && _driver_repair_asked_merge "$t" "$wt" "$trunk" "$d/steps/repair.json" "$pre_model"; then
      driver_refresh_install "$MAIN_REPO" "$wt" || driver_say "   repair: relinking the install after the merge failed — self-check tries again."
      return "$DRIVER_OK"
    fi
    [ "$rc" -eq 0 ] || return "$rc"
    ans="$d/steps/repair.json"
    jq -c '(.replacedTests // [])[]' "$ans" >> "$d/steps/replaced.jsonl" 2>/dev/null || true
    reask=""; st=$(jq -r '.status // ""' "$ans")
    lesson_only=0
    [ -n "$lesson_red" ] && [ -z "$code_failing" ] && [ "$unreadable" -eq 0 ] && [ -z "$conflicted" ] \
      && [ -n "$(jq -r '.lesson.guard // ""' "$ans")" ] && lesson_only=1
    if [ -n "$failing" ] || [ -n "$lesson_red" ] || [ "$unreadable" -eq 1 ]; then
      if [ "$st" = unchanged ]; then
        reask="answered unchanged"
      elif [ "$lesson_only" -eq 0 ] && [ "$(git -C "$wt" rev-parse HEAD)" = "$(git -C "$wt" rev-parse "$base" 2>/dev/null)" ] \
           && [ ! -f "$(git -C "$wt" rev-parse --git-path MERGE_HEAD 2>/dev/null)" ]; then
        reask="answered '${st:-?}' and committed nothing (the head is still $(printf '%s' "$base" | cut -c1-8))"
      fi
    fi
    if [ -z "$reask" ] && [ -n "$lesson_red" ] && [ "$st" = repaired ] && [ -z "$(jq -r '.lesson.guard // ""' "$ans")" ]; then
      reask="answered repaired with no lesson while the lesson check ($lesson_red) is red, and only a lesson in the PR body turns it green"
    fi
    if [ -z "$reask" ] && [ -n "$ev_tasks" ] && [ "$st" != park ]; then
      left=$(_driver_repair_evidence_left "$t" "$wt" "$trunk" "$base" "$plan_rel" "$pr")
      if [ -n "$left" ] && [ "$attempt" -eq 1 ]; then
        attempt=2
        driver_say "↩ repair: answered '${st:-?}' and left the evidence it owes open ($left) — asked once more, with the tasks named."
        driver_fact_put "$t" repair BRIEF "YOUR LAST ANSWER LEFT THE EVIDENCE OPEN: $left. Each evidence task is answered by an edit to the capture plan $plan_rel, committed, with the setup steps that bring the state into view — a code change alone leaves it open. The tasks:
$ev_tasks

$DRIVER_BRIEF_PREFACE

${briefs_text:-(no brief came with this repair — it was sent as a healing spawn with no note)}"
        continue
      fi
    fi
    if [ -z "$reask" ] && [ "$attempt" -eq 1 ] && [ "$st" != park ]; then
      local badcmd; badcmd=$(_driver_repair_bad_cmds "$wt" "$ans")
      if [ -n "$badcmd" ]; then
        attempt=2
        driver_say "↩ repair: a fix's command cannot be run as given — asked once more, told why, with no proof run."
        driver_fact_put "$t" repair BRIEF "YOUR LAST ANSWER NAMED A COMMAND THE DRIVER CANNOT RUN. Each fix's \`command\` is run verbatim from the worktree root, at the fix's parent and at the fix:
$badcmd
Answer again with the exact command; the commits you made stay.

$DRIVER_BRIEF_PREFACE

${briefs_text:-(no brief came with this repair — it was sent as a healing spawn with no note)}"
        continue
      fi
    fi
    if [ -z "$reask" ] && [ "$attempt" -eq 1 ] && [ "$st" != park ]; then
      local stale; stale=$(_driver_repair_stale_answers "$wt" "$base" "$trunk" "$ans" "$owes")
      if [ -n "$stale" ]; then
        attempt=2
        driver_say "↩ repair: every fix it named is an earlier round's — asked once more, told why."
        driver_fact_put "$t" repair BRIEF "YOUR LAST ANSWER NAMED FIXES THIS ROUND CANNOT PROVE. This repair started at $(printf '%s' "$base" | cut -c1-12); a pair at or before it is an earlier round's and is not re-proved here:
$stale
Answer again; the commits you made stay.

$DRIVER_BRIEF_PREFACE

${briefs_text:-(no brief came with this repair — it was sent as a healing spawn with no note)}"
        continue
      fi
    fi
    [ -n "$reask" ] && [ "$attempt" -eq 1 ] || break
    attempt=2
    driver_say "↩ repair: $reask while ${failing:+checks are red ($failing)}${lesson_red:+${failing:+ and }the lesson check is red ($lesson_red)}$([ "$unreadable" -eq 1 ] && echo 'the checks could not be read') — asked once more, with the red checks named."
    driver_fact_put "$t" repair BRIEF "YOUR LAST ANSWER WAS NOT A REPAIR. You $reask, and the pull request is still red: ${failing:-${lesson_red:-its checks could not be read — run gh pr checks $pr}}. A repair on a red PR ends in commits that turn those checks green, each with its proof. If a check is red for a reason you cannot fix here (it waits on a person's sign-off, or on something outside this branch), answer with a question that names the check and what it waits on — do not answer unchanged or repaired with nothing committed.

$DRIVER_BRIEF_PREFACE

${briefs_text:-(no brief came with this repair — it was sent as a healing spawn with no note)}"
  done

  if [ -n "$ev_tasks" ]; then
    left=$(_driver_repair_evidence_left "$t" "$wt" "$trunk" "$base" "$plan_rel" "$pr")
    if [ -n "$left" ]; then
      driver_say "✋ repair: the evidence PR #$pr owes is still open after $attempt answer(s) — $left"
      driver_state_set "$t" park_note "the repair left the evidence it owes open ($left); the tasks: $(printf '%s' "$ev_tasks" | tr '\n' ' ')"
      return "$DRIVER_E_REFUSED"
    fi
  fi

  # UNCHANGED is an answer only to a brief: the brief is already met, nothing is red,
  # nothing clashes, and nothing was committed. A red check or a conflict answered
  # "unchanged" is a guess — that is what a park and its question are for.
  if [ "$(jq -r '.status // ""' "$ans")" = unchanged ]; then
    [ -z "$failing" ] && [ -n "$lesson_red" ] && failing="$lesson_red"
    if [ -n "$failing" ] || [ -n "$conflicted" ] || [ "$unreadable" -eq 1 ]; then
      driver_say "✋ repair: answered unchanged while ${failing:+checks are red ($failing)}${conflicted:+ a merge conflicts}$([ "$unreadable" -eq 1 ] && echo ' the checks could not be read'). Unchanged is not an answer to those — park with a question instead."
      driver_state_set "$t" park_note "the repair answered unchanged $attempt time(s) while the PR is red or clashing${failing:+ — red checks: $failing}${conflicted:+ — conflicted: $(printf '%s' "$conflicted" | tr '\n' ' ')}"
      return "$DRIVER_E_REFUSED"
    fi
    if [ "$carried" -gt 0 ] && [ "$(git -C "$wt" rev-parse HEAD)" = "$pre_model" ] && [ -z "$(git -C "$wt" status --porcelain 2>/dev/null)" ]; then
      driver_say "   repair: unchanged — the $carried unpushed commit(s) are the repair; they go to the gates and the push"
      return "$DRIVER_OK"
    fi
    if [ "$(git -C "$wt" rev-parse HEAD)" != "$pre_model" ] || [ -n "$(git -C "$wt" status --porcelain 2>/dev/null)" ]; then
      driver_say "✋ repair: answered unchanged and changed the tree. Either it is a fix, with its proof, or it is unchanged."
      driver_state_set "$t" park_note "the repair answered unchanged and changed the tree"
      return "$DRIVER_E_REFUSED"
    fi
    # AN ADOPTED DRAFT SAID TO BE FINISHED is not taken on the model's word, nor asked of
    # a person: self-check and the review of the whole PR decide, and ship readies it after.
    if [ "$(driver_state_get "$t" repair_brief_source)" = adopt ]; then
      driver_say "   repair: unchanged — $(jq -r '.reason // ""' "$ans") — the adopted draft goes to the gates and a review of the whole PR"
      return "$DRIVER_OK"
    fi
    # NOTHING OWED IS READ, NOT ASKED. #13636 asked the owner to confirm "the head holds
    # develop, GitHub says MERGEABLE, nothing is red": all of it a read the driver makes.
    local owed
    if owed=$(_driver_repair_nothing_owed "$wt" "$trunk" "$pr"); then
      driver_say "   repair: nothing to repair — $(jq -r '.reason // ""' "$ans") — PR #$pr is at this head with $trunk in, MERGEABLE, nothing red, auto-merge armed"
      swarm_gh pr comment "$pr" --repo "$REPO_SLUG" --body "Re-checked by the driver at $(git -C "$wt" rev-parse --short HEAD): nothing to repair. The head contains $trunk, GitHub reads it MERGEABLE, no check on it is red and auto-merge is armed, so nothing was changed. The repair said: $(jq -r '.reason // "no reason given"' "$ans")" >/dev/null 2>&1 || true
      return "$DRIVER_E_NOOP"
    fi
    driver_say "   repair: unchanged, and the driver cannot confirm nothing is owed: $owed"
    # A CALLER'S BRIEF ANSWERED "UNCHANGED" IS A QUESTION, not a ship. The model saying
    # the owner's answer is already met is its judgement; shipped on it, a draft PR
    # would be readied and armed without the change anyone asked for.
    # AND ASKED ONCE PER HEAD. The answer comes back as a new brief on the same PR; a
    # second "unchanged" at the head the person was asked about is that answer acted
    # on, not a new question — or the two would ask each other for ever.
    local cur bsha; cur=$(git -C "$wt" rev-parse HEAD); bsha=$(driver_state_get "$t" repair_brief_sha)
    if [ "$(driver_state_get "$t" unchanged_asked_head)" = "$cur" ] \
       && [ -n "$(driver_state_get "$t" unchanged_asked_brief)" ] && [ "$(driver_state_get "$t" unchanged_asked_brief)" != "$bsha" ]; then
      driver_say "   repair: unchanged — $(jq -r '.reason // ""' "$ans") — a person was asked about this exact head and answered; carrying on"
      return "$DRIVER_OK"
    fi
    driver_state_set "$t" unchanged_asked_head "$cur"; driver_state_set "$t" unchanged_asked_brief "$bsha"
    driver_say "   repair: unchanged — $(jq -r '.reason // ""' "$ans") — asking rather than shipping"
    driver_state_set "$t" park_note "The repair step says this brief needs no change to the PR: $(jq -r '.reason // ""' "$ans"). Is that right — should the PR ship as it is?"
    driver_state_set "$t" park_cause person
    return "$DRIVER_E_QUESTION"
  fi

  # ---- what the tree says ------------------------------------------------------
  _driver_repair_take_listed "$t" "$wt" "$ans" || return "$DRIVER_E_REFUSED"
  # THE DRIVER OWNS THE MERGE. A clash is settled by a real merge of the trunk, made
  # here; the model resolves only the files that merge leaves marked, handed back once.
  local clash=0 handed=0 left owned=0 tsha=""
  { [ -n "$(driver_state_get "$t" repair_conflicted)" ] || [ "$merged" -eq 1 ]; } && clash=1
  while :; do
    if [ "$clash" -eq 1 ] && [ "$handed" -eq 0 ]; then
      left=$(_driver_repair_marked "$t" "$wt")
      if [ -n "$left" ]; then
        _driver_repair_hand_back "$t" "$wt" "$trunk" "$ans" "$left" || return "$?"
        handed=1; continue
      fi
    fi
    driver_git_actions "$t" "$wt" "$ans" repair || return "$DRIVER_E_REFUSED"
    [ "$clash" -eq 1 ] || break
    git -C "$wt" fetch -q origin "+refs/heads/$INTEGRATION_BRANCH:refs/remotes/origin/$INTEGRATION_BRANCH" 2>/dev/null || true
    tsha=$(git -C "$wt" rev-parse -q --verify "$trunk^{commit}" 2>/dev/null)
    owned=0; _driver_repair_own_trunk "$t" "$wt" "$tsha" "$ans" || owned=$?
    [ "$owned" -eq 2 ] && [ "$handed" -eq 0 ] || break
    _driver_repair_hand_back "$t" "$wt" "$trunk" "$ans" "$DRIVER_REPAIR_LEFT" || return "$?"
    handed=1
  done
  if [ -f "$(git -C "$wt" rev-parse --git-path MERGE_HEAD 2>/dev/null)" ] \
     || [ -n "$(git -C "$wt" diff --name-only --diff-filter=U 2>/dev/null)" ]; then
    local um; um=$(git -C "$wt" diff --name-only --diff-filter=U 2>/dev/null | tr '\n' ' ')
    [ -n "$um" ] || um=$(driver_state_get "$t" repair_conflicted | tr '\n' ' ')
    driver_say "✋ repair: the merge is unfinished — unmerged paths or a merge still in progress in $wt${um:+: $um}"
    driver_state_set "$t" park_note "the repair left the merge of $trunk unfinished${um:+ — still conflicting: $um}"
    return "$DRIVER_E_REFUSED"
  fi
  conflicted=$(driver_state_get "$t" repair_conflicted)
  if [ -n "$conflicted" ]; then
    if [ -z "$tsha" ] || ! git -C "$wt" merge-base --is-ancestor "$tsha" HEAD 2>/dev/null; then
      driver_say "✋ repair: the driver merged $trunk${tsha:+ ($(printf '%s' "$tsha" | cut -c1-10))} and the head still lacks it — a machine fault, not the ticket's."
      driver_state_set "$t" park_note "the driver's own merge of $trunk did not leave it an ancestor of the head"
      return "$DRIVER_E_REFUSED"
    fi
    # A resolution that takes the trunk's side everywhere leaves a PR with none of its change.
    local own_before own_after
    own_before=$(git -C "$wt" diff --name-only "$trunk"..."$base" 2>/dev/null)
    own_after=$(git -C "$wt" diff --name-only "$trunk"...HEAD 2>/dev/null)
    if [ -z "$own_after" ] || [ -z "$(printf '%s\n' "$own_after" | grep -xF -f <(printf '%s\n' "$own_before") 2>/dev/null)" ]; then
      driver_say "✋ repair: after the conflict resolution the PR's diff against $trunk ${own_after:+touches none of its own files ($(printf '%s' "$own_before" | tr '\n' ' '))}${own_after:-is empty} — the resolution dropped the PR's own change."
      driver_state_set "$t" park_note "the conflict resolution left PR #$pr without its own change: its diff against $trunk no longer touches $(printf '%s' "$own_before" | tr '\n' ' ')"
      return "$DRIVER_E_REFUSED"
    fi
    # shellcheck disable=SC2086
    if git -C "$wt" grep -nE '^(<<<<<<<|>>>>>>>)( |$)|^=======$' HEAD -- $conflicted >/dev/null 2>&1; then
      driver_say "✋ repair: a conflict marker is still in $(git -C "$wt" grep -lE '^(<<<<<<<|>>>>>>>)( |$)|^=======$' HEAD -- $conflicted 2>/dev/null | sed 's/^HEAD://' | tr '\n' ' ')— committed, so the gates would have read a broken file."
      driver_state_set "$t" park_note "the repair committed conflict markers"
      return "$DRIVER_E_REFUSED"
    fi
  fi
  marked=$(driver_conflict_markers "$wt" "$trunk")
  if [ -n "$marked" ]; then
    driver_say "✋ repair: a conflict marker is committed on $branch in $(printf '%s' "$marked" | tr '\n' ' ')."
    driver_state_set "$t" park_note "the repair committed conflict markers in: $(printf '%s' "$marked" | tr '\n' ' ')"
    return "$DRIVER_E_REFUSED"
  fi
  _driver_repair_put_back "$t" "$wt" "$ans" "$pre_dirty"
  dirty=$(git -C "$wt" status --porcelain 2>/dev/null)
  if [ -n "$dirty" ]; then
    driver_say "✋ repair: uncommitted changes — $(printf '%s' "$dirty" | awk '{print $NF}' | tr '\n' ' '). A change that is not committed is a change the gates never read."
    return "$DRIVER_E_REFUSED"
  fi
  if [ "$lesson_only" -eq 0 ] && [ "$(git -C "$wt" rev-parse HEAD)" = "$(git -C "$wt" rev-parse "$base" 2>/dev/null)" ]; then
    driver_say "✋ repair: the repair committed nothing — the head is still $(printf '%s' "$base" | cut -c1-8)."
    driver_state_set "$t" park_note "the repair step answered '$(jq -r '.status // "?"' "$ans")' and committed nothing, $attempt time(s)${failing:+ — red checks: $failing}"
    return "$DRIVER_E_REFUSED"
  fi

  # Before any proof or gate reads it: an install behind its lockfile is relinked here,
  # not found later as a red the repair is blamed for.
  driver_relink_if_behind "$MAIN_REPO" "$wt" || true
  n=$(jq -r '[.fixes[]?] | length' "$ans" 2>/dev/null)
  i=0
  local own_fixes=0 earlier_fixes=0 kind
  while [ "$i" -lt "${n:-0}" ]; do
    proof=$(jq -r --argjson i "$i" '.fixes[$i].proof // ""' "$ans")
    bid=$(jq -r --argjson i "$i" '.fixes[$i].what // "a fix"' "$ans")
    tcmd=$(jq -r --argjson i "$i" '.fixes[$i].command // ""' "$ans")
    i=$((i+1))
    if [ "$proof" = test ]; then
      tfile=$(jq -r --argjson i "$((i-1))" '.fixes[$i].test.file // ""' "$ans")
      tsha=$(jq -r  --argjson i "$((i-1))" '.fixes[$i].testCommit // ""' "$ans")
      isha=$(jq -r  --argjson i "$((i-1))" '.fixes[$i].implCommit // ""' "$ans")
      # THIS REPAIR'S OWN COMMITS. A test and a fix the PR already carried prove the
      # build, not this repair: only a fix after where the repair started is proved here.
      # One the branch carried from before is dropped with a note; any other is refused.
      kind=$(_driver_repair_fix_kind "$wt" "$base" "$trunk" "$isha")
      case "$kind" in
        earlier)
          driver_say "   repair '$bid' — $(printf '%s' "$isha" | cut -c1-10) is on the branch from before this repair started ($(printf '%s' "$base" | cut -c1-8)): proved in an earlier round, not re-proved"
          earlier_fixes=$((earlier_fixes+1)); continue ;;
        foreign)
          driver_say "✋ repair '$bid': ${isha:-no commit} is not a commit this repair made (it started at $(printf '%s' "$base" | cut -c1-8))."
          driver_state_set "$t" park_note "a repair fix named a commit that is not this repair's own"
          return "$DRIVER_E_REFUSED" ;;
      esac
      own_fixes=$((own_fixes+1))
      why=""; prc=0
      why=$(driver_prove_red_green "$wt" "$tfile" "$tsha" "$isha" "$tcmd") || prc=$?
      case "$prc" in
        0) driver_say "   repair '$bid' — $why" ;;
        4) driver_say "✋ repair '$bid' — $why"; return "$DRIVER_E_TIMEOUT" ;;
        8) driver_say "🛑 repair '$bid' — $why. Back on the queue, not parked."
           driver_state_set "$t" park_note "$why"
           return "$DRIVER_E_BUSY" ;;
        9) driver_say "✋ repair '$bid' — $why"
           driver_state_set "$t" park_note "a repair fix's test was never run: $why"
           return "$DRIVER_E_REFUSED" ;;
        *) driver_say "✋ repair '$bid' — $why"
           driver_state_set "$t" park_note "a repair fix is not proved red-then-green by its own test: $why"
           return "$DRIVER_E_REFUSED" ;;
      esac
    elif driver_gates_local_only && ! driver_cmd_local "$tcmd"; then
      # A ratchet, a check script or a test run named as the gate is CI's under localOnly.
      own_fixes=$((own_fixes+1))
      driver_say "   repair '$bid' — $tcmd is not in gates.local, so it is not run here (gates.localOnly): CI runs it on the push"
    else
      grc=0
      ( cd "$wt" && driver_bounded "$DRIVER_CMD_TIMEOUT" "$tcmd" ) > "$d/steps/repair-gate-$i.out" 2>&1 || grc=$?
      if [ "$grc" -eq 124 ]; then
        driver_say "✋ repair '$bid': $tcmd ran out of time (over ${DRIVER_CMD_TIMEOUT}s)."
        return "$DRIVER_E_TIMEOUT"
      elif [ "$grc" -ne 0 ]; then
        driver_say "✋ repair '$bid': its gate '$tcmd' still exits $grc at the head — $(tail -3 "$d/steps/repair-gate-$i.out" | tr '\n' ' ')"
        driver_state_set "$t" park_note "a repair fix's gate '$tcmd' is still red at the head"
        return "$DRIVER_E_REFUSED"
      fi
      own_fixes=$((own_fixes+1))
      driver_say "   repair '$bid' — $tcmd green at the head (no test can pin it: $(jq -r --argjson i "$((i-1))" '.fixes[$i].noTestBecause // "?"' "$ans"))"
    fi
  done
  if [ "$owes" -eq 1 ] && [ "$own_fixes" -eq 0 ] && [ "$earlier_fixes" -gt 0 ]; then
    driver_say "✋ repair: every fix it named is an earlier round's, from before $(printf '%s' "$base" | cut -c1-8) — nothing this round made answers what is owed."
    driver_state_set "$t" park_note "the repair named only an earlier round's fixes, $attempt time(s), and none of its own"
    return "$DRIVER_E_REFUSED"
  fi
  if [ -n "$lesson_red" ]; then
    rc=0; _driver_repair_write_lesson "$t" "$wt" "$trunk" "$base" "$pr" "$ans" "$row" || rc=$?
    [ "$rc" -eq 0 ] || return "$rc"
  fi
  if [ "$clash" -eq 1 ] && { [ -z "$tsha" ] || ! git -C "$wt" merge-base --is-ancestor "$tsha" HEAD 2>/dev/null; }; then
    driver_say "✋ repair: the head lacks $trunk after the driver's own merge — it is not pushed as a settled clash."
    driver_state_set "$t" park_note "the driver's own merge of $trunk did not leave it an ancestor of the head"
    return "$DRIVER_E_REFUSED"
  fi
  driver_state_set "$t" repair_conflicted ""
  driver_say "   repair: $(jq -r '.cause // ""' "$ans") — $own_fixes fix(es), each proved${earlier_fixes:+$([ "$earlier_fixes" -gt 0 ] && echo ", $earlier_fixes from an earlier round noted")}${lesson_red:+, and the lesson written}"
  return "$DRIVER_OK"
}
