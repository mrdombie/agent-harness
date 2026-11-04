#!/usr/bin/env bash
# owner-kinds.test.sh — every alert sent with --class owner reaches the owner.
# coordinator-notify.sh rewrites any key whose kind is not in OWNER_KINDS to agent
# work, so a call site the list forgot is an owner alert that never arrives (the
# stall alert and the missing-tools alert did exactly that). Each call site's kind
# is read from the source, then sent through the real notify script, live, and must
# land in needs-you.md.
# Run: bash "$0"
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/tests/lib/suite.sh" || exit 1
for v in $(env | sed -n 's/^\(GIT_[A-Z_]*\)=.*/\1/p'); do unset "$v"; done
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
. "$HERE/../swarm/tests/fixture.sh"
swarm_fixture; on_exit_keep_status 'rm -rf "$FIX"'
N="$HERE/coordinator-notify.sh"
C="$STATE/coordinator"
cat > "$BIN/ping" <<'SH'
#!/usr/bin/env bash
echo "$1" >> "$FIX/ping.log"
SH
chmod +x "$BIN/ping"
export COORDINATOR_NOTIFY_CMD="$BIN/ping"
unset COORDINATOR_SHADOW

# owner_sites — <file>:<line>\t<kind>, one per `--class owner` call outside the tests.
# A key held in a variable takes its kind from the nearest assignment (var="kind:…")
# or case arm (case "$var" in kind:*)) above the call in the same file; none is "?".
owner_sites() {
  local f
  (cd "$ROOT" && git ls-files -- '*.sh' '*.md') | grep -v '\.test\.sh$' | while IFS= read -r f; do
    awk -v f="$f" '
      { line[NR] = $0 }
      /^[ \t]*#/ { next }
      match($0, /--class[ =]owner[ ]+"?[^" ]+/) {
        tok = substr($0, RSTART, RLENGTH); sub(/^--class[ =]owner[ ]+"?/, "", tok)
        kind = "?"
        if (tok ~ /^\$/) {
          v = tok; gsub(/[${}]/, "", v); sub(/[^A-Za-z0-9_].*$/, "", v)
          for (i = NR - 1; i > 0 && i >= NR - 40; i--) {
            s = line[i]
            if (match(s, v "=\"?[a-z][a-z0-9-]*:")) { k = substr(s, RSTART, RLENGTH); sub(/^[^=]*="?/, "", k); sub(/:$/, "", k); kind = k; break }
            if (match(s, "case \"\\$\\{?" v "\\}?\" in [a-z][a-z0-9-]*:")) { k = substr(s, RSTART, RLENGTH); sub(/^.* in /, "", k); sub(/:$/, "", k); kind = k; break }
          }
        } else if (match(tok, /^[a-z][a-z0-9-]*:/)) {
          kind = substr(tok, 1, RLENGTH - 1)
        }
        printf "%s:%d\t%s\n", f, NR, kind
      }' "$ROOT/$f"
  done
}

SITES=$(owner_sites)
echo "--- the owner call sites, as read from the source ---"
printf '%s\n' "$SITES"
n=$(printf '%s\n' "$SITES" | grep -c .)
want "the reader finds the known owner call sites, not none" "1" "$([ "$n" -ge 7 ] && echo 1 || echo "$n")"
for k in red-2h disk-low login-lost blind decision signoff-batch host-tools; do
  want_in "a call site sending $k is read" $'\t'"$k"'$' "$SITES"
done

echo "--- every one of them reaches the owner ---"
while IFS=$'\t' read -r site kind; do
  [ -n "${site:-}" ] || continue
  if [ "$kind" = "?" ]; then
    want "$site: its key's kind can be read (assign it as kind:… or case it above the call)" "a kind" "?"
    continue
  fi
  rm -rf "$C"; : > "$FIX/ping.log"
  COORDINATOR_SHADOW=0 bash "$N" --class owner "$kind:probe" "probe from $site"
  want_in "$site ($kind) lands in needs-you.md" "<!-- key:$kind:probe -->" "$(cat "$C/needs-you.md" 2>/dev/null)"
  want_in "$site ($kind) pings the owner"      "probe from $site" "$(cat "$FIX/ping.log")"
done <<<"$SITES"

echo "--- agent work still never reaches the owner ---"
rm -rf "$C"; : > "$FIX/ping.log"
COORDINATOR_SHADOW=0 bash "$N" --class owner "red-pr:41:abc" "PR #41 is red"
want "a red PR on the rebuild clock is not the owner's" "" "$(cat "$C/needs-you.md" 2>/dev/null)"

suite_end "$FAILED"
