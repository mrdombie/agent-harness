#!/usr/bin/env bash
# evidence-gaps.test.sh — a changed screen file no evidence route or capture step renders
# is a gap; a drawer needs a shot whose setup opens it; a plan the PR edits replaces the
# routes, as CI reads it; evidence-class findings are told apart from the rest; and a
# ticket with no picture gets its changed screens at laptop/phone x light/dark.
# Run: bash "$0"
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/tests/lib/suite.sh" || exit 1
for v in $(env | sed -n 's/^\(GIT_[A-Z_]*\)=.*/\1/p'); do unset "$v"; done
HERE="$(cd "$(dirname "$0")" && pwd)"
PY="$HERE/evidence-gaps.py"
T=$(mktemp -d "${TMPDIR:-/tmp}/evidence-gaps.XXXXXX"); on_exit_keep_status 'rm -rf "$T"'
pass=0 fail=0
ok()  { pass=$((pass + 1)); echo "  ok  $1"; }
bad() { fail=$((fail + 1)); echo "  FAIL $1"; }
eg()  { python3 -I "$PY" "$@"; }

R="$T/repo"; mkdir -p "$R"; cd "$R" || exit 1
git init -q -b develop . && git config user.email t@invalid && git config user.name t
mkdir -p apps/web/src/app/people/'[id]' apps/web/src/app/settings apps/web/src/app/'(shell)'/home apps/web/src/app/dev/catalog \
         apps/web/src/components packages/ui/src docs/evidence/42
echo '{"name":"web"}' > apps/web/package.json; echo '{"name":"@acme/ui"}' > packages/ui/package.json
cat > apps/web/src/app/layout.tsx <<'X'
import { Shell } from '@/components/Shell'
export default function L({ children }) { return <Shell>{children}</Shell> }
X
cat > apps/web/src/app/'(shell)'/home/page.tsx <<'X'
import { PersonDrawer } from '../../../components/PersonDrawer'
import { Card } from '@acme/ui'
export default function P() { return <PersonDrawer /> }
X
cat > apps/web/src/app/settings/page.tsx <<'X'
import { Toggle } from '@/components/Toggle'
export default function S() { return <Toggle /> }
X
cat > apps/web/src/app/people/'[id]'/page.tsx <<'X'
import { Avatar } from '@/components/Avatar'
export default function Q() { return <Avatar /> }
X
cat > apps/web/src/app/dev/catalog/page.tsx <<'X'
import { Swatch } from '@/components/Swatch'
export default function C() { return <Swatch /> }
X
for c in Shell PersonDrawer Toggle Avatar Swatch Orphan; do echo "export function $c() { return null }" > "apps/web/src/components/$c.tsx"; done
echo "export function Card() { return null }" > packages/ui/src/Card.tsx
echo "export * from './Card'" > packages/ui/src/index.ts
git add -A && git commit -qm base; BASE=$(git rev-parse HEAD)

change() { git checkout -q -B "w$1" "$BASE"; shift; for f in "$@"; do echo "// $RANDOM" >> "$f"; done; git add -A && git commit -qm change; }
cov() { eg coverage --repo "$R" --base "$BASE" --head HEAD --ignore-route /dev "$@"; }

echo "evidence-gaps"
echo "--- coverage"
change 1 apps/web/src/components/PersonDrawer.tsx
out=$(cov --route /home); rc=$?
[ $rc -eq 1 ] && printf '%s' "$out" | grep -q '^missing-state	apps/web/src/components/PersonDrawer.tsx	/home	evidence gap: .*drawer that only shows once opened' \
  && ok "a changed drawer on an evidence route, with no capture step to open it, is a gap" || bad "drawer: rc=$rc $out"
out=$(cov --route /settings); rc=$?
[ $rc -eq 1 ] && printf '%s' "$out" | grep -q '^missing-route	apps/web/src/components/PersonDrawer.tsx	/home	' \
  && ok "a changed file no evidence route renders is a gap naming the route it renders on (a route group dropped)" || bad "route: rc=$rc $out"

# The capture plan the PR edits replaces the routes; a shot whose setup opens the drawer answers it.
git checkout -q -B w1b w1
printf '{"shots":[{"name":"home-drawer-laptop-light","route":"/home","viewport":"laptop","theme":"light","setup":["click the \\"Open\\" button"]}]}\n' > docs/evidence/42/plan.json
git add -A && git commit -qm plan
out=$(cov --plan docs/evidence/42/plan.json --route /settings); rc=$?
[ $rc -eq 0 ] && [ -z "$out" ] && ok "a plan shot on the route whose setup opens the drawer answers it, and the plan replaces the routes" || bad "plan answer: rc=$rc $out"
out=$(cov --plan docs/evidence/41/plan.json --route /settings); rc=$?
[ $rc -eq 1 ] && ok "a plan the PR does not add or edit is not read (CI would not read it either)" || bad "foreign plan read: rc=$rc $out"
printf '{"shots":[{"name":"home-laptop-light","route":"/home","viewport":"laptop","theme":"light"}]}\n' > docs/evidence/42/plan.json
git add -A && git commit -qm "plan without setup"
out=$(cov --plan docs/evidence/42/plan.json); rc=$?
[ $rc -eq 1 ] && printf '%s' "$out" | grep -q '^missing-state' && ok "a plan shot of the route that opens nothing still leaves the drawer unseen" || bad "setup-less plan passed: $out"

change 2 apps/web/src/components/Shell.tsx
out=$(cov --route /settings); rc=$?
[ $rc -eq 0 ] && ok "a file a layout above the route imports (an alias import) renders on it" || bad "layout: rc=$rc $out"
out=$(eg routes --repo "$R" --base "$BASE" --head HEAD --ignore-route /dev | tr '\n' ' ')
[ "$out" = "/home " ] && ok "a change every page shows is derived to one route, not all of them" || bad "layout routes: '$out'"
change 3 packages/ui/src/Card.tsx
out=$(cov --route /settings); rc=$?
printf '%s' "$out" | grep -q 'packages/ui/src/Card.tsx	/home' && ok "a workspace package's file is followed to the page that imports the package" || bad "package: rc=$rc $out"
out=$(cov --route /home); rc=$?
[ $rc -eq 0 ] && ok "and is covered by that page's route" || bad "package covered: rc=$rc $out"
change 4 apps/web/src/components/Avatar.tsx
out=$(cov --route /people/123); rc=$?
[ $rc -eq 0 ] && ok "a concrete route covers a dynamic page" || bad "dynamic: rc=$rc $out"
change 5 apps/web/src/components/Swatch.tsx apps/web/src/components/Orphan.tsx
out=$(cov --route /settings); rc=$?
[ $rc -eq 0 ] && [ -z "$out" ] && ok "a file only an ignored catalogue route, or no page at all, renders is not a screen file" || bad "not screens: rc=$rc $out"
out=$(eg coverage --repo "$R" --base "$BASE" --head HEAD --route /settings); rc=$?
printf '%s' "$out" | grep -q 'Swatch.tsx	/dev/catalog' && ok "without the ignore, the catalogue route is a screen" || bad "ignore not optional: $out"

echo "--- routes (no picture: derived from the changed screens)"
change 6 apps/web/src/components/PersonDrawer.tsx apps/web/src/components/Toggle.tsx apps/web/src/components/Avatar.tsx
out=$(eg routes --repo "$R" --base "$BASE" --head HEAD --ignore-route /dev | tr '\n' ' ')
[ "$out" = "/home /settings " ] && ok "the routes the changed files render on, dynamic ones left out: $out" || bad "routes: '$out'"
change 7 apps/web/src/app/settings/page.tsx
out=$(eg routes --repo "$R" --base "$BASE" --head HEAD | tr '\n' ' ')
[ "$out" = "/settings " ] && ok "a changed page is its own route" || bad "page route: '$out'"

echo "--- plan"
P="$T/plan.json"; rm -f "$P"
out=$(eg plan --into "$P" --route /settings --route /)
[ "$(printf '%s' "$out" | jq -r '[.shots[] | "\(.route) \(.viewport) \(.theme)"] | join(",")')" = "/settings laptop light,/settings laptop dark,/settings phone light,/settings phone dark,/ laptop light,/ laptop dark,/ phone light,/ phone dark" ] \
  && ok "each route at laptop and phone, light and dark" || bad "plan: $out"
printf '{"shots":[{"name":"mine","route":"/settings","viewport":"phone","theme":"dark","setup":["press Escape"]}]}' > "$P"
out=$(eg plan --into "$P" --route /settings)
[ "$(printf '%s' "$out" | jq '.shots | length')" = 4 ] && [ "$(printf '%s' "$out" | jq -r '.shots[0].setup[0]')" = "press Escape" ] \
  && ok "a shot the plan already has for a route, width and theme is kept, not doubled" || bad "merge: $out"
printf '%s' "$out" > "$P"; eg check-plan "$P" && ok "the merged plan is one CI can read" || bad "check-plan refused a good plan"
printf '{"shots":[{"name":"Bad Name","route":"settings","viewport":"tablet"}]}' > "$P"
err=$(eg check-plan "$P" 2>&1); rc=$?
[ $rc -eq 1 ] && printf '%s' "$err" | grep -q 'name must' && printf '%s' "$err" | grep -q 'route must' && printf '%s' "$err" | grep -q 'viewport must' \
  && ok "check-plan names every bad field" || bad "check-plan: rc=$rc $err"

echo "--- classify"
out=$(printf '%s\n' \
  "Major · evidence gap: the approved picture declares menu-phone-dark and CI pinned no shot of it" \
  "Major · the people drawer open state has no shot" \
  "Major · dark theme missing for the pipeline page" \
  "Major · no 390 shot of the detail page" \
  "Minor · the region 'filters' has no shot" \
  "Major · five rows read Sam Member" \
  "Minor · the lock icon sits 2px low" | eg classify)
[ "$(printf '%s\n' "$out" | grep -c .)" = 5 ] && ! printf '%s' "$out" | grep -q 'Sam Member\|2px' \
  && ok "the five evidence findings are picked out, the two design findings are not" || bad "classify: $out"

echo "--- plants"
plant() { # <desc> <old> <new> <check>
  local P2="$T/plant.py"; cp "$PY" "$P2"
  python3 - "$P2" "$2" "$3" <<'X' || { bad "plant did not land: $1"; return; }
import sys
p, a, b = sys.argv[1:]
s = open(p).read()
if s.count(a) != 1: sys.exit(1)
open(p, "w").write(s.replace(a, b))
X
  local was="$PY"; PY="$P2"; local r; r=$("$4"); PY="$was"
  [ "$r" = red ] && ok "planted: $1 → red" || bad "planted: $1 → not caught"
}
p_state() { git -C "$R" checkout -q w1; cov --route /home >/dev/null && echo red || echo green; }
p_route() { git -C "$R" checkout -q w3; cov --route /settings >/dev/null && echo red || echo green; }
p_layout() { git -C "$R" checkout -q w2; [ -n "$(eg routes --repo "$R" --base "$BASE" --head HEAD)" ] && echo green || echo red; }
plant "a drawer needs no opening step"      'if STATEFUL.search(posixpath.basename(f)):' 'if False:' p_state
plant "every changed file counts as shown"  'if f not in shown:' 'if False:' p_route
plant "layouts above a page are not roots"  'lay = f"{d}/layout.{e}"' 'lay = f"{d}/nolayout.{e}"' p_layout

echo "evidence-gaps: $pass passed, $fail failed"
suite_end "$fail"
