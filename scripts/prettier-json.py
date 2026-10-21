#!/usr/bin/env python3
"""prettier-json.py <file> [--root <tree>] — rewrite a JSON file in the layout Prettier's
json parser prints, for a tree that has no Prettier installed to run.

Python's indent-2 JSON is not that layout: Prettier puts a short array on one line,
so a plan written by json.dumps failed the consuming project's format check.

The layout: every non-empty object is broken, one key per line (Prettier keeps an
object broken when its first key starts a new line, and this writer always starts it
there). An array is printed on one line when it holds no non-empty object, is not two
or more non-empty objects or arrays, and fits within printWidth with the comma after
it; otherwise one element per line. printWidth, tabWidth and useTabs are read from the
tree's .prettierrc / .prettierrc.json when it is JSON. Arrays of numbers, which
Prettier fills several to a line, are printed one per line when broken.
"""
import json
import os
import sys


def options(root):
    o = {"printWidth": 80, "tabWidth": 2, "useTabs": False}
    for name in (".prettierrc", ".prettierrc.json"):
        p = os.path.join(root, name)
        if os.path.isfile(p):
            try:
                with open(p) as fh:
                    cfg = json.load(fh)
            except (ValueError, OSError):
                continue
            if isinstance(cfg, dict):
                for k in o:
                    if k in cfg:
                        o[k] = cfg[k]
            break
    return o


def flat(v):
    if isinstance(v, list):
        return "[" + ", ".join(flat(x) for x in v) + "]"
    if isinstance(v, dict):
        return "{}" if not v else None
    return json.dumps(v, ensure_ascii=False)


def must_break(a):
    if any(isinstance(x, dict) and x for x in a):
        return True
    if any(isinstance(x, list) and must_break(x) for x in a):
        return True
    # Prettier breaks an array of two or more elements that are all objects or arrays
    # of more than one element.
    return len(a) > 1 and all(isinstance(x, (dict, list)) and len(x) > 1 for x in a)


def render(v, depth, col, trailer, o):
    unit = "\t" if o["useTabs"] else " " * o["tabWidth"]
    width = o["tabWidth"] if o["useTabs"] else len(unit)
    inner = unit * (depth + 1)
    if isinstance(v, dict):
        if not v:
            return "{}"
        rows = []
        items = list(v.items())
        for i, (k, x) in enumerate(items):
            key = json.dumps(k, ensure_ascii=False) + ": "
            t = 0 if i == len(items) - 1 else 1
            rows.append(inner + key + render(x, depth + 1, (depth + 1) * width + len(key), t, o) + ("," if t else ""))
        return "{\n" + "\n".join(rows) + "\n" + unit * depth + "}"
    if isinstance(v, list):
        if not v:
            return "[]"
        if not must_break(v):
            f = flat(v)
            if col + len(f) + trailer <= o["printWidth"]:
                return f
        rows = []
        for i, x in enumerate(v):
            t = 0 if i == len(v) - 1 else 1
            rows.append(inner + render(x, depth + 1, (depth + 1) * width, t, o) + ("," if t else ""))
        return "[\n" + "\n".join(rows) + "\n" + unit * depth + "]"
    return json.dumps(v, ensure_ascii=False)


def main(argv):
    if not argv:
        print("usage: prettier-json.py <file> [--root <tree>]", file=sys.stderr)
        return 2
    path = argv[0]
    root = argv[argv.index("--root") + 1] if "--root" in argv else os.path.dirname(os.path.abspath(path))
    with open(path, encoding="utf-8") as fh:
        data = json.load(fh)
    out = render(data, 0, 0, 0, options(root)) + "\n"
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(out)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
