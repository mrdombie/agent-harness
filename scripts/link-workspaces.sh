#!/usr/bin/env bash
# link-workspaces.sh <shared-clone> <worktree>
#
# Point a worktree's workspace packages at the WORKTREE's own siblings.
#
# /claim borrows the shared clone's node_modules with one symlink. npm links each
# workspace package in there relatively (node_modules/@scope/pkg ->
# ../../packages/pkg), and a relative link resolves against where the link file
# really is: the shared clone, whose working tree nothing updates. So code in a
# worktree imported the clone's stale copy of its own sibling packages.
#
# Node looks in <workspace>/node_modules before walking up to the borrowed one,
# so this writes, into each workspace the worktree has, an absolute link per
# workspace package to the worktree's copy. Real dependencies are untouched and
# still come from the shared install; nothing is written into the shared clone.
# Idempotent. Every path it writes is gitignored by any repo that ignores
# node_modules.
set -uo pipefail
SHARED="${1:?usage: link-workspaces.sh <shared-clone> <worktree>}"
WT="${2:?usage: link-workspaces.sh <shared-clone> <worktree>}"
SHARED=$(cd "$SHARED" && pwd -P) || exit 1
WT=$(cd "$WT" && pwd -P) || exit 1
NM="$SHARED/node_modules"
[ -d "$NM" ] || { echo "link-workspaces: no node_modules in $SHARED — nothing to do"; exit 0; }

# norm <path> — collapse . and .. without touching the filesystem.
norm() {
  local out="" seg IFS=/
  for seg in $1; do
    case "$seg" in ''|.) ;; ..) out="${out%/*}" ;; *) out="$out/$seg" ;; esac
  done
  printf '%s\n' "${out:-/}"
}

# name<TAB>repo-relative path, for every link in node_modules (scoped or not)
# that resolves inside the shared clone and outside node_modules: a workspace.
pairs=$(
  for l in "$NM"/* "$NM"/@*/*; do
    [ -L "$l" ] || continue
    # Resolved by PATH, not by cd: the stale clone often lacks a package the
    # worktree has, and that package is exactly the one that most needs a link.
    r=$(readlink "$l")
    if [ "${r#/}" != "$r" ]; then t=$(norm "$r"); else t=$(norm "$(cd "$(dirname "$l")" && pwd -P)/$r"); fi
    # if, not case: bash 3.2 misparses a case's `)` inside $( ).
    [ "${t#"$SHARED"/}" != "$t" ] || continue                 # outside the clone
    [ "${t#"$SHARED"/node_modules}" = "$t" ] || continue      # a real dependency
    printf '%s\t%s\n' "${l#"$NM"/}" "${t#"$SHARED"/}"
  done
)
[ -n "$pairs" ] || { echo "link-workspaces: no workspace packages linked in $NM"; exit 0; }

n=0
while IFS=$'\t' read -r _ ws; do
  [ -d "$WT/$ws" ] || continue                    # a workspace this worktree lacks
  while IFS=$'\t' read -r name rel; do
    [ "$rel" = "$ws" ] && continue                # a package needs no link to itself
    [ -d "$WT/$rel" ] || continue
    mkdir -p "$(dirname "$WT/$ws/node_modules/$name")"
    ln -sfn "$WT/$rel" "$WT/$ws/node_modules/$name" && n=$((n+1))
  done <<< "$pairs"
done <<< "$pairs"
echo "link-workspaces: $n workspace link(s) now point into $WT"
