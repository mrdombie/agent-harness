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
import subprocess
import sys

PR_CMD = re.compile(r"(?:^|[;&|(\n`]|\bthen|\bdo)\s*gh\s+pr\s+(create|edit)\b(.*)")
CLOSE_REF = re.compile(
    r"\b(?:close[sd]?|fix(?:e[sd])?|resolve[sd]?)(?:\s+ticket)?:?\s+([\w.-]+/[\w.-]+)?#(\d+)",
    re.I,
)
HEREDOC = re.compile(r"""<<-?\s*(?:"([^"]+)"|'([^']+)'|([A-Za-z_][A-Za-z0-9_]*))""")
ASSIGN = re.compile(r"(?:^|[\s;&(])([A-Za-z_][A-Za-z0-9_]*)=(\"[^\"$`]*\"|'[^']*'|[^\s;&|$`'\"]+)(?=[\s;&|)]|$)")


def deny(reason):
    print(json.dumps({"hookSpecificOutput": {
        "hookEventName": "PreToolUse",
        "permissionDecision": "deny",
        "permissionDecisionReason": reason,
    }}, separators=(",", ":")))
    sys.exit(0)


def strip_heredocs(text):
    """The command with every heredoc BODY removed: a body is data, not shell."""
    out, term = [], None
    for line in text.split("\n"):
        if term is not None:
            if line.strip() == term:
                term = None
            continue
        found = HEREDOC.findall(line)
        if found:
            term = next(g for g in found[-1] if g)
        out.append(line)
    return "\n".join(out)


def unquote(tok):
    tok = tok.strip()
    if len(tok) >= 2 and tok[0] == tok[-1] and tok[0] in "\"'":
        return tok[1:-1]
    return tok


def flag(args, *names):
    for n in names:
        m = re.search(r"(?:^|\s)" + re.escape(n) + r"(?:=|\s+)(\"[^\"]*\"|'[^']*'|\S+)", args)
        if m:
            return unquote(m.group(1))
    return None


def has_flag(args, *names):
    return any(re.search(r"(?:^|\s)" + re.escape(n) + r"(?:=|\s|$)", args) for n in names)


def expand(path, env):
    path = re.sub(r"\$\{(\w+)\}|\$(\w+)", lambda m: env.get(m.group(1) or m.group(2), m.group(0)), path)
    return os.path.expanduser(path)


def run(argv, cwd):
    try:
        r = subprocess.run(argv, cwd=cwd, capture_output=True, text=True, timeout=8)
    except (OSError, subprocess.SubprocessError):
        return None
    return r.stdout.strip() if r.returncode == 0 else None


def issue_of(branch):
    """The ticket a branch names: the first digit run of its first segment."""
    branch = re.sub(r"^[^:]+:", "", branch or "")   # owner:branch
    m = re.search(r"\d+", branch.split("/")[0])
    return m.group(0) if m else None


def refs(text, repo):
    nums = set()
    for owner_repo, num in CLOSE_REF.findall(text or ""):
        if owner_repo and repo and owner_repo.lower() != repo.lower():
            continue
        if owner_repo and not repo:
            continue
        nums.add(num)
    return nums


def main():
    payload = json.load(sys.stdin)
    cmd = (payload.get("tool_input") or {}).get("command") or ""
    if "gh" not in cmd or "pr" not in cmd:
        return
    code = strip_heredocs(cmd)
    base_cwd = payload.get("cwd") or os.getcwd()

    env = dict(os.environ)
    for name, val in ASSIGN.findall(code):
        env[name] = unquote(val)

    for m in PR_CMD.finditer(code):
        verb, args = m.group(1), m.group(2)
        args = re.split(r"\s(?:&&|\|\||;|\|)\s|[;\n]", args)[0]
        inline = has_flag(args, "--body", "-b")
        body_file = flag(args, "--body-file", "-F")
        if not inline and body_file is None:
            continue   # not setting a body

        # The directory this gh runs in: the last `cd` before it, else the session's.
        cwd = base_cwd
        for c in re.findall(r"(?:^|[;&|(\n])\s*cd\s+(\"[^\"]+\"|'[^']+'|[^\s;&|]+)", code[: m.start() + 1]):
            p = expand(unquote(c), env)
            cwd = p if os.path.isabs(p) else os.path.join(cwd, p)
        repo = flag(args, "--repo", "-R")

        if verb == "create":
            branch = flag(args, "--head", "-H") or run(["git", "branch", "--show-current"], cwd)
            if not branch:
                continue
        else:
            target = re.match(r"\s*(\"[^\"]*\"|'[^']*'|[^\s-]\S*)", args)
            target = unquote(target.group(1)) if target else None
            if target and re.search(r"(?:^|/pull/)(\d+)$", target):
                num = re.search(r"(\d+)$", target).group(1)
                argv = ["gh", "pr", "view", num, "--json", "headRefName", "-q", ".headRefName"]
                if repo:
                    argv[3:3] = ["--repo", repo]
                branch = run(argv, cwd)
                if not branch:
                    deny(f"Refused: could not read the branch of PR {num}, so this body cannot be checked "
                         "against the ticket it names. Retry once gh can reach the PR.")
            else:
                branch = target or run(["git", "branch", "--show-current"], cwd)
            if not branch:
                continue

        issue = issue_of(branch)
        if not issue:
            continue   # a branch that names no ticket has nothing to compare against

        if inline or body_file == "-":
            text, where = cmd, "this command"
        else:
            path = expand(body_file, env)
            if not os.path.isabs(path):
                path = os.path.join(cwd, path)
            if issue not in os.path.basename(path) and issue not in path:
                deny(f"Refused: the body file {body_file} does not name ticket #{issue}. A PR body file is "
                     f"per ticket, never a shared scratch path another agent can overwrite. Write it to "
                     f"\"$(git rev-parse --absolute-git-dir)/pr-body-{issue}.md\" and pass that.")
            written_here = re.search(r"(?:>|\btee\s+(?:-a\s+)?)\s*[\"']?" + re.escape(body_file), cmd)
            if written_here:
                text, where = cmd, "the body this command writes"
            else:
                try:
                    with open(path, encoding="utf-8", errors="replace") as fh:
                        text = fh.read()
                except OSError:
                    continue   # gh reports a missing file itself
                where = body_file

        closes = refs(text, repo)
        wrong = sorted(closes - {issue}, key=int)
        if wrong:
            deny(f"Refused: {where} closes {', '.join('#' + n for n in wrong)} but the branch {branch} is "
                 f"ticket #{issue}. This is another ticket's PR body. Rebuild the body for #{issue} from "
                 "its own commits and evidence; never re-send a body file you did not just write.")


if __name__ == "__main__":
    main()
