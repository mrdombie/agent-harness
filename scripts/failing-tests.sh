# failing-tests.sh — failing_test_files <log>: the test files a runner printed on a failure
# line, each once, in the order they appear. Sourced, and the only copy of this parse.
failing_test_files() {
  perl -ne 's/\e\[[0-9;]*[A-Za-z]//g;
    next unless /(\bFAIL(ED)?\b|\bfailed\b|\bnot ok\b|\xe2\x9c\x97|\xc3\x97|\xe2\x9c\x95|\xe2\x9c\x98)/;
    while (m{((?:[\w@.+-]+/)*[\w@+-][\w.@+-]*\.(?:test|spec)\.[A-Za-z]+)}g) {
      my $p = $1; $p =~ s{^(\./)+}{}; print "$p\n" }' "$1" 2>/dev/null | awk '!seen[$0]++'
}
