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
// The labels that mean nobody can start a row (coord_stopped): a repair is stopped
// only by those that park the ticket; a hold or a question stops new work too.
const STOP_ALL = [LBL('LBL_BATCHED', 'status:batched'), LBL('LBL_PARKED', 'status:parked'), LBL('LBL_BLOCKED', 'status:blocked'),
  LBL('LBL_EXTERNAL_BLOCKED', 'status:external-blocked'), LBL('LBL_GATED', 'status:gated'), LBL('LBL_DRAFTING', 'status:drafting'),
  LBL('LBL_PM_DECISION', 'status:pm-decision'), LBL('LBL_PM_TRACK', 'status:pm-track')]
const STOP_NEW = [...STOP_ALL, LBL('HOLD_LABEL', 'needs:human-approval'), LBL('LBL_NEEDS_HUMAN', 'status:needs-human'),
  LBL('LBL_OWNER_DECISION', 'needs:owner-decision')]
const REPAIR_NOTE = /(^|\n)REPAIR on PR #[0-9]/
export const classOf = (t) => (String(t.class || 'new') === 'new' && REPAIR_NOTE.test(String(t.note || '')) ? 'repair' : String(t.class || 'new'))
// A row somebody can start: its ticket open and wearing no stop label. Unread, it counts.
export function startable(cls, issue) {
  if (!issue) return true
  if (issue.state && issue.state !== 'OPEN') return false
  const stop = cls === 'new' ? STOP_NEW : STOP_ALL
  return !(issue.labels || []).some((l) => stop.includes(l))
}
// The queue in the order the coordinator runs it: an entry the PM put on top first,
// then priority (none last), and within one priority a front entry (a resume, an
// answer) first, then class, product before tooling, then kind for new work, then
// position — the same order as coord_queue_ordered. An unknown class sorts last.
// Only rows somebody can start are listed, so the count is the work there is.
export function queueOf(file = COORD_QUEUE, issues = issuesByTicket()) {
  let q
  try { q = JSON.parse(fs.readFileSync(file, 'utf8')) } catch { return { scopes: [], tickets: [] } }
  const fallback = q.label || q.scope || ''
  const rows = (Array.isArray(q.tickets) ? q.tickets : [])
    .filter((t) => t && t.n != null)
    .map((t) => ({ ...t, class: classOf(t) }))
    .filter((t) => startable(t.class, issues[String(t.n)]))
    .map((t, pos) => ({ t, pos, top: t.top ? 0 : 1, front: t.front ? 0 : 1, prin: Number.isInteger(t.prin) ? t.prin : 9,
                        rank: RANK[t.class] ?? 3, tool: t.tooling ? 1 : 0, kind: t.class === 'new' ? (KIND[t.kind] ?? 2) : 0 }))
    .sort((a, b) => a.top - b.top || (a.top === 0 ? a.pos - b.pos : 0) || a.prin - b.prin
                    || a.front - b.front || (a.front === 0 ? a.pos - b.pos : 0)
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

// ticket -> its newest open pull request, by closing reference or by branch:
// its number, whether it is red, and whether it waits on the owner's sign-off.
function prRowsByTicket(file = PRS_FILE) {
  const rows = readJsonCached(file)
  const by = {}
  if (!Array.isArray(rows)) return by
  const hold = LBL('HOLD_LABEL', 'needs:human-approval')
  for (const p of rows) {
    if (!p || p.number == null) continue
    const ts = new Set((p.closingIssuesReferences || []).map((r) => String(r && r.number)).filter((n) => n !== 'undefined'))
    const bt = branchTicket(p.headRefName)
    if (bt) ts.add(bt)
    const row = { number: p.number, red: prRed(p),
                  held: (p.labels || []).some((l) => (typeof l === 'string' ? l : l && l.name) === hold) }
    for (const t of ts) if (!(t in by) || p.number > by[t].number) by[t] = row
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

// ---- the board: every open ticket, counted once per five minutes -------------
// The queue is only what can start now; the owner asked how much stands between
// now and launch: the release (releaseOf), read from every open ticket. The issue
// snapshot holds only the queue's and the recent runs' tickets, so this is one
// batched read of them all, off the request path and never more than once in
// BOARD_MS. A read that stopped part-way is not a count and is not kept.
const BOARD_FILE = process.env.SWARM_BOARD_FILE || path.join(RUNS, '..', 'swarm', 'board.json')
const BOARD_MS = Math.max(300_000, Number(process.env.SWARM_BOARD_MS || 300_000))
const AFTER_LAUNCH = process.env.SWARM_AFTER_LAUNCH_LABEL || 'after-launch'
const CLAIM_LOCK = process.env.SWARM_CLAIM_LOCK || ''
// The coordinator's own five-hour readings: <epoch> \t <utilization> \t <reset epoch> \t <builders>.
const PACE_FILE = process.env.SWARM_PACE_FILE || path.join(path.dirname(COORD_QUEUE), 'pace.tsv')
// Containers, not work: a batch folds child tickets that stay open on their own, and
// an epic or programme is the sum of its children. Counted beside them, they count
// the same work twice. The first prefix names the batch wrappers; the rest and the
// labels are epics and programmes.
const words = (v, d) => String(v ?? d).split(/\s+/).filter(Boolean)
const WRAPPER_PREFIXES = words(process.env.SWARM_WRAPPER_TITLE_PREFIXES, 'Batch PROGRAMME EPIC')
const WRAPPER_LABELS = words(process.env.SWARM_WRAPPER_LABELS, 'epic programme')
const reEsc = (x) => x.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')
const PREFIX_RE = WRAPPER_PREFIXES.map((p) => new RegExp(`^\\s*${reEsc(p)}(?![a-z])`, 'i'))
// 'batch', 'epic', or null for a work item. Read from the forge's own title, never the plain one.
export function wrapperOf(title, labels = []) {
  const t = String(title ?? '')
  if (PREFIX_RE.length && PREFIX_RE[0].test(t)) return 'batch'
  if (PREFIX_RE.slice(1).some((r) => r.test(t)) || (labels || []).some((l) => WRAPPER_LABELS.includes(l))) return 'epic'
  return null
}

// ---- the release: which tickets it is made of -------------------------------
// Owner call 2026-10-18 (the launch-runway study): the release is the urgent and
// high-priority work only, less what is set for after launch (a label, or one of
// the post-launch milestones), less parked work and the containers. Open, done,
// added and the pace all count this one population, so the bar and the date agree.
const listOf = (v, d) => { const w = String(v ?? '').split(/[\s,]+/).filter(Boolean); return w.length ? w : d }
const jsonList = (v, d) => { try { const j = JSON.parse(v); return Array.isArray(j) ? j.map(String) : d } catch { return d } }
export const RELEASE_PRIORITIES = listOf(process.env.SWARM_RELEASE_PRIORITIES, ['P0', 'P1'])
export const POST_LAUNCH_MILESTONES = jsonList(process.env.SWARM_POST_LAUNCH_MILESTONES,
  ['Post-launch', 'Mobile (fast-follow)', 'Echo phase 2 — Bodyguard + Sedric parity'])
const PARKED = LBL('LBL_PARKED', 'status:parked')
const msTitle = (m) => String((m && typeof m === 'object' ? m.title : m) ?? '')
export const postLaunch = (labels, milestone) => (labels || []).includes(AFTER_LAUNCH) || POST_LAUNCH_MILESTONES.includes(msTitle(milestone))
const releasePriority = (labels) => (labels || []).some((l) => RELEASE_PRIORITIES.includes(l))
// What a search count can test: priority, the after-launch label and parked. The
// forge's search honours only the FIRST -milestone: in a query (measured 2026-10-20:
// two of them counted 365 and 444, each the count of the first alone), so the
// post-launch milestones and the wrappers are read as rows and taken off after.
export const searchScope = (labels) => releasePriority(labels) && !(labels || []).includes(AFTER_LAUNCH) && !(labels || []).includes(PARKED)
const postLaunchMilestone = (milestone) => POST_LAUNCH_MILESTONES.includes(msTitle(milestone))
// Where an open ticket stands against the release, first match wins:
// 'post', 'lower', 'batch' / 'epic' (a wrapper), 'parked', or 'release'.
export function releaseOf(title, labels = [], milestone = null) {
  if (postLaunch(labels, milestone)) return 'post'
  if (!releasePriority(labels)) return 'lower'
  const w = wrapperOf(title, labels)
  if (w) return w
  if (labels.includes(PARKED)) return 'parked'
  return 'release'
}
const quoted = (x) => `"${String(x).replace(/"/g, '')}"`
// searchScope as a search clause, so the forge's counts are of the same tickets.
export const scopeClause = () => [`label:${RELEASE_PRIORITIES.join(',')}`, `-label:${quoted(AFTER_LAUNCH)}`, `-label:${quoted(PARKED)}`].join(' ')
// What a kept file was read under: a changed setting is a changed population. The
// board and the trend are search counts under scopeClause; the rows taken off them
// also depend on which wrappers and milestones there are.
export const rowsKey = () => JSON.stringify([scopeClause(), POST_LAUNCH_MILESTONES, WRAPPER_PREFIXES, WRAPPER_LABELS])

// Our own build tooling, as the coordinator tells it (coord_tooling in
// scripts/coordinator-env.sh): one of its labels, or a title scope ("feat(gates): …").
// The lists arrive from live-view.sh, which reads them from the coordinator's own settings.
const TOOLING_LABELS = listOf(process.env.SWARM_TOOLING_LABELS, [])
const TOOLING_SCOPES = listOf(process.env.SWARM_TOOLING_SCOPES, []).map((x) => x.toLowerCase())
export function toolingOf(labels = [], title = '') {
  if ((labels || []).some((l) => TOOLING_LABELS.includes(l))) return true
  const m = /^[a-z]+\(([^)]*)\)!?:/i.exec(String(title ?? ''))
  return TOOLING_SCOPES.includes(m ? m[1].toLowerCase() : '')
}

// Local midnight, as the instant the "today" counts start from.
export function dayStart(now = Date.now()) {
  const d = new Date(now); d.setHours(0, 0, 0, 0)
  return d.toISOString().replace(/\.\d{3}Z$/, 'Z')
}

const BOARD_QUERY = `query($owner:String!,$name:String!,$done:String!,$made:String!,$merged:String!,$endCursor:String){
 done: search(query:$done,type:ISSUE,first:0){issueCount}
 made: search(query:$made,type:ISSUE,first:0){issueCount}
 merged: search(query:$merged,type:ISSUE,first:0){issueCount}
 repository(owner:$owner,name:$name){issues(states:OPEN,first:100,after:$endCursor){totalCount pageInfo{hasNextPage endCursor} nodes{number title createdAt milestone{title} labels(first:50){nodes{name}}}}}}`

export function boardArgs(repo, since) {
  const [owner, name] = String(repo).split('/')
  const q = (s) => `repo:${repo} ${s}`
  const not = scopeClause()
  return ['api', 'graphql', '--paginate', '--slurp', '-F', `owner=${owner}`, '-F', `name=${name}`,
    '-f', `done=${q(`is:issue is:closed reason:completed closed:>=${since} ${not}`)}`,
    '-f', `made=${q(`is:issue created:>=${since} ${not}`)}`,
    '-f', `merged=${q(`is:pr is:merged merged:>=${since}`)}`,
    '-f', `query=${BOARD_QUERY}`]
}

// The pages of that read, as the board file keeps them. Null unless the last page
// says there is no next one: a short read would count too few and look like progress.
export function boardFromPages(pages, since, at) {
  if (!Array.isArray(pages) || !pages.length) return null
  const open = []
  let last = null
  for (const p of pages) {
    const iss = p && p.data && p.data.repository && p.data.repository.issues
    if (!iss || !Array.isArray(iss.nodes)) return null
    for (const n of iss.nodes) {
      if (!n || n.number == null) continue
      open.push({ number: n.number, title: plainTitle(n.title), raw: n.title, createdAt: n.createdAt || null, milestone: msTitle(n.milestone) || null,
                  labels: ((n.labels && n.labels.nodes) || []).map((l) => l && l.name).filter(Boolean) })
    }
    last = iss
  }
  if (!last || !last.pageInfo || last.pageInfo.hasNextPage !== false) return null
  const d = pages[0].data
  const count = (k) => (d[k] && Number.isInteger(d[k].issueCount) ? d[k].issueCount : null)
  return { at, since, scope: scopeClause(), open, doneToday: count('done'), newToday: count('made'), mergedToday: count('merged') }
}

// Every live claim and the host it is on, from the claim refs every host writes.
export function claimsFromList(out) {
  try {
    const j = JSON.parse(out)
    if (!Array.isArray(j)) return null
    return j.filter((c) => c && c.issue != null).map((c) => ({ issue: String(c.issue), host: String(c.host || '') }))
  } catch { return null }
}

let boardTried = 0, boardBusy = false
// A file read under another scope (an older page, a changed setting) is not fresh.
const sameScope = (file, key = scopeClause()) => { const j = readJsonCached(file); return !!j && j.scope === key }
function boardFresh(now) {
  try { return now - fs.statSync(BOARD_FILE).mtimeMs < BOARD_MS && sameScope(BOARD_FILE) } catch { return false }
}
function refreshBoard(now) {
  if (!REPO || boardBusy || now - boardTried < BOARD_MS || boardFresh(now)) return
  boardTried = now
  if (allowanceLow()) return
  const since = dayStart(now)
  const args = boardArgs(REPO, since)
  const keep = (out, claims) => {
    let pages
    try { pages = JSON.parse(out) } catch { return }
    const b = boardFromPages(pages, since, new Date(now).toISOString())
    if (!b) return
    b.claims = claims
    try {
      fs.mkdirSync(path.dirname(BOARD_FILE), { recursive: true })
      fs.writeFileSync(BOARD_FILE + '.tmp', JSON.stringify(b))
      fs.renameSync(BOARD_FILE + '.tmp', BOARD_FILE)
    } catch {}
  }
  const claimEnv = { ...process.env, CLAIM_REPO: QUEUE_REPO || process.env.CLAIM_REPO || '' }
  noteGh(['api', 'graphql'])
  if (process.env.SWARM_PROGRESS_SYNC) {
    let out = '', claims = null
    try { out = execFileSync(GH, args, { timeout: 120_000, encoding: 'utf8', maxBuffer: 64 * 1024 * 1024 }) } catch { return }
    if (CLAIM_LOCK) { try { claims = claimsFromList(execFileSync(CLAIM_LOCK, ['list', '--json'], { timeout: 60_000, encoding: 'utf8', env: claimEnv })) } catch {} }
    keep(out, claims)
    return
  }
  boardBusy = true
  execFile(GH, args, { timeout: 120_000, maxBuffer: 64 * 1024 * 1024 }, (err, out) => {
    if (err) { boardBusy = false; return }
    if (!CLAIM_LOCK) { boardBusy = false; keep(out, null); return }
    execFile(CLAIM_LOCK, ['list', '--json'], { timeout: 60_000, env: claimEnv }, (e2, c) => {
      boardBusy = false
      keep(out, e2 ? null : claimsFromList(c))
    })
  })
}

// ---- progress to launch: done against a fixed start, and the pace per day ----
// One GraphQL call of search counts (no per-ticket reads), kept TREND_MS, at least
// fifteen minutes. A day is local midnight to midnight; both sides count only the
// release's own scope (scopeClause), so the pace is the pace of the release.
const TREND_FILE = process.env.SWARM_TREND_FILE || path.join(path.dirname(BOARD_FILE), 'trend.json')
const TREND_MS = Math.max(900_000, Number(process.env.SWARM_TREND_MS || 900_000))
const PROGRESS_SINCE = process.env.SWARM_PROGRESS_SINCE || '2026-10-13'
const TREND_DAYS = 7

const localDay = (ms) => { const d = new Date(ms); return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}` }
const iso = (ms) => new Date(ms).toISOString().replace(/\.\d{3}Z$/, 'Z')
// The last TREND_DAYS whole days and today so far, oldest first: [{day, from, to}].
export function trendDays(now = Date.now()) {
  const start = new Date(now); start.setHours(0, 0, 0, 0)
  const out = []
  for (let i = TREND_DAYS; i >= 0; i--) {
    const a = new Date(start); a.setDate(a.getDate() - i)
    const b = new Date(a); b.setDate(b.getDate() + 1)
    out.push({ day: localDay(a.getTime()), from: iso(a.getTime()), to: iso(b.getTime() - 1000) })
  }
  return out
}
const baseStart = (base) => { const [y, m, d] = String(base).split('-').map(Number); return iso(new Date(y, m - 1, d).getTime()) }

export function trendArgs(repo, now = Date.now(), base = PROGRESS_SINCE, scope = scopeClause()) {
  const not = scope
  const q = (s) => JSON.stringify(`repo:${repo} ${s}`)
  const parts = [`base: search(query:${q(`is:issue is:closed reason:completed closed:>=${baseStart(base)} ${not}`)},type:ISSUE,first:0){issueCount}`]
  trendDays(now).forEach((d, i) => {
    parts.push(`a${i}: search(query:${q(`is:issue created:${d.from}..${d.to} ${not}`)},type:ISSUE,first:0){issueCount}`)
    parts.push(`d${i}: search(query:${q(`is:issue is:closed reason:completed closed:${d.from}..${d.to} ${not}`)},type:ISSUE,first:0){issueCount}`)
    parts.push(`m${i}: search(query:${q(`is:pr is:merged merged:${d.from}..${d.to}`)},type:ISSUE,first:0){issueCount}`)
  })
  return ['api', 'graphql', '-f', `query=query{ ${parts.join(' ')} }`]
}

// The answer as the trend file keeps it; null unless every count came back.
export function trendFromData(j, now = Date.now(), base = PROGRESS_SINCE) {
  const d = j && j.data
  if (!d) return null
  const n = (k) => (d[k] && Number.isInteger(d[k].issueCount) ? d[k].issueCount : null)
  const days = trendDays(now).map((x, i) => ({ day: x.day, added: n(`a${i}`), done: n(`d${i}`), merged: n(`m${i}`) }))
  if (n('base') == null || days.some((x) => x.added == null || x.done == null || x.merged == null)) return null
  return { at: iso(now), base, scope: scopeClause(), doneSinceBase: n('base'), days }
}

let trendTried = 0, trendBusy = false
function refreshTrend(now) {
  if (!REPO || trendBusy || now - trendTried < TREND_MS) return
  try { if (now - fs.statSync(TREND_FILE).mtimeMs < TREND_MS && sameScope(TREND_FILE)) return } catch {}
  trendTried = now
  if (allowanceLow()) return
  const args = trendArgs(REPO, now)
  const keep = (out) => {
    let t = null
    try { t = trendFromData(JSON.parse(out), now) } catch {}
    if (!t) return
    try {
      fs.mkdirSync(path.dirname(TREND_FILE), { recursive: true })
      fs.writeFileSync(TREND_FILE + '.tmp', JSON.stringify(t))
      fs.renameSync(TREND_FILE + '.tmp', TREND_FILE)
    } catch {}
  }
  noteGh(['api', 'graphql'])
  if (process.env.SWARM_PROGRESS_SYNC) {
    try { keep(execFileSync(GH, args, { timeout: 60_000, encoding: 'utf8' })) } catch {}
    return
  }
  trendBusy = true
  execFile(GH, args, { timeout: 60_000 }, (err, out) => { trendBusy = false; if (!err) keep(out) })
}

// ---- the wrappers: every batch, epic and programme, read with the trend ----
// Search counts cannot test a title prefix, nor more than one milestone, so the
// trend's counts include the wrappers and the post-launch milestones. Both are read
// here as rows — one paginated search per prefix, per label and per milestone, kept
// as long as the trend — and taken off those counts at answer time.
const WRAPPERS_FILE = process.env.SWARM_WRAPPERS_FILE || path.join(path.dirname(TREND_FILE), 'wrappers.json')
const SEARCH_CAP = 1000
const WRAPPER_QUERY = `query($q:String!,$endCursor:String){
 wrappers: search(query:$q,type:ISSUE,first:100,after:$endCursor){issueCount pageInfo{hasNextPage endCursor}
  nodes{... on Issue{number title state stateReason createdAt closedAt milestone{title} labels(first:50){nodes{name}}}}}}`

export function wrapperSearches(repo, prefixes = WRAPPER_PREFIXES, labels = WRAPPER_LABELS, milestones = POST_LAUNCH_MILESTONES) {
  return [...prefixes.map((p) => `in:title "${p}"`), ...labels.map((l) => `label:"${l}"`),
          ...milestones.map((m) => `milestone:${quoted(m)} ${scopeClause()}`)]
    .map((c) => ['api', 'graphql', '-f', `q=repo:${repo} is:issue ${c}`, '-f', `query=${WRAPPER_QUERY}`, '--paginate', '--slurp'])
}

// Each search's pages as gh --slurp gives them, into the wrappers file. Null unless
// every search came back whole and under the search cap: a short read undercounts.
export function wrappersFromPages(answers, at) {
  if (!Array.isArray(answers) || !answers.length) return null
  const by = new Map()
  for (const pages of answers) {
    if (!Array.isArray(pages) || !pages.length) return null
    let last = null
    for (const p of pages) {
      const s = p && p.data && p.data.wrappers
      if (!s || !Array.isArray(s.nodes) || !Number.isInteger(s.issueCount) || s.issueCount > SEARCH_CAP) return null
      for (const n of s.nodes) {
        if (!n || n.number == null) continue
        const labels = ((n.labels && n.labels.nodes) || []).map((l) => l && l.name).filter(Boolean)
        if (!wrapperOf(n.title, labels) && !postLaunchMilestone(n.milestone)) continue
        by.set(n.number, { number: n.number, title: n.title, labels, state: n.state || null, stateReason: n.stateReason || null,
                           milestone: msTitle(n.milestone) || null, createdAt: n.createdAt || null, closedAt: n.closedAt || null })
      }
      last = s
    }
    if (!last.pageInfo || last.pageInfo.hasNextPage !== false) return null
  }
  return { at, scope: rowsKey(), issues: [...by.values()] }
}

// How many tickets the scoped search counted that are not the release — its wrappers
// and its post-launch milestones — were added, or closed as done, in [from, to).
export function wrappersIn(w, kind, from, to) {
  if (!w || !Array.isArray(w.issues)) return 0
  const inside = (ts) => { const t = Date.parse(ts); return Number.isFinite(t) && t >= from && t < to }
  return w.issues.filter((i) => searchScope(i.labels) && (wrapperOf(i.title, i.labels) || postLaunchMilestone(i.milestone))
    && (kind === 'added' ? inside(i.createdAt)
      : i.state === 'CLOSED' && i.stateReason === 'COMPLETED' && inside(i.closedAt))).length
}

let wrappersTried = 0, wrappersBusy = false
function refreshWrappers(now) {
  if (!REPO || wrappersBusy || now - wrappersTried < TREND_MS) return
  try { if (now - fs.statSync(WRAPPERS_FILE).mtimeMs < TREND_MS && sameScope(WRAPPERS_FILE, rowsKey())) return } catch {}
  wrappersTried = now
  if (allowanceLow()) return
  const calls = wrapperSearches(REPO)
  const keep = (outs) => {
    let w = null
    try { w = wrappersFromPages(outs.map((o) => JSON.parse(o)), iso(now)) } catch {}
    if (!w) return
    try {
      fs.mkdirSync(path.dirname(WRAPPERS_FILE), { recursive: true })
      fs.writeFileSync(WRAPPERS_FILE + '.tmp', JSON.stringify(w))
      fs.renameSync(WRAPPERS_FILE + '.tmp', WRAPPERS_FILE)
    } catch {}
  }
  if (!calls.length) { keep([]); return }
  if (process.env.SWARM_PROGRESS_SYNC) {
    const outs = []
    for (const a of calls) {
      noteGh(['api', 'graphql'])
      try { outs.push(execFileSync(GH, a, { timeout: 120_000, encoding: 'utf8', maxBuffer: 64 * 1024 * 1024 })) } catch { return }
    }
    keep(outs)
    return
  }
  wrappersBusy = true
  const outs = []
  const next = (i) => {
    if (i >= calls.length) { wrappersBusy = false; keep(outs); return }
    noteGh(['api', 'graphql'])
    execFile(GH, calls[i], { timeout: 120_000, maxBuffer: 64 * 1024 * 1024 }, (err, out) => {
      if (err) { wrappersBusy = false; return }
      outs.push(out); next(i + 1)
    })
  }
  next(0)
}

// Done of the whole before-launch list, the pace, and where that pace lands.
// Burn is the average of (done - added) over the last whole days; at zero or
// below there is no date, because the list is not getting shorter.
// The trend is search counts, which cannot see a title; the wrappers read beside it
// comes off every one of them, so open, done and added are one population. No
// wrappers read is no release: a total of work plus containers is the wrong number.
export function launchOf(board, trend, wrappers, now = Date.now()) {
  if (!board || !trend || !Array.isArray(trend.days) || !wrappers || !Array.isArray(wrappers.issues)) return null
  // Counts read under another scope are of other tickets: no release until they are re-read.
  if (trend.scope !== scopeClause() || wrappers.scope !== rowsKey()) return null
  const open = board.releaseLeft
  const done = Math.max(0, trend.doneSinceBase - wrappersIn(wrappers, 'done', Date.parse(baseStart(trend.base)), Infinity))
  const total = done + open
  const days = trend.days.map((d) => {
    const [y, m, dd] = d.day.split('-').map(Number)
    const from = new Date(y, m - 1, dd).getTime(), to = new Date(y, m - 1, dd + 1).getTime()
    return { ...d, added: Math.max(0, d.added - wrappersIn(wrappers, 'added', from, to)),
             done: Math.max(0, d.done - wrappersIn(wrappers, 'done', from, to)) }
  })
  trend = { ...trend, days }
  const whole = trend.days.filter((d) => d.day !== localDay(now)).slice(-TREND_DAYS)
  const burn = whole.length ? whole.reduce((a, d) => a + d.done - d.added, 0) / whole.length : null
  const converging = burn != null && burn > 0
  let eta = null
  if (converging) { const e = new Date(now); e.setDate(e.getDate() + Math.ceil(open / burn)); eta = localDay(e.getTime()) }
  return { base: trend.base, done, open, product: board.product, tooling: board.tooling, total, pct: total ? Math.round((done * 1000) / total) / 10 : 0,
           burn: burn == null ? null : Math.round(burn * 10) / 10, converging, eta, days: trend.days, at: trend.at,
           today: trend.days.find((d) => d.day === localDay(now)) || null }
}

// A pull request that cannot go to the owner yet: a check failed or it clashes.
const RED_RUN = new Set(['FAILURE', 'ERROR', 'TIMED_OUT', 'CANCELLED', 'ACTION_REQUIRED', 'STARTUP_FAILURE'])
export const prRed = (p) => p.mergeable === 'CONFLICTING'
  || (p.statusCheckRollup || []).some((c) => c && (RED_RUN.has(c.conclusion) || RED_RUN.has(c.state)))

// The words each bucket is shown with, in the order the page lists them. Every
// before-launch ticket lands in exactly one, so the chips add up to the headline.
export const BUCKETS = {
  ready: 'Ready',
  building: 'Building',
  review: 'In review',
  pm: 'Waiting on PM',
  owner: `Waiting on ${OWNER}`,
  stuck: 'Blocked, drafting or parked',
  batched: 'Folded into a batch',
  other: 'Not sorted yet',
}
const OWNER_LABELS = [LBL('LBL_OWNER_DECISION', 'needs:owner-decision'), LBL('HOLD_LABEL', 'needs:human-approval'),
  LBL('LBL_NEEDS_HUMAN', 'status:needs-human')]
const PM_LABELS = [LBL('LBL_PM_DECISION', 'status:pm-decision'), LBL('LBL_PM_TRACK', 'status:pm-track'), 'needs:design', 'needs:data-model']
const STUCK_LABELS = [LBL('LBL_BLOCKED', 'status:blocked'), LBL('LBL_EXTERNAL_BLOCKED', 'status:external-blocked'),
  LBL('LBL_GATED', 'status:gated'), LBL('LBL_DRAFTING', 'status:drafting'), LBL('LBL_PARKED', 'status:parked')]

// Where one open ticket stands, first match wins. Owner waits come before review
// only while its pull request is clean: a red or clashing one is healing work first.
// Building is a live run, never the claimed label: a label outlives the run that set it.
export function bucketOf(labels, pr, building) {
  const has = (l) => labels.includes(l)
  if (building) return 'building'
  const ownerWait = OWNER_LABELS.some(has) || (pr && pr.held)
  if (ownerWait && !(pr && pr.red)) return 'owner'
  if (pr || has(LBL('LBL_IN_REVIEW', 'status:in-review')) || has('status:merged-needs-rollout')) return 'review'
  if (PM_LABELS.some(has)) return 'pm'
  if (STUCK_LABELS.some(has)) return 'stuck'
  if (has(LBL('LBL_BATCHED', 'status:batched'))) return 'batched'
  if (has(LBL('LBL_READY', 'status:ready'))) return 'ready'
  return 'other'
}

// Needs you is everything labelled for the owner (Dom, 2026-10-20: "Everything
// labelled for you"): every open issue and every open pull request carrying one of
// these, whatever else it is — red, after launch or a container. One row each.
const OWNER_ASK = listOf(process.env.SWARM_OWNER_LABELS, [LBL('LBL_OWNER_DECISION', 'needs:owner-decision'),
  LBL('LBL_NEEDS_HUMAN', 'status:needs-human'), 'needs:data-model', LBL('HOLD_LABEL', 'needs:human-approval')])
const ASK_WORDS = { [LBL('LBL_OWNER_DECISION', 'needs:owner-decision')]: 'A decision', [LBL('LBL_NEEDS_HUMAN', 'status:needs-human')]: 'Your input',
  'needs:data-model': 'A data model to approve', [LBL('HOLD_LABEL', 'needs:human-approval')]: 'A sign-off' }
const labelNames = (ls) => (ls || []).map((l) => (typeof l === 'string' ? l : l && l.name)).filter(Boolean)
export function needsYouOf(open, prs) {
  const out = []
  const add = (kind, number, title, labels) => {
    const asks = OWNER_ASK.filter((l) => labels.includes(l))
    if (!asks.length) return
    out.push({ kind, number: String(number), title: title || `${kind === 'pr' ? 'Pull request' : 'Ticket'} ${number}`,
               why: asks.map((l) => ASK_WORDS[l] || l).join(' · ') })
  }
  for (const i of open || []) if (i && i.number != null) add('issue', i.number, i.title, i.labels || [])
  for (const p of Array.isArray(prs) ? prs : []) if (p && p.number != null) add('pr', p.number, plainTitle(p.title), labelNames(p.labels))
  return out.sort((a, b) => Number(a.number) - Number(b.number) || (a.kind < b.kind ? -1 : 1))
}

export function boardOf(board, ctx, now = Date.now()) {
  if (!board || !Array.isArray(board.open) || board.scope !== scopeClause()) return null
  const counts = Object.fromEntries(Object.keys(BUCKETS).map((k) => [k, 0]))
  const outside = { lower: 0, post: 0, batch: 0, epic: 0, parked: 0 }
  let tooling = 0
  const lowerSeen = new Set()
  // Another host's claim is its live run; one on this host without a run here is stale.
  const here = new Set([THIS_HOST, ...(ctx.liveHosts || [])].filter(Boolean))
  const claimed = new Set((board.claims || []).filter((c) => !here.has(hostName(c.host))).map((c) => c.issue))
  for (const i of board.open) {
    const labels = i.labels || []
    const r = releaseOf(i.raw ?? i.title, labels, i.milestone)
    if (r === 'lower') { const p = labels.find((l) => /^P[0-9]$/.test(l)); lowerSeen.add(p || 'none') }
    if (r !== 'release') { outside[r]++; continue }
    if (toolingOf(labels, i.raw ?? i.title)) tooling++
    const t = String(i.number)
    const pr = ctx.prRows[t]
    counts[bucketOf(labels, pr, ctx.live.has(t) || claimed.has(t))]++
  }
  const total = Object.values(counts).reduce((a, b) => a + b, 0)
  // Today's counts belong to the day they were read on; past midnight they say nothing.
  // They are search counts, so the wrappers come off them; unread wrappers are no count.
  const wr = ctx.wrappers
  const since = Date.parse(board.since)
  const less = (n, k) => (Number.isInteger(n) ? Math.max(0, n - wrappersIn(wr, k, since, Infinity)) : null)
  const today = board.since === dayStart(now) && wr && wr.scope === rowsKey()
    ? { merged: board.mergedToday, done: less(board.doneToday, 'done'), made: less(board.newToday, 'added') }
    : null
  if (today) today.delta = today.done != null && today.made != null ? today.done - today.made : null
  return { at: board.at || null, releaseLeft: total, product: total - tooling, tooling, outside,
           priorities: RELEASE_PRIORITIES, lowerPriorities: [...lowerSeen].sort(), afterLabel: AFTER_LAUNCH,
           buckets: Object.keys(BUCKETS).map((k) => ({ key: k, label: BUCKETS[k], n: counts[k] })),
           needsYou: needsYouOf(board.open, ctx.prList), today, claims: board.claims || null }
}

// The newest five-hour reading the coordinator took whose window is still open.
export function usageOf(file = PACE_FILE, now = Date.now()) {
  let rows
  try { rows = fs.readFileSync(file, 'utf8').trim().split('\n') } catch { return null }
  for (let i = rows.length - 1; i >= 0; i--) {
    const [at, u, r] = rows[i].split('\t').map(Number)
    if (Number.isFinite(u) && Number.isFinite(r) && r * 1000 > now) {
      return { pct: Math.round(u * 100), resets: new Date(r * 1000).toISOString(), readAt: new Date(at * 1000).toISOString() }
    }
  }
  return null
}

// A ticket's title: its own read when that named one, else the board's.
const titleOf = (t) => (titles[t] && titles[t].title ? titles[t] : { ...titles[t], ...boardTitle(t) })
// A ticket's title from the board, for a row whose own title read has not landed.
function boardTitle(ticket) {
  const b = readJsonCached(BOARD_FILE)
  const i = b && Array.isArray(b.open) ? b.open.find((x) => x && String(x.number) === String(ticket)) : null
  return i && i.title ? { title: i.title } : {}
}

const hostName = (h) => String(h || '').replace(/^.*@/, '')
const THIS_HOST = process.env.SWARM_HOST || os.hostname().split('.')[0]
// Who is building where: this machine's live runs, and every other host's claims.
export function hostsOf(live, claims) {
  const by = {}
  for (const a of live) if (a.host) by[a.host] = (by[a.host] || 0) + 1
  const here = new Set([THIS_HOST, ...live.map((a) => a.host)].filter(Boolean))
  for (const c of claims || []) {
    const h = hostName(c.host)
    if (here.has(h) && !live.some((a) => a.ticket === c.issue)) continue
    if (h && !(h in by)) by[h] = 0
    if (h && !live.some((a) => a.ticket === c.issue)) by[h]++
  }
  return Object.entries(by).filter(([, n]) => n > 0).map(([host, n]) => ({ host, n })).sort((a, b) => b.n - a.n)
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
    const t = titleOf(run.ticket)
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
      host: hostName(run.host || run.operator),
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
  const prRows = prRowsByTicket()
  const ctx = { issues: issuesByTicket(), prs: Object.fromEntries(Object.entries(prRows).map(([t, r]) => [t, r.number])),
                prRows, prList: readJsonCached(PRS_FILE), live: new Set(live.map((a) => a.ticket)), liveHosts: live.map((a) => a.host), queued: new Set(queued.tickets.map((r) => r.ticket)) }
  const doneRows = [...newest.values()].sort((a, b) => b.endedAt - a.endedAt).slice(0, 20)
    .map(({ park, endedAt, ...d }) => ({ ...d, now: nowOf({ ...d, park }, ctx) }))
  refreshProgress(live.map((a) => a.ticket), [...new Set(live.map((a) => a.project).filter(Boolean))], now)
  refreshHold(now)
  refreshBoard(now)
  refreshTrend(now)
  refreshWrappers(now)
  ctx.wrappers = readJsonCached(WRAPPERS_FILE)
  const board = boardOf(readJsonCached(BOARD_FILE), ctx, now)
  const launch = launchOf(board, readJsonCached(TREND_FILE), ctx.wrappers, now)
  const queue = queued
  for (const r of queue.tickets) {
    fetchTitle(r.ticket)
    const t = titleOf(r.ticket)
    r.title = t.title || `Ticket ${r.ticket}`
  }
  // `at` is the whole staleness contract: every reader discards an answer older
  // than its own ceiling rather than believing a machine that has moved on.
  return { at: new Date(now).toISOString(), repo: REPO, load: os.loadavg()[0],
           plans: plansOf(live, progress.plans, plainName), live, done: doneRows, doneSummary: doneSummary(doneRows),
           hold, queue, capacity: capacityOf(), board, launch, usage: usageOf(PACE_FILE, now),
           hosts: hostsOf(live, board && board.claims),
           rules: { priorities: RELEASE_PRIORITIES, postLaunchMilestones: POST_LAUNCH_MILESTONES, afterLaunchLabel: AFTER_LAUNCH,
                    toolingLabels: TOOLING_LABELS, toolingScopes: TOOLING_SCOPES, ownerLabels: OWNER_ASK } }
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
