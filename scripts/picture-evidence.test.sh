#!/usr/bin/env bash
# picture-evidence.test.sh — the evidence a PR owes is read off its approved picture,
# not chosen by its builder; and a picture drawn from tidy data is refused.
# Run: bash "$0"
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
PE="$HERE/picture-evidence.py"
T=$(mktemp -d "${TMPDIR:-/tmp}/pe-test.XXXXXX"); trap 'rm -rf "$T"' EXIT
pass=0 fail=0
ok()  { pass=$((pass + 1)); echo "  ok  $1"; }
bad() { fail=$((fail + 1)); echo "  FAIL $1"; }
pe()  { python3 -I "$PE" "$@"; }

# The shape of the picture that went wrong: a grid, the command-menu, two phone frames.
cat > "$T/mock.html" <<'HTML'
<!doctype html><html data-real-data="duplicate-names longest-names empty scrolled"><body>
<section data-evidence-shot="voice-grid-laptop-light" data-evidence-route="/settings/voices" data-evidence-viewport="laptop" data-evidence-theme="light" data-evidence-shows="the permissions grid">grid</section>
<section data-evidence-shot="voice-menu-laptop-dark" data-evidence-route="/settings/voices" data-evidence-viewport="laptop" data-evidence-theme="dark" data-evidence-setup='press Meta+K ;; click the "Voice" menuitem'>menu</section>
<section data-evidence-shot="voice-grid-phone-light" data-evidence-route="/settings/voices" data-evidence-viewport="phone" data-evidence-theme="light">phone</section>
<section data-evidence-shot="voice-share-phone-dark" data-evidence-route="/voices/share" data-evidence-viewport="phone" data-evidence-theme="dark">phone share</section>
</body></html>
HTML

out=$(pe required "$T/mock.html"); rc=$?
[ $rc -eq 0 ] && [ "$(printf '%s\n' "$out" | grep -c .)" -eq 4 ] && ok "every region of the picture is a required shot" || bad "required: rc=$rc out=$out"
printf '%s\n' "$out" | grep -q $'^voice-menu-laptop-dark\t/settings/voices\tlaptop\tdark\t\tpress Meta+K ;; click "Voice" menuitem' \
  || printf '%s\n' "$out" | grep -q $'^voice-menu-laptop-dark\t/settings/voices\tlaptop\tdark\t\tpress Meta+K ;; click the "Voice" menuitem' \
  && ok "a region's setup steps come with it" || bad "setup lost: $out"

out=$(pe routes "$T/mock.html")
[ "$out" = $'/settings/voices\n/voices/share' ] && ok "routes are the picture's routes, once each" || bad "routes: $out"

# THE BUG: CI pinned only the grid the builder listed. Two regions had no shot.
printf 'voice-grid-laptop-light\tdocs/evidence/1/voice-grid-laptop-light.png\tlight\t/settings/voices\nvoice-grid-phone-light.png\n' > "$T/pinned"
out=$(pe missing --shots "$T/pinned" "$T/mock.html" 2>"$T/err"); rc=$?
[ $rc -eq 1 ] && printf '%s' "$out" | grep -q '^voice-menu-laptop-dark' && printf '%s' "$out" | grep -q '^voice-share-phone-dark' \
  && ! printf '%s' "$out" | grep -q 'voice-grid' && ok "a region with no pinned shot is named, and fails" || bad "missing: rc=$rc out=$out"
printf 'a/voice-grid-laptop-light.png\nvoice-menu-laptop-dark.png\nvoice-grid-phone-light\nvoice-share-phone-dark.png\n' > "$T/all"
pe missing --shots "$T/all" "$T/mock.html" >/dev/null 2>&1 && ok "every region pinned passes" || bad "complete set refused"

# A picture with no regions is not "nothing owed".
echo '<html><body><div>old picture</div></body></html>' > "$T/old.html"
pe missing --shots "$T/all" "$T/old.html" >/dev/null 2>&1; rc=$?
[ $rc -eq 3 ] && ok "a picture that declares no regions says so (exit 3), never passes as nothing owed" || bad "no regions: rc=$rc"

# The plan: the builder's own setup for a shot it named is kept; the rest are added.
echo '{"shots":[{"name":"voice-menu-laptop-dark","route":"/settings/voices","viewport":"laptop","theme":"dark","setup":["press Control+K"]}]}' > "$T/plan.json"
out=$(pe plan --into "$T/plan.json" "$T/mock.html")
[ "$(printf '%s' "$out" | jq '.shots | length')" = 4 ] && [ "$(printf '%s' "$out" | jq -r '.shots[0].setup[0]')" = "press Control+K" ] \
  && [ "$(printf '%s' "$out" | jq -r '.shots[] | select(.name=="voice-share-phone-dark") | .viewport')" = phone ] \
  && ok "plan keeps the builder's shot and adds every region it lacked" || bad "plan: $out"
out=$(pe plan --into "$T/none.json" "$T/mock.html")
[ "$(printf '%s' "$out" | jq -r '.shots[1].setup | join("|")')" = 'press Meta+K|click the "Voice" menuitem' ] && ok "a fresh plan carries the picture's setup" || bad "fresh plan: $out"

# Lint: the real-data floor.
pe lint "$T/mock.html" >/dev/null 2>&1 && ok "a picture with both widths and every real-data case passes lint" || bad "good picture refused: $(pe lint "$T/mock.html" 2>&1)"
sed 's/ data-real-data="duplicate-names longest-names empty scrolled"//' "$T/mock.html" > "$T/tidy.html"
out=$(pe lint "$T/tidy.html" 2>&1); rc=$?
[ $rc -eq 1 ] && printf '%s' "$out" | grep -q "'duplicate-names'" && printf '%s' "$out" | grep -q "'scrolled'" \
  && ok "a tidy picture (no duplicates, no longest names, no empty, unscrolled) is refused, case by case" || bad "tidy: rc=$rc $out"
sed 's/ data-real-data="duplicate-names longest-names empty scrolled"/ data-real-data="longest-names empty scrolled" data-real-data-na="duplicate-names: the screen lists no people"/' "$T/mock.html" > "$T/na.html"
pe lint "$T/na.html" >/dev/null 2>&1 && ok "a case excused with a reason passes" || bad "excused refused"
sed 's/ data-real-data="duplicate-names longest-names empty scrolled"/ data-real-data="longest-names empty scrolled" data-real-data-na="duplicate-names:"/' "$T/mock.html" > "$T/na2.html"
pe lint "$T/na2.html" >/dev/null 2>&1 && bad "an excuse with no reason passed" || ok "an excuse with no reason is not an excuse"
grep -v 'phone' "$T/mock.html" > "$T/laptop.html"
out=$(pe lint "$T/laptop.html" 2>&1)
printf '%s' "$out" | grep -q 'no phone frame' && ok "a picture with no phone frame is refused" || bad "laptop-only: $out"
out=$(pe lint "$T/old.html" 2>&1)
printf '%s' "$out" | grep -q 'declares no evidence shots' && ok "a picture with no regions fails lint" || bad "old lint: $out"
sed 's/voice-share-phone-dark/Voice Share/' "$T/mock.html" > "$T/badname.html"
out=$(pe lint "$T/badname.html" 2>&1)
printf '%s' "$out" | grep -q "'Voice Share': a name is lower-case" && ok "a shot name CI cannot use is refused" || bad "bad name passed"

# OLDER PICTURES: no markers. With --derive the regions come from its frames, not "none".
cat > "$T/legacy.html" <<'HTML'
<html><head><style>@media (prefers-color-scheme: dark) { :root { --bg: #111 } }</style></head><body>
<div class="states">
  <div class="frame"><div class="frame-h">1 · Arriving</div><div class="frame-b"><button class="btn dark">Go</button></div></div>
  <div class="frame"><div class="frame-h">Phone · 390 wide, scrolled</div><div class="frame-b"></div></div>
</div>
<section class="frame" id="empty-room"><h3>No rooms yet</h3></section>
</body></html>
HTML
pe required "$T/legacy.html" >/dev/null 2>&1; rc=$?
[ $rc -eq 3 ] && ok "without --derive an unmarked picture still says it declares nothing (exit 3)" || bad "no-derive: rc=$rc"
out=$(pe required --derive --route /desk "$T/legacy.html"); rc=$?
names=$(printf '%s\n' "$out" | cut -f1 | tr '\n' ' ')
[ $rc -eq 0 ] && [ "$names" = "1-arriving-laptop-light 1-arriving-laptop-dark phone-390-wide-scrolled-phone-light phone-390-wide-scrolled-phone-dark " ] \
  && ok "each outermost frame is a region, named by id or caption, at the widths and themes drawn; a second frame of the same page state is not" || bad "derived: rc=$rc $names"
printf '%s\n' "$out" | awk -F'\t' '$2 != "/desk"' | grep -q . && bad "a derived region lost its route" || ok "a frame with no route of its own is on the PR's route"
[ "$(pe derivation --derive --route /desk "$T/legacy.html" | cut -f2,3)" = $'frames\t4' ] && ok "derivation names how: frames 4" || bad "derivation: $(pe derivation --derive --route /desk "$T/legacy.html")"
echo '<html><body><p>an old picture with no frames</p></body></html>' > "$T/flat.html"
out=$(pe required --derive --route /desk --route /desk/new "$T/flat.html" | cut -f1 | tr '\n' ' ')
[ "$out" = "desk-laptop-light desk-laptop-dark desk-phone-light desk-phone-dark desk-new-laptop-light desk-new-laptop-dark desk-new-phone-light desk-new-phone-dark " ] \
  && ok "no frames: every evidence route at laptop/phone x light/dark" || bad "routes fallback: $out"
[ "$(pe derivation --derive "$T/flat.html" | cut -f2)" = none ] && ok "no frames and no routes: none, said so" || bad "none"

# A derived region is covered by CI's shot of its route, width and theme, whatever CI named it.
printf 'desk\tx/desk.png\tlight\t/desk\ndesk-dark\tx/desk-dark.png\tdark\t/desk\ndesk-phone.png\ndesk-phone-dark.png\n' > "$T/ci"
pe missing --derive --route /desk --shots "$T/ci" "$T/legacy.html" > "$T/out" 2>/dev/null; rc=$?
[ $rc -eq 0 ] && ok "CI's route-named shots cover the derived regions" || bad "derived missing: rc=$rc $(cat "$T/out")"
grep -v 'phone-dark' "$T/ci" > "$T/ci2"
out=$(pe missing --derive --route /desk --shots "$T/ci2" "$T/legacy.html" 2>/dev/null); rc=$?
[ $rc -eq 1 ] && [ "$(printf '%s\n' "$out" | cut -f1)" = "phone-390-wide-scrolled-phone-dark" ] && ok "a derived region with no matching shot is named" || bad "derived gap: rc=$rc $out"
printf 'desk\tx/desk.png\tlight\t/desk\n' > "$T/ci3"
pe missing --shots "$T/ci3" "$T/mock.html" >/dev/null 2>&1 && bad "a marked region was matched by route, not name" || ok "a marked region is still matched by its name only"

# AN OLDER PICTURE DRAWN AS MANY FRAMES OF ONE PAGE (PR 13415: 16 frames, 32 shots, its
# phone frames read as laptop). A frame is a phone when a <style> rule draws it 320-480
# wide, and frames with the same route, setup, width and theme are one shot.
cat > "$T/many.html" <<'HTML'
<html><head><style>
.frame { border: 1px solid #ccc; padding: 16px }
.frame.ph { width: 390px; border-radius: 22px }
.lk { width: 22px; height: 22px }
.tip { max-width: 300px }
.ph .rail { width: 100% }
@media (prefers-color-scheme: dark) { :root { --bg: #111 } }
</style></head><body>
<div class="frame lt" id="s1-lt-today"><span class="lk">i</span><span class="tip">tip</span></div>
<div class="frame lt aft" id="s1-lt-after"></div>
<div class="frame dk" id="s1-dk-today"></div>
<div class="frame ph lt" id="s1-ph-lt"><div class="rail"></div></div>
<div class="frame ph dk aft" id="s1-ph-dk"></div>
<div class="frame ph lt" id="s2-ph-today"></div>
<div class="frame lt aft" id="s2-lap-a"></div>
</body></html>
HTML
out=$(pe required --derive --route /dashboard/approvals "$T/many.html"); rc=$?
rows=$(printf '%s\n' "$out" | cut -f3,4 | tr '\t\n' ' ,')
[ $rc -eq 0 ] && [ "$rows" = "laptop light,laptop dark,phone light,phone dark," ] \
  && ok "seven frames of one page are four shots: laptop and phone, light and dark" || bad "many frames: rc=$rc [$rows] $(printf '%s\n' "$out" | cut -f1 | tr '\n' ' ')"
[ "$(printf '%s\n' "$out" | awk -F'\t' '$1 ~ /-ph-/ { print $3 }' | sort -u)" = phone ] \
  && ok "a frame a <style> rule draws 390 wide is a phone" || bad "css-sized phone frame read as: $(printf '%s\n' "$out" | awk -F'\t' '$1 ~ /-ph-/ { print $1, $3 }')"
printf '%s\n' "$out" | awk -F'\t' '$1 ~ /^s1-lt-today-phone/' | grep -q . \
  && bad "a 22px icon or a 300px tooltip inside a laptop frame was read as a phone" || ok "an icon or tooltip narrower than a phone is not a phone"
# Frames on different routes, or with different setups, stay apart.
sed 's|<div class="frame lt aft" id="s2-lap-a">|<div class="frame lt aft" id="s2-lap-a" data-route="/dashboard/other">|' "$T/many.html" > "$T/many2.html"
[ "$(pe required --derive --route /dashboard/approvals "$T/many2.html" | grep -c .)" = 6 ] \
  && ok "a frame on another route is its own shot" || bad "routes merged: $(pe required --derive --route /dashboard/approvals "$T/many2.html" | cut -f1-4)"

# REAL DATA by approval date: the cut-off is 2026-10-20; with no date known, exempt.
pe lint --approved 2026-10-19 "$T/tidy.html" >/dev/null 2>&1 && ok "a tidy picture approved 2026-10-19 is exempt" || bad "old tidy refused"
pe lint --approved none "$T/tidy.html" >/dev/null 2>&1 && ok "a tidy picture with no known date is exempt" || bad "undated tidy refused"
pe lint --approved 2026-10-20 "$T/tidy.html" >/dev/null 2>&1 && bad "a tidy picture approved 2026-10-20 passed" || ok "a tidy picture approved 2026-10-20 is refused"
pe lint "$T/tidy.html" >/dev/null 2>&1 && bad "a tidy picture being drawn passed" || ok "a picture being drawn (no date given) owes real data"
sed 's/<html>/<html data-picture-approved="2026-10-01">/' "$T/tidy.html" > "$T/tidy-dated.html"
pe lint --approved 2026-10-20 "$T/tidy-dated.html" >/dev/null 2>&1 && ok "the picture's own data-picture-approved wins" || bad "own date ignored"
pe lint --approved 2026-10-19 "$T/laptop.html" >/dev/null 2>&1 && ok "an older picture is not refused for one width" || bad "old laptop-only refused"
pe lint --derive --route /desk --approved none "$T/legacy.html" >/dev/null 2>&1 && ok "an older unmarked picture lints clean once derived" || bad "legacy lint: $(pe lint --derive --route /desk --approved none "$T/legacy.html" 2>&1)"
out=$(pe lint --derive --approved none "$T/legacy.html" 2>&1)
printf '%s' "$out" | grep -q "derived region .* no route" && ok "a derived region with no route is a gap, named" || bad "routeless derived region passed"

echo "picture-evidence: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
