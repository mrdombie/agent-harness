import glob, hashlib, json, os, re, shlex, subprocess, sys, tempfile

# Refuses an agent's change to `preApprovedWrites` in a .claude/harness.json, and
# to `integrationBranch`, which names the branch the injector anchors it on.
#
# The key grants pre-approval for writes against the environments it names, and
# the session-start injector reads it from the repo. So an agent that edits it
# has approved itself in its next session: the same trap as an agent applying a
# sign-off label the gate cannot attribute. Only the operator adds or widens it.
#
# The judgement is on the PARSED value, before against after, wherever the after
# state can be computed: Write, Edit, cp/mv/ln/install/rsync over the file, a
# heredoc `cat >`/`tee`, `git checkout|restore` from a ref, `git apply|am`, `git
# commit` (index and working tree against HEAD) and `git push` (the pushed commit
# against where it forked from the integration branch). A command that names the
# file and is neither one of those nor a known reader is refused: its result
# cannot be computed without running it. Removing the key is allowed: it grants
# nothing, so it can only narrow.
#
# Not seen, by construction: a write that never names the file (a variable, a
# script behind npm/make, git plumbing). The injector covers those: it honours
# only the value on origin's integration branch, which takes a push and a merge.

KEYS = ('preApprovedWrites', 'integrationBranch')
MAX_SCRIPT = 256 * 1024
WRITE_FLAGS = ('>', '>>', '>|', '&>', '&>>')
REDIRECTS = {'>', '>>', '>|', '&>', '&>>', '<', '<<', '<<-', '<<<', '>&', '<&'}
INTERPRETERS = re.compile(r'^(python[0-9.]*|py|node|nodejs|deno|bun|tsx|ts-node|ruby|perl|php|osascript|lua|Rscript)$')
SHELLS = {'bash', 'sh', 'zsh', 'dash', 'ksh'}
INPLACE = {'sed', 'gsed', 'perl', 'ruby', 'awk', 'gawk'}
# Commands that only read a file they name. Anything else naming harness.json
# that no rule below can compute is refused.
READERS = {'cat', 'jq', 'grep', 'egrep', 'fgrep', 'rg', 'ag', 'head', 'tail', 'less', 'more', 'wc', 'diff',
           'cmp', 'ls', 'stat', 'file', 'echo', 'printf', 'bat', 'test', '[', 'shasum', 'sha256sum', 'md5',
           'md5sum', 'cksum', 'git', 'gh', 'realpath', 'readlink', 'dirname', 'basename', 'open', 'code',
           'column', 'sort', 'uniq', 'cut', 'tr', 'nl', 'od', 'xxd', 'hexdump', 'true', 'false', ':',
           'node', 'python', 'python3', 'cd', 'pushd', 'popd', 'source', '.', 'bash', 'sh', 'zsh'}
# What a script does to a file once it has named it. Text, by necessity: the
# result cannot be computed without running the script.
WRITE_MARK = re.compile(r'''(?<!stdout)(?<!stderr)\.write(_text|_bytes)?\(|writeFile|appendFile|createWriteStream|'''
                        r'''open\([^)]*,\s*(mode\s*=\s*)?['"][wax]\+?b?['"]|['"]r\+b?['"]|os\.rename|os\.replace|renameSync|'''
                        r'''unlink|os\.remove|truncate|shutil|copyFile|\bmv\b|\bcp\b|\bsed\b|>\s*['"]?[^\s'"]*harness\.json''')
SHELL_WORDS = {'if', 'then', 'elif', 'else', 'do', 'while', 'until', '!', '{', '}', 'fi', 'done', 'esac'}
# Git settings that move what a push sends, where the remote is, or what runs on commit.
GIT_KEYS = re.compile(r'^(remote\..+\.(url|pushurl|push|fetch)|url\..+\.(insteadof|pushinsteadof)|alias\..+|core\.hookspath|'
                      r'include\.path|includeif\..+)$', re.I)

ASK = ("Only the operator adds, widens or edits `preApprovedWrites` (or the `integrationBranch` it is "
       "anchored on): an agent that changes it has approved itself, the same as an agent applying a "
       "sign-off label. Ask the operator to make this change. Removing `preApprovedWrites` is allowed. "
       "For an unrelated edit to harness.json, use the Edit tool: it shows the guard the key is unchanged.")


def refuse(why):
    sys.stderr.write('Blocked: ' + why + ' ' + ASK + '\n')
    sys.exit(2)


def value_of(text):
    """Both keys as the injector would see them: canonical JSON, ABSENT, or MALFORMED:<hash>."""
    if text is None:
        return ('ABSENT', 'ABSENT')
    dup = []

    def pairs(kv):
        ks = [k for k, _ in kv]
        if any(ks.count(k) > 1 for k in KEYS):
            dup.append(1)
        return dict(kv)
    try:
        obj = json.loads(text, object_pairs_hook=pairs)
    except Exception:
        obj = None
    if obj is None or dup or not isinstance(obj, dict):
        # Two different broken files are two different values.
        h = 'MALFORMED:' + hashlib.sha256(text.encode('utf-8', 'surrogateescape')).hexdigest()[:16]
        return (h, h)
    return tuple(json.dumps(obj[k], sort_keys=True, separators=(',', ':')) if k in obj else 'ABSENT' for k in KEYS)


def show(v):
    return 'absent' if v == 'ABSENT' else ('unreadable JSON' if v.startswith('MALFORMED') else v)


def allowed(b, a):
    return a == b or (a[0] == 'ABSENT' and a[1] == b[1])


def judge(before_text, after_text, where, shared=None):
    b, a = value_of(before_text), value_of(after_text)
    if allowed(b, a):
        return
    # Taking the operator's own value from the integration branch is not self-approval.
    if shared is not None and value_of(shared) == a and a[0] != 'ABSENT':
        return
    k = 0 if a[0] != b[0] else 1
    refuse('this changes `%s` in %s (%s -> %s).' % (KEYS[k], where, show(b[k]), show(a[k])))


def read(path):
    try:
        with open(path, 'rb') as fh:
            return fh.read(MAX_SCRIPT * 8).decode('utf-8', 'surrogateescape')
    except Exception:
        return None


KNOWN = []  # (dev, ino) of the config files this call can reach


def is_cfg(path):
    # Case-folded: the default macOS volume is case-insensitive, so .CLAUDE/Harness.JSON is the file.
    for p in {os.path.abspath(path), os.path.realpath(path)}:
        if os.path.basename(p).lower() == 'harness.json' and os.path.basename(os.path.dirname(p)).lower() == '.claude':
            return True
    try:
        st = os.stat(path)  # a hard link to it under another name
        return (st.st_dev, st.st_ino) in KNOWN
    except OSError:
        return False


def is_gitprot(path):
    """git's own config and hooks: rewriting them moves the remote, the push or what runs on commit."""
    p = os.path.realpath(os.path.expanduser(path)).replace('\\', '/')
    parts = p.lower().split('/')
    if parts[-1] == '.gitconfig' or p.lower().endswith('/.config/git/config'):
        return True
    if '.git' in parts:
        k = parts.index('.git')
        return parts[-1] == 'config' or 'hooks' in parts[k:] or parts[-1] in ('packed-refs',)
    return False


def gitprot_refuse(path):
    refuse('this writes %s, git\'s own config or hooks, which decide where pushes go and what runs on commit.' % path)


def clean_env():
    return {k: v for k, v in os.environ.items() if not k.startswith('GIT_')}


def git(repo, *args):
    try:
        r = subprocess.run(['git', '--no-replace-objects', '-C', repo] + list(args), capture_output=True,
                           env=clean_env(), timeout=10)
    except Exception:
        return None
    return r.stdout.decode('utf-8', 'surrogateescape') if r.returncode == 0 else None


def toplevel(d):
    out = git(d, 'rev-parse', '--show-toplevel')
    return out.strip() if out else None


def learn(d):
    for base in filter(None, {toplevel(d), os.environ.get('CLAUDE_PROJECT_DIR')}):
        try:
            st = os.stat(os.path.join(base, '.claude', 'harness.json'))
            KNOWN.append((st.st_dev, st.st_ino))
        except OSError:
            pass


# ---- Write / Edit ---------------------------------------------------------------

def judge_file_tool(tool, ti):
    path = ti.get('file_path') or ''
    if not path:
        return
    learn(os.path.dirname(path) or '.')
    if is_gitprot(path):
        gitprot_refuse(path)
    if not is_cfg(path):
        return
    before = read(path)
    if tool == 'Write':
        after = ti.get('content', '')
    else:
        edits = ti.get('edits') or [ti]
        after = before
        for e in edits:
            old, new = e.get('old_string', ''), e.get('new_string', '')
            if after is None or not old or old not in after:
                return  # the tool itself will fail: nothing is written
            after = after.replace(old, new) if e.get('replace_all') else after.replace(old, new, 1)
    top = toplevel(os.path.dirname(os.path.realpath(path)))
    judge(before, after, path, shared_value(top) if top else None)


# ---- Bash -------------------------------------------------------------------------

def scan(text):
    """Shell text with comments and heredoc bodies removed, plus the bodies in order.

    Quote-aware: `<<` or `#` inside quotes is text, not a heredoc or a comment,
    so a quoted one cannot hide the lines after it."""
    out, bodies, pending = [], [], []
    i, n, q = 0, len(text), None
    while i < n:
        c = text[i]
        if q == "'":
            out.append(c)
            if c == "'":
                q = None
            i += 1
            continue
        if c == '\\' and i + 1 < n:
            out.append(text[i:i + 2])
            i += 2
            continue
        if q == '"':
            out.append(c)
            if c == '"':
                q = None
            i += 1
            continue
        if text.startswith("$'", i):
            # ANSI-C quoting, which shlex cannot read: emitted as a plain single-quoted word.
            j, buf = i + 2, []
            while j < n and text[j] != "'":
                if text[j] == '\\' and j + 1 < n:
                    buf.append({'n': '\n', 't': '\t'}.get(text[j + 1], text[j + 1]))
                    j += 2
                else:
                    buf.append(text[j])
                    j += 1
            out.append("'" + ''.join(buf).replace("'", "'\\''") + "'")
            i = j + 1
            continue
        if c in '\'"':
            q = c
            out.append(c)
            i += 1
            continue
        if c == '#' and (not out or out[-1][-1:] in ' \t\n;|&('):
            while i < n and text[i] != '\n':
                i += 1
            continue
        if text.startswith('<<', i) and not text.startswith('<<<', i) and not (out and out[-1].endswith('<')):
            m = re.match(r'<<(-?)[ \t]*("([^"]+)"|\'([^\']+)\'|\\?([A-Za-z_][A-Za-z0-9_]*))', text[i:])
            if m:
                pending.append((m.group(3) or m.group(4) or m.group(5), m.group(1) == '-'))
                out.append(m.group(0))
                i += m.end()
                continue
        if c == '\n' and pending:
            out.append('\n')
            i += 1
            for term, strip in pending:
                buf = []
                while i < n:
                    j = text.find('\n', i)
                    line = text[i:] if j < 0 else text[i:j]
                    i = n if j < 0 else j + 1
                    if (line.lstrip('\t') if strip else line) == term:
                        break
                    buf.append(line)
                bodies.append('\n'.join(buf) + '\n')
            pending = []
            continue
        out.append(c)
        i += 1
    for _ in pending:  # a heredoc opened on the last line has an empty body
        bodies.append('')
    return ''.join(out), bodies


def tokens(code):
    lx = shlex.shlex(code, posix=True, punctuation_chars='();<>|&\n')
    lx.whitespace = ' \t\r'
    lx.commenters = ''
    lx.whitespace_split = True
    return list(lx)


def is_sep(t):
    # Punctuation runs arrive grouped (`;\n`, `&&\n`), so test by content.
    return t not in REDIRECTS and t != '' and all(c in '();<>|&\n' for c in t)


def segments(toks):
    seg = []
    for t in toks:
        if is_sep(t):
            if seg:
                yield seg
            seg = []
        else:
            seg.append(t)
    if seg:
        yield seg


def expand(tok, cwd):
    p = os.path.expanduser(tok)
    p = p if os.path.isabs(p) else os.path.join(cwd, p)
    if any(c in tok for c in '*?['):
        return glob.glob(p) or [p]
    return [p]


def names_cfg(toks, cwd):
    for t in toks:
        if 'harness.json' in t.lower():
            return True
        val = t.split('=', 1)[1] if t.startswith('-') and '=' in t else t
        if any(is_cfg(p) for p in expand(val, cwd)):
            return True
    return False


def args_of(seg):
    """Command words, redirects, and leading VAR=value assignments, apart."""
    args, redirs, i = [], [], 0
    while i < len(seg):
        t = seg[i]
        if t in REDIRECTS:
            if i + 1 < len(seg):
                redirs.append((t, seg[i + 1]))
            i += 2
            continue
        if re.fullmatch(r'[0-9]', t) and i + 1 < len(seg) and seg[i + 1] in REDIRECTS:
            i += 1
            continue
        args.append(t)
        i += 1
    while args and args[0] in SHELL_WORDS:
        args = args[1:]
    assigns = {}
    while args and (re.fullmatch(r'[A-Za-z_][A-Za-z0-9_]*=.*', args[0]) or
                    args[0] in ('sudo', 'command', 'exec', 'time', 'nohup', 'env', 'builtin', 'xargs', 'nice')):
        if '=' in args[0] and not args[0].startswith('-'):
            k, v = args[0].split('=', 1)
            assigns[k] = v
        args = args[1:]
    return args, redirs, assigns


def judge_bash(cmd, cwd, depth=0):
    if depth > 3:
        return
    learn(cwd)
    code, bodies = scan(cmd)
    try:
        toks = tokens(code)
    except ValueError:
        if re.search(r'harness\.json|\.claude|\.git/|\bgit\b|\btee\b|\bcp\b|\bmv\b|\bsed\b|>', cmd, re.I):
            refuse('the guard could not parse this command, and it runs git or writes files, so it cannot see '
                   'what it does. Rewrite it in plainer shell (no unbalanced quotes).')
        return
    body_i = 0
    for seg in segments(toks):
        args, redirs, assigns = args_of(seg)
        here = None
        nhere = sum(1 for op, _ in redirs if op in ('<<', '<<-'))
        if nhere:
            here = bodies[body_i] if body_i < len(bodies) else ''
            body_i += nhere
        for op, t in redirs:
            if op == '<':
                here = read(expand(t, cwd)[0])
            elif op == '<<<':
                here = t + '\n'
        if not args:
            continue
        name = os.path.basename(args[0])
        # Redirect onto the file. Only a plain `cat` of a heredoc has a known result.
        for op, target in redirs:
            if op in WRITE_FLAGS and any(is_gitprot(p) for p in expand(target, cwd)):
                gitprot_refuse(target)
            if op in WRITE_FLAGS and any(is_cfg(p) for p in expand(target, cwd)):
                path = expand(target, cwd)[0]
                if name == 'cat' and len(args) == 1 and here is not None:
                    before = read(path)
                    judge(before, (before or '') + here if op == '>>' else here, path)
                else:
                    refuse('this redirects output onto %s, and the guard cannot see what that output is.' % target)
        if name in ('for', 'case', 'select', 'function', 'rm', 'unlink', 'trash'):
            continue  # a loop header names no command; removing the file grants nothing
        files = [a for a in args[1:] if not a.startswith('-')]
        dests = files[-1:] if name in ('cp', 'mv', 'ln', 'install', 'rsync', 'ditto') else \
            files if name in ('tee', 'touch', 'truncate') or (name in INPLACE and any(
                re.fullmatch(r'-[lnpawsE0-9]*i\S*|--in-place\S*', a) for a in args[1:])) else []
        for a in dests:
            if any(is_gitprot(p) for p in expand(a, cwd)):
                gitprot_refuse(a)
        if name in ('cd', 'pushd'):
            if len(args) > 1 and not args[1].startswith('-'):
                cwd = expand(args[1], cwd)[0]
                learn(cwd)
            continue
        if name in SHELLS or name in ('eval', 'source', '.'):
            inner = None
            if name == 'eval':
                inner = ' '.join(args[1:])
            elif '-c' in args[1:]:
                k = args.index('-c')
                inner = args[k + 1] if k + 1 < len(args) else None
            elif len(args) > 1 and not args[1].startswith('-'):
                inner = read(expand(args[1], cwd)[0])
            elif here is not None:
                inner = here
            if inner:
                judge_bash(inner, cwd, depth + 1)
            continue
        if name == 'git':
            judge_git(args, cwd, here, assigns)
            continue
        if name in ('cp', 'mv', 'ln', 'install', 'rsync', 'gcp', 'gmv', 'ditto'):
            judge_copy(name, args, cwd)
            continue
        if name == 'tee':
            for a in args[1:]:
                if not a.startswith('-') and is_cfg(expand(a, cwd)[0]):
                    path = expand(a, cwd)[0]
                    if here is not None and '-a' not in args and '--append' not in args:
                        judge(read(path), here, path)
                    else:
                        refuse('this tees output onto %s, and the guard cannot see what that output is.' % a)
            continue
        if name in INPLACE and names_cfg(args[1:], cwd) and \
                any(re.fullmatch(r'-[lnpawsE0-9]*i\S*|--in-place\S*', a) for a in args[1:]):
            refuse('this edits harness.json in place with %s, and the guard cannot see the result without running it.' % name)
        if name == 'patch':
            texts = [here or ''] + [read(expand(a, cwd)[0]) or '' for a in args[1:] if not a.startswith('-')]
            if any('harness.json' in t for t in texts) or names_cfg(args[1:], cwd):
                refuse('this patches harness.json with patch(1), and the guard cannot see the result. Use git apply, which it can replay.')
            continue
        if name == 'gh':
            if names_cfg(args[1:], cwd) and any(
                    a in ('PUT', 'PATCH', 'POST', 'DELETE', '-f', '-F', '--field', '--raw-field', '--input')
                    or a.startswith('--method') or a.startswith('-X') for a in args[1:]):
                refuse('this writes harness.json on the remote through the GitHub API, where the guard cannot see the value.')
            continue
        if INTERPRETERS.match(name) or os.path.isfile(expand(args[0], cwd)[0]):
            judge_script(name, args, cwd, here, depth)
            continue
        if name == 'find' and names_cfg(args[1:], cwd):
            if any(a in ('-exec', '-execdir', '-ok', '-okdir', '-delete', '-fprint', '-fprintf', '-fls') for a in args[1:]):
                refuse('this runs find over harness.json with an action, and the guard cannot see what it does.')
            continue
        if name in ('sed', 'gsed', 'awk', 'gawk'):
            # Reading the file is fine; naming it inside the script (sed `w`, awk `print >`) writes it.
            if any('harness.json' in a.lower() and not is_cfg(expand(a, cwd)[0]) for a in args[1:]):
                refuse('this %s script names harness.json, and the guard cannot see what it writes there.' % name)
            continue
        if name not in READERS and (names_cfg(args[1:], cwd) or (here and 'harness.json' in here)):
            refuse('`%s` names harness.json, and the guard cannot see what it does to it.' % name)


def judge_script(name, args, cwd, here, depth):
    texts = []
    if here:
        texts.append(here)
    for a in args[1:]:
        if not a.startswith('-') or a.startswith('-e') or a.startswith('-c'):
            texts.append(a)
            p = expand(a, cwd)[0]
            if os.path.isfile(p) and os.path.getsize(p) < MAX_SCRIPT and not is_cfg(p):
                texts.append(read(p) or '')
    if not INTERPRETERS.match(name):
        # An executable named as the command: a shell script is judged as shell.
        p = expand(args[0], cwd)[0]
        if os.path.getsize(p) >= MAX_SCRIPT:
            return
        src = read(p) or ''
        if not src.startswith('#!'):
            return
        first = src.split('\n', 1)[0]
        if re.search(r'\b(ba|z|da|k)?sh\b', first):
            judge_bash(src, cwd, depth + 1)
            return
        texts.append(src)
    for t in texts:
        if 'harness.json' in t.lower() and WRITE_MARK.search(t):
            refuse('this runs a script that names harness.json and writes files, and the guard cannot see what it writes.')


def covers(path_tok, cwd, top):
    """True when a pathspec can reach <top>/.claude/harness.json. Magic and globs count."""
    if path_tok.startswith(':') or any(c in path_tok for c in '*?['):
        return True
    top = os.path.realpath(top)
    cfg = os.path.join(top, '.claude', 'harness.json').lower()
    for p in expand(path_tok, cwd):
        p = os.path.realpath(p).rstrip('/').lower()
        if p == cfg or cfg.startswith(p + '/') or p == top.lower():
            return True
    return False


def anchor(top):
    """The integration branch as origin's default branch names it. Local refs: this is the
    drift check. The injector asks the remote itself, so a forged local ref grants nothing."""
    for cand in ('origin/HEAD', 'origin/develop', 'origin/main'):
        text = git(top, 'show', cand + ':.claude/harness.json')
        if text is None:
            continue
        try:
            ib = json.loads(text).get('integrationBranch')
        except Exception:
            ib = None
        if isinstance(ib, str) and ib and git(top, 'rev-parse', '--verify', '-q', 'origin/' + ib + '^{commit}'):
            return 'origin/' + ib
        return cand
    return None


def shared_value(top):
    ref = anchor(top)
    return git(top, 'show', ref + ':.claude/harness.json') if ref else None


def judge_git(args, cwd, here, assigns):
    if any(k in assigns for k in ('GIT_DIR', 'GIT_WORK_TREE', 'GIT_INDEX_FILE', 'GIT_OBJECT_DIRECTORY')):
        if any(a in ('commit', 'push', 'checkout', 'restore', 'apply', 'am', 'add', 'stage', 'read-tree', 'update-index')
               for a in args[1:]):
            refuse('this runs git with its own GIT_ environment, so the guard cannot see which tree or index it changes.')
    i, repo, aliases = 1, cwd, {}
    while i < len(args) and args[i].startswith('-'):
        a = args[i]
        if a in ('-C', '-c', '--git-dir', '--work-tree') and i + 1 < len(args):
            v = args[i + 1]
            if a == '-C':
                repo = expand(v, repo)[0]
            elif a == '--work-tree':
                repo = expand(v, repo)[0]
            elif a == '--git-dir':
                repo = os.path.dirname(expand(v, repo)[0].rstrip('/'))
            elif v.startswith('alias.') and '=' in v:
                aliases[v[6:].split('=', 1)[0]] = v.split('=', 1)[1]
            elif GIT_KEYS.match(v.split('=', 1)[0]):
                refuse('this runs git with `-c %s`, which moves where it pushes or what it runs.' % v.split('=', 1)[0])
            i += 2
        else:
            if a.startswith('--work-tree='):
                repo = expand(a.split('=', 1)[1], repo)[0]
            elif a.startswith('--git-dir='):
                repo = os.path.dirname(expand(a.split('=', 1)[1], repo)[0].rstrip('/'))
            i += 1
    if i >= len(args):
        return
    sub, rest = args[i], args[i + 1:]
    top = toplevel(repo)
    if not top:
        return
    learn(top)
    alias = aliases.get(sub) or (git(top, 'config', '--get', 'alias.' + sub) or '').strip()
    if alias:
        if alias.startswith('!'):
            judge_bash(alias[1:] + ' ' + ' '.join(shlex.quote(a) for a in rest), repo, 1)
            return
        parts = shlex.split(alias)
        sub, rest = parts[0], parts[1:] + rest
    rel = '.claude/harness.json'
    cfg = os.path.join(top, rel)
    at = lambda ref: git(top, 'show', ref + ':' + rel)
    pos = [a for a in rest if not a.startswith('-')]
    shared = shared_value(top) if sub in ('commit', 'checkout', 'restore', 'apply', 'am') else None

    if sub == 'config':
        writes = len(pos) >= 2 or any(a in ('--add', '--unset', '--unset-all', '--replace-all', '--rename-section',
                                            '--remove-section') for a in rest)
        if writes and pos and GIT_KEYS.match(pos[0]):
            refuse('this sets git config `%s`, which moves where pushes go or what runs on commit.' % pos[0])
    elif sub == 'remote' and pos and pos[0] in ('add', 'set-url', 'rename', 'set-head', 'set-branches', 'remove', 'rm'):
        refuse('this changes the git remote (`git remote %s`), which the shared value is read from.' % pos[0])
    elif sub == 'replace' or (sub in ('update-ref', 'symbolic-ref') and any(a.startswith('refs/remotes/') for a in pos)):
        refuse('this rewrites what a remote ref or object reads as (`git %s`).' % sub)
    elif sub == 'commit':
        vh = at('HEAD')
        judge(vh, at(''), cfg + ' (staged for commit)', shared)
        # The working tree too, always: `git add -A && git commit` stages it after this check runs.
        judge(vh, read(cfg), cfg + ' (in the working tree, which this commit can take)', shared)
    elif sub == 'push':
        judge_push(top, rest, cfg, rel)
    elif sub in ('checkout', 'restore'):
        if sub == 'checkout':
            if '--' in rest:
                k = rest.index('--')
                refs = [a for a in rest[:k] if not a.startswith('-')]
                paths, ref = rest[k + 1:], (refs[0] if refs else None)
            elif len(pos) >= 2 and any(covers(a, repo, top) for a in pos[1:]):
                ref, paths = pos[0], pos[1:]
            elif len(pos) == 1 and covers(pos[0], repo, top) and \
                    (pos[0] in ('.', ':/') or os.path.exists(expand(pos[0], repo)[0])):
                ref, paths = None, pos
            else:
                return  # a branch switch: history arrives committed, and only origin's value is honoured
            if not any(covers(p, repo, top) for p in paths):
                return
            after = at(ref) if ref else at('')
            judge(read(cfg), after, cfg + ' (git checkout %s)' % (ref or 'from the index'), shared)
        else:
            ref, staged, worktree = None, False, False
            for j, a in enumerate(rest):
                if a.startswith('--source='):
                    ref = a.split('=', 1)[1]
                elif a in ('-s', '--source') and j + 1 < len(rest):
                    ref = rest[j + 1]
                elif a.startswith('-s') and len(a) > 2:
                    ref = a[2:]
                elif a in ('-S', '--staged'):
                    staged = True
                elif a in ('-W', '--worktree'):
                    worktree = True
            paths = [a for j, a in enumerate(rest) if not a.startswith('-') and
                     not (j > 0 and rest[j - 1] in ('-s', '--source'))]
            if not any(covers(p, repo, top) for p in paths):
                return
            if staged:
                judge(at(''), at(ref or 'HEAD'), cfg + ' (git restore --staged)', shared)
            if worktree or not staged:
                src = ref or ('HEAD' if staged else None)
                judge(read(cfg), at(src) if src else at(''), cfg + ' (git restore)', shared)
    elif sub in ('apply', 'am'):
        if any(a in ('--continue', '--abort', '--skip', '--quit', '--show-current-patch', '--retry') for a in rest):
            return
        patches = [read(expand(p, repo)[0]) for p in pos] if pos and pos != ['-'] else [here]
        cached = any(a in ('--cached', '--index') for a in rest)
        for text in patches:
            if text is None:
                refuse('this applies a patch the guard cannot read (from a pipe, or a missing file), so it cannot see whether it touches harness.json.')
            if 'harness.json' not in text.lower():
                continue
            base = at('') if cached else read(cfg)
            judge(base, simulate_patch(base, text, rest), cfg + ' (git %s)' % sub, shared)


def judge_push(top, rest, cfg, rel):
    ref = anchor(top)
    if not ref:
        return  # no integration branch to compare with; the injector grants nothing either
    target = ref.split('/', 1)[1]
    at = lambda r: git(top, 'show', r + ':' + rel)
    heads = lambda: [(h, h[len('refs/heads/'):]) for h in
                     (git(top, 'for-each-ref', '--format=%(refname)', 'refs/heads') or '').split()]
    pos = [a for a in rest if not a.startswith('-')]
    if any(a in ('--all', '--mirror', '--branches') for a in rest):
        pairs = heads()
    else:
        specs = pos[1:]
        if not specs:
            # No refspec on the line: git uses the remote's configured push refspecs, then push.default.
            specs = (git(top, 'config', '--get-all', 'remote.%s.push' % (pos[0] if pos else 'origin')) or '').split()
            if not specs and (git(top, 'config', '--get', 'push.default') or '').strip() == 'matching':
                pairs = heads()
                specs = None
            elif not specs:
                cur = (git(top, 'symbolic-ref', '-q', '--short', 'HEAD') or 'HEAD').strip()
                specs = ['HEAD:' + cur]
        if specs is not None:
            pairs = []
            for sp in specs:
                src, _, dst = sp.lstrip('+').partition(':')
                if src:  # `:dst` deletes; it pushes no content
                    pairs.append((src, dst or src))
    shared = at(ref)
    for src, dst in pairs:
        if not git(top, 'rev-parse', '--verify', '-q', src + '^{commit}'):
            continue
        mine = value_of(at(src))
        dst = dst[len('refs/heads/'):] if dst.startswith('refs/heads/') else dst
        if allowed(value_of(shared), mine):
            continue
        if dst != target:
            # A branch that did not touch the key (it matches where it forked) is not changing it.
            mb = (git(top, 'merge-base', src, ref) or '').strip()
            if mb and allowed(value_of(at(mb)), mine):
                continue
        judge(shared, at(src), cfg + ' (pushed from %s to %s, against %s)' % (src, dst, ref))


def simulate_patch(base, text, opts):
    with tempfile.TemporaryDirectory() as d:
        os.makedirs(os.path.join(d, '.claude'))
        target = os.path.join(d, '.claude', 'harness.json')
        if base is not None:
            with open(target, 'w', encoding='utf-8', errors='surrogateescape') as fh:
                fh.write(base)
        pf = os.path.join(d, 'p.diff')
        with open(pf, 'w', encoding='utf-8', errors='surrogateescape') as fh:
            fh.write(text)
        extra = [o for o in opts if re.fullmatch(r'-p[0-9]+|-R|--reverse', o)]
        r = subprocess.run(['git', 'apply', '--include=*harness.json'] + extra + [pf],
                           cwd=d, capture_output=True, env=clean_env())
        if r.returncode != 0:
            refuse('this applies a patch to harness.json that the guard could not replay, so it cannot see the result.')
        return read(target)


def judge_copy(name, args, cwd):
    opts_with_value = {'-t', '--target-directory', '-S', '--suffix', '-m', '--mode', '-o', '--owner', '-g', '--group', '-e'}
    pos, tdir, i = [], None, 1
    while i < len(args):
        a = args[i]
        if a in ('-t', '--target-directory') and i + 1 < len(args):
            tdir = args[i + 1]
            i += 2
            continue
        if a.startswith('--target-directory='):
            tdir = a.split('=', 1)[1]
        elif a in opts_with_value:
            i += 2
            continue
        elif not a.startswith('-'):
            pos.append(a)
        i += 1
    if tdir is not None:
        srcs, dest = pos, tdir
    elif len(pos) >= 2:
        srcs, dest = pos[:-1], pos[-1]
    else:
        return
    dest_p = expand(dest, cwd)[0]
    into_dir = os.path.isdir(dest_p) or dest.endswith('/') or len(srcs) > 1 or tdir is not None
    for s in srcs:
        for sp in expand(s, cwd):
            target = os.path.join(dest_p, os.path.basename(sp.rstrip('/'))) if into_dir else dest_p
            if os.path.isdir(sp) or (not os.path.exists(sp) and s.endswith('/')):
                if (name == 'rsync' and s.endswith('/')) or name == 'ditto':
                    target = dest_p
                for relp in ('harness.json', os.path.join('.claude', 'harness.json')):
                    t = os.path.join(target, relp)
                    if is_cfg(t):
                        judge(read(t), read(os.path.join(sp, relp)), t)
                continue
            if is_cfg(target):
                if not os.path.exists(sp):
                    refuse('this puts %s over %s, and it does not exist yet, so the guard cannot see what will land.' % (s, target))
                judge(read(target), read(sp), target)


def main(raw):
    payload = json.loads(raw or '{}')
    tool = payload.get('tool_name') or ''
    ti = payload.get('tool_input') or {}
    if tool in ('Write', 'Edit', 'MultiEdit'):
        judge_file_tool(tool, ti)
    elif 'command' in ti:
        judge_bash(ti.get('command') or '', payload.get('cwd') or os.getcwd())


if __name__ == '__main__':
    raw = sys.stdin.read()
    try:
        main(raw)
    except SystemExit:
        raise
    except Exception as e:  # a guard that crashes on input naming the file refuses it
        sys.stderr.write('guard-pre-approved-writes: %s\n' % e)
        if 'harness.json' in raw.lower():
            refuse('the guard failed while judging input that names harness.json (%s).' % e)
    sys.exit(0)
