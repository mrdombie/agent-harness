#!/usr/bin/env bash
# proof-fresh-install.test.sh — a proof tree whose install is not its own lockfile's is
# installed fresh once and proved, never parked as the change's failure. Measured
# 2026-11-08 on the origin project: two proofs cloned a stored install into the tree
# without the change, worktree.prepare (prisma:ensure) found no prisma bin (127) or another
# prisma (2), and both tickets parked as if the change had failed.
#
# The install command is a stand-in registry: it writes prisma with its bin and npm's
# record of it, as npm ci does. The store is a plain copy (BUILDER_INSTALL_CLONE=copy).
# Run: bash "$0"
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/tests/lib/suite.sh" || exit 1
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
. "$HERE/fixture.sh"
driver_fixture; on_exit_keep_status 'rm -rf "$FIX"'
. "$HERE/../steps/build.sh" || exit 1
command -v node >/dev/null 2>&1 || suite_skip "no node on this host"

cat > "$FIX/fake-install" <<'SH'
#!/usr/bin/env bash
mkdir -p node_modules/prisma node_modules/.bin
printf '{"name":"prisma","version":"7.10.1","bin":{"prisma":"cli.sh"}}\n' > node_modules/prisma/package.json
printf '#!/usr/bin/env bash\n[ "$1" = generate ] && echo generated\n' > node_modules/prisma/cli.sh
chmod +x node_modules/prisma/cli.sh
ln -sf ../prisma/cli.sh node_modules/.bin/prisma
jq '{lockfileVersion: 3, packages: (.packages | with_entries(select(.key != "")))}' package-lock.json > node_modules/.package-lock.json
echo "fake install in $PWD" >> "$FAKE_INSTALL_LOG"
SH
chmod +x "$FIX/fake-install"
export BUILDER_INSTALL_CMD="$FIX/fake-install" FAKE_INSTALL_LOG="$FIX/installs.log" \
  BUILDER_INSTALL_STORE="$FIX/store" BUILDER_INSTALL_CLONE=copy
: > "$FAKE_INSTALL_LOG"
jq '.worktree = ((.worktree // {}) + {prepare: ["./node_modules/.bin/prisma generate"]})' "$HARNESS_CFG_PATH" > "$FIX/cfg.json"
export HARNESS_CFG="$FIX/cfg.json" HARNESS_CFG_PATH="$FIX/cfg.json"

printf '{"name":"fx","private":true,"devDependencies":{"prisma":"7.10.1"}}\n' > "$REPO/package.json"
printf '{"lockfileVersion":3,"packages":{"":{"name":"fx"},"node_modules/prisma":{"version":"7.10.1","dev":true,"bin":{"prisma":"cli.sh"}}}}\n' > "$REPO/package-lock.json"
printf 'node_modules/\n' > "$REPO/.gitignore"
git -C "$REPO" add -A; git -C "$REPO" commit -qm "fixture: prisma"

task() { # <n> — a test commit, then the change it proves
  printf '#!/usr/bin/env bash\ngrep -q "f%s=yes" f%s.txt\n' "$1" "$1" > "$REPO/f$1.test.sh"
  printf 'f%s=no\n' "$1" > "$REPO/f$1.txt"
  git -C "$REPO" add -A; git -C "$REPO" commit -qm "test: f$1"; TS=$(git -C "$REPO" rev-parse HEAD)
  printf 'f%s=yes\n' "$1" > "$REPO/f$1.txt"; git -C "$REPO" add -A; git -C "$REPO" commit -qm "feat: f$1"; IS=$(git -C "$REPO" rev-parse HEAD)
}
prove() { OUT=$(driver_prove_red_green "$REPO" "f$1.test.sh" "$TS" "$IS" "bash f$1.test.sh" 2>&1); RC=$?; }
KEY=$(bash "$ROOT/scripts/builder-install.sh" --fingerprint "$REPO")
# poison [record] — the stored install for this lockfile with prisma's bin gone; "record"
# also takes the bin out of npm's record, so nothing short of running prepare can tell.
poison() {
  rm -rf "$BUILDER_INSTALL_STORE"; mkdir -p "$FIX/seed"; cp "$REPO/package.json" "$REPO/package-lock.json" "$FIX/seed/"
  bash "$ROOT/scripts/builder-install.sh" "$FIX/seed" 2>/dev/null >/dev/null; rm -rf "$FIX/seed"
  rm -f "$BUILDER_INSTALL_STORE/$KEY/node_modules/.bin/prisma"
  [ "${1:-}" != record ] || { jq 'del(.packages["node_modules/prisma"].bin)' "$BUILDER_INSTALL_STORE/$KEY/node_modules/.package-lock.json" > "$FIX/rec.json" \
    && mv "$FIX/rec.json" "$BUILDER_INSTALL_STORE/$KEY/node_modules/.package-lock.json"; }
}
installs() { grep -c . "$FAKE_INSTALL_LOG"; }

echo "--- the tree without the change clones an install with no prisma bin: installed fresh, and proved ---"
export DRIVER_TICKET=611
poison record; task 1; n0=$(installs); prove 1
want "it proves red then green"            "0" "$RC"
want_in "it says it installed fresh"       'installing it fresh, once .*not the change' "$OUT"
want_in "and that the fresh install held"  'prepared on a fresh install' "$OUT"
want "one fresh install, for the before tree" "1" "$(( $(installs) - n0 ))"
want "the before tree has prisma's bin"    "yes" "$([ -e "$(_driver_proof_reuse_dir)/before/node_modules/.bin/prisma" ] && echo yes || echo no)"
want "the broken stored install is replaced" "yes" "$([ -e "$BUILDER_INSTALL_STORE/$KEY/node_modules/.bin/prisma" ] && echo yes || echo no)"
driver_proof_trees_drop

echo "--- a tree that will not prepare even fresh is a driver fault, not the change ---"
jq '.worktree.prepare = ["sh -c \"exit 4\""]' "$FIX/cfg.json" > "$FIX/bad.json"
export DRIVER_TICKET=612
task 2; OUT=$(HARNESS_CFG="$FIX/bad.json" driver_prove_red_green "$REPO" f2.test.sh "$TS" "$IS" "bash f2.test.sh" 2>&1); RC=$?
want "the proof says it could not be taken"  "5" "$RC"
want_in "named the driver's"                 'a driver fault, not the change: the tree without the change could not be prepared' "$OUT"
want_in "after the one fresh try"            'failed again on a fresh install' "$OUT"
want_not_in "it never blames the change"     'does not test it|still fails with the change' "$OUT"
driver_proof_trees_drop

echo "--- the store copy npm's record says holds a bin it lacks: dropped, installed instead ---"
poison; mkdir -p "$FIX/t3"; cp "$REPO/package.json" "$REPO/package-lock.json" "$FIX/t3/"; n0=$(installs)
out=$(bash "$ROOT/scripts/builder-install.sh" "$FIX/t3" 2>&1); rc=$?
want "the install succeeds"               "0" "$rc"
want_in "it names the copy as broken"     'have no files or a missing bin' "$out"
want_in "and drops it from the store"     "dropping $KEY" "$out"
want "it installed instead of cloning"    "1" "$(( $(installs) - n0 ))"
want "the tree has prisma's bin"          "yes" "$([ -e "$FIX/t3/node_modules/.bin/prisma" ] && echo yes || echo no)"

echo "--- plant: the fresh retry deleted, the same tree parks as an unprepared proof ---"
_driver_proof_prepare() { driver_prepare_worktree "$1" >&2; }
export DRIVER_TICKET=613
poison record; task 4; prove 4
want "planted: the proof is not taken"      "5" "$RC"
want_not_in "planted: nothing installs fresh" 'installing it fresh' "$OUT"
driver_proof_trees_drop

echo "--- plant: the holes check deleted, the broken copy is cloned and kept ---"
sed 's/^  n=\$(install_holes "\$1"); n=\${n:-0}$/  n=0/' "$ROOT/scripts/builder-install.sh" > "$FIX/bi-planted.sh"
want "the plant landed" "0" "$(grep -c 'install_holes "\$1"' "$FIX/bi-planted.sh")"
poison; rm -rf "$FIX/t5"; mkdir -p "$FIX/t5"; cp "$REPO/package.json" "$REPO/package-lock.json" "$FIX/t5/"
bash "$FIX/bi-planted.sh" "$FIX/t5" >/dev/null 2>&1
want "planted: the tree has no prisma bin" "no" "$([ -e "$FIX/t5/node_modules/.bin/prisma" ] && echo yes || echo no)"

suite_end "$FAILED"
