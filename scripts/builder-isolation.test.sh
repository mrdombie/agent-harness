#!/usr/bin/env bash
# builder-isolation.test.sh — two builders in one repo install, test and serve without
# touching each other's files or processes (builder-install.sh, builder-dev.sh).
#
# A real npm-workspaces fixture (no registry packages, so `npm ci --offline` runs
# anywhere), two worktrees of one scratch repo, each with its own install and its own
# dev server — a node server that starts a child of its own, so "the group" is more than
# one process. Then one plant per rule, each of which must turn its case red.
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/tests/lib/suite.sh" || exit 1
# Scratch git must never be aimed at a real repo by a hook's GIT_* environment.
for v in $(env | sed -n 's/^\(GIT_[A-Z_]*\)=.*/\1/p'); do unset "$v"; done
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
command -v node >/dev/null 2>&1 && command -v npm >/dev/null 2>&1 || suite_skip "no node/npm on this host"
command -v perl >/dev/null 2>&1 || suite_skip "no perl on this host"

FAIL=0
ok()  { echo "  ok   — $1"; }
bad() { echo "  FAIL — $1"; FAIL=1; }
want() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (want '$2', got '$3')"; fi; }

T=$(cd "$(mktemp -d)" && pwd -P)
export BUILDER_DEV_DIR="$T/dev" BUILDER_INSTALL_STORE="$T/store" BUILDER_INSTALL_CLONE=copy
export BUILDER_DEV_BASE_PORT=$(( 20000 + RANDOM % 20000 )) BUILDER_DEV_STOP_SEC=5
export HOME="$T/home"; mkdir -p "$HOME"
export npm_config_cache="$T/npm-cache"
cleanup() {
  local r
  for r in "$T"/dev/*/pgid; do [ -f "$r" ] && kill -KILL -- "-$(cat "$r")" 2>/dev/null; done
  rm -rf "$T"
}
on_exit_keep_status cleanup

# --- the fixture: a root with one workspace, a test, and a dev server --------------------
R="$T/repo"; mkdir -p "$R/packages/lib"
cat > "$R/package.json" <<'J'
{ "name": "fx-root", "private": true, "workspaces": ["packages/*"],
  "scripts": { "test": "node test.js", "dev": "node server.js" } }
J
printf '{ "name": "@fx/lib", "version": "1.0.0", "main": "index.js" }\n' > "$R/packages/lib/package.json"
printf 'module.exports = "v1"\n' > "$R/packages/lib/index.js"
cat > "$R/test.js" <<'JS'
const v = require("@fx/lib")
require("fs").writeFileSync("node_modules/.ran-here", v)
console.log("lib=" + v + " in " + require.resolve("@fx/lib"))
JS
# The server starts a child of its own: the group is more than one process.
cat > "$R/server.js" <<'JS'
const { spawn } = require("child_process")
const child = spawn("sleep", ["300"], { stdio: "ignore" })
require("fs").writeFileSync(".child-pid", String(child.pid))
require("http").createServer((q, s) => s.end(require("path").basename(process.cwd()))).listen(+process.env.PORT)
JS
printf 'node_modules\n.child-pid\n' > "$R/.gitignore"
(cd "$R" && npm install --offline --no-audit --no-fund >/dev/null 2>&1) || suite_skip "npm could not write the fixture's lockfile offline"
rm -rf "$R/node_modules"
git -C "$R" init -q -b main && git -C "$R" add -A && git -C "$R" -c user.name=t -c user.email=t@t commit -qm fixture
A="$T/wt/sh-100-a"; B="$T/wt/sh-1100-b"   # same ticket port base (100 mod 1000): the reservation decides
git -C "$R" worktree add -q --detach "$A" HEAD && git -C "$R" worktree add -q --detach "$B" HEAD
fixture_path A "$T"; fixture_path B "$T"
export BUILDER_INSTALL_CMD="npm ci --offline --no-audit --no-fund"

INST="$HERE/builder-install.sh"; DEV="$HERE/builder-dev.sh"
inst() { bash "${INST_SUT:-$INST}" "$@" 2>&1; }
dev()  { bash "${DEV_SUT:-$DEV}" "$@" 2>/dev/null; }
get()  { node -e 'require("http").get(process.argv[1], r => { let b = ""; r.on("data", d => b += d); r.on("end", () => process.stdout.write(b)) }).on("error", () => process.stdout.write("refused"))' "$1"; }
alive() { kill -0 "$1" 2>/dev/null && echo alive || echo gone; }
kb() { du -sk "$1" 2>/dev/null | cut -f1; }

# --- the cases (each one a function, so a plant can run it again) ----------------------
case_own_install() {
  rm -rf "$BUILDER_INSTALL_STORE"
  inst "$A" >/dev/null; inst "$B" > "$T/b.out"
  printf '%s|%s|%s|%s' \
    "$([ -d "$A/node_modules" ] && [ ! -L "$A/node_modules" ] && echo dir || echo link)" \
    "$([ "$A/node_modules/@fx/lib" -ef "$A/packages/lib" ] && [ "$B/node_modules/@fx/lib" -ef "$B/packages/lib" ] && echo own || echo shared)" \
    "$(touch "$A/node_modules/.only-a"; [ -e "$B/node_modules/.only-a" ] && echo leaked || echo apart)" \
    "$(grep -q 'cloned from the store' "$T/b.out" && echo stored || echo installed)"
}
case_tests_apart() {
  printf 'module.exports = "v2-a"\n' > "$A/packages/lib/index.js"
  printf '%s|%s' "$(cd "$A" && npm test --silent 2>/dev/null | sed -n 's/^lib=\([^ ]*\).*/\1/p')" \
                 "$(cd "$B" && npm test --silent 2>/dev/null | sed -n 's/^lib=\([^ ]*\).*/\1/p')"
  printf 'module.exports = "v1"\n' > "$A/packages/lib/index.js"
}
case_if_stale() {
  local one two
  one=$(inst --if-stale "$A" | grep -c 'nothing to do')
  printf '{ "name": "@fx/lib", "version": "1.0.1", "main": "index.js" }\n' > "$A/packages/lib/package.json"
  two=$(inst --if-stale "$A" | grep -c 'nothing to do')
  printf '{ "name": "@fx/lib", "version": "1.0.0", "main": "index.js" }\n' > "$A/packages/lib/package.json"; inst "$A" >/dev/null
  printf '%s|%s' "$one" "$two"
}
case_unverified() {
  local out rc
  out=$(BUILDER_INSTALL_STORE="$T/empty-store" BUILDER_INSTALL_CMD=true inst "$B"); rc=$?
  printf '%s|%s' "$rc" "$([ -f "$B/node_modules/.harness-install-stamp" ] && echo stamped || echo none)"
  inst "$B" >/dev/null
}
case_servers_apart() {
  local ua ub ga gb ca cb pa pb
  dev start "$A" > "$T/ua" & dev start "$B" > "$T/ub" & wait
  ua=$(cat "$T/ua"); ub=$(cat "$T/ub")
  for _ in $(seq 1 40); do [ -s "$A/.child-pid" ] && [ -s "$B/.child-pid" ] && [ "$(get "$ua")" != refused ] && [ "$(get "$ub")" != refused ] && break; sleep 0.25; done
  pa=${ua##*:}; pb=${ub##*:}
  ga=$(cat "$BUILDER_DEV_DIR/$pa/pgid" 2>/dev/null); gb=$(cat "$BUILDER_DEV_DIR/$pb/pgid" 2>/dev/null)
  ca=$(cat "$A/.child-pid" 2>/dev/null); cb=$(cat "$B/.child-pid" 2>/dev/null)
  printf '%s|%s|%s|' "$([ -n "$pa" ] && [ "$pa" != "$pb" ] && echo ports-apart || echo same-port)" "$(get "$ua")" "$(get "$ub")"
  dev stop "$A" >/dev/null
  printf '%s|%s|%s|%s|%s' "$(alive "${ga:-0}")" "$(alive "${ca:-0}")" "$(alive "${gb:-0}")" "$(alive "${cb:-0}")" "$(get "$ub")"
  dev stop "$B" >/dev/null
  rm -f "$A/.child-pid" "$B/.child-pid"
}

echo "--- two builders, one repo: each has its own install ---"
got=$(case_own_install)
want "A's node_modules is a directory of its own, not a link" "dir" "$(cut -d'|' -f1 <<<"$got")"
want "each tree's workspace package resolves to its own source" "own" "$(cut -d'|' -f2 <<<"$got")"
want "a write into A's install never reaches B's" "apart" "$(cut -d'|' -f3 <<<"$got")"
want "B, on A's lockfile, is cloned from the store instead of installing again" "stored" "$(cut -d'|' -f4 <<<"$got")"

echo "--- …and runs its tests against its own code ---"
want "A runs A's edit, B still runs v1" "v2-a|v1" "$(case_tests_apart)"
want "each test wrote into its own install only" "v2-a|v1" "$(cat "$A/node_modules/.ran-here" 2>/dev/null)|$(cat "$B/node_modules/.ran-here" 2>/dev/null)"

echo "--- the install is rebuilt only when its manifests move ---"
want "unchanged: nothing to do; a package.json moved: rebuilt" "1|0" "$(case_if_stale)"

echo "--- an install that exits 0 but does not match its lockfile is refused ---"
want "exit 1 and no stamp" "1|none" "$(case_unverified)"

echo "--- each builder's dev server is its own process group ---"
got=$(case_servers_apart)
want "two starts at once on one port base take two ports" "ports-apart" "$(cut -d'|' -f1 <<<"$got")"
want "A's server serves A, B's serves B" "sh-100-a|sh-1100-b" "$(cut -d'|' -f2,3 <<<"$got")"
want "stopping A stops A's server and the child it started" "gone|gone" "$(cut -d'|' -f4,5 <<<"$got")"
want "…and leaves B's server, its child and its answers alone" "alive|alive|sh-1100-b" "$(cut -d'|' -f6,7,8 <<<"$got")"
want "nothing is left recorded" "" "$(dev list)"

echo "--- disk per builder ---"
echo "  disk: A node_modules $(kb "$A/node_modules") KB, B node_modules $(kb "$B/node_modules") KB, store $(kb "$BUILDER_INSTALL_STORE") KB (copy mode here; a copy-on-write clone shares the store's blocks)"
[ -n "$(kb "$A/node_modules")" ] && ok "disk per builder measured" || bad "disk per builder could not be measured"

# --- plants: each rule removed, its case must go red -------------------------------------
echo "--- plants ---"
K="$T/kit"; mkdir -p "$K"
plant() { # <name> <file> <from> <to> <case> <green>
  local f="$K/$2" n got
  cp "$HERE/$2" "$f"
  n=$(F="$3" TO="$4" perl -0pi -e '$c = s/\Q$ENV{F}\E/$ENV{TO}/g; END { print STDERR $c }' "$f" 2>&1 >/dev/null)
  [ "${n:-0}" -gt 0 ] || { bad "plant '$1' did not land"; return; }
  grep -qF -- "$3" "$f" && { bad "plant '$1' left the original in place"; return; }
  got=$(INST_SUT="$K/builder-install.sh" DEV_SUT="$K/builder-dev.sh" "$5")
  [ "$got" != "$6" ] && ok "plant '$1' turns its case red ($got)" || bad "plant '$1' survived: the case still reads $got"
  cp "$HERE/$2" "$f"
}
cp "$INST" "$DEV" "$K/"
GREEN_OWN="dir|own|apart|stored"
plant "a clone is a link"          builder-install.sh 'cp -R "$1" "$2" 2>/dev/null && return 0' 'ln -s "$1" "$2" && return 0' case_own_install "$GREEN_OWN"
plant "nothing is stored"          builder-install.sh '  [ -d "$store/$key" ] && return 0' '  return 0' case_own_install "$GREEN_OWN"
plant "no rebuild check"           builder-install.sh 'if [ "$mode" = stale ] && ' 'if false && ' case_if_stale "1|0"
plant "unverified stamp"           builder-install.sh '  verify "$TREE" || { say "the install in $TREE exited 0' '  true || { say "the install in $TREE exited 0' case_unverified "1|none"
GREEN_DEV="ports-apart|sh-100-a|sh-1100-b|gone|gone|alive|alive|sh-1100-b"
plant "no group of its own"        builder-dev.sh "exec perl -e 'setpgrp(0, 0); exec @ARGV or exit 127'" "exec perl -e 'exec @ARGV or exit 127'" case_servers_apart "$GREEN_DEV"
plant "stop reaches a peer"        builder-dev.sh '  kill -TERM -- "-$g" 2>/dev/null' '  for x in "$DEV_DIR"/*/pgid; do kill -TERM -- "-$(cat "$x")" 2>/dev/null; done' case_servers_apart "$GREEN_DEV"
plant "the port is not reserved"   builder-dev.sh '  mkdir "$DEV_DIR/$cand" 2>/dev/null || continue' '  mkdir -p "$DEV_DIR/$cand"' case_servers_apart "$GREEN_DEV"
for r in "$T"/dev/*/pgid; do [ -f "$r" ] && kill -KILL -- "-$(cat "$r")" 2>/dev/null; done
rm -rf "${BUILDER_DEV_DIR:?}"/*

suite_end "$FAIL"
