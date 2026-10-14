"""Judge for pr-body-matches-branch.sh: a PR body must close the ticket its branch names.

Reads the PreToolUse payload on stdin. Prints a deny decision, or nothing to allow.

Parallel agents wrote their PR bodies to one shared scratch file. When a hook
refused a command that wrote the file and opened the PR together, the agent
re-ran only `gh pr create --body-file`, which published whatever another agent
had left there: three PRs went up carrying a fourth PR's description and its
`Closes #`. So a body for one ticket must never reach another ticket's PR.
"""
import json
import os
import re
import shlex
import subprocess
import sys

PR_CMD = re.compile(r"(?:^|[;&|(\n`]|\bthen|\bdo)[ \t]*gh[ \t]+pr[ \t]+(create|edit)\b")
CLOSE_REF = re.compile(
    r"\b(?:close[sd]?|fix(?:e[sd])?|resolve[sd]?)(?:\s+ticket)?:?\s+"
    r"(?:https://github\.com/([\w.-]+/[\w.-]+)/issues/|([\w.-]+/[\w.-]+)?#)(\d+)",
    re.I,
)
HEREDOC = re.compile(r"""<<-?[ \t]*(?:"([^"]+)"|'([^']+)'|([A-Za-z_][A-Za-z0-9_]*))""")
ASSIGN = re.compile(r"(?:^|[\s;&(])([A-Za-z_][A-Za-z0-9_]*)=(\"[^\"`]*\"|'[^']*'|[^\s;&|`'\"]+)(?=[\s;&|)]|$)")
CAT_FILE = re.compile(r"\$\(\s*(?:cat\s+|<\s*)(?!<)(\"(?:\$\([^)]*\)|[^\"])+\"|'[^']+'|(?:\$\([^)]*\)|[^\s)])+)\s*\)")
# gh pr create/edit flags that take a value. Everything else is a switch or the target.
VALUED = {
    "-R", "--repo", "-b", "--body", "-F", "--body-file", "-t", "--title", "-H", "--head",
    "-B", "--base", "-a", "--assignee", "-l", "--label", "-r", "--reviewer", "-m",
    "--milestone", "-p", "--project", "-T", "--template", "--recover",
    "--add-assignee", "--remove-assignee", "--add-label", "--remove-label",
    "--add-project", "--remove-project", "--add-reviewer", "--remove-reviewer",
}
OPERATORS = {";", "&&", "||", "|", "&", ";;", "|&", "\n"}


def deny(reason):
    print(json.dumps({"hookSpecificOutput": {
        "hookEventName": "PreToolUse",
        "permissionDecision": "deny",
        "permissionDecisionReason": reason,
    }}, separators=(",", ":")))
    sys.exit(0)


def split_heredocs(text):
    """(code, bodies): the command with heredoc BODIES removed, and each body by the
    code line that opened it. A body is data, not shell."""
    code, bodies, pending, cur = [], {}, [], None
    for line in text.split("\n"):
        if cur is not None:
            term, idx, buf = cur
            if line.strip() == term:
                bodies.setdefault(idx, []).append("\n".join(buf))
                cur = pending.pop(0) if pending else None
            else:
                buf.append(line)
            continue
        idx = len(code)
        code.append(line)
        terms = [next(g for g in m if g) for m in HEREDOC.findall(line)]
        if terms:
            queue = [(t, idx, []) for t in terms]
            cur, pending = queue[0], queue[1:]
    return "\n".join(code), bodies


def unquote(tok):
    tok = tok.strip()
    if len(tok) >= 2 and tok[0] == tok[-1] and tok[0] in "\"'":
        return tok[1:-1]
    return tok


def run(argv, cwd):
    try:
        r = subprocess.run(argv, cwd=cwd, capture_output=True, text=True, timeout=8)
    except (OSError, subprocess.SubprocessError):
        return None
    return r.stdout.strip() if r.returncode == 0 else None


def expand(value, env, cwd):
    """Fill in $VAR / ${VAR} from assignments seen in the command, and the two git
    lookups a body path is built from. Anything else stays as written."""
    def git_sub(m):
        out = run(["git", "rev-parse", m.group(1)], cwd)
        return out if out else m.group(0)
    for _ in range(4):
        before = value
        value = re.sub(r"\$\(\s*git\s+rev-parse\s+(--absolute-git-dir|--show-toplevel|--git-dir)\s*\)", git_sub, value)
        value = re.sub(r"\$\{(\w+)\}|\$(\w+)", lambda m: env.get(m.group(1) or m.group(2), m.group(0)), value)
        if value == before:
            break
    return os.path.expanduser(value)


def issue_of(branch):
    """The ticket a branch names: `<letters>-<n>` or `<n>` leading its first segment."""
    branch = re.sub(r"^[^:/]+:", "", branch or "")   # owner:branch
    m = re.match(r"(?:[A-Za-z]+-)?(\d+)(?:[-_][A-Za-z]|$)", branch.split("/")[0])
    return m.group(1) if m else None


def own_repo(repo, cwd):
    if repo:
        return repo.lower()
    url = run(["git", "remote", "get-url", "origin"], cwd) or ""
    m = re.search(r"github\.com[:/]([\w.-]+/[\w.-]+?)(?:\.git)?$", url)
    return m.group(1).lower() if m else None


def refs(text, repo):
    nums = set()
    for url_repo, short_repo, num in CLOSE_REF.findall(text or ""):
        other = (url_repo or short_repo).lower()
        if other and other != repo:
            continue   # another repo's ticket, or one we cannot place
        nums.add(num)
    return nums


def tokens_of(segment):
    """The gh command's own words: up to the first operator or unquoted newline."""
    segment = re.sub(r"\\\n", " ", segment)            # a continued line is one line
    segment = re.sub(r"\d*>&\d+", " ", segment)          # 2>&1 is not a background &
    try:
        lex = shlex.shlex(segment, posix=True, punctuation_chars=";&|\n")
        lex.whitespace = " \t\r"
        lex.whitespace_split = True
        lex.commenters = ""   # a `# via /finish` inside backticks is not the end of the line
        toks = list(lex)
    except ValueError:
        toks = segment.split()
    out = []
    for t in toks:
        if t in OPERATORS:
            break
        out.append(t)
    return out


def parse(toks):
    opts, positional, i = {}, [], 0
    while i < len(toks):
        t = toks[i]
        if t.startswith("-") and "=" in t and t.split("=", 1)[0] in VALUED:
            k, v = t.split("=", 1)
            opts.setdefault(k, v)
        elif t in VALUED:
            opts.setdefault(t, toks[i + 1] if i + 1 < len(toks) else "")
            i += 1
        elif not t.startswith(("-", "#", "`")):
            positional.append(t)
        i += 1
    return opts, positional


def get(opts, *names):
    for n in names:
        if n in opts:
            return opts[n]
    return None


def name_check(raw, path, issue, branch):
    base = os.path.basename(path)
    if "$" in base:
        return   # a name we cannot fill in here; the content check still runs
    if not re.search(r"(?<!\d)" + re.escape(issue) + r"(?!\d)", base):
        deny(f"Refused: the body file {raw} is not named for ticket #{issue} (branch {branch}). A PR "
             f"body file is per ticket, never a shared scratch path another agent can overwrite. "
             f"Write it to \"$(git rev-parse --absolute-git-dir)/pr-body-{issue}.md\" and pass that.")


def main():
    try:
        payload = json.load(sys.stdin)
    except ValueError:
        return
    cmd = (payload.get("tool_input") or {}).get("command") or ""
    if "gh" not in cmd or "pr" not in cmd:
        return
    code, bodies = split_heredocs(cmd)
    base_cwd = payload.get("cwd") or os.getcwd()

    env = dict(os.environ)
    for name, val in ASSIGN.findall(code):
        env[name] = unquote(val)

    for m in PR_CMD.finditer(code):
        verb = m.group(1)
        rest = code[m.end():]
        toks = tokens_of(rest)
        opts, positional = parse(toks)
        inline = get(opts, "--body", "-b")
        body_file = get(opts, "--body-file", "-F")
        if inline is None and body_file is None:
            continue   # not setting a body

        # The directory this gh runs in: the last `cd` before it, else the session's.
        cwd = base_cwd
        for c in re.findall(r"(?:^|[;&|(\n])[ \t]*cd[ \t]+(\"[^\"]+\"|'[^']+'|[^\s;&|]+)", code[: m.start() + 1]):
            p = expand(unquote(c), env, cwd)
            cwd = p if os.path.isabs(p) else os.path.join(cwd, p)
        repo = get(opts, "--repo", "-R")

        if verb == "create":
            branch = get(opts, "--head", "-H") or run(["git", "branch", "--show-current"], cwd)
        else:
            target = expand(positional[0], env, cwd) if positional else None
            if target and re.search(r"(?:^#?|/pull/)\d+$", target):
                argv = ["gh", "pr", "view", target.lstrip("#"), "--json", "headRefName", "-q", ".headRefName"]
                if repo and "/pull/" not in target:
                    argv[4:4] = ["--repo", repo]
                branch = run(argv, cwd)
                if not branch:
                    deny(f"Refused: could not read the branch of PR {target}, so this body cannot be "
                         "checked against the ticket it names. Retry once gh can reach the PR.")
            elif target and "$" in target:
                continue   # a PR we cannot name here (e.g. "$PR_NUMBER")
            else:
                branch = target or run(["git", "branch", "--show-current"], cwd)
        issue = issue_of(branch)
        if not issue:
            continue   # a branch that names no ticket has nothing to compare against

        # Heredoc bodies opened on the lines this gh command spans.
        first = code[: m.end()].count("\n")
        last = first + (inline or "").count("\n")
        own_bodies = "\n".join(b for i in range(first, last + 1) for b in bodies.get(i, []))

        texts = []   # (what was read, its text)
        files = []
        if inline is not None:
            texts.append(("the --body text", inline + ("\n" + own_bodies if "<<" in inline else "")))
            own_text = rest[: len("\n".join(rest.split("\n")[: last - first + 1]))]
            files += [unquote(p) for p in CAT_FILE.findall(own_text)]   # raw: shlex splits a nested $( )
        if body_file is not None and body_file != "-":
            files.append(body_file)
        elif body_file == "-":
            texts.append(("this command", cmd))

        for raw in files:
            path = expand(raw, env, cwd)
            if not os.path.isabs(path) and "$" not in path:
                path = os.path.join(cwd, path)
            name_check(raw, path, issue, branch)
            target = r"\s*[\"']?" + re.escape(raw) + r"[\"']?"
            fresh = re.compile(r"(?:(?<!>)>(?!>)|\btee\s+(?!-a))" + target)
            append = re.compile(r"(?:>>|\btee\s+-a\s+)" + target)
            lines = code.split("\n")
            written = [i for i, line in enumerate(lines) if fresh.search(line) or append.search(line)]
            if written:
                texts.append(("the body this command writes",
                              "\n".join(b for i in written for b in bodies.get(i, [])) or cmd))
            appended = any(append.search(line) for line in lines)
            if (appended or not written) and "$" not in path:
                try:
                    with open(path, encoding="utf-8", errors="replace") as fh:
                        texts.append((raw, fh.read()))
                except OSError:
                    pass   # gh reports a missing file itself

        repo_id = own_repo(repo, cwd)
        for where, text in texts:
            wrong = sorted(refs(text, repo_id) - {issue}, key=int)
            if wrong:
                deny(f"Refused: {where} closes {', '.join('#' + n for n in wrong)} but the branch {branch} "
                     f"is ticket #{issue}. One PR closes its own ticket only; this looks like another "
                     f"ticket's PR body. Rebuild the body for #{issue} from its own commits and evidence; "
                     "never re-send a body file you did not just write. Name a rolled-in ticket without "
                     "a closing keyword.")


if __name__ == "__main__":
    main()
