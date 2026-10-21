#!/usr/bin/env bash
# toolkit_spawn_root and toolkit_main_checkout_sane — where a spawned run starts,
# and the main checkout every build's push reads.
#
#   #278: the spawn checkout was keyed by commit alone, so with two clones of one
#   project on a machine a run for clone B started in clone A's checkout, resolved
#   MAIN_REPO to A, and ensure-hooks parked every build.
#   #277: an emptied package.json in the main checkout failed every builder's push
#   for 1.5 hours; nothing looked before the builds started.
#
# The functions are read out of toolkit-env.sh itself, so this tests the shipped text.
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/tests/lib/suite.sh" || exit 1
for v in $(env | sed -n 's/^\(GIT_[A-Z_]*\)=.*/\1/p'); do unset "$v"; done
ENV_SH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/toolkit-env.sh"
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "  ok   — $1"; }
fail() { FAIL=$((FAIL+1)); echo "  FAIL — $1"; }
for fn in _kit_spawn_held toolkit_main_checkout_sane toolkit_spawn_root; do
  FN=$(sed -n "/^$fn() {/,/^}/p" "$ENV_SH")
  [ -n "$FN" ] || { echo "  FAIL — toolkit-env.sh defines no $fn"; exit 1; }
  eval "$FN"
done

SB=$(mktemp -d "${TMPDIR:-/tmp}/spawn-root-test.XXXXXX"); SB=$(cd "$SB" && pwd -P)
on_exit_keep_status 'rm -rf "$SB"'
export TMPDIR="$SB/tmp"; mkdir -p "$TMPDIR"
G() { git -c user.email=t@example.com -c user.name=t -c commit.gpgsign=false -c init.defaultBranch=develop "$@"; }
INTEGRATION_BRANCH=develop
UP="$SB/up"; mkdir -p "$UP/apps/web"
printf '{"name":"root"}\n' > "$UP/package.json"
printf '{"name":"web"}\n' > "$UP/apps/web/package.json"
printf '{"lockfileVersion":3}\n' > "$UP/package-lock.json"
G -C "$UP" init -q && G -C "$UP" add -A && G -C "$UP" commit -qm init
G clone -q "$UP" "$SB/a"; G clone -q "$UP" "$SB/b"

echo "--- two clones of one repo at one commit get two spawn checkouts ---"
MAIN_REPO="$SB/a"; ra=$(toolkit_spawn_root 2>"$SB/err.a"); rca=$?
MAIN_REPO="$SB/b"; rb=$(toolkit_spawn_root 2>"$SB/err.b"); rcb=$?
[ "$rca" -eq 0 ] && [ "$rcb" -eq 0 ] && ok "both spawn" || fail "spawn failed: a=$rca b=$rcb $(cat "$SB/err.a" "$SB/err.b")"
[ -n "$ra" ] && [ "$ra" != "$rb" ] && ok "they are different checkouts" || fail "clone B reused clone A's checkout: $ra"
cb=$(git -C "$rb" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)
[ "$(cd "$cb" && pwd -P)" = "$SB/b/.git" ] && ok "clone B's checkout belongs to clone B" || fail "clone B's checkout belongs to $cb"
MAIN_REPO="$SB/a"; ra2=$(toolkit_spawn_root 2>/dev/null)
[ "$ra2" = "$ra" ] && ok "clone A at the same commit reuses its own" || fail "clone A did not reuse its checkout: $ra2"

echo "--- a checkout of the right name that belongs to another clone is rebuilt ---"
MAIN_REPO="$SB/b"
rm -rf "$rb"; git -C "$SB/b" worktree prune; git -C "$SB/a" worktree add -q --detach "$rb" HEAD; : > "$rb.ready"
rb2=$(toolkit_spawn_root 2>/dev/null)
cb=$(git -C "$rb2" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)
[ "$(cd "$cb" && pwd -P)" = "$SB/b/.git" ] && ok "rebuilt from clone B" || fail "handed back clone A's checkout ($cb)"

echo "--- an emptied package.json in the main checkout is restored before a run starts ---"
MAIN_REPO="$SB/a"
: > "$SB/a/package.json"
printf '{"name": ' > "$SB/a/apps/web/package.json"
cp "$SB/a/package-lock.json" "$SB/lock.before"
toolkit_spawn_root >/dev/null 2>"$SB/err"; rc=$?
[ "$rc" -eq 0 ] && ok "the spawn goes ahead" || fail "the spawn refused: $(cat "$SB/err")"
[ "$(cat "$SB/a/package.json")" = '{"name":"root"}' ] && ok "the root package.json is restored" || fail "root package.json is '$(cat "$SB/a/package.json")'"
jq empty "$SB/a/apps/web/package.json" 2>/dev/null && ok "the workspace package.json is restored" || fail "workspace package.json still invalid"
cmp -s "$SB/lock.before" "$SB/a/package-lock.json" && ok "a valid lockfile is left byte-identical" || fail "the valid lockfile was rewritten"
grep -q 'restored' "$SB/err" && ok "and it says so" || fail "nothing said: $(cat "$SB/err")"

echo "--- unmerged files in the main checkout refuse the spawn with the reason ---"
G -C "$SB/a" checkout -qb side
printf '{"name":"side"}\n' > "$SB/a/package.json"; G -C "$SB/a" commit -qam side
G -C "$SB/a" checkout -q develop
printf '{"name":"main"}\n' > "$SB/a/package.json"; G -C "$SB/a" commit -qam main
G -C "$SB/a" merge -q side >/dev/null 2>&1
out=$(toolkit_spawn_root 2>&1); rc=$?
[ "$rc" -ne 0 ] && ok "refused" || fail "spawned into a main checkout mid-merge: $out"
printf '%s' "$out" | grep -q 'unmerged' && ok "naming the unmerged files" || fail "no reason given: $out"

echo
echo "$PASS passed, $FAIL failed"
suite_end "$FAIL"
