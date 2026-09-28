import os, re, shlex, sys

# Judges only commands actually run. The same words inside a quoted string (an agent brief,
# a commit message, an echo) are one token and never match.
#
# The changed-only commands are a project fact and arrive in CHANGED_CMDS from the
# shell wrapper, which reads gates.changed out of .claude/harness.json. The
# fallback names the npm shape because that is what the wrapper cannot guess —
# and a guard that goes silent where it cannot read a config is not a guard.
cmd = sys.argv[1]
#
# NO SCRIPT NAME IS HARDCODED. The kit must not tell an agent to run a command
# only one project has: `npm run <missing>` prints nothing and exits 1, which
# reads as a gate failure rather than a missing script. When the config names
# nothing, the message describes the check instead of inventing its name.
CHANGED = os.environ.get('HARNESS_GATES_CHANGED') or \
    'the changed-only checks your project declares under gates.changed in .claude/harness.json'
FORMAT_CHANGED = os.environ.get('HARNESS_FORMAT_CHANGED') or \
    'your project\'s changed-only formatter'
msg = ("Blocked: {} reflows files you did not change (the integration branch is only "
       "diff-formatted). Run " + FORMAT_CHANGED + ", or pass the exact files you edited.")
cmd = re.sub(r'\$\((?:[^()]|\([^()]*\))*\)', 'CHANGED_FILES.ts', cmd)  # $(git status …) = changed files
try:
    lx = shlex.shlex(cmd, posix=True, punctuation_chars=True)
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

for seg in segs:
    while seg and (re.match(r'^[A-Z_][A-Z0-9_]*=', seg[0]) or seg[0] in ('npx', 'exec', 'env', 'time')):
        seg = seg[1:]
    # Spawned agents check only what they changed (measured 2026-09-28: load 32-40 on 10
    # cores while every agent ran the whole-app typecheck and full suites; an instruction
    # alone gets ignored). Only unattended runs — spawn-claim exports CLAIM_RUN_LOG, so a
    # person's own interactive session is untouched.
    if os.environ.get('CLAIM_RUN_LOG'):
        heavy = None
        def full(name):
            # A project may have redefined the plain name to BE changed-only; read its
            # own definition rather than assuming. Unreadable -> treat as whole-app.
            try:
                import json
                v = json.load(open('package.json')).get('scripts', {}).get(name, '')
            except Exception:
                v = ''
            return 'changed' not in v
        if len(seg) >= 3 and seg[0] == 'npm' and seg[1] == 'run' and seg[2] in ('typecheck:all', 'test:all', 'lint:all'):
            heavy = f"npm run {seg[2]}"
        elif len(seg) >= 3 and seg[0] == 'npm' and seg[1] == 'run' and seg[2] in ('typecheck', 'test', 'lint') and full(seg[2]):
            heavy = f"npm run {seg[2]}"
        elif len(seg) >= 2 and seg[0] == 'npm' and seg[1] in ('test', 't') and full('test'):
            heavy = 'npm test'
        elif seg and (seg[0] == 'vitest' or seg[0].endswith('/vitest')) and not any(
                not a.startswith('-') and a not in ('run', 'related') for a in seg[1:]):
            heavy = 'vitest over the whole repo'
        if heavy:
            print(f"Blocked: {heavy} runs the whole app and swamps a machine several agents "
                  f"are sharing. Agents run the changed-only checks: `{CHANGED}`. "
                  "The push hook and CI run everything else.", file=sys.stderr)
            sys.exit(2)
    if len(seg) >= 3 and seg[0] == 'npm' and seg[1] == 'run' and seg[2] == 'format':
        print(msg.format("the whole-repo format script"), file=sys.stderr)
        sys.exit(2)
    if not seg or not (seg[0] == 'prettier' or seg[0].endswith('/prettier')):
        continue
    if not any(a in ('--write', '-w') for a in seg[1:]):
        continue
    skip = False
    for t in seg[1:]:
        if skip:
            skip = False
            continue
        if t.isdigit():
            continue  # the fd number in "2>&1", split off by the lexer
        if set(t) <= set('<>&') or t in ('2>', '1>') or re.match(r'^\d*>>?$', t):
            skip = True
            continue
        if re.match(r'^\d*>>?&?\d*$', t) or t.startswith(('>', '<')):
            continue
        if t.startswith('-') or t == 'CHANGED_FILES.ts':
            continue
        last = t.rstrip('/').split('/')[-1]
        if t in ('.', './') or '*' in t or not re.search(r'\.[A-Za-z0-9]+$', last):
            print(msg.format(f"prettier --write on `{t}`"), file=sys.stderr)
            sys.exit(2)
sys.exit(0)
