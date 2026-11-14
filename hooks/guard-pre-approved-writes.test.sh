#!/usr/bin/env bash
# Plant tests for guard-pre-approved-writes.sh. Every route that widens the key
# is refused, unrelated edits pass, and each route's guard switched off in a copy
# lets its case through, so the case is proved to test that guard.
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/tests/lib/suite.sh" || exit 1
D="$(cd "$(dirname "$0")" && pwd)"; G="$D/guard-pre-approved-writes.sh"
KIT="$(cd "$D/.." && pwd)"
fail=0
TDIR=$(mktemp -d); on_exit_keep_status '[ -n "${KEEP:-}" ] || rm -rf "$TDIR"'
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
printf '%s\n' "$BASE" > "$C"
# A repo test that writes a scratch harness.json in its own temp fixture, the shape of driver/tests/*.test.sh.
mkdir -p "$R/tests"
SCRATCH_TEST='#!/usr/bin/env bash
F=$(mktemp -d); mkdir -p "$F/.claude"; printf "{}\n" > "$F/.claude/harness.json"
jq ".preApprovedWrites = {\"environments\": [\"Production\"]}" "$F/.claude/harness.json" > "$F/h.json" && mv "$F/h.json" "$F/.claude/harness.json"
rm -rf "$F"'
WIDEN_TEST='#!/usr/bin/env bash
sed -i "" "s/\"Staging\"]/\"Staging\", \"Production\"]/" .claude/harness.json'
printf '%s\n' "$SCRATCH_TEST" > "$R/tests/scratch.test.sh"
printf '%s\n' "$SCRATCH_TEST" > "$R/tests/edited.test.sh"
chmod +x "$R/tests/scratch.test.sh"
g add .claude tests && g commit -qm base
g checkout -qb wide; printf '%s\n' "$WIDE" > "$C"; g commit -qam wide
g checkout -q -; g checkout -qb same; printf '%s\n' "$SAME" > "$C"; g commit -qam same
g checkout -q -
g diff HEAD wide > "$TDIR/wide.patch"; g diff HEAD same > "$TDIR/same.patch"
# A real bare origin: the push judge asks the remote, never a local ref.
git init -q --bare "$TDIR/origin.git"; git -C "$TDIR/origin.git" symbolic-ref HEAD refs/heads/develop
g remote add origin "$TDIR/origin.git"; g push -q origin HEAD:refs/heads/develop; g fetch -q origin
# Agent-made tests that widen the real file: one modified from the merged copy, one untracked,
# one committed locally but never merged to origin's integration branch.
printf '%s\n' "$WIDEN_TEST" > "$R/tests/edited.test.sh"
printf '%s\n' "$WIDEN_TEST" > "$R/tests/evil.test.sh"
printf '%s\n' "$WIDEN_TEST" > "$R/tests/local.test.sh"; g add tests/local.test.sh && g commit -qm local
ln "$C" "$TDIR/hardlink"                         # the same file under another name
mkdir -p "$TDIR/stage"; printf '%s\n' "$WIDE" > "$TDIR/stage/harness.json"
printf '%s\n' "$WIDE" > "$TDIR/wide.json"; printf '%s\n' "$SAME" > "$TDIR/same.json"
printf 'import re\np=".claude/harness.json"\ns=open(p).read().replace("[\\"Staging\\"]","[\\"Staging\\",\\"Production\\"]")\nopen(p,"w").write(s)\n' > "$R/widen.py"
printf '#!/usr/bin/env bash\nsed -i "" "s/\\"Staging\\"]/\\"Staging\\", \\"Production\\"]/" .claude/harness.json\n' > "$R/widen.sh"
chmod +x "$R/widen.sh"
# A script that only reads the file: an assignment naming the path, a test, a query. Then the
# same script with one more line, once per way of writing the file.
READS='#!/usr/bin/env bash
f(){ local cfg="${HARNESS_CFG_PATH:-$1/.claude/harness.json}" c=""
  [[ -f "$cfg" ]] && c=$(jq -r ".repo // empty" "$cfg"); echo "$c"; }
export HARNESS_CFG_PATH=.claude/harness.json
test -f .claude/harness.json && grep -c repo .claude/harness.json
f .'
printf '%s\n' "$READS" > "$R/reads.sh"
wscript(){ printf '%s\n%s\n' "$READS" "$2" > "$R/w-$1.sh"; }
wscript redirect "jq . $TDIR/wide.json > .claude/harness.json"
wscript tee      "jq . $TDIR/wide.json | tee .claude/harness.json"
wscript sed      'sed -i "" "s/\"Staging\"]/\"Staging\", \"Production\"]/" .claude/harness.json'
wscript jqmv     "jq '.preApprovedWrites.environments += [\"Production\"]' .claude/harness.json > $TDIR/h.tmp && mv $TDIR/h.tmp .claude/harness.json"
wscript cp       "cp $TDIR/wide.json .claude/harness.json"
wscript python   "python3 -c 'open(\".claude/harness.json\", \"w\").write(open(\"$TDIR/wide.json\").read())'"
wscript node     "node -e 'require(\"fs\").writeFileSync(\".claude/harness.json\", \"{}\")'"
WFORMS="redirect tee sed jqmv cp python node"
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
add fetchfake block "$(bashp "git fetch . +wide:refs/remotes/origin/develop")"
add gitprotsh block "$(bashp "git rev-parse wide > .git/refs/remotes/origin/develop")"
add updidx block "$(bashp "git update-index --cacheinfo 100644,\$(git rev-parse wide:.claude/harness.json),.claude/harness.json")"
add updref block "$(bashp "git update-ref --stdin <<'EOF'
update refs/remotes/origin/develop wide
EOF")"
add gitcfg block "$(bashp "git config set remote.origin.url $TDIR/evil.git")"
add gitcfg block "$(bashp "git config --file .git/config remote.origin.url $TDIR/evil.git")"
add gitcfgedit block "$(bashp "git config --edit")"
add -      allow "$(bashp "git fetch origin && git fetch --all")"
add pushsrc block "$(bashp "c=\$(git rev-parse wide); git push origin \"\$c\":refs/heads/develop")"
add pushsrc block "$(bashp "git push origin \"\$(git rev-parse wide)\":develop")"
add -      block "$(bashp "git push origin 'refs/heads/*:refs/heads/*'")"
add gitdir block "$(bashp "git -C .git config remote.origin.url $TDIR/evil.git")"
add scriptgit block "$(bashp "python3 -c \"open('.git/config','a').write('[remote]')\"")"
add -      allow "$(bashp "cat .git/HEAD && ls .git/refs/heads")"
add -      allow "$(bashp "git config user.email t@example.com && git config --get remote.origin.url")"
add parsefail block "$(bashp "git push origin wide; echo \"unterminated")"
add -      block "$(bashp "git push origin wide; echo \$'it\\'s'")"
add -      block "$(bashp "git push -f origin wide:develop")"
add gitcfg block "$(bashp "git config remote.origin.push +refs/heads/wide:refs/heads/develop")"
add gitcfg block "$(bashp "git config --global url./tmp/fake.insteadOf https://github.com/")"
add gitcfgc block "$(bashp "git -c remote.origin.url=/tmp/fake push origin HEAD")"
add remote block "$(bashp "git remote set-url origin /tmp/fake.git")"
add plumbing block "$(bashp "git update-ref refs/remotes/origin/develop wide")"
add plumbing block "$(bashp "git replace HEAD wide")"
add gitprot block "$(writep "[remote \"origin\"]" "$R/.git/config")"
add gitprotsh block "$(bashp "printf 'git add -A' >> .git/hooks/pre-commit")"
add gitprotsh block "$(bashp "cp $TDIR/wide.json .git/hooks/pre-commit")"
add -      allow "$(bashp "cat .git/config && git config --get remote.origin.url")"
add -      allow "$(bashp "rm .claude/harness.json")"
add -      allow "$(bashp "if jq -e .repo .claude/harness.json >/dev/null; then echo yes; fi")"
add -      allow "$(bashp "for f in .claude/*.json; do jq . \"\$f\"; done")"
add -      allow "$(bashp "python3 -c \"import json; d = json.load(open('.claude/harness.json')); print(d.get('a'))\"")"
add -      allow "$(bashp "node -e 'process.stdout.write(JSON.stringify(require(\"./.claude/harness.json\")))'")"
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
add -      allow "$(bashp "bash tests/scratch.test.sh")"
add -      allow "$(bashp "./tests/scratch.test.sh 2>&1 | tail -5")"
add -      allow "$(bashp "cd tests && bash scratch.test.sh")"
add copy   block "$(bashp "bash tests/scratch.test.sh && cp $TDIR/wide.json .claude/harness.json")"
add redirect block "$(bashp "bash tests/scratch.test.sh > .claude/harness.json")"
add trusted block "$(bashp "bash tests/edited.test.sh")"
add trusted block "$(bashp "bash tests/evil.test.sh")"
add trusted block "$(bashp "bash tests/local.test.sh")"
add trustarg block "$(bashp "HARNESS_CFG=.claude/harness.json bash tests/scratch.test.sh")"
add trustarg block "$(bashp "bash tests/scratch.test.sh .claude/harness.json")"
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
# Writes are judged, not mentions.
add declare allow "$(bashp "bash reads.sh")"
add declare allow "$(bashp "export HARNESS_CFG_PATH=.claude/harness.json && jq -r .repo \"\$HARNESS_CFG_PATH\"")"
add dbracket allow "$(bashp "[[ -f .claude/harness.json ]] && echo yes")"
add declsub block "$(bashp "export X=\"\$(cp $TDIR/wide.json .claude/harness.json)\"")"
add declsub block "$(bashp "export X=\"\`cp $TDIR/wide.json .claude/harness.json\`\"")"
add declopen block "$(bashp "export X='\$(cp $TDIR/wide.json .claude/harness.json'")"
add pattern allow "$(bashp "case x in widen.s?) echo y;; esac")"
for w in $WFORMS; do add shell block "$(bashp "bash w-$w.sh")"; done
add -      allow "$(bashp "bash $KIT/scripts/builder-install.sh")"

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
s=open(sys.argv[1]).read(); old="        judge(vh, at(''), cfg + ' (staged for commit)', shared)"
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
addw commitwt block "$(bashp "git commit -am w; echo \$'it\\'s'")"
printf '%s\n' "$WIDE" > "$C"
while IFS=$'\t' read -r id want got what; do
  [ "$want" = "$got" ] && ok "$want  (widened working tree) $what" || bad "$want wanted, got $got: (widened working tree) $what"
done < <(run_cases "$D" "" "$WT")
printf '%s\n' "$BASE" > "$C"

# A copy of the hook with one line of the judge replaced; prints its dir, or nothing.
plant_dir(){ local dir="$TDIR/p-$1"; mkdir -p "$dir/lib"; cp "$D/guard-pre-approved-writes.sh" "$dir/"; cp "$D/lib/python.sh" "$dir/lib/"
  python3 -c 'import sys
s=open(sys.argv[1]).read(); old,new=sys.argv[3],sys.argv[4]
if s.count(old)!=1: sys.exit(1)
open(sys.argv[2],"w").write(s.replace(old,new))' "$D/guard-pre-approved-writes.py" "$dir/guard-pre-approved-writes.py" "$2" "$3" && echo "$dir"; }

# 2c. The operator widened the key on develop; an agent merging develop in takes it. Allowed:
# taking the shared value is not self-approval. Plant: the shared allowance off refuses it.
g update-ref refs/remotes/origin/develop wide; printf '%s\n' "$WIDE" > "$C"; g add .claude
[ "$(judge "$D" "$(bashp 'git commit --no-edit')")" -eq 0 ] && ok "allow  concluding a merge that brings the operator's value from develop" ||
  bad "concluding a merge of the operator's value is refused"
pd=$(plant_dir shared "    if shared is not None and value_of(shared) == a and a[0] != 'ABSENT':" "    if False:")
[ -n "$pd" ] && grep -q '^    if False:$' "$pd/guard-pre-approved-writes.py" || bad "plant shared did not land"
[ "$(judge "$pd" "$(bashp 'git commit --no-edit')")" -eq 2 ] && ok "plant: shared allowance off, the merge is refused, so the allowance is what lets it through" ||
  bad "plant: shared allowance off, yet the merge passes: the case proves nothing"
g reset -q -- .claude; printf '%s\n' "$BASE" > "$C"; g update-ref refs/remotes/origin/develop "$(g rev-parse HEAD)"

# 2e. A forged local origin ref does not move what the push is judged against.
g update-ref refs/remotes/origin/develop wide
[ "$(judge "$D" "$(bashp 'git push origin wide:refs/heads/develop')")" -eq 2 ] &&
  ok "block  push onto develop with origin/develop forged locally to match" || bad "a forged local origin ref lets the widening push"
pd=$(plant_dir localref "    sha, default = remote_head(top, 'HEAD')" "    sha, default = (git(top, 'rev-parse', 'origin/develop') or '').strip(), 'develop'")
[ -n "$pd" ] || bad "plant localref did not land"
[ "$(judge "$pd" "$(bashp 'git push origin wide:refs/heads/develop')")" -eq 0 ] &&
  ok "plant: local ref trusted, the forged push passes, so asking the remote is the guard" ||
  bad "plant: local ref trusted, yet still refused: the case proves nothing"
g update-ref refs/remotes/origin/develop "$(g rev-parse HEAD)"

# 2f. A peer moves develop on the remote after this clone last fetched: a feature push still passes.
P2="$TDIR/peer"; git clone -q "$TDIR/origin.git" "$P2"
git -C "$P2" -c user.name=t -c user.email=t@t commit -q --allow-empty -m peer && git -C "$P2" push -q origin HEAD:develop
[ "$(judge "$D" "$(bashp 'git push -u origin same')")" -eq 0 ] && ok "allow  feature push while develop moved on the remote" ||
  bad "a feature push is refused because develop moved on the remote: $(cat "$TDIR/err")"

# 2d. A configured push refspec is what a bare `git push` sends.
g config remote.origin.push '+refs/heads/wide:refs/heads/develop'
[ "$(judge "$D" "$(bashp 'git push origin')")" -eq 2 ] && ok "block  bare git push with a configured refspec sending the widening" ||
  bad "a configured push refspec sends the widening unjudged"
pd=$(plant_dir pushcfg "            specs = (git(top, 'config', '--get-all', 'remote.%s.push' % (pos[0] if pos else 'origin')) or '').split()" "            specs = []")
[ -n "$pd" ] || bad "plant pushcfg did not land"
[ "$(judge "$pd" "$(bashp 'git push origin')")" -eq 0 ] && ok "plant: configured refspec ignored, the push passes" ||
  bad "plant: configured refspec ignored, yet still refused: the case proves nothing"
g config --unset remote.origin.push
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
                judge_bash(inner, cwd, depth + 1, inner_script or script, bool(inner_script))" "            if False:
                pass"
plant checkout "            judge(read(cfg), after, cfg + ' (git checkout %s)' % (ref or 'from the index'), shared)" "            pass"
plant restore  "                judge(read(cfg), at(src) if src else at(''), cfg + ' (git restore)', shared)" "                pass"
plant apply    "            judge(base, simulate_patch(base, text, rest), cfg + ' (git %s)' % sub, shared)" "            pass"
plant gh       "            if names_cfg(args[1:], cwd) and any(" "            if False and any("
plant exec     "            judge_bash(src, cwd, depth + 1, p)
            return" "            return"
plant declsub  "                for sub in inner or []:" "                for sub in []:"
plant declopen "                if inner is None and names_cfg([a], cwd):" "                if False:"
# The other way: with the rule off, a script that only reads the file is refused again.
allowed_by(){ # id, old, new: every allow case of that id is refused once the rule is off
  local pd n=0 held=0; pd=$(plant_dir "$1" "$2" "$3"); [ -n "$pd" ] || { bad "plant $1 did not land"; return; }
  while IFS=$'\t' read -r id want got what; do
    n=$((n+1)); [ "$got" = block ] && held=$((held+1))
  done < <(run_cases "$pd" "$1")
  [ "$n" -gt 0 ] && [ "$held" -eq "$n" ] && ok "plant $1 off: all $n of its reads are refused, so the rule is what allows them" ||
    bad "plant $1 off: only $held of $n reads are refused: the allow cases prove nothing"
}
allowed_by declare  "DECLARE = {'local', 'export', 'declare', 'typeset', 'readonly'}" "DECLARE = set()"
allowed_by pattern  "        pattern = '/' not in args[0] and any(c in args[0] for c in '*?[')" "        pattern = False"
allowed_by dbracket"'source', '.', 'bash', 'sh', 'zsh', '[['}" "'source', '.', 'bash', 'sh', 'zsh'}"

# 3b. A refusal inside a script names the script and the line it could not pass.
for w in $WFORMS; do
  judge "$D" "$(bashp "bash w-$w.sh")" >/dev/null
  grep -qF "line 7 of $R/w-$w.sh" "$TDIR/err" && ok "block  w-$w.sh: the refusal names line 7 of the script" ||
    bad "w-$w.sh: the refusal does not name the line: $(cat "$TDIR/err")"
  # The same script without its last line only reads the file.
  sed '$d' "$R/w-$w.sh" > "$R/r-$w.sh"
  [ "$(judge "$D" "$(bashp "bash r-$w.sh")")" -eq 0 ] && ok "allow  w-$w.sh without its write" || bad "w-$w.sh without its write is refused: $(cat "$TDIR/err")"
done
pd=$(plant_dir line "        if track:" "        if False:"); [ -n "$pd" ] || bad "plant line did not land"
judge "$pd" "$(bashp "bash w-tee.sh")" >/dev/null
grep -q "Blocked" "$TDIR/err" && ! grep -q "line 7 of" "$TDIR/err" && ok "plant: line tracking off, the refusal names no line" ||
  bad "plant: line tracking off, yet the refusal still names the line (or nothing was refused)"

# 3c. The kit's own scripts. A guard is in a kit when the folder above it carries the plugin manifest.
mkkit(){ mkdir -p "$1/.claude-plugin" "$1/hooks/lib" "$1/scripts"; printf '{}\n' > "$1/.claude-plugin/plugin.json"
  cp "$D/guard-pre-approved-writes.sh" "$D/guard-pre-approved-writes.py" "$1/hooks/"; cp "$D/lib/python.sh" "$1/hooks/lib/"
  cp "$KIT/scripts/builder-install.sh" "$1/scripts/"
  # Stands for any kit script the judge would refuse line by line.
  printf '#!/usr/bin/env bash\ncp %s .claude/harness.json\n' "$TDIR/wide.json" > "$1/scripts/kit-writes.sh"; chmod +x "$1/scripts/kit-writes.sh"; }
FK="$TDIR/kit"; mkkit "$FK"
NK="$TDIR/nokit/hooks"; mkdir -p "$NK/lib"; cp "$D/guard-pre-approved-writes.sh" "$D/guard-pre-approved-writes.py" "$NK/"; cp "$D/lib/python.sh" "$NK/lib/"
want(){ # want, hook dir, command, label
  local rc got=allow; rc=$(judge "$2" "$(bashp "$3")"); [ "$rc" -eq 2 ] && got=block; [ "$rc" -ne 0 ] && [ "$rc" -ne 2 ] && got="error$rc"
  [ "$got" = "$1" ] && ok "$1  $4" || bad "$1 wanted, got $got: $4: $(cat "$TDIR/err")"; }
want allow "$FK/hooks" "bash $FK/scripts/builder-install.sh"              "the kit's unmodified installer"
want allow "$FK/hooks" "cd $TDIR && bash $FK/scripts/builder-install.sh $R 2>&1 | tail -4" "the kit's unmodified installer, given a tree"
want allow "$FK/hooks" "bash $FK/scripts/kit-writes.sh"                   "an unmodified kit script is not scanned"
want allow "$FK/hooks" "$FK/scripts/kit-writes.sh"                        "an unmodified kit script run by name"
want block "$FK/hooks" "bash $FK/scripts/kit-writes.sh .claude/harness.json" "a kit script aimed at the file by an argument is judged on its content"
want block "$FK/hooks" "HARNESS_CFG_PATH=.claude/harness.json $FK/scripts/kit-writes.sh" "a kit script aimed at the file by a variable is judged on its content"
want block "$NK"       "bash $FK/scripts/kit-writes.sh"                   "the same script, judged by a guard outside that kit"
# Plant: kit trust off, the kit script is read again.
FK2="$TDIR/kit2"; mkkit "$FK2"
python3 - "$FK2/hooks/guard-pre-approved-writes.py" <<'PY' || bad "plant kit did not land"
import sys
s=open(sys.argv[1]).read(); old="    p = os.path.realpath(path)\n    root = os.path.realpath(KIT)\n"
assert s.count(old)==1; open(sys.argv[1],'w').write(s.replace(old, old + "    return False\n"))
PY
want block "$FK2/hooks" "bash $FK2/scripts/kit-writes.sh"                 "plant: kit trust off, the kit script is refused, so the trust is what lets it run"
# A copy is the kit's while its bytes are; changed, it is judged on what it now says.
mkdir -p "$R/scripts"; cp "$FK/scripts/kit-writes.sh" "$R/scripts/kit-writes.sh"; cp "$FK/scripts/builder-install.sh" "$R/scripts/"
want allow "$FK/hooks" "bash scripts/kit-writes.sh"                       "a byte-identical copy of a kit script"
printf '# a note\n' >> "$R/scripts/kit-writes.sh"
want block "$FK/hooks" "bash scripts/kit-writes.sh"                       "a modified copy of a kit script is judged on its content, not its name"
printf '# a note\n' >> "$R/scripts/builder-install.sh"
want allow "$FK/hooks" "bash scripts/builder-install.sh"                  "a modified installer that still only reads the file"
printf 'cp %s .claude/harness.json\n' "$TDIR/wide.json" >> "$R/scripts/builder-install.sh"
want block "$FK/hooks" "bash scripts/builder-install.sh"                  "a modified installer that writes the file"
grep -qE "line [0-9]+ of $R/scripts/builder-install.sh: \`cp " "$TDIR/err" && ok "block  the refusal names the added line" ||
  bad "the modified installer's refusal does not name the added line: $(cat "$TDIR/err")"
# The installer read line by line, outside any kit: allowed for what it does, and refused again
# on its assignment once naming the path counts as a write.
want allow "$NK" "bash $KIT/scripts/builder-install.sh"                   "the installer judged on its content"
pd=$(plant_dir instdecl "DECLARE = {'local', 'export', 'declare', 'typeset', 'readonly'}" "DECLARE = set()"); [ -n "$pd" ] || bad "plant instdecl did not land"
want block "$pd" "bash $KIT/scripts/builder-install.sh"                   "plant: assignments judged as writes, the installer is refused as it was"
grep -qE "\`local\` names harness.json.*line [0-9]+ of $KIT/scripts/builder-install.sh: \`local cfg=" "$TDIR/err" &&
  ok "block  that refusal is the one reported, on the installer's own line" || bad "the planted refusal is not the reported one: $(cat "$TDIR/err")"

plant fold     "os.path.basename(p).lower() == 'harness.json' and os.path.basename(os.path.dirname(p)).lower() == '.claude'" "os.path.basename(p) == 'harness.json' and os.path.basename(os.path.dirname(p)) == '.claude'"
plant link     "        return (st.st_dev, st.st_ino) in KNOWN" "        return False"
plant ib       "    return tuple(json.dumps(obj[k], sort_keys=True, separators=(',', ':')) if k in obj else 'ABSENT' for k in KEYS)" "    return tuple(json.dumps(obj[k], sort_keys=True, separators=(',', ':')) if k in obj else 'ABSENT' for k in KEYS[:1]) + ('',)"
plant unknown  "        if name not in READERS and (names_cfg(" "        if False and (names_cfg("
plant findexec "                refuse('this runs find over" "                continue
                refuse('this runs find over"
plant scan     "        if c in '\\'\"':
            q = c" "        if False:
            q = c"
plant am       "                refuse('this applies a patch the guard cannot read" "                continue
                refuse('this applies a patch the guard cannot read"
plant push     "        judge_push(top, rest, cfg, rel)" "        pass"
plant gitenv   "        if any(a in ('commit', 'push'," "        if False and any(a in ('commit', 'push',"
plant parsefail "        if re.search(r'harness\\.json|\\.claude|\\.git/|\\bgit\\b|" "        if False and re.search(r'harness\\.json|\\.claude|\\.git/|\\bgit\\b|"
plant gitcfg   "            if hit:
                refuse('this sets git config" "            if False:
                refuse('this sets git config"
plant pushsrc  "        if any(c in src for c in '\$\`*') or not git(top, 'rev-parse', '--verify', '-q', src + '^{commit}'):
            refuse(" "        if False:
            refuse("
plant gitdir   "        top = repo  # inside .git" "        return
        top = repo  # inside .git"
plant scriptgit "        if ('harness.json' in t.lower() or GITPROT_TXT.search(t)) and WRITE_MARK.search(t):" "        if 'harness.json' in t.lower() and WRITE_MARK.search(t):"
plant fetchfake "    elif sub == 'fetch' and pos and" "    elif False and"
plant updidx   "    elif sub == 'update-index' and (" "    elif False and ("
plant updref   "            or (sub == 'update-ref' and '--stdin' in rest" "            or False and (sub == 'update-ref' and '--stdin' in rest"
plant gitcfgedit "        if any(a in ('-e', '--edit') for a in rest) or (pos and pos[0] == 'edit'):" "        if False:"
plant gitcfgc  "            elif GIT_KEYS.match(v.split('=', 1)[0]):" "            elif False:"
plant remote   "    elif sub == 'remote' and pos and" "    elif False and"
plant plumbing "    elif sub == 'replace' or (sub in" "    elif False and (sub in"
plant gitprot  "    if is_gitprot(path):
        gitprot_refuse(path)" "    pass"
plant gitprotsh "def gitprot_refuse(path):" "def gitprot_refuse(path):
    return"
plant trusted  "    return bool(merged and disk) and merged.strip() == disk.strip()" "    return True"
plant trustarg "    return len(args) == 1 + (os.path.basename(args[0]) in SHELLS) and not names_cfg(list(assigns.values()), cwd)" "    return True"
# The other way: trust off, the merged test is judged line by line and refused again.
pd=$(plant_dir notrust "    if not TEST_SCRIPT.search(os.path.basename(p)) or not os.path.isfile(p):" "    if True:")
[ -n "$pd" ] || bad "plant notrust did not land"
[ "$(judge "$pd" "$(bashp 'bash tests/scratch.test.sh')")" -eq 2 ] &&
  ok "plant: merged-test trust off, the scratch-fixture test is refused, so the trust is what lets it run" ||
  bad "plant: merged-test trust off, yet the test still runs: the allow case proves nothing"
printf '%s\n' "$WIDE" > "$C"
plant commitwt "        judge(vh, read(cfg), cfg + ' (in the working tree, which this commit can take)', shared)" "        pass" "$WT"
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
suite_end "$fail"
