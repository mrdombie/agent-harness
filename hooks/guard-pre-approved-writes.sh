#!/usr/bin/env bash
# PreToolUse (Bash, Write|Edit): refuse an agent's change to `preApprovedWrites`
# in a .claude/harness.json. The key pre-approves writes; the session-start
# injector reads it from the repo, so an agent that edits it approves itself.
# Only the operator adds or widens it. Removing it is allowed (it grants nothing).
#
# The judge compares the key's parsed value before and after. It is the second
# half of the fix: hooks/standing-rules.sh honours the key only when the working
# tree matches the committed value, so a write this guard cannot see is inert
# until committed, and `git commit` is judged here.
#
# Self-test: hooks/guard-pre-approved-writes.test.sh
payload=$(cat)
# Cheap skip for Bash only: nothing that can reach the file, by name, glob, git or
# a script. Write and Edit always go through: a hard link reaches it under any name.
grep -qiE '"tool_name" *: *"(Write|Edit|MultiEdit)"|harness|\.claude|git|cp|mv|ln|install|rsync|patch|tee|[*?]|\.(sh|py|js|mjs|cjs|ts|rb|pl)|python|node|perl|ruby|bash|sh |eval|source|gh ' <<<"$payload" || exit 0
. "$(dirname "$0")/lib/python.sh"
harness_python || harness_python_refuse guard-pre-approved-writes
printf '%s' "$payload" | "${HARNESS_PY[@]}" "$(dirname "$0")/guard-pre-approved-writes.py"
