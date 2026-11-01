#!/usr/bin/env bash
# fixture-path.test.sh — a suite whose read-back path comes back empty stops, and never touches the clone it runs from.
# `git -C ""` is the current directory. trial2's worktree path came back empty and the
# suite committed the operator's uncommitted work onto their branch and pointed their
# hooks at an always-fail pre-push. Here the operator is a scratch repo, the suite is
# the real trial2 run from a copy of this kit with start forced to cut no worktree.
# Run: bash "$0"
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/tests/lib/suite.sh" || exit 1
for v in $(env | sed -n 's/^\(GIT_[A-Z_]*\)=.*/\1/p'); do unset "$v"; done
KIT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SB=$(mktemp -d "${TMPDIR:-/tmp}/fixture-path-test.XXXXXX"); SB=$(cd "$SB" && pwd -P)
on_exit_keep_status 'rm -rf "$SB"'
fail=0
ok()  { echo "  ok   — $1"; }
bad() { echo "  FAIL — $1"; fail=1; }

# held <value> <root> — runs fixture_path in a suite of its own; prints its exit code
held() {
  printf '#!/usr/bin/env bash\n. "%s/tests/lib/suite.sh"\nP=%q\nfixture_path P %q\necho went-on\n' "$KIT" "$1" "$2" > "$SB/h.test.sh"
  bash "$SB/h.test.sh" > "$SB/h.out" 2>&1; echo $?
}

echo "--- fixture_path holds a path to its root ---"
mkdir -p "$SB/root/a" "$SB/elsewhere"; ln -s "$SB/root" "$SB/link"
r=$(held "" "$SB/root"); [ "$r" != 0 ] && ! grep -q went-on "$SB/h.out" && ok "an empty path stops the suite (exit $r)" || bad "an empty path went on: $(cat "$SB/h.out")"
grep -q 'is empty' "$SB/h.out" && grep -q '^SUITE-END h.test.sh: FAIL' "$SB/h.out" && ok "and says so in a failing summary line" || bad "no refusal: $(cat "$SB/h.out")"
r=$(held "$SB/elsewhere" "$SB/root"); [ "$r" != 0 ] && ! grep -q went-on "$SB/h.out" && ok "a path outside the root stops it" || bad "a path outside the root went on"
r=$(held "$SB/rootx/a" "$SB/root"); [ "$r" != 0 ] && ok "a sibling sharing the root's name as a prefix is outside it" || bad "\$SB/rootx passed as inside \$SB/root"
r=$(held "$SB/root/a" ""); [ "$r" != 0 ] && ok "no root stops it" || bad "no root went on"
r=$(held "$SB/root/a" "$SB/root"); [ "$r" = 0 ] && grep -q went-on "$SB/h.out" && ok "a path inside goes on" || bad "a path inside stopped: $(cat "$SB/h.out")"
r=$(held "$SB/link/a" "$SB/root"); [ "$r" = 0 ] && ok "and so does one reached through a link to the root" || bad "a linked path inside stopped: $(cat "$SB/h.out")"

echo "--- trial2 with no worktree from start: it stops, and the operator's clone is untouched ---"
OP="$SB/operator"
git init -q -b work "$OP"
printf 'committed\n' > "$OP/a.txt"
git -C "$OP" add a.txt && git -C "$OP" -c user.email=o@e.invalid -c user.name=O commit -qm "the operator's work"
printf 'not yet committed\n' > "$OP/b.txt"; git -C "$OP" add b.txt
printf 'still editing\n' >> "$OP/a.txt"
snap() { # the operator's clone, as the operator would check it
  git -C "$OP" rev-parse HEAD
  git -C "$OP" config --get core.hooksPath || echo "<no hooksPath>"
  git -C "$OP" status --porcelain
  cksum < "$OP/.git/index"
  cksum < "$OP/.git/config"
}
before=$(snap)

mkdir -p "$SB/kit"
(cd "$KIT" && tar -cf - --exclude=.git .) | (cd "$SB/kit" && tar -xf -)
# Start finishes and records no worktree, as it did on the machine that measured it.
cat >> "$SB/kit/driver/steps/start.sh" <<'SH'
eval "__planted_real_$(declare -f driver_step_start)"
driver_step_start() { [ "${1-}" = 407 ] && return 0; __planted_real_driver_step_start "$@"; }
SH
out=$(cd "$OP" && bash "$SB/kit/driver/tests/trial2.test.sh" 2>&1); rc=$?
printf '%s\n' "$out" > "$SB/trial2.out"
[ "$rc" != 0 ] && ok "trial2 fails (exit $rc)" || bad "trial2 passed with no worktree"
grep -q 'refused: .* is empty' "$SB/trial2.out" && ok "and says the path came back empty" || bad "trial2 never refused the empty path; its tail: $(tail -5 "$SB/trial2.out")"
after=$(snap)
[ "$(sed -n 1p <<<"$after")" = "$(sed -n 1p <<<"$before")" ] && ok "the operator's HEAD did not move" || bad "the operator's HEAD moved: $(git -C "$OP" log --oneline -3 | tr '\n' ' ')"
[ "$(sed -n 2p <<<"$after")" = "<no hooksPath>" ] && ok "their hooks were not rewired" || bad "core.hooksPath is now $(sed -n 2p <<<"$after")"
[ "$after" = "$before" ] && ok "their index, config and working tree are as they left them" || bad "the operator's clone changed: before [$before] after [$after]"
[ -z "$(git -C "$OP" log --all --author='^T <' --format=%h)" ] && ok "and nothing was committed under the fixture's name" || bad "the fixture committed into the operator's clone"

suite_end "$fail"
