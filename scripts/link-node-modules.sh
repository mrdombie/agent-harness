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
# A worktree whose package-lock.json differs from the shared clone's gets its own
# install instead (`npm ci --prefer-offline`; LINK_NODE_MODULES_INSTALL overrides).
#
# Otherwise symlinks only: no install, nothing written to the shared clone. Idempotent —
# re-running relinks, so it also converts a worktree that still has the old single
# symlink. A real install (a node_modules directory this script did not build) is
# left alone.
#
# THE LINKS ARE A SNAPSHOT OF THE MANIFESTS. A merge of the trunk that adds a package
# changes package-lock.json and package.json and nothing re-ran this, so the new
# top-level package was never linked and every gate importing it failed with "Cannot
# find module". So each run records a fingerprint of what it was built from — this
# tree's package-lock.json, the shared clone's, the root package.json and each
# workspace's — in node_modules/.harness-link-stamp as "<linked|own> <sha256>", and
# `--if-stale` rebuilds only when that fingerprint moved (or was never written).
#
# A PRIVATE INSTALL BEHIND ITS LOCKFILE IS REPLACED. A node_modules directory with no
# mark and no fingerprint (made by hand, or by this script before it wrote them) used to
# be "a real install — left alone" for ever; when it fell behind package-lock.json every
# gate checking the install went red, and a fixer that may not run an install asked a
# person. Now, when npm's own record of it (node_modules/.package-lock.json) disagrees with
# the lockfile on a version, or lacks a package it declares, it is removed and rebuilt — linked, or this script's own
# install — unless another process, live run or claim holds the tree (worktree-lib.sh),
# which exits 3 and changes nothing. A private install that matches is still left alone.
#
#   link-node-modules.sh --behind <worktree> — exit 0 when the tree's install (through
#   its links) disagrees with its lockfile, printing the count and where it lives; 1 not.
#
# Exit 0 linked, up to date, or nothing to link · 1 a workspace does not resolve to
# this worktree afterwards, the own install failed, or the arguments are wrong · 3 a
# private install behind its lockfile, left alone because the tree is in use elsewhere.
set -euo pipefail

# install_drift <tree> — prints how many packages the tree's lockfile declares that npm
# installed at another version OR NOT AT ALL; nothing when either record is missing
# (cannot tell). A missing one counts: an install made before the lockfile gained a
# package has no entry for it, and every import of it is "Cannot find module".
# Optional, linked and bundled entries are never required to be there.
install_drift() {
  [ -f "$1/package-lock.json" ] && [ -f "$1/node_modules/.package-lock.json" ] || return 0
  node -e '
    const fs = require("fs")
    let a, b
    try { a = JSON.parse(fs.readFileSync(process.argv[1], "utf8")).packages || {}; b = JSON.parse(fs.readFileSync(process.argv[2], "utf8")).packages || {} } catch { process.exit(0) }
    let n = 0
    for (const [k, d] of Object.entries(b)) {
      if (!k || !/(^|\/)node_modules\//.test(k) || !d || !d.version || d.link || d.inBundle || d.optional || d.devOptional) continue
      const i = a[k]
      if (!i || (i.version && i.version !== d.version)) n++
    }
    process.stdout.write(String(n))
  ' "$1/node_modules/.package-lock.json" "$1/package-lock.json" 2>/dev/null || true
}

if [ "${1:-}" = "--behind" ]; then
  [ -d "${2:-}" ] || { echo "usage: link-node-modules.sh --behind <worktree>" >&2; exit 1; }
  n=$(install_drift "$2"); n=${n:-0}
  [ "$n" -gt 0 ] 2>/dev/null || exit 1
  where=$(cd "$2/node_modules" && cd "$(dirname "$(readlink .package-lock.json 2>/dev/null || echo .package-lock.json)")" 2>/dev/null && pwd -P)
  echo "$n package(s) $2/package-lock.json declares are missing from ${where:-$2/node_modules} or installed there at another version"
  exit 0
fi

IF_STALE=0
[ "${1:-}" = "--if-stale" ] && { IF_STALE=1; shift; }
SHARED_REPO=${1:-}
WT=${2:-}
[ -n "$SHARED_REPO" ] && [ -n "$WT" ] || { echo "usage: link-node-modules.sh [--if-stale] <shared-repo> <worktree>" >&2; exit 1; }
SHARED_REPO=$(cd "$SHARED_REPO" && pwd -P)
WT=$(cd "$WT" && pwd -P)
SHARED_NM="$SHARED_REPO/node_modules"
MARK=".linked-from-shared-install"
STAMP=".harness-link-stamp"

[ -d "$SHARED_NM" ] || { echo "link-node-modules: $SHARED_REPO has no node_modules — nothing to link."; exit 0; }

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
  const rx = s => new RegExp("^" + s.replace(/[.+?^${}()|[\]\\]/g, "\\$&").replace(/\*+/g, "[^/]*") + "$")
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

# The fingerprint of everything the install is built from. A file that is not there
# hashes as absent, so adding or removing one moves it too.
FP=$(printf '%s\n' "$WORKSPACES" | cut -f2 | node -e '
  const fs = require("fs"), path = require("path"), crypto = require("crypto")
  const [wt, shared] = process.argv.slice(1)
  const h = crypto.createHash("sha256")
  const add = (label, f) => { let c = "<absent>"; try { c = fs.readFileSync(f) } catch {} ; h.update(label + "\0"); h.update(c); h.update("\0") }
  add("lock", path.join(wt, "package-lock.json"))
  add("shared-lock", path.join(shared, "package-lock.json"))
  add("package.json", path.join(wt, "package.json"))
  for (const d of fs.readFileSync(0, "utf8").split("\n").filter(Boolean)) add(d, path.join(wt, d, "package.json"))
  process.stdout.write(h.digest("hex"))
' "$WT" "$SHARED_REPO")
STAMPED=$(cat "$WT/node_modules/$STAMP" 2>/dev/null || true)
if [ "$IF_STALE" = 1 ] && [ -n "$FP" ]; then
  case "$STAMPED" in
    "linked $FP"|"own $FP") echo "link-node-modules: $WT/node_modules is up to date with its lockfile and package.json files — nothing to do."; exit 0 ;;
    "") echo "link-node-modules: $WT/node_modules has no fingerprint — rebuilding it." >&2 ;;
    *) echo "link-node-modules: $WT's lockfile or package.json files changed since its node_modules was built — rebuilding it." >&2 ;;
  esac
fi

# A private install (no mark, no fingerprint) behind its lockfile: rebuilt below, as long as
# nothing but this run holds the tree. The caller's own claim is its ticket's
# (LINK_NODE_MODULES_TICKET, else DRIVER_TICKET); its own processes are its ancestry.
held_elsewhere() { # <tree> — prints who holds it; 1 when nobody but the caller does
  local why rc rid pid n mine="${LINK_NODE_MODULES_TICKET:-${DRIVER_TICKET:-}}"
  # shellcheck source=worktree-lib.sh
  . "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/worktree-lib.sh" || { echo "worktree-lib.sh could not be loaded"; return 0; }
  wt_can_see_processes || { echo "no lsof here, so who uses it cannot be told"; return 0; }
  wt_cwds_load --exclude-self
  if pid=$(wt_occupant "$1"); then echo "pid $pid has its cwd there"; return 0; fi
  if rid=$(wt_run_holder "$1"); then
    pid=$(jq -r '.pid // .child_pid // empty' "${RUNS_DIR:-${STATE_DIR:-}/runs}/$rid.json" 2>/dev/null)
    case "$WT_SELF" in *" $pid "*) ;; *) echo "live run $rid holds it"; return 0 ;; esac
  fi
  why=$(wt_claim_holder "$1"); rc=$?
  [ "$rc" = 2 ] && { echo "the claims could not be read"; return 0; }
  if [ "$rc" = 0 ]; then
    n=$(printf '%s' "$why" | sed -n 's/^claim #\([0-9][0-9]*\).*/\1/p')
    [ -n "$mine" ] && [ "$n" = "$mine" ] || { echo "$why"; return 0; }
  fi
  return 1
}
if [ -d "$WT/node_modules" ] && [ ! -L "$WT/node_modules" ] && [ ! -f "$WT/node_modules/$MARK" ] && [ -z "$STAMPED" ]; then
  drift=$(install_drift "$WT"); drift=${drift:-0}
  if [ "$drift" -gt 0 ] 2>/dev/null; then
    if who=$(held_elsewhere "$WT"); then
      echo "link-node-modules: $WT/node_modules is a private install $drift package(s) behind its lockfile, but it is not this run's to replace ($who) — left alone." >&2
      exit 3
    fi
    echo "link-node-modules: $WT/node_modules is a private install $drift package(s) behind its lockfile — replaced by the harness (machine setup; nobody installs into the worktree by hand)." >&2
    rm -rf "$WT/node_modules"
    while IFS=$'\t' read -r _n dir; do
      [ -n "$dir" ] && [ -d "$WT/$dir/node_modules" ] && [ ! -L "$WT/$dir/node_modules" ] \
        && [ ! -f "$WT/$dir/node_modules/$MARK" ] && rm -rf "$WT/$dir/node_modules"
    done <<EOF
$WORKSPACES
EOF
    STAMPED=""
  fi
fi

# A worktree whose lockfile is not the shared one's needs packages the shared install lacks:
# it gets its own install (from the npm cache where it can), never the shared links.
if [ -f "$WT/package-lock.json" ] && [ -f "$SHARED_REPO/package-lock.json" ] \
   && ! cmp -s "$WT/package-lock.json" "$SHARED_REPO/package-lock.json"; then
  if [ -d "$WT/node_modules" ] && [ ! -L "$WT/node_modules" ] && [ ! -f "$WT/node_modules/$MARK" ]; then
    case "$STAMPED" in
      # An own install this script made, from an older lockfile: made again.
      own\ *) [ "$STAMPED" = "own $FP" ] || { rm -rf "$WT/node_modules"; STAMPED=""; } ;;
    esac
    if [ -d "$WT/node_modules" ]; then
      echo "link-node-modules: $WT/package-lock.json differs from the shared one and $WT/node_modules is already its own install — left alone."
      exit 0
    fi
  fi
  # Only links this script made go: a symlink, or a directory carrying the mark (symlinks are not followed).
  [ -L "$WT/node_modules" ] && rm -f "$WT/node_modules"
  for d in "$WT/node_modules" "$WT"/*/*/node_modules "$WT"/*/node_modules; do
    [ -d "$d" ] && [ ! -L "$d" ] && [ -f "$d/$MARK" ] && rm -rf "$d"
  done
  echo "link-node-modules: $WT/package-lock.json differs from $SHARED_REPO/package-lock.json — installing the worktree's own dependencies." >&2
  (cd "$WT" && ${LINK_NODE_MODULES_INSTALL:-npm ci --prefer-offline --no-audit --no-fund}) >&2 \
    || { echo "link-node-modules: the worktree's own install failed." >&2; exit 1; }
  printf 'own %s\n' "$FP" > "$WT/node_modules/$STAMP"
  echo "link-node-modules: own install in $WT/node_modules (its lockfile differs from the shared one)."
  exit 0
fi

# An own install this script made, for a lockfile that now matches the shared one: links
# instead. Its workspace node_modules came from the same install, so they go too.
case "$STAMPED" in
  own\ *)
    if [ -d "$WT/node_modules" ] && [ ! -L "$WT/node_modules" ] && [ ! -f "$WT/node_modules/$MARK" ]; then
      echo "link-node-modules: $WT/node_modules was its own install for an older lockfile — the lockfile now matches the shared one, so it is linked instead." >&2
      rm -rf "$WT/node_modules"
      while IFS=$'\t' read -r _n dir; do
        [ -n "$dir" ] && [ -d "$WT/$dir/node_modules" ] && [ ! -L "$WT/$dir/node_modules" ] \
          && [ ! -f "$WT/$dir/node_modules/$MARK" ] && rm -rf "$WT/$dir/node_modules"
      done <<EOF
$WORKSPACES
EOF
    fi ;;
esac

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
    # A scope directory left empty (a scope that is no longer a workspace scope)
    # would otherwise survive and swallow the link to the shared one INSIDE it.
    find "$d" -mindepth 1 -maxdepth 1 -type d -empty -exec rmdir {} +
  fi
  mkdir -p "$d"
  printf '%s\n' "$SHARED_REPO" > "$d/$MARK"
}


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
    [ "$name" = "$MARK" ] || [ "$name" = "$STAMP" ] && continue
    owned "$name" && continue
    link "$e" "$dst/$name"
  done
}

if ! fresh_dir "$WT/node_modules"; then
  echo "link-node-modules: $WT/node_modules is a real install — left alone."
  exit 0
fi
# Gone until this run proves the links: a run that fails part-way is never "up to date".
rm -f "$WT/node_modules/$STAMP"
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
    printf '%s\n' "$WORKSPACES" | cut -f1 | grep -xF -- "$scope/${e##*/}" >/dev/null && continue
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
printf 'linked %s\n' "$FP" > "$WT/node_modules/$STAMP"

echo "link-node-modules: shared install linked into $WT/node_modules; $links workspace package(s) point at this worktree; $mirrored workspace node_modules mirrored."
