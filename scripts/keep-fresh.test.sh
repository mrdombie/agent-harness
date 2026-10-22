#!/usr/bin/env bash
# keep-fresh.test.sh — a mechanical clash is settled by its rule and pushed as a merge;
# anything else leaves the branch exactly as it was and queues a repair; a PR that is
# only behind, a claimed PR, a shadow pass and a project that has not turned it on push
# nothing. Real git: an origin, a clone, and branches that truly conflict.
# Run: bash "$0"
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/tests/lib/suite.sh" || exit 1
for v in $(env | sed -n 's/^\(GIT_[A-Z_]*\)=.*/\1/p'); do unset "$v"; done
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../swarm/tests/fixture.sh"
swarm_fixture; on_exit_keep_status 'rm -rf "$FIX"'
K="$HERE/keep-fresh.sh"
C="$STATE/coordinator"
ORIGIN="$FIX/origin.git"
export GIT_CONFIG_GLOBAL="$FIX/gitconfig" GIT_CONFIG_NOSYSTEM=1
git config --file "$GIT_CONFIG_GLOBAL" user.name tester
git config --file "$GIT_CONFIG_GLOBAL" user.email tester@example.com
git config --file "$GIT_CONFIG_GLOBAL" init.defaultBranch develop
cfg() { jq "$1" "$HARNESS_CFG_PATH" > "$FIX/h.json" && mv "$FIX/h.json" "$HARNESS_CFG_PATH"; }
cfg '.merge = {method: "squash", updateBehind: "bot", keepFresh: true, mechanical: [
       {rule: "integration", paths: ["**/.deploy-trigger"]},
       {rule: "union", paths: ["changes/*.md"]},
       {rule: "stricter-json", paths: ["ratchet/*.json"]},
       {rule: "package-scripts", paths: ["package.json"]}]}
     | .design = {surfacePaths: ["apps/web/**"], neverScreens: ["**/.deploy-trigger"]}'

# The forge, over REST: the open list, each PR's own reading, and comments that are recorded.
cat > "$BIN/gh" <<'GH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_LOG"
if [ "$1" = api ]; then
  ep=""; skip=0
  for a in "${@:2}"; do
    if [ "$skip" = 1 ]; then skip=0; continue; fi
    case "$a" in -X|-f|-F|-H|-q|--jq|--method|--input) skip=1 ;; -*) ;; *) [ -n "$ep" ] || ep="$a" ;; esac
  done
  case "$ep" in
    */issues/*/comments) for a in "$@"; do case "$a" in body=*) printf '%s\n---\n' "${a#body=}" >> "$FIX/comments.log" ;; esac; done; exit 0 ;;
    *"/pulls?"*) cat "$FIX/gh/pulls.json"; exit 0 ;;
    */pulls/*) n=${ep##*/}; [ -f "$FIX/gh/pull-$n.json" ] || exit 1; cat "$FIX/gh/pull-$n.json"; exit 0 ;;
  esac
  exit 1
fi
case "$1 $2" in
  "issue view") exit 1 ;;
  "pr list") echo '[]' ;;
esac
exit 0
GH
chmod +x "$BIN/gh"
export COORDINATOR_CLAIMS_CMD="cat $FIX/claims.json"
export COORDINATOR_FIX_LOCK="$BIN/no-fix-lock"
printf '#!/usr/bin/env bash\necho "[]"\n' > "$BIN/no-fix-lock"; chmod +x "$BIN/no-fix-lock"
unset COORDINATOR_SHADOW KEEP_FRESH_PUSH_GUARD

W="$FIX/work"     # a second clone that plays the builders and develop
fresh() {
  rm -rf "$ORIGIN" "$W" "$C" "$STATE/runs"/* "$FIX/comments.log"
  : > "$GH_LOG"; printf '[]\n' > "$FIX/claims.json"; printf '[]\n' > "$FIX/gh/pulls.json"; rm -f "$FIX"/gh/pull-*.json
  git init -q --bare "$ORIGIN"
  git clone -q "$ORIGIN" "$W" 2>/dev/null
  mkdir -p "$W/changes" "$W/ratchet" "$W/src" "$W/apps/web"
  printf '1\n' > "$W/.deploy-trigger"
  printf '# 100\n- first\n' > "$W/changes/100.md"
  printf '{\n  "a.ts": 5,\n  "b.ts": 3,\n  "list": [\n    "x"\n  ]\n}\n' > "$W/ratchet/baseline.json"
  printf '{\n  "name": "w",\n  "scripts": {\n    "build": "tsc"\n  },\n  "dependencies": {\n    "left-pad": "1.0.0"\n  }\n}\n' > "$W/package.json"
  printf 'export const a = 1;\n' > "$W/src/app.ts"
  printf 'page\n' > "$W/apps/web/page.tsx"
  git -C "$W" checkout -q -b develop && git -C "$W" add -A && git -C "$W" commit -qm base && git -C "$W" push -q origin develop
  # The coordinator's clone: origin is the forge.
  git -C "$REPO" remote remove origin 2>/dev/null; git -C "$REPO" remote add origin "$ORIGIN"
  git -C "$REPO" fetch -q origin
  for r in $(git -C "$REPO" for-each-ref --format='%(refname)' refs/keep-fresh); do git -C "$REPO" update-ref -d "$r"; done
}
# branch <n> <pr-edit> <develop-edit> — PR n's branch off develop, then develop moves.
branch() {
  local n=$1 br="tkt-$1-work"
  git -C "$W" checkout -q develop && git -C "$W" checkout -q -b "$br"
  (cd "$W" && eval "$2") && git -C "$W" add -A && git -C "$W" commit -qm "pr $n" && git -C "$W" push -q origin "$br:refs/heads/$br"
  git -C "$W" checkout -q develop
  if [ -n "$3" ]; then (cd "$W" && eval "$3") && git -C "$W" add -A && git -C "$W" commit -qm "develop for $n" && git -C "$W" push -q origin develop:refs/heads/develop; fi
}
# reads <n> <mergeable> <state> — what GitHub says of PR n now, at its pushed head.
reads() {
  local n=$1 sha; sha=$(git -C "$W" rev-parse "refs/heads/tkt-$n-work")
  jq --argjson n "$n" --arg sha "$sha" '. + [{number:$n, draft:false, head:{ref:("tkt-\($n)-work"), sha:$sha, repo:{full_name:"acme/widgets"}}}]' \
    "$FIX/gh/pulls.json" > "$FIX/gh/p.json" && mv "$FIX/gh/p.json" "$FIX/gh/pulls.json"
  jq -n --argjson n "$n" --arg sha "$sha" --argjson m "$2" --arg s "$3" '{number:$n, head:{sha:$sha}, mergeable:$m, mergeable_state:$s}' > "$FIX/gh/pull-$n.json"
}
remote_head() { git --git-dir="$ORIGIN" rev-parse "refs/heads/tkt-$1-work"; }
at_head() { git --git-dir="$ORIGIN" show "refs/heads/tkt-$1-work:$2" 2>/dev/null; }
pushed_for() { git -C "$W" rev-parse "refs/heads/tkt-$1-work"; }
live() { COORDINATOR_SHADOW=0 bash "$K" 2>&1; }
repairs() { jq -r '[.tickets[]? | select(.class == "repair") | .n] | join(" ")' "$C/queue.json" 2>/dev/null; }

echo "--- .deploy-trigger takes the integration branch's side, and the merge is pushed ---"
fresh; branch 11 'printf "pr\n" > .deploy-trigger' 'printf "dev\n" > .deploy-trigger'; reads 11 false dirty
before=$(pushed_for 11); out=$(live)
want "the branch moved"                         1 "$([ "$(remote_head 11)" != "$before" ] && echo 1)"
want "develop's side won"                        dev "$(at_head 11 .deploy-trigger)"
want "pushed as a merge: two parents"            2 "$(git --git-dir="$ORIGIN" rev-list --parents -n1 "refs/heads/tkt-11-work" | wc -w | awk '{print $1 - 1}')"
want "its first parent is the PR's old head"     "$before" "$(git --git-dir="$ORIGIN" rev-parse "refs/heads/tkt-11-work^1")"
want "its second parent is develop"              "$(git --git-dir="$ORIGIN" rev-parse refs/heads/develop)" "$(git --git-dir="$ORIGIN" rev-parse "refs/heads/tkt-11-work^2")"
want "one comment"                               1 "$(grep -c '^Kept fresh' "$FIX/comments.log" 2>/dev/null)"
want_in "the comment names the file and rule"    '`.deploy-trigger` — integration' "$(cat "$FIX/comments.log" 2>/dev/null)"
want "no repair queued"                          "" "$(repairs)"
want_in "it says what it pushed"                 '#11 pushed' "$out"

echo "--- develop deleting .deploy-trigger wins too ---"
fresh; branch 12 'printf "pr\n" > .deploy-trigger' 'git rm -q .deploy-trigger'; reads 12 false dirty
live >/dev/null
want "the file is gone from the branch"          "" "$(at_head 12 .deploy-trigger)"
want "and the branch is a merge"                 1 "$(git --git-dir="$ORIGIN" rev-parse -q --verify "refs/heads/tkt-12-work^2" >/dev/null && echo 1)"

echo "--- a changelog fragment takes the union ---"
fresh; branch 13 'printf -- "- from the PR\n" >> changes/100.md' 'printf -- "- from develop\n" >> changes/100.md'; reads 13 false dirty
live >/dev/null
f=$(at_head 13 changes/100.md)
want_in "the PR's line is kept"                  'from the PR' "$f"
want_in "develop's line is kept"                 'from develop' "$f"
want_not_in "no conflict marker"                 '^(<<<<<<<|>>>>>>>|=======)' "$f"
want_in "the comment names the union"            '`changes/100.md` — union' "$(cat "$FIX/comments.log" 2>/dev/null)"

echo "--- a ratchet baseline takes the stricter value per key and the union of entries ---"
fresh
branch 14 'printf "{\n  \"a.ts\": 4,\n  \"b.ts\": 3,\n  \"c.ts\": 1,\n  \"list\": [\n    \"x\",\n    \"y\"\n  ]\n}\n" > ratchet/baseline.json' \
          'printf "{\n  \"a.ts\": 2,\n  \"b.ts\": 1,\n  \"list\": [\n    \"x\",\n    \"z\"\n  ]\n}\n" > ratchet/baseline.json'
reads 14 false dirty; live >/dev/null
j=$(at_head 14 ratchet/baseline.json)
want "a.ts: the lower of 4 and 2"                2 "$(jq '."a.ts"' <<<"$j" 2>/dev/null)"
want "b.ts: develop lowered it"                  1 "$(jq '."b.ts"' <<<"$j" 2>/dev/null)"
want "c.ts: the PR's new entry"                  1 "$(jq '."c.ts"' <<<"$j" 2>/dev/null)"
want "list: both sides' entries"                 'x,y,z' "$(jq -r '.list | join(",")' <<<"$j" 2>/dev/null)"
want "written back in the file's own format"     "$(jq --indent 2 . <<<"$j" 2>/dev/null)" "$j"

echo "--- package.json: scripts both sides only added are unioned ---"
fresh
branch 15 'jq --indent 2 ".scripts.lint = \"eslint\"" package.json > p && mv p package.json' \
          'jq --indent 2 ".scripts.test = \"vitest\"" package.json > p && mv p package.json'
reads 15 false dirty; live >/dev/null
want "every script is there"                     'build,lint,test' "$(at_head 15 package.json | jq -r '.scripts | keys | join(",")' 2>/dev/null)"
want "nothing else changed"                      '1.0.0' "$(at_head 15 package.json | jq -r '.dependencies["left-pad"]' 2>/dev/null)"

echo "--- package.json: a clash outside scripts is real ---"
fresh
branch 16 'jq --indent 2 ".dependencies[\"left-pad\"] = \"1.1.0\"" package.json > p && mv p package.json' \
          'jq --indent 2 ".dependencies[\"left-pad\"] = \"1.2.0\"" package.json > p && mv p package.json'
reads 16 false dirty; before=$(pushed_for 16); out=$(live)
want "the branch is untouched"                   "$before" "$(remote_head 16)"
want "a repair is queued for its ticket"         16 "$(repairs)"
want_in "it names the clash"                     'outside "scripts"' "$out"
want "no comment"                                "" "$(cat "$FIX/comments.log" 2>/dev/null)"

echo "--- a real code conflict leaves the branch unchanged, even beside a mechanical one ---"
fresh
branch 17 'printf "export const a = 2;\n" > src/app.ts; printf "pr\n" > .deploy-trigger' \
          'printf "export const a = 3;\n" > src/app.ts; printf "dev\n" > .deploy-trigger'
reads 17 false dirty; before=$(pushed_for 17); out=$(live)
want "the branch is untouched"                   "$before" "$(remote_head 17)"
want "a repair is queued"                        17 "$(repairs)"
want_in "the repair note names the file"         'src/app.ts' "$(jq -r '.tickets[]?.note' "$C/queue.json" 2>/dev/null)"
want "nothing left in the clone's worktrees"     1 "$(git -C "$REPO" worktree list | wc -l | tr -d ' ')"
out=$(live)
want "the same head is not tried twice"          "" "$(grep -c 'real conflict' <<<"$out" | grep -v '^0$')"

echo "--- a PR that is only behind and clean is untouched ---"
fresh; branch 18 'printf "b\n" > src/other.ts' 'printf "dev\n" > .deploy-trigger'; reads 18 true behind
before=$(pushed_for 18); out=$(live)
want "the branch is untouched"                   "$before" "$(remote_head 18)"
want "no repair"                                 "" "$(repairs)"
want "no merge was tried"                        "" "$(grep -E 'pushed|conflict|merges cleanly' <<<"$out")"
out=$(live)
want "its state is not read again on the same heads" 1 "$(grep -c 'pulls/18$' "$GH_LOG")"

echo "--- a claimed PR, or one a live run holds, is skipped ---"
fresh; branch 19 'printf "pr\n" > .deploy-trigger' 'printf "dev\n" > .deploy-trigger'; reads 19 false dirty
printf '[{"issue": 19, "branch": "tkt-19-work"}]\n' > "$FIX/claims.json"
before=$(pushed_for 19); out=$(live)
want "the claimed branch is untouched"           "$before" "$(remote_head 19)"
want_in "it says why"                            'a claim on #19' "$out"
printf '[]\n' > "$FIX/claims.json"; fix_running 19; out=$(live)
want "a live run's branch is untouched"          "$before" "$(remote_head 19)"
want_in "it says why"                            'a live run for #19' "$out"
rm -f "$STATE/runs"/claim-19-*.json
printf 'not json' > "$FIX/claims.json"; out=$(live)
want "an unreadable claim list touches nothing"  "$before" "$(remote_head 19)"

echo "--- shadow is the default, and pushes nothing ---"
fresh; branch 20 'printf "pr\n" > .deploy-trigger' 'printf "dev\n" > .deploy-trigger'; reads 20 false dirty
before=$(pushed_for 20); out=$(bash "$K" 2>&1)
want "nothing pushed"                            "$before" "$(remote_head 20)"
want_in "it says it would"                       'would push #20' "$out"
want "no comment"                                "" "$(cat "$FIX/comments.log" 2>/dev/null)"

echo "--- off unless the project turns it on ---"
fresh; branch 21 'printf "pr\n" > .deploy-trigger' 'printf "dev\n" > .deploy-trigger'; reads 21 false dirty
cp "$HARNESS_CFG_PATH" "$FIX/cfg.bak"; cfg 'del(.merge.keepFresh)'
before=$(pushed_for 21); out=$(live)
want "nothing pushed"                            "$before" "$(remote_head 21)"
want_in "it says it is off"                      'off' "$out"
cfg '.merge.keepFresh = true | .merge.mechanical = []'; out=$(live)
want "no rules: every conflict is real"          "$before" "$(remote_head 21)"
want "and goes to a builder"                     21 "$(repairs)"
mv "$FIX/cfg.bak" "$HARNESS_CFG_PATH"

echo "--- the per-pass limit ---"
fresh
for n in 31 32 33; do branch "$n" "printf 'pr$n\n' > .deploy-trigger" ''; done
(cd "$W" && printf 'dev\n' > .deploy-trigger && git add -A && git commit -qm dev && git push -q origin develop)
for n in 31 32 33; do reads "$n" false dirty; done
cp "$HARNESS_CFG_PATH" "$FIX/cfg.bak"; cfg '.merge.keepFreshPerTick = 2'
b33=$(pushed_for 33); live >/dev/null
want "two pushed, oldest first"                  'dev dev' "$(at_head 31 .deploy-trigger) $(at_head 32 .deploy-trigger)"
want "the third waits"                           "$b33" "$(remote_head 33)"
mv "$FIX/cfg.bak" "$HARNESS_CFG_PATH"

echo "--- the sign-off guard is run on the push, and a refusal pushes nothing ---"
fresh; branch 22 'printf "pr\n" > .deploy-trigger' 'printf "dev\n" > .deploy-trigger'; reads 22 false dirty
printf '#!/usr/bin/env bash\ncat > "%s/guard.in"; echo "refused: screens"; exit 1\n' "$FIX" > "$BIN/guard"; chmod +x "$BIN/guard"
before=$(pushed_for 22); out=$(KEEP_FRESH_PUSH_GUARD="$BIN/guard" live)
want_in "the guard read the push's ref line"     "refs/heads/tkt-22-work $before" "$(cat "$FIX/guard.in" 2>/dev/null)"
want "nothing pushed"                            "$before" "$(remote_head 22)"
want "it goes to a builder"                      22 "$(repairs)"

echo "--- a sign-off survives: the merge leaves the PR's own screens as they were ---"
fresh; branch 23 'printf "pr page\n" > apps/web/page.tsx; printf "pr\n" > .deploy-trigger' 'printf "dev\n" > .deploy-trigger'; reads 23 false dirty
before=$(pushed_for 23); live >/dev/null; after=$(remote_head 23)
git -C "$REPO" fetch -q origin
moved=$(printf 'apps/web/page.tsx\n' | (cd "$REPO" && HARNESS_CFG_PATH="$HARNESS_CFG_PATH" bash "$HERE/approval-kept.sh" own-changed "$before" "$after" refs/remotes/origin/develop)); krc=$?
want "approval-kept could read both heads"       0 "$krc"
want "pushed"                                    1 "$([ "$after" != "$before" ] && echo 1)"
want "approval-kept: the PR's own screen change is the same at both heads" "" "$moved"
printf 'HEAD %s refs/heads/tkt-23-work %s\n' "$after" "$before" | (cd "$REPO" && SIGNOFF_GUARD_DRYRUN=1 HARNESS_CFG_PATH="$HARNESS_CFG_PATH" bash "$HERE/signoff-push-guard.sh" origin >/dev/null 2>&1)
want "the sign-off guard passes the same push"   0 "$?"

suite_end "$FAILED"
