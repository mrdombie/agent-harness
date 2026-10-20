#!/usr/bin/env bash
# sweep-orphan-worktrees.sh — remove the worktrees nothing needs, clean the caches of the rest.
#   sweep-orphan-worktrees.sh [--apply] [--caches-only]
# Considers every worktree under the worktree root and the temp dirs, whatever its name, whichever
# clone of the project registered it.
# Never removed with: a claim on a ticket its folder or branch names, a live run's record naming it,
# a process inside, uncommitted
# changes, or a commit pushed nowhere (a commit that is the head of a merged PR counts as pushed).
# Otherwise removed when its PR has merged or its ticket is closed (with no open PR), and any other
# one once untouched for SWEEP_WORKTREE_HOURS (24).
# Then `harness-tools-*` script snapshots under the same roots: removed when not the current one,
# older than SWEEP_TOOLS_HOURS (24), and no process has a file or its cwd inside.
# Every worktree it keeps gets the cache pass (worktree-cache.sh, idle `build.cacheIdleMin`, 30).
set -uo pipefail

APPLY=0 CACHES_ONLY=0
for arg in "$@"; do
  case "$arg" in
    --apply) APPLY=1 ;;
    --caches-only) CACHES_ONLY=1 ;;
    *) echo "unknown argument: $arg (--apply, --caches-only)" >&2; exit 2 ;;
  esac
done

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/toolkit-env.sh" || exit 1
. "$HERE/worktree-lib.sh"

THRESHOLD_HOURS="${SWEEP_WORKTREE_HOURS:-24}"
TOOLS_HOURS="${SWEEP_TOOLS_HOURS:-24}"
IDLE_MIN="${SWEEP_CACHE_IDLE_MIN:-$(toolkit_cfg build.cacheIdleMin 2>/dev/null || echo 30)}"
CLAIMS_DIR="$STATE_DIR/claims"
GH="${SWEEP_GH:-gh}"

ROOTS=()
if [ -n "${SWEEP_WORKTREE_ROOTS:-}" ]; then
  IFS=: read -r -a ROOTS <<<"$SWEEP_WORKTREE_ROOTS"
else
  r=$(toolkit_worktree_root 2>/dev/null) && ROOTS+=("$r")
  ROOTS+=("${TMPDIR:-/tmp}" /private/tmp /tmp)
fi
REAL_ROOTS=()
for r in "${ROOTS[@]}"; do [ -d "$r" ] && REAL_ROOTS+=("$(wt_real "$r")"); done
under_root() { local r; for r in "${REAL_ROOTS[@]}"; do case "$1/" in "$r"/*) return 0 ;; esac; done; return 1; }

origin_of() { git -C "$1" remote get-url origin 2>/dev/null; }
MAIN_ORIGIN=$(origin_of "$MAIN_REPO")
MAIN_COMMON=$(git -C "$MAIN_REPO" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)

# The main checkout's own registered worktrees, plus any folder directly under a root that is a
# worktree of another clone (a second clone's worktrees share the root and were never looked at).
# A main checkout (its .git is a directory) is never a candidate.
WORKTREES=() SEEN=" "
add_candidate() { local real; real=$(wt_real "$1")
  case "$SEEN" in *" $real "*) return ;; esac
  SEEN="$SEEN$real "; WORKTREES+=("$1"); }
while IFS= read -r wt; do
  [ -n "$wt" ] && [ -d "$wt" ] || continue
  under_root "$(wt_real "$wt")" && add_candidate "$wt"
done < <(git -C "$MAIN_REPO" worktree list --porcelain 2>/dev/null | sed -n 's/^worktree //p' | tail -n +2 | sort -u)
for r in "${REAL_ROOTS[@]}"; do
  for d in "$r"/*; do [ -f "$d/.git" ] && add_candidate "$d"; done
done
[ ${#WORKTREES[@]} -gt 0 ] || echo "Sweep: no worktrees under ${REAL_ROOTS[*]:-no root}"

cache_pass() { # <worktree>...
  [ $# -gt 0 ] || return 0
  if [ "$APPLY" = 1 ]; then bash "$HERE/worktree-cache.sh" clean --idle-min "$IDLE_MIN" "$@"
  else bash "$HERE/worktree-cache.sh" clean --idle-min "$IDLE_MIN" --dry-run "$@"; fi
}

if [ "$CACHES_ONLY" = 1 ]; then
  cache_pass ${WORKTREES[@]+"${WORKTREES[@]}"}
  exit 0
fi

mtime_of() {
  if stat --version >/dev/null 2>&1; then stat -c %Y "$1" 2>/dev/null; else stat -f %m "$1" 2>/dev/null; fi
}
now=$(date -u +%s)
SEE=1; wt_can_see_processes && wt_cwds_load || SEE=0

# ---- worktrees -----------------------------------------------------------------
CLAIMS_OK=1
CLAIM_REFS=$(perl -e 'alarm shift; exec @ARGV' 20 git -C "$MAIN_REPO" ls-remote origin 'refs/claims/*' 2>/dev/null) || CLAIMS_OK=0

ticket_of() { printf '%s' "$1" | sed -n 's/^[A-Za-z_]*-\{0,1\}\([0-9][0-9]*\).*/\1/p'; }
branch_of() { git -C "$1" symbolic-ref --short -q HEAD 2>/dev/null; }

claim_on() { # <worktree> — echoes what claims it
  local n src form
  for src in "$(basename "$1")" "$(branch_of "$1")"; do
    n=$(ticket_of "$src"); [ -n "$n" ] || continue
    for form in "$n" "#$n"; do
      [ -d "$CLAIMS_DIR/$form.lock" ] && { echo "lockfile $form.lock"; return 0; }
    done
    grep -q "refs/claims/$n\$" <<<"$CLAIM_REFS" && { echo "refs/claims/$n on origin"; return 0; }
  done
  return 1
}

# Every branch's PRs and every named ticket's state, in one query per 40 worktrees.
# FORGE lines: "B<TAB>branch<TAB>state<TAB>number<TAB>headOid" and "T<TAB>number<TAB>state".
# A failed lookup leaves FORGE empty: nothing is fast-tracked, the age rule still applies.
FORGE="" FORGE_OK=1
forge_load() {
  local owner="${REPO_SLUG%%/*}" name="${REPO_SLUG#*/}" q="" i=0 n=0 wt br t out map="" tickets=" "
  flush() {
    [ -n "$q" ] || return 0
    # A partial answer (a number that is no issue) exits non-zero but still prints the data.
    out=$("$GH" api graphql -f query="query { repository(owner: \"$owner\", name: \"$name\") { $q } }" 2>/dev/null)
    q=""; n=0
    printf '%s' "$out" | jq -e '.data.repository' >/dev/null 2>&1 || { FORGE_OK=0; return 0; }
    FORGE="$FORGE$(printf '%s' "$out" | jq -r --arg map "$map" '
      ($map | split("\n") | map(select(length > 0) | split("\t") | {key: .[0], value: .[1]}) | from_entries) as $m
      | .data.repository | to_entries[] | select(.value != null)
      | if (.key | startswith("b")) then ($m[.key] // empty) as $b | .value.nodes[]? | ["B", $b, .state, (.number|tostring), .headRefOid] | @tsv
        else ["T", (.key | ltrimstr("t")), .value.state] | @tsv end' 2>/dev/null)
"
  }
  for wt in "${WORKTREES[@]}"; do
    i=$((i+1))
    br=$(branch_of "$wt")
    if [ -n "$br" ]; then
      # jq writes the branch as a GraphQL string literal: quotes and backslashes escaped.
      q="$q b$i: pullRequests(headRefName: $(printf '%s' "$br" | jq -Rs .), first: 20) { nodes { number state headRefOid } } "
      map="${map}b$i	$br
"
    fi
    for t in $(ticket_of "$(basename "$wt")") $(ticket_of "$br"); do
      case "$tickets" in *" $t "*) continue ;; esac
      tickets="$tickets$t "
      q="$q t$t: issueOrPullRequest(number: $t) { ... on Issue { state } ... on PullRequest { state } } "
    done
    n=$((n+1)); [ "$n" -ge 40 ] && flush
  done
  flush
}

# done_why <worktree> — sets FINISHED to why its work is finished (merged PR / closed ticket), or
# fails; sets MERGED_HEADS to the head commits of the branch's merged PRs. Not run in a subshell.
FINISHED="" MERGED_HEADS=""
done_why() {
  local wt=$1 br rows t st
  FINISHED="" MERGED_HEADS=""
  br=$(branch_of "$wt")
  rows=""
  [ -n "$br" ] && rows=$(printf '%s' "$FORGE" | awk -F'\t' -v b="$br" '$1=="B" && $2==b')
  printf '%s\n' "$rows" | awk -F'\t' '$3=="OPEN"' | grep . >/dev/null && return 1
  MERGED_HEADS=$(printf '%s\n' "$rows" | awk -F'\t' '$3=="MERGED"{print $5}')
  if [ -n "$MERGED_HEADS" ]; then
    FINISHED="PR #$(printf '%s\n' "$rows" | awk -F'\t' '$3=="MERGED"{print $4; exit}') merged"; return 0
  fi
  for t in $(ticket_of "$(basename "$wt")") $(ticket_of "$br"); do
    st=$(printf '%s' "$FORGE" | awk -F'\t' -v n="$t" '$1=="T" && $2==n {print $3; exit}')
    case "$st" in CLOSED|MERGED) FINISHED="ticket #$t closed"; return 0 ;; esac
  done
  return 1
}

# unpushed <worktree> — the number of commits on HEAD that no remote and no merged PR head holds.
unpushed() {
  local wt=$1 c h k
  c=$(git -C "$wt" rev-list --count HEAD --not --remotes 2>/dev/null) || return 1
  # The PR's branch is deleted on merge, so its commits leave every remote; the PR head still holds them.
  for h in $MERGED_HEADS; do
    [ "$c" = 0 ] && break
    git -C "$wt" cat-file -e "$h^{commit}" 2>/dev/null || continue
    k=$(git -C "$wt" rev-list --count HEAD --not --remotes "$h" 2>/dev/null) || continue
    [ "$k" -lt "$c" ] && c=$k
  done
  echo "$c"
}

remove_wt() { # <worktree> <common-dir>
  git --git-dir="$2" worktree remove --force "$1" >/dev/null 2>&1
}

if [ ${#WORKTREES[@]} -gt 0 ] && [ "$CLAIMS_OK" = 1 ]; then
  if command -v "$GH" >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then forge_load; else FORGE_OK=0; fi
fi

threshold=$(( THRESHOLD_HOURS * 3600 ))
removed=0 KEPT=()
keep() { echo "keep    $(basename "$1") — $2"; KEPT+=("$1"); }

for wt in ${WORKTREES[@]+"${WORKTREES[@]}"}; do
  real=$(wt_real "$wt")
  [ "$CLAIMS_OK" = 1 ] || { keep "$wt" "claims could not be read from origin"; continue; }
  common=$(git -C "$wt" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) \
    || { keep "$wt" "unreadable (no readable git dir)"; continue; }
  if [ "$common" != "$MAIN_COMMON" ] && [ "$(origin_of "$wt")" != "$MAIN_ORIGIN" ]; then
    keep "$wt" "a worktree of another repo"; continue
  fi
  if why=$(claim_on "$wt"); then keep "$wt" "live claim ($why)"; continue; fi
  if why=$(wt_run_holder "$real"); then keep "$wt" "a live run holds it ($why)"; continue; fi
  [ "$SEE" = 1 ] || { keep "$wt" "cannot see processes (no lsof)"; continue; }
  if pid=$(wt_occupant "$real"); then keep "$wt" "in use (pid $pid)"; continue; fi
  if ! done_why "$wt"; then
    m=$(mtime_of "$wt"); case "$m" in ''|*[!0-9]*) keep "$wt" "unreadable (cannot stat)"; continue ;; esac
    [ $(( now - m )) -ge "$threshold" ] || { keep "$wt" "younger than ${THRESHOLD_HOURS}h"; continue; }
  fi
  status=$(git -C "$wt" status --porcelain 2>/dev/null) || { keep "$wt" "unreadable (git status failed)"; continue; }
  [ -z "$status" ] || { keep "$wt" "uncommitted changes"; continue; }
  orphans=$(unpushed "$wt") || { keep "$wt" "unreadable (rev-list failed)"; continue; }
  [ "$orphans" = 0 ] || { keep "$wt" "$orphans commit(s) on no remote"; continue; }

  why="${FINISHED:-untouched ${THRESHOLD_HOURS}h}, no claim, nobody inside, clean, fully pushed"
  if [ "$APPLY" = 0 ]; then
    echo "would remove  $(basename "$wt") — $why"
    removed=$((removed+1)); continue
  fi
  if remove_wt "$wt" "$common"; then
    echo "remove  $(basename "$wt") — $why"
    removed=$((removed+1))
  else
    keep "$wt" "git worktree remove refused it"
  fi
done

forge_note=""; [ "$FORGE_OK" = 1 ] || forge_note=" (PR and ticket states unreadable: only the age rule applied)"
if [ "$APPLY" = 0 ]; then
  echo "Sweep (dry run): kept=${#KEPT[@]} would-remove=$removed$forge_note — pass --apply to delete"
else
  echo "Sweep complete: kept=${#KEPT[@]} removed=$removed$forge_note"
fi

# ---- harness-tools-* script snapshots ------------------------------------------
# toolkit_tools() extracts scripts/ per integration-branch commit and never removes one.
CURRENT=$(git -C "$MAIN_REPO" rev-parse --verify --quiet "origin/$INTEGRATION_BRANCH^{commit}" 2>/dev/null || true)
TOOLS=()
for r in "${REAL_ROOTS[@]}"; do
  for d in "$r"/harness-tools-*; do [ -d "$d" ] && [ ! -L "$d" ] && TOOLS+=("$d"); done
done
if [ ${#TOOLS[@]} -gt 0 ]; then
  t_removed=0 t_kept=0 t_kb=0
  OPEN_FILES=""
  [ "$SEE" = 1 ] && OPEN_FILES=$(cd / && lsof -Fn 2>/dev/null | sed -n 's/^n//p' | grep '/harness-tools-')
  for d in "${TOOLS[@]}"; do
    real=$(wt_real "$d"); sfx=${d##*/harness-tools-}
    if [ -n "$CURRENT" ] && case "$CURRENT" in "$sfx"*) true ;; *) false ;; esac; then t_kept=$((t_kept+1)); continue; fi
    [ "$SEE" = 1 ] || { t_kept=$((t_kept+1)); continue; }
    m=$(mtime_of "$d"); case "$m" in ''|*[!0-9]*) t_kept=$((t_kept+1)); continue ;; esac
    [ $(( now - m )) -ge $(( TOOLS_HOURS * 3600 )) ] || { t_kept=$((t_kept+1)); continue; }
    if pid=$(wt_occupant "$real") || printf '%s\n' "$OPEN_FILES" | grep -qF -- "$real/"; then
      echo "keep    $(basename "$d") — in use"; t_kept=$((t_kept+1)); continue
    fi
    kb=$(du -sk "$d" 2>/dev/null | cut -f1); t_kb=$(( t_kb + ${kb:-0} ))
    [ "$APPLY" = 1 ] && rm -rf "$d"
    t_removed=$((t_removed+1))
  done
  if [ "$APPLY" = 1 ]; then echo "tools snapshots: removed=$t_removed kept=$t_kept freed=$(( t_kb / 1024 ))MB"
  else echo "tools snapshots (dry run): would-remove=$t_removed kept=$t_kept ($(( t_kb / 1024 ))MB)"; fi
fi

cache_pass ${KEPT[@]+"${KEPT[@]}"}
