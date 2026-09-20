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

rm -rf "$MDIR"
exit $fail
