#!/usr/bin/env bash
# builder-install.sh — every builder's tree gets an install of its own.
#
#   builder-install.sh <tree>               the tree's own node_modules, built now
#   builder-install.sh --if-stale <tree>    only when its manifests moved since it was built
#   builder-install.sh --behind <tree>      exit 0, saying how, when npm's record of the install
#                                           disagrees with the tree's lockfile; 1 when it agrees
#   builder-install.sh --fingerprint <tree> the key the install is stored under
#
# WHY OWN, NOT LINKED. Trees used to borrow the shared clone's node_modules by symlink. A
# workspace import then ran the shared checkout's copy of the package, one `npm install` in
# any tree rewrote every peer's install mid-build, and the harness grew a hook per way of
# stepping on it (npm install, add -A of the link, a shared install that held every start
# while it waited for builds to drain). A tree with its own node_modules has nothing to share.
#
# CHEAP BECAUSE IT IS CONTENT-ADDRESSED. An install is keyed on what it is built from — the
# lockfile, the root package.json, each workspace's package.json, the platform and the node
# major — and kept once in the store (BUILDER_INSTALL_STORE, ~/.cache/agent-harness/installs).
# A tree whose key the store holds gets a copy-on-write clone of it: one clonefile(2) of the
# whole directory on APFS, `cp --reflink=always` on btrfs/xfs. Measured on the Mac on
# 2026-11-04 for the origin project (1.76 GB, 120,644 files): `npm ci --prefer-offline`
# 20 s and 1.8 GB; a clone 5.5 s and 44 MB, measured in an APFS image of its own. A key
# the store lacks is installed (worktree.install, else `npm ci --prefer-offline`) and then
# stored by clone, so the next tree on that lockfile pays the 5.5 s. Where nothing can clone
# (ext4, NTFS) every tree installs and nothing is stored: a full copy would cost what an
# install does.
#
# A clone is the tree's own: writing into it never reaches the store or a peer. The store
# keeps BUILDER_INSTALL_KEEP (3) keys, newest used first; removing one never touches a
# clone made from it.
#
# CHECKED BEFORE IT IS STAMPED. An install that exits 0 can still lack packages (2026-10-23:
# 379 missing after a clean exit), so the stamp — node_modules/.harness-install-stamp,
# "own <key>" — is written only when npm's record agrees with the lockfile and each workspace
# package resolves to this tree's own directory for it.
#
# Exit 0 installed, up to date, or nothing to install · 1 the install failed, or the arguments.
set -uo pipefail
STAMP=".harness-install-stamp"
say() { echo "builder-install: $*" >&2; }

# install_drift <tree> — how many packages the lockfile declares that npm's record lacks or
# holds at another version; nothing when either record is missing (cannot tell).
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

# workspaces <tree> — "<package name>\t<dir>" for each workspace the root package.json declares.
workspaces() {
  node -e '
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
  ' "$1"
}

# fingerprint <tree> — sha256 of everything the install is built from.
fingerprint() {
  workspaces "$1" | cut -f2 | node -e '
    const fs = require("fs"), path = require("path"), crypto = require("crypto")
    const wt = process.argv[1]
    const h = crypto.createHash("sha256")
    const add = (label, f) => { let c = "<absent>"; try { c = fs.readFileSync(f) } catch {} ; h.update(label + "\0"); h.update(c); h.update("\0") }
    h.update(process.platform + "-" + process.arch + "-node" + process.versions.node.split(".")[0] + "\0")
    add("lock", path.join(wt, "package-lock.json"))
    add("package.json", path.join(wt, "package.json"))
    for (const d of fs.readFileSync(0, "utf8").split("\n").filter(Boolean)) add(d, path.join(wt, d, "package.json"))
    process.stdout.write(h.digest("hex"))
  ' "$1"
}

# clone_dir <src> <dst> — a copy-on-write clone; 1 when this filesystem cannot make one.
clone_dir() {
  case "${BUILDER_INSTALL_CLONE:-auto}" in
    off) return 1 ;;
    copy) cp -R "$1" "$2" 2>/dev/null && return 0; rm -rf "$2"; return 1 ;;   # tests: the store path on any filesystem
  esac
  case "$(uname -s 2>/dev/null)" in
    Darwin)
      if command -v python3 >/dev/null 2>&1 && python3 -c '
import ctypes, sys
libc = ctypes.CDLL("libc.dylib", use_errno=True)
sys.exit(0 if libc.clonefile(sys.argv[1].encode(), sys.argv[2].encode(), 0) == 0 else 1)' "$1" "$2" 2>/dev/null; then
        return 0
      fi
      rm -rf "$2"; cp -cR "$1" "$2" 2>/dev/null && return 0 ;;
    Linux)
      cp -a --reflink=always "$1" "$2" 2>/dev/null && return 0 ;;
  esac
  rm -rf "$2"
  return 1
}

# with_timeout <sec> <cmd…> — in a process group of its own, killed whole at the limit (124).
with_timeout() {
  perl -e '$t = shift; $p = fork; die "fork" unless defined $p;
    if ($p == 0) { setpgrp(0, 0); exec @ARGV or exit 127 }
    $SIG{ALRM} = sub { kill "TERM", -$p; sleep 3; kill "KILL", -$p; exit 124 };
    alarm $t; waitpid($p, 0); exit($? & 127 ? 128 + ($? & 127) : $? >> 8)' "$@"
}

# install_cmd <tree> — the project's install, else npm ci with the project's age rule lifted:
# a lockfile install takes only the versions the lock pins, so the cutoff guards nothing there.
install_cmd() {
  local cfg="${HARNESS_CFG_PATH:-$1/.claude/harness.json}" c="" age=""
  if [ -n "${BUILDER_INSTALL_CMD:-}" ]; then printf '%s' "$BUILDER_INSTALL_CMD"; return; fi
  [ -f "$cfg" ] && c=$(jq -r '.worktree.install // empty' "$cfg" 2>/dev/null)
  if [ -n "$c" ]; then printf '%s' "$c"; return; fi
  if [ -f "$1/.npmrc" ]; then
    grep -qE '^[[:space:]]*min-release-age[[:space:]]*=' "$1/.npmrc" && age=" --min-release-age=0"
    grep -qE '^[[:space:]]*before[[:space:]]*=' "$1/.npmrc" && age="$age --before=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  fi
  printf 'npm ci --prefer-offline --no-audit --no-fund%s' "$age"
}

# nm_dirs <tree> — the install's directories, relative: the root's and each workspace's.
nm_dirs() {
  echo node_modules
  workspaces "$1" | cut -f2 | while IFS= read -r d; do [ -n "$d" ] && echo "$d/node_modules"; done
}

# drop_install <tree> — every node_modules the install owns, whatever shape the last one had.
# A link is removed as a link (its target is not this tree's); rm -r never follows one.
drop_install() {
  local d
  while IFS= read -r d; do
    [ -n "$d" ] || continue
    if [ -L "$1/$d" ]; then rm -f "$1/$d"; elif [ -e "$1/$d" ]; then rm -rf "${1:?}/$d"; fi
  done <<<"$(nm_dirs "$1")"
}

# verify <tree> — npm's record agrees with the lockfile and every workspace is this tree's own.
verify() {
  local n name dir bad=0
  [ -d "$1/node_modules" ] && [ ! -L "$1/node_modules" ] || { say "$1/node_modules is not a directory of its own"; return 1; }
  n=$(install_drift "$1"); n=${n:-0}
  [ "$n" -eq 0 ] 2>/dev/null || { say "$n package(s) $1/package-lock.json declares are missing from the install or at another version"; return 1; }
  while IFS=$'\t' read -r name dir; do
    [ -n "$name" ] || continue
    if [ -e "$1/node_modules/$name" ] && ! [ "$1/node_modules/$name" -ef "$1/$dir" ]; then
      say "$name does not resolve to $dir in this tree"; bad=1
    fi
  done <<<"$(workspaces "$1")"
  return "$bad"
}

# store_put <tree> <key> — the tree's install kept under <key>, by clone; nothing when it cannot clone.
store_put() {
  local store="$1" tree="$2" key="$3" tmp d
  [ -d "$store/$key" ] && return 0
  mkdir -p "$store" 2>/dev/null || return 0
  tmp="$store/.tmp-$key-$$"
  rm -rf "$tmp"; mkdir -p "$tmp" || return 0
  while IFS= read -r d; do
    [ -n "$d" ] && [ -d "$tree/$d" ] || continue
    mkdir -p "$(dirname "$tmp/$d")"
    clone_dir "$tree/$d" "$tmp/$d" || { rm -rf "$tmp"; return 0; }
  done <<<"$(nm_dirs "$tree")"
  rm -rf "$tmp/node_modules/.cache" "$tmp/node_modules/$STAMP"
  : > "$tmp/.complete"
  # A peer storing the same key first wins; this copy goes.
  # rename(2) onto a directory that exists fails, where mv would move this one inside it.
  perl -e 'rename $ARGV[0], $ARGV[1] or exit 1' "$tmp" "$store/$key" 2>/dev/null || rm -rf "$tmp"
}

# store_get <store> <tree> <key> — the stored install cloned into the tree; 1 when it is not stored.
store_get() {
  local store="$1" tree="$2" key="$3" d
  [ -f "$store/$key/.complete" ] || return 1
  while IFS= read -r d; do
    [ -n "$d" ] && [ -d "$store/$key/$d" ] || continue
    mkdir -p "$(dirname "$tree/$d")"
    clone_dir "$store/$key/$d" "$tree/$d" || { drop_install "$tree"; return 1; }
  done <<<"$(nm_dirs "$tree")"
  touch "$store/$key/.complete"
  return 0
}

# store_prune <store> — keep the newest-used BUILDER_INSTALL_KEEP keys. Ages come from the
# .complete stamp (stat, never find -newer: bfs reads its date forms differently).
store_prune() {
  local store="$1" keep="${BUILDER_INSTALL_KEEP:-3}" list n
  [ -d "$store" ] || return 0
  case "$keep" in ''|*[!0-9]*) keep=3 ;; esac
  list=$(for d in "$store"/*/; do
    d=${d%/}; [ -f "$d/.complete" ] || continue
    printf '%s\t%s\n' "$(stat -f %m "$d/.complete" 2>/dev/null || stat -c %Y "$d/.complete" 2>/dev/null || echo 0)" "$d"
  done | sort -rn | awk -F'\t' -v k="$keep" 'NR > k { print $2 }')
  [ -n "$list" ] || return 0
  n=$(printf '%s\n' "$list" | grep -c .)
  say "store: removing $n install(s) past the newest $keep"
  while IFS= read -r d; do
    case "$d" in "$store"/*) rm -rf "$d" ;; esac
  done <<<"$list"
}

mode=build
case "${1:-}" in
  --if-stale) mode=stale; shift ;;
  --behind) mode=behind; shift ;;
  --fingerprint) mode=fp; shift ;;
esac
TREE="${1:-}"
[ -n "$TREE" ] && [ -d "$TREE" ] || { echo "usage: builder-install.sh [--if-stale|--behind|--fingerprint] <tree>" >&2; exit 1; }
TREE=$(cd "$TREE" && pwd -P)

if [ "$mode" = behind ]; then
  n=$(install_drift "$TREE"); n=${n:-0}
  [ "$n" -gt 0 ] 2>/dev/null || exit 1
  echo "$n package(s) $TREE/package-lock.json declares are missing from $TREE/node_modules or installed there at another version"
  exit 0
fi

[ -f "$TREE/package.json" ] || { say "$TREE has no package.json — nothing to install."; exit 0; }
command -v node >/dev/null 2>&1 || { say "node is not on PATH"; exit 1; }
KEY=$(fingerprint "$TREE")
[ -n "$KEY" ] || { say "could not fingerprint $TREE"; exit 1; }
[ "$mode" = fp ] && { echo "$KEY"; exit 0; }

if [ "$mode" = stale ] && [ "$(cat "$TREE/node_modules/$STAMP" 2>/dev/null)" = "own $KEY" ] && [ ! -L "$TREE/node_modules" ]; then
  echo "builder-install: $TREE/node_modules is up to date with its manifests — nothing to do."
  exit 0
fi

STORE="${BUILDER_INSTALL_STORE:-$HOME/.cache/agent-harness/installs}"
t0=$(date +%s)
drop_install "$TREE"
how=""
if store_get "$STORE" "$TREE" "$KEY" && verify "$TREE"; then
  how="cloned from the store"
else
  drop_install "$TREE"
  cmd=$(install_cmd "$TREE")
  say "installing $TREE's own dependencies: $cmd"
  # shellcheck disable=SC2086 # the command is a word list, as the project wrote it
  (cd "$TREE" && with_timeout "${BUILDER_INSTALL_TIMEOUT_SEC:-1200}" bash -c "$cmd") >&2 \
    || { say "the install failed in $TREE"; exit 1; }
  verify "$TREE" || { say "the install in $TREE exited 0 but does not match its lockfile"; exit 1; }
  how="installed"
  store_put "$STORE" "$TREE" "$KEY"
fi
printf 'own %s\n' "$KEY" > "$TREE/node_modules/$STAMP"
store_prune "$STORE"
echo "builder-install: $TREE has its own install ($how, $(( $(date +%s) - t0 )) s)."
exit 0
