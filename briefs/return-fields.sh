#!/usr/bin/env bash
# return-fields.sh — a brief's list of answer fields, generated from its schema.
#
#   briefs/return-fields.sh <step>             print the list schemas/<step>.json implies
#   briefs/return-fields.sh --check [<step>…]  exit 1 when a brief's list differs from it
#   briefs/return-fields.sh --write [<step>…]  rewrite each brief's list from its schema
#
# With no step, --check and --write take every schema in schemas/. The list sits in
# the brief's Return section between the two markers below; the schema is the one
# source, so the brief cannot name a field the validator refuses or leave out one
# it requires. --check also refuses a Return section whose prose names, in
# backticks, a field or value the schema does not have. Exit 2 when a brief or
# schema cannot be read, or has no markers.
set -uo pipefail
BRIEFS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCHEMAS=${BRIEFS_SCHEMAS:-"$BRIEFS/schemas"}
BEGIN_RE='^<!-- fields:begin'
END_LINE='<!-- fields:end -->'

die() { printf 'briefs/return-fields.sh: %s\n' "$1" >&2; exit 2; }

render() { # <step>
  local s="$SCHEMAS/$1.json"
  [ -f "$s" ] || die "no schema at $s"
  printf '<!-- fields:begin — generated from schemas/%s.json by briefs/return-fields.sh --write %s; edit the schema, never this list -->\n' "$1" "$1"
  printf 'Every field the contract has; `additionalProperties` is false, so no other.\n\n'
  jq -r '
    def typ: if has("const") then (.const | tojson)
             elif has("enum") then "one of " + (.enum | map(tojson) | join(", "))
             elif .type == "array" then "list of " + ((.items // {}) | typ)
             elif .type then .type else "any" end;
    def fields($pre; $req):
      (.properties // {}) | to_entries[] | .key as $k | .value as $v
      | "- `\($pre)\($k)`\(if ($req | index($k)) != null then " (required)" else "" end): \($v | typ)",
        (if $v.type == "object" then $v | fields("\($pre)\($k)."; ($v.required // []))
         elif $v.type == "array" and ($v.items.type? == "object") then $v.items | fields("\($pre)\($k)[]."; ($v.items.required // []))
         else empty end);
    def names: map("`\(.)`") | join(", ");
    def parts: . as $n | [ (if .required then "requires " + (.required | names) else empty end),
                 (if .oneOf then "exactly one of " + ([.oneOf[].required[]?] | names) else empty end),
                 (if .anyOf then "at least one of " + ([.anyOf[].required[]?] | names) else empty end) ]
               | if length > 0 then join("; ")
                 else "a further rule on " + (($n.properties // {}) | keys | names) + " (see the schema)" end;
    def cond: [ (.properties // {}) | to_entries[] | select(.value | has("const")) | "`\(.key)` is \(.value.const | tojson)" ] | join(" and ");
    def rules($lead):
      if has("if") then
        "- \($lead)when \(.if | cond): \(.then | parts)",
        (if has("else") then (.else | if has("if") then rules("otherwise, ") else "- otherwise: \(parts)" end) else empty end)
      else empty end;
    fields(""; (.required // [])),
    ( [ rules(""), ((.allOf // [])[] | rules("")) ] | if length > 0 then "", "Conditional:", .[] else empty end )
  ' "$s" || die "schemas/$1.json could not be read"
  printf '%s\n' "$END_LINE"
}

brief_block() { # <brief> — the list as the brief carries it now
  awk -v b="$BEGIN_RE" -v e="$END_LINE" '$0 ~ b { on = 1 } on { print } on && $0 == e { exit }' "$1"
}

steps_or_all() {
  if [ $# -gt 0 ]; then printf '%s\n' "$@"; else ls "$SCHEMAS"/*.json 2>/dev/null | while read -r f; do basename "$f" .json; done; fi
}

check() {
  local rc=0 step brief want have known name
  for step in $(steps_or_all "$@"); do
    brief="$BRIEFS/$step.md"
    [ -f "$brief" ] || die "no brief at $brief for schemas/$step.json"
    have=$(brief_block "$brief")
    [ -n "$have" ] || die "$step.md carries no fields:begin/fields:end list — run: briefs/return-fields.sh --write $step"
    want=$(render "$step") || exit 2
    if [ "$have" != "$want" ]; then
      printf '%s.md: the field list is not the one schemas/%s.json implies — run: briefs/return-fields.sh --write %s\n' "$step" "$step" "$step"
      diff <(printf '%s\n' "$have") <(printf '%s\n' "$want") | sed 's/^/  /'
      rc=1
    fi
    # The prose around the list may only name what the schema has: a field, or a value one takes.
    known=$(jq -r '[.. | objects | ((.properties // {}) | keys[]), (select(has("const")) | .const | tostring), ((.enum // [])[] | tostring)] | unique[]' "$SCHEMAS/$step.json")
    for name in $(sed -n '/^## Return/,$p' "$brief" | sed "/$BEGIN_RE/,/^$END_LINE\$/d" | grep -o '`[A-Za-z][A-Za-z]*`' | tr -d '`' | sort -u); do
      grep -qxF -- "$name" <<<"$known" && continue
      printf '%s.md: its Return section names `%s`, and schemas/%s.json has no field or value called that\n' "$step" "$name" "$step"
      rc=1
    done
  done
  return $rc
}

write() {
  local step brief block tmp
  for step in $(steps_or_all "$@"); do
    brief="$BRIEFS/$step.md"
    [ -f "$brief" ] || die "no brief at $brief"
    [ -n "$(brief_block "$brief")" ] || die "$step.md has no fields:begin/fields:end markers to write between"
    block=$(render "$step") || exit 2
    tmp=$(mktemp)
    BLOCK="$block" awk -v b="$BEGIN_RE" -v e="$END_LINE" '
      $0 ~ b { print ENVIRON["BLOCK"]; skip = 1; next }
      skip && $0 == e { skip = 0; next }
      !skip { print }' "$brief" > "$tmp" && mv "$tmp" "$brief"
    echo "wrote $step.md"
  done
}

case "${1:-}" in
  --check) shift; check "$@" ;;
  --write) shift; write "$@" ;;
  ""|-h|--help) sed -n '2,13p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; [ -n "${1:-}" ] || exit 2 ;;
  -*) die "unknown flag $1" ;;
  *) render "$1" ;;
esac
