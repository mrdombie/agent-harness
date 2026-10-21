#!/usr/bin/env bash
# return-fields.test.sh — a brief's Return section and its schema are one contract:
# the field list is generated from the schema, and a drift either way is a refusal.
# Measured 2026-10-17: build.md's Return section never named `changed`, which a
# built answer must carry, and a build parked as "answered in a shape the driver
# cannot read". The examples are validated against the schemas in schemas.test.sh.
# Run: bash "$0"
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/tests/lib/suite.sh" || exit 1
for v in $(env | sed -n 's/^\(GIT_[A-Z_]*\)=.*/\1/p'); do unset "$v"; done
BRIEFS="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RF="$BRIEFS/return-fields.sh"

FAILED=0
ok()  { printf 'OK       %s\n' "$1"; }
bad() { printf 'MISMATCH %s\n' "$1"; FAILED=1; }
want() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 — wanted '$2', got '$3'"; fi; }
want_in() {
  if printf '%s' "$3" | grep -qF -- "$2"; then ok "$1"
  else bad "$1 — no '$2' in: $(printf '%s' "$3" | tr '\n' '|')"; fi
}

[ -f "$RF" ] || { printf 'MISMATCH return-fields.sh is missing: %s\n' "$RF"; exit 1; }
steps=$(ls "$BRIEFS/schemas"/*.json 2>/dev/null | while read -r f; do basename "$f" .json; done)
[ -n "$steps" ] || { printf 'MISMATCH no schemas — refusing to report clean\n'; exit 1; }

echo "--- every brief carries the list its schema implies ---"
for step in $steps; do
  out=$(bash "$RF" --check "$step" 2>&1); rc=$?
  want "$step.md is in step with schemas/$step.json" 0 "$rc"
  [ "$rc" = 0 ] || printf '         %s\n' "$out"
done

# Read straight off the schema, not through the generator: a renderer that drops a
# field would otherwise agree with itself.
echo "--- every field the schema has is named in the brief's Return section ---"
for step in $steps; do
  missing=""
  ret=$(sed -n '/^## Return/,$p' "$BRIEFS/$step.md")
  for p in $(jq -r '[paths(objects) | select(length >= 2 and .[-2] == "properties")
                     | map(select(. != "properties" and . != "items" and . != "if" and . != "then" and . != "else" and . != "allOf" and (type == "string")))]
                    | map(select(length > 0)) | unique[] | join(".")' "$BRIEFS/schemas/$step.json"); do
    leaf=${p##*.}
    printf '%s' "$ret" | grep -qE "\`([A-Za-z]+(\[\])?\.)*$leaf\`" || missing="$missing $p"
  done
  want "$step.md names every field of schemas/$step.json" "" "${missing# }"
done

TD=$(mktemp -d); on_exit_keep_status 'rm -rf "$TD"'
fresh() { rm -rf "$TD/b"; mkdir -p "$TD/b"; cp -R "$BRIEFS/schemas" "$BRIEFS/build.md" "$RF" "$TD/b/"; }

echo "--- a field the schema gains and the brief lacks is refused ---"
fresh
jq '.properties.evidence = {"type": "string"}' "$TD/b/schemas/build.json" > "$TD/x" && mv "$TD/x" "$TD/b/schemas/build.json"
out=$(bash "$TD/b/return-fields.sh" --check build 2>&1); rc=$?
want "refused" 1 "$rc"
want_in "and the diff names it" '`evidence`' "$out"

echo "--- a field the brief's list keeps after the schema dropped it is refused ---"
fresh
jq 'del(.properties.surfaces)' "$TD/b/schemas/build.json" > "$TD/x" && mv "$TD/x" "$TD/b/schemas/build.json"
out=$(bash "$TD/b/return-fields.sh" --check build 2>&1); rc=$?
want "refused" 1 "$rc"
want_in "and the diff names it" '`surfaces`' "$out"

echo "--- the Return prose naming a field the schema lacks is refused ---"
fresh
printf '\n`testFirst` carries `redLog`, the red run in full.\n' >> "$TD/b/build.md"
out=$(bash "$TD/b/return-fields.sh" --check build 2>&1); rc=$?
want "refused" 1 "$rc"
want_in "and names it" 'names `redLog`' "$out"

echo "--- a requirement that holds only when built is said in the list ---"
out=$(bash "$RF" build)
want_in "a built answer requires changed and changelog" 'when `status` is "built": requires `changed`, `changelog`; exactly one of `testFirst`, `testOnly`' "$out"
want_in "and anything else requires the question" '- otherwise: requires `question`' "$out"

echo "--- --write regenerates what --check refused ---"
fresh
jq '.properties.evidence = {"type": "string"}' "$TD/b/schemas/build.json" > "$TD/x" && mv "$TD/x" "$TD/b/schemas/build.json"
bash "$TD/b/return-fields.sh" --write build >/dev/null
bash "$TD/b/return-fields.sh" --check build >/dev/null 2>&1; want "in step after --write" 0 "$?"
want "the brief outside the list is untouched" \
  "$(sed '/^<!-- fields:begin/,/^<!-- fields:end -->$/d' "$BRIEFS/build.md")" \
  "$(sed '/^<!-- fields:begin/,/^<!-- fields:end -->$/d' "$TD/b/build.md")"

echo "--- a brief with no list is a 2, not a pass ---"
fresh
sed '/^<!-- fields:begin/,/^<!-- fields:end -->$/d' "$BRIEFS/build.md" > "$TD/b/build.md"
bash "$TD/b/return-fields.sh" --check build >/dev/null 2>&1; want "refused as unreadable" 2 "$?"

[ "$FAILED" = 0 ] && echo "briefs/return-fields: all good"
suite_end "$FAILED"
