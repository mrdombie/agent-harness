#!/usr/bin/env bash
# picture-approve.test.sh — an approved picture is published once, as a secret gist,
# and the ticket says where; a second run is a no-op; a new version publishes again.
# Run: bash "$0"
set -uo pipefail
for v in $(env | sed -n 's/^\(GIT_[A-Z_]*\)=.*/\1/p'); do unset "$v"; done
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../swarm/tests/fixture.sh"
swarm_fixture; trap 'rm -rf "$FIX"' EXIT
P="$HERE/picture-approve.sh"

# A stand-in gh: the ticket's comments live in $FIX/comments.json, a posted comment
# is appended there, and each gist made is a new id.
printf '[]\n' > "$FIX/comments.json"; : > "$FIX/gists"
cat > "$BIN/gh" <<'GH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_LOG"
case "$1 $2" in
  "issue view") [ -f "$FIX/comments-down" ] && exit 1
                jq '{comments: .}' "$FIX/comments.json" ;;
  "gist create") n=$(( $(grep -c . "$FIX/gists") + 1 )); echo "g$n" >> "$FIX/gists"
                 echo "- Creating gist home-mock.html" >&2; echo "https://gist.github.com/tester/abc$n" ;;
  "api gists/"*) id=${2#gists/}
                 jq -n --arg id "$id" '{files: {"home-mock.html": {raw_url: ("https://gist.githubusercontent.com/tester/" + $id + "/raw/0123/home-mock.html")}}}' \
                   | jq -r "$4" ;;
  "issue comment") body=""; prev=""; for a in "$@"; do [ "$prev" = --body ] && body="$a"; prev="$a"; done
                   jq --arg b "$body" '. + [{body: $b}]' "$FIX/comments.json" > "$FIX/c.json" && mv "$FIX/c.json" "$FIX/comments.json" ;;
esac
exit 0
GH
chmod +x "$BIN/gh"
PIC="$FIX/home-mock.html"
printf '<html><body><section data-evidence-shot="home-laptop-light">Home</section></body></html>\n' > "$PIC"
SHA=$(shasum -a 256 "$PIC" | awk '{print $1}')
gists() { grep -c '^gist create' "$GH_LOG" | tr -d ' '; }
posts() { grep -c '^issue comment' "$GH_LOG" | tr -d ' '; }

echo "--- the first run publishes a secret gist and says where on the ticket ---"
: > "$GH_LOG"
out=$(bash "$P" 42 "$PIC" 2>&1); rc=$?
want "it succeeds"                          "0" "$rc"
want "one gist made"                        "1" "$(gists)"
want_in "described with the project, the ticket and the file" \
  '^gist create --desc Widgets #42 approved picture: home-mock.html .*home-mock.html$' "$(cat "$GH_LOG")"
want_not_in "and never public"              '^gist create .*(--public|-p )' "$(cat "$GH_LOG")"
want "one comment posted"                   "1" "$(posts)"
body=$(jq -r '.[-1].body' "$FIX/comments.json")
want_in "the comment starts with the line machines look for" '^\*\*Picture for any machine\*\*' "$(printf '%s' "$body" | head -1)"
want_in "it names the gist"                 'https://gist\.github\.com/tester/abc1' "$body"
want_in "and the raw file"                  'https://gist\.githubusercontent\.com/tester/abc1/raw/0123/home-mock\.html' "$body"
want_in "and the file's sha"                "$SHA" "$body"
want_in "it prints the gist"                '^gist: https://gist\.github\.com/tester/abc1$' "$out"

echo "--- the same file again: nothing made, nothing posted ---"
: > "$GH_LOG"
out=$(bash "$P" 42 "$PIC" 2>&1); rc=$?
want "it succeeds"                          "0" "$rc"
want "no second gist"                       "0" "$(gists)"
want "no second comment"                    "0" "$(posts)"
want_in "it says it was already published"  '^already published: .*https://gist\.github\.com/tester/abc1' "$out"

echo "--- a new version of the picture is published again ---"
printf '<html><body><section data-evidence-shot="home-phone-dark">Home v2</section></body></html>\n' > "$PIC"
: > "$GH_LOG"
bash "$P" 42 "$PIC" >/dev/null 2>&1
want "a changed file makes a new gist"      "1" "$(gists)"
want "and a new comment"                    "1" "$(posts)"

echo "--- comments that cannot be read publish nothing ---"
: > "$GH_LOG"; touch "$FIX/comments-down"
printf 'v3\n' >> "$PIC"
bash "$P" 42 "$PIC" >/dev/null 2>&1; rc=$?
want "it fails"                             "1" "$rc"
want "and makes no gist"                    "0" "$(gists)"
rm -f "$FIX/comments-down"

echo "--- the project's name comes from harness.json when it names one ---"
jq '.projectName = "Acme Widgets"' "$HARNESS_CFG_PATH" > "$FIX/h.json" && mv "$FIX/h.json" "$HARNESS_CFG_PATH"
: > "$GH_LOG"
bash "$P" 43 "$PIC" >/dev/null 2>&1
want_in "the configured name"               '^gist create --desc Acme Widgets #43 approved picture: home-mock.html' "$(cat "$GH_LOG")"

echo "--- bad arguments touch nothing ---"
: > "$GH_LOG"
bash "$P" abc "$PIC" >/dev/null 2>&1; want "a ticket that is not a number exits 2" "2" "$?"
bash "$P" 42 "$FIX/missing.html" >/dev/null 2>&1; want "a missing file exits 2" "2" "$?"
want "and gh was never asked"               "0" "$(grep -c . "$GH_LOG" | tr -d ' ')"

exit $FAILED
