#!/usr/bin/env bash
# release-push-key.test.sh — the version bump pushes with the deploy key that main's check rule lets through.
set -u; cd "$(dirname "$0")/.." || exit 1
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/tests/lib/suite.sh" || exit 1
fail=0; f=.github/workflows/release.yml
ok(){ if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi; }
co=$(awk '/uses: actions\/checkout@/{c=1} c&&/^ *- name:/{exit} c' "$f")
ok "checkout carries the release deploy key" '[[ "$co" =~ ssh-key:\ \"?\$\{\{\ secrets\.RELEASE_DEPLOY_KEY\ \}\} ]]'
ok "the bump still pushes to main"           'grep -q "git push origin HEAD:main" "$f"'
suite_end "$fail"
