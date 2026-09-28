---
name: block-npm-install-in-worktree
enabled: true
event: bash
action: block
conditions:
  - field: command
    operator: regex_match
    pattern: (^|[;&|\n]\s*)(sudo\s+)?npm\s+(install|i|ci)(\s|$)(?!.*--dry-run)
  - field: command
    operator: not_contains
    pattern: "# main-clone install"
---

**Blocked: `npm install` / `npm ci` inside a worktree.**

Worktrees share `node_modules` by symlink to the main repo. Installing here
rewrites the shared tree and breaks every other agent mid-build.

If you hit `TS2307 Cannot find module`, the symlink is dead — relink it.
Never reinstall.

## The one legitimate install, and how to say so

Refreshing the **main clone** is the prescribed fix when the shared tree falls
behind the lockfile — `check:node-modules-fresh` says so in its own failure
message. This rule used to block that too, which left the only correct install
needing a human every time develop took a dependency bump (#10029).

Say it deliberately, the way `no-handrolled-pr` lets `/finish` through:

```
cd <main-clone> && npm install   # main-clone install
```

Check `ls -ld <dir>/node_modules` first. A **real directory** is safe to install
into. A **symlink** is not — that is the shared tree, and this rule is about you.

## Why the pattern is no longer anchored at the start

It was `^\s*npm\s+…`, so `npm install` was blocked and `cd /some/worktree &&
npm install` walked straight through. Same operation, opposite outcomes,
decided by whether the line happened to start with `cd` — and the safe
main-clone install was the one written plainly, so the rule blocked the good
form and permitted the dangerous one. The boundary class now covers `;`, `&&`,
`||`, a pipe and a newline.

## `--dry-run` is exempt, but it is NOT read-only

The exemption exists for the lockfile check. Note what it costs: on 2026-09-03
an `npm install --dry-run` at the main clone is the prime suspect for
`node_modules/.package-lock.json` being rewritten to versions nothing had
installed — npm's reify step can write that file while moving no packages. Not
confirmed (the file's mtime did not line up), so treat it as a caution rather
than a fact.

It mattered because `check:node-modules-fresh` trusted that manifest and went
blind. It now reads the real `node_modules/<pkg>/package.json` as well
(#10029), so a rewritten manifest is caught rather than believed.
