// live-view — one page of what every agent on this machine is doing right now,
// read from the run records and the logs beside them.
//
// It exists because nothing else can answer the question. A status page rebuilt
// from the forge sees merged work, not work in progress; the logs on this
// machine are the only place "what is it doing at this moment" is written down.
// Everything else in the swarm asks THIS for the agent count, which is why a
// missing answer has to mean busy — see swarm_live_count.
//
// Configuration arrives as environment variables, set by swarm/live-view.sh,
// which resolves them the one way the whole layer resolves anything.
// No dependencies: node and nothing else.
import http from 'node:http'
import fs from 'node:fs'
import path from 'node:path'
import os from 'node:os'
import { execFile, execFileSync } from 'node:child_process'
import { fileURLToPath } from 'node:url'
import { gather as gatherProgress, plansOf, progressOf, shortTitle, allowanceLow, noteGh } from './progress.mjs'

const RUNS = process.env.SWARM_RUNS_DIR || path.join(os.homedir(), '.swarm/runs')
const PORT = Number(process.env.SWARM_PORT || 4777)
const REPO = process.env.SWARM_REPO || ''
const GH = process.env.SWARM_GH || 'gh'
const PREFIX = process.env.SWARM_PROGRAMME_PREFIX || 'project:'
const TITLES = process.env.SWARM_TITLES || path.join(RUNS, '..', 'live-view-titles.json')
const KEEP_HOURS = Number(process.env.SWARM_DONE_HOURS || 6)
const TAIL = 400_000
// How far along, cached: the facts are git and forge reads, far too slow for a
// request that every other part of the swarm polls. Refreshed off the request
// path, and a snapshot taken before the first refresh lands says `unknown` on
// every step rather than inventing one.
const PROGRESS_CACHE = process.env.SWARM_PROGRESS_CACHE
  || path.join(RUNS, '..', 'swarm', 'progress.json')
const PROGRESS_MS = Number(process.env.SWARM_PROGRESS_MS || 60_000)
const DRIVER_DIR = process.env.DRIVER_DIR || path.join(RUNS, '..', 'driver')
const QUEUE_REPO = process.env.SWARM_QUEUE_REPO || ''
const PLAIN = process.env.SWARM_PLAIN_TITLES || path.join(RUNS, '..', 'plain-titles.json')
// The coordinator's queue and whether anything holds its spawns. The queue is a
// state file read as it stands; the hold is asked of hold-status.sh, which runs
// the same functions the coordinator decides with.
const COORD_QUEUE = process.env.SWARM_COORD_QUEUE || path.join(RUNS, '..', 'coordinator', 'queue.json')
// The last tick's ceiling, the reading behind it and the healing / new split.
const COORD_CAPACITY = path.join(path.dirname(COORD_QUEUE), 'capacity.json')
const HOLD_SCRIPT = process.env.SWARM_HOLD_SCRIPT
  || path.join(path.dirname(fileURLToPath(import.meta.url)), '..', 'hold-status.sh')
const HOLD_MS = Number(process.env.SWARM_HOLD_MS || 30_000)
const BASH = process.env.SWARM_BASH || 'bash'
// Where a finished ticket stands NOW, read from what the coordinator already
// keeps: its issue snapshot and the open pull requests the tick shares. No call
// per row. A run's exit says how the run ended, not where the ticket is.
const COORD_ISSUES = process.env.SWARM_COORD_ISSUES || path.join(path.dirname(COORD_QUEUE), 'snapshot', 'issues.json')
const PRS_FILE = process.env.SWARM_PRS_FILE || path.join(RUNS, '..', 'swarm', 'prs.json')
const OWNER = process.env.SWARM_OWNER_NAME || 'the owner'
const BRANCH_PREFIX = process.env.BRANCH_PREFIX || ''
const LBL = (k, d) => process.env[k] || d

let progressAt = 0, progress = { tickets: {}, plans: {} }
try { progress = JSON.parse(fs.readFileSync(PROGRESS_CACHE, 'utf8')) } catch {}

// SWARM_PROGRESS_SYNC makes the refresh happen in-line, which is what a test
// wants: a background refresh is a race a test cannot win.
// Never in this process otherwise: the reads are synchronous, and in-process they
// froze every request for ~45 s of each minute.
const PROGRESS_JS = fileURLToPath(new URL('./progress.mjs', import.meta.url))
let gathering = false
function refreshProgress(tickets, ids, now) {
  if (gathering || now - progressAt < PROGRESS_MS) return
  progressAt = now
  if (allowanceLow()) return
  const args = { tickets, ids, repo: REPO, queueRepo: QUEUE_REPO, driverDir: DRIVER_DIR, prefix: PREFIX }
  const keep = (next) => {
    if (!next || typeof next !== 'object' || !next.tickets || !next.plans) return
    progress = next
    try {
      fs.mkdirSync(path.dirname(PROGRESS_CACHE), { recursive: true })
      fs.writeFileSync(PROGRESS_CACHE, JSON.stringify(next))
    } catch {}
  }
  if (process.env.SWARM_PROGRESS_SYNC) { try { keep(gatherProgress(args)) } catch {} ; return }
  gathering = true
  execFile(process.execPath, [PROGRESS_JS, '--gather', JSON.stringify(args)],
    { timeout: 300_000, maxBuffer: 64 * 1024 * 1024 }, (err, out) => {
      gathering = false
      if (err) return
      try { keep(JSON.parse(out)) } catch {}
    })
}

let holdAt = 0, hold = { held: false }
function refreshHold(now) {
  if (now - holdAt < HOLD_MS) return
  holdAt = now
  const take = (out) => { try { const j = JSON.parse(out); if (j && typeof j === 'object') hold = j } catch {} }
  if (process.env.SWARM_PROGRESS_SYNC) {
    try { take(execFileSync(BASH, [HOLD_SCRIPT], { timeout: 20_000, encoding: 'utf8' })) } catch {}
    return
  }
  execFile(BASH, [HOLD_SCRIPT], { timeout: 20_000 }, (err, out) => { if (!err) take(out) })
}

const RANK = { repair: 0, 'approved-merge': 1, new: 2 }
const KIND = { 'half-built': 0, feature: 1, other: 2, polish: 3 }
// The queue in the order the coordinator runs it: a front entry first, then
// priority (none last), then class, product before tooling, then kind for new
// work, then position — the
// same order as coord_queue_ordered. An unknown class sorts last.
export function queueOf(file = COORD_QUEUE) {
  let q
  try { q = JSON.parse(fs.readFileSync(file, 'utf8')) } catch { return { scopes: [], tickets: [] } }
  const fallback = q.label || q.scope || ''
  const rows = (Array.isArray(q.tickets) ? q.tickets : [])
    .filter((t) => t && t.n != null)
    .map((t, pos) => ({ t, pos, front: t.front ? 0 : 1, prin: Number.isInteger(t.prin) ? t.prin : 9,
                        rank: RANK[t.class] ?? 3, tool: t.tooling ? 1 : 0, kind: t.class === 'new' ? (KIND[t.kind] ?? 2) : 0 }))
    .sort((a, b) => a.front - b.front || (a.front === 0 ? a.pos - b.pos : 0) || a.prin - b.prin
                    || a.rank - b.rank || a.tool - b.tool || a.kind - b.kind || a.pos - b.pos)
    .map(({ t }) => ({ ticket: String(t.n), class: String(t.class || 'new'), note: String(t.note || ''),
                       scope: String(t.scope || fallback), pinned: !!t.pinned }))
  const scopes = Array.isArray(q.scopes) ? q.scopes.map((s) => String(s.label || s.scope || s))
    : [...new Set(rows.map((r) => r.scope).filter(Boolean))]
  return { scopes, seededAt: q.seeded_at || null, tickets: rows }
}

export function capacityOf(file = COORD_CAPACITY) {
  try { const c = JSON.parse(fs.readFileSync(file, 'utf8')); return c && typeof c === 'object' ? c : null } catch { return null }
}

let titles = {}
try { titles = JSON.parse(fs.readFileSync(TITLES, 'utf8')) } catch {}
const pending = new Set()

// A title is worth one call per ticket, ever, and it is cached to a file so a
// restart does not re-ask for every ticket at once. A failure is not retried in
// the same process: the card falls back to "Ticket 1234", which is honest.
function fetchTitle(ticket) {
  if (!REPO || titles[ticket] || pending.has(ticket) || pending.size >= 4 || allowanceLow()) return
  pending.add(ticket)
  noteGh(['issue', 'view'])
  execFile(GH, ['issue', 'view', String(ticket), '--repo', REPO, '--json', 'title,labels'],
    { timeout: 20_000 }, (err, out) => {
      pending.delete(ticket)
      if (err) return
      try {
        const j = JSON.parse(out)
        const programme = (j.labels || []).map((l) => l.name).find((n) => n.startsWith(PREFIX)) || ''
        titles[ticket] = { title: plainTitle(j.title), project: programme.slice(PREFIX.length) }
        fs.writeFileSync(TITLES, JSON.stringify(titles))
      } catch {}
    })
}

// filter(Boolean): an empty or dash-edged id splits to '' and ''[0] throws.
const plainName = (id) => String(id ?? '').split(/[-_ ]+/).filter(Boolean)
  .map((w) => (/^(ai|api|ci|ui|uat|ux)$/i.test(w) ? w.toUpperCase() : w[0].toUpperCase() + w.slice(1)))
  .join(' ')

// "fix(desk): the strip drops its last item" → "The strip drops its last item"
function plainTitle(t) {
  const s = String(t ?? '').replace(/^[a-z]+(\([^)]*\))?:\s*/i, '').replace(/^#?\d+:\s*/, '')
  return s.charAt(0).toUpperCase() + s.slice(1)
}

const alive = (pid) => { try { process.kill(pid, 0); return true } catch { return false } }

// On Windows the spawner runs under Git Bash, whose pids and '/c/…' paths mean
// nothing to a native node: process.kill() answers ESRCH for a running agent,
// which reads the machine as empty and lets the scheduler fill it. The spawner
// records the native pid beside the MSYS one; read that, and turn a drive path
// back into one node can open.
const WIN = process.platform === 'win32'
const runPid = (run) => (WIN && (run.child_winpid || run.winpid)) || run.child_pid || run.pid
const nativePath = (p) => (WIN && typeof p === 'string' ? p.replace(/^\/([a-zA-Z])\//, '$1:/') : p)

function tail(file) {
  try {
    const fd = fs.openSync(file, 'r')
    const size = fs.fstatSync(fd).size
    const len = Math.min(size, TAIL)
    const buf = Buffer.alloc(len)
    fs.readSync(fd, buf, 0, len, size - len)
    fs.closeSync(fd)
    return buf.toString('utf8')
  } catch { return '' }
}

function stepFrom(block) {
  if (block.type === 'text') {
    const t = String(block.text ?? '').replace(/\s+/g, ' ').trim()
    return t ? { kind: 'say', text: t.slice(0, 220) } : null
  }
  if (block.type !== 'tool_use') return null
  const i = block.input || {}
  const base = (p) => (p ? path.basename(p) : '')
  const map = {
    Bash: i.description || String(i.command ?? '').slice(0, 80),
    Read: `Reading ${base(i.file_path)}`,
    Edit: `Editing ${base(i.file_path)}`,
    Write: `Writing ${base(i.file_path)}`,
    Grep: `Searching for "${String(i.pattern ?? '').slice(0, 40)}"`,
    Glob: `Finding ${i.pattern || 'files'}`,
    Agent: `Asked a reviewer: ${i.description || ''}`,
    Skill: `Running /${i.skill || ''}`,
    TodoWrite: 'Updating its checklist',
  }
  return { kind: 'do', text: String(map[block.name] ?? block.name).slice(0, 140) }
}

// ---- cli-signal reader: begin ----------------------------------------------
// A run that died on the service, by the CLI's own error result. The same words
// in a run's ordinary final report (a CI log it quoted) are not a death.
const INFRA_RE = /API Error|Connection refused|ECONNRESET|ETIMEDOUT|overloaded|Overloaded|529|503 Service|socket hang up/
const infraDeath = (j) => j.is_error === true && INFRA_RE.test(String(j.result ?? ''))
// ---- cli-signal reader: end ------------------------------------------------

// eslint-disable-next-line no-control-regex
const ANSI_RE = /\x1b\[[0-9;?]*[ -\/]*[@-~]/g

// The driver's own park line: `⏸ #12 parked (pm): reason — the question`.
const PARK_RE = /⏸ #\d+ parked \((person|pm|driver)\): ([^\n"]*)/g
function parkOf(text) {
  let m, last = null
  PARK_RE.lastIndex = 0
  while ((m = PARK_RE.exec(text))) last = m
  if (!last) return null
  const reason = last[2].split(' — ')[0].trim()
  return { cause: last[1], reason: reason.length > 120 ? reason.slice(0, 119) + '…' : reason, full: last[2] }
}

function parseLog(file) {
  const steps = []
  let result = null
  const text = tail(file)
  for (const line of text.split('\n')) {
    // The step driver logs plain lines, not stream-JSON; each one is a step.
    if (!line.startsWith('{')) {
      const t = line.replace(ANSI_RE, '').trim()
      if (t) steps.push({ kind: 'say', text: t.slice(0, 220) })
      continue
    }
    let j
    try { j = JSON.parse(line) } catch { continue }
    if (j.type === 'assistant') {
      for (const b of j.message?.content || []) {
        const s = stepFrom(b)
        if (s) steps.push(s)
      }
    } else if (j.type === 'result') {
      result = { subtype: j.subtype, cost: j.total_cost_usd, summary: String(j.result ?? '').slice(0, 400), infra: infraDeath(j) }
    }
  }
  let mtime = 0
  try { mtime = fs.statSync(file).mtimeMs } catch {}
  return { steps: steps.slice(-10), result, mtime, park: parkOf(text) }
}

// A state file read as it stands, re-parsed only when it changes: the PR cache
// is ~600 KB and the page asks every five seconds.
const jsonCache = new Map()
function readJsonCached(file) {
  let m
  try { m = fs.statSync(file).mtimeMs } catch { return null }
  const hit = jsonCache.get(file)
  if (hit && hit.m === m) return hit.v
  let v = null
  try { v = JSON.parse(fs.readFileSync(file, 'utf8')) } catch {}
  jsonCache.set(file, { m, v })
  return v
}

// The ticket a branch belongs to, in the three shapes scripts/branch-ticket.sh knows.
export function branchTicket(b, pre = BRANCH_PREFIX) {
  b = String(b || '')
  let m
  if (pre && b.startsWith(pre) && (m = /^(\d+)(\D|$)/.exec(b.slice(pre.length)))) return m[1]
  if ((m = /^(\d+)\//.exec(b))) return m[1]
  if ((m = /^[a-z]+\/(\d+)-/.exec(b))) return m[1]
  return ''
}

// ticket -> its open pull request number, by closing reference or by branch.
function openPrsByTicket(file = PRS_FILE) {
  const rows = readJsonCached(file)
  const by = {}
  if (!Array.isArray(rows)) return by
  for (const p of rows) {
    if (!p || p.number == null) continue
    const ts = new Set((p.closingIssuesReferences || []).map((r) => String(r && r.number)).filter((n) => n !== 'undefined'))
    const bt = branchTicket(p.headRefName)
    if (bt) ts.add(bt)
    for (const t of ts) if (!(t in by) || p.number > by[t]) by[t] = p.number
  }
  return by
}

function issuesByTicket(file = COORD_ISSUES) {
  const j = readJsonCached(file)
  const by = {}
  const rows = Array.isArray(j) ? j : j && typeof j === 'object' ? Object.values(j) : []
  for (const i of rows) {
    if (!i || i.number == null) continue
    by[String(i.number)] = { state: String(i.state || ''), reason: String(i.stateReason || ''),
      labels: (i.labels || []).map((l) => (typeof l === 'string' ? l : l && l.name)).filter(Boolean) }
  }
  return by
}

// The words and tone a finished row's state is shown with. Only `stopped` is a failure.
export const NOW_STATES = {
  shipped: { tone: 'ok', count: 'shipped' },
  closed: { tone: 'neutral', count: 'closed' },
  review: { tone: 'ok', count: 'in review' },
  queue: { tone: 'neutral', count: 'back in queue' },
  running: { tone: 'ok', count: 'running again' },
  pm: { tone: 'warn', count: 'waiting on PM' },
  owner: { tone: 'warn', count: `waiting on ${OWNER}` },
  blocked: { tone: 'warn', count: 'blocked' },
  finished: { tone: 'neutral', count: 'finished' },
  stopped: { tone: 'bad', count: 'stopped' },
}

// Where a finished ticket stands now, first match wins.
export function nowOf(d, ctx) {
  const t = String(d.ticket)
  const issue = ctx.issues[t]
  const has = (l) => !!issue && issue.labels.includes(l)
  const parked = has(LBL('LBL_PARKED', 'status:parked'))
  const openPr = ctx.prs[t]
  const ref = /\/pull\/(\d+)|\bPR #(\d+)/.exec(d.summary || '')
  const reported = ref ? Number(ref[1] || ref[2]) : null
  const done = has(LBL('LBL_DONE', 'status:done')) || has('status:merged-needs-rollout')
  const park = d.park
  const at = (state, text, extra = {}) => ({ state, text, tone: NOW_STATES[state].tone, ...extra })
  const completed = !!issue && issue.state === 'CLOSED' && issue.reason === 'COMPLETED'
  if ((d.exit === 0 && reported && !openPr) || done || completed) return at('shipped', 'Shipped')
  if (issue && issue.state === 'CLOSED') return at('closed', 'Closed')
  if (openPr) return at('review', `In review — PR #${openPr}`, { pr: openPr })
  if (ctx.queued.has(t) || (has(LBL('LBL_READY', 'status:ready')) && !parked)) return at('queue', 'Back in the queue')
  if (ctx.live.has(t)) return at('running', 'Running again')
  if (has(LBL('LBL_PM_DECISION', 'status:pm-decision')) || (parked && park && park.cause === 'pm')) return at('pm', 'Waiting on PM')
  if ([LBL('LBL_OWNER_DECISION', 'needs:owner-decision'), LBL('LBL_NEEDS_HUMAN', 'status:needs-human'),
       LBL('HOLD_LABEL', 'needs:human-approval')].some(has)) return at('owner', `Waiting on ${OWNER}`)
  if (has(LBL('LBL_BLOCKED', 'status:blocked'))) {
    const by = park && /blocked (?:by|on) #(\d+)/i.exec(park.full)
    return at('blocked', by ? `Blocked by #${by[1]}` : 'Blocked', by ? { by: Number(by[1]) } : {})
  }
  if (d.exit === 0 && !park) return at('finished', 'Finished')
  const why = (park && park.reason) || d.note || (d.exit != null ? `exit ${d.exit}` : 'no reason on record')
  return at('stopped', `Stopped — ${why}`)
}

// "Finished: 1 shipped · 10 back in queue · 4 stopped", biggest first after the
// states that are good news.
export function doneSummary(rows) {
  const n = {}
  for (const r of rows) n[r.now.state] = (n[r.now.state] || 0) + 1
  const parts = Object.keys(NOW_STATES).filter((k) => n[k]).map((k) => `${n[k]} ${NOW_STATES[k].count}`)
  return parts.length ? `Finished: ${parts.join(' · ')}` : 'Finished'
}

// A run is live when it has no .ended marker AND its agent's process still
// exists. The marker alone is not enough — a wrapper killed before it could
// write one leaves a record that looks like a running agent forever, which is
// how a launcher once reported eight running with three alive.
export function snapshot(now = Date.now()) {
  const live = []
  let plainTitles = {}
  try { plainTitles = JSON.parse(fs.readFileSync(PLAIN, 'utf8')) } catch {}
  const done = []
  let files = []
  try { files = fs.readdirSync(RUNS).filter((f) => /^claim-.*\.json$/.test(f)) } catch {}
  for (const f of files) {
    let run
    try { run = JSON.parse(fs.readFileSync(path.join(RUNS, f), 'utf8')) } catch { continue }
    let ended = null
    try { ended = JSON.parse(fs.readFileSync(path.join(RUNS, f.replace(/\.json$/, '.ended')), 'utf8')) } catch {}
    const isLive = !ended && alive(runPid(run))
    if (!isLive && (!ended || now - Date.parse(ended.ended_at) > KEEP_HOURS * 3600_000)) continue
    fetchTitle(run.ticket)
    const log = parseLog(nativePath(run.log || ''))
    const t = titles[run.ticket] || {}
    // NOT `f`: that is the loop's filename, and a second `const f` in this block
    // shadows it into its own temporal dead zone — every read then throws into
    // the catch above and every run record is skipped in silence.
    const fct = progress.tickets[String(run.ticket)]
    const row = {
      ticket: String(run.ticket),
      title: t.title || `Ticket ${run.ticket}`,
      short: shortTitle(t.title || `Ticket ${run.ticket}`, plainTitles[String(run.ticket)], t.project, plainName),
      project: t.project || '',
      progress: progressOf(fct, fct && fct.driver),
      startedAgoMin: Math.round((now - Date.parse(run.started_at)) / 60000),
      quietSec: log.mtime ? Math.round((now - log.mtime) / 1000) : null,
      budget: run.budget_usd,
      steps: log.steps,
    }
    if (isLive) live.push(row)
    else done.push({
      ...row,
      exit: ended?.exit_code,
      endedAgoMin: Math.round((now - Date.parse(ended.ended_at)) / 60000),
      outcome: log.result?.subtype || (ended?.exit_code === 0 ? 'success' : 'stopped'),
      cost: log.result?.cost,
      summary: log.result?.summary || '',
      infra: !!log.result?.infra,
      note: String(ended?.note || ''),
      park: log.park,
      endedAt: Date.parse(ended.ended_at) || 0,
    })
  }
  live.sort((a, b) => a.startedAgoMin - b.startedAgoMin)
  // One row per ticket: its newest run. Twenty runs of five tickets read as twenty failures.
  const newest = new Map()
  for (const d of done) { const o = newest.get(d.ticket); if (!o || d.endedAt > o.endedAt) newest.set(d.ticket, d) }
  const queued = queueOf()
  const ctx = { issues: issuesByTicket(), prs: openPrsByTicket(), live: new Set(live.map((a) => a.ticket)),
                queued: new Set(queued.tickets.map((r) => r.ticket)) }
  const doneRows = [...newest.values()].sort((a, b) => b.endedAt - a.endedAt).slice(0, 20)
    .map(({ park, endedAt, ...d }) => ({ ...d, now: nowOf({ ...d, park }, ctx) }))
  refreshProgress(live.map((a) => a.ticket), [...new Set(live.map((a) => a.project).filter(Boolean))], now)
  refreshHold(now)
  const queue = queued
  for (const r of queue.tickets) {
    fetchTitle(r.ticket)
    const t = titles[r.ticket] || {}
    r.title = t.title || `Ticket ${r.ticket}`
  }
  // `at` is the whole staleness contract: every reader discards an answer older
  // than its own ceiling rather than believing a machine that has moved on.
  return { at: new Date(now).toISOString(), repo: REPO, load: os.loadavg()[0],
           plans: plansOf(live, progress.plans, plainName), live, done: doneRows, doneSummary: doneSummary(doneRows),
           hold, queue, capacity: capacityOf() }
}

export function serve(port = PORT) {
  const page = fs.readFileSync(new URL('./index.html', import.meta.url), 'utf8')
  return http.createServer((req, res) => {
    if (req.url === '/api/agents') {
      // A throw here escapes to the process and kills the page for every viewer.
      let body
      try { body = JSON.stringify(snapshot()) } catch (e) {
        res.writeHead(500, { 'content-type': 'application/json', 'cache-control': 'no-store' })
        res.end(JSON.stringify({ error: String(e && e.message || e) }))
        return
      }
      res.writeHead(200, { 'content-type': 'application/json', 'cache-control': 'no-store' })
      res.end(body)
      return
    }
    res.writeHead(200, { 'content-type': 'text/html; charset=utf-8' })
    res.end(page)
  }).listen(port, '127.0.0.1')
}

if (process.argv[1] && import.meta.url === new URL(`file://${process.argv[1]}`).href) {
  serve().on('listening', () => console.log(`live-view on http://127.0.0.1:${PORT}`))
}
