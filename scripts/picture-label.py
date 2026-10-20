#!/usr/bin/env python3
"""picture-label.py — label an older approved picture's frames as evidence regions, for good.

  picture-label.py [--route <path>]... [--approved <YYYY-MM-DD>] [--dry-run] <picture.html>

Pictures approved before the region convention (shared/picture-rules.md) draw their
frames with no data-evidence-* markers, so the judge derives the regions every time
(scripts/picture-evidence.py --derive). This writes those regions into the picture:
on each outermost frame, and on a phone drawn inside one, it adds

  data-evidence-shot  data-evidence-route  data-evidence-viewport  data-evidence-theme

and, with --approved, data-picture-approved on the first frame it labels. It adds
ATTRIBUTES ONLY, inside the start tags it labels: no element, no text, no style
changes, so nothing the picture renders changes. It checks that before it writes —
the labelled file with the added attributes taken out must be the original, byte for
byte — and prints the diff. --dry-run prints the diff and writes nothing.

A frame's route is its own data-route, else the first --route. One element carries one
region, so a dark theme drawn only by the page's colour-scheme switch is not labelled;
add a dark frame by hand where the PR owes a dark shot. A picture that already carries
markers is left alone.

Exit codes: 0 labelled (or already labelled) · 1 nothing to label (no frames, or no
route for one) · 2 could not run.
"""
import difflib
import html
import importlib.util
import os
import sys


def load_pe():
    sys.dont_write_bytecode = True   # no __pycache__ left in the kit
    here = os.path.dirname(os.path.abspath(__file__))
    spec = importlib.util.spec_from_file_location("picture_evidence", os.path.join(here, "picture-evidence.py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def die(msg, code=2):
    print(f"picture-label: {msg}", file=sys.stderr)
    sys.exit(code)


def offset_of(src, pos):
    line, col = pos
    off = 0
    for _ in range(line - 1):
        off = src.index("\n", off) + 1
    return off + col


def main(argv):
    routes, approved, dry, paths, i = [], "", False, [], 0
    while i < len(argv):
        a = argv[i]
        if a == "--dry-run":
            dry = True
        elif a in ("--route", "--approved"):
            if i + 1 >= len(argv):
                die(f"{a} needs a value")
            i += 1
            if a == "--route":
                routes.append(argv[i])
            else:
                approved = argv[i]
        elif a.startswith("-"):
            die(f"unknown option {a}")
        else:
            paths.append(a)
        i += 1
    if len(paths) != 1:
        die("usage: picture-label.py [--route <path>]... [--approved <YYYY-MM-DD>] [--dry-run] <picture.html>")
    pe = load_pe()
    if approved and not pe.DATE_RE.match(approved):
        die(f"--approved wants YYYY-MM-DD, not '{approved}'")
    for r in routes:
        if not r.startswith("/"):
            die(f"a route starts with '/': '{r}'")
    path = paths[0]
    try:
        with open(path, encoding="utf-8", newline="") as f:
            src = f.read()
    except OSError as e:
        die(f"cannot read {path}: {e.strerror}")
    pic = pe.Picture()
    pic.feed(src)
    pic.close()
    if pic.shots:
        print(f"picture-label: {path} already carries {len(pic.shots)} region(s) — left as it is")
        return 0
    rows = pe.frame_regions(pic, routes)
    if not rows:
        die(f"{path} draws no frame this can find (class frame, screen, artboard, device, phone, laptop, desktop, "
            "mobile or browser) — the judge falls back to the PR's evidence routes; mark the frames by hand", 1)

    # One element, one region: the first of each element's regions in the derived order.
    picked, seen_el = [], set()
    for f, el, name, route, vp, th in rows:
        key = el["pos"]
        if key in seen_el:
            continue
        seen_el.add(key)
        picked.append((el, name, route, vp, th))
    unrouted = [n for _, n, r, _, _ in picked if not r]
    if unrouted:
        die(f"no route for {', '.join(unrouted)}: name the screen with --route /path", 1)

    inserts = []
    for k, (el, name, route, vp, th) in enumerate(picked):
        off = offset_of(src, el["pos"])
        raw = el["raw"]
        if src[off:off + len(raw)] != raw:
            die(f"could not place the start tag of '{name}' in the source — nothing written")
        end = off + len(raw) - (2 if raw.endswith("/>") else 1)
        attrs = (f' data-evidence-shot="{html.escape(name)}" data-evidence-route="{html.escape(route)}"'
                 f' data-evidence-viewport="{vp}" data-evidence-theme="{th}"')
        if k == 0 and approved:
            attrs += f' data-picture-approved="{approved}"'
        inserts.append((end, attrs))
    out = src
    for end, attrs in sorted(inserts, reverse=True):
        out = out[:end] + attrs + out[end:]

    # NOTHING IT RENDERS CHANGES: take the added attributes back out and it is the original.
    # Ascending: with the earlier ones gone, each sits at its place in the original.
    back = out
    for end, attrs in sorted(inserts):
        if back[end:end + len(attrs)] != attrs:
            die("an added attribute is not where it was put — nothing written")
        back = back[:end] + back[end + len(attrs):]
    if back != src:
        die("the labelled picture is not the original plus attributes — nothing written")
    check = pe.Picture()
    check.feed(out)
    check.close()
    if len(check.shots) != len(picked):
        die(f"the labelled picture reads {len(check.shots)} region(s), not {len(picked)} — nothing written")

    diff = difflib.unified_diff(src.splitlines(keepends=True), out.splitlines(keepends=True),
                                fromfile=path, tofile=f"{path} (labelled)")
    sys.stdout.writelines(diff)
    if not dry:
        with open(path, "w", encoding="utf-8", newline="") as f:
            f.write(out)
    themes = {th for *_, th in picked}
    drawn_dark = any(f["dark_inside"] for f in pic.frames) or pic.dark_css
    print(f"picture-label: {len(picked)} region(s) {'would be ' if dry else ''}labelled in {path}"
          + ("; its dark theme is drawn by the colour-scheme switch, so no dark region is labelled — add one by hand where a dark shot is owed"
             if drawn_dark and "dark" not in themes else ""), file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
