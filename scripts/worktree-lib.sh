#!/usr/bin/env bash
# worktree-lib.sh — sourced by the worktree sweeper and the cache pass.
#   wt_real <path> · wt_cwds_load [--exclude-self] · wt_occupant <real-wt> · wt_run_holder <real-wt> · wt_live_runs · wt_can_see_processes · wt_cfg <cfg> <jq-path>

wt_real() { (cd "$1" 2>/dev/null && pwd -P) || printf '%s' "$1"; }

wt_can_see_processes() { command -v lsof >/dev/null 2>&1; }

WT_CWDS=""
WT_SELF=""
wt_cwds_load() { # [--exclude-self] — removal must never exclude the caller: a session sitting in a worktree is using it
  WT_CWDS=$(cd / && lsof -a -d cwd -Fpn 2>/dev/null | awk '/^p/{p=substr($0,2)} /^n/{print p "\t" substr($0,2)}')
  WT_SELF=""
  [ "${1:-}" = --exclude-self ] || return 0
  local p=$$ n=0
  WT_SELF=" $$ "
  while [ "$p" -gt 1 ] 2>/dev/null && [ "$n" -lt 64 ]; do
    p=$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' ')
    [ -n "$p" ] || break
    WT_SELF="$WT_SELF$p "; n=$((n+1))
  done
}

wt_occupant() { # <real-wt>
  printf '%s\n' "$WT_CWDS" | awk -F'\t' -v root="$1/" -v self="$WT_SELF" '
    index(self, " " $1 " ") { next }
    index($2 "/", root) == 1 { print $1; found = 1; exit }
    END { exit !found }'
}

# wt_run_holder <real-wt> — the id of a live run whose record names this tree (its
# claim's worktree or the checkout it was spawned in); 1 when none does. Live: no
# .ended beside the record and its pid answers. A run record is the one holder lsof
# cannot see between two commands, and the one a branch name never carries.
wt_run_holder() {
  local runs="${RUNS_DIR:-${STATE_DIR:+$STATE_DIR/runs}}" f id pid w
  [ -n "$runs" ] && [ -d "$runs" ] || return 1
  for f in "$runs"/*.json; do
    [ -f "$f" ] || continue
    id=${f##*/}; id=${id%.json}
    [ -e "$runs/$id.ended" ] && continue
    pid=$(jq -r '.pid // .child_pid // empty' "$f" 2>/dev/null)
    [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null || continue
    while IFS= read -r w; do
      [ -n "$w" ] || continue
      case "$(wt_real "$w")/" in "$1"/*) printf '%s' "$id"; return 0 ;; esac
    done <<EOS
$(cat "$runs/$id.worktrees" 2>/dev/null)
$(jq -r '.spawn_root // empty' "$f" 2>/dev/null)
EOS
  done
  return 1
}

# wt_live_runs — the record of every live run on this host, one path a line: the
# same liveness wt_run_holder reads (no .ended beside it, its pid answers).
wt_live_runs() {
  local runs="${RUNS_DIR:-${STATE_DIR:+$STATE_DIR/runs}}" f pid
  [ -n "$runs" ] && [ -d "$runs" ] || return 0
  for f in "$runs"/*.json; do
    [ -f "$f" ] && [ ! -e "${f%.json}.ended" ] || continue
    pid=$(jq -r '.pid // .child_pid // empty' "$f" 2>/dev/null)
    [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null && printf '%s\n' "$f"
  done
  return 0
}

wt_cfg() { # <cfg-file> <jq path>
  [ -f "$1" ] || return 0
  jq -r "$2 // empty | if type == \"array\" then .[] else . end" "$1" 2>/dev/null
}

# wt_recent <dir> <min> [<name>...] — something in it changed in the last <min> minutes, folders
# called <name> left out. A find that errors counts as recent: an empty answer from a failed
# filter is not proof of idleness.
wt_recent() {
  local d="$1" m="$2" out n; shift 2
  local skip=()
  for n in "$@"; do skip+=(-name "$n" -prune -o); done
  out=$(find "$d" ${skip[@]+"${skip[@]}"} -mmin "-$m" -print -quit 2>/dev/null) || return 0
  [ -n "$out" ]
}

wt_nested() { case "$1/" in "$2"/*) return 0 ;; esac; case "$2/" in "$1"/*) return 0 ;; esac; return 1; }   # <a> <b> — one is the other or holds it

wt_ticket_of() { printf '%s' "$1" | sed -n 's/^[A-Za-z_]*-\{0,1\}\([0-9][0-9]*\).*/\1/p'; }

# Claims, every host's: origin's refs/claims/* and `claim-lock.sh list --json` (its worktree,
# branch and ticket). wt_claims_load <repo> fails, and WT_CLAIMS_OK stays 0, when either
# cannot be read; a caller that cannot read them deletes nothing.
# A read is exported for the child passes it starts and reused by them for WT_CLAIMS_TTL (120) seconds.
# Seams: WT_CLAIM_LIST (an executable printing the list JSON), WT_CLAIM_REFS (one printing ls-remote lines).
WT_CLAIMS_OK=${WT_CLAIMS_OK:-0} WT_CLAIMS_FOR=${WT_CLAIMS_FOR:-} WT_CLAIMS_AT=${WT_CLAIMS_AT:-0}
WT_CLAIM_ROWS=${WT_CLAIM_ROWS:-} WT_CLAIM_NUMS=${WT_CLAIM_NUMS:- }
wt_claims_load() { # <repo>
  local repo="$1" here refs list now
  here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  now=$(date +%s)
  if [ "$WT_CLAIMS_OK" = 1 ] && [ -n "$repo" ] && [ "$WT_CLAIMS_FOR" = "$(wt_real "$repo")" ] \
     && [ $(( now - WT_CLAIMS_AT )) -lt "${WT_CLAIMS_TTL:-120}" ] 2>/dev/null; then return 0; fi
  WT_CLAIMS_OK=0 WT_CLAIMS_FOR="" WT_CLAIM_ROWS="" WT_CLAIM_NUMS=" "
  export WT_CLAIMS_OK
  [ -n "$repo" ] && [ -d "$repo" ] || return 1
  if [ -n "${WT_CLAIM_REFS:-}" ]; then refs=$("$WT_CLAIM_REFS" "$repo" 2>/dev/null) || return 1
  else refs=$(cd / && perl -e 'alarm shift; exec @ARGV' 30 git -C "$repo" ls-remote origin 'refs/claims/*' 2>/dev/null) || return 1; fi
  if [ -n "${WT_CLAIM_LIST:-}" ]; then list=$("$WT_CLAIM_LIST" "$repo" 2>/dev/null) || return 1
  else list=$(cd "$repo" && HARNESS_MAIN_REPO="$repo" perl -e 'alarm shift; exec @ARGV' 60 bash "$here/claim-lock.sh" list --json 2>/dev/null) || return 1; fi
  printf '%s' "$list" | jq -e 'type == "array"' >/dev/null 2>&1 || return 1
  WT_CLAIM_ROWS=$(printf '%s' "$list" | jq -r '.[] | [(.issue // "" | tostring), (.worktree // ""), (.branch // ""), (.host // "")] | @tsv' 2>/dev/null) || return 1
  WT_CLAIM_NUMS=" $(printf '%s\n' "$refs" | sed -n 's#.*refs/claims/\([0-9][0-9]*\)$#\1#p' | tr '\n' ' ')$(printf '%s\n' "$WT_CLAIM_ROWS" | cut -f1 | tr '\n' ' ')"
  WT_CLAIMS_FOR=$(wt_real "$repo") WT_CLAIMS_AT=$now WT_CLAIMS_OK=1
  export WT_CLAIMS_OK WT_CLAIMS_FOR WT_CLAIMS_AT WT_CLAIM_ROWS WT_CLAIM_NUMS
}

wt_repo_of() { # <checkout> — the clone it belongs to (a bare clone's dir, or the dir holding .git)
  local common
  common=$(git -C "$1" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || return 1
  common=$(wt_real "$common")
  if [ "${common##*/}" = .git ]; then printf '%s' "${common%/.git}"; else printf '%s' "$common"; fi
}

# wt_claim_holder <worktree> — prints the claim that holds it and returns 0; 1 when none does;
# 2 when the claims for its repo could not be read. Loads them for the tree's repo when not loaded.
wt_claim_holder() {
  local wt="$1" real br repo n src issue cw cb host lock
  real=$(wt_real "$wt")
  repo=$(wt_repo_of "$real") || return 2
  wt_claims_load "$repo" || return 2
  br=$(git -C "$real" symbolic-ref --short -q HEAD 2>/dev/null)
  while IFS=$'\t' read -r issue cw cb host; do
    [ -n "$issue" ] || continue
    [ -n "$cw" ] && wt_nested "$(wt_real "$cw")" "$real" && { printf 'claim #%s (its worktree, on %s)' "$issue" "${host:-?}"; return 0; }
    [ -n "$br" ] && [ "$cb" = "$br" ] && { printf 'claim #%s (its branch %s, on %s)' "$issue" "$br" "${host:-?}"; return 0; }
  done <<<"$WT_CLAIM_ROWS"
  for src in "${real##*/}" "$br"; do
    n=$(wt_ticket_of "$src"); [ -n "$n" ] || continue
    case "$WT_CLAIM_NUMS" in *" $n "*) printf 'claim #%s' "$n"; return 0 ;; esac
    for lock in "${STATE_DIR:-/nonexistent}/claims/$n.lock" "${STATE_DIR:-/nonexistent}/claims/#$n.lock"; do
      [ -d "$lock" ] && { printf 'claim #%s (lockfile)' "$n"; return 0; }
    done
  done
  return 1
}
