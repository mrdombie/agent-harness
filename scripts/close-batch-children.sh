#!/usr/bin/env bash
# close-batch-children.sh <ticket> <pr> — after a batch ticket's PR merges, close
# every child its body lists, each with a comment naming the PR.
#
# A batch ticket builds several small tickets on one screen as ONE PR (Dom,
# 2026-10-16). Its body lists them ("**Children (6):** #11182, #11183, …" or
# "Rolled in: #11182, …"); the PR closes the batch ticket only, so without this the
# children stay open, labelled status:batched, for no agent ever to start.
#
# Prints one line per child: "closed #n", "already closed #n" or "FAILED #n".
# A ticket that lists no children closes nothing. Exits 1 when a close failed.
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SELF_DIR/toolkit-env.sh" || exit 1
T="${1:?usage: close-batch-children.sh <ticket> <pr>}"; PR="${2:?usage: close-batch-children.sh <ticket> <pr>}"
T="${T#\#}"; PR="${PR#\#}"

# The same lines the pr-body-matches-branch hook reads a batch's children from.
batch_children() { # <body on stdin> — one number per line, in the order listed
  grep -iE '^[[:space:]>*_-]*(children([[:space:]]*\([0-9]+\))?|rolled in)[[:space:]]*:?' \
    | grep -oE '#[0-9]+' | tr -d '#' | awk -v t="$T" '$0 != t && !seen[$0]++'
}

body=$(gh issue view "$T" --repo "$REPO_SLUG" --json body -q .body 2>/dev/null) \
  || { echo "close-batch-children: could not read #$T — no child closed" >&2; exit 1; }
kids=$(printf '%s\n' "$body" | batch_children)
[ -n "$kids" ] || exit 0

fail=0
for n in $kids; do
  st=$(gh issue view "$n" --repo "$REPO_SLUG" --json state -q .state 2>/dev/null)
  if [ "$st" = CLOSED ]; then echo "already closed #$n"; continue; fi
  if gh issue close "$n" --repo "$REPO_SLUG" --reason completed \
       --comment "Shipped in PR #$PR (batch #$T)." >/dev/null 2>&1; then
    echo "closed #$n"
  else
    echo "FAILED #$n"; fail=1
  fi
done
exit $fail
