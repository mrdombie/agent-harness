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
import { execFile } from 'node:child_process'

const RUNS = process.env.SWARM_RUNS_DIR || path.join(os.homedir(), '.swarm/runs')
const PORT = Number(process.env.SWARM_PORT || 4777)
const REPO = process.env.SWARM_REPO || ''
const GH = process.env.SWARM_GH || 'gh'
const PREFIX = process.env.SWARM_PROGRAMME_PREFIX || 'project:'
const TITLES = process.env.SWARM_TITLES || path.join(RUNS, '..', 'live-view-titles.json')
const KEEP_HOURS = Number(process.env.SWARM_DONE_HOURS || 6)
const TAIL = 400_000

let titles = {}
try { titles = JSON.parse(fs.readFileSync(TITLES, 'utf8')) } catch {}
const pending = new Set()

// A title is worth one call per ticket, ever, and it is cached to a file so a
// restart does not re-ask for every ticket at once. A failure is not retried in
// the same process: the card falls back to "Ticket 1234", which is honest.
function fetchTitle(ticket) {
  if (!REPO || titles[ticket] || pending.has(ticket)) return
  pending.add(ticket)
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

// "fix(desk): the strip drops its last item" → "The strip drops its last item"
function plainTitle(t) {
  const s = String(t ?? '').replace(/^[a-z]+(\([^)]*\))?:\s*/i, '').replace(/^#?\d+:\s*/, '')
  return s.charAt(0).toUpperCase() + s.slice(1)
}

const alive = (pid) => { try { process.kill(pid, 0); return true } catch { return false } }

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

function parseLog(file) {
  const steps = []
  let result = null
  for (const line of tail(file).split('\n')) {
    if (!line.startsWith('{')) continue
    let j
    try { j = JSON.parse(line) } catch { continue }
    if (j.type === 'assistant') {
      for (const b of j.message?.content || []) {
        const s = stepFrom(b)
        if (s) steps.push(s)
      }
    } else if (j.type === 'result') {
      result = { subtype: j.subtype, cost: j.total_cost_usd, summary: String(j.result ?? '').slice(0, 400) }
    }
  }
  let mtime = 0
  try { mtime = fs.statSync(file).mtimeMs } catch {}
  return { steps: steps.slice(-10), result, mtime }
}

// A run is live when it has no .ended marker AND its agent's process still
// exists. The marker alone is not enough — a wrapper killed before it could
// write one leaves a record that looks like a running agent forever, which is
// how a launcher once reported eight running with three alive.
export function snapshot(now = Date.now()) {
  const live = []
  const done = []
  let files = []
  try { files = fs.readdirSync(RUNS).filter((f) => /^claim-.*\.json$/.test(f)) } catch {}
  for (const f of files) {
    let run
    try { run = JSON.parse(fs.readFileSync(path.join(RUNS, f), 'utf8')) } catch { continue }
    let ended = null
    try { ended = JSON.parse(fs.readFileSync(path.join(RUNS, f.replace(/\.json$/, '.ended')), 'utf8')) } catch {}
    const isLive = !ended && alive(run.child_pid || run.pid)
    if (!isLive && (!ended || now - Date.parse(ended.ended_at) > KEEP_HOURS * 3600_000)) continue
    fetchTitle(run.ticket)
    const log = parseLog(run.log || '')
    const t = titles[run.ticket] || {}
    const row = {
      ticket: String(run.ticket),
      title: t.title || `Ticket ${run.ticket}`,
      project: t.project || '',
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
    })
  }
  live.sort((a, b) => a.startedAgoMin - b.startedAgoMin)
  done.sort((a, b) => a.endedAgoMin - b.endedAgoMin)
  // `at` is the whole staleness contract: every reader discards an answer older
  // than its own ceiling rather than believing a machine that has moved on.
  return { at: new Date(now).toISOString(), repo: REPO, load: os.loadavg()[0], live, done: done.slice(0, 20) }
}

export function serve(port = PORT) {
  const page = fs.readFileSync(new URL('./index.html', import.meta.url), 'utf8')
  return http.createServer((req, res) => {
    if (req.url === '/api/agents') {
      res.writeHead(200, { 'content-type': 'application/json', 'cache-control': 'no-store' })
      res.end(JSON.stringify(snapshot()))
      return
    }
    res.writeHead(200, { 'content-type': 'text/html; charset=utf-8' })
    res.end(page)
  }).listen(port, '127.0.0.1')
}

if (process.argv[1] && import.meta.url === new URL(`file://${process.argv[1]}`).href) {
  serve().on('listening', () => console.log(`live-view on http://127.0.0.1:${PORT}`))
}
