#!/usr/bin/env python3
"""picture-evidence.py — the evidence a pull request owes comes from its approved picture.

  picture-evidence.py required <mock.html>...             one shot a line: name route viewport theme shows setup (TSV)
  picture-evidence.py routes <mock.html>...               the routes those shots are on, once each
  picture-evidence.py plan [--into <plan.json>] <mock>... a capture plan holding every shot; a shot the
                                                          plan already names keeps the plan's own setup
  picture-evidence.py missing --shots <file|-> <mock>...  the required shots no name in <file> covers
  picture-evidence.py lint <mock.html>...                 the picture's regions and its real-data cover
  picture-evidence.py derivation <mock.html>...           per picture: path, how its regions were found
                                                          (marked | frames | routes | none), how many
  picture-evidence.py scope --files <file|-> <mock>...    per region: name \t changed|untouched|unknown \t
                                                          the changed file that drew it, read off the
                                                          region's data-evidence-files against the diff

Options, before the pictures, on any command:
  --derive              an unmarked picture's regions are derived instead of none (below)
  --route <path>        a route the PR names under `## Evidence routes`; once per route
  --approved <date>     when the picture was approved (YYYY-MM-DD), for lint's real-data rule;
                        "none" when no date is known. Left out, the picture is being drawn now.
  --real-data-from <d>  the first approval date that owes real data (default 2026-10-20)

OLDER PICTURES. Pictures approved before the region convention carry no markers. With
--derive their regions are derived, not failed closed: each outermost frame or screen
the picture draws (an element whose class says frame, screen, artboard, device, phone,
laptop, desktop, mobile or browser) becomes a region named by its id, label, heading or
caption, at laptop and phone and light and dark where the picture draws them (a phone
inside a frame, a dark theme in its styles). A picture with no frames falls back to
every --route at laptop 1440 / phone 390 x light / dark. A derived region is covered by
a CI shot of the same route, viewport and theme, whatever CI named the file, and lint
does not ask a derived picture for the both-widths rule it predates.
scripts/picture-label.py writes the markers into such a picture for good.

REAL DATA, and a laptop and a phone frame, are owed by pictures approved on or after
--real-data-from. The date is the
picture's own data-picture-approved attribute, else --approved; a picture approved
earlier, or with no known date (--approved none), is exempt from lint's real-data refusal. The critic
still grades real data on the built screen.

The builder wrote its own `## Evidence routes` on one pull request and listed the
one region it had built; the approved picture had four, two of them a menu and a
phone frame, and nobody photographed them. So the picture says what is owed, in
markup a machine reads, and nobody downstream chooses:

  <section data-evidence-shot="voice-grid-phone-dark"     lower-case, digits, dashes; the PNG's name
           data-evidence-route="/settings/voices"          where it is
           data-evidence-viewport="phone"                  laptop (1440) or phone (390)
           data-evidence-theme="dark"                      light or dark
           data-evidence-shows="the owner-only lock row"   what a reviewer should see (optional)
           data-evidence-setup='click the "Share" button ;; press Escape'   steps, ";;" between (optional)
           data-evidence-files="apps/web/voices/** apps/web/ui/Grid.tsx">   the source that draws it (optional)

SCOPE. A check judges only what the change changed: on one PR every critic finding sat
on a part of a shared screen the PR never touched, and the repair parked on them. A
region's data-evidence-files (globs, space-separated; `**` any depth, `*` one segment,
a bare directory everything under it) names the files and component folders that draw
it. `scope` holds them against the PR's changed files: changed when one matches,
untouched when none does, unknown when the region names no files (a derived region, or
an older picture) — the judge then reads unknown as changed, never as a pass.

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
DATE_RE = re.compile(r"^\d{4}-\d{2}-\d{2}")
VIEWPORTS = ("laptop", "phone")
THEMES = ("light", "dark")
REAL_DATA = ("duplicate-names", "longest-names", "empty", "scrolled")
REAL_DATA_FROM = "2026-10-20"
STEP_SEP = ";;"
FRAME_WORDS = {"frame", "screen", "artboard", "device", "phone", "laptop", "desktop", "mobile", "browser"}
FRAME_ATTRS = ("data-frame", "data-screen", "data-artboard")
PHONE_WORDS = {"phone", "mobile", "iphone", "android", "handset", "390"}
DARK_WORDS = {"dark", "theme-dark", "dark-mode", "is-dark"}
CAPTION_WORDS = {"caption", "title", "label", "frame-h", "frame-title", "frame-label", "frame-name"}
NAME_KEYS = ("data-name", "data-label", "data-title", "aria-label")
VOID = {"area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "param", "source", "track", "wbr"}
DARK_CSS = re.compile(r"prefers-color-scheme\s*:\s*dark|data-theme\s*=\s*['\"]?dark")
# A phone is drawn 320 to 480 wide; narrower is an icon or a dot, wider a laptop.
PHONE_MIN, PHONE_MAX = 320, 480
WIDTH_DECL = re.compile(r"(?:^|[;{\s])(?:max-)?width\s*:\s*(\d+(?:\.\d+)?)px", re.I)
STYLE_BLOCK = re.compile(r"<style\b[^>]*>(.*?)</style>", re.I | re.S)
CSS_RULE = re.compile(r"([^{}]+)\{([^{}]*)\}")
COMPOUND = re.compile(r"^([a-z][a-z0-9-]*)?((?:[.#][a-zA-Z0-9_-]+)+)$|^([a-z][a-z0-9-]*)$")


def words(a):
    return set((a.get("class") or "").lower().split())


def tokens(text):
    return set(re.split(r"[^a-z0-9]+", (text or "").lower()))


def is_frame(a):
    return bool(words(a) & FRAME_WORDS) or any(k in a for k in FRAME_ATTRS)


def phone_wide(decls):
    """True when declarations draw a phone's width (PHONE_MIN..PHONE_MAX px)."""
    m = WIDTH_DECL.search(decls or "")
    return bool(m) and PHONE_MIN <= float(m.group(1)) <= PHONE_MAX


def narrow_selectors(html):
    """[(tag, classes, id)] for each single-compound selector a <style> block draws phone-wide.
    Combinator selectors (".ph .rail") are skipped: they size a child, not the frame."""
    out = []
    for block in STYLE_BLOCK.findall(html or ""):
        block = re.sub(r"/\*.*?\*/", "", block, flags=re.S)
        for sel, decls in CSS_RULE.findall(block):
            if not phone_wide(decls):
                continue
            for one in sel.split(","):
                one = one.strip()
                m = COMPOUND.match(one)
                if not m:
                    continue
                tag = (m.group(1) or m.group(3) or "").lower()
                parts = re.findall(r"([.#])([a-zA-Z0-9_-]+)", m.group(2) or "")
                out.append((tag, {v.lower() for k, v in parts if k == "."}, next((v for k, v in parts if k == "#"), None)))
    return out


def css_phone(tag, a, narrow):
    cls = words(a)
    return any((not t or t == tag) and c <= cls and (i is None or i == a.get("id")) and (t or c or i)
               for t, c, i in narrow)


def is_phone(a, tag="", narrow=()):
    if (words(a) | tokens(a.get("id"))) & PHONE_WORDS or (a.get("data-viewport") or "").lower() == "phone":
        return True
    return phone_wide(a.get("style")) or css_phone(tag, a, narrow)


def is_dark(a, own):
    if (a.get("data-theme") or "").lower() == "dark":
        return True
    # A bare "dark" class inside a frame is a dark button, not a dark frame.
    return bool(words(a) & (DARK_WORDS if own else DARK_WORDS - {"dark"}))


def slug(text):
    return re.sub(r"-+", "-", re.sub(r"[^a-z0-9]+", "-", (text or "").lower())).strip("-")[:40].strip("-")


class Picture(HTMLParser):
    """The markers a picture carries, and the outermost frames it draws."""

    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.shots = []
        self.covered = set()
        self.excused = {}
        self.approved = ""
        self.frames = []
        self.dark_css = False
        self.narrow = []       # the <style> selectors that draw a phone's width
        self._stack = []       # [tag, frame or None]
        self._caption = None   # [frame, depth] while a frame's first heading or caption is read

    def feed(self, data):
        # Read first: a frame is sized by a rule in <style>, often far from the frame.
        self.narrow += narrow_selectors(data)
        super().feed(data)

    def _outer(self):
        for _, f in reversed(self._stack):
            if f is not None:
                return f
        return None

    def _take(self, a):
        if DATE_RE.match(a.get("data-picture-approved", "")) and not self.approved:
            self.approved = a["data-picture-approved"][:10]
        if "data-evidence-shot" in a:
            self.shots.append({
                "name": a.get("data-evidence-shot", "").strip(),
                "route": a.get("data-evidence-route", "").strip(),
                "viewport": a.get("data-evidence-viewport", "laptop").strip() or "laptop",
                "theme": a.get("data-evidence-theme", "light").strip() or "light",
                "shows": " ".join(a.get("data-evidence-shows", "").split()),
                "setup": [s.strip() for s in a.get("data-evidence-setup", "").split(STEP_SEP) if s.strip()],
                "files": a.get("data-evidence-files", "").split(),
            })
        for word in a.get("data-real-data", "").split():
            self.covered.add(word.strip().lower())
        for part in a.get("data-real-data-na", "").split(STEP_SEP):
            if ":" in part:
                case, why = part.split(":", 1)
                if why.strip():
                    self.excused[case.strip().lower()] = why.strip()

    def _where(self):
        return self.getpos(), self.get_starttag_text() or ""

    def _see(self, tag, a, closes):
        self._take(a)
        outer, mine = self._outer(), None
        if outer is None and is_frame(a):
            pos, raw = self._where()
            mine = {"attrs": a, "pos": pos, "raw": raw, "caption": "", "phone": is_phone(a, tag, self.narrow),
                    "inner_phone": None, "dark": is_dark(a, True), "dark_inside": False}
            self.frames.append(mine)
        elif outer is not None:
            if is_phone(a, tag, self.narrow) and not outer["phone"] and outer["inner_phone"] is None:
                pos, raw = self._where()
                outer["inner_phone"] = {"attrs": a, "pos": pos, "raw": raw}
            if is_dark(a, False):
                outer["dark_inside"] = True
            if (not closes and not outer["caption"] and self._caption is None
                    and (tag in ("h1", "h2", "h3", "h4", "figcaption", "caption") or words(a) & CAPTION_WORDS)):
                self._caption = [outer, len(self._stack) + 1]
        if not closes and tag not in VOID:
            self._stack.append([tag, mine])

    def handle_starttag(self, tag, attrs):
        self._see(tag, {k: (v if v is not None else "") for k, v in attrs}, False)

    def handle_startendtag(self, tag, attrs):
        self._see(tag, {k: (v if v is not None else "") for k, v in attrs}, True)

    def handle_endtag(self, tag):
        for i in range(len(self._stack) - 1, -1, -1):
            if self._stack[i][0] == tag:
                del self._stack[i:]
                break
        if self._caption is not None and len(self._stack) < self._caption[1]:
            self._caption = None

    def handle_data(self, data):
        if self._stack and self._stack[-1][0] == "style" and DARK_CSS.search(data):
            self.dark_css = True
        if self._caption is not None:
            f = self._caption[0]
            f["caption"] = " ".join((f["caption"] + " " + data).split())[:80]


def die(msg):
    print(f"picture-evidence: {msg}", file=sys.stderr)
    sys.exit(2)


def load(path):
    pic = Picture()
    try:
        with open(path, encoding="utf-8") as f:
            pic.feed(f.read())
        pic.close()
    except OSError as e:
        die(f"cannot read {path}: {e.strerror}")
    return pic


def frame_name(f, i):
    a = f["attrs"]
    for v in [a.get("id")] + [a.get(k) for k in NAME_KEYS] + [f["caption"]]:
        if slug(v):
            return slug(v)
    return f"frame-{i + 1}"


def frame_regions(pic, routes):
    """[(frame, element, name, route, viewport, theme)] for each outermost frame: the
    element is the frame itself, or for its phone the phone drawn inside it."""
    out = []
    for i, f in enumerate(pic.frames):
        base, a = frame_name(f, i), f["attrs"]
        route = next((r for r in (a.get("data-evidence-route"), a.get("data-route")) if (r or "").startswith("/")),
                     routes[0] if routes else "")
        if f["phone"] or tokens(f["caption"]) & PHONE_WORDS:   # "Phone · 390 wide" names a phone frame
            views = [("phone", f)]
        else:
            views = [("laptop", f)] + ([("phone", f["inner_phone"])] if f["inner_phone"] else [])
        themes = ["dark"] if f["dark"] else ["light"] + (["dark"] if f["dark_inside"] or pic.dark_css else [])
        for vp, el in views:
            for th in themes:
                out.append((f, el, f"{base}-{vp}-{th}", route, vp, th))
    return out


def derive(pic, routes):
    """(shots, how): the regions of an unmarked picture, by its frames, else by the routes."""
    rows = frame_regions(pic, routes)
    if rows:
        how = "frames"
        shots = [{"name": n, "route": r, "viewport": vp, "theme": th,
                  "shows": f"the frame '{f['caption'] or n}' (derived)", "setup": [], "derived": True}
                 for f, _, n, r, vp, th in rows]
    elif routes:
        how = "routes"
        shots = [{"name": f"{slug(r) or 'root'}-{vp}-{th}", "route": r, "viewport": vp, "theme": th,
                  "shows": f"{r} (derived from the PR's evidence routes)", "setup": [], "derived": True}
                 for r in routes for vp in VIEWPORTS for th in THEMES]
    else:
        return [], "none"
    # One photograph per page state: frames on the same route with the same setup, width
    # and theme are the same shot however many the picture draws.
    same, kept = set(), []
    for s in shots:
        k = (s["route"], tuple(s["setup"]), s["viewport"], s["theme"])
        if k not in same:
            same.add(k)
            kept.append(s)
    shots = kept
    seen = {}
    for s in shots:
        n = s["name"]
        seen[n] = seen.get(n, 0) + 1
        if seen[n] > 1:
            s["name"] = f"{n}-{seen[n]}"
    return shots, how


class Opts:
    def __init__(self):
        self.derive = False
        self.routes = []
        self.approved = "today"   # lint at drawing time: a picture being drawn owes real data
        self.real_data_from = REAL_DATA_FROM


def opts_of(args):
    o, rest, i = Opts(), [], 0
    while i < len(args):
        a = args[i]
        if a == "--derive":
            o.derive = True
        elif a in ("--route", "--approved", "--real-data-from"):
            if i + 1 >= len(args):
                die(f"{a} needs a value")
            v = args[i + 1].strip()
            i += 1
            if a == "--route":
                if v.startswith("/") and v not in o.routes:
                    o.routes.append(v)
            elif a == "--approved":
                o.approved = v[:10] if DATE_RE.match(v) else ("today" if v == "today" else "")   # "none": no date known
            elif DATE_RE.match(v):
                o.real_data_from = v[:10]
            else:
                die(f"--real-data-from wants YYYY-MM-DD, not '{v}'")
        else:
            rest.append(a)
        i += 1
    return o, rest


class Read:
    """Every picture named, each derived on its own."""

    def __init__(self, paths, o):
        if not paths:
            die("name at least one picture")
        self.shots, self.covered, self.excused, self.each = [], set(), {}, []
        for p in paths:
            pic = load(p)
            if pic.shots:
                shots, how = pic.shots, "marked"
            elif o.derive:
                shots, how = derive(pic, o.routes)
            else:
                shots, how = [], "none"
            self.shots += shots
            self.covered |= pic.covered
            self.excused.update(pic.excused)
            self.each.append({"path": p, "how": how, "n": len(shots), "pic": pic, "shots": shots})


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


def no_regions():
    print("picture-evidence: the picture declares no data-evidence-shot regions", file=sys.stderr)
    return 3


def cmd_required(paths, o):
    shots = unique(Read(paths, o).shots)
    if not shots:
        return no_regions()
    for s in shots:
        print("\t".join([s["name"], s["route"], s["viewport"], s["theme"], flat(s["shows"]), f" {STEP_SEP} ".join(s["setup"])]))
    return 0


def cmd_routes(paths, o):
    shots = unique(Read(paths, o).shots)
    if not shots:
        return no_regions()
    seen = []
    for s in shots:
        if s["route"] and s["route"] not in seen:
            seen.append(s["route"])
    print("\n".join(seen))
    return 0


def cmd_plan(args, o):
    into = None
    if args[:1] == ["--into"]:
        if len(args) < 2:
            die("--into needs a plan.json path")
        into, args = args[1], args[2:]
    shots = unique(Read(args, o).shots)
    if not shots:
        return no_regions()
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
        if s["name"] in have or not s["route"]:
            continue
        shot = {"name": s["name"], "route": s["route"], "viewport": s["viewport"], "theme": s["theme"]}
        if s["setup"]:
            shot["setup"] = s["setup"]
        plan["shots"].append(shot)
    print(json.dumps(plan, indent=2))
    return 0


def shot_of(line):
    """A pinned shot: its name, and the route, viewport and theme it shows."""
    cols = line.split("\t")
    base = cols[0].strip().rsplit("/", 1)[-1]
    name = re.sub(r"\.(png|jpe?g|webp)$", "", base, flags=re.I)
    t = tokens(name)
    theme = cols[2].strip() if len(cols) > 2 and cols[2].strip() in THEMES else ("dark" if "dark" in t else "light")
    route = cols[3].strip() if len(cols) > 3 and cols[3].strip().startswith("/") else ""
    return {"name": name, "route": route, "viewport": "phone" if t & PHONE_WORDS else "laptop", "theme": theme}


def covers(shot, region):
    if shot["name"] == region["name"]:
        return True
    if not region.get("derived") or shot["viewport"] != region["viewport"] or shot["theme"] != region["theme"]:
        return False
    r = region["route"]
    if not r:
        return False
    if shot["route"] == r:
        return True
    rs = slug(r)
    return bool(rs) and (shot["name"] == rs or shot["name"].startswith(rs + "-"))


def cmd_missing(args, o):
    if args[:1] != ["--shots"] or len(args) < 3:
        die("usage: missing --shots <file|-> <mock.html>...")
    src, paths = args[1], args[2:]
    try:
        text = sys.stdin.read() if src == "-" else open(src, encoding="utf-8").read()
    except OSError as e:
        die(f"cannot read {src}: {e.strerror}")
    have = [shot_of(l) for l in text.splitlines() if l.split("\t", 1)[0].strip()]
    shots = unique(Read(paths, o).shots)
    if not shots:
        return no_regions()
    gone = [s for s in shots if not any(covers(h, s) for h in have)]
    for s in gone:
        print("\t".join([s["name"], s["route"], s["viewport"], s["theme"], flat(s["shows"])]))
    if gone:
        print(f"picture-evidence: {len(gone)} of {len(shots)} shot(s) the approved picture declares have no pinned shot", file=sys.stderr)
        return 1
    return 0


def owes_real_data(pic, o):
    """(owed, why): a picture approved before the cut-off, or on no known date, is exempt."""
    date = pic.approved or o.approved
    if date == "today":
        return True, "being drawn now"
    if not date:
        return False, "no approval date known"
    if date < o.real_data_from:
        return False, f"approved {date}, before {o.real_data_from}"
    return True, f"approved {date}"


def cmd_lint(paths, o):
    r = Read(paths, o)
    gaps, notes = [], []
    if not r.shots:
        gaps.append("it declares no evidence shots: mark each frame with data-evidence-shot, data-evidence-route, data-evidence-viewport and data-evidence-theme")
    names = {}
    for s in r.shots:
        n = s["name"]
        if not NAME_RE.match(n):
            gaps.append(f"shot '{n}': a name is lower-case letters, digits and dashes")
        names[n] = names.get(n, 0) + 1
        if s.get("derived") and not s["route"]:
            gaps.append(f"derived region '{n}': no route — name the screen under the PR's '## Evidence routes'")
        elif not s["route"].startswith("/"):
            gaps.append(f"shot '{n}': its route '{s['route']}' does not start with '/'")
        if s["viewport"] not in VIEWPORTS:
            gaps.append(f"shot '{n}': viewport '{s['viewport']}' is not laptop or phone")
        if s["theme"] not in THEMES:
            gaps.append(f"shot '{n}': theme '{s['theme']}' is not light or dark")
    for n, c in names.items():
        if c > 1:
            gaps.append(f"shot '{n}' is declared {c} times: one name, one picture")
    # Both widths is a drawing rule, like real data: owed by a marked picture drawn under it.
    owed = [e for e in r.each if owes_real_data(e["pic"], o)[0]]
    drawn = [s for e in owed if e["how"] == "marked" for s in e["shots"]]
    if drawn:
        vps = {s["viewport"] for s in drawn}
        for vp in VIEWPORTS:
            if vp not in vps:
                gaps.append(f"no {vp} frame: a picture shows the screen on a laptop (1440) and a phone (390)")
    for e in r.each:
        if e["how"] in ("frames", "routes"):
            notes.append(f"{e['path']}: {e['n']} region(s) derived from its {e['how']}")
        due, why = owes_real_data(e["pic"], o)
        if not due:
            notes.append(f"{e['path']}: real data exempt — {why}")
    if owed:
        for case in REAL_DATA:
            if case not in r.covered and case not in r.excused:
                gaps.append(f"real data: '{case}' is neither drawn (data-real-data) nor excused with a reason (data-real-data-na)")
    for g in gaps:
        print(f"picture-evidence: {g}", file=sys.stderr)
    for n in notes:
        print(f"picture-evidence: note: {n}", file=sys.stderr)
    if gaps:
        return 1
    print(f"picture-evidence: ok — {len(r.shots)} shot(s), real data drawn: {' '.join(sorted(r.covered & set(REAL_DATA))) or 'none'}"
          + (f"; excused: {', '.join(sorted(r.excused))}" if r.excused else ""))
    return 0


def glob_re(g):
    """A data-evidence-files glob as a regex: `**` any depth, `*` and `?` within a segment,
    a pattern with no wildcard the file itself or everything under it."""
    g = g.strip()
    g = g[2:] if g.startswith("./") else g
    if not any(c in g for c in "*?["):
        return re.compile(re.escape(g.rstrip("/")) + r"(?:/.*)?$")
    out, i = "", 0
    while i < len(g):
        if g.startswith("**/", i):
            out, i = out + r"(?:.*/)?", i + 3
        elif g.startswith("**", i):
            out, i = out + r".*", i + 2
        elif g[i] == "*":
            out, i = out + r"[^/]*", i + 1
        elif g[i] == "?":
            out, i = out + r"[^/]", i + 1
        else:
            out, i = out + re.escape(g[i]), i + 1
    return re.compile(out + "$")


def cmd_scope(args, o):
    if args[:1] != ["--files"] or len(args) < 3:
        die("usage: scope --files <file|-> <mock.html>...")
    src, paths = args[1], args[2:]
    try:
        text = sys.stdin.read() if src == "-" else open(src, encoding="utf-8").read()
    except OSError as e:
        die(f"cannot read {src}: {e.strerror}")
    changed = [l.strip() for l in text.splitlines() if l.strip()]
    shots = unique(Read(paths, o).shots)
    if not shots:
        return no_regions()
    for s in shots:
        globs = s.get("files") or []
        if not globs:
            print(f"{s['name']}\tunknown\t")
            continue
        res = [glob_re(g) for g in globs]
        hit = next((f for f in changed if any(r.match(f) for r in res)), "")
        print(f"{s['name']}\t{'changed' if hit else 'untouched'}\t{hit}")
    return 0


def cmd_derivation(paths, o):
    for e in Read(paths, o).each:
        print(f"{e['path']}\t{e['how']}\t{e['n']}")
    return 0


def main(argv):
    if not argv:
        print(__doc__.split("\n\n")[0], file=sys.stderr)
        return 2
    cmd = argv[0]
    o, rest = opts_of(argv[1:])
    if cmd == "required":
        return cmd_required(rest, o)
    if cmd == "routes":
        return cmd_routes(rest, o)
    if cmd == "plan":
        return cmd_plan(rest, o)
    if cmd == "missing":
        return cmd_missing(rest, o)
    if cmd == "lint":
        return cmd_lint(rest, o)
    if cmd == "derivation":
        return cmd_derivation(rest, o)
    if cmd == "scope":
        return cmd_scope(rest, o)
    die(f"unknown command '{cmd}' — required|routes|plan|missing|lint|derivation|scope")
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
