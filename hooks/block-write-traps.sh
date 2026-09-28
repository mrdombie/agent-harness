#!/usr/bin/env bash
# PreToolUse (Write|Edit): four write-time traps.
#
# 1. PHANTOM WORKTREE PATH — a retyped temp worktree path whose directory does
#    not exist. Write would silently create a phantom tree (3 incidents). Deny
#    unless the worktree root exists.
# 2. MAIN-CLONE EDIT — the shared object store is a clone nobody works in, and
#    its checkout runs behind. An Edit there lands on no branch. Deny edits to
#    its source trees; the .claude/ tooling tree is left alone.
# 3. CREDENTIAL IN MEMORY — never store a pasted key/token/secret in a memory
#    file. Deny when the written content matches a secret shape.
# 4. NEW TOOLING OUTSIDE THE KIT — a brand-new command or skill written into a
#    machine's own ~/.claude lives on that machine and nowhere else. It is the
#    duplication this kit exists to remove: two live copies of one thing,
#    silently disagreeing. Editing an EXISTING file stays allowed (the backlog
#    still has to be moved); creating one does not.
#
# Where the shared clone lives is DERIVED from the checkout, never written
# down: it is a per-machine fact and differs between two computers on the same
# project. Absent it, trap 2 stands down and the
# other three keep firing; a guard that goes inert where it cannot read a config
# is not a guard.
#
# Self-test: hooks/block-write-traps.test.sh
set -euo pipefail
payload=$(cat)
f=$(printf '%s' "$payload" | jq -r '.tool_input.file_path // ""' 2>/dev/null || echo "")
[ -z "$f" ] && exit 0
deny(){ jq -nc --arg r "$1" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'; exit 0; }

# 1. phantom worktree path
case "$f" in
  */var/folders/*/T/*|/tmp/*|/private/tmp/*)
    # The root is the FIRST component under the temp base. The old form
    # anchored on '/T/' only, so every /tmp worktree path was matched by the
    # case above and then missed by the regex — the guard was half dead.
    root=$(printf '%s' "$f" | sed -nE 's#^((/private)?/tmp/[a-z]+-?[0-9]+[^/]*)/.*$#\1#p')
    [ -n "$root" ] || root=$(printf '%s' "$f" | sed -nE 's#^(.*/T/[a-z]+-?[0-9]+[^/]*)/.*$#\1#p')
    if [ -n "$root" ] && [ ! -d "$root" ]; then
      deny "Worktree directory does not exist: $root — the path was retyped, not read from the recorded path file. Command-substitute it from the claim's recorded worktree path, never type the hash."
    fi ;;
esac

# 2. main-clone edit. MAIN_REPO is whatever the kit resolved, else the config's
#    own checkout. Only the source trees: .claude/ holds the tooling and is the
#    one thing legitimately edited there.
#    DERIVED, NOT CONFIGURED. The header used to claim this came from
#    harness.json while `_cfg` was assigned and never used — one line, its own
#    assignment — so in practice the trap depended entirely on the cache file,
#    which toolkit-env.sh writes only after some skill has run. Dead on exactly
#    the fresh machine this exists for.
#
#    A clone's location is a per-machine fact and must not be written down: it
#    differs between two computers working the same project, and the repo's own
#    check:no-machine-paths refuses it in a config for that reason. So derive it
#    the same way the resolver does — the clone that owns the .git a worktree
#    points at — and fall back to the resolver's last-seen value only for a
#    session started outside any checkout.
_main="${HARNESS_MAIN_REPO:-}"
_here="${CLAUDE_PROJECT_DIR:-$PWD}"
_top=$(git -C "$_here" rev-parse --show-toplevel 2>/dev/null || true)
if [ -z "$_main" ]; then
  _common=$(git -C "$_here" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)
  case "$_common" in */.git) _main="${_common%/.git}" ;; esac
fi
[ -n "$_main" ] || _main=$(cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/.harness-last-main-repo" 2>/dev/null || true)

#    ONLY WHEN YOU ARE SOMEWHERE ELSE. `--git-common-dir` returns the repo's own
#    .git when you are standing in a PLAIN checkout, so the derivation names the
#    repo you are working in — and the first version of this denied every source
#    edit in any checkout that was not itself a worktree, telling the author to
#    go and use a worktree that may not exist. The test only ever ran from
#    inside a worktree, which is why it was green.
#
#    The trap is about editing SOMEONE ELSE'S tree: your own toplevel being the
#    clone means you are simply working in it, and that is not what this is for.
[ -n "$_top" ] && [ "$_top" = "$_main" ] && _main=""

#    ABSOLUTE ONLY. A relative or empty $_main left the pattern below as a bare
#    `/*`, which matches every absolute path — so one relative value in the env
#    or in the cache file denied every Write and Edit on the machine.
case "$_main" in /*) ;; *) _main="" ;; esac

# macOS resolves /var to /private/var, so a derived clone path and the path the
# tool was handed can name the SAME directory and not match as strings. Compare
# against both spellings; without this the trap was silently one-sided. Only
# ever computed from an absolute $_main, so it can never widen to `/`.
_alt=""
case "$_main" in
  /private/*) _alt="${_main#/private}" ;;
  /?*)        _alt="/private$_main" ;;
esac
[ -n "$_alt" ] || _alt="$_main"
if [ -n "$_main" ]; then
  case "$f" in
    "$_main"/.claude/*|"$_alt"/.claude/*) ;;
    "$_main"/*|"$_alt"/*)
      deny "This is the shared main clone (nobody's branch, checkout runs behind), not your worktree. An edit here lands on no branch and can land on a peer's. Edit the same path inside your claim worktree." ;;
  esac
fi

# 4. new tooling outside the kit
case "$f" in
  "$HOME"/.claude/commands/*.md|"$HOME"/.claude/skills/*/SKILL.md)
    _inrepo=0
    [ -n "${_main:-}" ] && case "$f" in "$_main"/*) _inrepo=1 ;; esac
    if [ "$_inrepo" -eq 0 ] && [ ! -e "$f" ]; then
      deny "New commands and skills are not born in ~/.claude — a copy there lives on one machine and nowhere else. Add it to the harness repo (skills/<name>/SKILL.md, reading project facts from .claude/harness.json), open a PR, merge, then update the plugin. If it is one project's own, put it in that repo's .claude/skills through a ticket."
    fi ;;
esac

# 3. credential written into memory
case "$f" in
  */memory/*.md)
    content=$(printf '%s' "$payload" | jq -r '.tool_input.content // .tool_input.new_string // ""' 2>/dev/null || echo "")
    if printf '%s' "$content" | grep -qE 'sk-ant-[A-Za-z0-9_-]{20,}|ghp_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{30,}|xox[abp]-[A-Za-z0-9-]{20,}|AKIA[0-9A-Z]{16}|-----BEGIN [A-Z ]*PRIVATE KEY|Bearer [A-Za-z0-9._-]{30,}|sk-[A-Za-z0-9]{32,}'; then
      deny "That looks like a credential. Never store a key, token or secret in memory: treat it as compromised and point to the project's secret store instead."
    fi ;;
esac
exit 0
