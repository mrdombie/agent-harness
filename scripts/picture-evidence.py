#!/usr/bin/env python3
"""picture-evidence.py — the evidence a pull request owes comes from its approved picture.

  picture-evidence.py required <mock.html>...             one shot a line: name route viewport theme shows setup (TSV)
  picture-evidence.py routes <mock.html>...               the routes those shots are on, once each
  picture-evidence.py plan [--into <plan.json>] <mock>... a capture plan holding every shot; a shot the
                                                          plan already names keeps the plan's own setup
  picture-evidence.py missing --shots <file|-> <mock>...  the required shots no name in <file> covers
  picture-evidence.py lint <mock.html>...                 the picture's regions and its real-data cover

The builder wrote its own `## Evidence routes` on one pull request and listed the
one region it had built; the approved picture had four, two of them a menu and a
phone frame, and nobody photographed them. So the picture says what is owed, in
markup a machine reads, and nobody downstream chooses:

  <section data-evidence-shot="voice-grid-phone-dark"     lower-case, digits, dashes; the PNG's name
           data-evidence-route="/settings/voices"          where it is
           data-evidence-viewport="phone"                  laptop (1440) or phone (390)
           data-evidence-theme="dark"                      light or dark
           data-evidence-shows="the owner-only lock row"   what a reviewer should see (optional)
           data-evidence-setup='click the "Share" button ;; press Escape'>   steps, ";;" between (optional)

Real data (lint): the picture says which hard cases it draws, on any element,
`data-real-data="duplicate-names longest-names empty scrolled"`, and for a case the
screen cannot have, `data-real-data-na="duplicate-names: the screen lists no people"`
(";;" between several). A case neither drawn nor excused is a gap.

Exit codes: 0 fine · 1 a gap (named on stderr) · 2 could not run · 3 the picture
declares no evidence shots (required/routes/plan/missing), so nothing is derived
from it and the caller says so rather than reading it as "nothing owed".
"""
import json
import re
import sys
from html.parser import HTMLParser

NAME_RE = re.compile(r"^[a-z0-9]+(?:-[a-z0-9]+)*$")
VIEWPORTS = ("laptop", "phone")
THEMES = ("light", "dark")
REAL_DATA = ("duplicate-names", "longest-names", "empty", "scrolled")
STEP_SEP = ";;"


class Picture(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.shots = []
        self.covered = set()
        self.excused = {}

    def handle_starttag(self, tag, attrs):
        a = {k: (v if v is not None else "") for k, v in attrs}
        if "data-evidence-shot" in a:
            self.shots.append({
                "name": a.get("data-evidence-shot", "").strip(),
                "route": a.get("data-evidence-route", "").strip(),
                "viewport": a.get("data-evidence-viewport", "laptop").strip() or "laptop",
                "theme": a.get("data-evidence-theme", "light").strip() or "light",
                "shows": " ".join(a.get("data-evidence-shows", "").split()),
                "setup": [s.strip() for s in a.get("data-evidence-setup", "").split(STEP_SEP) if s.strip()],
            })
        for word in a.get("data-real-data", "").split():
            self.covered.add(word.strip().lower())
        for part in a.get("data-real-data-na", "").split(STEP_SEP):
            if ":" in part:
                case, why = part.split(":", 1)
                if why.strip():
                    self.excused[case.strip().lower()] = why.strip()

    handle_startendtag = handle_starttag


def die(msg):
    print(f"picture-evidence: {msg}", file=sys.stderr)
    sys.exit(2)


def read(paths):
    if not paths:
        die("name at least one picture")
    pic = Picture()
    for p in paths:
        try:
            with open(p, encoding="utf-8") as f:
                pic.feed(f.read())
        except OSError as e:
            die(f"cannot read {p}: {e.strerror}")
    return pic


def unique(shots):
    seen, out = set(), []
    for s in shots:
        if s["name"] in seen:
            continue
        seen.add(s["name"])
        out.append(s)
    return out


def flat(s):
    return " ".join(str(s).split())


def cmd_required(paths):
    shots = unique(read(paths).shots)
    if not shots:
        print("picture-evidence: the picture declares no data-evidence-shot regions", file=sys.stderr)
        return 3
    for s in shots:
        print("\t".join([s["name"], s["route"], s["viewport"], s["theme"], flat(s["shows"]), f" {STEP_SEP} ".join(s["setup"])]))
    return 0


def cmd_routes(paths):
    shots = unique(read(paths).shots)
    if not shots:
        print("picture-evidence: the picture declares no data-evidence-shot regions", file=sys.stderr)
        return 3
    seen = []
    for s in shots:
        if s["route"] and s["route"] not in seen:
            seen.append(s["route"])
    print("\n".join(seen))
    return 0


def cmd_plan(args):
    into = None
    if args[:1] == ["--into"]:
        if len(args) < 2:
            die("--into needs a plan.json path")
        into, args = args[1], args[2:]
    shots = unique(read(args).shots)
    if not shots:
        print("picture-evidence: the picture declares no data-evidence-shot regions", file=sys.stderr)
        return 3
    plan = {"shots": []}
    if into:
        try:
            with open(into, encoding="utf-8") as f:
                plan = json.load(f)
        except FileNotFoundError:
            plan = {"shots": []}
        except (OSError, ValueError) as e:
            die(f"{into} is not a readable capture plan: {e}")
        if not isinstance(plan, dict) or not isinstance(plan.get("shots", []), list):
            die(f"{into} is not a capture plan: no shots list")
        plan.setdefault("shots", [])
    have = {s.get("name") for s in plan["shots"] if isinstance(s, dict)}
    for s in shots:
        if s["name"] in have:
            continue
        shot = {"name": s["name"], "route": s["route"], "viewport": s["viewport"], "theme": s["theme"]}
        if s["setup"]:
            shot["setup"] = s["setup"]
        plan["shots"].append(shot)
    print(json.dumps(plan, indent=2))
    return 0


def cmd_missing(args):
    if args[:1] != ["--shots"] or len(args) < 3:
        die("usage: missing --shots <file|-> <mock.html>...")
    src, paths = args[1], args[2:]
    try:
        text = sys.stdin.read() if src == "-" else open(src, encoding="utf-8").read()
    except OSError as e:
        die(f"cannot read {src}: {e.strerror}")
    # A shot is known by its file name, with or without the folder and extension.
    have = set()
    for line in text.splitlines():
        first = line.split("\t", 1)[0].strip()
        if not first:
            continue
        base = first.rsplit("/", 1)[-1]
        have.add(re.sub(r"\.(png|jpe?g|webp)$", "", base, flags=re.I))
    shots = unique(read(paths).shots)
    if not shots:
        print("picture-evidence: the picture declares no data-evidence-shot regions", file=sys.stderr)
        return 3
    gone = [s for s in shots if s["name"] not in have]
    for s in gone:
        print("\t".join([s["name"], s["route"], s["viewport"], s["theme"], flat(s["shows"])]))
    if gone:
        print(f"picture-evidence: {len(gone)} of {len(shots)} shot(s) the approved picture declares have no pinned shot", file=sys.stderr)
        return 1
    return 0


def cmd_lint(paths):
    pic = read(paths)
    gaps = []
    if not pic.shots:
        gaps.append("it declares no evidence shots: mark each frame with data-evidence-shot, data-evidence-route, data-evidence-viewport and data-evidence-theme")
    names = {}
    for s in pic.shots:
        n = s["name"]
        if not NAME_RE.match(n):
            gaps.append(f"shot '{n}': a name is lower-case letters, digits and dashes")
        names[n] = names.get(n, 0) + 1
        if not s["route"].startswith("/"):
            gaps.append(f"shot '{n}': its route '{s['route']}' does not start with '/'")
        if s["viewport"] not in VIEWPORTS:
            gaps.append(f"shot '{n}': viewport '{s['viewport']}' is not laptop or phone")
        if s["theme"] not in THEMES:
            gaps.append(f"shot '{n}': theme '{s['theme']}' is not light or dark")
    for n, c in names.items():
        if c > 1:
            gaps.append(f"shot '{n}' is declared {c} times: one name, one picture")
    if pic.shots:
        vps = {s["viewport"] for s in pic.shots}
        for vp in VIEWPORTS:
            if vp not in vps:
                gaps.append(f"no {vp} frame: a picture shows the screen on a laptop (1440) and a phone (390)")
    for case in REAL_DATA:
        if case not in pic.covered and case not in pic.excused:
            gaps.append(f"real data: '{case}' is neither drawn (data-real-data) nor excused with a reason (data-real-data-na)")
    for g in gaps:
        print(f"picture-evidence: {g}", file=sys.stderr)
    if gaps:
        return 1
    print(f"picture-evidence: ok — {len(pic.shots)} shot(s), real data drawn: {' '.join(sorted(pic.covered & set(REAL_DATA))) or 'none'}"
          + (f"; excused: {', '.join(sorted(pic.excused))}" if pic.excused else ""))
    return 0


def main(argv):
    if not argv:
        print(__doc__.split("\n\n")[0], file=sys.stderr)
        return 2
    cmd, rest = argv[0], argv[1:]
    if cmd == "required":
        return cmd_required(rest)
    if cmd == "routes":
        return cmd_routes(rest)
    if cmd == "plan":
        return cmd_plan(rest)
    if cmd == "missing":
        return cmd_missing(rest)
    if cmd == "lint":
        return cmd_lint(rest)
    die(f"unknown command '{cmd}' — required|routes|plan|missing|lint")
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
