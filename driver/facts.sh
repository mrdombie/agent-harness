#!/usr/bin/env bash
# facts.sh — filling the briefs' placeholders, and refusing when one is not filled.
#
#   driver_fact_put <ticket> <slot> <NAME> <value>
#   driver_facts_common <ticket> <slot>
#   driver_substitute <brief> <factdir> <out>   0 = every placeholder filled
#
# WHY THIS EXISTS. briefs/README.md says it plainly — "substitute all of them
# before sending … a placeholder left unfilled reaches the model literally" — and
# nothing did. Measured on the 2026-09-27 trial: the plan prompt was byte-identical
# for two different tickets (md5 a92aa3c6…), and six placeholders reached the model
# as the characters `{{TICKET}}`. Both agents noticed and said so in their notes.
# The run only produced anything at all because it was launched from inside the
# ticket's worktree and they read the number off the branch name.
#
# A MISSING FACT IS A REFUSAL, NOT AN EMPTY STRING. That is the whole design here:
# every gatherer below writes either a real value or a sentence saying there is
# none and why, and `driver_substitute` refuses when a placeholder resolves to
# nothing. An unfilled placeholder that merely looks odd in a prompt is the failure
# that cannot be seen from outside; one that stops the step can only be seen.
#
# The facts live one per file under `<state>/steps/<slot>.facts/<NAME>`, for the
# same reason the prompt does: it is what a person re-reads when the answer looks
# wrong, and a value with newlines in it survives a file where it would not survive
# an argument list.
[ -n "${DRIVER_DIR:-}" ] || . "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/driver-env.sh" || exit 1
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/state.sh" || exit 1

driver_fact_dir() { printf '%s' "$(driver_state_dir "$1")/steps/$2.facts"; }

# AN EMPTY VALUE IS NOT A VALUE. `printf '%s\n' ""` writes one empty line, which a
# reader cannot tell from a fact that happens to be blank — so an empty file is
# written as ZERO bytes and driver_substitute refuses on it. Measured while building
# this: a gatherer whose jq was mis-quoted produced nothing, the brief went out
# reading "- The ticket: " and the step ran happily on it. That is F4 wearing a
# different hat, so the refusal has to cover it.
driver_fact_put() { # <ticket> <slot> <NAME> <value>
  local d; d=$(driver_fact_dir "$1" "$2"); mkdir -p "$d"
  if [ -z "$(printf '%s' "$4" | tr -d '[:space:]')" ]; then
    : > "$d/$3"
  else
    printf '%s\n' "$4" > "$d/$3"
  fi
}

# driver_substitute <brief> <factdir> <out>
#
# It builds the line up rather than rewriting it in place, so a fact whose own text
# contains `{{SOMETHING}}` — a ticket body quoting a brief, which is exactly what
# this ticket's body does — is passed through and never re-scanned. Rewriting in
# place also cannot terminate on a placeholder it has no value for.
driver_substitute() { # <brief> <factdir> <out>
  local brief="$1" dir="$2" out="$3" missfile missing
  missfile="$out.missing"
  awk -v dir="$dir" -v missfile="$missfile" '
    function load(name,   f, line, acc, got) {
      f = dir "/" name; acc = ""; got = 0
      while ((getline line < f) > 0) { acc = (got ? acc "\n" : "") line; got = 1 }
      close(f)
      if (!got) return "\001"
      return acc
    }
    {
      line = $0; built = ""
      while (match(line, /\{\{[A-Z0-9_]+\}\}/)) {
        name = substr(line, RSTART + 2, RLENGTH - 4)
        val = load(name)
        if (val == "\001") { miss[name] = 1; val = "(NOT SUBSTITUTED: " name ")" }
        built = built substr(line, 1, RSTART - 1) val
        line = substr(line, RSTART + RLENGTH)
      }
      print built line
    }
    END { n = 0; for (m in miss) { printf "%s%s", (n++ ? " " : ""), m > missfile } }
  ' "$brief" > "$out"
  missing=$(cat "$missfile" 2>/dev/null); rm -f "$missfile"
  [ -z "$missing" ] || { printf '%s' "$missing"; return 1; }
  return 0
}

# --- the gatherers ------------------------------------------------------------
# Each writes a value or a sentence saying there is none and why. None of them
# names a project: every project-specific value comes from harness.json or from
# the ticket.

_driver_fact_none() { printf '(none — %s)' "$1"; }

# The ticket, verbatim. The premise verdict, the plannable check and the surface
# question are all read off this, so it goes in whole rather than summarised.
driver_fact_ticket() { # <ticket>
  local j
  j=$(swarm_gh issue view "$1" --repo "$REPO_SLUG" --json title,body,labels 2>/dev/null) || j=""
  if [ -z "$j" ]; then _driver_fact_none "#$1 could not be read from $REPO_SLUG"; return 0; fi
  # --arg, not shell-quoted interpolation. Built the other way the closing quote of
  # the jq program was eaten by the shell, jq exited 3 on a compile error, and the
  # brief went out with an empty ticket — which is the very defect this file is for.
  printf '%s\n' "$j" | jq -r --arg n "$1" \
    '"#\($n) \(.title)\n\nLabels: \([.labels[].name] | join(", "))\n\n\(.body // "(the ticket has no body)")"'
}

# The project's own facts file. It IS the answer to "this project": the kit names
# no project, so there is nothing here to compose.
driver_fact_project() {
  if [ -n "${HARNESS_CFG:-}" ] && [ -f "$HARNESS_CFG" ]; then
    jq -S . "$HARNESS_CFG" 2>/dev/null || cat "$HARNESS_CFG"
    # The model reads gates.changed above too, and would run its tests as the checks.
    if driver_gates_local_only; then
      printf '\nLocal checks are gates.local and nothing more (gates.localOnly): run those and the one test file you wrote, never gates.changed or the whole suite. Every test runs once, in CI.\n'
    fi
  else
    _driver_fact_none "this run resolved no harness.json"
  fi
}

# Whatever this project calls the approved design, plus anything on the branch
# filed under the ticket's own number. A design the driver cannot find is said to
# be absent rather than left as the characters {{DESIGN}}.
driver_fact_design() { # <ticket>
  local wt found law out=""
  wt=$(driver_state_get "$1" worktree); [ -n "$wt" ] || wt="$MAIN_REPO"
  law=$(driver_opt law ""); [ -n "$law" ] || law=$(driver_opt design.philosophy "")
  [ -z "$law" ] || out="This project's design law: $law"
  found=$(git -C "$wt" ls-files 2>/dev/null | grep -E "(^|/)$1(/|-|_)" | head -10)
  if [ -n "$found" ]; then
    out="${out:+$out
}Filed under this ticket's number on the branch:
$(printf '%s\n' "$found" | sed 's/^/  /')"
  fi
  [ -n "$out" ] || out="$(_driver_fact_none "nothing on the branch is filed under #$1 and harness.json names no design law. The ticket body stands in for the approved design")"
  printf '%s' "$out"
}

# The programme, by its label. The state file is a consuming-repo convention and
# the brief asks for the BRIEF of it, never the whole append-only file.
# WHERE THE PROGRAMME STATE FILES ARE, for a caller that has no working tree of
# its own. `PROGRAMMES_DIR` is `${REPO_ROOT:+$REPO_ROOT/docs/programmes}` and
# REPO_ROOT is EMPTY for a bare clone or a headless spawn — so on the 2026-09-28
# trial every step was told "this project keeps no programme state directory",
# while the run's own worktree held 29 of them.
#
# The ticket's worktree first, because that is the tree this run is building in and
# the one whose state files are at the branch's version; then the shared checkout.
_driver_programmes_dir() { # [ticket]
  local d
  for d in "${PROGRAMMES_DIR:-}" \
           "$(driver_state_get "${1:-}" worktree 2>/dev/null)/docs/programmes" \
           "${MAIN_REPO:-}/docs/programmes"; do
    case "$d" in ''|/docs/programmes) continue ;; esac
    [ -d "$d" ] && { printf '%s' "$d"; return 0; }
  done
  return 1
}

driver_fact_programme() { # <ticket>
  local labels p dir name brief=""
  labels=$(swarm_gh issue view "$1" --repo "$REPO_SLUG" --json labels -q '[.labels[].name] | join(" ")' 2>/dev/null) || labels=""
  p=""
  for l in $labels; do
    case "$l" in "${SWARM_PROGRAMME_PREFIX:-project:}"*) p="$l"; break ;; esac
  done
  [ -n "$p" ] || { _driver_fact_none "#$1 carries no programme label"; return 0; }
  dir=$(_driver_programmes_dir "$1") || {
    printf 'Programme: %s\n%s\n' "$p" "$(_driver_fact_none "no docs/programmes directory resolves from this run's worktree or from ${MAIN_REPO:-the shared checkout}")"
    return 0; }
  # THE FILE FOR THIS PROGRAMME, not the first one on disk. `head -1` handed every
  # ticket whichever state file sorted first — 29 of them on the trial — so the one
  # fact this brief exists to carry was another programme's.
  name="${p#${SWARM_PROGRAMME_PREFIX:-project:}}"
  # BY WHAT THE FILE SAYS, NOT BY WHAT IT IS CALLED. A filename glob is a proxy and
  # a bad one: measured on the project this was written for, all 29 state files are
  # named for the EPIC (`state-10011.md`) and the programme label lives in the body
  # as `**Label:** \`project:one-desk\``. `state-*one-desk*.md` matches none of
  # them, so the fix would have shipped asserting "none of them is named for this
  # programme" on every ticket — green in a suite that invented the filename it was
  # looking for. The label is the thing; grep for it.
  brief=$(grep -l -- "$p" "$dir"/state-*.md 2>/dev/null | head -1)
  if [ -z "$brief" ]; then
    printf 'Programme: %s\n%s holds %s state file(s) and none of them names this programme, so read the ticket alone rather than another programme\x27s ledger.\n' \
      "$p" "$dir" "$(ls "$dir"/state-*.md 2>/dev/null | wc -l | tr -d ' ')"
    return 0
  fi
  # THE BRIEF, NOT THE LEDGER — when the project has something that prints one.
  # These files are append-only and grow for as long as the programme is open; a
  # step handed the whole thing designs from the programme's history rather than
  # from its own ticket. `programmes.brief` is a project command with {{FILE}} and
  # {{EPIC}} substituted. Absent is normal: the file is named instead.
  local cmd out epic
  cmd=$(driver_opt programmes.brief "")
  if [ -n "$cmd" ]; then
    epic=$(basename "$brief" .md); epic="${epic#state-}"
    cmd=$(printf '%s' "$cmd" | sed -e "s|{{FILE}}|$brief|g" -e "s|{{EPIC}}|$epic|g")
    out=$( ( cd "$(dirname "$dir")/.." 2>/dev/null || cd "${MAIN_REPO:-.}"; driver_bounded 120 "$cmd" ) 2>/dev/null )
    if [ -n "$(printf '%s' "$out" | tr -d '[:space:]')" ]; then
      printf 'Programme: %s (from %s)\n%s\n' "$p" "$brief" "$out"
      return 0
    fi
    printf 'Programme: %s\nIts state file: %s\nThis project names a programmes.brief command and it printed nothing here, so read the brief at the top of that file yourself — the locked decisions, the open questions and what shipped recently — never the whole ledger.\n' \
      "$p" "$brief"
    return 0
  fi
  printf 'Programme: %s\nIts state file: %s\nRead the brief at the top of it — the locked decisions, the open questions and what shipped recently — never the whole ledger.\n' \
    "$p" "$brief"
}

# The premise GATHER, which decides nothing. Same shape the claim flow prints: a
# mechanical path-exists check measured 0 true positives in 25 tickets, so this
# marks each cited path present, moved or absent and the step returns the verdict.
driver_fact_premise() { # <ticket>
  local body cited wt trunk p alt out=""
  wt=$(driver_state_get "$1" worktree); [ -n "$wt" ] || wt="$MAIN_REPO"
  trunk="HEAD"
  git -C "$wt" rev-parse --verify -q "origin/$INTEGRATION_BRANCH" >/dev/null 2>&1 \
    && trunk="origin/$INTEGRATION_BRANCH"
  body=$(swarm_gh issue view "$1" --repo "$REPO_SLUG" --json body -q '.body // ""' 2>/dev/null) || body=""
  cited=$(printf '%s\n' "$body" \
    | grep -oE '[A-Za-z0-9._/-]+/[A-Za-z0-9._/-]+\.[a-z]{2,4}' | sort -u | head -8)
  if [ -z "$cited" ]; then
    printf '%s' "$(_driver_fact_none "the ticket cites no repository path, so judge the premise from its body alone")"
    return 0
  fi
  out="Read against $trunk. This gathers; the verdict is yours."
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    if git -C "$wt" cat-file -e "$trunk:$p" 2>/dev/null; then
      out="$out
  present  $p"
    else
      alt=$(git -C "$wt" ls-tree -r --name-only "$trunk" 2>/dev/null | grep -F "/$(basename "$p")" | head -3)
      if [ -n "$alt" ]; then
        out="$out
  MOVED    $p -> $(printf '%s' "$alt" | tr '\n' ' ')"
      else
        out="$out
  ABSENT   $p (no same-named file anywhere on $trunk)"
      fi
    fi
  done <<EOP
$cited
EOP
  printf '%s' "$out"
}

# What is already in flight on this ticket. A resume is not a fresh build, and the
# plan brief says to read it before writing anything — so it has to be here.
driver_fact_in_flight() { # <ticket>
  local prs branches claims out=""
  prs=$(swarm_gh pr list --repo "$REPO_SLUG" --state open --limit 100 \
          --json number,headRefName,title,body \
          -q ".[] | select((.headRefName | test(\"(^|/)($BRANCH_PREFIX)?$1[-/]\")) or ((.body // \"\") | test(\"#$1\\\\b\"))) | \"  PR #\(.number) \(.headRefName) — \(.title)\"" 2>/dev/null) || prs=""
  branches=$(git ls-remote --heads origin 2>/dev/null \
               | grep -E "refs/heads/($BRANCH_PREFIX)?$1[-/]" | sed 's/^/  branch /') || branches=""
  claims=$(bash "$CL" list 2>/dev/null | sed -n '2,$p' | sed 's/^/  claim /') || claims=""
  [ -z "$prs" ]      || out="Open pull requests naming #$1:
$prs"
  [ -z "$branches" ] || out="${out:+$out
}Remote branches keyed to #$1:
$branches"
  [ -z "$claims" ]   || out="${out:+$out
}Every live claim in the system:
$claims"
  [ -n "$out" ] || out="$(_driver_fact_none "no open pull request, remote branch or live claim names #$1")"
  printf '%s' "$out"
}

# The standard a change is held to, and the screen rules. Both are project facts
# and both are optional: a backend-only project has no screen rules, and saying so
# is different from leaving the placeholder in the prompt.
# THE CODING STANDARD, AND NOTHING STANDS IN FOR IT. This used to fall back to
# `law` — the DESIGN law — so on the 2026-09-28 trial the build step was told this
# project's coding standard is docs/design/design-philosophy.md. The real one is
# docs/CODING_STANDARDS.md. A wrong document cannot be seen from inside a prompt;
# an absence can, which is the whole argument of this file.
driver_fact_standards() {
  local v; v=$(driver_opt standards "")
  [ -n "$v" ] && printf '%s' "$v" \
    || _driver_fact_none "harness.json names no standards document — set 'standards' to this project's coding standard. The design law is not one, and is given separately as the screen rules"
}

driver_fact_surface_rules() {
  local v; v=$(driver_opt design.philosophy ""); [ -n "$v" ] || v=$(driver_opt law "")
  if [ -n "$v" ]; then printf '%s' "$v"
  else _driver_fact_none "harness.json declares no design section, so this project has no screen rules"; fi
}

# driver_fact_screen_steps — the vocabulary this project's renderer understands for
# the setup steps of a screen state: design.renderSteps, inline or a file in the
# tree. The kit names no project, so the steps a renderer can perform are the
# project's to say.
driver_fact_screen_steps() { # <ticket>
  local v wt; v=$(driver_opt design.renderSteps "")
  if [ -z "$v" ]; then
    _driver_fact_none "harness.json names no design.renderSteps, so this project's renderer takes no setup steps — leave screenStates empty"
    return
  fi
  wt=$(driver_state_get "${1:-}" worktree 2>/dev/null); [ -n "$wt" ] || wt="$MAIN_REPO"
  case "$v" in /*|*..*) printf '%s' "$v"; return ;; esac
  if [ -f "$wt/$v" ]; then head -c 16000 "$wt/$v"; else printf '%s' "$v"; fi
}

# THE SCREEN'S POLISH LIST, WHEN ITS TICKET IS FOR A SCREEN THAT HAS ONE — or the
# list itself, when the ticket IS a polish list. Minor findings go on one list per
# screen (scripts/polish-list.sh), never a ticket each, and ride along with the next
# ticket for that screen. The builder records each item it fixed (take); ship
# reserves those for its PR, and the item is ticked only when that PR merges. Read
# once per run and kept, so every step sees the list as the plan saw it.
#   state: polish_fact · polish_items (<list> \t <item>, one a line) · polish_self (1: the ticket is a list)
driver_fact_polish_list() { # <ticket>
  local t="$1" cached labels slugs slug n items out="" kept="" pl lists="" rc why alone=""
  cached=$(driver_state_get "$t" polish_fact)
  [ -n "$cached" ] && { printf '%s' "$cached"; return 0; }
  labels=$(swarm_gh issue view "$t" --repo "$REPO_SLUG" --json labels -q '.labels[].name' 2>/dev/null) || {
    _driver_fact_none "#$t's labels could not be read, so no polish list was looked for"; return 0; }
  pl="$KIT_ROOT/scripts/polish-list.sh"
  if printf '%s\n' "$labels" | grep -qxF -- "$LBL_POLISH_LIST"; then
    driver_state_set "$t" polish_self 1; lists="$t"
  fi
  slugs=$(printf '%s\n' "$labels" | awk -v p="$LBL_SCREEN_PREFIX" 'p != "" && index($0, p) == 1 && length($0) > length(p) { print substr($0, length(p) + 1) }')
  while IFS= read -r slug; do
    [ -n "$slug" ] || continue
    n=$(bash "$pl" for-screen "$slug" 2>/dev/null) || { _driver_fact_none "the polish list for ${LBL_SCREEN_PREFIX}$slug could not be read"; return 0; }
    [ -n "$n" ] && [ "$n" != "$t" ] || continue
    # A list its own run holds lends none (polish-list.sh lends).
    why=$(bash "$pl" lends "$n" "$t" 2>/dev/null); rc=$?
    [ "$rc" -eq 1 ] && { alone="${alone:+$alone; }$why"; continue; }
    [ "$rc" -eq 0 ] || { _driver_fact_none "polish list #$n could not be read"; return 0; }
    lists="$lists $n"
  done <<EOS
$slugs
EOS
  if [ -z "${lists// /}" ]; then
    if [ -n "$alone" ]; then out=$(_driver_fact_none "$alone, so it lends this ticket none")
    elif [ -z "$slugs" ]; then out=$(_driver_fact_none "#$t carries no ${LBL_SCREEN_PREFIX}<slug> label, so no screen's polish list rides along")
    else out=$(_driver_fact_none "no open polish list for $(printf '%s\n' "$slugs" | awk -v p="$LBL_SCREEN_PREFIX" 'NF { printf "%s%s%s", (n++ ? ", " : ""), p, $0 }')"); fi
    driver_state_set "$t" polish_fact "$out"; printf '%s' "$out"; return 0
  fi
  for n in $lists; do
    # Another screen ticket takes at most coordinator.polishListFull of a list's items (--lend).
    items=$(bash "$pl" items "$n" $([ "$n" = "$t" ] || echo --lend) 2>/dev/null) || { _driver_fact_none "polish list #$n could not be read"; return 0; }
    [ -n "$items" ] || continue
    kept="$kept$(printf '%s\n' "$items" | awk -v n="$n" 'NF { print n "\t" $0 }')"$'\n'
    out="${out:+$out

}Polish list #$n$([ "$n" = "$t" ] && echo " (this ticket)") — fix these in this change. Record each one you fixed with
\`bash $pl take $n $t \"<the item, exactly as written>\"\`; it is ticked when the pull request merges, never by you. Each blocks at its grade (none named: Minor) whoever put it there — the review adds every one not recorded as a finding:
$(printf '%s\n' "$items" | sed 's/^/- /')"
  done
  [ -n "$out" ] || out=$(_driver_fact_none "no open polish list for this ticket holds a free item")
  driver_state_set "$t" polish_items "$kept"
  driver_state_set "$t" polish_fact "$out"
  printf '%s' "$out"
}

# THE INDEPENDENT CRITIC'S OPEN FINDINGS on this ticket's pull request, when it has one
# and the critic's latest verdict did not pass (scripts/screen-findings.sh critic). What
# you touch, you fix: each is in scope for this change and blocks at its grade, whether
# or not this change put it there — one PR left narration an earlier critic had flagged,
# and the next critic failed the screen for it.
driver_fact_critic_findings() { # <ticket>
  local t="$1" pr branch out
  pr=$(driver_state_get "$t" pr); [ -n "$pr" ] || pr=$(driver_state_get "$t" critic_pr)
  if [ -z "$pr" ]; then
    branch=$(driver_state_get "$t" branch)
    [ -n "$branch" ] && pr=$(swarm_gh pr list --repo "$REPO_SLUG" --head "$branch" --state open --json number -q '.[0].number // empty' 2>/dev/null)
    # Read once a run: every step asks, and the PR does not change number.
    [ -n "$pr" ] && driver_state_set "$t" critic_pr "$pr"
  fi
  [ -n "$pr" ] || { _driver_fact_none "#$t has no open pull request, so no critic has judged it yet"; return 0; }
  out=$(bash "${DRIVER_SCREEN_FINDINGS:-$KIT_ROOT/scripts/screen-findings.sh}" critic "$pr" 2>/dev/null) \
    || { _driver_fact_none "the independent critic's findings on PR #$pr could not be read"; return 0; }
  [ -n "$out" ] || { _driver_fact_none "the independent critic has no open finding on PR #$pr"; return 0; }
  # Its check listed in release.nonBlockingChecks: a warning until the release, never a fix round.
  if release_check_nonblocking "$(driver_opt review.judge.context "Design critic")"; then
    _driver_fact_none "the independent critic failed PR #$pr on $(printf '%s\n' "$out" | grep -c .) finding(s), and until the release its check warns and does not block (release.nonBlockingChecks), so none is a blocker of this step; the PM reads them with the CI shots at sign-off"
    return 0
  fi
  printf 'The independent design critic failed PR #%s on these. Each is in scope for this change and blocks at its grade, whoever put it there; fix every one (a Minor too), and the critic judges the screen again after CI photographs it:\n' "$pr"
  printf '%s\n' "$out" | awk -F'\t' '{ printf "- %s · %s\n", $1, $3 }'
}

# EVIDENCE OWED IS WORK. Three repairs in one day were told to add shots (a drawer open,
# dark, 390 wide) and pushed without touching the capture plan or `## Evidence routes`:
# they read their job as "turn red checks green", and nothing red said the evidence was
# short. driver_evidence_tasks lists what is owed — the judge's evidence-class findings on
# the PR and the changed UI files no evidence route or capture step renders
# (scripts/evidence-gaps.sh) — one "- " line each, and keeps it as evidence_tasks.
driver_evidence_tasks() { # <ticket> <tree> <trunk> <pr>
  local t="$1" wt="$2" trunk="$3" pr="$4" body base out
  driver_state_set "$t" evidence_warnings ""
  [ -n "$pr" ] || { driver_state_set "$t" evidence_tasks ""; return 0; }
  body=$(mktemp "${TMPDIR:-/tmp}/evidence-body.XXXXXX") || return 0
  swarm_gh pr view "$pr" --repo "$REPO_SLUG" --json body -q .body > "$body" 2>/dev/null || : > "$body"
  base=$(git -C "$wt" merge-base "$trunk" HEAD 2>/dev/null)
  if [ -n "$base" ]; then
    local key; key=$(driver_evidence_plan "$t"); key=$(basename "${key%/plan.json}")
    out=$(bash "${DRIVER_EVIDENCE_GAPS:-$KIT_ROOT/scripts/evidence-gaps.sh}" tasks "$pr" "$wt" "$base" HEAD "$key" "$body" 2>/dev/null)
  else
    out=$(bash "${DRIVER_EVIDENCE_GAPS:-$KIT_ROOT/scripts/evidence-gaps.sh}" tasks "$pr" 2>/dev/null)
  fi
  rm -f "$body"
  if [ -n "$out" ] && _driver_evidence_report_only; then
    _driver_evidence_warn "$t" "$wt" "$pr" "$out"
    out=""
  fi
  driver_state_set "$t" evidence_tasks "$out"
  printf '%s' "$out"
}

# An evidence gap is the critic's and the picture check's finding: while either check is
# in release.nonBlockingChecks it warns, so the gaps are no task, no refusal, no park.
# evidence.gapChecks names those checks (default: review.judge.context and "Approved picture").
_driver_evidence_report_only() {
  local names n
  names=$(jq -r --arg j "$(driver_opt review.judge.context "Design critic")" \
    '(.evidence.gapChecks // [$j, "Approved picture"]) | if type == "array" then .[] else empty end | strings' \
    "${HARNESS_CFG:-/dev/null}" 2>/dev/null)
  while IFS= read -r n; do
    [ -n "$n" ] && release_check_nonblocking "$n" && return 0
  done <<<"$names"
  return 1
}

# _driver_evidence_warn <ticket> <tree> <pr> <tasks> — said in the run log (stderr: the
# caller captures stdout as the task list) and commented on the PR once per head and set.
_driver_evidence_warn() {
  local t="$1" wt="$2" pr="$3" tasks="$4" head key ledger body
  driver_state_set "$t" evidence_warnings "$tasks"
  driver_say "   evidence: warning, not blocking — $(printf '%s\n' "$tasks" | grep -c .) evidence gap(s) on PR #$pr are report-only until the release (release.nonBlockingChecks), so no repair task:" >&2
  printf '%s\n' "$tasks" | sed 's/^/     /' >&2
  head=$(git -C "$wt" rev-parse HEAD 2>/dev/null | cut -c1-9)
  key="$pr	${head:-?}	$(printf '%s' "$tasks" | cksum | cut -d' ' -f1)"
  ledger="${DRIVER_EVIDENCE_WARN_LEDGER:-${STATE_DIR:-${TMPDIR:-/tmp}}/swarm/evidence-warnings.tsv}"
  grep -qxF -- "$key" "$ledger" 2>/dev/null && return 0
  body="**Warning, not blocking — report-only until the release.** The evidence this pull request is missing, at \`${head:-?}\`:
$tasks

Until the release, the checks that find evidence gaps report but do not block (\`release.nonBlockingChecks\` in harness.json), so no repair is sent for them. The PM reads them with the CI shots at sign-off."
  if swarm_gh api "repos/$REPO_SLUG/issues/$pr/comments" -X POST -f body="$body" >/dev/null 2>&1; then
    mkdir -p "$(dirname "$ledger")" 2>/dev/null
    printf '%s\n' "$key" >> "$ledger"
  fi
  return 0
}

# driver_fact_evidence_tasks <ticket> — the tasks, said as edits to the capture plan.
driver_fact_evidence_tasks() { # <ticket>
  local t="$1" tasks plan pr wt trunk
  tasks=$(driver_state_get "$t" evidence_tasks)
  if [ -z "$tasks" ] && [ "$(driver_state_get "$t" mode)" != repair ]; then
    pr=$(driver_state_get "$t" pr); [ -n "$pr" ] || pr=$(driver_state_get "$t" critic_pr)
    wt=$(driver_state_get "$t" worktree)
    if [ -n "$pr" ] && [ -n "$wt" ] && [ -d "$wt" ]; then
      trunk="origin/$INTEGRATION_BRANCH"; git -C "$wt" rev-parse --verify -q "$trunk" >/dev/null 2>&1 || trunk="$INTEGRATION_BRANCH"
      tasks=$(driver_evidence_tasks "$t" "$wt" "$trunk" "$pr")
    fi
  fi
  if [ -z "$tasks" ] && [ -n "$(driver_state_get "$t" evidence_warnings)" ]; then
    _driver_fact_none "the evidence gaps on this pull request are report-only until the release (release.nonBlockingChecks), so none is a task of this step; the PM reads them with the CI shots at sign-off"; return 0
  fi
  [ -n "$tasks" ] || { _driver_fact_none "no evidence is owed: the critic names no missing shot and every changed screen file is on an evidence route"; return 0; }
  plan=$(driver_evidence_plan "$t")
  printf 'This pull request owes evidence. Each line below is a task, and its answer is an edit to the capture plan `%s` — a fix that only changes code leaves it open, and the driver refuses a repair that leaves it open:
%s

' "$plan" "$tasks"
  printf 'How: the plan is {"shots":[{"name","route","viewport":"laptop"|"phone","theme":"light"|"dark","setup":[step sentences]}]}. A plan the PR adds or edits REPLACES the `## Evidence routes` list when CI photographs, so keep every shot it already owes and add the missing ones: a state that only shows once opened (a drawer, a dialog, a menu) is a shot whose `setup` opens it, at laptop and phone, light and dark; a missing theme or width is a shot at it. Setup steps use the project'"'"'s step sentences (the screen steps you were given). Commit the plan; report it as a fix with proof "gate" and command `python3 -I %s check-plan %s`. The driver copies the plan'"'"'s routes into the PR body'"'"'s `## Evidence routes` when it ships; you do not edit the body.
' "$KIT_ROOT/scripts/evidence-gaps.py" "$plan"
}

# driver_facts_common <ticket> <slot> — the ten every step may ask for. Cheap ones
# are always written; the expensive reads are the two gh calls, and they are the
# same two the step would make anyway. The polish list is read once a run.
driver_facts_common() { # <ticket> <slot>
  local t="$1" s="$2"
  driver_fact_put "$t" "$s" TICKET          "$(driver_fact_ticket "$t")"
  driver_fact_put "$t" "$s" PROJECT_FACTS   "$(driver_fact_project)"
  driver_fact_put "$t" "$s" DESIGN          "$(driver_fact_design "$t")"
  driver_fact_put "$t" "$s" PROGRAMME_BRIEF "$(driver_fact_programme "$t")"
  driver_fact_put "$t" "$s" PREMISE_REPORT  "$(driver_fact_premise "$t")"
  driver_fact_put "$t" "$s" IN_FLIGHT       "$(driver_fact_in_flight "$t")"
  driver_fact_put "$t" "$s" STANDARDS       "$(driver_fact_standards)"
  driver_fact_put "$t" "$s" SURFACE_RULES   "$(driver_fact_surface_rules)"
  driver_fact_put "$t" "$s" SCREEN_STEPS    "$(driver_fact_screen_steps "$t")"
  driver_fact_put "$t" "$s" POLISH_LIST     "$(driver_fact_polish_list "$t")"
  driver_fact_put "$t" "$s" CRITIC_FINDINGS "$(driver_fact_critic_findings "$t")"
  case "$s" in repair|fix) driver_fact_put "$t" "$s" EVIDENCE_TASKS "$(driver_fact_evidence_tasks "$t")" ;; esac
  case "$s" in build*|fix|repair) driver_fact_put "$t" "$s" PROOF_LIMITS "$(driver_fact_proof_limits)" ;; esac
}

# driver_fact_proof_limits — what cannot prove a change here. A proof tree runs no app
# server, so an e2e browser spec is refused on both sides unless the project's own e2e
# harness brings the app up (`tests.e2eProofs: true`).
# driver_auto_proof_kinds — the autoProofs kinds proof.autoAccept turns on, space-separated.
driver_auto_proof_kinds() {
  local k on=""
  for k in docs-only comment-only wording-only test-only; do
    python3 -I "$KIT_ROOT/scripts/proof-class.py" enabled --kind "$k" --cfg "${HARNESS_CFG:-}" 2>/dev/null && on="$on $k"
  done
  printf '%s' "${on# }"
}

driver_fact_proof_limits() {
  if [ "$(driver_opt tests.e2eProofs false)" = true ]; then
    printf 'This project'"'"'s e2e harness brings the app up, so an e2e browser spec can prove a change here, as can a unit or DOM test.'
  else
    printf 'An e2e browser spec (Playwright, e2e/**/*.spec.ts) cannot prove a change here: a proof tree runs no app server, so every page load is refused on both sides. Prove it with a unit or DOM test (vitest, a *.test.ts or *.dom.test.tsx) that goes red without the change; the e2e spec can still ship as extra coverage.'
  fi
  local on; on=$(driver_auto_proof_kinds)
  if [ -n "$on" ]; then
    printf ' A fix no red/green pair can show whose one commit is only %s needs no PM answer and is never a question or a deferral: it goes in autoProofs with the kind and the commit, which must touch the file the finding names. The driver reads that commit'"'"'s diff and refuses a claim it does not bear out. test-only also names testFile, command and a break: a literal find/replace in the code the test pins, never a test file, that the command fails on; the driver plants it, then restores the code (proof.autoAccept).' "$on"
  else
    printf ' proof.autoAccept is off here: a fix no red/green pair can show needs a PM answer (pmProofs).'
  fi
}
