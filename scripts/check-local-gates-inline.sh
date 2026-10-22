#!/usr/bin/env bash
# check-local-gates-inline.sh — no skill, agent or rule reads the local gates with its own jq.
# Usage: check-local-gates-inline.sh [file ...]   (default: the kit's markdown under skills/, agents/, shared/, rules/)
# The local set is decided once, in scripts/local-gates.sh (gates.local under
# gates.localOnly, else gates.changed). A run command that inlines `.gates.changed`
# skips that rule: the prose claim flow ran test:changed on a project whose driver
# already ran gates.local alone.
cd "$(dirname "$0")/.." || exit 2
if [ $# -gt 0 ]; then files=("$@"); else
  files=(); while IFS= read -r f; do files+=("$f"); done < <(git ls-files 'skills/*.md' 'agents/*.md' 'shared/*.md' 'rules/*.md')
  [ "${#files[@]}" -gt 0 ] || { echo "check-local-gates-inline: no markdown to scan — refusing to report clean"; exit 2; }
  # Control: the scan must see the helper before its silence about inlined reads means anything.
  seen=$(grep -l 'local-gates\.sh' "${files[@]}" 2>/dev/null | wc -l | tr -d ' ')
  echo "control, call sites of local-gates.sh : $seen files"
  [ "$seen" -gt 0 ] || { echo "check-local-gates-inline: no file calls local-gates.sh — refusing to report clean"; exit 2; }
fi
# A jq path into the changed list: `.gates.changed`, or `.gates | .changed` / `.gates["changed"]`.
hits=$(grep -nE '\.gates[[:space:]]*(\.|\|[[:space:]]*\.|\[")changed' "${files[@]}" /dev/null 2>/dev/null)
if [ -n "$hits" ]; then
  printf '%s\n' "$hits" | sed 's/^/  /; s/$/   ← call scripts\/local-gates.sh instead/'
  echo "check-local-gates-inline: the lines above read gates.changed themselves and skip gates.localOnly"
  exit 1
fi
echo "check-local-gates-inline: ${#files[@]} files read the local gates through local-gates.sh"
