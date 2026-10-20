import fnmatch, glob, hashlib, itertools, json, os, re, shlex, subprocess, sys, tempfile

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
#
# Not the project's file: a fixture's stand-in under a sandbox variable, where every
# value the variable can hold is provably a temp dir (see "Sandbox paths" below).

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
GITPROT_TXT = re.compile(r'\.git/(config|refs|hooks|packed-refs)|\.gitconfig|\.config/git/config', re.I)
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
TOPS = set()  # work trees this call can reach: the project's config is <top>/.claude/harness.json
RES = []  # one Resolver per shell text being judged, innermost last


def is_cfg(path):
    if RES and RES[-1] is not None and path in RES[-1].paths:
        # A sandbox path the Resolver proved cannot be the project's config. Skipping the inode
        # check below is safe: expand() only records paths that do not exist, so none is a hard link.
        return False
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
        return parts[-1] in ('config', 'packed-refs') or 'hooks' in parts[k:] or 'refs' in parts[k:]
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
        TOPS.add(base)
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
            if text[i + 1] != '\n':  # a line continuation is removed, as the shell removes it
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


# ---- Sandbox paths (#169) -----------------------------------------------------------
# A test fixture writes a stand-in config under a sandbox variable:
#   SB="${TMPDIR:-/tmp}"; SB="${SB%/}/fx-$$"; UP="$SB/up"; cat > "$UP/.claude/harness.json"
# The judge sees `$UP` unexpanded, so by name alone that is the project's config. A path
# whose variable can be the repo is still judged exactly as before. It is let through
# only when every value the variable can hold at that point, from the literal assignments
# in the same text, is a sandbox: under $TMPDIR (whatever it holds), a new mktemp dir, or
# a literal temp root, and matching neither the project's config nor any work tree of it.
# Anything the Resolver cannot pin down (a variable from the environment, `$(pwd)`, a
# conditional first assignment, eval, a link made in the same text, an unquoted use)
# leaves the path judged as before.

DQ, UQ = '\x04', '\x02'  # a `$` the shell expands, inside double quotes / unquoted
ANY, FRESH, WILD = '\x05', '\x03', '\x06'  # $TMPDIR (any value) / a new mktemp dir / any text
SANDBOX_ROOTS = ('/tmp/', '/var/tmp/', '/private/tmp/', '/var/folders/', '/private/var/folders/')
ASSIGN = re.compile(r'([A-Za-z_][A-Za-z0-9_]*)=(.*)', re.S)
REF = re.compile(r'[\x02\x04](?:\{(?P<b>[A-Za-z_][A-Za-z0-9_]*|[\x02\x04])(?P<op>%%?/|:?-[^}\x02\x04]*)?\}|'
                 r'(?P<n>[A-Za-z_][A-Za-z0-9_]*|[\x02\x04])|\((?P<sub>[^()`;|&]*)\))')
REFNAMES = re.compile(r'[\x02\x04]\{?[#!]?([A-Za-z_][A-Za-z0-9_]*)')
SETREF = re.compile(r'[\x02\x04]\{([A-Za-z_][A-Za-z0-9_]*):?[=?]')
BARE = re.compile(r'(?<![\x02\x04{A-Za-z0-9_])([A-Za-z_][A-Za-z0-9_]*)(?![A-Za-z0-9_])')
LINKS = re.compile(r'\bln\b|symlink|\bmount\b|bindfs|--link|--symbolic|\bcp\b[^\n;&|]*\s-[A-Za-z]*[ls]\b')
NAMEREF = re.compile(r'\b(declare|typeset|local)\s+-[A-Za-z]*n')
DYN_CMDS = {'eval', 'source', '.', 'trap'}
VAR_CMDS = {'declare', 'typeset', 'local', 'export', 'readonly', 'read', 'mapfile', 'readarray', 'getopts',
            'let', 'unset'}
SPECIAL = {'RANDOM', 'SRANDOM', 'BASHPID'}
COPIERS = {'cp', 'gcp', 'mv', 'gmv', 'rsync', 'ditto', 'install'}
PREFIXES = {'sudo', 'command', 'exec', 'time', 'nohup', 'env', 'builtin', 'xargs', 'nice'}
ARCHIVERS = {'tar', 'gtar', 'bsdtar', 'cpio', 'pax', 'unzip', '7z', 'ar'}
MKTEMP_SHADOW = re.compile(r'\bmktemp\s*\(|\bfunction\s+mktemp\b|\balias\b|\bhash\b|\benable\b|\bPATH\+?=')
MAX_ALTS = 64
MAX_WILD = 4  # unknown parts in one sandbox path: the fixtures use three
_PROTECTED = {}


def mark_vars(code):
    """The text with each `$` the shell expands marked DQ (in double quotes) or UQ. Same token boundaries."""
    out, q, i, n = [], None, 0, len(code)
    while i < n:
        c = code[i]
        if q == "'":
            out.append(c)
            q = None if c == "'" else q
            i += 1
            continue
        if c == '\\' and i + 1 < n:
            out.append(code[i:i + 2])
            i += 2
            continue
        if c == '$':
            out.append(DQ if q == '"' else UQ)
        elif q == '"':
            out.append(c)
            q = None if c == '"' else q
        else:
            q = c if c in '\'"' else None
            out.append(c)
        i += 1
    return ''.join(out)


def protected():
    """The project's config in every work tree this call can reach, as written and resolved."""
    tops = set(TOPS)
    try:
        here = os.getcwd()
    except OSError:  # the cwd was deleted: the tops this call learned still count
        here = None
    for d in filter(None, (os.environ.get('CLAUDE_PROJECT_DIR'), here and toplevel(here))):
        tops.add(d)
    key = frozenset(tops)
    if key not in _PROTECTED:
        all_tops = set(tops)
        for t in tops:
            for line in (git(t, 'worktree', 'list', '--porcelain') or '').splitlines():
                if line.startswith('worktree '):
                    all_tops.add(line[9:])
        cfgs = set()
        for t in all_tops:
            c = os.path.join(t, '.claude', 'harness.json')
            cfgs.update({os.path.abspath(c), os.path.realpath(c)})
        _PROTECTED[key] = cfgs
    return _PROTECTED[key]


class Resolver:
    """Every value a variable can hold where a path names it, from the literal assignments
    in one shell text. What it cannot pin down is None, and the path is judged as before."""

    def __init__(self, code, toks):
        self.paths, self.ok = set(), False
        if any(c in code for c in (DQ, UQ, ANY, FRESH, WILD)):
            return  # the input carries the marker bytes themselves: they would be misread
        try:
            mt = tokens(mark_vars(code))
        except ValueError:
            return
        if len(mt) != len(toks) or LINKS.search(code) or NAMEREF.search(code):
            return
        self.mt, self.toks, self.at = mt, toks, {}
        for i, t in enumerate(toks):
            self.at.setdefault(t, []).append(i)
        self.nest = self.nesting()
        if self.nest is None:
            return
        self.assigns, self.first_ok, self.taint, self.refs, self.setters = {}, set(), set(), {}, []
        self.dyn, self.copiers, self.archive, self._copies = len(mt), [], False, None
        # mktemp is a new dir only if it is the real mktemp: not a function, alias or PATH lookup the text changes.
        self.fresh_ok = not MKTEMP_SHADOW.search(code)
        for seg in self.segments():
            self.read_segment(*seg)
        self.read_words()
        self.settle()
        self.ok = True

    def nesting(self):
        """The loop, function, group, subshell, if or case frames around each token; None if unbalanced."""
        nest, stack, cmdpos, func_next, prev = [], [], True, False, ''
        for t in self.mt:
            nest.append(tuple(stack))
            if is_sep(t):
                for c in t:
                    if c == '(':
                        stack.append('func' if t.startswith('(') and prev == '()' else 'sub')
                    elif c == ')' and stack and stack[-1] in ('sub', 'func'):
                        stack.pop()
                    elif c == ')' and not (stack and stack[-1] == 'case'):
                        return None
                cmdpos = True
                prev = t.replace(' ', '').replace('\n', '')
                continue
            if t == '{' and func_next:  # `function f {`: the name took the command position
                stack.append('func')
                func_next, cmdpos, prev = False, True, t
                continue
            if cmdpos:
                if t in ('if', 'case', 'for', 'while', 'until', 'select', '{'):
                    stack.append({'if': 'if', 'case': 'case', '{': 'func' if prev == '()' or func_next else 'group'}.get(t, 'loop'))
                    func_next = False
                elif t in ('fi', 'esac', 'done', '}'):
                    want = {'fi': ('if',), 'esac': ('case',), 'done': ('loop',), '}': ('func', 'group')}[t]
                    if not stack or stack[-1] not in want:
                        return None
                    stack.pop()
                elif t == 'function':
                    func_next = True
                cmdpos = t in SHELL_WORDS or t in ('then', 'do', 'else', 'elif', 'in') or bool(ASSIGN.fullmatch(t))
            prev = t
        return None if stack else nest

    def segments(self):
        """(start, end, separator before, separator after) for each simple command."""
        segs, cur, before = [], None, ''
        for i, t in enumerate(self.mt):
            if is_sep(t):
                if cur is not None:
                    segs.append((cur, i, before, t))
                    cur = None
                before = t
            elif cur is None:
                cur = i
        if cur is not None:
            segs.append((cur, len(self.mt), before, ''))
        return segs

    def read_segment(self, start, end, sep_b, sep_a):
        """One command: its assignments, copies, archives, and what can set variables at run time."""
        mt = self.mt
        plain = lambda s: not any(c in '&|' for c in s)  # not one side of && || | or & (nesting is checked apart)
        words = list(range(start, end))
        while words and mt[words[0]] in SHELL_WORDS | {'then', 'do', 'else', 'elif', 'function'}:
            if mt[words[0]] == 'function':
                words = words[1:]  # and its name
            words = words[1:]
        only_assigns, cmd = True, None
        for i in words:
            m = ASSIGN.fullmatch(mt[i])
            if m and (cmd is None or cmd in ('export', 'readonly', 'local', 'declare', 'typeset')):
                continue
            if cmd is None:
                cmd = mt[i]
                only_assigns = cmd in ('export', 'readonly')
            elif mt[i].startswith('-'):
                only_assigns = False
        run = [i for i in words if not ASSIGN.fullmatch(mt[i])]
        while run and mt[run[0]] in PREFIXES:
            run = run[1:]
        if run and os.path.basename(mt[run[0]]) in COPIERS:
            self.copiers.append((os.path.basename(mt[run[0]]), run[1:]))
        if any(os.path.basename(mt[i]) in ARCHIVERS or INTERPRETERS.match(os.path.basename(mt[i])) for i in run[:1]) \
                or (run and mt[run[0]] == 'git' and any(mt[i] in ('clone', 'worktree', 'archive', 'bundle') for i in run)):
            self.archive = True  # unpacks or copies a tree, links and all, the copy judge cannot see
        if run and mt[run[0]] == '.':
            self.dyn = min(self.dyn, run[0])  # `builtin .`, `command .`: a sourced file sets anything
        if cmd in DYN_CMDS and not (cmd == 'trap' and not any(DQ in mt[i] or UQ in mt[i] for i in words)):
            # A literal trap action is text the scans below already read; one built at run time is not.
            self.dyn = min(self.dyn, start)
        elif (cmd in VAR_CMDS and any((DQ in mt[i] or UQ in mt[i]) and not ASSIGN.fullmatch(mt[i]) for i in words)) or \
                (cmd == 'printf' and any(mt[i] == '-v' for i in words)):
            # Sets or clears a variable it names at run time. Before every assignment a
            # path relies on, and outside a function, it cannot reach that path's value.
            self.setters.append(words[0])  # the command itself: a leading `{` sits outside the frame it opens
        for i in words:
            m = ASSIGN.fullmatch(mt[i])
            if not m:
                continue
            name, val, after = m.group(1), m.group(2), sep_a
            if val.endswith(UQ) and i + 1 < len(mt) and mt[i + 1].startswith('('):
                val, after = self.substitution(i, val)
            self.assigns.setdefault(name, []).append((i, val))
            if name not in self.first_ok and len(self.assigns[name]) == 1 and only_assigns and \
                    not self.nest[i] and plain(sep_b) and after is not None and plain(after):
                self.first_ok.add(name)

    def read_words(self):
        """Every word, wherever it stands: references, bare names, and the dynamic commands a walk missed."""
        mt = self.mt
        for i, t in enumerate(mt):
            if t in ('eval', 'source'):
                self.dyn = min(self.dyn, i)
            elif t in VAR_CMDS or t in ('printf', 'trap'):
                rest = []
                for u in mt[i + 1:]:
                    if is_sep(u):
                        break
                    rest.append(u)
                if any((DQ in u or UQ in u) and not ASSIGN.fullmatch(u) for u in rest) and (t != 'printf' or '-v' in rest):
                    if t == 'trap':
                        self.dyn = min(self.dyn, i)
                    else:
                        self.setters.append(i)
            for name in REFNAMES.findall(t):
                self.refs.setdefault(name, []).append(i)
            self.taint.update(SETREF.findall(t))
            m = ASSIGN.fullmatch(t)
            self.taint.update(BARE.findall(t[len(m.group(1)) + 1:] if m else t))

    def settle(self):
        for name, a in self.assigns.items():
            if any(r <= a[0][0] for r in self.refs.get(name, [])):
                self.first_ok.discard(name)  # read before it is first assigned: the environment's value
        self.fresh_ok = self.fresh_ok and 'PATH' not in self.assigns

    def copies_safe(self):
        """A fixture config can be written and then copied out of its sandbox, where the copy
        cannot see a tree that does not exist yet. So every copy in the text must land in a
        sandbox, or copy only files the copy judge can read; and no archive is unpacked."""
        if self._copies is None:
            self._copies = not self.archive and all(self.copy_ok(c, ws) for c, ws in self.copiers)
        return self._copies

    def copy_ok(self, cmd, ws):
        mt, dest, pos, k = self.mt, None, [], 0
        while k < len(ws):
            t = mt[ws[k]]
            if t in ('-t', '--target-directory') and k + 1 < len(ws):
                dest = ws[k + 1]
                k += 2
                continue
            if t.startswith('--target-directory='):
                return False
            if not t.startswith('-') and not ASSIGN.fullmatch(t):
                pos.append(ws[k])
            k += 1
        if dest is None:
            if len(pos) < 2:
                return True
            dest, pos = pos[-1], pos[:-1]
        if self.word_ok(dest):
            return True
        recursive = any(re.fullmatch(r'-[A-Za-z]*[rRa][A-Za-z]*|--recursive|--archive', mt[i]) for i in ws)
        for i in pos:
            src = self.toks[i]
            if DQ in mt[i] or UQ in mt[i] or mt[dest].count(DQ) or mt[dest].count(UQ):
                return False
            if not (os.path.isabs(src) and os.path.isfile(src)) and (recursive or cmd not in ('cp', 'gcp', 'install')):
                return False
        return True

    def substitution(self, i, val):
        """An unquoted `V=$(...)`: the value, and the separator after its `)` (None: a word follows)."""
        depth, mt = 0, self.mt
        for j in range(i + 1, len(mt)):
            t = mt[j]
            if not is_sep(t):
                continue
            for k, c in enumerate(t):
                depth += (c == '(') - (c == ')')
                if depth == 0:
                    inner = (' '.join(mt[i + 1:j]) + ' ' + t[:k])[1:].strip()  # less the opening `(`
                    rest = t[k + 1:]
                    if rest.strip(' '):
                        after = rest
                    elif j + 1 == len(mt):
                        after = ''
                    else:
                        after = mt[j + 1] if is_sep(mt[j + 1]) else None  # `$(...)/x`: a word follows
                    return (val + '(' + inner + ')' if after is not None else None), after
        return None, None

    def values(self, name, pos, seen):
        """(every value `name` can hold read at token pos, the assigned variables it rests on) or None."""
        if name == 'TMPDIR':
            return [ANY], set()
        if name in SPECIAL:
            return [WILD], set()
        if name in self.taint or name in seen or name not in self.first_ok:
            return None
        a, used = self.assigns[name], {name}
        if pos <= a[0][0]:
            return None
        top = not self.nest[pos]
        base, tails = [], []
        for i, v in a:
            if top and i >= pos:
                continue  # runs after this point: a top-level line is never re-entered
            r = self.parse(v, i, seen | {name}, name)
            if r is None:
                return None
            alts, selfref, strip, u = r
            used |= u
            if selfref:
                if any(not s.startswith('/') for s in alts):
                    return None
                tails.append((alts, strip))
            else:
                base.extend(alts)
        out = list(base)
        for alts, strip in tails:
            out.extend((b[:-1] if strip and b.endswith('/') else b) + WILD + s for b in base for s in alts)
        return (out, used) if base and len(out) <= MAX_ALTS else None

    def parse(self, s, idx, seen, selfname=None):
        """(alternatives, starts with the variable itself, its `%/` strip, variables used) or None."""
        if s is None or any(c in s for c in '`\\$') or s.startswith('~'):
            return None
        parts, i, selfref, strip, used = [], 0, False, False, set()
        while i < len(s):
            js = [k for k in (s.find(UQ, i), s.find(DQ, i)) if k >= 0]
            if not js:
                parts.append([s[i:]])
                break
            j = min(js)
            if j > i:
                parts.append([s[i:j]])
            m = REF.match(s, j)
            if not m:
                return None
            i = m.end()
            name, op, sub = m.group('b') or m.group('n'), m.group('op') or '', m.group('sub')
            if sub is not None:
                if not self.fresh_ok or not re.match(r'\s*mktemp(\s|$)', sub) or re.search(r'(^|\s)(-[A-Za-z]*u|--dry-run)', sub):
                    return None
                parts.append([FRESH])
                continue
            if name in (UQ, DQ):
                parts.append([WILD])
                continue
            if name == selfname:
                if parts or op not in ('', '%/', '%%/'):
                    return None
                selfref, strip = True, bool(op)
                continue
            r = self.values(name, idx, seen)
            if r is None:
                return None
            vals, u = r
            used |= u
            if op in ('%/', '%%/'):
                vals = [v.rstrip('/') if op == '%%/' else (v[:-1] if v.endswith('/') else v) for v in vals]
            elif op:
                vals = vals + [op.split('-', 1)[1]]
            parts.append(vals)
        alts = ['']
        for p in parts:
            alts = [a + b for a in alts for b in p]
            if len(alts) > MAX_ALTS:
                return None
        return alts, selfref, strip, used

    def sandbox(self, p):
        if '..' in p.split('/'):
            return False
        if FRESH in p:
            return all(p[k + 1:k + 2] in ('', '/') for k in range(len(p)) if p[k] == FRESH)
        if p.count(ANY) + p.count(WILD) > MAX_WILD:
            return False  # more unknowns than the link check below can walk
        if not (p.startswith(ANY) or any(p.startswith(r) or p.startswith(r[:-1] + WILD) for r in SANDBOX_ROOTS)):
            return False
        pat = ''.join('*' if c in (ANY, WILD) else glob.escape(c) for c in p).lower()
        cfgs = protected()
        if any(fnmatch.fnmatchcase(c.lower(), pat) for c in cfgs):
            return False
        real = {os.path.realpath(c).lower() for c in cfgs}
        # An existing path that links into the repo: judged by where it resolves.
        for d in filter(None, {os.environ.get('TMPDIR'), '/tmp', tempfile.gettempdir()}):
            g = ''.join(glob.escape(d.rstrip('/')) if c == ANY else '*' if c == WILD else glob.escape(c) for c in p)
            for hit in itertools.islice(glob.iglob(g), 256):
                try:
                    st = os.stat(hit)
                except OSError:
                    st = None
                if os.path.realpath(hit).lower() in real or (st and (st.st_dev, st.st_ino) in KNOWN):
                    return False
        return True

    def exempt(self, tok):
        if not self.ok or any(c in tok for c in '*?[') or not self.at.get(tok) or not self.copies_safe():
            return False
        return all(self.word_ok(i) for i in self.at[tok])

    def word_ok(self, i):
        """True when the word at token i is a path every value of which is a sandbox."""
        m = self.mt[i]
        if UQ in m or DQ not in m:
            return False  # no variable, or an unquoted one the shell splits and globs
        if self.dyn < len(self.mt) and (self.dyn < i or self.nest[i]):
            return False  # eval or source can run before this and set anything
        r = self.parse(m, i, frozenset())
        if r is None or not all(self.sandbox(p) for p in r[0]):
            return False
        first = min([self.assigns[v][0][0] for v in r[3]] or [len(self.mt)])
        # Harmless only in top-level flow that runs once, in place: anything else may be a function called later.
        return not any(s >= first or not set(self.nest[s]) <= {'loop', 'if'} for s in self.setters)


def sandboxed(tok):
    """True when this shell word is a path the Resolver proved cannot be the project's config.
    Any failure inside the proof is False: the path is judged as it was before the proof existed."""
    try:
        return bool(RES) and RES[-1] is not None and RES[-1].exempt(tok)
    except Exception:
        return False


def expand(tok, cwd):
    p = os.path.expanduser(tok)
    p = p if os.path.isabs(p) else os.path.join(cwd, p)
    out = (glob.glob(p) or [p]) if any(c in tok for c in '*?[') else [p]
    if sandboxed(tok):
        if not any(os.path.lexists(x) for x in out):
            RES[-1].paths.update(out)
    return out


def names_cfg(toks, cwd):
    for t in toks:
        if sandboxed(t):
            continue
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
    if depth == 0:
        TOPS.add(cwd)
    try:
        res = Resolver(code, toks)
    except Exception:
        res = None  # a proof that crashed proves nothing: the judgement without it stands
    RES.append(res)
    try:
        judge_segments(toks, bodies, cwd, depth)
    finally:
        RES.pop()


def judge_segments(toks, bodies, cwd, depth):
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
            if any('harness.json' in a.lower() and not is_cfg(expand(a, cwd)[0]) and not sandboxed(a)
                   for a in args[1:]):
                refuse('this %s script names harness.json, and the guard cannot see what it writes there.' % name)
            continue
        if name not in READERS and any(is_gitprot(p) for a in args[1:] if not a.startswith('-') for p in expand(a, cwd)):
            refuse('`%s` names git\'s own config, refs or hooks, and the guard cannot see what it does to them.' % name)
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
        if ('harness.json' in t.lower() or GITPROT_TXT.search(t)) and WRITE_MARK.search(t):
            refuse('this runs a script that names harness.json or git\'s own config, refs or hooks, and writes files; '
                   'the guard cannot see what it writes.')


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
        if git(repo, 'rev-parse', '--git-dir') is None:
            return
        top = repo  # inside .git: no work tree, but config, remotes and refs are all here
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
        reads = (pos and pos[0] in ('get', 'list')) or any(
            a.split('=', 1)[0] in ('--get', '--get-all', '--get-regexp', '--get-urlmatch', '--get-color',
                                   '--get-colorbool', '-l', '--list') for a in rest)
        if any(a in ('-e', '--edit') for a in rest) or (pos and pos[0] == 'edit'):
            refuse('this opens git config in an editor, where the guard cannot see what changes.')
        if not reads:
            # Every positional: `config set <key>`, `config --file <f> <key>` and the bare form all name the key somewhere.
            hit = [a for a in rest if GIT_KEYS.match(a.split('=', 1)[0])]
            if hit:
                refuse('this sets git config `%s`, which moves where pushes go or what runs on commit.' % hit[0])
    elif sub == 'remote' and pos and pos[0] in ('add', 'set-url', 'rename', 'set-head', 'set-branches', 'remove', 'rm'):
        refuse('this changes the git remote (`git remote %s`), which the shared value is read from.' % pos[0])
    elif sub == 'replace' or (sub in ('update-ref', 'symbolic-ref') and any(a.startswith('refs/remotes/') for a in pos)) \
            or (sub == 'update-ref' and '--stdin' in rest and (here is None or 'refs/remotes/' in here)):
        refuse('this rewrites what a remote ref or object reads as (`git %s`).' % sub)
    elif sub == 'fetch' and pos and not git(top, 'config', '--get', 'remote.%s.url' % pos[0]) and \
            any(':' in a and 'refs/remotes/' in a.split(':', 1)[1] for a in pos[1:]):
        refuse('this fetches into a remote-tracking ref from somewhere other than that remote.')
    elif sub == 'update-index' and (any(a in ('--cacheinfo', '--index-info', '--stdin') for a in rest) and
                                    (names_cfg(rest, repo) or here is None or 'harness.json' in (here or ''))):
        refuse('this writes harness.json into the index directly (`git update-index`), where the guard cannot see the value.')
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


def remote_head(top, what):
    """(sha, branch) the REMOTE reports for HEAD or refs/heads/<b>, within 4 s; local refs can be forged."""
    try:
        r = subprocess.run(['git', '--no-replace-objects', '-C', top, 'ls-remote', '--symref', 'origin', what],
                           capture_output=True, timeout=4,
                           env=dict(clean_env(), GIT_TERMINAL_PROMPT='0',
                                    GIT_SSH_COMMAND=os.environ.get('GIT_SSH_COMMAND') or 'ssh -o BatchMode=yes -o ConnectTimeout=4'))
    except Exception:
        return None, None
    sha, br = None, None
    for line in r.stdout.decode('utf-8', 'replace').splitlines():
        f = line.split()
        if len(f) >= 3 and f[0] == 'ref:':
            br = f[1][len('refs/heads/'):] if f[1].startswith('refs/heads/') else f[1]
        elif len(f) >= 2 and f[1] == what:
            sha = f[0]
    if sha and not br:
        br = what[len('refs/heads/'):] if what.startswith('refs/heads/') else what
    return sha, br


def have(top, sha):
    """True when sha is local, fetching it (into FETCH_HEAD only, no ref) when it is not."""
    if git(top, 'cat-file', '-e', sha + '^{commit}') is not None:
        return True
    try:
        subprocess.run(['git', '-C', top, 'fetch', '-q', '--no-write-fetch-head', 'origin', sha], capture_output=True,
                       timeout=8, env=dict(clean_env(), GIT_TERMINAL_PROMPT='0'))
    except Exception:
        pass
    return git(top, 'cat-file', '-e', sha + '^{commit}') is not None


def judge_push(top, rest, cfg, rel):
    sha, default = remote_head(top, 'HEAD')
    if not sha:
        return  # no remote to read; the injector grants nothing either
    at = lambda r: git(top, 'show', r + ':' + rel)
    if not have(top, sha):
        refuse('the remote\'s default branch is at a commit this clone has not fetched, so the guard cannot read the '
               'shared value to judge this push. Run `git fetch origin` first.')
    ref, target = sha, default
    try:
        ib = json.loads(at(sha) or '{}').get('integrationBranch')
    except Exception:
        ib = None
    if isinstance(ib, str) and ib and ib != default:
        isha, _ = remote_head(top, 'refs/heads/' + ib)
        if isha:
            if not have(top, isha):
                refuse('the remote\'s %s is at a commit this clone has not fetched. Run `git fetch origin` first.' % ib)
            ref, target = isha, ib
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
        if any(c in src for c in '$`*') or not git(top, 'rev-parse', '--verify', '-q', src + '^{commit}'):
            refuse('this pushes `%s`, which the guard cannot resolve to a commit before the shell runs, so it cannot '
                   'judge what lands on the remote. Push a named branch.' % src)
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
