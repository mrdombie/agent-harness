#!/usr/bin/env python3
"""Draw report.html for one panel run.

Usage: panel-report.py <run-folder> [--bar 70]

Reads scores.tsv (and scores-before.tsv if present) with columns
panel reviewer n cluster verdict_a verdict_b verdict ticket ask evidence
and writes <run-folder>/report.html. Every number on the page is counted
from those files here; nothing is typed in by hand.
"""
import csv, collections, html, os, sys

E = html.escape
V = ['ANSWERED', 'PARTIAL', 'MISSING', 'NOT_IN_SCOPE']


def load(path):
    if not os.path.exists(path):
        return None
    rows = list(csv.DictReader(open(path), delimiter='\t'))
    for r in rows:  # older runs called the fourth verdict after the area they were written for
        for k in ('verdict', 'verdict_a', 'verdict_b'):
            if r.get(k, '').startswith('NOT_') and r[k] != 'NOT_IN_SCOPE':
                r[k] = 'NOT_IN_SCOPE'
    return rows


def pct(rows):
    return round(100 * sum(r['verdict'] == 'ANSWERED' for r in rows) / len(rows)) if rows else 0


def main():
    run = sys.argv[1].rstrip('/')
    bar = int(sys.argv[sys.argv.index('--bar') + 1]) if '--bar' in sys.argv else 70
    now, before = load(run + '/scores.tsv'), load(run + '/scores-before.tsv')
    if not now:
        sys.exit('no scores.tsv in ' + run)
    title = open(run + '/subject.md').readline().lstrip('# ').strip() if os.path.exists(run + '/subject.md') else os.path.basename(run)
    panels = collections.OrderedDict()
    for r in now:
        panels.setdefault(r['panel'], []).append(r)
    bpanels = collections.defaultdict(list)
    for r in before or []:
        bpanels[r['panel']].append(r)

    gate_rows, blocks = [], []
    for panel, rows in panels.items():
        p, bp = pct(rows), (pct(bpanels[panel]) if bpanels[panel] else None)
        passed = p >= bar
        gate_rows.append(f'<tr><td>{E(panel.title())}</td><td>{len(rows)}</td><td>{"" if bp is None else str(bp) + "% → "}<b>{p}%</b></td><td class="{"ok" if passed else "bad"}">{"passes" if passed else "stops the build"}</td></tr>')
        c = collections.Counter(r['verdict'] for r in rows)
        # by reviewer
        who = collections.OrderedDict()
        for r in rows:
            who.setdefault(r['reviewer'], collections.Counter())[r['verdict']] += 1
        bwho = collections.defaultdict(collections.Counter)
        for r in bpanels[panel]:
            bwho[r['reviewer']][r['verdict']] += 1
        wrows = ''.join(f'<tr><td>{E(k)}</td><td>{sum(v.values())}</td><td>{(str(bwho[k]["ANSWERED"]) + " → ") if bpanels[panel] else ""}<b>{v["ANSWERED"]}</b></td><td>{v["MISSING"]}</td></tr>' for k, v in who.items())
        # clusters
        cl = collections.OrderedDict()
        for r in rows:
            cl.setdefault(r['cluster'], collections.Counter())[r['verdict']] += 1
        order = sorted(cl.items(), key=lambda kv: -sum(kv[1].values()))
        mx = max(sum(v.values()) for _, v in order)
        bars = ''.join(
            f'<div class="brow"><div class="lab"><b>{E(k)}</b></div><div class="track" style="width:{sum(v.values()) / mx * 100:.1f}%">'
            + ''.join(f'<i class="{cls}" style="flex:{v[vv]}"></i>' for cls, vv in [('a', 'ANSWERED'), ('p', 'PARTIAL'), ('m', 'MISSING'), ('n', 'NOT_IN_SCOPE')])
            + f'</div><div class="num">{v["ANSWERED"]}/{sum(v.values())}</div></div>' for k, v in order)
        # missing, grouped
        miss = collections.OrderedDict()
        for r in rows:
            if r['verdict'] == 'MISSING':
                miss.setdefault(r['cluster'], []).append(r)
        mhtml = ''.join('<div class="gap"><b>' + E(k) + ' · ' + str(len(v)) + '</b>' + ''.join(
            f'<p class="q">“{E(r["ask"])}”<small>{E(r["reviewer"])} {E(r["n"])}{" · planned in #" + E(r["ticket"]) if r["ticket"] not in ("", "-") else " · not planned"}</small></p>' for r in v[:6])
            + (f'<p class="note">and {len(v) - 6} more</p>' if len(v) > 6 else '') + '</div>' for k, v in sorted(miss.items(), key=lambda kv: -len(kv[1])))
        # scorer disagreements
        dis = [r for r in rows if r['verdict_b'] and r['verdict_a'] != r['verdict_b']]
        dhtml = ''.join(f'<tr><td>{E(r["reviewer"])} {E(r["n"])}</td><td>{E(r["ask"])}</td><td>{E(r["verdict_a"].lower())} / {E(r["verdict_b"].lower())}</td></tr>' for r in dis[:40])
        blocks.append(f'''<section><h2>{E(panel.title())}</h2>
<div class="stats"><div class="s"><b>{c["ANSWERED"]}</b><span>answered</span></div><div class="s"><b>{c["PARTIAL"]}</b><span>partly</span></div><div class="s bad"><b>{c["MISSING"]}</b><span>missing</span></div><div class="s"><b>{c["NOT_IN_SCOPE"]}</b><span>not this area's job</span></div></div>
<div class="tw"><table><thead><tr><th>Reviewer</th><th>Questions</th><th>Answered</th><th>Missing</th></tr></thead><tbody>{wrows}</tbody></table></div>
<div class="key"><span><i class="a"></i>answered</span><span><i class="p"></i>partly</span><span><i class="m"></i>missing</span><span><i class="n"></i>not this area's job</span></div><div>{bars}</div>
{('<h3>Still missing</h3><div class="gaps">' + mhtml + '</div>') if miss else ''}
{('<h3>Where the two scorers disagreed — ' + str(len(dis)) + '</h3><div class="tw"><table><thead><tr><th>Who</th><th>Question</th><th>Scorer A / B</th></tr></thead><tbody>' + dhtml + '</tbody></table></div>') if dis else ''}
</section>''')

    all_pass = all(pct(rows) >= bar for rows in panels.values())
    pr = ''
    if os.path.exists(run + '/principal.md'):
        lines = [l.strip() for l in open(run + '/principal.md') if l.strip()]
        pr = '<section><h2>The principal\'s read</h2>' + ''.join(f'<p class="note" style="font-size:.98rem;color:var(--ink)">{E(l)}</p>' for l in lines) + '</section>'
    doc = f'''<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>{E(title)}</title>
<link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=Geist:wght@400;500;600;700&display=swap"><style>
:root{{--paper:#fffcf7;--card:#fff6e6;--ink:#1a2940;--soft:#51607a;--faint:#606b80;--rule:#e3cfc0;--good:#0a754d;--mango:#ffc857;--crit:#b91c1c;--ember:#a8400a;--na:#c9bfb2}}
@media (prefers-color-scheme:dark){{:root:not([data-theme="light"]){{--paper:#1c1309;--card:#2a1c10;--ink:#f5f1ea;--soft:#c9bfb2;--faint:#a89e8f;--rule:#54391f;--good:#4ccf94;--crit:#f87171;--ember:#ff8a4c;--na:#54391f}}}}
:root[data-theme="dark"]{{--paper:#1c1309;--card:#2a1c10;--ink:#f5f1ea;--soft:#c9bfb2;--faint:#a89e8f;--rule:#54391f;--good:#4ccf94;--crit:#f87171;--ember:#ff8a4c;--na:#54391f}}
*{{box-sizing:border-box}}body{{margin:0;background:var(--paper);color:var(--ink);font-family:Geist,system-ui,sans-serif;font-size:16px;line-height:1.5}}
main{{max-width:980px;margin:0 auto;padding:40px 20px 90px;display:grid;gap:36px}}h1,h2,h3{{margin:0;line-height:1.15;text-wrap:balance}}h1{{font-size:2.1rem;letter-spacing:-.02em}}h2{{font-size:1.35rem}}h3{{font-size:1.05rem;margin-top:8px}}p{{margin:0}}
.eb{{font-size:.75rem;letter-spacing:.1em;text-transform:uppercase;color:var(--faint)}}section{{display:grid;gap:14px;border-top:1px solid var(--rule);padding-top:26px}}
.verdict{{font-weight:700;padding:8px 14px;border-radius:10px;justify-self:start}}.pass{{background:color-mix(in srgb,var(--good) 12%,transparent);color:var(--good)}}.stop{{background:color-mix(in srgb,var(--crit) 12%,transparent);color:var(--crit)}}
.stats{{display:grid;grid-template-columns:repeat(auto-fit,minmax(140px,1fr));gap:10px}}.s{{background:var(--card);border:1px solid var(--rule);border-radius:12px;padding:12px 14px;display:grid}}.s b{{font-size:1.8rem;line-height:1.05;font-variant-numeric:tabular-nums}}.s span{{color:var(--soft);font-size:.88rem}}.s.bad b{{color:var(--crit)}}
table{{border-collapse:collapse;width:100%;font-size:.93rem}}td,th{{text-align:left;padding:8px 10px;border-bottom:1px solid var(--rule);vertical-align:top}}th{{font-size:.78rem;color:var(--faint);font-weight:500}}.tw{{overflow-x:auto}}td.ok{{color:var(--good);font-weight:600}}td.bad{{color:var(--crit);font-weight:600}}
.key{{display:flex;gap:14px;flex-wrap:wrap;font-size:.84rem;color:var(--soft)}}.key i{{display:inline-block;width:12px;height:12px;border-radius:3px;margin-right:6px;vertical-align:-1px}}
.brow{{display:grid;grid-template-columns:230px 1fr 52px;gap:12px;align-items:center;padding:5px 0}}.lab b{{font-size:.9rem;font-weight:600}}.track{{display:flex;height:15px;border-radius:4px;overflow:hidden;min-width:8px}}.track i{{display:block}}
.a{{background:var(--good)}}.p{{background:var(--mango)}}.m{{background:var(--crit)}}.n{{background:var(--na)}}.num{{text-align:right;color:var(--soft);font-size:.88rem;font-variant-numeric:tabular-nums}}
@media (max-width:640px){{.brow{{grid-template-columns:1fr 52px}}.track{{grid-column:1/-1;order:3}}}}
.gaps{{display:grid;grid-template-columns:repeat(auto-fit,minmax(290px,1fr));gap:12px}}.gap{{background:var(--card);border:1px solid var(--rule);border-radius:12px;padding:14px;display:grid;gap:8px;align-content:start}}
.q{{font-size:.92rem;border-left:3px solid var(--ember);padding-left:10px}}.q small{{display:block;color:var(--faint);font-size:.78rem}}.note{{font-size:.86rem;color:var(--soft)}}
</style></head><body><main>
<header style="display:grid;gap:10px"><span class="eb">The Panel · run report</span><h1>{E(title)}</h1><span class="verdict {"pass" if all_pass else "stop"}">{"Passes the gate" if all_pass else "Stops the build"} · bar {bar}%</span></header>
<section><h2>The gate</h2><div class="tw"><table><thead><tr><th>Group</th><th>Questions</th><th>Answered</th><th>Verdict</th></tr></thead><tbody>{"".join(gate_rows)}</tbody></table></div>
<p class="note">Counted from scores.tsv in {E(run.replace(os.path.expanduser("~"), "~"))}. Each question was written blind; see subject.md for how this run was set up.</p></section>
{pr}{"".join(blocks)}
</main></body></html>'''
    open(run + '/report.html', 'w').write(doc)
    print('report.html ·', ' · '.join(f'{k}: {pct(v)}%' for k, v in panels.items()), '·', 'PASS' if all_pass else 'STOP')


if __name__ == '__main__':
    main()
