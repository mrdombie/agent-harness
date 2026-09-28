import os, re, shlex, sys

# Judges only commands actually run. Up to eight agents share one machine, each with its own
# dev servers and headless browsers. On 2026-09-24 one agent ran `pkill -f 'next dev apps/'`
# and `pkill -f chromium_headless` and killed every other agent's servers mid-capture; one of
# them lost an hour's unsaved fixes. A kill must name only what this agent started.
cmd = sys.argv[1]

# A heredoc BODY is DATA the command reads on stdin, not shell it runs. Without
# this, writing ABOUT the guard trips it: this very fix was blocked while posting
# the ticket comment that described it, because the comment quoted the pattern the
# rule denies. The hookify guard hit the identical wall the same day.
#
# Known limit, deliberate: `bash <<EOF` really does run its body. What agents
# actually use is `bash -c "…"`, and that text is not a heredoc.
def strip_heredocs(text):
    out, term = [], None
    for line in text.split('\n'):
        if term is not None:
            if line.strip() == term:
                term = None
            continue
        m = None
        for m in re.finditer(r'<<-?\s*(\"[^\"]+\"|\'[^\']+\'|[A-Za-z_][A-Za-z0-9_]*)', line):
            pass
        out.append(line)
        if m:
            term = m.group(1).strip('\'"')
    return '\n'.join(out)

cmd = strip_heredocs(cmd)
# A pattern is SCOPED when it can only match this agent's own processes: its
# worktree path, its ticket number — or a PORT. A port names exactly one server,
# and the design skills already derive one per ticket (3000 + the last three
# digits), so `pkill -f 'next dev --webpack -p 3346'` hits one agent and no
# other. Blocking it was a false positive that pushed agents toward the broad
# patterns this guard exists to stop: measured 2026-09-27, `-p <port>` and
# `-p=<port>` forms were refused while the bare `pkill -f 'next dev'` they then
# reached for was refused too, leaving no allowed way to stop your own server.
#
# The worktree shapes are project facts, so they arrive in the environment from
# the shell wrapper, which reads them out of .claude/harness.json. The fallbacks
# below are GENERIC on purpose — outside a configured checkout the guard still
# has to fire, and a hook that goes inert where it cannot read a config is the
# failure this kit keeps finding.
_prefix = os.environ.get('HARNESS_BRANCH_PREFIX') or ''
_wtroot = os.environ.get('HARNESS_WORKTREE_ROOT') or ''
_own = [
    re.escape(_prefix) + r'\d{3,}' if _prefix else r'[a-z]{2,8}-\d{3,}',
    r'/var/folders/', r'/private/var/folders/', r'/scratchpad/',
]
if _wtroot:
    _own.append(re.escape(_wtroot.rstrip('/') + '/'))
SCOPED = re.compile(
    '|'.join(_own)
    # FOUR digits minimum: ':30' or '-p 80' would match half the process table,
    # and a dev port is 3000-9999 everywhere this runs.
    + r'|(^|[^0-9])-p[= ]\d{4,5}(\D|$)|:\d{4,5}(\D|$)'
)
msg = ("Blocked: {} matches processes of every agent on this machine, not just yours. "
       "Kill the PIDs you started (write them to a file when you start them), or scope the "
       "pattern to your own worktree path, e.g. pkill -f '<your own worktree path>.*next'.")

try:
    lx = shlex.shlex(re.sub(r'\$\(|`', ' ; ', cmd), posix=True, punctuation_chars=True)
    lx.whitespace_split = True
    toks = list(lx)
except ValueError:
    sys.exit(0)

segs = [[]]
for t in toks:
    if t and set(t) <= set(';&|()\n'):
        segs.append([])
    else:
        segs[-1].append(t)

kill_present = any(seg and seg[0] in ('kill', 'xargs') and ('kill' in seg) for seg in segs) or \
    any(seg and seg[0] == 'kill' for seg in segs)

for seg in segs:
    while seg and (re.match(r'^[A-Z_][A-Z0-9_]*=', seg[0]) or seg[0] in ('sudo', 'exec', 'env', 'command')):
        seg = seg[1:]
    if not seg:
        continue
    name = seg[0].rsplit('/', 1)[-1]
    if name == 'killall':
        print(msg.format(f"`{' '.join(seg)}`"), file=sys.stderr)
        sys.exit(2)
    if name not in ('pkill', 'pgrep'):
        continue
    if name == 'pgrep' and not kill_present:
        continue  # looking is fine; only killing by the pattern is not
    if '-P' in seg:
        continue  # children of a named parent pid are that parent's own
    args, skip = [], False
    for a in seg[1:]:
        if skip:
            skip = False
            continue
        if set(a) <= set('<>&'):
            skip = True  # the next token is the redirect's target, not the pattern
            continue
        if a.startswith('-') or a.isdigit():
            continue
        args.append(a)
    pattern = args[-1] if args else ''
    if pattern and SCOPED.search(pattern):
        continue
    print(msg.format(f"`{name} {' '.join(seg[1:])}`"), file=sys.stderr)
    sys.exit(2)
sys.exit(0)
