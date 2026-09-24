#!/usr/bin/env bash
# toolkit-env.sh — the one place the agent toolkit resolves WHERE things are.
#
#   . "$(git rev-parse --show-toplevel)/scripts/toolkit-env.sh" || exit 1
#
# Sets, for the caller:
#   KIT_ROOT      the plugin's own root — the directory holding scripts/, skills/,
#                 hooks/. Everything the kit ships is addressed from here.
#   STATE_DIR     per-machine state — claims cache, session label, auto-skip.
#                 $HARNESS_STATE_DIR, else stateDir in harness.json
#   REPO_ROOT     the checkout this session runs in (or $HARNESS_REPO_ROOT);
#                 EMPTY for a headless caller that only set HARNESS_MAIN_REPO
#   MAIN_REPO     the git object store every worktree shares: the clone that owns
#                 .git, or the bare directory itself (or $HARNESS_MAIN_REPO)
#   SUPPORT_REPO  the sister-repo clone if one sits beside MAIN_REPO
#                 (or $HARNESS_SISTER_REPO); empty when absent
#   PROGRAMMES_DIR docs/programmes in this checkout — the programme state files
#   CL            scripts/claim-lock.sh
#   toolkit_tools echoes a directory holding scripts/ exactly as on origin/develop,
#                 materialised by `git archive` and keyed by that SHA
#
# WHY: nine skills carried the same fourteen-line block reading a per-machine
# config.json that bootstrap-queue.sh wrote from wherever it was run. The copies
# drifted (some fetched first, some did not; one hard-coded the config path), and
# a config.json is one more file that can name the wrong machine. Everything here
# is derivable from the checkout, so nothing is written down.
#
# Sourced, not executed: on failure it returns 1 (or exits 1 when run directly).
#
# Every HARNESS_* variable has an optional LEGACY alias: a project that pinned an
# older prefix in its fixtures declares `legacyEnvPrefix` in harness.json (or sets
# HARNESS_LEGACY_ENV_PREFIX), and `_hv NAME` reads HARNESS_NAME, else <PREFIX>_NAME.
# The kit itself names no prefix — that is what keeps it project-agnostic.

# Callers normally set KIT_ROOT (a skill's preamble has the plugin root
# substituted in; a consuming repo's shim sets it before sourcing). Sourced bare
# from bash or zsh, derive it from this file's own path — both shells, because
# the agent's Bash tool is whatever the operator's login shell is.
if [ -z "${KIT_ROOT:-${HARNESS_KIT_ROOT:-}}" ]; then
  if [ -n "${BASH_VERSION:-}" ]; then _kit_self="${BASH_SOURCE[0]}"; else eval '_kit_self="${(%):-%x}"'; fi
  KIT_ROOT="$(cd "$(dirname "$_kit_self")/.." && pwd)"; unset _kit_self
else
  KIT_ROOT="${KIT_ROOT:-$HARNESS_KIT_ROOT}"
fi

_kit_legacy="${HARNESS_LEGACY_ENV_PREFIX:-}"
if [ -z "$_kit_legacy" ]; then
  _kit_probe="${HARNESS_CFG_PATH:-$(git rev-parse --show-toplevel 2>/dev/null)/.claude/harness.json}"
  [ -f "$_kit_probe" ] && _kit_legacy=$(jq -r '.legacyEnvPrefix // empty' "$_kit_probe" 2>/dev/null)
  unset _kit_probe
fi
# _hv NAME [LEGACY_SUFFIX] — HARNESS_NAME, else ${legacyEnvPrefix}_${LEGACY_SUFFIX:-NAME}.
# Indirection through eval so the same file sources under bash and zsh.
_hv() {
  local v="HARNESS_$1" out
  eval "out=\"\${$v:-}\""
  if [ -n "$out" ]; then printf '%s' "$out"; return; fi
  [ -n "$_kit_legacy" ] || return 0
  v="${_kit_legacy}_${2:-$1}"; eval "out=\"\${$v:-}\""; printf '%s' "$out"
}

# Per-machine state. The env overrides win; otherwise the config names it (below,
# once the reader exists). No literal default: a second project on the same machine
# must not share this one's claims directory.
STATE_DIR="$(_hv STATE_DIR)"

# The checkout we are in, if any. A scheduled job has none and says so with
# HARNESS_MAIN_REPO instead; everything that needs a working tree checks
# REPO_ROOT is non-empty before using it.
REPO_ROOT="$(_hv REPO_ROOT)"; [ -n "$REPO_ROOT" ] || REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || true)"

# The object store: the env override wins, else the clone that owns the .git of
# wherever we are (a worktree's common dir; the bare dir itself for a bare clone).
if [ -n "$(_hv MAIN_REPO)" ]; then
  MAIN_REPO="$(_hv MAIN_REPO)"
else
  _toolkit_common=$(git -C "${REPO_ROOT:-.}" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)
  case "$_toolkit_common" in
    "")      MAIN_REPO="$REPO_ROOT" ;;
    */.git)  MAIN_REPO="${_toolkit_common%/.git}" ;;
    *)       MAIN_REPO="$_toolkit_common" ;;
  esac
  unset _toolkit_common
fi
if [ -z "$MAIN_REPO" ]; then
  echo "toolkit-env: not inside a checkout of the repo — start the session in one, or set HARNESS_MAIN_REPO." >&2
  return 1 2>/dev/null || exit 1
fi
if ! git -C "$MAIN_REPO" rev-parse --git-dir >/dev/null 2>&1; then
  echo "toolkit-env: no git repo at '$MAIN_REPO' (MAIN_REPO) — is HARNESS_MAIN_REPO pointing at a moved clone?" >&2
  return 1 2>/dev/null || exit 1
fi

PROGRAMMES_DIR="${REPO_ROOT:+$REPO_ROOT/docs/programmes}"

# The project's own facts, in one file, read through one function — so the kit
# can be installed on another repo without editing it (#10167). Env vars still
# win: fixtures pin them (#10067).
HARNESS_CFG="$(_hv CFG_PATH HARNESS_CFG)"; [ -n "$HARNESS_CFG" ] || HARNESS_CFG="${REPO_ROOT:+$REPO_ROOT/.claude/harness.json}"
# No checkout (a scheduled job on the object store alone): read the config out
# of the clone's HEAD instead of refusing — the file is tracked, so the ref has it.
# The object-store clone's HEAD can be far behind the remote (52 commits on
# 2026-09-20, review of PR #10362), so origin's refs are probed first — the
# integration branch before origin/HEAD, which usually names the production
# branch and is behind by design. HARNESS_CFG_REF pins one ref outright.
if [ -z "$HARNESS_CFG" ] || [ ! -f "$HARNESS_CFG" ]; then
  for _ref in ${HARNESS_CFG_REF:-} ${HARNESS_INTEGRATION_BRANCH:+origin/$HARNESS_INTEGRATION_BRANCH} origin/develop origin/HEAD origin/main HEAD; do
    if git -C "$MAIN_REPO" cat-file -e "$_ref:.claude/harness.json" 2>/dev/null; then
      HARNESS_CFG="${TMPDIR:-/tmp}/harness.json.$(git -C "$MAIN_REPO" rev-parse --short "$_ref")"
      [ -s "$HARNESS_CFG" ] || git -C "$MAIN_REPO" show "$_ref:.claude/harness.json" > "$HARNESS_CFG" 2>/dev/null || HARNESS_CFG=""
      break
    fi
  done
  unset _ref
fi

# toolkit_cfg <dotted.key> — echo a value from harness.json. An array joins on
# spaces so `for x in $(toolkit_cfg labels.decision)` reads naturally.
#
# REFUSES rather than guessing. The epic's decision default is explicit: when a
# command needs a project fact the config lacks, refuse with the key name and
# never fall back to this project's value — a silent fallback is how the kit
# would keep working on the origin project and quietly break everywhere else.
toolkit_cfg() {
  local key="${1:?toolkit_cfg: need a key}" val
  if [ -z "$HARNESS_CFG" ] || [ ! -f "$HARNESS_CFG" ]; then
    echo "toolkit-env: no harness.json at '${HARNESS_CFG:-<unset>}' — every project the kit runs on needs one." >&2
    return 1
  fi
  val=$(jq -r --arg k "$key" '
          getpath($k | split("."))
          | if type == "array" then join(" ") elif . == null then empty else . end
        ' "$HARNESS_CFG" 2>/dev/null)
  if [ -z "$val" ]; then
    echo "toolkit-env: harness.json has no '$key'." >&2
    return 1
  fi
  printf '%s\n' "$val"
}

SUPPORT_REPO="$(_hv SISTER_REPO SUPPORT_REPO)"
[ -n "$SUPPORT_REPO" ] || SUPPORT_REPO="$(dirname "$MAIN_REPO")/$(toolkit_cfg sisterRepos 2>/dev/null | awk '{print $1}')"
git -C "$SUPPORT_REPO" rev-parse --git-dir >/dev/null 2>&1 || SUPPORT_REPO=""

CL="$KIT_ROOT/scripts/claim-lock.sh"

# The project facts every command reads. No fallbacks: a missing key is a
# refusal that names the key (toolkit_cfg prints it), never this project's value.
# One jq pass emits every fact as a shell assignment: fifteen separate reads cost
# ~370 ms per source and every skill sources this (review of PR #10362). A missing
# key still refuses by name — the pass lists what it could not find.
_toolkit_facts=$(jq -r '
  def need(var; key): (getpath(key | split("."))) as $v
    | if $v == null then "MISSING \(key)" else "\(var)=\($v | if type == "array" then join(" ") else . end | @sh)" end;
  [ need("REPO_SLUG"; "repo"), need("INTEGRATION_BRANCH"; "integrationBranch"), need("BRANCH_PREFIX"; "branchPrefix"),
    need("LBL_DRAFTING"; "labels.drafting"), need("LBL_READY"; "labels.ready"), need("LBL_CLAIMED"; "labels.claimed"),
    need("LBL_IN_REVIEW"; "labels.inReview"), need("LBL_GATED"; "labels.gated"), need("LBL_PARTIAL"; "labels.partial"),
    need("LBL_NEEDS_HUMAN"; "labels.needsHuman"), need("LBL_PM_DECISION"; "labels.pmDecision"), need("LBL_PM_TRACK"; "labels.pmTrack"),
    need("LBL_BLOCKED"; "labels.blocked"), need("LBL_EXTERNAL_BLOCKED"; "labels.externalBlocked"), need("LBL_PARKED"; "labels.parked"),
    need("HOLD_LABEL"; "labels.hold"), need("DECISION_LABELS"; "labels.decision"),
    "DESIGN_KIT=\(.design.kit // "" | @sh)", "CFG_STATE_DIR=\(.stateDir // "" | @sh)" ] | .[]
' "$HARNESS_CFG" 2>/dev/null) || {
  if [ -z "$HARNESS_CFG" ]; then
    echo "toolkit-env: no .claude/harness.json in this checkout, and none on origin/develop, origin/HEAD, origin/main or HEAD of '$MAIN_REPO' — every project the kit runs on needs one (set HARNESS_CFG_PATH to point at it)." >&2
  else
    echo "toolkit-env: cannot read '$HARNESS_CFG' as JSON." >&2
  fi
  return 1 2>/dev/null || exit 1; }
case "$_toolkit_facts" in *MISSING*)
  echo "toolkit-env: harness.json lacks: $(printf '%s\n' "$_toolkit_facts" | awk '/^MISSING/{print $2}' | tr '\n' ' ')" >&2
  return 1 2>/dev/null || exit 1 ;;
esac
eval "$_toolkit_facts"; unset _toolkit_facts
# The status-label namespace ("status:" here), for jq filters that pick the status column.
STATUS_PREFIX="${LBL_READY%%:*}:"
[ -n "$STATE_DIR" ] || STATE_DIR="${CFG_STATE_DIR/#\~/$HOME}"
[ -n "$STATE_DIR" ] || { echo "toolkit-env: no state dir — set HARNESS_STATE_DIR or 'stateDir' in harness.json." >&2; return 1 2>/dev/null || exit 1; }
unset CFG_STATE_DIR
# Remember it for the global hooks, which run in sessions started OUTSIDE any
# checkout (the operator starts sessions in a skills folder) and so have no config
# to read. Written only when it changes.
_last="$HOME/.claude/.harness-last-state-dir"
[ "$(cat "$_last" 2>/dev/null)" = "$STATE_DIR" ] || { mkdir -p "$HOME/.claude" && printf '%s\n' "$STATE_DIR" > "$_last" 2>/dev/null; }
unset _last

# DESIGN_KIT is empty when the config carries no design section — the design layer
# is OPTIONAL (a backend-only project has none); the design skills refuse on empty.

# The clone a ticket ships to, from its repo: label (empty label = the main repo).
# A sister repo is any name listed under sisterRepos in harness.json.
toolkit_repo_path() {
  local _sister
  for _sister in $(toolkit_cfg sisterRepos 2>/dev/null); do
    if [ "${1:-}" = "$_sister" ]; then
      [ -n "$SUPPORT_REPO" ] && { echo "$SUPPORT_REPO"; return 0; }
      echo "toolkit-env: no clone for repo '$1' — clone it beside the main repo, or set HARNESS_SISTER_REPO." >&2
      return 1
    fi
  done
  echo "$MAIN_REPO"
}

# The GitHub login this session acts as — the operator. ONE resolver for the
# whole toolkit (claim-lock.sh reads the same variables): HARNESS_LOGIN (or its
# legacy alias), else the login half of CLAIM_AGENT, else gh's own config (no
# network), else the API. Exported so every later fence and child process reuses
# it; a failed lookup is not cached. Fixtures set the login or CLAIM_AGENT and
# never touch the net.
toolkit_login() {
  if [ -z "$(_hv LOGIN)" ]; then
    # ${CLAIM_AGENT%%@*} on an UNSET variable: bash 3.2 quietly yields "",
    # bash 5 under set -u aborts with "CLAIM_AGENT: unbound variable". So the
    # macOS suite went green and the Linux runner died on the same line —
    # first caught 2026-09-24 by the first fixture to run claim-lock in a
    # clean environment. Default first, strip second.
    local l
    l="${CLAIM_AGENT:-}"
    l="${l%%@*}"
    [ -n "$l" ] && [ "$l" != "${CLAIM_AGENT:-}" ] || l=$(gh config get -h github.com user 2>/dev/null || true)
    [ -n "$l" ] || l=$(gh api user --jq .login 2>/dev/null || true)
    [ -n "$l" ] || { echo unknown; return; }
    HARNESS_LOGIN="$l"; export HARNESS_LOGIN
    [ -z "$_kit_legacy" ] || export "${_kit_legacy}_LOGIN=$l"
  fi
  _hv LOGIN; echo
}

# Is this login one of the humans whose approving review the gate counts?
# The gate reads the HUMAN_APPROVERS repo variable (default: the repo owner); so does this.
toolkit_is_approver() { # <login>
  # The workflow defaults the variable to the repo owner when unset; so does this,
  # and a fetched (even empty) answer is cached so one failure is not one per call.
  if [ -z "${HUMAN_APPROVERS_RESOLVED:-}" ]; then
    [ -n "${HUMAN_APPROVERS:-}" ] || HUMAN_APPROVERS=$(gh variable get HUMAN_APPROVERS --repo "$REPO_SLUG" 2>/dev/null || true)
    [ -n "${HUMAN_APPROVERS:-}" ] || HUMAN_APPROVERS="${REPO_SLUG%/*}"
    HUMAN_APPROVERS_RESOLVED=1; export HUMAN_APPROVERS HUMAN_APPROVERS_RESOLVED
  fi
  case ",$HUMAN_APPROVERS," in *",$1,"*) return 0 ;; *) return 1 ;; esac
}

# Every live claim — refs on origin plus any unmigrated lockfile — one per line.
# claim-lock.sh is the only reader that unions both; never re-derive this.
toolkit_claimed_issues() {
  bash "$CL" list --json 2>/dev/null | jq -r '.[].issue' 2>/dev/null
}

toolkit_tools() {
  local sha base dir
  sha=$(git -C "$MAIN_REPO" rev-parse --short "origin/$INTEGRATION_BRANCH" 2>/dev/null) \
    || { echo "toolkit-env: origin/$INTEGRATION_BRANCH not found in $MAIN_REPO — fetch first" >&2; return 1; }
  base="${TMPDIR:-/tmp}"; dir="${base%/}/harness-tools-$sha"
  if [ ! -d "$dir" ]; then
    # Materialise into a temp dir and move it into place, so a half-extracted
    # tree never masquerades as a finished one; a racing session finds it done.
    local tmp; tmp=$(mktemp -d "${base%/}/harness-tools-XXXXXX") || return 1
    if git -C "$MAIN_REPO" archive "origin/$INTEGRATION_BRANCH" scripts 2>/dev/null | tar -x -C "$tmp" 2>/dev/null && [ -d "$tmp/scripts" ]; then
      { [ ! -d "$dir" ] && mv "$tmp" "$dir" 2>/dev/null; } || rm -rf "$tmp"
    else
      rm -rf "$tmp"; echo "toolkit-env: could not materialise scripts/ from origin/$INTEGRATION_BRANCH in $MAIN_REPO" >&2; return 1
    fi
  fi
  echo "$dir"
}

export KIT_ROOT STATE_DIR REPO_ROOT MAIN_REPO SUPPORT_REPO PROGRAMMES_DIR CL HARNESS_CFG
export REPO_SLUG INTEGRATION_BRANCH BRANCH_PREFIX DESIGN_KIT STATUS_PREFIX
export LBL_DRAFTING LBL_READY LBL_CLAIMED LBL_IN_REVIEW LBL_GATED LBL_PARTIAL LBL_NEEDS_HUMAN LBL_PM_DECISION LBL_PM_TRACK LBL_BLOCKED LBL_EXTERNAL_BLOCKED LBL_PARKED HOLD_LABEL DECISION_LABELS
