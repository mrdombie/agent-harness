#!/usr/bin/env bash
# follow-up.test.sh — merge first, fix after: each review finding that does not hold the
# change is one ticket, naming the PR, the file:line and the finding; a Major at P1, a
# Minor at P3; status ready and at the front of the queue; filed once per PR and
# finding, whether this host or the forge remembers it; a Critical or a Nit never.
# Run: bash "$0"
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/tests/lib/suite.sh" || exit 1
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../driver/tests/fixture.sh"
driver_fixture; on_exit_keep_status 'rm -rf "$FIX"'
SUT="$HERE/follow-up.sh"

# The forge, for this script's REST calls: the parent's labels, the search, the create.
cat > "$FIX/fgh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FIX/fgh.log"
case "$*" in
  # The search answers as GitHub does (the caller's -q applies to it); fgh.search-fails refuses it once.
  *"-X GET search/issues"*)
     if [ -f "$FIX/fgh.search-fails" ]; then rm -f "$FIX/fgh.search-fails"; echo 'gh: HTTP 502: Bad Gateway' >&2; exit 1; fi
     if [ -f "$FIX/fgh.found" ]; then printf '{"total_count":1,"items":[{"number":%s}]}\n' "$(cat "$FIX/fgh.found")"
     else echo '{"total_count":0,"items":[]}'; fi; exit 0 ;;
  *"repos/acme/widgets/issues -X POST"*)
     n=$(( $(cat "$FIX/fgh.next" 2>/dev/null || echo 776) + 1 )); echo "$n" > "$FIX/fgh.next"
     printf '%s\0' "$@" > "$FIX/fgh.create.$n"; echo "$n"; exit 0 ;;
  *"repos/acme/widgets/labels -X POST"*) : > "$FIX/fgh.label"; exit 0 ;;
  *"repos/acme/widgets/labels/"*) [ -f "$FIX/fgh.label" ] || exit 1; echo fix-after-merge; exit 0 ;;
  *"repos/acme/widgets/issues/"*) printf 'screen:home\narea:feed\nP2\n'; exit 0 ;;
esac
exit 0
SH
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "$FIX/queue.log"\n' > "$FIX/queue"
chmod +x "$FIX/fgh" "$FIX/queue"
export FOLLOW_UP_GH="$FIX/fgh" FOLLOW_UP_QUEUE_CMD="$FIX/queue" FOLLOW_UP_LEDGER="$FIX/ledger.tsv"
for n in 777 778 779 780 781; do fix_issue "$n" OPEN ""; done

F="$FIX/findings.jsonl"
cat > "$F" <<'J'
{"id":"m1","grade":"major","file":"apps/web/a.tsx","line":3,"summary":"the save is dropped","reason":"a failure shows as success","fix":"keep the error","round":1}
{"id":"n2","grade":"minor","file":"lib/x.ts","line":2,"summary":"the log line is vague","round":1}
{"id":"c3","grade":"critical","file":"lib/y.ts","line":1,"summary":"another workspace sees the rows","round":1}
{"id":"z4","grade":"nit","file":"lib/z.ts","line":1,"summary":"taste","round":1}
J
created() { ls "$FIX"/fgh.create.* 2>/dev/null | grep -c .; }
args_of() { tr '\0' '\n' < "$FIX/fgh.create.$1"; }
export GH_BACKOFF_FILE="$FIX/gh-backoff"
reset() { rm -f "$FIX"/fgh.create.* "$FIX/fgh.next" "$FIX/fgh.found" "$FIX/ledger.tsv" "$GH_BACKOFF_FILE"; : > "$FIX/fgh.log"; : > "$FIX/queue.log"; : > "$GH_LOG"; }
case_file() { OUT=$(bash "$SUT" file 701 42 "$F" 2>&1); RC=$?; R="created=$(created)"; }

echo "--- a Major and a Minor are filed; a Critical and a Nit are not ---"
reset; case_file
want "it exits clean"                          "0" "$RC"
want "two tickets"                             "created=2" "$R"
want_in "the Major at P1"                      '^labels\[\]=P1$' "$(args_of 777)"
want_in "the Minor at P3"                      '^labels\[\]=P3$' "$(args_of 778)"
want_in "every follow-up wears fix-after-merge" '^labels\[\]=fix-after-merge$' "$(args_of 777)"
want_in "the Minor too"                        '^labels\[\]=fix-after-merge$' "$(args_of 778)"
want "the label was missing, so it was created once" "1" "$(grep -c 'labels -X POST -f name=fix-after-merge' "$FIX/fgh.log")"
want_in "the parent's screen rides along"      '^labels\[\]=screen:home$' "$(args_of 777)"
want_not_in "the parent's priority does not"   '^labels\[\]=P2$' "$(args_of 777)"
want_in "the body names the PR"                'A review finding on PR #42 \(ticket #701\)' "$(args_of 777)"
want_in "the file:line"                        'apps/web/a.tsx:3' "$(args_of 777)"
want_in "the finding"                          'the save is dropped' "$(args_of 777)"
want_in "and carries its dedupe key"           'follow-up: pr=42 finding=m1' "$(args_of 777)"
want_in "it is made ready"                     'issue edit 777 .*--add-label.status:ready' "$(tr '\n' ' ' < "$GH_LOG")"
want_in "and put at the front of the queue"    '^add 777 --front --note follow-up of PR #42: major at apps/web/a.tsx:3$' "$(cat "$FIX/queue.log")"
want_in "a Critical is never filed"            "c3 is graded 'critical', which is never filed" "$OUT"

echo "--- filed once: a second ship files nothing ---"
case_file
want "nothing new"                             "created=2" "$R"
want_in "and says they were filed"             '2 finding\(s\) on PR #42 were already filed' "$OUT"

echo "--- filed once even when this host forgot: the forge's marker is found ---"
reset; echo 900 > "$FIX/fgh.found"; case_file
want "nothing created"                         "created=0" "$R"
want_in "the key is searched for"              'follow-up: pr=42 finding=m1' "$(cat "$FIX/fgh.log")"

echo "--- a search that fails is unknown: nothing is filed, and it says so ---"
reset; : > "$FIX/fgh.search-fails"; case_file
want "nothing created on the failed search"    "created=1" "$R"
want_in "it logs unknown"                      'unknown — whether finding .* was filed could not be read' "$OUT"
want "and exits non-zero"                      "1" "$RC"

echo "--- plants: each guard out, its case fails ---"
KIT="$FIX/kit"
plant() { # <label> <exact text to delete> <setup> <the result the guard prevents>
  rm -rf "$KIT"; mkdir -p "$KIT"; cp -R "$HERE" "$KIT/scripts"; cp -R "$HERE/../swarm" "$HERE/../driver" "$KIT/"
  python3 -I -c 'import sys; p, l = sys.argv[1], sys.argv[2]; s = open(p).read(); n = s.count(l); open(p, "w").write(s.replace(l, "", 1)); sys.exit(0 if n == 1 else 1)' "$KIT/scripts/follow-up.sh" "$2" \
    || { want "plant landed: $1" "landed" "missed"; return; }
  reset; eval "$3"; SUT="$KIT/scripts/follow-up.sh" case_file; want "planted ($1): the case now fails" "$4" "$R"
}
plant "the ledger" '  if n=$(awk -F'"'"'\t'"'"' -v p="$PR" -v i="$id" '"'"'$1 == p && $2 == i { print $3; exit }'"'"' "$LEDGER" 2>/dev/null) && [ -n "$n" ]; then
    had=$((had + 1)); continue
  fi' 'SUT="$KIT/scripts/follow-up.sh" case_file' "created=4"
plant "the forge search" '  if [ -n "$n" ]; then printf '"'"'%s\t%s\n'"'"' "$key" "$n" >> "$LEDGER"; had=$((had + 1)); continue; fi' 'echo 900 > "$FIX/fgh.found"' "created=2"
plant "the grade map" '    major) pri="$P_MAJOR" ;; minor) pri="$P_MINOR" ;;' ':' "created=0"
plant "the follow-up label" ' -f "labels[]=$FU_LABEL"' 'case_file() { OUT=$(bash "$SUT" file 701 42 "$F" 2>&1); RC=$?; R="label=$(args_of 777 | grep -c "^labels\[\]=fix-after-merge$")"; }' "label=0"
plant "the label's creation" '  ensure_fu_label
' 'rm -f "$FIX/fgh.label"; case_file() { OUT=$(bash "$SUT" file 701 42 "$F" 2>&1); RC=$?; R="made=$(grep -c "labels -X POST" "$FIX/fgh.log")"; }' "made=0"

suite_end "$FAILED"
