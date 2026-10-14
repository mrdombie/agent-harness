#!/usr/bin/env bash
# Self-test for pr-body-matches-branch.sh.
#
# A scratch repo on branch t-200/work and a stub `gh` that knows two PRs:
# #101 is on t-100/first, #202 is on t-200/work. The first case is the death this
# guard exists for: ticket 100's body pushed to ticket 200's PR.
D="$(cd "$(dirname "$0")" && pwd)"; H="$D/pr-body-matches-branch.sh"
fail=0
for v in $(env | sed -n 's/^\(GIT_[A-Z_]*\)=.*/\1/p'); do unset "$v"; done
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
git -C "$T" init -q -b t-200/work repo
git -C "$T/repo" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
mkdir "$T/bin"
cat > "$T/bin/gh" <<'GH'
#!/usr/bin/env bash
case "$*" in
  *"pr view 101"*) echo t-100/first ;;
  *"pr view 202"*) echo t-200/work ;;
  *"pr view https://github.com/o/r/pull/202"*) echo t-200/work ;;
  *) exit 1 ;;
esac
GH
chmod +x "$T/bin/gh"
export PATH="$T/bin:$PATH"
R="$T/repo"
printf 'Closes #100\n' > "$R/body-100.md"        # ticket 100's real body
printf 'Closes #200\n' > "$R/body-200.md"        # ticket 200's real body
printf 'Closes #100\n' > "$R/stale-200.md"       # named for 200, carrying 100's body
printf 'Closes #200\n' > "$R/pr.md"              # the right body at a shared path
printf 'Closes ticket #200.\n' > "$R/ticket-200.md"
mkdir -p "$T/claude-200/scratch"; printf 'Closes #100\n' > "$T/claude-200/scratch/pr.md"   # shared path whose DIR holds 200
GD=$(git -C "$R" rev-parse --absolute-git-dir); printf 'Closes #100\n' > "$GD/pr-body-200.md"   # stale, in the right place

run(){ jq -nc --arg c "$1" --arg d "$R" '{tool_input:{command:$c},cwd:$d}' | bash "$H" 2>/dev/null; }
check(){ want=$1 name=$2 cmd=$3
  out=$(run "$cmd"); got=allow
  printf '%s' "$out" | grep -q '"permissionDecision":"deny"' && got=deny
  if [ "$got" = "$want" ]; then printf 'ok   %-5s %s\n' "$want" "$name"
  else printf 'FAIL %-5s got %s: %s\n' "$want" "$got" "$name"; fail=1; fi; }

# The death: a body for issue A pushed to PR B.
check deny  "A's body pushed to B's PR (edit)"          "gh pr edit 202 --body-file $R/body-100.md"
check deny  "A's body in a file named for B (edit)"     "gh pr edit 202 --body-file $R/stale-200.md"
check deny  "A's body opening B's PR (create --head)"   "gh pr create --head t-200/work --body-file $R/stale-200.md"
check deny  "A's body inline on B's branch"             "cd $R && gh pr create --title x --body 'Closes #100'"
check deny  "A's body written then sent in one command" "cat > $R/body-200.md <<'EOF'
Closes #100
EOF
gh pr create --head t-200/work --body-file $R/body-200.md"
check deny  "a shared scratch path, even with the right body" "gh pr edit 202 --body-file $R/pr.md"
check deny  "a shared path via a variable"              "S=$R; gh pr create --head t-200/work --body-file \$S/pr.md"
check deny  "a backslash-continued send of a stale shared file" "gh pr create --base main \\
  --head t-200/work \\
  --body-file $R/pr.md"
check deny  "--body \"\$(cat stale)\" from a shared file"     "gh pr create --head t-200/work --body \"\$(cat $R/body-100.md)\""
check deny  "--body \"\$(< stale)\" named for B, holding A"   "gh pr create --head t-200/work --body \"\$(< $R/stale-200.md)\""
check deny  "a shared path whose directory holds the number" "gh pr create --head t-200/work --body-file $T/claude-200/scratch/pr.md"
check deny  "re-sending the git-dir body without rewriting it" "cd $R && gh pr edit 202 --body-file \"\$(git rev-parse --absolute-git-dir)/pr-body-200.md\""
check deny  "-R before the PR number still reads that PR"  "gh pr edit -R o/r 202 --body 'Closes #100'"
check deny  "a PR URL as the target"                    "gh pr edit https://github.com/o/r/pull/202 --body 'Closes #100'"
check deny  "a semicolon inside the title"              "gh pr create --head t-200/work --title 'fix: a; b' --body 'Closes #100'"
check deny  "the finish inline heredoc form, wrong ticket" "cd $R && gh pr create --base main --title x \`# via /finish\` --body \"\$(cat <<'EOF'
## Summary
Closes ticket #100.
EOF
)\""
check deny  "a second ticket closed beside the right one" "gh pr create --head t-200/work --body 'Closes #200, closes #201'"
check deny  "a PR whose branch cannot be read"          "gh pr edit 999 --body-file $R/body-200.md"
# The same commands with the right body pass.
check allow "B's body to B's PR (edit)"                 "gh pr edit 202 --body-file $R/body-200.md"
check allow "A's body to A's PR (edit)"                 "gh pr edit 101 --body-file $R/body-100.md"
check allow "B's body inline, Closes ticket form"       "cd $R && gh pr create --title x --body 'Closes ticket #200.'"
check allow "B's body file, Closes ticket form"         "gh pr create --head t-200/work --body-file $R/ticket-200.md"
check allow "the file this command writes is read, not the stale one on disk" "cat > $R/stale-200.md <<'EOF'
Closes #200
EOF
gh pr create --head t-200/work --body-file $R/stale-200.md"
check allow "finish's body-file form: set, written and sent in one command" "cd $R && TICKET_KEY=200; BODY_FILE=\"\$(git rev-parse --absolute-git-dir)/pr-body-\$TICKET_KEY.md\"; cat > \"\$BODY_FILE\" <<'EOF'
Closes #200
EOF
gh pr create --head t-200/work --body-file \"\$BODY_FILE\""
check allow "the same form when the ticket variable is not in this command" "cd $R && BODY_FILE=\"\$(git rev-parse --absolute-git-dir)/pr-body-\$TICKET_KEY.md\"; cat > \"\$BODY_FILE\" <<'EOF'
Closes #200
EOF
gh pr create --head t-200/work --body-file \"\$BODY_FILE\""
check allow "the finish inline heredoc form"            "cd $R && gh pr create --base main --title x \`# via /finish\` --body \"\$(cat <<'EOF'
## Summary
Closes ticket #200.
EOF
)\""
check allow "the evidence gate's re-read of the PR's own body" "gh pr edit \"\$PR_NUMBER\" --repo o/r --body \"\$(gh pr view \"\$PR_NUMBER\" --repo o/r --json body -q .body)\""
check allow "a commit message closing another ticket, before the send" "cd $R && git commit -m 'refactor; fixes #100 follow-up' && gh pr create --head t-200/work --body 'Closes #200'"
check allow "-R before the PR number, right body"       "gh pr edit -R o/r 202 --body 'Closes #200'"
check allow "a branch whose first segment is not a ticket" "gh pr create --head v2/thing --body 'Closes #100'"
check allow "no body set"                               "gh pr edit 202 --add-label needs:review"
check allow "a branch that names no ticket"             "gh pr create --head hooks/tidy --body 'Closes #100'"
check allow "another repo's ticket"                     "gh pr create --head t-200/work --body 'Closes other/repo#100 and closes #200'"
check allow "gh pr create quoted inside a heredoc"      "cat <<'EOF'
gh pr create --head t-200/work --body 'Closes #100'
EOF"

# The guard is only a guard if it is wired: deleting its registration must fail here.
if jq -e '.hooks.PreToolUse[] | select(.matcher=="Bash") | .hooks[] | select(.command | test("pr-body-matches-branch\\.sh"))' \
     "$D/hooks.json" >/dev/null; then echo "ok   registered as a PreToolUse Bash hook"
else echo "FAIL hooks.json does not register pr-body-matches-branch.sh"; fail=1; fi

[ "$fail" -eq 0 ] && echo "pr-body-matches-branch: all cases pass"
exit $fail
