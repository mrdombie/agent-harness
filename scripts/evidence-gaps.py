#!/usr/bin/env python3
"""evidence-gaps.py — what a pull request changed on screen that its evidence never shows.

  evidence-gaps.py classify                      findings on stdin; prints the evidence-class ones
                                                 ("no shot of X", "dark missing", "390 missing",
                                                 "region has no shot", "evidence gap: …")
  evidence-gaps.py coverage --repo <git dir> --base <sha> --head <sha>
                            [--plan <path>] [--route <r>]... [--ignore-route <prefix>]...
                                                 one gap a line: kind \t file \t routes \t text
  evidence-gaps.py routes --repo <git dir> --base <sha> --head <sha> [--ignore-route <prefix>]...
                                                 the routes the changed UI renders on, one a line
  evidence-gaps.py plan --into <plan.json> --route <r>...
                                                 the plan with each route at laptop 1440 / phone 390 x
                                                 light / dark (picture-evidence.py's derivation), a
                                                 shot the plan already has for that route, width and
                                                 theme kept as it is
  evidence-gaps.py check-plan <plan.json>        exit 0 when the plan is one CI can read

WHY. Three repairs in one day were told to add shots (a drawer open, dark, 390 wide) and
pushed without touching the capture plan or `## Evidence routes`: they read their job as
"turn red checks green", and nothing red said the evidence was short. So the gap is
measured, not remembered:

  missing-route  a UI file the PR changes that no evidence route renders. The routes the
                 capture uses are the plan's when the PR adds or edits <plan> (the plan
                 replaces the routes list, as CI reads it), else the --route list. A file
                 renders on a route when the route's page, or a layout above it, imports it,
                 directly or through other files (relative, `@/`/`~/` and workspace-package
                 imports followed). A file no page imports at all is not a screen file, nor
                 is one only pages under an --ignore-route prefix import (a component
                 catalogue: evidence.coverage.ignoreRoutes, default /dev).
  missing-state  a changed file that only shows once opened (a drawer, dialog, modal,
                 sheet, popover, dropdown, tooltip, toast, overlay) with no plan shot on a
                 route that renders it whose setup steps do something: nothing opened it.

Exit codes: 0 fine (coverage: no gap) · 1 a gap · 2 could not run.
"""
import importlib.util
import json
import os
import posixpath
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.dont_write_bytecode = True   # loading picture-evidence.py must leave no cache in the kit
CODE_EXT = (".tsx", ".jsx", ".ts", ".js", ".mjs")
UI_EXT = (".tsx", ".jsx")
NOT_UI = re.compile(r"(^|/)(__tests__|__mocks__|e2e|tests?)/|\.(test|spec|stories)\.[a-z]+$|(^|/)docs/")
PAGE = re.compile(r"^(?:.*/)?app/((?:.*/)?)(page|layout)\.(tsx|jsx|ts|js)$")
STATEFUL = re.compile(r"(drawer|dialog|modal|sheet|popover|dropdown|tooltip|toast|overlay|lightbox|flyout|slide-?over|"
                      r"(context|action|overflow|kebab)-?menu)", re.I)
IMPORT = re.compile(r"""(?:from|import)\s*\(?\s*['"]([^'"]+)['"]""")
EVIDENCE = re.compile(
    r"evidence gap|no (pinned )?shot|never (been )?photographed|not photographed|nobody saw it|"
    r"(has|with) no shot|without a shot|no (dark|phone|390|mobile|laptop|1440)[ -]?(theme |width )?(shot|capture|evidence|frame)|"
    r"(dark|phone|390|mobile|laptop|1440)[^.;]{0,40}\b(missing|not (shown|captured|photographed|evidenced))|"
    r"missing[^.;]{0,30}\b(shot|dark|phone|390|capture|state)|"
    r"(drawer|dialog|modal|menu|sheet|popover)[^.;]{0,40}\b(open|state)[^.;]{0,30}\b(missing|no shot|not shown|never)|"
    r"capture (plan|step)|evidence route", re.I)


def die(msg):
    print(f"evidence-gaps: {msg}", file=sys.stderr)
    sys.exit(2)


def git(repo, *args):
    r = subprocess.run(["git", "-C", repo, *args], capture_output=True, text=True)
    if r.returncode not in (0, 1):
        die(f"git {' '.join(args[:2])} failed: {r.stderr.strip()[:200]}")
    return r.stdout


def opts(argv):
    o = {"routes": [], "plan": [], "ignore": [], "repo": None, "base": None, "head": None, "into": None}
    rest, i = [], 0
    while i < len(argv):
        a = argv[i]
        if a in ("--repo", "--base", "--head", "--into", "--plan", "--route", "--ignore-route"):
            if i + 1 >= len(argv):
                die(f"{a} needs a value")
            v = argv[i + 1]
            i += 1
            if a == "--route":
                v = v.strip()
                if v.startswith("/") and v not in o["routes"]:
                    o["routes"].append(v)
            elif a == "--plan":
                o["plan"].append(v)
            elif a == "--ignore-route":
                o["ignore"].append(v.rstrip("/") or "/")
            else:
                o[a[2:]] = v
        else:
            rest.append(a)
        i += 1
    return o, rest


# ---- the import graph at a commit -------------------------------------------------

class Tree:
    def __init__(self, repo, head):
        self.repo, self.head = repo, head
        files = git(repo, "ls-tree", "-r", "--name-only", head).splitlines()
        self.files = set(files)
        self.code = [f for f in files if f.endswith(CODE_EXT) and "/node_modules/" not in f]
        self.stems = {}
        for f in self.code:
            s = re.sub(r"\.[A-Za-z]+$", "", f)
            self.stems.setdefault(s, []).append(f)
            if s.endswith("/index"):
                self.stems.setdefault(s[: -len("/index")], []).append(f)
        self.packages = {}
        for f in files:
            if f.endswith("package.json") and (f == "package.json" or f.endswith("/package.json")):
                try:
                    name = json.loads(git(repo, "show", f"{head}:{f}")).get("name")
                except (ValueError, AttributeError):
                    name = None
                d = posixpath.dirname(f)
                if name and d:
                    self.packages[name] = d
        self.edges = {}
        out = git(repo, "grep", "-I", "-E", r"""(from|import)[[:space:]]*\(?[[:space:]]*['"]""", head, "--",
                  *[f"*{e}" for e in CODE_EXT])
        for line in out.splitlines():
            parts = line.split(":", 2)
            if len(parts) < 3:
                continue
            f = parts[1]
            for spec in IMPORT.findall(parts[2]):
                for t in self.resolve(f, spec):
                    self.edges.setdefault(f, set()).add(t)

    def top(self, f, n=2):
        return "/".join(f.split("/")[:n])

    def resolve(self, src, spec):
        if spec.startswith("."):
            s = posixpath.normpath(posixpath.join(posixpath.dirname(src), spec))
            return self.stems.get(re.sub(r"\.(tsx|jsx|ts|js|mjs)$", "", s), [])
        if spec.startswith(("@/", "~/")):
            tail = "/" + spec[2:]
            hits = [f for s, fs in self.stems.items() if s.endswith(tail) for f in fs]
            near = [f for f in hits if self.top(f) == self.top(src)]
            return near or hits
        for name, d in self.packages.items():
            if spec == name or spec.startswith(name + "/"):
                sub = spec[len(name):].lstrip("/")
                if sub:
                    got = [f for s, fs in self.stems.items() if s.startswith(d + "/") and s.endswith("/" + sub) for f in fs]
                    if got:
                        return got
                # The package as a whole: every file it holds is within reach.
                return [f for f in self.code if f.startswith(d + "/")]
        return []

    def reach(self, roots):
        seen, todo = set(), list(roots)
        while todo:
            f = todo.pop()
            if f in seen:
                continue
            seen.add(f)
            todo.extend(self.edges.get(f, ()))
        return seen


def page_route(f):
    """(route pattern segments, kind) for a Next.js app-router page or layout, else None."""
    m = PAGE.match(f)
    if not m:
        return None
    segs = [s for s in m.group(1).split("/") if s and not (s.startswith("(") and s.endswith(")")) and not s.startswith("@")]
    return segs, m.group(2)


def seg_match(pat, segs):
    if not pat:
        return not segs
    p = pat[0]
    if p.startswith("[[...") or p.startswith("[..."):
        lo = 0 if p.startswith("[[") else 1
        return any(seg_match(pat[1:], segs[k:]) for k in range(lo, len(segs) + 1))
    if not segs:
        return False
    if p.startswith("[") or segs[0].startswith("{") or p == segs[0]:
        return seg_match(pat[1:], segs[1:])
    return False


def route_segs(route):
    return [s for s in route.split("?", 1)[0].split("#", 1)[0].split("/") if s]


def roots_of(tree, page):
    """A page, and every layout above it up to its app directory: all of them render."""
    out, d = [page], posixpath.dirname(page)
    while d and d != ".":
        for e in ("tsx", "jsx", "ts", "js"):
            lay = f"{d}/layout.{e}"
            if lay in tree.files:
                out.append(lay)
        if d.endswith("/app") or d == "app":
            break
        d = posixpath.dirname(d)
    return out


def pages_of(tree, route):
    """The page files a route lands on, and every layout above each."""
    segs, out = route_segs(route), []
    for f in tree.code:
        pr = page_route(f)
        if pr and pr[1] == "page" and seg_match(pr[0], segs):
            out += roots_of(tree, f)
    return out


def all_pages(tree, ignore=()):
    """Every page, less those under an ignored route prefix (a component catalogue is not a screen)."""
    out = []
    for f in tree.code:
        if (page_route(f) or ("", ""))[1] != "page":
            continue
        r = route_of_page(f)
        if any(r == i or r.startswith(i + "/") for i in ignore):
            continue
        out.append(f)
    return out


def route_of_page(f):
    segs, _ = page_route(f)
    return "/" + "/".join(segs)


def changed_ui(o):
    names = git(o["repo"], "diff", "--name-only", "--diff-filter=d", f"{o['base']}...{o['head']}").splitlines()
    return names, [f for f in names if f.endswith(UI_EXT) and not NOT_UI.search(f)]


def read_plan(repo, head, path):
    try:
        p = json.loads(git(repo, "show", f"{head}:{path}"))
    except ValueError:
        return None
    return p if isinstance(p, dict) and isinstance(p.get("shots"), list) else None


def renders_on(tree, f, ignore=(), limit=3):
    """The routes whose page reaches f — for naming in a gap."""
    out = []
    for p in sorted(all_pages(tree, ignore)):
        if f in tree.reach(roots_of(tree, p)):
            r = route_of_page(p)
            if r not in out:
                out.append(r)
        if len(out) >= limit:
            break
    return out


def cmd_coverage(argv):
    o, _ = opts(argv)
    for k in ("repo", "base", "head"):
        if not o[k]:
            die(f"coverage needs --{k}")
    names, ui = changed_ui(o)
    if not ui:
        return 0
    tree = Tree(o["repo"], o["head"])
    screens = tree.reach([r for p in all_pages(tree, o["ignore"]) for r in roots_of(tree, p)])
    ui = [f for f in ui if f in screens]
    if not ui:
        return 0
    # CI's reading: a plan this PR adds or edits replaces the routes list outright.
    plan, plan_path = None, ""
    for p in o["plan"]:
        if p in names:
            plan, plan_path = read_plan(o["repo"], o["head"], p), p
            break
    shots = [s for s in (plan or {}).get("shots", []) if isinstance(s, dict) and str(s.get("route", "")).startswith("/")]
    routes = list(dict.fromkeys(s["route"] for s in shots)) if plan else o["routes"]
    reach_of = {r: tree.reach(pages_of(tree, r)) for r in routes}
    shown = set().union(*reach_of.values()) if reach_of else set()
    where = f"the capture plan ({plan_path})" if plan else "`## Evidence routes`"
    gaps = 0
    for f in ui:
        if f not in shown:
            on = renders_on(tree, f, o["ignore"])
            print("\t".join(["missing-route", f, " ".join(on),
                             f"evidence gap: {f} changed and no route in {where} renders it — it renders on "
                             f"{', '.join(on) or 'no known route'}: add a shot of it to the capture plan and its route to `## Evidence routes`"]))
            gaps += 1
            continue
        if STATEFUL.search(posixpath.basename(f)):
            opened = [s for s in shots if s.get("setup") and f in reach_of.get(s["route"], set())]
            if not opened:
                kind = STATEFUL.search(posixpath.basename(f)).group(1).lower()
                on = [r for r in routes if f in reach_of[r]]
                print("\t".join(["missing-state", f, " ".join(on),
                                 f"evidence gap: {f} is a {kind} that only shows once opened, and no capture-plan shot on "
                                 f"{', '.join(on)} has setup steps that open it — add shots (laptop and phone, light and dark) whose setup opens it"]))
                gaps += 1
    return 1 if gaps else 0


def cmd_routes(argv):
    o, _ = opts(argv)
    for k in ("repo", "base", "head"):
        if not o[k]:
            die(f"routes needs --{k}")
    names, ui = changed_ui(o)
    ign = o["ignore"]
    pagefiles = [f for f in names if (page_route(f) or ("", ""))[1] == "page"]
    out = [r for r in map(route_of_page, pagefiles) if not any(r == i or r.startswith(i + "/") for i in ign)]
    if ui:
        # Fewest routes that show every changed file: a page is taken only for a file no
        # route taken so far renders, and a page CI cannot photograph as written is skipped.
        tree = Tree(o["repo"], o["head"])
        left = set(ui)
        for r in out:
            for p in pages_of(tree, r):
                left -= tree.reach([p])
        for p in sorted(all_pages(tree, ign)):
            r = route_of_page(p)
            if not left or len(out) >= 8:
                break
            if "[" in r:
                continue
            got = tree.reach(pages_of(tree, r)) & left
            if got:
                out.append(r)
                left -= got
    # A dynamic segment cannot be photographed as written: CI needs a real path.
    seen = []
    for r in out:
        if "[" not in r and r not in seen:
            seen.append(r)
    print("\n".join(seen[:8]))
    return 0


def derive_of():
    spec = importlib.util.spec_from_file_location("picture_evidence", os.path.join(HERE, "picture-evidence.py"))
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m


def cmd_plan(argv):
    o, _ = opts(argv)
    if not o["into"]:
        die("plan needs --into <plan.json>")
    if not o["routes"]:
        die("plan needs at least one --route")
    pe = derive_of()
    shots, _how = pe.derive(pe.Picture(), o["routes"])
    plan = {"shots": []}
    if os.path.exists(o["into"]):
        try:
            with open(o["into"], encoding="utf-8") as f:
                plan = json.load(f)
        except (OSError, ValueError) as e:
            die(f"{o['into']} is not a readable capture plan: {e}")
        if not isinstance(plan, dict) or not isinstance(plan.get("shots", []), list):
            die(f"{o['into']} is not a capture plan: no shots list")
        plan.setdefault("shots", [])
    have = [s for s in plan["shots"] if isinstance(s, dict)]
    names = {s.get("name") for s in have}
    for s in shots:
        if s["name"] in names:
            continue
        if any(h.get("route") == s["route"] and h.get("viewport", "laptop") == s["viewport"]
               and h.get("theme", "light") == s["theme"] for h in have):
            continue
        plan["shots"].append({"name": s["name"], "route": s["route"], "viewport": s["viewport"], "theme": s["theme"]})
    print(json.dumps(plan, indent=2))
    return 0


def cmd_check_plan(argv):
    if not argv:
        die("check-plan needs a plan.json")
    try:
        with open(argv[0], encoding="utf-8") as f:
            plan = json.load(f)
    except (OSError, ValueError) as e:
        print(f"evidence-gaps: {argv[0]} is not readable JSON: {e}", file=sys.stderr)
        return 1
    bad = []
    if not isinstance(plan, dict) or not isinstance(plan.get("shots"), list) or not plan["shots"]:
        bad.append('the plan has no non-empty "shots" list')
    else:
        seen = set()
        for i, s in enumerate(plan["shots"]):
            w = f"shot {i}"
            if not isinstance(s, dict):
                bad.append(f"{w} is not an object")
                continue
            n = s.get("name")
            if not isinstance(n, str) or not re.match(r"^[a-z0-9][a-z0-9-]*$", n):
                bad.append(f"{w} name must be lower-case letters, digits and dashes")
            elif n in seen:
                bad.append(f"{w} name {n} is used twice")
            seen.add(n)
            if not str(s.get("route", "")).startswith("/"):
                bad.append(f"{w} route must start with /")
            if s.get("viewport", "laptop") not in ("laptop", "phone"):
                bad.append(f"{w} viewport must be laptop or phone")
            if s.get("theme", "light") not in ("light", "dark"):
                bad.append(f"{w} theme must be light or dark")
            st = s.get("setup", [])
            if not isinstance(st, list) or any(not isinstance(x, str) for x in st):
                bad.append(f"{w} setup must be a list of step sentences")
    for b in bad:
        print(f"evidence-gaps: {b}", file=sys.stderr)
    return 1 if bad else 0


def cmd_classify(_argv):
    n = 0
    for line in sys.stdin:
        if line.strip() and EVIDENCE.search(line):
            sys.stdout.write(line if line.endswith("\n") else line + "\n")
            n += 1
    return 0


def main(argv):
    if not argv:
        die("usage: classify | coverage | routes | plan | check-plan")
    cmd, rest = argv[0], argv[1:]
    table = {"classify": cmd_classify, "coverage": cmd_coverage, "routes": cmd_routes,
             "plan": cmd_plan, "check-plan": cmd_check_plan}
    if cmd not in table:
        die(f"unknown command {cmd}")
    return table[cmd](rest)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
