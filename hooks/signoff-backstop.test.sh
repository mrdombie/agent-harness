#!/usr/bin/env bash
# Plant tests for signoff-backstop.sh. Exit 1 on any mismatch.
#
# Every case plants the thing that should make the hook fire or stay quiet.
# A hook that never fires is decorative; a hook that always fires is a loop.
H="$(dirname "$0")/signoff-backstop.sh"; fail=0
# The hook reads the state dir through the resolver; pin it to a scratch dir so
# the real .session-label is never the fixture.
export CLAUDE_PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "$0")/../.." && pwd)}"
export HARNESS_STATE_DIR="${HARNESS_STATE_DIR:-$(mktemp -d "${TMPDIR:-/tmp}/signoff-fixture-XXXXXX")}"
LABEL="$HARNESS_STATE_DIR/.session-label"
BAK=$(mktemp); SAVED=no
[ -f "$LABEL" ] && { cp "$LABEL" "$BAK"; SAVED=yes; }
MDIR="${TMPDIR:-/tmp}/claude-signoff-backstop"

restore(){ if [ "$SAVED" = yes ]; then cp "$BAK" "$LABEL"; else rm -f "$LABEL"; fi; rm -f "$BAK"; }
trap restore EXIT

# want: nag | quiet ; args: <desc> <last_assistant_message> <stop_hook_active> <session>
t(){ want=$1 desc=$2 msg=$3 active=$4 sess=$5
  jq -nc --arg m "$msg" --argjson a "$active" --arg s "$sess" \
    '{session_id:$s,hook_event_name:"Stop",stop_hook_active:$a,last_assistant_message:$m}' \
    | "$H" >/dev/null 2>&1
  [ $? -eq 2 ] && got=nag || got=quiet
  mark=OK; [ "$got" = "$want" ] || { mark=MISMATCH; fail=1; }
  printf '%-9s want=%-6s got=%-6s %s\n' "$mark" "$want" "$got" "$desc"; }

rm -rf "$MDIR"
printf 'content-lab\t%s\n' "$(date +%Y-%m-%dT%H:%M:%S%z)" > "$LABEL"

t nag   'fresh label, no banner in the reply'            'All done, merged it.'          false s1
rm -rf "$MDIR"
t quiet 'banner already present'                         '🏷️ Working on: Content Lab'    false s2
rm -rf "$MDIR"
t quiet 'stop_hook_active guard'                         'All done, merged it.'          true  s3

# cooldown: same session twice in a row must nag once, then go quiet
rm -rf "$MDIR"
t nag   'cooldown — first stop of the session'           'All done.'                     false s4
t quiet 'cooldown — second stop, same session'           'All done.'                     false s4
t nag   'cooldown is per session, not global'            'All done.'                     false s5

# absent scope
rm -rf "$MDIR"; rm -f "$LABEL"
t quiet 'no .session-label — nothing in play'            'All done.'                     false s6

# stale scope
rm -rf "$MDIR"
printf 'content-lab\t2020-01-01T00:00:00+0000\n' > "$LABEL"
touch -t 202001010000 "$LABEL"
t quiet 'label older than 6h — no live flow'             'All done.'                     false s7

# empty scope
rm -rf "$MDIR"; printf '\t%s\n' "$(date +%Y-%m-%dT%H:%M:%S%z)" > "$LABEL"
t quiet 'label file present but scope empty'             'All done.'                     false s8

# ---------------------------------------------------------------- peer scope
# .session-label is ONE global slot. Without this guard a session prints another
# session's scope in its banner, which is the one line the operator acts on.
#
# `ps` is stubbed so the identity walk has a fixed answer: without it
# claude_session_pid() finds no claude ancestor under a test runner, the guard
# can never fire, and every case below would pass on a dead guard.
STUB=$(mktemp -d "${TMPDIR:-/tmp}/signoff-ps-XXXXXX")
cat > "$STUB/ps" <<'STUBEOF'
#!/usr/bin/env bash
# args: -p <pid> [-o comm=|-o ppid=]
pid=""; field=""
while [ $# -gt 0 ]; do
  case "$1" in
    -p) pid=$2; shift 2 ;;
    -o) field=$2; shift 2 ;;
    *)  shift ;;
  esac
done
case "$field" in
  comm=) if [ "$pid" = "$FAKE_ME" ]; then echo "/opt/claude/native-binary/claude"; else echo "bash"; fi; exit 0 ;;
  ppid=) if [ "$pid" = "$FAKE_ME" ]; then echo "1"; else echo "$FAKE_ME"; fi; exit 0 ;;
  "")    case " $FAKE_LIVE " in *" $pid "*) exit 0 ;; *) exit 1 ;; esac ;;
esac
exit 0
STUBEOF
chmod +x "$STUB/ps"
export FAKE_ME=424242
export FAKE_LIVE="424242 515151"
OLDPATH=$PATH; export PATH="$STUB:$PATH"

printf 'content-lab\t%s\n' "$(date +%Y-%m-%dT%H:%M:%S%z)" > "$LABEL"

rm -rf "$MDIR"; echo 515151 > "$LABEL.owner"
t quiet 'scope owned by a LIVE peer session — do not demand its banner' 'All done.' false p1

rm -rf "$MDIR"; echo 424242 > "$LABEL.owner"
t nag   'scope owned by THIS session — still demanded'                  'All done.' false p2

rm -rf "$MDIR"; echo 999999 > "$LABEL.owner"
t nag   'owner recorded but dead — uncertain falls through to demanding' 'All done.' false p3

rm -rf "$MDIR"; rm -f "$LABEL.owner"
t nag   'no owner file at all — a solo session is unaffected'            'All done.' false p4

rm -rf "$MDIR"
# A scope written by a flow that did NOT claim it: the label is newer than the
# owner file, and the id in that file is ours. Before the staleness rule this
# read as "owner == me" and demanded a banner for a programme this session never
# chose. Measured 2026-09-24 with 43 minutes between the two files.
printf 'someone elses scope\t%s\n' "$(date +%Y-%m-%dT%H:%M:%S%z)" > "$LABEL"
echo "$FAKE_ME" > "$LABEL.owner"
touch -t 202609240954 "$LABEL.owner"
t quiet 'a scope whose owner file is older than it is not demanded'   'All done.' false p5

rm -rf "$MDIR"
# The control: both written together is the solo session, and it is still nagged.
printf 'our own scope\t%s\n' "$(date +%Y-%m-%dT%H:%M:%S%z)" > "$LABEL"
echo "$FAKE_ME" > "$LABEL.owner"
t nag   'both written together is a solo session, still demanded'     'All done.' false p6

export PATH=$OLDPATH; rm -rf "$STUB"; rm -f "$LABEL.owner"
unset FAKE_ME FAKE_LIVE

# A DRIVER STEP IS NOT A PERSON'S TURN. The banner is an instruction to an
# operator's terminal, and inside a driver step there is no operator — the exit 2
# made the model replace its whole final answer with the banner, so the driver read
# no JSON at all and both tickets of the 2026-09-27 trial parked at step 1 of 7.
# The control above it is the same input WITHOUT the marker: nag, then quiet.
rm -rf "$MDIR"
printf 'content-lab\t%s\n' "$(date +%Y-%m-%dT%H:%M:%S%z)" > "$LABEL"
rm -f "$LABEL.owner"
t nag   'the control: this input does nag'                 'All done, merged it.'  false d0
rm -rf "$MDIR"
HARNESS_DRIVER_RUN=10867:plan \
  t quiet 'and stands down for a driver step'              'All done, merged it.'  false d1

rm -rf "$MDIR"
exit $fail
