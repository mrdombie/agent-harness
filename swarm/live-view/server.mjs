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
import { execFileSync, spawn } from 'node:child_process'
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
// Every machine's heartbeat and the sheet's version floor, as the last tick knew them.
const COORD_FLEET = path.join(path.dirname(COORD_QUEUE), 'fleet.json')
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
const WIN = process.platform === 'win32'

// A refresh or cache write that fails (ENOSPC included) is logged and skipped: the
// page answers from what it already has. Once a minute per kind, so a full disk is
// one line a minute, not one a request.
const warned = new Map()
function warn(what, e) {
  const now = Date.now()
  if (now - (warned.get(what) || 0) < 60_000) return
  warned.set(what, now)
  const why = typeof e?.code === 'number' ? `exit ${e.code}` : (e?.code || e?.message || e)
  try { console.error(`live-view: ${what} failed: ${why}`) } catch {}
}
const guard = (what, fn) => { try { fn() } catch (e) { warn(what, e) } }
// A child run in its own process group and killed whole at its deadline. execFile's
// own timeout kills only the child, and a grandchild still holding the pipe keeps
// the callback, and the refresh's in-flight flag, pending for ever.
const REFRESH_TIMEOUT_MS = Number(process.env.SWARM_REFRESH_TIMEOUT_MS || 0)
function runChild(what, cmd, args, opts, done) {
  const ms = REFRESH_TIMEOUT_MS || opts.timeout || 60_000
  let settled = false, child = null, timer = null
  const finish = (err, out) => {
    if (settled) return
    settled = true
    clearTimeout(timer)
    // A command that exits non-zero has answered; only a hang or a failed start is news.
    if (err && typeof err.code !== 'number') warn(what, err)
    try { done(err, out) } catch (e) { warn(what, e) }
  }
  // spawn, not execFile: execFile drops `detached`, and the group kill below needs it.
  const max = opts.maxBuffer || 1024 * 1024, out = []
  let size = 0
  try { child = spawn(cmd, args, { env: opts.env, detached: !WIN, windowsHide: true, stdio: ['ignore', 'pipe', 'ignore'] }) } catch (e) { finish(e); return }
  child.on('error', (e) => finish(e))
  child.stdout.on('data', (d) => {
    size += d.length
    if (size <= max) out.push(d)
    else { try { child.kill('SIGKILL') } catch {} ; finish(Object.assign(new Error('maxBuffer exceeded'), { code: 'EMAXBUFFER' })) }
  })
  child.on('close', (code, sig) => finish(code === 0 ? null : Object.assign(new Error(`exit ${code ?? sig}`), { code: code ?? sig }), Buffer.concat(out).toString('utf8')))
  timer = setTimeout(() => {
    try { if (WIN) child.kill('SIGKILL'); else process.kill(-child.pid, 'SIGKILL') } catch {}
    finish(Object.assign(new Error(`no answer in ${ms} ms`), { code: 'EDEADLINE' }))
  }, ms)
  timer.unref?.()
}

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
    } catch (e) { warn('progress cache', e) }
  }
  if (process.env.SWARM_PROGRESS_SYNC) { try { keep(gatherProgress(args)) } catch {} ; return }
  gathering = true
  runChild('progress', process.execPath, [PROGRESS_JS, '--gather', JSON.stringify(args)],
    { timeout: 300_000, maxBuffer: 64 * 1024 * 1024 }, (err, out) => {
      gathering = false
      if (err) return
      try { keep(JSON.parse(out)) } catch {}
    })
}

let holdAt = 0, hold = { held: false }, holding = false
function refreshHold(now) {
  if (holding || now - holdAt < HOLD_MS) return
  holdAt = now
  const take = (out) => { try { const j = JSON.parse(out); if (j && typeof j === 'object') hold = j } catch {} }
  if (process.env.SWARM_PROGRESS_SYNC) {
    try { take(execFileSync(BASH, [HOLD_SCRIPT], { timeout: 20_000, encoding: 'utf8' })) } catch {}
    return
  }
  holding = true
  runChild('hold', BASH, [HOLD_SCRIPT], { timeout: 20_000 }, (err, out) => { holding = false; if (!err) take(out) })
}

const RANK = { repair: 0, 'approved-merge': 1, new: 2 }
// A process fix runs first of all (coord_process, owner call 2026-10-20).
const PROCESS = process.env.SWARM_PROCESS_LABEL || 'process'
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
// The queue in the order the coordinator runs it: a process fix first of all, then an entry the PM put on top,
// then priority (none last), and within one priority a front entry (a resume, an
// answer) first, then class, product before tooling, then kind for new work, then
// position — the same order as coord_queue_ordered. An unknown class sorts last.
// Only rows somebody can start are listed, so the count is the work there is.
export function queueOf(file = COORD_QUEUE, issues = issuesByTicket()) {
  let q
  try { q = JSON.parse(fs.readFileSync(file, 'utf8')) } catch { return { scopes: [], tickets: [], processFirst: 0 } }
  const fallback = q.label || q.scope || ''
  const rows = (Array.isArray(q.tickets) ? q.tickets : [])
    .filter((t) => t && t.n != null)
    .map((t) => ({ ...t, class: classOf(t) }))
    .filter((t) => startable(t.class, issues[String(t.n)]))
    .map((t, pos) => ({ t, pos, proc: (issues[String(t.n)] ? (issues[String(t.n)].labels || []).includes(PROCESS) : !!t.process) ? 0 : 1,
                        top: t.top ? 0 : 1, front: t.front ? 0 : 1, prin: Number.isInteger(t.prin) ? t.prin : 9,
                        rank: RANK[t.class] ?? 3, tool: t.tooling ? 1 : 0, kind: t.class === 'new' ? (KIND[t.kind] ?? 2) : 0 }))
    .sort((a, b) => a.proc - b.proc || a.top - b.top || (a.top === 0 ? a.pos - b.pos : 0) || a.prin - b.prin
                    || a.front - b.front || (a.front === 0 ? a.pos - b.pos : 0)
                    || a.rank - b.rank || a.tool - b.tool || a.kind - b.kind || a.pos - b.pos)
    .map(({ t, proc }) => ({ ticket: String(t.n), class: String(t.class || 'new'), note: String(t.note || ''),
                       scope: String(t.scope || fallback), pinned: !!t.pinned, process: proc === 0 }))
  const scopes = Array.isArray(q.scopes) ? q.scopes.map((s) => String(s.label || s.scope || s))
    : [...new Set(rows.map((r) => r.scope).filter(Boolean))]
  return { scopes, seededAt: q.seeded_at || null, tickets: rows, processFirst: rows.filter((r) => r.process).length }
}

// Free disk, read now: under the guard's floor nothing new starts (scripts/disk-guard.sh). The
// floor and the resume mark come from live-view.sh; the hold is the guard's own file.
const DISK_STOP = Number(process.env.SWARM_DISK_STOP_BELOW_GB || 30)
const DISK_RESUME = Number(process.env.SWARM_DISK_RESUME_AT_GB || 50)
const DISK_HOLD = process.env.SWARM_DISK_HOLD_FILE || path.join(path.dirname(COORD_QUEUE), 'disk-hold')
const DISK_AT = process.env.HARNESS_STATE_DIR || path.join(RUNS, '..')
// Under WSL the guard names the Windows drive too (disk-guard.sh host): Linux's figure is the
// virtual disk's, which can show 831 GB free on a host drive with 37. The lower one counts.
function freeGbAt(at, planted) {
  if (planted != null && planted !== '') return /^\d+$/.test(planted) ? Number(planted) : null
  try { const st = fs.statfsSync(at); return Math.floor(Number(st.bavail) * Number(st.bsize) / 2 ** 30) } catch { return null }
}
export function diskOf() {
  const linux = freeGbAt(fs.existsSync(DISK_AT) ? DISK_AT : os.homedir(), process.env.SWARM_FREE_DISK_GB)
  const hostPath = process.env.SWARM_DISK_HOST_PATH || ''
  let free = linux, where = ''
  if (hostPath) {
    const host = freeGbAt(hostPath, process.env.SWARM_HOST_FREE_DISK_GB)
    if (host != null && (linux == null || host < linux)) { free = host; where = linux == null ? 'on the Windows host' : `on the Windows host (Linux shows ${linux})` }
    else if (linux != null) where = host == null ? `on Linux (the Windows host at ${hostPath} could not be read)` : `on Linux (the Windows host shows ${host})`
  }
  return { freeGb: free, stopBelowGb: DISK_STOP, resumeAtGb: DISK_RESUME, held: fs.existsSync(DISK_HOLD),
           low: free != null && free < DISK_STOP, ...(where ? { where } : {}) }
}

// One row per machine: its harness, disk, builds and how long since its last tick.
export function fleetOf(file = COORD_FLEET, now = Date.now()) {
  let f
  try { f = JSON.parse(fs.readFileSync(file, 'utf8')) } catch { return null }
  if (!f || !Array.isArray(f.hosts)) return null
  const num = (v) => (typeof v === 'number' && Number.isFinite(v) ? v : null)
  return {
    minHarness: f.minHarness || null,
    owner: f.owner || null,
    hosts: f.hosts.filter((h) => h && h.host).map((h) => ({
      host: String(h.host), version: h.version || null, freeGb: num(h.freeGb), builds: num(h.builds) ?? 0,
      tickAgoMin: num(h.tick) == null ? null : Math.max(0, Math.round((now / 1000 - h.tick) / 60)), behind: !!h.behind,
      tick: num(h.tick), runs: Array.isArray(h.runs) ? h.runs.filter((r) => r && r.t != null) : [] })),
  }
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
  runChild('title', GH, ['issue', 'view', String(ticket), '--repo', REPO, '--json', 'title,labels'],
    { timeout: 20_000 }, (err, out) => {
      pending.delete(ticket)
      if (err) return
      try {
        const j = JSON.parse(out)
        const programme = (j.labels || []).map((l) => l.name).find((n) => n.startsWith(PREFIX)) || ''
        titles[ticket] = { title: plainTitle(j.title), project: programme.slice(PREFIX.length) }
        fs.writeFileSync(TITLES, JSON.stringify(titles))
      } catch (e) { warn('title cache', e) }
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
export function prRowsByTicket(file = PRS_FILE, heads = (readJsonCached(PR_STATES_FILE) || {}).heads || null) {
  const rows = readJsonCached(file)
  const by = {}
  if (!Array.isArray(rows)) return by
  const hold = LBL('HOLD_LABEL', 'needs:human-approval')
  for (const p of rows) {
    if (!p || p.number == null) continue
    const ts = new Set((p.closingIssuesReferences || []).map((r) => String(r && r.number)).filter((n) => n !== 'undefined'))
    const bt = branchTicket(p.headRefName)
    if (bt) ts.add(bt)
    // A copy read on an older head says nothing about the newest push: no clash, no red from it.
    const status = heads && heads[String(p.number)] && p.headRefOid && heads[String(p.number)] !== p.headRefOid
      ? { state: 'checks', text: 'Waiting for checks on the newest push' } : openPrState(p)
    const row = { number: p.number, red: ['clash', 'failed'].includes(status.state),
                  held: (p.labels || []).some((l) => (typeof l === 'string' ? l : l && l.name) === hold), status }
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
// Where a finished ticket's pull request stands, beyond the open ones the tick shares:
// the newest closed ones and what merged into the trunk today. Two REST calls, never
// GraphQL (the shared GraphQL allowance ran out twice on 2026-10-21), never per row,
// kept PR_STATES_MS and at least a minute.
const PR_STATES_FILE = process.env.SWARM_PR_STATES_FILE || path.join(path.dirname(BOARD_FILE), 'pr-states.json')
const PR_STATES_MS = Math.max(60_000, Number(process.env.SWARM_PR_STATES_MS || 120_000))
const TRUNK = process.env.SWARM_INTEGRATION_BRANCH || process.env.INTEGRATION_BRANCH || 'develop'

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
    return j.filter((c) => c && c.issue != null).map((c) => ({ issue: String(c.issue), host: String(c.host || ''),
      step: c.step ? String(c.step) : null, claimedAt: c.claimed_at ? String(c.claimed_at) : null }))
  } catch { return null }
}

// The claims, kept apart from the board: the board waits on forge reads and the
// allowance, a claim list is one git fetch and changes by the minute. One call in
// flight, killed at its deadline, never on the request path.
const CLAIMS_FILE = process.env.SWARM_CLAIMS_FILE || path.join(path.dirname(BOARD_FILE), 'claims.json')
const CLAIMS_MS = Math.max(15_000, Number(process.env.SWARM_CLAIMS_MS || 60_000))
const CLAIMS_TIMEOUT_MS = Number(process.env.SWARM_CLAIMS_TIMEOUT_MS || 30_000)
// Older than this, a kept list says nothing about who is building now.
const CLAIMS_MAX_AGE_MS = Math.max(CLAIMS_MS * 3, 600_000)
let claimsTried = 0, claimsBusy = false
function refreshClaims(now) {
  if (!CLAIM_LOCK || claimsBusy || now - claimsTried < CLAIMS_MS) return
  try { if (now - fs.statSync(CLAIMS_FILE).mtimeMs < CLAIMS_MS) return } catch {}
  claimsTried = now
  const keep = (out) => {
    const claims = claimsFromList(out)
    if (!claims) return
    try {
      fs.mkdirSync(path.dirname(CLAIMS_FILE), { recursive: true })
      fs.writeFileSync(CLAIMS_FILE + '.tmp', JSON.stringify({ at: new Date(now).toISOString(), claims }))
      fs.renameSync(CLAIMS_FILE + '.tmp', CLAIMS_FILE)
    } catch (e) { warn('claims cache', e) }
  }
  const env = { ...process.env, CLAIM_REPO: QUEUE_REPO || process.env.CLAIM_REPO || '' }
  if (process.env.SWARM_PROGRESS_SYNC) {
    try { keep(execFileSync(CLAIM_LOCK, ['list', '--json'], { timeout: CLAIMS_TIMEOUT_MS, encoding: 'utf8', env })) } catch {}
    return
  }
  claimsBusy = true
  runChild('claims', CLAIM_LOCK, ['list', '--json'], { timeout: CLAIMS_TIMEOUT_MS, env }, (err, out) => {
    claimsBusy = false
    if (!err) keep(out)
  })
}
// The kept claim list, or null when there is none young enough to believe.
function claimsNow(now) {
  const j = readJsonCached(CLAIMS_FILE)
  if (!j || !Array.isArray(j.claims) || !(now - Date.parse(j.at) < CLAIMS_MAX_AGE_MS)) return null
  return j.claims
}

// The two calls: the 100 most recently updated closed pull requests, and today's merges into the trunk.
export function prStateArgs(repo, since, trunk = TRUNK) {
  return [
    ['api', `repos/${repo}/pulls?state=closed&sort=updated&direction=desc&per_page=100`, '--jq',
     '[.[] | {number, title, mergedAt: .merged_at, closedAt: .closed_at, head: .head.ref, body: ((.body // "")[0:4000])}]'],
    ['api', 'search/issues', '-X', 'GET', '-f', `q=repo:${repo} is:pr is:merged base:${trunk} merged:>=${since}`, '-f', 'per_page=100',
     '--jq', '{total: .total_count, items: [.items[] | {number, title, mergedAt: (.pull_request.merged_at // .closed_at)}]}'],
    // The newest-updated open pull requests' heads: a state read off the shared copy is
    // only believed for the head it was read on. Optional: without it the copy stands.
    ['api', `repos/${repo}/pulls?state=open&sort=updated&direction=desc&per_page=100`, '--jq', '[.[] | {number, head: .head.sha}]'],
  ]
}
// Both answers as the file keeps them; null unless both are the shape asked for.
export function prStatesFrom(outs, since, at) {
  let closed, merged
  try { closed = JSON.parse(outs[0]); merged = JSON.parse(outs[1]) } catch { return null }
  if (!Array.isArray(closed) || !merged || !Number.isInteger(merged.total) || !Array.isArray(merged.items)) return null
  let heads = null
  try { const h = JSON.parse(outs[2]); if (Array.isArray(h)) heads = Object.fromEntries(h.filter((x) => x && x.number != null && x.head).map((x) => [String(x.number), String(x.head)])) } catch {}
  return { at, since, trunk: TRUNK, closed: closed.filter((p) => p && p.number != null), merged, heads }
}
let prStatesTried = 0, prStatesBusy = false
function refreshPrStates(now) {
  if (!REPO || prStatesBusy || now - prStatesTried < PR_STATES_MS) return
  const since = dayStart(now)
  try { if (now - fs.statSync(PR_STATES_FILE).mtimeMs < PR_STATES_MS && (readJsonCached(PR_STATES_FILE) || {}).since === since) return } catch {}
  prStatesTried = now
  if (allowanceLow()) return
  const calls = prStateArgs(REPO, since)
  const keep = (outs) => {
    const v = prStatesFrom(outs, since, iso(now))
    if (!v) return
    try {
      fs.mkdirSync(path.dirname(PR_STATES_FILE), { recursive: true })
      fs.writeFileSync(PR_STATES_FILE + '.tmp', JSON.stringify(v))
      fs.renameSync(PR_STATES_FILE + '.tmp', PR_STATES_FILE)
    } catch (e) { warn('pr states cache', e) }
  }
  if (process.env.SWARM_PROGRESS_SYNC) {
    const outs = []
    for (const a of calls) {
      noteGh(a)
      try { outs.push(execFileSync(GH, a, { timeout: 60_000, encoding: 'utf8', maxBuffer: 16 * 1024 * 1024 })) } catch { if (outs.length < 2) return; break }
    }
    keep(outs)
    return
  }
  prStatesBusy = true
  const outs = []
  const next = (i) => {
    if (i >= calls.length) { prStatesBusy = false; keep(outs); return }
    noteGh(calls[i])
    runChild('pr states', GH, calls[i], { timeout: 60_000, maxBuffer: 16 * 1024 * 1024 }, (err, out) => {
      if (err) { prStatesBusy = false; if (outs.length >= 2) keep(outs); return }
      outs.push(out)
      try { next(i + 1) } catch (e) { prStatesBusy = false; throw e }
    })
  }
  next(0)
}

// ticket -> its newest closed pull request: by branch, or by a closing word in its body.
const CLOSES_RE = /\b(?:close[sd]?|fix(?:e[sd])?|resolve[sd]?)\s*:?\s+#(\d+)/gi
export function closedByTicket(v) {
  const by = {}
  for (const p of (v && Array.isArray(v.closed) ? v.closed : [])) {
    const ts = new Set([...String(p.body || '').matchAll(CLOSES_RE)].map((m) => m[1]))
    const bt = branchTicket(p.head)
    if (bt) ts.add(bt)
    const row = { number: p.number, mergedAt: p.mergedAt || null, closedAt: p.closedAt || null }
    for (const t of ts) if (!(t in by) || p.number > by[t].number) by[t] = row
  }
  return by
}

export function closedByNumber(v) {
  const by = {}
  for (const p of (v && Array.isArray(v.closed) ? v.closed : [])) by[String(p.number)] = { number: p.number, mergedAt: p.mergedAt || null, closedAt: p.closedAt || null }
  return by
}

// "14:05" today, "Tue 20 Oct 14:05" before: the time a person reads off a row.
const pad2 = (n) => String(n).padStart(2, '0')
export function clockOf(ts, now = Date.now()) {
  const d = new Date(ts)
  if (isNaN(d)) return ''
  const hm = `${pad2(d.getHours())}:${pad2(d.getMinutes())}`
  if (localDay(d.getTime()) === localDay(now)) return hm
  return `${d.toLocaleDateString('en-GB', { weekday: 'short', day: 'numeric', month: 'short' })} ${hm}`
}

// Merged today: count and rows, only when read today.
export function mergedTodayOf(v, now = Date.now()) {
  if (!v || !v.merged || v.since !== dayStart(now)) return null
  const items = v.merged.items.filter((i) => i && i.number != null)
    .map((i) => ({ number: String(i.number), title: plainTitle(i.title), mergedAt: i.mergedAt || null, time: i.mergedAt ? clockOf(i.mergedAt, now) : '' }))
    .sort((a, b) => String(b.mergedAt).localeCompare(String(a.mergedAt)))
  return { since: v.since, at: v.at, trunk: v.trunk || TRUNK, total: v.merged.total, items }
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
    } catch (e) { warn('board cache', e) }
  }
  noteGh(['api', 'graphql'])
  if (process.env.SWARM_PROGRESS_SYNC) {
    let out = ''
    try { out = execFileSync(GH, args, { timeout: 120_000, encoding: 'utf8', maxBuffer: 64 * 1024 * 1024 }) } catch { return }
    keep(out, claimsNow(now))
    return
  }
  boardBusy = true
  runChild('board', GH, args, { timeout: 120_000, maxBuffer: 64 * 1024 * 1024 }, (err, out) => {
    boardBusy = false
    if (!err) keep(out, claimsNow(Date.now()))
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
    } catch (e) { warn('trend cache', e) }
  }
  noteGh(['api', 'graphql'])
  if (process.env.SWARM_PROGRESS_SYNC) {
    try { keep(execFileSync(GH, args, { timeout: 60_000, encoding: 'utf8' })) } catch {}
    return
  }
  trendBusy = true
  runChild('trend', GH, args, { timeout: 60_000 }, (err, out) => { trendBusy = false; if (!err) keep(out) })
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
    } catch (e) { warn('wrappers cache', e) }
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
    runChild('wrappers', GH, calls[i], { timeout: 120_000, maxBuffer: 64 * 1024 * 1024 }, (err, out) => {
      if (err) { wrappersBusy = false; return }
      outs.push(out)
      try { next(i + 1) } catch (e) { wrappersBusy = false; throw e }
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
// Read by each check's newest run, the same rule as openPrState.
export const prRed = (p) => ['clash', 'failed'].includes(openPrState(p).state)

// Where one OPEN pull request stands, in the words the page shows, first match wins.
// The approval check is red by design until the sign-off, so it is the sign-off, not
// a failure; the design critic still running is the design review.
const APPROVAL_RE = new RegExp(process.env.SWARM_APPROVAL_CHECKS || '^approval-gate', 'i')
const DESIGN_RE = new RegExp(process.env.SWARM_DESIGN_CHECKS || 'design critic|judge the composed screen', 'i')
const OK_RUN = new Set(['SUCCESS', 'NEUTRAL', 'SKIPPED'])
// Which checks block a merge: the trunk's ruleset, read once in REQUIRED_MS (at least ten
// minutes). Unread, every check counts. A check the project names report-only
// (release.nonBlockingChecks, via live-view.sh) never blocks, whatever the ruleset says.
const REQUIRED_FILE = process.env.SWARM_REQUIRED_CHECKS_FILE || path.join(RUNS, '..', 'swarm', 'required-checks.json')
// The gather child (progress.mjs) reads the same set for the live card's PR cell.
process.env.SWARM_REQUIRED_CHECKS_FILE = REQUIRED_FILE
const REQUIRED_MS = Math.max(600_000, Number(process.env.SWARM_REQUIRED_MS || 600_000))
const NON_BLOCKING = (() => { try { const j = JSON.parse(process.env.SWARM_NONBLOCKING_CHECKS || '[]'); return Array.isArray(j) ? j.map(String) : [] } catch { return [] } })()
export function checkRules() {
  const v = readJsonCached(REQUIRED_FILE)
  return { required: v && Array.isArray(v.contexts) && v.contexts.length ? new Set(v.contexts.map(String)) : null, nonBlocking: new Set(NON_BLOCKING) }
}
export const requiredArgs = (repo, trunk = TRUNK) => ['api', `repos/${repo}/rules/branches/${trunk}`, '--jq',
  '[.[] | select(.type == "required_status_checks") | .parameters.required_status_checks[]?.context]']
let requiredTried = 0, requiredBusy = false
function refreshRequired(now) {
  if (!REPO || requiredBusy || now - requiredTried < REQUIRED_MS) return
  try { if (now - fs.statSync(REQUIRED_FILE).mtimeMs < REQUIRED_MS) return } catch {}
  requiredTried = now
  if (allowanceLow()) return
  const a = requiredArgs(REPO)
  const keep = (out) => {
    let c
    try { c = JSON.parse(out) } catch { return }
    if (!Array.isArray(c)) return
    try {
      fs.mkdirSync(path.dirname(REQUIRED_FILE), { recursive: true })
      fs.writeFileSync(REQUIRED_FILE + '.tmp', JSON.stringify({ at: iso(now), branch: TRUNK, contexts: c.map(String) }))
      fs.renameSync(REQUIRED_FILE + '.tmp', REQUIRED_FILE)
    } catch (e) { warn('required checks cache', e) }
  }
  noteGh(a)
  if (process.env.SWARM_PROGRESS_SYNC) { try { keep(execFileSync(GH, a, { timeout: 30_000, encoding: 'utf8' })) } catch {} ; return }
  requiredBusy = true
  runChild('required checks', GH, a, { timeout: 30_000 }, (err, out) => { requiredBusy = false; if (!err) keep(out) })
}
// "Widths and contrast on changed routes" → "widths"; "Code gates" → "code gates".
const SHORT_STOP = new Set(['approved', 'does', 'which', 'did', 'the', 'a', 'every'])
export function shortCheck(n) {
  const w = String(n).split(/ \/ | — /)[0].replace(/[()]/g, '').trim().toLowerCase().split(/\s+/)
  return (w[0].length <= 5 || SHORT_STOP.has(w[0])) && w[1] ? `${w[0]} ${w[1]}` : w[0]
}

export function openPrState(p, rules = checkRules()) {
  const labels = labelNames(p.labels)
  const blocks = (n) => !rules.nonBlocking.has(n) && (!rules.required || rules.required.has(n))
  // One answer per check name, its NEWEST run: a run still going counts as newest, then
  // the latest finish. An older skipped run beside a newer failure is not a pass.
  const by = new Map()
  for (const c of p.statusCheckRollup || []) {
    if (!c) continue
    const name = String(c.name || c.context || 'a check')
    const busy = c.state ? /PENDING|EXPECTED/.test(c.state) : /IN_PROGRESS|QUEUED|PENDING|WAITING|REQUESTED/.test(c.status || '') || !c.conclusion
    const failed = !busy && (RED_RUN.has(c.conclusion) || /FAILURE|ERROR/.test(c.state || ''))
    const good = !busy && (OK_RUN.has(c.conclusion) || c.state === 'SUCCESS')
    const at = busy ? Infinity : Date.parse(c.completedAt || c.startedAt || c.createdAt || '') || 0
    const o = by.get(name)
    if (!o || at >= o.at) by.set(name, { busy, failed, good, at })
  }
  const names = [...by.entries()]
  // A report-only check that failed is a note beside the state, never the state.
  const reds = names.filter(([n, c]) => c.failed && !APPROVAL_RE.test(n)).map(([n]) => n)
  const failed = reds.filter(blocks)
  const notes = reds.filter((n) => !blocks(n)).map(shortCheck)
  const busy = names.filter(([n, c]) => c.busy && !APPROVAL_RE.test(n) && (blocks(n) || DESIGN_RE.test(n))).map(([n]) => n)
  const held = labels.includes(LBL('HOLD_LABEL', 'needs:human-approval'))
  const approvalWaits = names.some(([n, c]) => APPROVAL_RE.test(n) && !c.good)
  const n = notes.length ? { notes } : {}
  if (p.mergeable === 'CONFLICTING' || p.mergeStateStatus === 'DIRTY') return { state: 'clash', text: 'Clashes with newer code', ...n }
  const other = busy.filter((x) => !DESIGN_RE.test(x))
  if (failed.length) {
    const also = [failed.length > 1 ? `and ${failed.length - 1} more` : '', busy.length ? `${busy.length} still running` : ''].filter(Boolean).join(' · ')
    return { state: 'failed', text: `A check failed: ${failed[0]}${also ? ` (${also})` : ''}`, checks: failed, ...n }
  }
  if (other.length) return { state: 'checks', text: `Waiting for checks (${other.length} running)`, ...n }
  if (busy.length || labels.includes('needs:design')) return { state: 'design', text: 'Waiting for design review', ...n }
  if (held || approvalWaits) return { state: 'signoff', text: 'Waiting for sign-off', ...n }
  if (!names.length) return { state: 'checks', text: 'Waiting for checks (none started yet)' }
  return { state: 'ready', text: 'Checks passed — waiting to merge', ...n }
}

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

// By area (the owner, 2026-10-23: "see all this properly, per area"): every open ticket,
// grouped by the project's own section labels (liveView.sections, via SWARM_SECTIONS),
// counted by the board's buckets; tooling gets its own group; the rest is "Other".
const SECTIONS = (() => { try { const j = JSON.parse(process.env.SWARM_SECTIONS || '[]'); return Array.isArray(j) ? j.filter((x) => x && x.label && x.name) : [] } catch { return [] } })()
const PRIO_NAMES = { P0: 'Urgent', P1: 'High', P2: 'Normal', P3: 'Polish' }
export function areasOf(board, ctx, sections = SECTIONS) {
  if (!board || !Array.isArray(board.open) || !sections.length) return null
  const here = new Set([THIS_HOST, ...(ctx.liveHosts || [])].filter(Boolean))
  const claimed = new Set((board.claims || []).filter((c) => !here.has(hostName(c.host))).map((c) => c.issue))
  const groups = [...sections.map((s) => ({ key: s.label, name: s.name })), { key: '__tooling', name: 'Tooling' }, { key: '__other', name: 'Other' }]
  const by = Object.fromEntries(groups.map((g) => [g.key, { ...g, counts: {}, rows: [] }]))
  for (const i of board.open) {
    const labels = i.labels || []
    const t = String(i.number)
    const g = toolingOf(labels, i.raw ?? i.title) ? '__tooling' : (sections.find((s) => labels.includes(s.label)) || { label: '__other' }).label
    const r = releaseOf(i.raw ?? i.title, labels, i.milestone)
    // The same split as the headline (boardOf): only 'release' rows are release work; batches,
    // epics and parked tickets are counted beside it, never in it, so the areas add up to it.
    const bucket = r === 'release' ? bucketOf(labels, ctx.prRows[t], ctx.live.has(t) || claimed.has(t))
      : r === 'lower' ? 'later' : r === 'post' ? 'post' : r === 'parked' ? 'parked' : 'container'
    const p = labels.find((l) => /^P[0-9]$/.test(l))
    const row = by[g]
    row.counts[bucket] = (row.counts[bucket] || 0) + 1
    row.rows.push({ number: t, title: i.title, priority: PRIO_NAMES[p] || 'None', bucket, screen: labels.some((l) => l.startsWith('screen:')) })
  }
  const order = { building: 0, review: 1, ready: 2, pm: 3, owner: 4, stuck: 5, batched: 6, other: 7, parked: 8, later: 9, container: 10, post: 11 }
  const pr = { Urgent: 0, High: 1, Normal: 2, Polish: 3, None: 4 }
  for (const g of Object.values(by)) g.rows.sort((a, b) => order[a.bucket] - order[b.bucket] || pr[a.priority] - pr[b.priority] || Number(a.number) - Number(b.number))
  return { labels: { ...BUCKETS, parked: 'Parked', later: 'After higher priority', container: 'Batch or epic', post: 'After launch' },
           outside: ['parked', 'later', 'container', 'post'],
           groups: groups.map((g) => by[g.key]).filter((g) => g.rows.length) }
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

// Another machine's builds, from its claims: one row per ticket that is not running
// here. Its progress, activity and quiet time live in logs on that machine, so they
// are absent (null), never guessed. A claim on this host with no run is stale.
// A host's heartbeat older than this says nothing about its runs: the machine is not reporting.
const HB_STALE_MIN = Number(process.env.SWARM_HEARTBEAT_STALE_MIN || 15)
export function elsewhereOf(claims, live, now = Date.now(), title = () => ({}), fleet = null) {
  const hostBeat = (h) => ((fleet && fleet.hosts) || []).find((x) => String(x.host).toLowerCase() === String(h).toLowerCase()) || null
  const here = new Set([THIS_HOST, ...live.map((a) => a.host)].filter(Boolean))
  const seen = new Set(live.map((a) => a.ticket))
  const rows = []
  for (const c of claims || []) {
    const host = hostName(c.host)
    if (!host || here.has(host) || seen.has(c.issue)) continue
    seen.add(c.issue)
    const t = title(c.issue) || {}
    const at = Date.parse(c.claimedAt || '')
    // Its activity, from that machine's heartbeat: when the run last did anything and
    // its last line. A heartbeat gone quiet is the machine not reporting, not the run.
    const hb = hostBeat(host)
    const beatAt = hb && hb.tick != null ? hb.tick * 1000 : null
    const beatStale = beatAt == null || now - beatAt > HB_STALE_MIN * 60_000
    const run = !beatStale ? (hb.runs || []).find((r) => String(r.t) === String(c.issue)) : null
    const runAt = run && Number(run.at) > 0 ? Number(run.at) * 1000 : null
    rows.push({ ticket: c.issue, title: t.title || `Ticket ${c.issue}`, short: t.short || t.title || `Ticket ${c.issue}`,
                project: t.project || '', host, remote: true, claimStep: c.step || null,
                startedAgoMin: Number.isFinite(at) ? Math.max(0, Math.round((now - at) / 60000)) : null,
                progress: null, quietSec: runAt != null ? Math.max(0, Math.round((now - runAt) / 1000)) : null,
                steps: run && run.say ? [{ kind: 'say', text: String(run.say) }] : null,
                beatAt: beatAt != null ? new Date(beatAt).toISOString() : null, beatTime: beatAt != null ? clockOf(beatAt, now) : null,
                beatStale: hb ? beatStale : null })
  }
  return rows.sort((a, b) => (a.startedAgoMin ?? 1e9) - (b.startedAgoMin ?? 1e9))
}

// The words and tone a finished row's state is shown with, in the order the header
// counts them. A run that handed off a pull request is not a ticket that shipped:
// each row says where the ticket stands NOW, read from GitHub, and only a merge is "merged".
export const NOW_STATES = {
  merged: { tone: 'ok', count: 'merged' },
  ready: { tone: 'ok', count: 'ready to merge' },
  checks: { tone: 'neutral', count: 'waiting for checks' },
  design: { tone: 'warn', count: 'waiting for design review' },
  signoff: { tone: 'warn', count: 'waiting for sign-off' },
  failed: { tone: 'bad', count: 'a check failed' },
  clash: { tone: 'bad', count: 'clashing' },
  running: { tone: 'ok', count: 'running again' },
  queue: { tone: 'neutral', count: 'back in queue' },
  pm: { tone: 'warn', count: 'waiting on PM' },
  owner: { tone: 'warn', count: `waiting on ${OWNER}` },
  stopped: { tone: 'bad', count: 'stopped' },
  done: { tone: 'neutral', count: 'closed as done' },
  closed: { tone: 'neutral', count: 'closed' },
  unread: { tone: 'neutral', count: 'not read yet' },
  finished: { tone: 'neutral', count: 'no pull request' },
}

// What a run's exit code means, and who moves it on (driver/driver-env.sh's table).
const EXIT_WHY = {
  20: ['it asked a question', 'PM'], 21: ['a step it needs is not installed', 'machine fault'],
  22: ['a step answered in a shape the driver cannot read', 'machine fault'], 23: ['it had no brief to work from', 'machine fault'],
  24: ['a gate refused the change', 'PM'], 25: ['a step ran out of time', 'machine fault'],
  26: ['GitHub could not be read', 'the queue'], 27: ['the usage limit was reached', 'the queue, after the usage resets'],
  28: ['it was put back on the queue', 'the queue'], 29: ['another run holds the ticket', 'the queue'],
  31: ['it found an open pull request to repair', 'the queue'], 33: ['the model service failed twice', 'machine fault'],
  143: ['it was stopped', 'the queue'], 137: ['it was killed', 'the queue'],
}
// Until launch the PM takes the owner's calls (the project config's signoff.untilLaunchPm,
// via live-view.sh); only a legal or commercial question still goes to the owner.
const UNTIL_LAUNCH_PM = /^(1|true|yes)$/i.test(process.env.SWARM_UNTIL_LAUNCH_PM || '')
const OWNER_ONLY_RE = new RegExp(process.env.SWARM_OWNER_ONLY_WORDS || '\\b(legal|commercial|contract|pricing|price|licen[cs]e|terms of|lawyer|GDPR|invoice|billing)\\b', 'i')
export const ownerAsk = (text) => (UNTIL_LAUNCH_PM && !OWNER_ONLY_RE.test(String(text || '')) ? 'PM' : OWNER)
// A park's reason in plain words: no exit codes, no "rather than guessing".
const plainReason = (r) => String(r || '').replace(/\s*\(exit \d+\)/g, '').replace(/ rather than guessing/, '').trim()
const cut = (x, n) => (x.length > n ? x.slice(0, n - 1) + '…' : x)

// Where a finished ticket stands now, first match wins.
export function nowOf(d, ctx) {
  const t = String(d.ticket)
  const issue = ctx.issues[t]
  const has = (l) => !!issue && issue.labels.includes(l)
  const parked = has(LBL('LBL_PARKED', 'status:parked'))
  const open = ctx.prRows[t]
  const ref = /\/pull\/(\d+)|\bPR #(\d+)/.exec(d.summary || '')
  const reported = ref ? String(ref[1] || ref[2]) : ''
  const closed = (ctx.closed || {})[t] || (reported && (ctx.closedNumbers || {})[reported]) || null
  const ready = has(LBL('LBL_READY', 'status:ready'))
  const queued = ctx.queued.has(t) || ready
  const park = d.park
  const at = (state, text, extra = {}) => ({ state, text, tone: NOW_STATES[state].tone, ...extra })
  const stop = (state, why, next, extra = {}) => at(state, `Stopped: ${why} — next: ${next}`, { why, next, ...extra })
  if (ctx.live.has(t)) return at('running', 'Running again')
  // A merge is final; a newer open pull request for the ticket is newer work.
  if (closed && closed.mergedAt && !(open && open.number > closed.number)) {
    return at('merged', `Merged ${clockOf(closed.mergedAt, ctx.now)}`, { pr: closed.number, at: closed.mergedAt })
  }
  const owner = [LBL('LBL_OWNER_DECISION', 'needs:owner-decision'), LBL('LBL_NEEDS_HUMAN', 'status:needs-human'),
    LBL('HOLD_LABEL', 'needs:human-approval')].some(has)
  const pmWait = has(LBL('LBL_PM_DECISION', 'status:pm-decision')) || has(LBL('LBL_PM_TRACK', 'status:pm-track'))
  const blocked = has(LBL('LBL_BLOCKED', 'status:blocked'))
  // The newest run parked, and the ticket still sits where the park put it (or is unread):
  // the park's own reason and who moves it, ahead of any pull request it left behind.
  if (park && !(issue && issue.state === 'CLOSED') && (!issue || parked || owner || pmWait || blocked || ready)) {
    const by = /blocked (?:by|on) #(\d+)/i.exec(park.full || '')
    const why = cut(plainReason(park.reason) || 'it parked', 120)
    const detail = cut(String(park.full || '').split(' — ').slice(1).join(' — ').trim(), 240)
    const extra = { ...(detail ? { detail } : {}), ...(open ? { pr: open.number } : {}), ...(by ? { by: Number(by[1]) } : {}) }
    if (by) return stop('stopped', `blocked by #${by[1]}`, `#${by[1]} finishing`, extra)
    if (park.cause === 'pm') return stop('pm', why, 'PM', extra)
    if (park.cause === 'person') { const who = ownerAsk(park.full); return stop(who === 'PM' ? 'pm' : 'owner', why, who, extra) }
    return stop('stopped', why, queued && !parked ? 'the queue (it tries again)' : 'machine fault', extra)
  }
  if (open) return at(open.status ? open.status.state : 'checks', open.status ? open.status.text : 'Waiting for checks',
    { pr: open.number, ...(open.status && open.status.notes ? { notes: open.status.notes } : {}) })
  if (issue && issue.state === 'CLOSED') {
    return issue.reason === 'COMPLETED' || has(LBL('LBL_DONE', 'status:done')) ? at('done', 'Ticket closed as done') : at('closed', 'Ticket closed')
  }
  if (ctx.queued.has(t) || (ready && !parked)) return at('queue', 'Back in the queue')
  if (pmWait) return stop('pm', 'waiting on a PM decision', 'PM')
  if (owner) return stop('owner', `waiting on ${OWNER}`, OWNER)
  if (blocked) return stop('stopped', 'blocked by another ticket', 'that ticket finishing')
  if (d.exit === 0 && !park && reported) return at('unread', `Handed off PR #${reported} — its state is not read yet`, { pr: Number(reported) })
  if (d.exit === 0 && !park) return at('finished', 'Finished — no pull request found')
  const [w, next] = EXIT_WHY[d.exit] || []
  const why = cut(plainReason(park && park.reason) || d.note || w || (d.exit != null ? `exit ${d.exit}` : 'no reason on record'), 120)
  return stop('stopped', why, next || (parked ? 'PM' : 'the queue'))
}

// "Finished: 2 merged · 5 waiting for checks · 1 a check failed · 3 stopped".
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
  const claimRows = claimsNow(now) || []
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
    guard('title', () => fetchTitle(run.ticket))
    const log = parseLog(nativePath(run.log || ''))
    const t = titleOf(run.ticket)
    // NOT `f`: that is the loop's filename, and a second `const f` in this block
    // shadows it into its own temporal dead zone — every read then throws into
    // the catch above and every run record is skipped in silence.
    const fct = progress.tickets[String(run.ticket)]
    const claim = (claimRows || []).find((c) => String(c.issue) === String(run.ticket))
    const drv = fct && fct.driver
    const prog = progressOf(fct, drv)
    const claimStep = claim && claim.step ? String(claim.step) : null
    const row = {
      ticket: String(run.ticket),
      title: t.title || `Ticket ${run.ticket}`,
      short: shortTitle(t.title || `Ticket ${run.ticket}`, plainTitles[String(run.ticket)], t.project, plainName),
      project: t.project || '',
      progress: prog,
      // Which record names its step: the driver's own state where it is on this machine,
      // else the claim's step field, else the facts read from git and the forge.
      claimStep,
      stepFrom: drv && Array.isArray(drv.done) && drv.done.length ? 'driver' : claimStep ? 'claim'
        : prog && prog.of && (prog.unreadable || []).length < prog.of ? 'facts' : null,
      startedAgoMin: Math.round((now - Date.parse(run.started_at)) / 60000),
      quietSec: log.mtime ? Math.round((now - log.mtime) / 1000) : null,
      budget: run.budget_usd,
      host: hostName(run.host || run.operator) || THIS_HOST,
      steps: log.steps,
      // quick or full, off the driver's record (steps/size.sh): null before size has run.
      route: drv && (drv.route === 'quick' || drv.route === 'full') ? drv.route : null,
    }
    if (isLive) live.push(row)
    else done.push({
      ...row,
      exit: ended?.exit_code,
      endedAgoMin: Math.round((now - Date.parse(ended.ended_at)) / 60000),
      finishedAt: ended.ended_at || null,
      // How the RUN ended, never where the ticket is: that is `now`.
      lastRun: log.result?.subtype === 'error_max_budget_usd' ? 'out-of-budget' : ended?.exit_code === 0 ? 'ended' : 'stopped',
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
  // Read before the rows are, so a row answers from the newest states there are.
  guard('required checks', () => refreshRequired(now))
  guard('pr states', () => refreshPrStates(now))
  const prStates = readJsonCached(PR_STATES_FILE)
  const prRows = prRowsByTicket(PRS_FILE, (prStates || {}).heads || null)
  const ctx = { issues: issuesByTicket(), prs: Object.fromEntries(Object.entries(prRows).map(([t, r]) => [t, r.number])),
                prRows, closed: closedByTicket(prStates), closedNumbers: closedByNumber(prStates), now, prList: readJsonCached(PRS_FILE), live: new Set(live.map((a) => a.ticket)), liveHosts: live.map((a) => a.host), queued: new Set(queued.tickets.map((r) => r.ticket)) }
  const doneRows = [...newest.values()].sort((a, b) => b.endedAt - a.endedAt).slice(0, 20)
    .map(({ park, endedAt, ...d }) => {
      const n = nowOf({ ...d, park }, ctx)
      const pr = n.pr != null ? String(n.pr) : ''
      return { ...d, pr, prUrl: pr && REPO ? `https://github.com/${REPO}/pull/${pr}` : '', at: d.finishedAt, now: n }
    })
  guard('progress', () => refreshProgress(live.map((a) => a.ticket), [...new Set(live.map((a) => a.project).filter(Boolean))], now))
  guard('hold', () => refreshHold(now))
  guard('claims', () => refreshClaims(now))
  guard('board', () => refreshBoard(now))
  guard('trend', () => refreshTrend(now))
  guard('wrappers', () => refreshWrappers(now))
  ctx.wrappers = readJsonCached(WRAPPERS_FILE)
  const boardFile = readJsonCached(BOARD_FILE)
  const claims = claimsNow(now) || (boardFile && boardFile.claims) || null
  const board = boardOf(boardFile && { ...boardFile, claims }, ctx, now)
  let areas = null
  guard('areas', () => { areas = areasOf(boardFile && { ...boardFile, claims }, ctx) })
  const fleet = fleetOf(COORD_FLEET, now)
  const elsewhere = elsewhereOf(claims, live, now, (t) => {
    guard('title', () => fetchTitle(t))
    const x = titleOf(t)
    return x.title ? { ...x, short: shortTitle(x.title, plainTitles[t], x.project, plainName) } : {}
  }, fleet)
  const launch = launchOf(board, readJsonCached(TREND_FILE), ctx.wrappers, now)
  const queue = queued
  for (const r of queue.tickets) {
    guard('title', () => fetchTitle(r.ticket))
    const t = titleOf(r.ticket)
    r.title = t.title || `Ticket ${r.ticket}`
  }
  // `at` is the whole staleness contract: every reader discards an answer older
  // than its own ceiling rather than believing a machine that has moved on.
  return { at: new Date(now).toISOString(), repo: REPO, load: os.loadavg()[0],
           plans: plansOf(live, progress.plans, plainName), live, elsewhere, thisHost: THIS_HOST, done: doneRows, doneSummary: doneSummary(doneRows),
           hold, queue, capacity: capacityOf(), fleet,
           mergedToday: mergedTodayOf(readJsonCached(PR_STATES_FILE), now), disk: diskOf(), board, areas, launch, usage: usageOf(PACE_FILE, now),
           hosts: hostsOf(live, claims),
           rules: { priorities: RELEASE_PRIORITIES, postLaunchMilestones: POST_LAUNCH_MILESTONES, afterLaunchLabel: AFTER_LAUNCH,
                    toolingLabels: TOOLING_LABELS, toolingScopes: TOOLING_SCOPES, ownerLabels: OWNER_ASK } }
}

export function serve(port = PORT) {
  const page = fs.readFileSync(new URL('./index.html', import.meta.url), 'utf8')
  const srv = http.createServer((req, res) => {
    try { answer(req, res) } catch (e) {
      warn('request', e)
      try { if (!res.headersSent) res.writeHead(500, { 'content-type': 'application/json', 'cache-control': 'no-store' }); res.end('{"error":"live-view"}') } catch {}
    }
  })
  srv.on('clientError', (e, socket) => { try { socket.destroy() } catch {} })
  return srv.listen(port, '127.0.0.1')
  function answer(req, res) {
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
  }
}

if (process.argv[1] && import.meta.url === new URL(`file://${process.argv[1]}`).href) {
  // A log write that fails (a full disk) is no reason to stop answering.
  process.stdout.on('error', () => {}); process.stderr.on('error', () => {})
  process.on('unhandledRejection', (e) => warn('promise', e))
  serve().on('listening', () => console.log(`live-view on http://127.0.0.1:${PORT}`))
}
