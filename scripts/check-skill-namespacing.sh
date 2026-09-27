#!/usr/bin/env bash
# Every reference to a skill THIS KIT SHIPS must name the kit: /<plugin>:<skill>.
#
# WHY: a bare /claim resolves to whichever copy the machine happens to carry.
# Measured on the origin project, 2026-09-27: three copies were reachable — a user
# command at 1,268 lines, the project's own skill at 1,118, and the kit's — and
# the one that actually loaded was the user command, in 100% of 549 runs, while
# the project's own loaded zero times. They disagreed by 474 lines. Nothing in the
# system said which had run.
#
# Namespacing is what makes the other copies unreachable: Claude Code resolves
# /<plugin>:<skill> to the plugin and nothing else, so a spawned run cannot be
# handed a different implementation by the machine it happens to be on. A bare
# name inside the kit's own instructions hands that choice back.
#
# A bare name is legitimate when the skill is NOT one of ours — /design and
# /critic belong to the consuming project. Those are the ones this gate ignores,
# by construction: it only knows the names in skills/.
#
# SCOPE is the instruction surface an AGENT reads and acts on: skills/, shared/
# and agents/. A `/claim` in a shell comment is documentation a person reads, and
# `# via /finish` is a literal marker string the guard hooks match on — renaming
# that would break the hook it belongs to. Both are exempt by construction rather
# than by suppression, so the gate cannot be satisfied by editing a comment.
#
# Escape: append `harness:bare-ok: <reason>` to the line. The reason is required.
set -u
cd "$(dirname "$0")/.." || exit 1

PLUGIN=$(jq -r '.name' .claude-plugin/plugin.json 2>/dev/null)
[ -n "$PLUGIN" ] && [ "$PLUGIN" != null ] || { echo "no plugin name in .claude-plugin/plugin.json"; exit 2; }

# Longest first, so /claim-status is read as claim-status and not as claim.
NAMES=$(for d in skills/*/; do basename "$d"; done | awk '{ print length, $0 }' | sort -rn | cut -d' ' -f2-)
[ -n "$NAMES" ] || { echo "no skills/ directories — refusing to report clean"; exit 2; }
ALT=$(printf '%s' "$NAMES" | tr '\n' '|' | sed 's/|$//')

FILES=$(git ls-files 'skills/*' 'shared/*' 'agents/*')
[ -n "$FILES" ] || { echo "no instruction files to scan — refusing to report clean"; exit 2; }

# Control: the probe must be able to see a namespaced reference before its silence
# about bare ones means anything. A zero from a strictness probe is clean,
# suppressed, or never ran.
control=$(printf '%s\n' "$FILES" | xargs grep -c "/$PLUGIN:" 2>/dev/null | awk -F: '{s+=$2} END{print s+0}')
printf 'control, probe can see references : %s namespaced\n' "$control"
[ "$control" -gt 0 ] || { echo "probe found no namespaced references at all — refusing to report clean"; exit 2; }

hits=$(printf '%s\n' "$FILES" | ALT="$ALT" PLUGIN="$PLUGIN" xargs perl -ne '
  BEGIN { $alt = $ENV{ALT}; }
  next if /harness:bare-ok:/;
  # `# via /finish` is a marker the guard hooks grep for, not an invocation.
  my $line = $_; $line =~ s/# via \/(?:$alt)\b//g;
  # A leading path segment ("skills/claim/") is not a skill reference, and a
  # trailing /, - or . keeps /claim from matching inside /claim-status or
  # /queue.sh.
  while ($line =~ /(?<![A-Za-z0-9_.\-])\/($alt)\b(?![\/\-.])/g) {
    print "$ARGV:$.: /$1\n";
  }
  close ARGV if eof;   # $. counts per file, not across the whole batch
' 2>/dev/null)

n=$(printf '%s' "$hits" | grep -c . )
printf 'bare references to our own skills : %s (want 0)\n' "$n"
[ "$n" -eq 0 ] && exit 0

printf '%s\n' "$hits" | sed 's/^/  /'
cat <<MSG

Each line above names one of this kit's own skills without the kit. Write
/$PLUGIN:<skill> instead, or append 'harness:bare-ok: <reason>' to the line when
the reference genuinely means the consuming project's copy.
MSG
exit 1
