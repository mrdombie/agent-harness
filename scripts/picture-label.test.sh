#!/usr/bin/env bash
# picture-label.test.sh — an older picture's frames get their region markers written in,
# and nothing the picture renders changes: take the added attributes out and it is the
# original, byte for byte.
# Run: bash "$0"
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/tests/lib/suite.sh" || exit 1
HERE="$(cd "$(dirname "$0")" && pwd)"
PL="$HERE/picture-label.py"
PE="$HERE/picture-evidence.py"
T=$(mktemp -d "${TMPDIR:-/tmp}/pl-test.XXXXXX"); on_exit_keep_status 'rm -rf "$T" "$HERE/.picture-label.plant.py"'
pass=0 fail=0
ok()  { pass=$((pass + 1)); echo "  ok  $1"; }
bad() { fail=$((fail + 1)); echo "  FAIL $1"; }

# The shape of the pictures approved before 2026-10-20: frames, a phone drawn inside
# one, a dark theme only in the styles, odd spacing and a self-closing tag kept as is.
cat > "$T/orig.html" <<'HTML'
<!doctype html>
<html><head><style>@media (prefers-color-scheme: dark) { :root { --bg: #111 } }</style></head><body>
<div class="states">
  <div class="frame"   data-x='a > b'><div class="frame-h">1 · Arriving</div>
    <div class="frame-b"><button class="btn dark">Go</button></div>
    <div class="phone"><p>the same, on a phone</p></div></div>
  <section class="frame" id="empty-room"><h3>No rooms yet</h3><img src="x.png"/></section>
</div>
</body></html>
HTML
strip() { python3 -I -c 'import re,sys; sys.stdout.write(re.sub(r" data-(?:evidence-[a-z]+|picture-approved)=\"[^\"]*\"", "", open(sys.argv[1], encoding="utf-8", newline="").read()))' "$1"; }
unchanged() { [ "$(strip "$1"; echo x)" = "$(cat "$T/orig.html"; echo x)" ]; }

# 1 It labels each frame and the phone inside one; nothing it renders changes.
case_label() {
  cp "$T/orig.html" "$T/p.html"
  python3 -I "$PL" --route /desk --approved 2026-10-18 "$T/p.html" > "$T/out" 2>"$T/err"; rc=$?
  [ $rc -eq 0 ] && unchanged "$T/p.html" && [ "$(grep -o 'data-evidence-shot=' "$T/p.html" | grep -c .)" -eq 3 ] && echo green || echo red
}
[ "$(case_label)" = green ] && ok "labelled, and with the added attributes taken out it is the original byte for byte" || bad "label: $(cat "$T/err")"
out=$(cat "$T/out")
printf '%s' "$out" | grep -q '^+.*data-evidence-shot="1-arriving-laptop-light"' && printf '%s' "$out" | grep -q '^-  <div class="frame"' \
  && ok "it prints the diff" || bad "no diff printed: $out"
req=$(python3 -I "$PE" required "$T/p.html" | cut -f1-4 | tr '\t' ' ')
[ "$req" = "$(printf '1-arriving-laptop-light /desk laptop light\n1-arriving-phone-light /desk phone light\nempty-room-laptop-light /desk laptop light')" ] \
  && ok "the labelled picture declares its regions without --derive" || bad "required: $req"
grep -q 'data-picture-approved="2026-10-18"' "$T/p.html" && python3 -I "$PE" lint "$T/p.html" >/dev/null 2>&1 \
  && ok "the approval date is written, so the older picture lints clean on its own" || bad "lint after label: $(python3 -I "$PE" lint "$T/p.html" 2>&1)"
grep -c 'data-evidence-shot' "$T/p.html" | grep -qx 3 && ok "one region on each element: two frames and the phone inside one" || bad "count: $(grep -c data-evidence-shot "$T/p.html")"

# 2 Once labelled, it is left alone.
cp "$T/p.html" "$T/again.html"; python3 -I "$PL" --route /desk "$T/again.html" >/dev/null 2>&1
cmp -s "$T/p.html" "$T/again.html" && ok "a labelled picture is not labelled twice" || bad "relabelled"

# 3 --dry-run writes nothing; no route, or no frame, writes nothing and says why.
cp "$T/orig.html" "$T/d.html"; python3 -I "$PL" --dry-run --route /desk "$T/d.html" > "$T/dout" 2>/dev/null
cmp -s "$T/orig.html" "$T/d.html" && grep -q '^+' "$T/dout" && ok "--dry-run prints the diff and writes nothing" || bad "dry-run wrote"
cp "$T/orig.html" "$T/n.html"; python3 -I "$PL" "$T/n.html" >/dev/null 2>"$T/nerr"; rc=$?
[ $rc -eq 1 ] && cmp -s "$T/orig.html" "$T/n.html" && grep -q -- '--route' "$T/nerr" && ok "with no route it writes nothing and asks for one" || bad "no route: rc=$rc"
echo '<html><body><p>flat</p></body></html>' > "$T/flat.html"; cp "$T/flat.html" "$T/f2.html"
python3 -I "$PL" --route /desk "$T/f2.html" >/dev/null 2>&1; rc=$?
[ $rc -eq 1 ] && cmp -s "$T/flat.html" "$T/f2.html" && ok "a picture with no frames is left alone, exit 1" || bad "flat: rc=$rc"

echo "plants"
plant() { # <desc> <case> <old> <new> [<old> <new>]…
  local P="$HERE/.picture-label.plant.py" d="$1" c="$2"; shift 2; cp "$PL" "$P"
  python3 - "$P" "$@" <<'PY' || { bad "plant did not land: $d"; rm -f "$P"; return; }
import sys
p, pairs = sys.argv[1], sys.argv[2:]
s = open(p).read()
for a, b in zip(pairs[::2], pairs[1::2]):
    if s.count(a) != 1: sys.exit(1)
    s = s.replace(a, b)
open(p, "w").write(s)
PY
  local keep="$PL" r; PL="$P"; r=$("$c"); PL="$keep"; rm -f "$P"
  [ "$r" = red ] && ok "planted: $d → red" || bad "planted: $d → not caught"
}
# The label also changes what renders, with its own check switched off: the test still sees it.
plant "a label that also changes the render" case_label \
  "        inserts.append((end, attrs))" "        inserts.append((end, attrs + ' style=\"outline:0\"'))" \
  "    if back != src:" "    if False:"
plant "nothing is written" case_label \
  '        with open(path, "w", encoding="utf-8", newline="") as f:' '        with open(os.devnull, "w", encoding="utf-8", newline="") as f:'
plant "the phone inside a frame is not labelled" case_label \
  '    rows = pe.frame_regions(pic, routes)' '    rows = [r for r in pe.frame_regions(pic, routes) if r[4] != "phone"]'

echo "picture-label: $pass passed, $fail failed"
suite_end "$fail"
