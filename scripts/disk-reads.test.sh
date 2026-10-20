#!/usr/bin/env bash
# disk-reads.test.sh — free disk is read in one place, so a fix to how it is read reaches every reader.
#
# 2026-10-20: under WSL, Linux's df showed 831 GB free while the Windows drive holding the virtual
# disk had 37. disk-guard.sh learnt to read both and take the lower; the housekeeping pass had its
# own `df` and would have kept reading 831. Every free-space reading goes through disk-guard.sh
# (`free`, `host`); the live page's server is the one other reader, and takes the host path from it.
# Run: bash "$0"
set -uo pipefail
for v in $(env | sed -n 's/^\(GIT_[A-Z_]*\)=.*/\1/p'); do unset "$v"; done
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
fail=0
ok()  { echo "  ok   — $1"; }
bad() { echo "  FAIL — $1"; fail=1; }

ALLOWED='^(scripts/disk-guard\.sh|swarm/live-view/server\.mjs)$'
READS='(^|[^A-Za-z0-9_-])df +(-[A-Za-z]+ +)*(-[A-Za-z]+|/|"?\$)|statfs|disk_usage|os\.statvfs'
# readers <root> — "<file>:<line>:<text>" for every free-space read outside the allowed two.
readers() {
  ( cd "$1" && find . -type f \( -name '*.sh' -o -name '*.mjs' -o -name '*.js' -o -name '*.cjs' -o -name '*.py' \) \
      -not -path './.git/*' -not -path './reference/*' -not -path '*/node_modules/*' \
      -not -name '*.test.sh' -not -path './swarm/tests/*' -not -path './scripts/fixtures/*' -print \
    | sed 's|^\./||' | sort | while IFS= read -r f; do
        printf '%s\n' "$f" | grep -qE "$ALLOWED" && continue
        grep -nE "$READS" "$f" 2>/dev/null | grep -vE '^[0-9]+: *#' | sed "s|^|$f:|"
      done )
}

echo "--- the kit: no free-space read outside disk-guard.sh and the live page's server ---"
found=$(readers "$ROOT")
[ -z "$found" ] && ok "none" || { bad "free disk read outside disk-guard.sh:"; printf '%s\n' "$found" | sed 's/^/        /'; }
grep -qE 'disk-guard\.sh" free' "$ROOT/scripts/coordinator-housekeeping.sh" \
  && ok "housekeeping asks the guard" || bad "housekeeping does not ask disk-guard.sh free"
grep -qE 'disk-guard\.sh" host' "$ROOT/swarm/live-view.sh" \
  && ok "the live page takes the host drive from the guard" || bad "live-view.sh does not ask disk-guard.sh host"

echo "--- the scan sees a planted reader, and passes what is not one ---"
SB=$(mktemp -d "${TMPDIR:-/tmp}/disk-reads-test-XXXXXX"); trap 'rm -rf "$SB"' EXIT
mkdir -p "$SB/scripts" "$SB/swarm/live-view"
printf '#!/usr/bin/env bash\nfree=$(df -Pk "$STATE_DIR" | awk "NR==2{print \\$4}")\n' > "$SB/scripts/a.sh"
printf 'const st = fs.statfsSync(dir)\n' > "$SB/scripts/b.mjs"
printf 'import shutil\nshutil.disk_usage("/")\n' > "$SB/scripts/c.py"
printf '#!/usr/bin/env bash\n# df -h / is how a person looks\necho "pdf -k"; undf=1\n' > "$SB/scripts/d.sh"
printf 'df -Pk /\n' > "$SB/scripts/disk-guard.sh"; printf 'fs.statfsSync(at)\n' > "$SB/swarm/live-view/server.mjs"
got=$(readers "$SB" | cut -d: -f1 | tr '\n' ' ')
[ "$got" = "scripts/a.sh scripts/b.mjs scripts/c.py " ] && ok "a df, a statfs and a disk_usage are found; a comment, a word and the allowed two are not" \
  || bad "wanted 'scripts/a.sh scripts/b.mjs scripts/c.py ', got '$got'"

exit $fail
