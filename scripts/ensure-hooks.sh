#!/usr/bin/env bash
# ensure-hooks.sh [--check] <main-repo> <worktree> — make git run the worktree's own
# .husky hooks, and prove it, or exit non-zero.
#
# Husky points the SHARED core.hooksPath at the relative `.husky/_`, a gitignored
# directory only `npm install` creates. A linked worktree has none unless someone
# copies it in, and when it is missing git runs no hook at all and the push goes
# out unchecked. Pointing the shared value at the main clone's absolute `.husky/_`
# does not hold either: the next `npm install` resets it, and husky's shim runs the
# script beside itself, so it would run the main clone's stale checkout of the gate.
#
# So, per worktree:
#   1. a dispatcher directory in the worktree's PRIVATE git dir (not the working
#      tree: `git clean -xdf` cannot remove it, nothing has to be copied, husky
#      need never have run). Each hook in it runs <worktree root>/.husky/<hook> the
#      way husky's own shim does;
#   2. `git config --worktree core.hooksPath <that dir>`. Worktree config is read
#      after the shared file, so husky resetting the shared value changes nothing;
#   3. the resolved hooks dir is read back from git and its pre-push must be
#      executable, and the worktree must carry .husky/pre-push. Anything else is
#      a 🛑 and exit 1.
#
# --check runs step 3 alone (no writes) — for a worktree that already exists.
#
# extensions.worktreeConfig is enabled on the shared repo. With it on, core.bare in
# the shared file applies to EVERY worktree, so a shared core.bare=true (a main
# clone kept bare) would turn each linked worktree bare. git's documented remedy is
# applied first: core.bare=true and core.worktree move to the main worktree's own
# config.worktree, then the extension is switched on (git help worktree,
# "CONFIGURATION FILE"). Git older than 2.20 refuses such a repo.
#
# Windows (UNTESTED here — no Windows machine in CI): the dispatcher is a POSIX sh
# script run by Git for Windows' sh, like husky's. A pre-push killed partway was
# seen to let the push through on Windows; on macOS/Linux a killed hook exits
# non-zero and git refuses the push (see the test). Nothing in this script changes
# how Windows reports a killed child's exit status.
#
# Exit: 0 hooks resolve and pre-push will run · 1 they do not (or bad arguments).
set -uo pipefail

CHECK_ONLY=0
[ "${1:-}" = "--check" ] && { CHECK_ONLY=1; shift; }
MAIN="${1:-}"; WT="${2:-}"
die() { echo "🛑 ensure-hooks: $*" >&2; exit 1; }
[ -n "$MAIN" ] && [ -n "$WT" ] || die "usage: ensure-hooks.sh [--check] <main-repo> <worktree>"

common_of() { git -C "$1" rev-parse --path-format=absolute --git-common-dir 2>/dev/null; }
MAIN_COMMON=$(common_of "$MAIN") || die "$MAIN is not a git repository"
WT_COMMON=$(common_of "$WT") || die "$WT is not a git worktree"
MAIN_COMMON=$(cd "$MAIN_COMMON" && pwd -P); WT_COMMON=$(cd "$WT_COMMON" && pwd -P)
[ "$MAIN_COMMON" = "$WT_COMMON" ] || die "$WT is not a worktree of $MAIN ($WT_COMMON ≠ $MAIN_COMMON)"
TOP=$(git -C "$WT" rev-parse --show-toplevel 2>/dev/null) || die "$WT has no working tree"
WT_GITDIR=$(git -C "$WT" rev-parse --absolute-git-dir 2>/dev/null) || die "cannot read the git dir of $WT"
SHIMS="$WT_GITDIR/harness-hooks"

verify() {
  local resolved
  resolved=$(git -C "$WT" rev-parse --path-format=absolute --git-path hooks 2>/dev/null) \
    || die "git could not resolve a hooks directory for $WT"
  [ -f "$TOP/.husky/pre-push" ] \
    || die "$TOP has no .husky/pre-push — there is no pre-push gate here to run"
  [ -x "$resolved/pre-push" ] \
    || die "git resolves hooks for $WT to $resolved, and there is no executable pre-push there — git would push with NO hook. Run: ensure-hooks.sh \"$MAIN\" \"$WT\""
  [ -f "$resolved/h" ] && grep -q '^# agent-harness hook dispatcher' "$resolved/h" 2>/dev/null \
    || die "git resolves hooks for $WT to $resolved, which is not this kit's dispatcher — a husky shim there runs whatever .husky/ sits beside it, not this worktree's. Run: ensure-hooks.sh \"$MAIN\" \"$WT\""
  echo "ensure-hooks: $WT runs its own .husky hooks (via $resolved)"
}

[ "$CHECK_ONLY" = 1 ] && { verify; exit 0; }

# git config takes a lock on the file; peers set up worktrees at the same time.
cfg() { local n=0; until git "$@" 2>/dev/null; do n=$((n+1)); [ "$n" -ge 20 ] && return 1; sleep 0.2; done; }

if [ "$(git -C "$MAIN" config --file "$MAIN_COMMON/config" --type=bool --get extensions.worktreeConfig 2>/dev/null)" != "true" ]; then
  # core.bare=true first goes where the main worktree alone reads it, then leaves
  # the shared file, then the extension goes on — no linked worktree ever reads bare.
  if [ "$(git config --file "$MAIN_COMMON/config" --type=bool --get core.bare 2>/dev/null)" = "true" ]; then
    cfg config --file "$MAIN_COMMON/config.worktree" core.bare true || die "could not write $MAIN_COMMON/config.worktree"
    cfg config --file "$MAIN_COMMON/config" --unset core.bare || die "could not move core.bare out of $MAIN_COMMON/config"
  fi
  if cw=$(git config --file "$MAIN_COMMON/config" --get core.worktree 2>/dev/null); then
    cfg config --file "$MAIN_COMMON/config.worktree" core.worktree "$cw" || die "could not write $MAIN_COMMON/config.worktree"
    cfg config --file "$MAIN_COMMON/config" --unset core.worktree || die "could not move core.worktree out of $MAIN_COMMON/config"
  fi
  cfg config --file "$MAIN_COMMON/config" extensions.worktreeConfig true || die "could not enable extensions.worktreeConfig in $MAIN_COMMON/config"
fi

mkdir -p "$SHIMS" || die "could not create $SHIMS"
# Husky 9's shim, except the script it runs is <worktree root>/.husky/<hook>, found
# from where git runs hooks (the worktree root) rather than from the shim's own path.
cat > "$SHIMS/h" <<'SH'
#!/usr/bin/env sh
# agent-harness hook dispatcher — written by ensure-hooks.sh; runs this worktree's .husky/<hook>.
[ "$HUSKY" = "2" ] && set -x
n=$(basename "$0")
top=$(git rev-parse --show-toplevel 2>/dev/null) || top=$PWD
[ -d "$top/.husky" ] || { echo "agent-harness hooks: no .husky in $top — refusing $n" >&2; exit 1; }
s="$top/.husky/$n"
[ ! -f "$s" ] && exit 0
i="${XDG_CONFIG_HOME:-$HOME/.config}/husky/init.sh"
[ -f "$i" ] && . "$i"
[ "${HUSKY-}" = "0" ] && exit 0
export PATH="node_modules/.bin:$PATH"
sh -e "$s" "$@"
c=$?
[ $c != 0 ] && echo "husky - $n script failed (code $c)"
[ $c = 127 ] && echo "husky - command not found in PATH=$PATH"
exit $c
SH
for hook in applypatch-msg commit-msg post-applypatch post-checkout post-commit post-merge \
            post-rewrite pre-applypatch pre-auto-gc pre-commit pre-merge-commit pre-push \
            pre-rebase prepare-commit-msg; do
  printf '#!/usr/bin/env sh\n. "$(dirname "$0")/h"\n' > "$SHIMS/$hook"
  chmod +x "$SHIMS/$hook"
done

cfg -C "$WT" config --worktree core.hooksPath "$SHIMS" || die "could not set core.hooksPath for $WT"
verify
