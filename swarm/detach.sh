#!/usr/bin/env bash
# detach.sh <command…> — run a command in a session of its own, so a tool-call
# timeout, a restarted daemon or a closed terminal cannot take it down with
# them. macOS ships no setsid(1); perl's is the one that is always there.
exec perl -e 'use POSIX qw(setsid); setsid() or die "setsid: $!"; exec @ARGV or die "exec: $!"' -- "$@"
