#!/usr/bin/env bash
# proof-case-filter.test.sh — a proof runs its command twice inside one time limit, so it
# runs the case, not the suite, and one slow run is the machine's until it is slow twice.
#
# Two builds parked "ran past its time limit … a watch-mode runner is the usual cause" on
# whole shell suites that take minutes alone and ran past 30 beside other builders.
#   - a test file that says it takes a case filter is proved with that filter: the whole
#     file is refused before a tree is built, and the refusal gives the command to use
#   - with the filter, the one case is red without the change and green with it
#   - a proof out of time waits for the machine and is taken once more with twice the
#     limit; out of time again, the note names the command and what each half took
#   - every step is told which test files take a filter, read off the files themselves
# case-filter: SUITE_ONLY='<a case title, or a pattern over them>' bash driver/tests/proof-case-filter.test.sh
# Run: bash "$0"
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/tests/lib/suite.sh" || exit 1
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/fixture.sh"
driver_fixture; on_exit_keep_status 'rm -rf "$FIX"'
. "$HERE/../steps/build.sh" || exit 1
. "$HERE/../facts.sh" || exit 1

# A project whose suite has two cases and takes a filter, with the kit's own suite library.
mkdir -p "$REPO/lib"; cp "$HERE/../../tests/lib/suite.sh" "$REPO/lib/suite.sh"
printf 'old\n' > "$REPO/greeting.txt"
words_suite() { # <with the second case: yes|no> — the suite, written whole
  {
    printf '%s\n' '#!/usr/bin/env bash' '# words.test.sh: two cases.' "# case-filter: SUITE_ONLY='<case title>' bash words.test.sh" '. lib/suite.sh' 'F=0'
    printf '%s\n' 'if suite_case "the file is there"; then [ -f greeting.txt ] || F=1; [ -z "${RUNS_LOG:-}" ] || echo there >> "$RUNS_LOG"; fi'
    [ "$1" != yes ] || printf '%s\n' 'if suite_case "it greets in the new words"; then grep -q new greeting.txt || F=1; [ -z "${RUNS_LOG:-}" ] || echo greets >> "$RUNS_LOG"; fi'
    printf '%s\n' 'suite_end "$F"'
  } > "$REPO/words.test.sh"
}
words_suite no
git -C "$REPO" add -A; git -C "$REPO" commit -qm "base: a suite with one case"
words_suite yes
git -C "$REPO" add -A; git -C "$REPO" commit -qm "test: it greets in the new words"
W_TEST=$(git -C "$REPO" rev-parse HEAD)
printf 'new\n' > "$REPO/greeting.txt"; git -C "$REPO" add -A; git -C "$REPO" commit -qm "feat: the new words"
W_IMPL=$(git -C "$REPO" rev-parse HEAD)
printf '#!/usr/bin/env bash\ngrep -q new greeting.txt\n' > "$REPO/plain.test.sh"
git -C "$REPO" add -A; git -C "$REPO" commit -qm "test: a file with no filter"

# slow_script — slow for its first SLOW_RUNS runs; into SLOW_MEM_FILE when set it writes 5%
# free for its first SLOW_TIGHT_RUNS runs and 60% after, as a build beside it takes the memory
# and gives it back (a proof drops SWARM_*).
slow_script() {
  printf '#!/usr/bin/env bash\nn=$(cat "$COUNT_FILE"); echo $((n + 1)) > "$COUNT_FILE"\nif [ -n "${SLOW_MEM_FILE:-}" ]; then if [ "$n" -lt "${SLOW_TIGHT_RUNS:-99}" ]; then echo 5; else echo 60; fi > "$SLOW_MEM_FILE"; fi\n[ "$n" -ge "${SLOW_RUNS:-2}" ] || sleep 30\ngrep -q yes slow.txt\n' > "$REPO/slow.test.sh"
}
# slow_commits — S_TEST and S_IMPL: the slow suite, made once.
slow_commits() {
  S_TEST=$(git -C "$REPO" log --format=%H --grep='^test: slow' -1); S_IMPL=$(git -C "$REPO" log --format=%H --grep='^feat: slow' -1)
  [ -z "$S_TEST" ] || return 0
  printf 'no\n' > "$REPO/slow.txt"; slow_script
  git -C "$REPO" add -A; git -C "$REPO" commit -qm "test: slow"; S_TEST=$(git -C "$REPO" rev-parse HEAD)
  printf 'yes\n' > "$REPO/slow.txt"; git -C "$REPO" add -A; git -C "$REPO" commit -qm "feat: slow"; S_IMPL=$(git -C "$REPO" rev-parse HEAD)
}

if suite_case "a test file says how it runs one case"; then
want "the filter is read off the file" "SUITE_ONLY='<case title>' bash words.test.sh" "$(driver_case_filter_of "$REPO/words.test.sh")"
rc=0; driver_case_filter_of "$REPO/plain.test.sh" >/dev/null || rc=$?
want "a file that names none has none" "1" "$rc"
printf '# case-filter: run it with care\n' > "$FIX/prose.test.sh"
rc=0; driver_case_filter_of "$FIX/prose.test.sh" >/dev/null || rc=$?
want "a line that names no variable is not a filter" "1" "$rc"
fi

if suite_case "the whole file is refused before a tree is built, with the command to give"; then
export RUNS_LOG="$FIX/runs.log"; : > "$RUNS_LOG"
out=$(driver_prove_red_green "$REPO" words.test.sh "$W_TEST" "$W_IMPL" "bash words.test.sh" 2>&1); rc=$?
want "the whole suite is not a proof command" "7" "$rc"
want_in "it says the file takes a case filter" 'runs all of words.test.sh, which takes a case filter' "$out"
want_in "and gives the command" "give it as: SUITE_ONLY='<case title>' bash words.test.sh" "$out"
want "nothing was run" "" "$(cat "$RUNS_LOG")"
out=$(driver_prove_red_green "$REPO" plain.test.sh "$W_TEST" "$W_IMPL" "bash plain.test.sh" 2>&1); rc=$?
want_not_in "a file with no filter is run whole, as before" 'case filter' "$out"
fi

if suite_case "with the filter, the one case is red then green"; then
export RUNS_LOG="$FIX/runs.log"; : > "$RUNS_LOG"
out=$(driver_prove_red_green "$REPO" words.test.sh "$W_TEST" "$W_IMPL" "SUITE_ONLY='it greets' bash words.test.sh" 2>&1); rc=$?
want "the case proves the change" "0" "$rc"
want_in "red then green" 'red .* then green' "$out"
want "only that case ran, once in each half" "greets greets" "$(tr '\n' ' ' < "$RUNS_LOG" | sed 's/ $//')"
out=$(driver_prove_red_green "$REPO" words.test.sh "$W_TEST" "$W_IMPL" "SUITE_ONLY='no such case' bash words.test.sh" 2>&1); rc=$?
want "a filter that matches no case is never green" "2" "$rc"
fi

if suite_case "out of time once: it waits for the machine and is taken once more"; then
# Slow for its first two runs (the two halves of the first proof), quick after: a busy machine.
printf '0\n' > "$FIX/count"; export COUNT_FILE="$FIX/count"
printf 'no\n' > "$REPO/slow.txt"
slow_script
git -C "$REPO" add -A; git -C "$REPO" commit -qm "test: slow"
S_TEST=$(git -C "$REPO" rev-parse HEAD)
printf 'yes\n' > "$REPO/slow.txt"; git -C "$REPO" add -A; git -C "$REPO" commit -qm "feat: slow"
S_IMPL=$(git -C "$REPO" rev-parse HEAD)
out=$(DRIVER_CMD_TIMEOUT=2 driver_prove_red_green "$REPO" slow.test.sh "$S_TEST" "$S_IMPL" "bash slow.test.sh" 2>&1); rc=$?
want "the second take proves it" "0" "$rc"
want_in "it said it waits for the machine" 'proof: out of time after [0-9]+s \(limit 2s a half.*waiting for the machine, then taken once more with twice the limit' "$out"
want "four runs: two cut off, two finished" "4" "$(cat "$FIX/count")"
want "the gate slot is given back" "" "$(ls "$HARNESS_GATE_SLOT_DIR" 2>/dev/null | grep -v '\.lock$' | head -1)"
fi

if suite_case "out of time twice: the note names the command and what each half took"; then
printf '0\n' > "$FIX/count"; export COUNT_FILE="$FIX/count"
slow_commits
out=$(SWARM_FREE_MEM_PCT=60 SWARM_SWAP_PCT=0 SLOW_RUNS=99 DRIVER_CMD_TIMEOUT=2 driver_prove_red_green "$REPO" slow.test.sh "$S_TEST" "$S_IMPL" "bash slow.test.sh" 2>&1); rc=$?
want "still out of time: its own refusal" "4" "$rc"
want "taken twice and no more" "4" "$(cat "$FIX/count")"
want_in "the note names the command and the limit of the second take" 'slow.test.sh ran out of time: .bash slow.test.sh. did not finish within 4s' "$out"
want_in "and what each half took" '\(without the change: stopped at [0-9]+s; with it: stopped at [0-9]+s\)' "$out"
want_in "and that it was taken twice" 'taken twice, the second time alone in a machine gate slot with twice the limit' "$out"
want_not_in "it guesses at no cause" 'watch-mode' "$out"
want_not_in "the fallback park wording guesses at none either" 'watch-mode' "$(cat "$HERE/../build-ticket")"
want_not_in "with memory to spare it names no memory" 'out of memory' "$out"
fi

if suite_case "out of time under memory pressure: it waits for memory, is taken once more, and names memory"; then
printf '0\n' > "$FIX/count"; export COUNT_FILE="$FIX/count"
slow_commits
printf '#!/usr/bin/env bash\necho 60 > "%s"\n' "$FIX/mem-pct" > "$FIX/mem-raise"; chmod +x "$FIX/mem-raise"
printf '60\n' > "$FIX/mem-pct"
out=$(unset SWARM_FREE_MEM_PCT; SLOW_MEM_FILE="$FIX/mem-pct" SWARM_FREE_MEM_PCT_FILE="$FIX/mem-pct" SWARM_SWAP_PCT=0 MACHINE_GATE_ON_WAIT="$FIX/mem-raise" MACHINE_GATE_POLL=0 \
  SLOW_RUNS=99 DRIVER_CMD_TIMEOUT=2 driver_prove_red_green "$REPO" slow.test.sh "$S_TEST" "$S_IMPL" "bash slow.test.sh" 2>&1); rc=$?
want "still out of time: its own refusal" "4" "$rc"
want "taken twice and no more" "4" "$(cat "$FIX/count")"
want_in "the retry waited on memory" 'machine busy \(free memory 5%' "$out"
want_in "the note names memory" 'the machine was out of memory \(free memory 5%, floor 10%\)' "$out"
want_not_in "it guesses at no cause" 'watch-mode' "$out"
fi

if suite_case "out of memory at the first timeout, memory to spare at the second: it names no memory"; then
printf '0\n' > "$FIX/count"; export COUNT_FILE="$FIX/count"
slow_commits
printf '#!/usr/bin/env bash\necho 60 > "%s"\n' "$FIX/mem-pct" > "$FIX/mem-raise"; chmod +x "$FIX/mem-raise"
printf '60\n' > "$FIX/mem-pct"
out=$(unset SWARM_FREE_MEM_PCT; SLOW_MEM_FILE="$FIX/mem-pct" SLOW_TIGHT_RUNS=2 SWARM_FREE_MEM_PCT_FILE="$FIX/mem-pct" SWARM_SWAP_PCT=0 MACHINE_GATE_ON_WAIT="$FIX/mem-raise" MACHINE_GATE_POLL=0 \
  SLOW_RUNS=99 DRIVER_CMD_TIMEOUT=2 driver_prove_red_green "$REPO" slow.test.sh "$S_TEST" "$S_IMPL" "bash slow.test.sh" 2>&1); rc=$?
want "still out of time: its own refusal" "4" "$rc"
want "taken twice and no more" "4" "$(cat "$FIX/count")"
want_in "the retry waited on memory" 'machine busy \(free memory 5%' "$out"
want_in "and that it was taken twice" 'taken twice, the second time alone in a machine gate slot with twice the limit' "$out"
want_not_in "the second timeout had memory to spare: memory is not named" 'out of memory' "$out"
fi

if suite_case "every step is told which test files take a filter"; then
facts=$(MAIN_REPO="$REPO" DRIVER_TICKET="" _driver_fact_case_filters)
want_in "the fact names the file" 'run one case at a time \(1: words.test.sh\)' "$facts"
want_in "and the way to run one case" "SUITE_ONLY='<case title>' bash words.test.sh" "$facts"
want_in "it is part of the project facts every step reads" 'words.test.sh' "$(MAIN_REPO="$REPO" DRIVER_TICKET="" driver_fact_project)"
git init -q "$FIX/bare-proj"; git -C "$FIX/bare-proj" -c user.email=t@example.invalid -c user.name=t commit -q --allow-empty -m root
want "a project with no such file is told nothing" "" "$(MAIN_REPO="$FIX/bare-proj" DRIVER_TICKET="" _driver_fact_case_filters)"
fi

suite_end "$FAILED"
