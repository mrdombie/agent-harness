#!/usr/bin/env bash
# link-node-modules.sh <shared-repo> <worktree> — give a worktree the shared
# install WITHOUT handing it the shared checkout's own workspace packages.
#
# A worktree used to get one symlink: `<worktree>/node_modules -> <shared>/node_modules`.
# That directory also holds the workspace links (`@scope/ui -> ../../packages/ui`),
# and those resolve relative to the SHARED checkout, so every workspace import in
# the worktree ran the shared clone's copy of the package, not the branch's:
#
#   - a dev server 500s on a subpath the branch added ("Can't resolve
#     '@scope/contracts/sign-in-codes'"), and a change to a package renders as the
#     stale copy without an error;
#   - a dependency the install left inside one workspace's own node_modules
#     (`packages/ui/node_modules/@formkit/auto-animate`) is invisible from the
#     worktree, whose `packages/ui/node_modules` does not exist, so typecheck
#     fails on a module the branch never touched.
#
# Instead the worktree gets its OWN node_modules directory:
#
#   - every top-level entry of the shared node_modules is symlinked in, except
#     the workspace scope(s), which are real directories here;
#   - each workspace package is linked to THIS worktree's directory for it;
#   - a third-party package in the same scope still links through to the shared one;
#   - each workspace's own node_modules in the shared clone is mirrored the same
#     way into the worktree's copy of that workspace.
#
# Symlinks only: no install, nothing written to the shared clone. Idempotent —
# re-running relinks, so it also converts a worktree that still has the old single
# symlink. A real install (a node_modules directory this script did not build) is
# left alone.
#
# Exit 0 linked (or nothing to link) · 1 a workspace does not resolve to this
# worktree afterwards, or the arguments are wrong.
set -euo pipefail

SHARED_REPO=${1:-}
WT=${2:-}
[ -n "$SHARED_REPO" ] && [ -n "$WT" ] || { echo "usage: link-node-modules.sh <shared-repo> <worktree>" >&2; exit 1; }
SHARED_REPO=$(cd "$SHARED_REPO" && pwd -P)
WT=$(cd "$WT" && pwd -P)
SHARED_NM="$SHARED_REPO/node_modules"
MARK=".linked-from-shared-install"

[ -d "$SHARED_NM" ] || { echo "link-node-modules: $SHARED_REPO has no node_modules — nothing to link."; exit 0; }

# Git Bash's `ln -s` writes a deep COPY of a directory unless MSYS=winsymlinks is
# set, so Windows gets a junction for a directory and a copy for a file.
windows=0
case "$(uname -s 2>/dev/null)" in MINGW*|MSYS*|CYGWIN*) windows=1 ;; esac
link() { # <target> <link>
  if [ "$windows" = 1 ]; then
    if [ -d "$1" ]; then cmd //c mklink //J "$(cygpath -w "$2")" "$(cygpath -w "$1")" >/dev/null
    else cp -p "$1" "$2"; fi
  else
    ln -sfn "$1" "$2"
  fi
}

# A node_modules directory to (re)build. A symlink (the old layout) is replaced. A
# directory this script built, or one holding nothing but workspace-scope links
# (what a per-workspace shadowing step leaves), is emptied of its links. Anything
# else is a real install and is refused.
fresh_dir() { # <dir> → 0 ready · 1 a real install, leave it
  local d=$1 e
  if [ -L "$d" ] || [ -f "$d" ]; then rm -f "$d"
  elif [ -d "$d" ]; then
    if [ ! -f "$d/$MARK" ]; then
      for e in "$d"/* "$d"/.[!.]* "$d"/..?*; do
        [ -e "$e" ] || [ -L "$e" ] || continue
        owned "${e##*/}" && [ -d "$e" ] && [ ! -L "$e" ] && continue
        return 1
      done
    fi
    find "$d" -mindepth 1 -maxdepth 2 -type l -exec rm -f {} +
  fi
  mkdir -p "$d"
  printf '%s\n' "$SHARED_REPO" > "$d/$MARK"
}

# The workspaces THIS checkout declares: "<package name>\t<dir relative to root>",
# from the root package.json's `workspaces` (an array, or { packages: [...] }).
# A `*` matches one path segment; `!negations` are honoured.
command -v node >/dev/null 2>&1 || { echo "link-node-modules: node is not on PATH — cannot read the workspaces." >&2; exit 1; }
WORKSPACES=$(node -e '
  const fs = require("fs"), path = require("path")
  const root = process.argv[1]
  let pkg = {}
  try { pkg = JSON.parse(fs.readFileSync(path.join(root, "package.json"), "utf8")) } catch {}
  let pats = pkg.workspaces || []
  if (!Array.isArray(pats)) pats = pats.packages || []
  const rx = s => new RegExp("^" + s.replace(/[.+^${}()|[\]\\]/g, "\\$&").replace(/\*+/g, "[^/]*") + "$")
  const expand = pat => {
    let dirs = [""]
    for (const seg of pat.replace(/\/+$/, "").split("/")) {
      const next = []
      for (const d of dirs) {
        if (!seg.includes("*")) { next.push(d ? d + "/" + seg : seg); continue }
        let ents = []
        try { ents = fs.readdirSync(path.join(root, d), { withFileTypes: true }) } catch {}
        for (const e of ents) if (e.isDirectory() && e.name !== "node_modules" && rx(seg).test(e.name)) next.push(d ? d + "/" + e.name : e.name)
      }
      dirs = next
    }
    return dirs
  }
  const out = new Map()
  for (const p of pats.filter(p => !p.startsWith("!"))) for (const d of expand(p)) out.set(d, true)
  for (const p of pats.filter(p => p.startsWith("!"))) for (const d of expand(p.slice(1))) out.delete(d)
  for (const d of [...out.keys()].sort()) {
    try {
      const name = JSON.parse(fs.readFileSync(path.join(root, d, "package.json"), "utf8")).name
      if (typeof name === "string" && name) process.stdout.write(name + "\t" + d + "\n")
    } catch {}
  }
' "$WT")

# The top-level entries the worktree owns: each workspace scope ("@scope"), and the
# name of each unscoped workspace package.
OWNED=$(printf '%s\n' "$WORKSPACES" | awk -F'\t' 'NF==2 { split($1, a, "/"); print a[1] }' | sort -u)
owned() { [ -n "$OWNED" ] && printf '%s\n' "$OWNED" | grep -qxF -- "$1"; }

# link_entries <shared node_modules> <worktree node_modules> — every entry, dot
# entries included, except the owned ones.
link_entries() {
  local src=$1 dst=$2 e name
  for e in "$src"/* "$src"/.[!.]* "$src"/..?*; do
    [ -e "$e" ] || [ -L "$e" ] || continue
    name=${e##*/}
    [ "$name" = "$MARK" ] && continue
    owned "$name" && continue
    link "$e" "$dst/$name"
  done
}

if ! fresh_dir "$WT/node_modules"; then
  echo "link-node-modules: $WT/node_modules is a real install — left alone."
  exit 0
fi
link_entries "$SHARED_NM" "$WT/node_modules"

# The owned scopes: whatever the shared scope holds that is NOT a workspace here
# (a published package under the same scope) links through; workspaces link home.
links=0
for scope in $OWNED; do
  case "$scope" in @*) ;; *) continue ;; esac
  [ -L "$WT/node_modules/$scope" ] && rm -f "$WT/node_modules/$scope"
  mkdir -p "$WT/node_modules/$scope"
  for e in "$SHARED_NM/$scope"/*; do
    [ -e "$e" ] || [ -L "$e" ] || continue
    printf '%s\n' "$WORKSPACES" | cut -f1 | grep -qxF -- "$scope/${e##*/}" && continue
    link "$e" "$WT/node_modules/$scope/${e##*/}"
  done
done
while IFS=$'\t' read -r name dir; do
  [ -n "$name" ] || continue
  link "$WT/$dir" "$WT/node_modules/$name"
  links=$((links + 1))
done <<EOF
$WORKSPACES
EOF

# A dependency the install left inside one workspace (a version clash, or a stale
# hoist) lives in that workspace's own node_modules, which the worktree does not
# have. Mirror it, minus the owned entries — those resolve from the root above.
mirrored=0
while IFS=$'\t' read -r name dir; do
  [ -n "$dir" ] && [ -d "$SHARED_REPO/$dir/node_modules" ] || continue
  if fresh_dir "$WT/$dir/node_modules"; then
    link_entries "$SHARED_REPO/$dir/node_modules" "$WT/$dir/node_modules"
    mirrored=$((mirrored + 1))
  fi
done <<EOF
$WORKSPACES
EOF

# Prove it: every workspace must resolve, from the root node_modules, to its own
# directory in THIS worktree. A link that lands anywhere else is the original bug.
bad=0
for scope in $OWNED; do
  case "$scope" in @*) ;; *) continue ;; esac
  # A linked scope directory would put this worktree's links INSIDE the shared clone.
  if [ -L "$WT/node_modules/$scope" ] || [ ! -d "$WT/node_modules/$scope" ]; then
    echo "✗ node_modules/$scope is not this worktree's own directory" >&2
    bad=1
  fi
done
while IFS=$'\t' read -r name dir; do
  [ -n "$name" ] || continue
  if ! [ "$WT/node_modules/$name" -ef "$WT/$dir" ]; then
    echo "✗ $name does not resolve to $dir in this worktree" >&2
    bad=1
  fi
done <<EOF
$WORKSPACES
EOF
[ "$bad" = 0 ] || exit 1

echo "link-node-modules: shared install linked into $WT/node_modules; $links workspace package(s) point at this worktree; $mirrored workspace node_modules mirrored."
