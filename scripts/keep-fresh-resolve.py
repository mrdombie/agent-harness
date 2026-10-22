#!/usr/bin/env python3
"""keep-fresh-resolve.py — settle a conflicted merge by the project's mechanical rules, or touch nothing.

    python3 -I keep-fresh-resolve.py <rules.json>     (cwd: a worktree with a merge in progress)

<rules.json> is `merge.mechanical` from harness.json: a list of {"rule": <name>, "paths": [<glob>, ...]}.
The first rule whose glob matches a conflicted file decides it. Rules:

  integration      the integration branch's side wins, a deletion included
  union            the lines of both sides (git merge-file --union)
  stricter-json    a 3-way JSON merge: a key both sides changed takes the lower number, a list
                   takes the entries either side added less those either side removed, a key one
                   side removed stays removed; two different strings or types are a real conflict
  package-scripts  a 3-way package.json merge in which the only change both sides made is adding
                   keys under "scripts" (a key added twice must agree); anything else both sides
                   changed, or any script one side changed or removed, is a real conflict

A JSON rule rewrites only a file it can reproduce byte for byte: each side must read back exactly
as json.dumps writes it at that file's indent, or the conflict is real.

Every file is decided before any is written. Exit 0: all resolved and staged, one "<path>\\t<rule>"
line each on stdout. Exit 1: a real conflict, "<path>\\t<why>" lines on stdout, nothing written.
Exit 2: the rules or the merge could not be read.
"""
import json
import os
import re
import subprocess
import sys
import tempfile

MISSING = object()


class Real(Exception):
    pass


def git(*args, stdin=None):
    r = subprocess.run(["git", *args], input=stdin, capture_output=True)
    if r.returncode != 0:
        raise RuntimeError(f"git {' '.join(args)}: {r.stderr.decode(errors='replace').strip()}")
    return r.stdout


def glob_re(pat):
    """A git pathspec written as a glob: ** crosses directories, * and ? stay in one,
    and a plain path matches itself and everything under it."""
    if not any(c in pat for c in "*?["):
        return re.compile(re.escape(pat.rstrip("/")) + r"(/.*)?$")
    out, i = "", 0
    while i < len(pat):
        c = pat[i]
        if c == "*":
            if pat[i + 1:i + 2] == "*":
                if pat[i + 2:i + 3] == "/":
                    out += "(.*/)?"
                    i += 3
                    continue
                out += ".*"
                i += 2
                continue
            out += "[^/]*"
        elif c == "?":
            out += "[^/]"
        else:
            out += re.escape(c)
        i += 1
    return re.compile(out + "$")


def stages():
    """{path: {stage: (mode, sha)}} for every unmerged path."""
    raw = git("ls-files", "-u", "-z").split(b"\0")
    out = {}
    for ent in raw:
        if not ent:
            continue
        meta, path = ent.split(b"\t", 1)
        mode, sha, st = meta.decode().split()
        out.setdefault(path.decode(), {})[int(st)] = (mode, sha)
    return out


def blob(sha):
    return git("cat-file", "blob", sha)


def indent_of(text):
    for line in text.splitlines()[1:]:
        stripped = line.lstrip(" \t")
        if stripped and len(stripped) != len(line):
            ws = line[:len(line) - len(stripped)]
            return "\t" if ws.startswith("\t") else len(ws)
    return 2


def dump(obj, ind, newline):
    return json.dumps(obj, indent=ind, ensure_ascii=False) + ("\n" if newline else "")


def load_exact(data, side):
    try:
        text = data.decode("utf-8")
        obj = json.loads(text)
    except (UnicodeDecodeError, ValueError) as e:
        raise Real(f"the {side} side is not JSON ({e})")
    ind = indent_of(text)
    if dump(obj, ind, text.endswith("\n")) != text:
        raise Real(f"the {side} side is formatted in a way this rule cannot write back")
    return obj, ind, text.endswith("\n")


def isnum(v):
    return isinstance(v, (int, float)) and not isinstance(v, bool)


def sorted_keys(d):
    k = list(d.keys())
    return k == sorted(k)


def stricter(b, o, t, where):
    if o == t:
        return o
    if b is not MISSING and o == b:
        return t
    if b is not MISSING and t == b:
        return o
    if isnum(o) and isnum(t):
        return min(o, t)
    if isinstance(o, dict) and isinstance(t, dict):
        bd = b if isinstance(b, dict) else {}
        keys = list(o.keys()) + [k for k in t.keys() if k not in o]
        res = {}
        for k in keys:
            bv, ov, tv = bd.get(k, MISSING), o.get(k, MISSING), t.get(k, MISSING)
            if ov is MISSING or tv is MISSING:
                # Added by one side: kept. Removed by one side: stays removed (a count gone to zero).
                if bv is MISSING:
                    res[k] = tv if ov is MISSING else ov
                continue
            res[k] = stricter(bv, ov, tv, f"{where}.{k}")
        if sorted_keys(o) and sorted_keys(t):
            res = {k: res[k] for k in sorted(res)}
        return res
    if isinstance(o, list) and isinstance(t, list):
        bl = b if isinstance(b, list) else []
        gone = [x for x in bl if x not in o or x not in t]
        res = []
        for x in o + t:
            if x not in res and x not in gone:
                res.append(x)
        return res
    raise Real(f"both sides set {where or 'the document'} to different values that are not numbers")


def scripts_merge(b, o, t):
    if not all(isinstance(x, dict) for x in (b, o, t)):
        raise Real("package.json is not an object on every side")
    keys = list(o.keys()) + [k for k in t.keys() if k not in o] + [k for k in b.keys() if k not in o and k not in t]
    res = {}
    for k in keys:
        bv, ov, tv = b.get(k, MISSING), o.get(k, MISSING), t.get(k, MISSING)
        if k == "scripts":
            bs, os_, ts = (x if isinstance(x, dict) else ({} if x is MISSING else None) for x in (bv, ov, tv))
            if bs is None or os_ is None or ts is None:
                raise Real("\"scripts\" is not an object on every side")
            for side, s in (("this pull request", os_), ("the integration branch", ts)):
                for name, cmd in bs.items():
                    if s.get(name, MISSING) != cmd:
                        raise Real(f"{side} changed or removed the existing script \"{name}\"")
            merged = dict(os_)
            for name, cmd in ts.items():
                if name in merged and merged[name] != cmd:
                    raise Real(f"both sides added the script \"{name}\" with different commands")
                merged.setdefault(name, cmd)
            res[k] = merged
            continue
        if ov == tv:
            r = ov
        elif ov == bv:
            r = tv
        elif tv == bv:
            r = ov
        else:
            raise Real(f"both sides changed \"{k}\", which is outside \"scripts\"")
        if r is not MISSING:
            res[k] = r
    return res


def resolve(path, rule, st):
    """('write', bytes, mode) | ('rm',) — or raise Real."""
    has = {s: st.get(s) for s in (1, 2, 3)}
    if rule == "integration":
        if has[3] is None:
            return ("rm",)
        return ("write", blob(has[3][1]), has[3][0])
    if has[2] is None or has[3] is None:
        raise Real("one side deleted it")
    ours, theirs = blob(has[2][1]), blob(has[3][1])
    base = blob(has[1][1]) if has[1] else None
    mode = has[2][0]
    if rule == "union":
        with tempfile.TemporaryDirectory() as d:
            paths = []
            for name, data in (("ours", ours), ("base", base or b""), ("theirs", theirs)):
                p = os.path.join(d, name)
                with open(p, "wb") as f:
                    f.write(data)
                paths.append(p)
            r = subprocess.run(["git", "merge-file", "-p", "--union", *paths], capture_output=True)
            if r.returncode < 0 or r.returncode > 127:
                raise Real("git merge-file could not union it")
            return ("write", r.stdout, mode)
    if rule == "stricter-json":
        o, ind, nl = load_exact(ours, "pull request's")
        t, _, _ = load_exact(theirs, "integration branch's")
        b = load_exact(base, "common ancestor's")[0] if base is not None else MISSING
        return ("write", dump(stricter(b, o, t, ""), ind, nl).encode("utf-8"), mode)
    if rule == "package-scripts":
        if base is None:
            raise Real("both sides added package.json")
        o, ind, nl = load_exact(ours, "pull request's")
        t, _, _ = load_exact(theirs, "integration branch's")
        b, _, _ = load_exact(base, "common ancestor's")
        return ("write", dump(scripts_merge(b, o, t), ind, nl).encode("utf-8"), mode)
    raise Real(f"the rule \"{rule}\" is not one this script knows")


KNOWN = ("integration", "union", "stricter-json", "package-scripts")


def main():
    if len(sys.argv) != 2:
        print("usage: keep-fresh-resolve.py <rules.json>", file=sys.stderr)
        return 2
    try:
        with open(sys.argv[1]) as f:
            rules = json.load(f)
        assert isinstance(rules, list)
        compiled = []
        for r in rules:
            assert isinstance(r, dict) and r.get("rule") in KNOWN and isinstance(r.get("paths"), list)
            compiled.append((r["rule"], [glob_re(p) for p in r["paths"] if isinstance(p, str)]))
    except (OSError, ValueError, AssertionError):
        print("keep-fresh-resolve: merge.mechanical must be a list of {rule, paths}, rule one of "
              + ", ".join(KNOWN), file=sys.stderr)
        return 2
    try:
        conflicted = stages()
    except RuntimeError as e:
        print(f"keep-fresh-resolve: {e}", file=sys.stderr)
        return 2
    if not conflicted:
        print("keep-fresh-resolve: nothing is conflicted", file=sys.stderr)
        return 2
    plan, real = [], []
    for path in sorted(conflicted):
        rule = next((name for name, res in compiled if any(rx.match(path) for rx in res)), None)
        if rule is None:
            real.append((path, "no mechanical rule covers it"))
            continue
        try:
            plan.append((path, rule, resolve(path, rule, conflicted[path])))
        except Real as e:
            real.append((path, f"{rule}: {e}"))
        except RuntimeError as e:
            print(f"keep-fresh-resolve: {e}", file=sys.stderr)
            return 2
    if real:
        for path, why in real:
            print(f"{path}\t{why}")
        return 1
    for path, rule, act in plan:
        if act[0] == "rm":
            git("rm", "-q", "--cached", "--ignore-unmatch", "--", path)
            if os.path.lexists(path):
                os.remove(path)
        else:
            os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
            with open(path, "wb") as f:
                f.write(act[1])
            if act[2] == "100755":
                os.chmod(path, 0o755)
            git("add", "--", path)
        print(f"{path}\t{rule}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
