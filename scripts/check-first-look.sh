#!/usr/bin/env bash
# Refuses a design-critic answer that skipped the first-look test, or passed a screen it could not read.
# Usage: check-first-look.sh <critic-output-file>   (or - for stdin)
# Exit 0: all three lines answered, or the verdict is SLOP. Exit 1: names what is missing.
set -uo pipefail
src="${1:--}"
if [ "$src" = "-" ]; then text="$(cat)"; else
  [ -f "$src" ] || { echo "check-first-look: no such file: $src" >&2; exit 2; }
  text="$(cat "$src")"
fi

verdict="$(printf '%s\n' "$text" | sed -n 's/^[*[:space:]]*VERDICT:[*[:space:]]*\([A-Z-]*\).*/\1/p' | head -1)"
missing=() blind=()
for label in For Happening Next; do
  line="$(printf '%s\n' "$text" | grep -E "^[[:space:]]*${label}:" | head -1)"
  answer="$(printf '%s' "$line" | sed -E "s/^[[:space:]]*${label}:[[:space:]]*//; s/[[:space:]]+$//")"
  if [ -z "$line" ] || [ -z "$answer" ] || [ "$answer" = "…" ]; then missing+=("$label")
  elif printf '%s' "$answer" | grep -qi 'CANNOT TELL'; then blind+=("$label"); fi
done

if [ "${#missing[@]}" -gt 0 ]; then
  echo "check-first-look: the critic did not run the first look — missing: ${missing[*]}" >&2
  exit 1
fi
if [ "${#blind[@]}" -gt 0 ] && [ "$verdict" != "SLOP" ]; then
  echo "check-first-look: the critic could not tell ${blind[*]} from the screen, yet said ${verdict:-no verdict}" >&2
  exit 1
fi
echo "check-first-look: ok (${verdict:-no verdict})"
