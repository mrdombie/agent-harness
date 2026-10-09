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
#   3. the resolved hooks dir is read back from git, and every hook the worktree
#      carries in .husky/ must be executable there. Anything else is a 🛑, exit 1.
#
# A worktree with no .husky/ directory is not husky-managed: nothing is written, its
# own hooks setup is left alone, exit 0.
#
# --check runs step 3 alone (no writes) — for a worktree that already exists.
#
# extensions.worktreeConfig is enabled on the shared repo. With it on, core.bare in
# the shared file applies to EVERY worktree, so a shared core.bare=true (a main
# clone kept bare) would turn each linked worktree bare. git's documented remedy
# (git help worktree, "CONFIGURATION FILE") is applied in one step under git's own
# config.lock: core.bare=true and core.worktree move to the main worktree's
# config.worktree as the extension goes on, so no reader sees a half-moved state.
# Tools that ignore config.worktree (older libgit2, JGit) then read the main clone
# as non-bare. Needs git >= 2.31 (--path-format).
#
# Windows (UNTESTED here — no Windows machine in CI): the dispatcher is a POSIX sh
# script run by Git for Windows' sh, like husky's. A pre-push killed partway was
# seen to let the push through on Windows; on macOS/Linux a killed hook exits
# non-zero and git refuses the push (see the test). Nothing in this script changes
# how Windows reports a killed child's exit status.
#
# Exit: 0 hooks resolve (or the worktree is not husky-managed) · 1 they do not.
set -uo pipefail

CHECK_ONLY=0
[ "${1:-}" = "--check" ] && { CHECK_ONLY=1; shift; }
MAIN="${1:-}"; WT="${2:-}"
die() { echo "🛑 ensure-hooks: $*" >&2; exit 1; }
[ -n "$MAIN" ] && [ -n "$WT" ] || die "usage: ensure-hooks.sh [--check] <main-repo> <worktree>"

# <worktree> is the tree's root; nothing of husky's to run there means nothing to do.
if [ ! -d "$WT/.husky" ]; then
  echo "ensure-hooks: $WT has no .husky/ — not husky-managed, its hooks are left alone."
  exit 0
fi

gv=$(git version 2>/dev/null | sed -n 's/^git version \([0-9]*\)\.\([0-9]*\).*/\1 \2/p')
set -- $gv
{ [ "${1:-0}" -gt 2 ] || { [ "${1:-0}" -eq 2 ] && [ "${2:-0}" -ge 31 ]; }; } \
  || die "git ${1:-?}.${2:-?} is too old — this needs git 2.31 or newer"

common_of() {
  local d; d=$(git -C "$1" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || return 1
  [ -n "$d" ] && (cd "$d" 2>/dev/null && pwd -P)
}
MAIN_COMMON=$(common_of "$MAIN") || die "$MAIN is not a git repository"
WT_COMMON=$(common_of "$WT") || die "$WT is not a git worktree"
[ "$MAIN_COMMON" = "$WT_COMMON" ] || die "$WT is not a worktree of $MAIN ($WT_COMMON ≠ $MAIN_COMMON)"
TOP=$(git -C "$WT" rev-parse --show-toplevel 2>/dev/null) && [ -n "$TOP" ] || die "$WT has no working tree"
WT_GITDIR=$(git -C "$WT" rev-parse --absolute-git-dir 2>/dev/null) && [ -n "$WT_GITDIR" ] || die "cannot read the git dir of $WT"
SHIMS="$WT_GITDIR/harness-hooks"
HOOKS="applypatch-msg commit-msg post-applypatch post-checkout post-commit post-merge
       post-rewrite pre-applypatch pre-auto-gc pre-commit pre-merge-commit pre-push
       pre-rebase prepare-commit-msg"

verify() {
  local resolved hook carried=""
  resolved=$(git -C "$WT" rev-parse --path-format=absolute --git-path hooks 2>/dev/null) && [ -n "$resolved" ] \
    || die "git could not resolve a hooks directory for $WT"
  [ -f "$resolved/h" ] && grep -q '^# agent-harness hook dispatcher' "$resolved/h" 2>/dev/null \
    || die "git resolves hooks for $WT to $resolved, which is not this kit's dispatcher — git would run no hook, or the wrong checkout's. Run: ensure-hooks.sh \"$MAIN\" \"$WT\""
  for hook in $HOOKS; do
    [ -f "$TOP/.husky/$hook" ] || continue
    carried="$carried $hook"
    [ -x "$resolved/$hook" ] \
      || die "git resolves hooks for $WT to $resolved, and $hook there is not executable — git would skip .husky/$hook. Run: ensure-hooks.sh \"$MAIN\" \"$WT\""
  done
  echo "ensure-hooks: $WT runs its own .husky hooks (${carried# }) via $resolved"
}

[ "$CHECK_ONLY" = 1 ] && { verify; exit 0; }

ext_on() { [ "$(git config --file "$MAIN_COMMON/config" --type=bool --get extensions.worktreeConfig 2>/dev/null)" = "true" ]; }

if ! ext_on; then
  # git's own lock protocol: take config.lock, write the new file into it, rename it
  # over config. Peers wait here and then find the extension already on.
  LOCK="$MAIN_COMMON/config.lock"; n=0
  until ( set -C; : > "$LOCK" ) 2>/dev/null; do
    n=$((n+1)); [ "$n" -ge 150 ] && die "$LOCK has been held for 30s — if no git process is running, remove it and re-run"
    sleep 0.2
  done
  trap 'rm -f "$LOCK"' EXIT
  if ! ext_on; then
    cp -p "$MAIN_COMMON/config" "$LOCK" || die "could not copy $MAIN_COMMON/config"
    if [ "$(git config --file "$LOCK" --type=bool --get core.bare 2>/dev/null)" = "true" ]; then
      git config --file "$MAIN_COMMON/config.worktree" core.bare true || die "could not write $MAIN_COMMON/config.worktree"
      git config --file "$LOCK" --unset core.bare || die "could not take core.bare out of the shared config"
    fi
    if cw=$(git config --file "$LOCK" --get core.worktree 2>/dev/null); then
      git config --file "$MAIN_COMMON/config.worktree" core.worktree "$cw" || die "could not write $MAIN_COMMON/config.worktree"
      git config --file "$LOCK" --unset core.worktree || die "could not take core.worktree out of the shared config"
    fi
    git config --file "$LOCK" extensions.worktreeConfig true || die "could not enable extensions.worktreeConfig"
    mv -f "$LOCK" "$MAIN_COMMON/config" || die "could not replace $MAIN_COMMON/config"
  fi
  rm -f "$LOCK"; trap - EXIT
fi

mkdir -p "$SHIMS" || die "could not create $SHIMS"
# Husky 9's shim, except the script it runs is <worktree root>/.husky/<hook>, found
# from where git runs hooks (the worktree root) rather than from the shim's own path.
cat > "$SHIMS/h" <<'SH' || die "could not write $SHIMS/h"
#!/usr/bin/env sh
# agent-harness hook dispatcher — written by ensure-hooks.sh; runs this worktree's .husky/<hook>.
[ "$HUSKY" = "2" ] && set -x
n=$(basename "$0")
top=$(git rev-parse --show-toplevel 2>/dev/null) || top=$PWD
[ -d "$top/.husky" ] || { echo "agent-harness hooks: no .husky in $top — refusing $n" >&2; exit 1; }
s="$top/.husky/$n"
if [ ! -f "$s" ]; then
  [ "$n" = "pre-push" ] && echo "agent-harness hooks: no .husky/pre-push in $top — pushing with no pre-push gate" >&2
  exit 0
fi
i="${XDG_CONFIG_HOME:-$HOME/.config}/husky/init.sh"
[ -f "$i" ] && . "$i"
if [ "${HUSKY-}" = "0" ]; then
  [ "$n" = "pre-push" ] && echo "agent-harness hooks: HUSKY=0 — pre-push skipped" >&2
  exit 0
fi
export PATH="node_modules/.bin:$PATH"
sh -e "$s" "$@"
c=$?
[ $c != 0 ] && echo "husky - $n script failed (code $c)"
[ $c = 127 ] && echo "husky - command not found in PATH=$PATH"
exit $c
SH
for hook in $HOOKS; do
  printf '#!/usr/bin/env sh\n. "$(dirname "$0")/h"\n' > "$SHIMS/$hook" && chmod +x "$SHIMS/$hook" \
    || die "could not write $SHIMS/$hook"
done

git -C "$WT" config --worktree core.hooksPath "$SHIMS" || die "could not set core.hooksPath for $WT"
verify
