#!/usr/bin/env bash
# ci-evidence.sh — a pixel PR's pictures come from CI. Each state status reads off
# the PR and its checks, wait's exit for each, only CI's own block counts as
# evidence, a verdict covers a head only across carry commits, the routes list is
# read the way CI reads it, and local capture is off unless a person turns it on.
# Then the plants: each guard made to match nothing, and the case it guards goes red.
set -uo pipefail
for v in $(env | sed -n 's/^\(GIT_[A-Za-z_]*\)=.*/\1/p'); do unset "$v"; done
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SB=$(mktemp -d "${TMPDIR:-/tmp}/ci-evidence-XXXXXX"); trap 'rm -rf "$SB"' EXIT
mkdir -p "$SB/bin" "$SB/fx"
cat > "$SB/bin/gh" <<'SH'
#!/usr/bin/env bash
# pr view <n> --json … [-q <jq>]   → fx/pr-<n>.json
# api <path> …                     → fx/<path with / ? = & as _>, or fail
if [ "$1 $2" = "pr view" ]; then
  f="$CIE_FX/pr-$3.json"; [ -f "$f" ] || exit 1
  q=""; while [ $# -gt 0 ]; do [ "$1" = "-q" ] && q="$2"; shift; done
  if [ -n "$q" ]; then jq -r "$q" "$f"; else cat "$f"; fi
  exit 0
fi
if [ "$1" = api ]; then
  k=$(printf '%s' "$2" | tr '/?=&' '____'); f="$CIE_FX/$k"
  [ -f "$f" ] && cat "$f" && exit 0
  exit 1
fi
exit 1
SH
chmod +x "$SB/bin/gh"
export PATH="$SB/bin:$PATH" CIE_FX="$SB/fx" CI_EVIDENCE_REPO="o/r" CI_EVIDENCE_EVERY=0
unset HARNESS_CFG HARNESS_LOCAL_EVIDENCE REPO_SLUG
fail=0
ok()  { echo "  ok   — $1"; }
bad() { echo "  FAIL — $1"; fail=1; }

A=$(printf 'a%.0s' {1..40}); B=$(printf 'b%.0s' {1..40}); C=$(printf 'c%.0s' {1..40})
h() { printf '%s%038d' e "$1"; }   # a distinct head per case
blockfor() { # <evsha> <name>…
  local s="$1"; shift
  printf '<!-- ci-evidence:begin -->\\n## Evidence (CI-captured)\\n<!-- ci-evidence-head:%s -->\\n' "$s"
  for n in "$@"; do printf -- '- [x](https://github.com/o/r/blob/%s/docs/evidence/7/%s.png)\\n' "$s" "$n"; done
  printf '<!-- ci-evidence:end -->'
}
pr() { # <n> <head> <draft> <body> [<branch>] [<closes, space-separated>] — closes ticket 7 unless told
  jq -n --arg h "$2" --argjson d "$3" --arg b "$4" --arg br "${5:-feature/x}" --arg c "${6-7}" \
    '{headRefOid:$h, isDraft:$d, body:$b, headRefName:$br,
      closingIssuesReferences:[$c | split(" ")[] | select(. != "") | {number:tonumber}]}' > "$SB/fx/pr-$1.json"
}
runs() { # <head> <capture status/conclusion|-> <decide status/conclusion|->
  local cap="$2" dec="$3"
  jq -n --arg c "$cap" --arg d "$dec" '{check_runs: (
      [ if $c == "-" then empty else {name:"Capture and pin the evidence", started_at:"2026-10-16T10:00:00Z",
          status:($c|split("/")[0]), conclusion:(($c|split("/")[1]) | if . == "" then null else . end)} end,
        if $d == "-" then empty else {name:"Does this diff need pixels?", started_at:"2026-10-16T09:59:00Z",
          status:($d|split("/")[0]), conclusion:(($d|split("/")[1]) | if . == "" then null else . end)} end ])}' \
    > "$SB/fx/repos_o_r_commits_$1_check-runs_per_page_100"
}
compare() { # <base> <head> <status> <parents> <file>…
  local b="$1" h="$2" st="$3" p="$4"; shift 4
  jq -n --arg st "$st" --argjson p "$p" --args '{status:$st,
      commits:[{parents:[range($p)|{sha:"x"}], commit:{message:"chore(evidence): shots"}}],
      files:[$ARGS.positional[] | {filename:.}]}' "$@" > "$SB/fx/repos_o_r_compare_$b...$h"
}
body_routes=$'## Summary\nx\n\n## Evidence routes\n- /dashboard\n- /settings/team\n\n'

# 1 pinned at the head
pr 1 "$A" false "$body_routes$(printf "$(blockfor "$A" dashboard)")"
# 2 pinned below the head, only evidence after it
pr 2 "$B" false "$(printf "$(blockfor "$A" dashboard)")"; compare "$A" "$B" ahead 1 docs/evidence/7/dashboard.png
# 3 pinned below the head, code after it, capture running
pr 3 "$(h 3)" false "$(printf "$(blockfor "$A" dashboard)")"; compare "$A" "$(h 3)" ahead 1 apps/web/page.tsx; runs "$(h 3)" in_progress/ -
# 4 nothing pinned, a draft
pr 4 "$A" true "$body_routes"
# 5 the decide check failed (no routes)
pr 5 "$(h 5)" false "no routes here"; runs "$(h 5)" - completed/failure
# 6 the capture failed
pr 6 "$(h 6)" false "$body_routes"; runs "$(h 6)" completed/failure completed/success
# 7 capture skipped, nothing pinned → none
pr 7 "$(h 7)" false "$body_routes"; runs "$(h 7)" completed/skipped completed/success
# 8 nothing yet
pr 8 "$(h 8)" false "$body_routes"
# 9 a hand-pinned link outside CI's block is not CI's evidence
pr 9 "$(h 9)" false "$body_routes- [hand](https://github.com/o/r/blob/$A/docs/evidence/7/hand.png)"
# 10 capture skipped on a develop merge, earlier pins stand
pr 10 "$(h 10)" false "$(printf "$(blockfor "$A" dashboard)")"; compare "$A" "$(h 10)" ahead 2 apps/web/x.tsx
prfiles() { local n="$1"; shift; jq -n --args '[$ARGS.positional[] | {filename:.}]' "$@" > "$SB/fx/repos_o_r_pulls_${n}_files_per_page_100"; }
prfiles 10 apps/web/page.tsx docs/evidence/7/dashboard.png
# 16 the merge changed a file this PR's screen imports through an alias
pr 16 "$(h 16)" false "$(printf "$(blockfor "$A" dashboard)")"; compare "$A" "$(h 16)" ahead 2 apps/web/src/components/band.tsx
prfiles 16 apps/web/page.tsx
printf "import { Band } from '@/components/band'\n" > "$SB/fx/repos_o_r_contents_apps_web_page.tsx_ref_$(h 16)"
# 17 more files changed than GitHub lists: unreadable, so stale
pr 17 "$(h 17)" false "$(printf "$(blockfor "$A" dashboard)")"; compare "$A" "$(h 17)" ahead 2 $(seq -f 'lib/f%g.ts' 1 300)
prfiles 17 apps/web/other.tsx
# CI's own evidence commit A wrote dashboard.png and hand.png; B is a builder's commit of renders.
P=$(printf 'f%.0s' {1..40})   # the head CI photographed: its capture passed there
cicommit() { local sha="$1" msg="$2"; shift 2; jq -n --arg m "$msg" --arg p "$P" --args '{commit:{message:$m}, parents:[{sha:$p}], files:[$ARGS.positional[] | {filename:., status:"added"}]}' "$@" > "$SB/fx/repos_o_r_commits_$sha"; }
cicommit "$A" "chore(evidence): screenshots captured by ci for #7" docs/evidence/7/dashboard.png docs/evidence/7/hand.png
cicommit "$B" "docs(evidence): owner-only sharing renders" docs/evidence/7/dashboard.png
runs "$P" completed/success completed/success
# 18 a commit dressed as CI's, on a head where no capture ran
C2=$(printf 'd%.0s' {1..40}); Q=$(printf '9%.0s' {1..40})
jq -n --arg q "$Q" '{commit:{message:"chore(evidence): screenshots captured by ci for #7"}, parents:[{sha:$q}], files:[{filename:"docs/evidence/7/dashboard.png", status:"added"}]}' > "$SB/fx/repos_o_r_commits_$C2"
runs "$Q" completed/failure completed/success
runs "$Q" completed/failure completed/success
pr 18 "$C2" false "$(printf "$(blockfor "$C2" dashboard)")"
# 19–23 CI keys the folder by ticket while the reader holds the PR, and CI pushes from
# inside its capture job: the capture is still running when the commit lands, and the
# push starts a run that cancels it. Read with a project config naming CI's identity.
blockat() { # <evsha> <folder> <name>…
  local s="$1" d="$2"; shift 2
  printf '<!-- ci-evidence:begin -->\\n<!-- ci-evidence-head:%s -->\\n' "$s"
  for n in "$@"; do printf -- '- [x](https://github.com/o/r/blob/%s/docs/evidence/%s/%s.png)\\n' "$s" "$d" "$n"; done
  printf '<!-- ci-evidence:end -->'
}
evcommit() { # <sha> <parent> <author email> <file>…
  local sha="$1" par="$2" em="$3"; shift 3
  jq -n --arg p "$par" --arg em "$em" --args '{commit:{message:"chore(evidence): screenshots captured by ci for #42",
      author:{name:"ci-bot", email:$em}}, parents:[{sha:$p}], files:[$ARGS.positional[] | {filename:., status:"added"}]}' "$@" \
    > "$SB/fx/repos_o_r_commits_$sha"
}
ev() { printf 'ab%038d' "$1"; }; par() { printf 'cd%038d' "$1"; }
printf '{"branchPrefix":"tk-","evidence":{"authorEmail":"ci@example.com"}}' > "$SB/ids.json"
# 19 the folder is the branch's ticket, no closing reference; capture still running
evcommit "$(ev 19)" "$(par 19)" ci@example.com docs/evidence/42/dashboard.png; runs "$(par 19)" in_progress/ completed/success
pr 19 "$(ev 19)" false "$body_routes$(printf "$(blockat "$(ev 19)" 42 dashboard)")" tk-42/slug ""
printf 'PNG19' > "$SB/fx/repos_o_r_contents_docs_evidence_42_dashboard.png_ref_$(ev 19)"
# 20 the folder is a ticket the PR closes; the capture ended cancelled after CI's push
evcommit "$(ev 20)" "$(par 20)" ci@example.com docs/evidence/42/dashboard.png; runs "$(par 20)" completed/cancelled completed/success
pr 20 "$(ev 20)" false "$(printf "$(blockat "$(ev 20)" 42 dashboard)")" feature/x "42"
# 21 the folder belongs to no ticket of this PR
evcommit "$(ev 21)" "$(par 21)" ci@example.com docs/evidence/99/dashboard.png; runs "$(par 21)" completed/success completed/success
pr 21 "$(ev 21)" false "$(printf "$(blockat "$(ev 21)" 99 dashboard)")" tk-42/slug "42"
# 22 the right folder and subject, but not CI's author
evcommit "$(ev 22)" "$(par 22)" builder@example.com docs/evidence/42/dashboard.png; runs "$(par 22)" completed/success completed/success
pr 22 "$(ev 22)" false "$(printf "$(blockat "$(ev 22)" 42 dashboard)")" tk-42/slug "42"
# 23 the folder is the PR's own number
evcommit "$(ev 23)" "$(par 23)" ci@example.com docs/evidence/23/dashboard.png; runs "$(par 23)" completed/success completed/success
pr 23 "$(ev 23)" false "$(printf "$(blockat "$(ev 23)" 23 dashboard)")" feature/x ""
# 13 CI's block, and a link at CI's sha outside it
pr 13 "$A" false "$(printf "$(blockfor "$A" dashboard)")
- [hand](https://github.com/o/r/blob/$A/docs/evidence/7/hand.png)"
# 14 inside CI's block, a shot CI's commit did not write (a builder's, from an older head)
pr 14 "$A" false "$(printf "$(blockfor "$A" dashboard builder-old)")"
# 15 a block naming a commit that is not CI's
pr 15 "$B" false "$(printf "$(blockfor "$B" dashboard)")"
# 11 capture skipped, but the merge's resolution edited this PR's own screen file
pr 11 "$(h 11)" false "$(printf "$(blockfor "$A" dashboard)")"; compare "$A" "$(h 11)" ahead 2 apps/web/room.tsx lib/other.ts
prfiles 11 apps/web/room.tsx
# 12 capture skipped, and the merge changed a file this PR's screen imports
pr 12 "$(h 12)" false "$(printf "$(blockfor "$A" dashboard)")"; compare "$A" "$(h 12)" ahead 2 apps/web/parts/band.tsx
prfiles 12 apps/web/page.tsx
printf "import { Band } from './parts/band'\nexport default 1\n" > "$SB/fx/repos_o_r_contents_apps_web_page.tsx_ref_$(h 12)"

S="$HERE/ci-evidence.sh"
st() { bash "$1" status "$2" 2>/dev/null | sed -n 's/^state=//p'; }
w()  { perl -e 'alarm shift; exec @ARGV' 8 bash "$1" wait "$2" 1 >/dev/null 2>&1; echo $?; }

core() { # <script> → failed cases, one per line
  local s=$1 o
  o=$(st "$s" 1); [ "$o" = pinned ] || echo "shots pinned at the head read $o"
  o=$(st "$s" 2); [ "$o" = pinned ] || echo "shots with only evidence after them read $o"
  o=$(st "$s" 3); [ "$o" = pending ] || echo "shots with code after them and a capture running read $o"
  o=$(st "$s" 4); [ "$o" = off ] || echo "a draft read $o"
  o=$(st "$s" 5); [ "$o" = failed ] || echo "a failed decide check read $o"
  o=$(st "$s" 6); [ "$o" = failed ] || echo "a failed capture read $o"
  o=$(st "$s" 7); [ "$o" = none ] || echo "a skipped capture with nothing pinned read $o"
  o=$(st "$s" 8); [ "$o" = pending ] || echo "no capture yet read $o"
  o=$(st "$s" 9); [ "$o" = pending ] || echo "a hand-pinned link outside the block read $o"
  runs "$(h 10)" completed/skipped completed/success
  o=$(st "$s" 10); [ "$o" = pinned ] || echo "a skipped capture over earlier pins read $o"
  rm -f "$SB/fx/repos_o_r_commits_$(h 10)_check-runs_per_page_100"
  runs "$(h 11)" completed/skipped completed/success
  o=$(st "$s" 11); [ "$o" = stale ] || echo "a skipped capture after a merge that edited this PR's screen read $o"
  o=$(w "$s" 11); [ "$o" = 6 ] || echo "wait on stale shots exited $o"
  runs "$(h 12)" completed/skipped completed/success
  o=$(st "$s" 12); [ "$o" = stale ] || echo "a skipped capture after a merge that changed an import of this PR's screen read $o"
  runs "$(h 16)" completed/skipped completed/success
  o=$(st "$s" 16); [ "$o" = stale ] || echo "a skipped capture after a merge that changed an alias import read $o"
  runs "$(h 17)" completed/skipped completed/success
  o=$(st "$s" 17); [ "$o" = stale ] || echo "a comparison GitHub may have cut read $o"
  o=$(st "$s" 10); [ "$o" = pending ] || echo "a merge after the pins with no verdict from CI read $o"
  o=$(w "$s" 1); [ "$o" = 0 ] || echo "wait on pinned exited $o"
  o=$(w "$s" 6); [ "$o" = 1 ] || echo "wait on failed exited $o"
  o=$(w "$s" 7); [ "$o" = 4 ] || echo "wait on none exited $o"
  o=$(w "$s" 4); [ "$o" = 5 ] || echo "wait on a draft exited $o"
  o=$(w "$s" 8); [ "$o" = 3 ] || echo "wait on nothing-yet exited $o (want 3, still waiting)"
  o=$(bash "$s" shots 9 2>/dev/null | grep -c .); [ "$o" = 0 ] || echo "shots listed a link outside CI's block"
  o=$(bash "$s" shots 1 2>/dev/null | grep -c .); [ "$o" = 1 ] || echo "shots did not list CI's link ($o)"
  o=$(bash "$s" shots 13 2>/dev/null | grep -c .); [ "$o" = 1 ] || echo "shots listed a link outside CI's block ($o)"
  o=$(bash "$s" shots 14 2>/dev/null | grep -c .); [ "$o" = 1 ] || echo "shots took a file CI's commit did not write ($o)"
  bash "$s" shots 14 2>&1 >/dev/null | grep -q 'refused: docs/evidence/7/builder-old.png' || echo "a builder-made shot was not named as refused"
  o=$(st "$s" 15); [ "$o" != pinned ] || echo "a block at a builder's commit read pinned"
  o=$(st "$s" 18); [ "$o" != pinned ] || echo "a commit dressed as CI's, with no capture run behind it, read pinned"
  o=$(bash "$s" shots 15 2>/dev/null | grep -c .); [ "$o" = 0 ] || echo "shots took links at a commit that is not CI's ($o)"
  (unset HARNESS_LOCAL_EVIDENCE; bash "$s" local) && echo "local capture is on with no flag set"
  HARNESS_LOCAL_EVIDENCE=1 bash "$s" local || echo "local capture stays off with the flag set"
  printf '%s' "$body_routes" | bash "$s" routes >/dev/null 2>&1 || echo "a good routes list was refused"
  printf '## Summary\nx\n' | bash "$s" routes >/dev/null 2>&1 && echo "a body with no routes list passed"
  printf '## Evidence routes\n- dashboard\n' | bash "$s" routes >/dev/null 2>&1 && echo "a route without a leading / passed"
  return 0
}

# fetch: the shot lands on disk and carries the route it came from
printf 'PNGDATA' > "$SB/fx/repos_o_r_contents_docs_evidence_7_dashboard.png_ref_$A"
printf 'PNGDATA' > "$SB/fx/repos_o_r_contents_docs_evidence_7_hand.png_ref_$A"
fetch_case() { # <script>
  local d="$SB/got-$RANDOM" line
  line=$(bash "$1" fetch 1 "$d" 2>/dev/null | head -1)
  [ "$(cat "$d/dashboard.png" 2>/dev/null)" = PNGDATA ] || echo "fetch did not write the shot"
  [ "$(cut -f4 <<<"$line")" = /dashboard ] || echo "fetch did not name the route ($line)"
  [ "$(cut -f3 <<<"$line")" = light ] || echo "fetch did not name the theme ($line)"
  bash "$1" fetch 9 "$d-hand" >/dev/null 2>&1 && echo "fetch took a hand-pinned shot from outside CI's block"
  bash "$1" fetch 13 "$d-13" >/dev/null 2>&1; [ -f "$d-13/hand.png" ] && echo "fetch took a hand-pinned shot from outside CI's block"
  bash "$1" fetch 14 "$d-14" >/dev/null 2>&1; [ -f "$d-14/builder-old.png" ] && echo "fetch took a file CI's commit did not write"
  bash "$1" fetch 15 "$d-15" >/dev/null 2>&1 && echo "fetch took shots at a commit that is not CI's"
  return 0
}

# at-head, in a scratch repo
R="$SB/repo"; git init -q "$R"; cd "$R" || exit 1
git config user.email t@t; git config user.name t
echo a > page.tsx; git add .; git commit -qm code; V=$(git rev-parse HEAD)
mkdir -p docs/evidence/7; echo p > docs/evidence/7/x.png; git add .; git commit -qm "chore(evidence): screenshots"; E=$(git rev-parse HEAD)
git commit -q --allow-empty -m "chore: verdict" -m "Design-Critic: SHIP (agent) 0123456789ab"; T=$(git rev-parse HEAD)
git checkout -qb code; echo b > page.tsx; git commit -qam "fix: more"; X=$(git rev-parse HEAD)
git checkout -q -b side "$V"; echo s > side.txt; git add .; git commit -qm side
git checkout -q -b merged "$T"; git merge -q --no-ff --no-edit side; M=$(git rev-parse HEAD)
git checkout -q "$T"
athead() { # <script> → failed cases
  local s=$1
  bash "$s" at-head "$T" "$T" >/dev/null || echo "a verdict at the head was refused"
  bash "$s" at-head "$V" "$E" >/dev/null || echo "a verdict under CI's evidence commit was refused"
  bash "$s" at-head "$V" "$T" >/dev/null || echo "a verdict under evidence plus an empty trailer was refused"
  bash "$s" at-head "$V" "$X" >/dev/null && echo "a verdict with a code commit after it passed"
  bash "$s" at-head "$V" "$M" >/dev/null && echo "a verdict with a merge after it passed"
  bash "$s" at-head "$X" "$T" >/dev/null && echo "a verdict on other code passed"
  # the evidence dir is the project's, read from its config
  printf '{"evidence":{"dir":"shots"}}' > "$SB/h.json"
  HARNESS_CFG="$SB/h.json" bash "$s" at-head "$V" "$E" >/dev/null && echo "the evidence dir from project config was ignored"
  return 0
}
cd "$HERE" || exit 1

tickets() { # <script> → failed cases
  local s=$1 o d="$SB/got19-$RANDOM"
  o=$(HARNESS_CFG="$SB/ids.json" st "$s" 19); [ "$o" = pinned ] || echo "shots in the branch ticket's folder, capture still running, read $o"
  HARNESS_CFG="$SB/ids.json" bash "$s" fetch 19 "$d" >/dev/null 2>&1; [ "$(cat "$d/dashboard.png" 2>/dev/null)" = PNG19 ] || echo "fetch refused shots in the branch ticket's folder"
  o=$(HARNESS_CFG="$SB/ids.json" st "$s" 20); [ "$o" = pinned ] || echo "shots in a closed ticket's folder, capture cancelled after the push, read $o"
  o=$(HARNESS_CFG="$SB/ids.json" st "$s" 21); [ "$o" != pinned ] || echo "shots in another ticket's folder read pinned"
  o=$(HARNESS_CFG="$SB/ids.json" st "$s" 22); [ "$o" != pinned ] || echo "an evidence commit by someone other than CI's author read pinned"
  o=$(HARNESS_CFG="$SB/ids.json" st "$s" 23); [ "$o" = pinned ] || echo "shots in the PR number's folder read $o"
  return 0
}
all() { core "$1"; fetch_case "$1"; tickets "$1"; (cd "$R" && athead "$1"); }

echo "ci-evidence"
r=$(all "$S"); [ -z "$r" ] && ok "every state, wait exit, fetch, verdict and routes case reads right" || { bad "cases failed:"; printf '         %s\n' "$r"; }

plant() { # <desc> <old> <new> <the case that must go red>
  cp "$S" "$SB/p.sh"
  python3 - "$SB/p.sh" "$2" "$3" <<'PY' || { bad "plant did not land: $1"; return; }
import sys
p, a, b = sys.argv[1:]
s = open(p).read()
if s.count(a) != 1: sys.exit(1)
open(p, "w").write(s.replace(a, b))
PY
  local r; r=$(all "$SB/p.sh")
  grep -qF -- "$4" <<<"$r" && ok "planted: $1 → red" || bad "planted: $1 → not red on its case ($4)"
}
echo "plants"
plant "kept shots never go stale"           'local pr="$1" from="$2" head="$3" changed own scr hit="" f dir spec base c' 'return 1' 'merge that edited this PR'"'"'s screen read'
plant "imports are not followed"             'c=$(printf '"'"'%s\n'"'"' "$changed" | awk -v b="$base"' 'c=$(true | awk -v b="$base"' 'changed an import of this PR'"'"'s screen read'
plant "a merge counts as a carry"            '[ "$parents" = 2 ] || return 1'            ':'                               'a verdict with a merge after it passed'
plant "a code file counts as a carry"        '| grep -vF "$EV_DIR/" >/dev/null'         '| grep NOTHING-MATCHES-THIS >/dev/null'  'a verdict with a code commit after it passed'
plant "the forge's carry ignores code files" 'select(startswith($d) | not)] | length == 0)' 'select(false)] | length == 0)' 'shots with code after them and a capture running read'
plant "evidence read from the whole body"    'urls=$(printf '"'"'%s\n'"'"' "$body" | block | links | ci_links' 'urls=$(printf '"'"'%s\n'"'"' "$body" | links | ci_links' 'fetch took a hand-pinned shot'
plant "shots read from the whole body"       'printf '"'"'%s\n'"'"' "$blk" | links | ci_links "$evsha" "$(ev_folders "$2" "$j")" ;;' 'jq -r .body <<<"$j" | links | ci_links "$evsha" "$(ev_folders "$2" "$j")" ;;' 'shots listed a link outside'
plant "a builder's file passes as CI's"      'if [ "$sha" = "$ev" ] && printf' 'if [ "$sha" = "$ev" ] || printf' 'took a file CI'"'"'s commit did not write'
plant "no capture run is asked for"          $'cap=$(check "$runs" "$EV_CAPTURE")\n  case "$cap" in\n    completed/success|' $'cap=completed/success\n  case "$cap" in\n    completed/success|' 'with no capture run behind it, read pinned'
plant "any commit counts as CI's"            'startswith($p) | not) then' 'startswith($p) | not) and false then' 'at a builder'"'"'s commit read pinned'
plant "only a finished capture owns its push" 'completed/success|completed/cancelled|in_progress/*|queued/*) ;;' 'completed/success) ;;' 'capture still running, read'
plant "a cancelled capture disowns its push" 'completed/success|completed/cancelled|in_progress/*|queued/*) ;;' 'completed/success|in_progress/*|queued/*) ;;' 'capture cancelled after the push, read'
plant "the folder is not checked"            'elif ($out | length) > 0 then' 'elif false then' 'in another ticket'"'"'s folder read pinned'
plant "CI's author is not checked"           'elif $em != "" and (.commit.author.email // "") != $em then' 'elif false then' 'someone other than CI'"'"'s author read pinned'
plant "the branch's ticket is not read"      'jq -r --arg pre "$BR_PREFIX" "$BRANCH_TICKET_JQ"' 'true || jq -r --arg pre "$BR_PREFIX" "$BRANCH_TICKET_JQ"' 'in the branch ticket'"'"'s folder, capture still running'
plant "closed tickets are not read"          'jq -r '"'"'.closingIssuesReferences[]?.number // empty'"'"' <<<"$2"' 'true || jq -r '"'"'.closingIssuesReferences[]?.number // empty'"'"' <<<"$2"' 'in a closed ticket'"'"'s folder'
plant "the PR's own number is not a folder"  '{ printf '"'"'%s\n'"'"' "$1"' '{ true' 'in the PR number'"'"'s folder read'
plant "the branch prefix is not configurable" 'BR_PREFIX=$(cfg branchPrefix "${BRANCH_PREFIX:-}")' 'BR_PREFIX=' 'in the branch ticket'"'"'s folder, capture still running'
plant "a draft is not told apart"            '[ "$draft" = true ] && {'                  '[ "$draft" = never ] && {'       'a draft read'
plant "a failed decide check is ignored"     '*/failure|*/timed_out|*/startup_failure|*/action_required)
      echo "state=failed"; echo "reason='"'"'$EV_DECIDE'"'"'' '*/NEVER)
      echo "state=failed"; echo "reason='"'"'$EV_DECIDE'"'"'' 'a failed decide check read'
plant "local capture on by default"          '"${HARNESS_LOCAL_EVIDENCE:-0}" = 1'        '"${HARNESS_LOCAL_EVIDENCE:-1}" = 1' 'local capture is on with no flag set'
plant "wait never gives up"                  '-ge "$max" ]'                              '-ge 999999 ]'                    'wait on nothing-yet exited'
plant "routes list not required"             '[ -n "$list" ] || {'                       'true || {'                       'a body with no routes list passed'
plant "the evidence dir is hardcoded"        'EV_DIR=$(cfg evidence.dir "docs/evidence")' 'EV_DIR=docs/evidence'           'the evidence dir from project config was ignored'
exit $fail
