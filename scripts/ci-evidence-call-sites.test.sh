#!/usr/bin/env bash
# The call sites of ci-evidence.sh, RUN out of the finish skill itself — not read.
#
#   Step 5.4  refuses a pixel PR with no '## Evidence routes' before readying it,
#             and puts the hold on BEFORE marking it ready
#   Gate 2    with no evidence in the body and local capture off, refuses and
#             names CI's state, and takes nothing locally
#   Gate 5    accepts a verdict under CI's evidence commit, refuses one under code
#
# Each block is cut from skills/finish/SKILL.md and executed. Then each guard is
# planted dead in a copy of the skill, and the case it guards must go red.
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/tests/lib/suite.sh" || exit 1
for v in $(env | sed -n 's/^\(GIT_[A-Za-z_]*\)=.*/\1/p'); do unset "$v"; done
KIT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SKILL="$KIT/skills/finish/SKILL.md"
SB=$(mktemp -d "${TMPDIR:-/tmp}/ci-ev-sites-XXXXXX"); on_exit_keep_status 'rm -rf "$SB"'
mkdir -p "$SB/bin" "$SB/fx"
cat > "$SB/bin/gh" <<'SH'
#!/usr/bin/env bash
echo "gh $*" >> "$CIE_LOG"
if [ "$1 $2" = "pr view" ]; then
  f="$CIE_FX/pr-$3.json"; [ -f "$f" ] || exit 1
  q=""; while [ $# -gt 0 ]; do [ "$1" = "-q" ] && q="$2"; shift; done
  if [ -n "$q" ]; then jq -r "$q" "$f"; else cat "$f"; fi; exit 0
fi
if [ "$1" = api ]; then
  case "$2" in repos/o/r) echo false; exit 0 ;; esac
  k=$(printf '%s' "$2" | tr '/?=&' '____'); [ -f "$CIE_FX/$k" ] && cat "$CIE_FX/$k" && exit 0; exit 1
fi
exit 0
SH
chmod +x "$SB/bin/gh"
export PATH="$SB/bin:$PATH" CIE_FX="$SB/fx" CIE_LOG="$SB/gh.log" CI_EVIDENCE_REPO=o/r CI_EVIDENCE_EVERY=0 CI_EVIDENCE_MAX=1
unset HARNESS_CFG HARNESS_LOCAL_EVIDENCE
fail=0
ok()  { echo "  ok   — $1"; }
bad() { echo "  FAIL — $1"; fail=1; }

A=$(printf 'a%.0s' {1..40})
blk="<!-- ci-evidence:begin -->
<!-- ci-evidence-head:$A -->
- [x](https://github.com/o/r/blob/$A/docs/evidence/7/dashboard.png)
<!-- ci-evidence:end -->"
mk() { jq -n --arg h "$2" --arg b "$3" '{headRefOid:$h, isDraft:false, body:$b}' > "$SB/fx/pr-$1.json"; }
mk 1 "$A" $'## Summary\nx\n\n## Evidence routes\n- /dashboard\n\n'"$blk"   # routes + pinned
mk 2 "$A" $'## Summary\nno routes\n'                                           # no routes
mk 3 "$A" $'## Evidence routes\n- /dashboard\n\n'                              # routes, nothing pinned yet

# --- cutting the blocks out of a skill file ----------------------------------
cut_step54() { # <skill> → the first bash block under Step 5.4, minus its env line
  awk '/^### Step 5\.4/{s=1} s && /^```bash/{b=1; next} b && /^```/{exit} b' "$1" | grep -v 'toolkit-env.sh'
}
cut_gate2() { # <skill> → the CI branch of Gate 2, wrapped so it runs alone
  printf 'if false; then :\n'
  awk '/^  elif .*ci-evidence\.sh" local/{s=1} s && /^  else$/{exit} s' "$1"
  printf 'fi\necho FELL-THROUGH\n'
}
cut_gate5() { # <skill> → Gate 5's head check
  awk '/# A verdict still covers the head when everything after it is CI/{s=1} s{print} s && /echo "✓ \$AT_HEAD"/{e=1; next} e && /^  fi$/{exit}' "$1"
}

run54() { # <skill> <pr> → exit code; log in $CIE_LOG
  : > "$CIE_LOG"
  (cd "$SB" && KIT_ROOT="$KIT" PR_NUMBER="$2" REPO_SLUG=o/r HOLD_LABEL=hold TICKET_KEY=7 \
     bash -c "toolkit_cfg() { echo squash; }; $(cut_step54 "$1")" >/dev/null 2>&1)
}

# A scratch repo: code, CI's evidence commit, an empty trailer; and a code commit.
R="$SB/repo"; git init -q "$R"
git -C "$R" config user.email t@t; git -C "$R" config user.name t
echo a > "$R/page.tsx"; git -C "$R" add .; git -C "$R" commit -qm code; V=$(git -C "$R" rev-parse HEAD)
mkdir -p "$R/docs/evidence/7"; echo p > "$R/docs/evidence/7/x.png"; git -C "$R" add .
git -C "$R" commit -qm "chore(evidence): screenshots"; E=$(git -C "$R" rev-parse HEAD)
echo b > "$R/page.tsx"; git -C "$R" commit -qam "fix: more"; X=$(git -C "$R" rev-parse HEAD)
run5() { # <skill> <verdict> <head> → exit code
  (cd "$R" && KIT_ROOT="$KIT" UI_GATE_SHA="$2" HEAD_SHA="$3" BRANCH=none \
     bash -c "$(cut_gate5 "$1")" >/dev/null 2>&1)
}
run2() { # <skill> <pr> → output (stderr and stdout)
  (cd "$SB" && KIT_ROOT="$KIT" PR_NUMBER="$2" bash -c "$(cut_gate2 "$1")" 2>&1)
}

cases() { # <skill> → failed cases, one per line
  local s=$1 o
  [ -n "$(cut_step54 "$s")" ] || echo "Step 5.4's block is missing"
  run54 "$s" 2 && echo "Step 5.4 went on with no routes list"
  grep -q 'pr ready' "$CIE_LOG" && echo "Step 5.4 readied a PR with no routes list"
  run54 "$s" 1 || echo "Step 5.4 refused a PR with routes and pinned shots"
  o=$(grep -nE 'pr edit 1 --add-label hold|pr ready 1' "$CIE_LOG" | cut -d: -f2 | tr '\n' ' ')
  case "$o" in "gh pr edit 1 --add-label hold gh pr ready 1 ") ;; *) echo "Step 5.4 did not hold before readying ($o)" ;; esac
  grep -q 'pr view 1 --json headRefOid' "$CIE_LOG" || echo "Step 5.4 never waited on CI"
  o=$(run2 "$s" 3)
  grep -q 'REFUSED: PR touches UI and CI has not pinned' <<<"$o" || echo "Gate 2 did not refuse a PR CI has not pinned ($o)"
  grep -q 'FELL-THROUGH' <<<"$o" && echo "Gate 2 fell through to local capture with the flag off"
  o=$(HARNESS_LOCAL_EVIDENCE=1 run2 "$s" 3)
  grep -q 'FELL-THROUGH' <<<"$o" || echo "Gate 2 did not reach the local fallback with the flag on"
  run5 "$s" "$V" "$E" || echo "Gate 5 refused a verdict under CI's evidence commit"
  run5 "$s" "$V" "$X" && echo "Gate 5 passed a verdict with code after it"
  run5 "$s" "$X" "$X" || echo "Gate 5 refused a verdict at the head"
  return 0
}

echo "ci-evidence call sites (finish)"
r=$(cases "$SKILL"); [ -z "$r" ] && ok "Step 5.4, Gate 2 and Gate 5 behave as written" || { bad "cases failed:"; printf '         %s\n' "$r"; }

plant() { # <desc> <old> <new> <the case that must go red>
  cp "$SKILL" "$SB/SKILL.md"
  python3 - "$SB/SKILL.md" "$2" "$3" <<'PY' || { bad "plant did not land: $1"; return; }
import sys
p, a, b = sys.argv[1:]
s = open(p).read()
if s.count(a) != 1: sys.exit(1)
open(p, "w").write(s.replace(a, b))
PY
  local r; r=$(cases "$SB/SKILL.md")
  grep -qF -- "$4" <<<"$r" && ok "planted: $1 → red" || bad "planted: $1 → not red on its case ($4)"
}
echo "plants"
plant "Step 5.4 skips the routes check" 'gh pr view "$PR_NUMBER" --json body -q .body | bash "$EV" routes || exit 1' 'true' 'went on with no routes list'
plant "Step 5.4 readies before holding" 'gh pr edit "$PR_NUMBER" --add-label "$HOLD_LABEL"
gh pr ready "$PR_NUMBER" 2>/dev/null || true' 'gh pr ready "$PR_NUMBER" 2>/dev/null || true
gh pr edit "$PR_NUMBER" --add-label "$HOLD_LABEL"' 'did not hold before readying'
plant "Step 5.4 never waits"            'bash "$EV" wait "$PR_NUMBER"; echo "wait exit: $?"' 'echo waited' 'never waited on CI'
plant "Gate 2 ignores the local flag"   '  elif ! bash "$KIT_ROOT/scripts/ci-evidence.sh" local; then' '  elif ! bash "$KIT_ROOT/scripts/ci-evidence.sh" local || true; then' 'did not reach the local fallback'
plant "Gate 2 refuses but carries on"   '    echo "   Do not capture locally. Re-run this step when wait exits 0." >&2
    exit 1' '    echo "   Do not capture locally. Re-run this step when wait exits 0." >&2' 'fell through to local capture with the flag off'
plant "Gate 5 strict equality again"    'if ! AT_HEAD=$(bash "$KIT_ROOT/scripts/ci-evidence.sh" at-head "$UI_GATE_SHA" "$HEAD_SHA"); then' 'if ! AT_HEAD=$(false); then' "refused a verdict under CI's evidence commit"
plant "Gate 5 waves everything through" 'if ! AT_HEAD=$(bash "$KIT_ROOT/scripts/ci-evidence.sh" at-head "$UI_GATE_SHA" "$HEAD_SHA"); then' 'if ! AT_HEAD=$(true); then' 'passed a verdict with code after it'
suite_end "$fail"
