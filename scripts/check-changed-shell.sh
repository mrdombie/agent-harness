#!/usr/bin/env bash
# check-changed-shell.sh — the cheap static checks for the shell scripts a change
# touches, fast enough for a project's gates.local:
#
#   1. shellcheck at error severity (the project's .shellcheckrc applies: shellcheck
#      finds it from each file's own directory). Not installed is a log line and a
#      skip, never a failure.
#   2. every network or long-running command the change ADDS (curl, wget, gh api,
#      git fetch, npm, npx, docker) carries a timeout or runs inside a bounded
#      wrapper (`timeout`, `--max-time`, a function whose name says bounded or
#      timeout). A deliberate exception says `# unbounded-ok: <why>` on the line.
#
#   check-changed-shell.sh [--base <ref>]     the files changed since <ref>'s merge-base
#   check-changed-shell.sh --files <file>…     these files, every line counted as added
#
# A changed script is a changed .sh file or a changed file whose first line is a
# bash/sh shebang. Unchanged files are never read. The base, unless given, is
# $CHECK_SHELL_BASE, then origin/<integrationBranch> from .claude/harness.json, then
# origin/HEAD, origin/main, origin/master. No base found is a refusal (exit 2): a
# check that cannot see the change reports like one that found nothing.
#
# Prints <file>:<line>: <rule>: <why> for each refusal and exits 1 when it printed any.
#   CHECK_SHELL_SEVERITY   shellcheck's -S (default error)
#   CHECK_SHELL_SHELLCHECK the shellcheck command (default shellcheck)
set -uo pipefail

say() { echo "check-changed-shell: $*" >&2; }
TOP=$(git rev-parse --show-toplevel 2>/dev/null) || { say "not inside a git checkout"; exit 2; }
cd "$TOP" || exit 2

base="${CHECK_SHELL_BASE:-}" files_mode=0
files=()
while [ $# -gt 0 ]; do
  case "$1" in
    --base) base="${2:?--base needs a ref}"; shift 2 ;;
    --files) files_mode=1; shift; while [ $# -gt 0 ]; do files+=("$1"); shift; done ;;
    *) say "unknown argument: $1"; exit 2 ;;
  esac
done

is_shell() { # <file>
  case "$1" in *.sh|*.bash) return 0 ;; esac
  local first; first=$(head -n1 "$1" 2>/dev/null)
  grep -Eq '^#![[:space:]]*(/usr/bin/env[[:space:]]+)?(/usr/local/bin/|/usr/bin/|/bin/)?(bash|sh|dash|ksh)([[:space:]]|$)' <<<"$first"
}

ranges=$(mktemp "${TMPDIR:-/tmp}/check-changed-shell.XXXXXX") || exit 2
trap 'rm -f "$ranges"' EXIT

if [ "$files_mode" = 1 ]; then
  for f in ${files[@]+"${files[@]}"}; do [ -f "$f" ] && printf '%s\t*\n' "$f" >> "$ranges"; done
else
  if [ -z "$base" ]; then
    ib=$(jq -r '.integrationBranch // empty' .claude/harness.json 2>/dev/null)
    for b in ${ib:+"origin/$ib"} "$(git symbolic-ref -q --short refs/remotes/origin/HEAD 2>/dev/null)" origin/main origin/master; do
      [ -n "$b" ] && git rev-parse -q --verify "$b^{commit}" >/dev/null 2>&1 && { base="$b"; break; }
    done
  fi
  [ -n "$base" ] || { say "no base to diff against (pass --base or set CHECK_SHELL_BASE) — refusing rather than checking nothing"; exit 2; }
  mb=$(git merge-base HEAD "$base" 2>/dev/null) || { say "no merge-base between HEAD and $base (a shallow clone?) — refusing rather than checking nothing"; exit 2; }
  while IFS= read -r f; do
    if [ ! -f "$f" ] || ! is_shell "$f"; then continue; fi
    # The added lines, as start,count pairs from the zero-context hunks.
    r=$(git diff -U0 --no-color "$mb" -- "$f" | sed -n 's/^@@ -[0-9,]* +\([0-9]*\)\(,\([0-9]*\)\)\{0,1\} @@.*/\1,\3/p' | tr '\n' ' ')
    printf '%s\t%s\n' "$f" "$r" >> "$ranges"
  done < <(git diff --name-only --diff-filter=ACMR "$mb" -- 2>/dev/null)
  while IFS= read -r f; do
    [ -f "$f" ] && is_shell "$f" && printf '%s\t*\n' "$f" >> "$ranges"
  done < <(git ls-files --others --exclude-standard 2>/dev/null)
fi

# --files takes any file it is handed; the shell test is for what a diff turns up.
[ -s "$ranges" ] || { say "no changed shell scripts"; exit 0; }
n=$(grep -c . "$ranges")
say "checking $n changed shell script(s)${base:+ against $base}"
bad=0

# 1. shellcheck, whole file: an error anywhere in a changed script is the change's to fix.
sc="${CHECK_SHELL_SHELLCHECK:-shellcheck}"
if command -v "$sc" >/dev/null 2>&1; then
  scfiles=(); while IFS=$'\t' read -r f _; do scfiles+=("$f"); done < "$ranges"
  out=$("$sc" -S "${CHECK_SHELL_SEVERITY:-error}" -f gcc -- "${scfiles[@]}" 2>&1); src=$?
  case "$src" in
    0) ;;
    1) printf '%s\n' "$out" | sed -n 's/^\([^:]*\):\([0-9]*\):[0-9]*: \([a-z]*\): \(.*\) \[\(SC[0-9]*\)\]$/\1:\2: \5 (\3): \4/p'; bad=1 ;;
    *) say "shellcheck could not run (exit $src):"; printf '%s\n' "$out" >&2; bad=1 ;;
  esac
else
  say "shellcheck is not installed — its half of this check is skipped (brew install shellcheck / apt-get install shellcheck)"
fi

# 2. Unbounded network and long-running commands, on the lines the change adds only.
# A test suite's fetch is from a fixture on disk and CI bounds the run, so suites are
# held to shellcheck alone.
while IFS=$'\t' read -r f r; do
  case "$f" in *.test.sh|*_test.sh|tests/*|*/tests/*|test/*|*/test/*) continue ;; esac
  CCS_RANGES="$r" perl -ne '
    BEGIN {
      %want = (); $all = ($ENV{CCS_RANGES} eq "*");
      for my $p (split " ", $ENV{CCS_RANGES}) {
        my ($s, $c) = split /,/, $p, -1; $c = 1 if !defined $c || $c eq "";
        $want{$_} = 1 for $s .. $s + $c - 1;
      }
      $bad = 0; $doc = ""; @st = ();
    }
    chomp; my $l = $_;
    # A heredoc body is data, not a command line.
    if ($doc ne "") { $doc = "" if $l =~ /^\t*\Q$doc\E\s*$/; next }
    # The line as code: quoted text becomes Q, a $( ) inside double quotes stays code,
    # and a quote left open carries to the next line (a multi-line awk or jq program).
    my $s = "";
    for (my $i = 0; $i < length $l; $i++) {
      my $ch = substr($l, $i, 1); my $top = @st ? $st[-1] : "";
      if ($top eq "\x27") { if ($ch eq "\x27") { pop @st; $s .= "Q" } next }
      if ($top eq "\"") {
        if ($ch eq "\\") { $i++; next }
        if ($ch eq "\"") { pop @st; $s .= "Q"; next }
        if ($ch eq "\$" && substr($l, $i + 1, 1) eq "(") { push @st, "("; $s .= " \$("; $i++ }
        next;
      }
      if ($ch eq "\\") { $s .= substr($l, $i, 2); $i++; next }
      if ($ch eq "\x27" || $ch eq "\"") { push @st, $ch; next }
      last if $ch eq "#" && ($i == 0 || substr($l, $i - 1, 1) =~ /[\s;&|(]/);
      if ($top eq "(") { if ($ch eq "(") { push @st, "(" } elsif ($ch eq ")") { pop @st } }
      $s .= $ch;
    }
    $doc = $1 if $s =~ /<<-?\s*Q?/ && $s !~ /<<</ && $l =~ /<<-?\s*[\x27"]?([A-Za-z_][A-Za-z0-9_]*)[\x27"]?/;
    next unless $all || $want{$.};
    next if $l =~ /#\s*unbounded-ok\b/;
    next unless $s =~ /(?:^|[;&|(`{!]|\$\(|\b(?:if|elif|while|until|then|do|else|exec|command|sudo|xargs|env|time)\s)\s*(?:[A-Za-z_][A-Za-z0-9_]*=\S*\s+)*(curl|wget|npx|npm|docker|gh\s+api|git(?:\s+-[Cc]\s+\S+)*\s+fetch)(?=\s|$|;)/;
    my $cmd = $1; $cmd =~ s/\s+/ /g; $cmd =~ s/^git .*fetch$/git fetch/;
    next if $l =~ /timeout|bounded|lowSpeedTime|--max-time|(?:^|\s)-m\s*[0-9]|(?:^|\s)-T\s*[0-9]/i;
    print "$ARGV:$.: unbounded-network: \x27$cmd\x27 has no timeout — wrap it in `timeout <secs>`, give it --max-time, or run it through a bounded wrapper (or end the line `# unbounded-ok: <why>`)\n";
    $bad = 1;
    END { exit $bad }' -- "$f" || bad=1
done < "$ranges"

[ "$bad" = 0 ] && say "ok"
exit "$bad"
