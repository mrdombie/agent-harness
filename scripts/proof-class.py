#!/usr/bin/env python3
"""proof-class.py — whether one commit is only docs, only comments, only wording or only tests.

  proof-class.py check --repo <tree> --commit <sha> --kind <kind> [--file <path>]
                       [--trunk <ref>] [--cfg <harness.json>]
                       [--test-file <path>] [--break-file <path>]
      exit 0 and one line saying why when the commit is that kind; exit 3 and why not.
  proof-class.py enabled --kind <kind> [--cfg <harness.json>]
      exit 0 when proof.autoAccept turns that kind on (the default for all four).

KINDS, each read off the commit's own diff, never off what the fixer says it did:
  docs-only     every file it touches matches the docs globs (md, mdx, markdown, txt, rst,
                plus proof.autoAccept.docsGlobs).
  comment-only  every file it touches is docs, or is code whose text with its comments
                taken out is the same before and after, line for line.
  wording-only  as comment-only, and string literals and JSX text are also masked, so only
                their contents may differ. A string in a code position (an import path, a
                comparison, an object key, a member access, a class name, a route, a tagged
                template) or one shaped like an identifier, a path or a number is compared
                as it is, never masked.
  test-only     every file it touches matches the test globs; --test-file must be one and
                --break-file must not be (the mutation is planted in code, not in a test).

A file the reader cannot read as code (a language it does not know, a binary, a mode
change, a merge commit) is a refusal with the reason: the fallback is a person, as before.

proof.autoAccept in harness.json: absent or true turns all four on; false turns all off;
an array names the kinds on; an object takes "kinds", "docsGlobs" and "testGlobs".
Test globs also take tests.patterns. A glob starting "!" excludes.
"""
import argparse
import json
import os
import re
import subprocess
import sys

KINDS = ("docs-only", "comment-only", "wording-only", "test-only")
DOCS_DEFAULT = ["**/*.md", "**/*.mdx", "**/*.markdown", "**/*.txt", "**/*.rst"]
TESTS_DEFAULT = ["**/*.test.*", "**/*.spec.*", "**/__tests__/**", "**/__mocks__/**"]


# ---------------------------------------------------------------- settings and globs

def load_cfg(path):
    if not path or not os.path.isfile(path):
        return {}
    try:
        with open(path, encoding="utf-8") as fh:
            return json.load(fh)
    except (OSError, ValueError):
        return {}


def auto_settings(cfg):
    raw = (cfg.get("proof") or {}).get("autoAccept", True) if isinstance(cfg.get("proof"), dict) else True
    kinds, docs, tests = list(KINDS), [], []
    if raw is False:
        kinds = []
    elif isinstance(raw, list):
        kinds = [k for k in raw if k in KINDS]
    elif isinstance(raw, dict):
        if raw.get("enabled") is False:
            kinds = []
        elif isinstance(raw.get("kinds"), list):
            kinds = [k for k in raw["kinds"] if k in KINDS]
        docs = [g for g in raw.get("docsGlobs") or [] if isinstance(g, str)]
        tests = [g for g in raw.get("testGlobs") or [] if isinstance(g, str)]
    pats = (cfg.get("tests") or {}).get("patterns") if isinstance(cfg.get("tests"), dict) else None
    if isinstance(pats, list):
        tests += ["**/" + p for p in pats if isinstance(p, str)]
    return kinds, DOCS_DEFAULT + docs, TESTS_DEFAULT + tests


def glob_re(g):
    out, i = "", 0
    while i < len(g):
        if g.startswith("**/", i):
            out += "(?:.*/)?"; i += 3
        elif g.startswith("**", i):
            out += ".*"; i += 2
        elif g[i] == "*":
            out += "[^/]*"; i += 1
        elif g[i] == "?":
            out += "[^/]"; i += 1
        else:
            out += re.escape(g[i]); i += 1
    return re.compile("^" + out + "$")


def matches(path, globs):
    hit = False
    for g in globs:
        neg = g.startswith("!")
        pat = g[1:] if neg else g
        target = path if "/" in pat else path.rsplit("/", 1)[-1]
        if glob_re(pat).match(target):
            if neg:
                return False
            hit = True
    return hit


# ---------------------------------------------------------------- git

def git(repo, *args):
    env = {k: v for k, v in os.environ.items() if not k.startswith("GIT_")}
    p = subprocess.run(["git", "-C", repo] + list(args), capture_output=True, env=env)
    return p.returncode, p.stdout


def commit_files(repo, sha):
    """[(old_mode, new_mode, status, path)] for a one-parent commit, or a reason string."""
    rc, out = git(repo, "rev-list", "--parents", "-n", "1", sha)
    if rc != 0:
        return "commit %s does not resolve" % sha[:10]
    parents = out.decode().split()[1:]
    if len(parents) != 1:
        return "commit %s has %d parents — only a one-parent commit can be read as one change" % (sha[:10], len(parents))
    rc, out = git(repo, "diff-tree", "-r", "--no-renames", "-z", "--raw", parents[0], sha)
    if rc != 0:
        return "the diff of %s could not be read" % sha[:10]
    parts = out.decode("utf-8", "replace").split("\0")
    files, i = [], 0
    while i + 1 < len(parts):
        meta, path = parts[i], parts[i + 1]
        i += 2
        if not meta.startswith(":"):
            continue
        m = meta[1:].split()
        files.append((m[0], m[1], m[4], path))
    return files, parents[0]


def blob(repo, sha, path):
    rc, out = git(repo, "cat-file", "blob", "%s:%s" % (sha, path))
    return out if rc == 0 else b""


# ---------------------------------------------------------------- languages

JS = {".js", ".jsx", ".mjs", ".cjs", ".ts", ".tsx", ".mts", ".cts"}
JSX = {".js", ".jsx", ".tsx"}
CLIKE = {".c", ".h", ".cc", ".cpp", ".hpp", ".go", ".java", ".kt", ".kts", ".swift", ".rs", ".cs", ".scala", ".dart"}
CSS = {".css"}
SCSS = {".scss", ".less"}
HASH = {".sh", ".bash", ".zsh", ".py", ".rb", ".toml", ".pl", ".r", ".tf", ".cfg", ".conf", ".ini", ".env"}
YAML = {".yml", ".yaml"}
SQL = {".sql"}
MARKUP = {".html", ".htm", ".xml", ".svg", ".vue", ".svelte"}
JSON_EXT = {".json"}
HASH_NAMES = {"Makefile", "Dockerfile", ".gitignore", ".dockerignore", ".npmrc", ".editorconfig"}
INDENTED = {".py", ".yml", ".yaml"}
WORDING_OK = JS | JSON_EXT | {".py"}


def lang_of(path):
    base = path.rsplit("/", 1)[-1]
    ext = os.path.splitext(base)[1].lower()
    if base in HASH_NAMES or base.startswith("Dockerfile"):
        return "hash", ext
    for name, group in (("js", JS), ("c", CLIKE), ("css", CSS), ("scss", SCSS), ("hash", HASH),
                        ("yaml", YAML), ("sql", SQL), ("markup", MARKUP), ("json", JSON_EXT)):
        if ext in group:
            return name, ext
    return None, ext


class Unreadable(Exception):
    pass


# Tokens: (kind, text, ctx). kind: ws, nl, code, str, tmpl, jsxtext, comment, regex.
IDENT = re.compile(r"[A-Za-z0-9_$\u0080-￿]+")
PUNCT_MULTI = ("===", "!==", "==", "!=", "=>", "${")
EXPR_KEYWORDS = {"return", "typeof", "case", "do", "else", "in", "of", "new", "delete", "void",
                 "throw", "instanceof", "yield", "await", "default", "export"}


class JsScanner:
    def __init__(self, src, jsx, python=False):
        self.s, self.i, self.jsx, self.py = src, 0, jsx, python
        self.toks = []

    def sig(self):
        for k, t, _ in reversed(self.toks):
            if k not in ("ws", "nl", "comment"):
                return k, t
        return None, None

    def expr_start(self):
        k, t = self.sig()
        if k is None:
            return True
        if k == "code":
            if IDENT.fullmatch(t):
                return t in EXPR_KEYWORDS
            return t not in (")", "]", "}")
        return False

    def emit(self, kind, text, ctx=None):
        self.toks.append((kind, text, ctx))

    def ws(self):
        m = re.compile(r"[ \t\r\f\v]*\n[ \t\r\f\v\n]*|[ \t\r\f\v]+").match(self.s, self.i)
        if m and m.end() > self.i:
            self.emit("nl" if "\n" in m.group() else "ws", m.group())
            self.i = m.end()
            return True
        return False

    def string(self, q):
        s, j = self.s, self.i + 1
        while j < len(s) and s[j] != q:
            if s[j] == "\\":
                j += 1
            elif s[j] == "\n":
                break
            j += 1
        self.emit("str", s[self.i:j + 1])
        self.i = j + 1

    def pystring(self):
        m = re.compile(r"([rRbBuUfF]{0,2})('''|\"\"\"|'|\")").match(self.s, self.i)
        pre, q = m.group(1), m.group(2)
        j = m.end()
        s = self.s
        while j < len(s):
            if s[j] == "\\" and "r" not in pre.lower():
                j += 2; continue
            if s.startswith(q, j):
                j += len(q); break
            if len(q) == 1 and s[j] == "\n":
                break
            j += 1
        text = s[self.i:j]
        self.emit("str", text, "f" if "f" in pre.lower() else None)
        self.i = j

    def template(self):
        s = self.s
        tagged = False
        k, t = self.sig()
        if k == "code" and (IDENT.fullmatch(t) or t in (")", "]")) and t not in EXPR_KEYWORDS:
            tagged = True
        j = self.i + 1
        start = self.i
        while j < len(s):
            if s[j] == "\\":
                j += 2; continue
            if s[j] == "`":
                self.emit("tmpl", s[start:j + 1], "tag" if tagged else None)
                self.i = j + 1
                return
            if s.startswith("${", j):
                self.emit("tmpl", s[start:j], "tag" if tagged else None)
                self.emit("code", "${")
                self.i = j + 2
                self.code(nested=True)
                if self.i >= len(s):
                    raise Unreadable("a template literal never closes")
                self.emit("code", "}")
                self.i += 1
                start = j = self.i
                continue
            j += 1
        raise Unreadable("a template literal never closes")

    def regex(self):
        s, j, cls = self.s, self.i + 1, False
        while j < len(s) and s[j] != "\n":
            c = s[j]
            if c == "\\":
                j += 2; continue
            if c == "[":
                cls = True
            elif c == "]":
                cls = False
            elif c == "/" and not cls:
                break
            j += 1
        if j >= len(s) or s[j] != "/":
            return False
        m = re.compile(r"[a-z]*").match(s, j + 1)
        self.emit("regex", s[self.i:m.end()])
        self.i = m.end()
        return True

    def jsx_element(self):
        """At '<'. Raises Unreadable on anything that is not JSX; the caller backtracks."""
        s = self.s
        self.emit("code", "<"); self.i += 1
        if s.startswith(">", self.i):
            self.emit("code", ">"); self.i += 1
            return self.jsx_children()
        m = re.compile(r"[A-Za-z][A-Za-z0-9_.:-]*").match(s, self.i)
        if not m:
            raise Unreadable("not jsx")
        self.emit("code", m.group()); self.i = m.end()
        attr = None
        while True:
            if self.i >= len(s):
                raise Unreadable("not jsx")
            if self.ws():
                continue
            if s.startswith("/>", self.i):
                self.emit("code", "/>"); self.i += 2
                return
            c = s[self.i]
            if c == ">":
                self.emit("code", ">"); self.i += 1
                return self.jsx_children()
            if c == "{":
                self.emit("code", "{"); self.i += 1
                self.code(nested=True)
                if self.i >= len(s):
                    raise Unreadable("not jsx")
                self.emit("code", "}"); self.i += 1
                continue
            if c == "=" and attr:
                self.emit("code", "="); self.i += 1
                while self.ws():
                    pass
                if self.i < len(s) and s[self.i] in "\"'":
                    q = s[self.i]
                    j = s.find(q, self.i + 1)
                    if j < 0:
                        raise Unreadable("not jsx")
                    self.emit("str", s[self.i:j + 1], "attr:" + attr)
                    self.i = j + 1
                attr = None
                continue
            m = re.compile(r"[A-Za-z_][A-Za-z0-9_:.-]*").match(s, self.i)
            if not m:
                raise Unreadable("not jsx")
            attr = m.group()
            self.emit("code", attr); self.i = m.end()

    def jsx_children(self):
        s = self.s
        while True:
            if self.i >= len(s):
                raise Unreadable("not jsx")
            j = self.i
            while j < len(s) and s[j] not in "<{":
                j += 1
            if j > self.i:
                self.emit("jsxtext", s[self.i:j]); self.i = j
                continue
            if s[self.i] == "{":
                self.emit("code", "{"); self.i += 1
                self.code(nested=True)
                if self.i >= len(s):
                    raise Unreadable("not jsx")
                self.emit("code", "}"); self.i += 1
                continue
            if s.startswith("</", self.i):
                m = re.compile(r"</\s*([A-Za-z][A-Za-z0-9_.:-]*)?\s*>").match(s, self.i)
                if not m:
                    raise Unreadable("not jsx")
                self.emit("code", "</"); self.emit("code", m.group(1) or ""); self.emit("code", ">")
                self.i = m.end()
                return
            self.jsx_element()

    def code(self, nested=False):
        s, depth = self.s, 0
        while self.i < len(s):
            if self.ws():
                continue
            c = s[self.i]
            if self.py:
                if c == "#":
                    j = s.find("\n", self.i)
                    j = len(s) if j < 0 else j
                    self.emit("comment", s[self.i:j]); self.i = j
                    continue
                if re.compile(r"[rRbBuUfF]{0,2}['\"]").match(s, self.i) and (
                        c in "'\"" or not IDENT.fullmatch(s[self.i - 1:self.i] or " ")):
                    self.pystring(); continue
            else:
                if s.startswith("//", self.i):
                    j = s.find("\n", self.i)
                    j = len(s) if j < 0 else j
                    self.emit("comment", s[self.i:j]); self.i = j
                    continue
                if s.startswith("/*", self.i):
                    j = s.find("*/", self.i + 2)
                    if j < 0:
                        raise Unreadable("a block comment never closes")
                    self.emit("comment", s[self.i:j + 2]); self.i = j + 2
                    continue
                if c in "'\"":
                    self.string(c); continue
                if c == "`":
                    self.template(); continue
                if c == "/" and self.expr_start() and self.regex():
                    continue
                if c == "<" and self.jsx and self.expr_start() and re.compile(r"<[A-Za-z>]").match(s, self.i):
                    save_i, save_n = self.i, len(self.toks)
                    try:
                        self.jsx_element()
                        continue
                    except Unreadable:
                        self.i = save_i
                        del self.toks[save_n:]
            m = IDENT.match(s, self.i)
            if m:
                self.emit("code", m.group()); self.i = m.end()
                continue
            if c == "{":
                depth += 1
            elif c == "}":
                if nested and depth == 0:
                    return
                depth -= 1
            for p in PUNCT_MULTI:
                if s.startswith(p, self.i) and p != "${":
                    self.emit("code", p); self.i += len(p)
                    break
            else:
                self.emit("code", c); self.i += 1


CHAR_LIT = re.compile(r"'(?:\\[^\n]{1,8}?|[^\\'\n])'")


def scan_simple(src, line_comments, block=None, quotes="'\"", hash_word=False, heredoc=False, yaml=False,
                chars=False):
    """Tokens for a language with line comments, an optional block comment and plain strings."""
    toks, i, s = [], 0, src
    wsre = re.compile(r"[ \t\r\f\v]*\n[ \t\r\f\v\n]*|[ \t\r\f\v]+")

    def prev_char():
        return s[i - 1] if i > 0 else "\n"

    while i < len(s):
        m = wsre.match(s, i)
        if m and m.end() > i:
            toks.append(("nl" if "\n" in m.group() else "ws", m.group(), None)); i = m.end(); continue
        if block and s.startswith(block[0], i):
            j = s.find(block[1], i + len(block[0]))
            if j < 0:
                raise Unreadable("a block comment never closes")
            toks.append(("comment", s[i:j + len(block[1])], None)); i = j + len(block[1]); continue
        hit = None
        for lc in line_comments:
            if s.startswith(lc, i) and (not hash_word or prev_char() in " \t\n;("):
                hit = lc; break
        if hit:
            j = s.find("\n", i); j = len(s) if j < 0 else j
            toks.append(("comment", s[i:j], None)); i = j; continue
        if heredoc:
            m = re.compile(r"<<-?\s*(['\"]?)([A-Za-z_][A-Za-z0-9_]*)\1").match(s, i)
            if m:
                end = re.compile(r"\n[ \t]*" + re.escape(m.group(2)) + r"[ \t]*(?=\n|$)").search(s, m.end())
                if not end:
                    raise Unreadable("a heredoc never closes")
                toks.append(("str", s[i:end.end()], None)); i = end.end(); continue
        c = s[i]
        if chars:
            m = CHAR_LIT.match(s, i)
            if m:
                toks.append(("str", m.group(), None)); i = m.end(); continue
        if c in quotes and (not yaml or re.compile(r"(^|[:\-\[,{]\s*|\n\s*)$").search(s[max(0, i - 40):i] or "\n")):
            j = i + 1
            while j < len(s) and s[j] != c:
                if s[j] == "\\" and c == '"':
                    j += 1
                j += 1
            toks.append(("str", s[i:j + 1], None)); i = j + 1; continue
        m = IDENT.match(s, i)
        if m:
            toks.append(("code", m.group(), None)); i = m.end(); continue
        toks.append(("code", c, None)); i += 1
    return toks


def tokens(path, text):
    lang, ext = lang_of(path)
    if lang == "js":
        sc = JsScanner(text, ext in JSX)
        sc.code()
        return sc.toks
    if ext == ".py":
        sc = JsScanner(text, False, python=True)
        sc.code()
        return sc.toks
    if lang == "c":
        return scan_simple(text, ["//"], ("/*", "*/"), quotes='"', chars=True)
    if lang == "css":
        return scan_simple(text, [], ("/*", "*/"))
    if lang == "scss":
        return scan_simple(text, ["//"], ("/*", "*/"))
    if lang == "hash":
        sh = ext in (".sh", ".bash", ".zsh") or path.rsplit("/", 1)[-1] in ("Makefile",)
        return scan_simple(text, ["#"], None, hash_word=True, heredoc=sh)
    if lang == "yaml":
        return scan_simple(text, ["#"], None, hash_word=True, yaml=True)
    if lang == "sql":
        return scan_simple(text, ["--"], ("/*", "*/"), quotes="'")
    if lang == "markup":
        return scan_simple(text, [], ("<!--", "-->"), quotes="")
    if lang == "json":
        return scan_simple(text, [], None, quotes='"')
    raise Unreadable("%s is in no language the reader knows" % path)


# ---------------------------------------------------------------- the canonical text

CODE_ATTRS = {"className", "class", "href", "src", "srcSet", "to", "id", "key", "type", "name", "role",
              "htmlFor", "for", "rel", "target", "method", "action", "style", "value", "variant",
              "size", "color", "as", "icon", "path", "url", "route", "pathname", "redirect",
              "redirectTo", "endpoint", "testId", "data-testid"}
COMPARE = {"===", "!==", "==", "!="}


def wording_shaped(content):
    """Prose a person reads, not a key: whitespace inside, or one Capitalised word."""
    if not re.search(r"[^\W\d_]", content):
        return False
    if re.search(r"\s", content):
        return True
    return bool(re.fullmatch(r"[A-Z][a-zà-ÿ']*[.!?:…]?", content))


def str_content(tok):
    k, t, _ = tok
    if k == "tmpl":
        t = t[1:] if t.startswith("`") else t
        t = t[:-1] if t.endswith("`") else t
        return t
    m = re.match(r"^[A-Za-z]{0,2}('''|\"\"\"|'|\")(.*)\1$", t, re.S)
    return m.group(2) if m else t


def code_position(toks, sig, pos):
    """True when the string at toks[sig[pos]] sits where its value is code, not prose."""
    k, t, ctx = toks[sig[pos]]
    if ctx == "tag" or ctx == "f":
        return True
    if ctx and ctx.startswith("attr:"):
        a = ctx[5:]
        return a in CODE_ATTRS or a.startswith("data-")
    p1 = toks[sig[pos - 1]][1] if pos >= 1 else None
    p2 = toks[sig[pos - 2]][1] if pos >= 2 else None
    n1 = toks[sig[pos + 1]][1] if pos + 1 < len(sig) else None
    if p1 in ("from", "import", "require", "case", "export", "|", "&") or n1 in ("|", "&", "in"):
        return True
    if p1 in COMPARE or n1 in COMPARE:
        return True
    if p1 == "(" and p2 in ("require", "import", "mock", "doMock", "resolve", "getElementById",
                            "querySelector", "querySelectorAll", "fetch", "push", "replace", "redirect"):
        return True
    if n1 == ":" and p1 in ("{", ","):
        return True
    if p1 == "[" and p2 is not None and (IDENT.fullmatch(p2) or p2 in (")", "]")):
        return True
    if p1 in (":", "=") and p2 is not None and p2 in CODE_ATTRS:
        return True
    return False


def canonical(path, text, mask):
    """Lines of the file with comments removed (and, when mask, prose literals masked)."""
    toks = tokens(path, text)
    lang, ext = lang_of(path)
    indented = ext in INDENTED
    sig = [j for j, tk in enumerate(toks) if tk[0] not in ("ws", "nl", "comment")]
    where = {j: n for n, j in enumerate(sig)}
    out = []

    def put(piece):
        if piece == " ":
            if out and (out[-1].endswith(" ") or out[-1].endswith("\n") or out[-1] == ""):
                return
        elif piece.startswith("\n") and out:
            out[-1] = out[-1].rstrip(" ")
        out.append(piece)

    for idx, tok in enumerate(toks):
        k, t, _ = tok
        if k == "comment":
            put("\n" if "\n" in t else " ")
        elif k == "nl":
            put("\n" + (t.rsplit("\n", 1)[-1] if indented else ""))
        elif k == "ws":
            put(" ")
        elif k == "jsxtext":
            if not t.strip():
                put(" ")
            elif mask:
                put(" "); put("\u27e8text\u27e9"); put(" ")
            else:
                put(" "); put(" ".join(t.split())); put(" ")
        elif k in ("str", "tmpl") and mask and not code_position(toks, sig, where[idx]) \
                and wording_shaped(str_content(tok)):
            put("\u27e8str\u27e9")
        else:
            put(t)
    lines = []
    for ln in "".join(out).split("\n"):
        ln = ln.rstrip() if indented else ln.strip()
        if ln.strip():
            lines.append(ln)
    return lines


# ---------------------------------------------------------------- the check

def check(a):
    cfg = load_cfg(a.cfg)
    kinds, docs, tests = auto_settings(cfg)
    if a.kind not in KINDS:
        return 3, 'kind "%s" is none of %s' % (a.kind, ", ".join(KINDS))
    if a.kind not in kinds:
        return 3, "proof.autoAccept is off for %s in this project, so only a PM answer can accept it" % a.kind
    got = commit_files(a.repo, a.commit)
    if isinstance(got, str):
        return 3, got
    files, parent = got
    short = a.commit[:10]
    if not files:
        return 3, "commit %s changes no file" % short
    paths = [f[3] for f in files]
    if a.file and a.file not in paths and not (a.kind == "test-only" and a.file == a.break_file):
        return 3, "commit %s does not touch %s, the file the finding names" % (short, a.file)
    if a.trunk:
        rc, _ = git(a.repo, "merge-base", "--is-ancestor", a.commit, a.trunk)
        if rc == 0:
            return 3, "commit %s is already on %s — it is not this change's" % (short, a.trunk)
    for om, nm, st, p in files:
        if om != "000000" and nm != "000000" and om != nm:
            return 3, "commit %s changes the mode of %s, which is not %s" % (short, p, a.kind)

    if a.kind == "docs-only":
        bad = [p for p in paths if not matches(p, docs)]
        if bad:
            return 3, "commit %s touches %s, which is not docs (docs globs: %s)" % (short, ", ".join(bad[:5]), ", ".join(docs))
        return 0, "commit %s touches only docs: %s" % (short, ", ".join(paths[:8]))

    if a.kind == "test-only":
        bad = [p for p in paths if not matches(p, tests)]
        if bad:
            return 3, "commit %s touches %s, which is not a test file (test globs: %s)" % (short, ", ".join(bad[:5]), ", ".join(tests))
        if not a.test_file or not matches(a.test_file, tests):
            return 3, "the named test %s is not a test file" % (a.test_file or "(none)")
        if not a.break_file:
            return 3, "the mutation names no file to break"
        if matches(a.break_file, tests) or a.break_file == a.test_file:
            return 3, "the mutation is planted in %s, a test file — it has to break the code the test pins" % a.break_file
        return 0, "commit %s touches only tests: %s" % (short, ", ".join(paths[:8]))

    mask = a.kind == "wording-only"
    code_files = 0
    for om, nm, st, p in files:
        if matches(p, docs):
            continue
        lang, ext = lang_of(p)
        if lang is None:
            return 3, "%s is in no language the reader knows, so a %s claim cannot be checked on it" % (p, a.kind)
        if mask and ext not in WORDING_OK:
            return 3, "wording-only is read for js/ts/jsx/tsx, json and python only — %s is not one" % p
        old = blob(a.repo, parent, p) if om != "000000" else b""
        new = blob(a.repo, a.commit, p) if nm != "000000" else b""
        if b"\0" in old or b"\0" in new:
            return 3, "%s is binary" % p
        try:
            co = canonical(p, old.decode("utf-8"), mask)
            cn = canonical(p, new.decode("utf-8"), mask)
        except (Unreadable, UnicodeDecodeError) as e:
            return 3, "%s could not be read as code (%s)" % (p, e)
        if co != cn:
            n = 0
            while n < min(len(co), len(cn)) and co[n] == cn[n]:
                n += 1
            was = co[n] if n < len(co) else "(nothing)"
            now = cn[n] if n < len(cn) else "(nothing)"
            what = "outside comments and prose literals" if mask else "outside comments"
            return 3, "commit %s changes code in %s %s: `%s` became `%s`" % (short, p, what, was[:120], now[:120])
        code_files += 1
    what = "prose literals and comments" if mask else "comments"
    return 0, "commit %s changes only %s: %d code file(s) read with them taken out are the same before and after" % (short, what, code_files)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("cmd", choices=("check", "enabled"))
    ap.add_argument("--repo", default=".")
    ap.add_argument("--commit")
    ap.add_argument("--kind", required=True)
    ap.add_argument("--file")
    ap.add_argument("--trunk")
    ap.add_argument("--cfg", default=os.environ.get("HARNESS_CFG", ""))
    ap.add_argument("--test-file", dest="test_file")
    ap.add_argument("--break-file", dest="break_file")
    a = ap.parse_args()
    if a.cmd == "enabled":
        kinds, _, _ = auto_settings(load_cfg(a.cfg))
        return 0 if a.kind in kinds else 1
    if not a.commit:
        print("names no commit"); return 3
    rc, why = check(a)
    print(why)
    return rc


if __name__ == "__main__":
    sys.exit(main())
