#!/usr/bin/env bash
# Plant tests for guard-pre-approved-writes.sh. Every route that widens the key
# is refused, unrelated edits pass, and each route's guard switched off in a copy
# lets its case through, so the case is proved to test that guard.
D="$(cd "$(dirname "$0")" && pwd)"; G="$D/guard-pre-approved-writes.sh"
KIT="$(cd "$D/.." && pwd)"
fail=0
TDIR=$(mktemp -d); trap 'rm -rf "$TDIR"' EXIT
ok(){ printf 'ok    %s\n' "$1"; }
bad(){ printf 'FAIL  %s\n' "$1"; fail=1; }

# GIT_* dropped: under a git hook they would aim the scratch repo's commands at the real one.
for v in $(env | sed -n 's/^\(GIT_[A-Z_]*\)=.*/\1/p'); do unset "$v"; done
R="$TDIR/repo"; C="$R/.claude/harness.json"
mkdir -p "$R/.claude"; git -C "$R" init -q
g(){ git -C "$R" -c user.name=t -c user.email=t@t "$@"; }
BASE='{
  "repo": "x/y",
  "preApprovedWrites": { "environments": ["Staging"], "decided": "op, 2026-10-14" }
}'
WIDE='{
  "repo": "x/y",
  "preApprovedWrites": { "environments": ["Staging", "Production"], "decided": "op, 2026-10-14" }
}'
SAME='{
  "repo": "x/z",
  "preApprovedWrites": { "environments": ["Staging"], "decided": "op, 2026-10-14" }
}'
printf '%s\n' "$BASE" > "$C"; g add .claude && g commit -qm base
g checkout -qb wide; printf '%s\n' "$WIDE" > "$C"; g commit -qam wide
g checkout -q -; g checkout -qb same; printf '%s\n' "$SAME" > "$C"; g commit -qam same
g checkout -q -
g diff HEAD wide > "$TDIR/wide.patch"; g diff HEAD same > "$TDIR/same.patch"
g update-ref refs/remotes/origin/develop HEAD   # the shared integration branch, at base
ln "$C" "$TDIR/hardlink"                         # the same file under another name
mkdir -p "$TDIR/stage"; printf '%s\n' "$WIDE" > "$TDIR/stage/harness.json"
printf '%s\n' "$WIDE" > "$TDIR/wide.json"; printf '%s\n' "$SAME" > "$TDIR/same.json"
printf 'import re\np=".claude/harness.json"\ns=open(p).read().replace("[\\"Staging\\"]","[\\"Staging\\",\\"Production\\"]")\nopen(p,"w").write(s)\n' > "$R/widen.py"
printf '#!/usr/bin/env bash\nsed -i "" "s/\\"Staging\\"]/\\"Staging\\", \\"Production\\"]/" .claude/harness.json\n' > "$R/widen.sh"
chmod +x "$R/widen.sh"
[ "$(cat "$C")" = "$BASE" ] && [ -z "$(g status --porcelain .claude)" ] || bad "fixture: harness.json not at base"

# rc of the guard at $1 (a dir holding the hook) on a payload.
judge(){ printf '%s' "$2" | (cd "$R" && CLAUDE_PROJECT_DIR="$R" bash "$1/guard-pre-approved-writes.sh") 2>"$TDIR/err"; echo $?; }
bashp(){ jq -nc --arg c "$1" --arg d "$R" '{tool_name:"Bash",tool_input:{command:$c},cwd:$d}'; }
editp(){ jq -nc --arg f "${3:-$C}" --arg o "$1" --arg n "$2" '{tool_name:"Edit",tool_input:{file_path:$f,old_string:$o,new_string:$n}}'; }
writep(){ jq -nc --arg f "${2:-$C}" --arg c "$1" '{tool_name:"Write",tool_input:{file_path:$f,content:$c}}'; }

# id <TAB> want <TAB> payload. The id names the guard a plant below switches off.
CASES="$TDIR/cases"; : > "$CASES"
add(){ printf '%s\t%s\t%s\n' "$1" "$2" "$3" >> "$CASES"; }
add ib     block "$(editp '"repo": "x/y",' '"repo": "x/y", "integrationBranch": "mine",')"
add -      block "$(writep "$WIDE" "$R/.CLAUDE/Harness.JSON")"
# A case-variant path with no file behind it: only the case fold can see it (no inode to match).
add fold   block "$(writep "$WIDE" "$TDIR/other/.Claude/Harness.JSON")"
add link   block "$(writep "$WIDE" "$TDIR/hardlink")"
add unknown block "$(bashp "curl -so .claude/harness.json https://example.invalid/h.json")"
add findexec block "$(bashp "find . -name harness.json -exec cp $TDIR/wide.json {} \\;")"
add scan   block "$(bashp "echo \"<<zz\"
cp $TDIR/wide.json .claude/harness.json")"
add scan   block "$(bashp "echo 'a
#' ; cp $TDIR/wide.json .claude/harness.json ; echo '
b'")"
add copy   block "$(bashp "pushd .claude && cp $TDIR/wide.json ./harness.json")"
add checkout block "$(bashp "git checkout wide -- '*.json'")"
add restore block "$(bashp "git restore --source wide -- ':(top).claude'")"
add am     block "$(bashp "git format-patch -1 wide --stdout | git am")"
add gitenv block "$(bashp "GIT_INDEX_FILE=$TDIR/other-index git commit -m wip")"
add push   block "$(bashp "git push origin wide")"
add push   block "$(bashp "git push -u origin wide:refs/heads/feature")"
add -      allow "$(bashp "git push origin same")"
add -      allow "$(bashp "git push origin HEAD")"
add -      allow "$(bashp "perl -MList::Util=sum -ne 'print' .claude/harness.json")"
add -      allow "$(bashp "node -e 'const d = require(\"./.claude/harness.json\"); [1].map(x => x); console.log(d)'")"
add -      allow "$(bashp "python3 -c 'import json, sys; json.dump(json.load(open(\".claude/harness.json\")), sys.stdout)'")"
add -      allow "$(bashp "find . -name harness.json")"
add -      allow "$(bashp "sed -n 1,5p .claude/harness.json")"
add -      allow "$(bashp "git status && git diff -- .claude/harness.json && git log -1")"
add -      allow "$(bashp "git am --abort")"
add edit   block "$(editp '["Staging"]' '["Staging", "Production"]')"
add edit   block "$(editp '"decided": "op, 2026-10-14"' '"decided": "op, 2026-10-15"')"
add edit   block "$(editp '"repo": "x/y",' '"repo": "x/y", "preApprovedWrites": {"environments":["Production"],"decided":"op, 2026-10-14"},')"
add edit   block "$(editp '"repo": "x/y",' '"repo": "x/y",,')"
add write  block "$(writep "$WIDE")"
add -      allow "$(editp '"repo": "x/y"' '"repo": "x/z"')"
add -      allow "$(editp '"preApprovedWrites": { "environments": ["Staging"], "decided": "op, 2026-10-14" }' '"other": 1')"
add -      allow "$(editp '"preApprovedWrites"' '"preApprovedWritesOld"')"
add -      allow "$(writep "$SAME")"
add -      allow "$(writep "$WIDE" "$R/notes.json")"
add -      allow "$(editp 'Staging' 'Production' "$R/README.md")"
add inplace block "$(bashp 'sed -i "" "s/\"Staging\"]/\"Staging\", \"Production\"]/" .claude/harness.json')"
add inplace block "$(bashp "perl -pi -e 's/Staging/Production/' .claude/harness.json")"
add redirect block "$(bashp "echo '$WIDE' > .claude/harness.json")"
add redirect block "$(bashp "jq '.preApprovedWrites.environments += [\"Production\"]' .claude/harness.json > .claude/harness.json")"
add heredoc block "$(bashp "cat > .claude/harness.json <<'EOF'
$WIDE
EOF")"
add -      allow "$(bashp "cat > .claude/harness.json <<'EOF'
$SAME
EOF")"
add tee    block "$(bashp "tee .claude/harness.json <<'EOF'
$WIDE
EOF")"
add copy   block "$(bashp "cp $TDIR/wide.json .claude/harness.json")"
add copy   block "$(bashp "mv $TDIR/wide.json $R/.claude/harness.json")"
add copy   block "$(bashp "jq . $TDIR/wide.json > /tmp/h.tmp && mv /tmp/h.tmp-missing .claude/harness.json")"
add copy   block "$(bashp "cp $TDIR/stage/harness.json .claude/")"
add -      allow "$(bashp "cp $TDIR/same.json .claude/harness.json")"
add -      allow "$(bashp "cp .claude/harness.json /tmp/backup.json")"
add script block "$(bashp "python3 -c 'import json; d=json.load(open(\".claude/harness.json\")); d[\"preApprovedWrites\"][\"environments\"].append(\"Production\"); json.dump(d, open(\".claude/harness.json\",\"w\"))'")"
add script block "$(bashp "python3 widen.py")"
add script block "$(bashp "python3 - <<'PY'
import json
d = json.load(open('.claude/harness.json'))
d['preApprovedWrites']['environments'].append('Production')
json.dump(d, open('.claude/harness.json', 'w'))
PY")"
add shell  block "$(bashp "bash -c 'sed -i \"\" s/Staging/Production/ .claude/harness.json'")"
add shell  block "$(bashp "bash widen.sh")"
add exec   block "$(bashp "./widen.sh")"
add checkout block "$(bashp "git checkout wide -- .claude/harness.json")"
add checkout block "$(bashp "cd / && git -C $R checkout wide -- .claude")"
add -      allow "$(bashp "git checkout HEAD -- .claude/harness.json")"
add -      allow "$(bashp "git checkout wide")"
add restore block "$(bashp "git restore --source=wide .claude/harness.json")"
add restore block "$(bashp "git restore -s wide -- .claude/")"
add apply  block "$(bashp "git apply $TDIR/wide.patch")"
add apply  block "$(bashp "git apply < $TDIR/wide.patch")"
add -      allow "$(bashp "git apply $TDIR/same.patch")"
add gh     block "$(bashp "gh api -X PUT repos/x/y/contents/.claude/harness.json -f content=abc")"
add -      allow "$(bashp "cat .claude/harness.json")"
add -      allow "$(bashp "jq .preApprovedWrites .claude/harness.json > /tmp/out.json")"
add -      allow "$(bashp "git commit -m 'edit harness.json docs'")"
add -      allow "$(bashp "python3 -c 'import json; print(json.load(open(\".claude/harness.json\")))'")"

run_cases(){ # $1 hook dir, $2 id filter ("" = all), $3 case file; prints "<id> <want> <got>" per case
  while IFS=$'\t' read -r id want p; do
    [ -n "$2" ] && [ "$id" != "$2" ] && continue
    rc=$(judge "$1" "$p"); got=allow; [ "$rc" -eq 2 ] && got=block
    [ "$rc" -ne 0 ] && [ "$rc" -ne 2 ] && got="error$rc"
    printf '%s\t%s\t%s\t%s\n' "$id" "$want" "$got" "$(jq -r '.tool_input.command // (.tool_name+" "+.tool_input.file_path)' <<<"$p" | head -1 | cut -c1-90)"
  done < "${3:-$CASES}"
}

# 1. The live guard.
while IFS=$'\t' read -r id want got what; do
  [ "$want" = "$got" ] && ok "$want  $what" || bad "$want wanted, got $got: $what"
done < <(run_cases "$D" "")
judge "$D" "$(editp '["Staging"]' '["Staging", "Production"]')" >/dev/null
grep -q 'Ask the operator' "$TDIR/err" && ok "a refusal tells the agent to ask the operator" || bad "the refusal does not say to ask the operator"

# 2. git commit: staged widening refused, staged unrelated change passes. The
# working tree is put back to base each time, so only the index carries the change.
printf '%s\n' "$WIDE" > "$C"; g add .claude; printf '%s\n' "$BASE" > "$C"
[ "$(judge "$D" "$(bashp 'git commit -m wip')")" -eq 2 ] && ok "block  git commit of a staged widening" || bad "a staged widening commits"
printf '%s\n' "$SAME" > "$C"; g add .claude; printf '%s\n' "$BASE" > "$C"
[ "$(judge "$D" "$(bashp 'git commit -m wip')")" -eq 0 ] && ok "allow  git commit of an unrelated staged change" || bad "an unrelated staged change is refused"
printf '%s\n' "$WIDE" > "$C"; g add .claude; printf '%s\n' "$BASE" > "$C"
mkdir -p "$TDIR/pc/lib"; cp "$D/guard-pre-approved-writes.sh" "$TDIR/pc/"; cp "$D/lib/python.sh" "$TDIR/pc/lib/"
python3 - "$D/guard-pre-approved-writes.py" "$TDIR/pc/guard-pre-approved-writes.py" <<'PY'
import sys
s=open(sys.argv[1]).read(); old="        judge(vh, at(''), cfg + ' (staged for commit)')"
assert s.count(old)==1; open(sys.argv[2],'w').write(s.replace(old,"        pass"))
PY
grep -q "(staged for commit)" "$TDIR/pc/guard-pre-approved-writes.py" && bad "commit plant did not land"
[ "$(judge "$TDIR/pc" "$(bashp 'git commit -m wip')")" -eq 0 ] && ok "plant: commit check off, the staged widening passes" ||
  bad "plant: commit check off, yet still refused: the case proves nothing"
g reset -q -- .claude; printf '%s\n' "$BASE" > "$C"

# 2b. The widening in the working tree only: every way a commit can take it is refused.
WT="$TDIR/wtcases"; : > "$WT"
addw(){ printf '%s\t%s\t%s\n' "$1" "$2" "$3" >> "$WT"; }
addw commitwt block "$(bashp 'git commit -am wip')"
addw commitwt block "$(bashp 'git add -A && git commit -m wip')"
addw commitwt block "$(bashp 'git -c alias.ci=commit ci -am wip')"
addw commitwt block "$(bashp "cd / && git --git-dir=$R/.git --work-tree=$R commit -am wip")"
addw commitwt block "$(bashp 'git commit -m wip -- "*.json"')"
printf '%s\n' "$WIDE" > "$C"
while IFS=$'\t' read -r id want got what; do
  [ "$want" = "$got" ] && ok "$want  (widened working tree) $what" || bad "$want wanted, got $got: (widened working tree) $what"
done < <(run_cases "$D" "" "$WT")
printf '%s\n' "$BASE" > "$C"
[ "$(cat "$C")" = "$BASE" ] && [ -z "$(g status --porcelain .claude)" ] || bad "commit cases left harness.json changed"

# 3. Death plants: each route's guard switched off in a copy lets its blocked cases through.
plant(){ # id, old, new
  local dir="$TDIR/p-$1"; mkdir -p "$dir/lib"
  cp "$D/guard-pre-approved-writes.sh" "$dir/"; cp "$D/lib/python.sh" "$dir/lib/"
  python3 - "$D/guard-pre-approved-writes.py" "$dir/guard-pre-approved-writes.py" "$2" "$3" <<'PY' || { bad "plant $1 did not land"; return; }
import sys
s=open(sys.argv[1]).read(); old,new=sys.argv[3],sys.argv[4]
if s.count(old)!=1: sys.exit(1)
open(sys.argv[2],'w').write(s.replace(old,new))
PY
  grep -qF -- "$3" "$dir/guard-pre-approved-writes.py" || { bad "plant $1: copy carries no plant"; return; }
  local n=0 leaked=0
  while IFS=$'\t' read -r id want got what; do
    n=$((n+1)); [ "$got" = allow ] && leaked=$((leaked+1))
  done < <(run_cases "$dir" "$1" "${4:-$CASES}")
  [ "$n" -gt 0 ] && [ "$leaked" -eq "$n" ] && ok "plant $1 off: all $n of its cases pass through" ||
    bad "plant $1 off: only $leaked of $n cases pass through, so those cases test something else"
}
plant edit     "    if not is_cfg(path):
        return" "    return"
plant write    "        after = ti.get('content', '')" "        return"
plant inplace  "        if name in INPLACE and names_cfg(args[1:], cwd) and \\" "        if False and \\"
plant redirect "                else:
                    refuse('this redirects" "                elif False:
                    refuse('this redirects"
plant heredoc  "                    judge(before, (before or '') + here if op == '>>' else here, path)" "                    pass"
plant tee      "                        judge(read(path), here, path)" "                        pass"
plant copy     "def judge_copy(name, args, cwd):" "def judge_copy(name, args, cwd):
    return"
plant script   "def judge_script(name, args, cwd, here, depth):" "def judge_script(name, args, cwd, here, depth):
    return"
plant shell    "            if inner:
                judge_bash(inner, cwd, depth + 1)" "            if False:
                judge_bash(inner, cwd, depth + 1)"
plant checkout "            judge(read(cfg), after, cfg + ' (git checkout %s)' % (ref or 'from the index'))" "            pass"
plant restore  "                judge(read(cfg), at(src) if src else at(''), cfg + ' (git restore)')" "                pass"
plant apply    "            judge(base, simulate_patch(base, text, rest), cfg + ' (git %s)' % sub)" "            pass"
plant gh       "            if names_cfg(args[1:], cwd) and any(" "            if False and any("
plant exec     "            judge_bash(src, cwd, depth + 1)
            return" "            return"

plant fold     "os.path.basename(p).lower() == 'harness.json' and os.path.basename(os.path.dirname(p)).lower() == '.claude'" "os.path.basename(p) == 'harness.json' and os.path.basename(os.path.dirname(p)) == '.claude'"
plant link     "        return (st.st_dev, st.st_ino) in KNOWN" "        return False"
plant ib       "    return tuple(json.dumps(obj[k], sort_keys=True, separators=(',', ':')) if k in obj else 'ABSENT' for k in KEYS)" "    return tuple(json.dumps(obj[k], sort_keys=True, separators=(',', ':')) if k in obj else 'ABSENT' for k in KEYS[:1]) + ('',)"
plant unknown  "        if name not in READERS and" "        if False and"
plant findexec "                refuse('this runs find over" "                continue
                refuse('this runs find over"
plant scan     "        if c in '\\'\"':
            q = c" "        if False:
            q = c"
plant am       "                refuse('this applies a patch the guard cannot read" "                continue
                refuse('this applies a patch the guard cannot read"
plant push     "        judge_push(top, rest, cfg, rel)" "        pass"
plant gitenv   "        if any(a in ('commit', 'push'," "        if False and any(a in ('commit', 'push',"
printf '%s\n' "$WIDE" > "$C"
plant commitwt "        judge(vh, read(cfg), cfg + ' (in the working tree, which this commit can take)')" "        pass" "$WT"
printf '%s\n' "$BASE" > "$C"

# 4. Registered on both matchers: an unregistered guard is a dead guard.
reg(){ jq -e --arg m "$2" '[.hooks.PreToolUse[] | select(.matcher == $m) | .hooks[].command | select(test("guard-pre-approved-writes.sh"))] | length == 1' "$1" >/dev/null; }
reg "$KIT/hooks/hooks.json" Bash && reg "$KIT/hooks/hooks.json" 'Write|Edit' &&
  ok "registered on Bash and on Write|Edit" || bad "not registered on both matchers"
jq '(.hooks.PreToolUse[].hooks) |= map(select(.command | test("guard-pre-approved-writes") | not))' "$KIT/hooks/hooks.json" > "$TDIR/hooks.json"
reg "$TDIR/hooks.json" Bash && bad "registration plant did not land, or the check reads something else" ||
  ok "registration deleted: the check fails"

[ "$(cat "$C")" = "$BASE" ] || bad "the suite changed the fixture: a guarded case was run, not judged"
[ "$fail" -eq 0 ] && echo "guard-pre-approved-writes: all cases pass"
exit $fail
