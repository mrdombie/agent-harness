// progress — how far along an agent is, and how far along its plan is.
//
// Seven steps, in the order every agent walks them, each read from a FACT:
//
//   Set up   the claim ref exists
//   Plan     the branch has a commit (or the step-runner recorded its plan step)
//   Build    the branch has more than one
//   Check    the branch is on origin, so the pre-push gate chain ran and passed
//   Review   a review verdict trailer on the branch
//   PR       a pull request, and its check rollup
//   Merged   that pull request is merged
//
// NEVER from anything the agent said about itself. A card built on an agent's own
// narration reports the story it tells, which is the one thing on the machine
// that cannot be checked. Where the step-runner has written its own step record
// that is read instead of inferred: it knows, this would guess.
//
// A fact that cannot be read is `unknown` and its step name travels with the row,
// so the page can name it. Three pairs that would otherwise draw the same are
// kept apart, because each one silently reads as the wrong answer:
//
//   no PR                     vs  the forge could not be asked   (prRead)
//   nothing committed         vs  the worktree was swept         (the forge answers)
//   no review on this branch  vs  this repo stamps none, ever    (stampsReviews)
//
// Every call out of this module goes through a seam so a test can record it:
// SWARM_GH, SWARM_GIT, SWARM_CLAIM_LOCK, DRIVER_DIR.
import fs from 'node:fs'
import path from 'node:path'
import { execFileSync } from 'node:child_process'
import { pathToFileURL } from 'node:url'

export const STEPS = ['Set up', 'Plan', 'Build', 'Check', 'Review', 'PR', 'Merged']
// The step-runner's own step names, in the same order.
// size is part of Set up; a quick run's one session (quick) edits and runs the gates, so
// it stands for Plan, Build and Check together and is read as Check done.
const DRIVER_STEP = { start: 0, size: 0, plan: 1, build: 2, quick: 3, 'self-check': 3, review: 4, ship: 5 }
// A repair walks its own order (build-ticket's DRIVER_REPAIR_STEPS), entered by reenter
// on the PR's branch. Its record keeps the earlier build's finished steps beside it.
const REPAIR_ORDER = ['reenter', 'repair', 'fix', 'self-check', 'review', 'record', 'ship']
const REPAIR_NAME = { reenter: 'Back on the PR', repair: 'Repair', fix: 'Fix', 'self-check': 'Check', review: 'Review', record: 'Record', ship: 'Push' }
// Which steps a LATER step being done proves, in order: Set up and Review are
// about what somebody did and nothing downstream proves them. See progressOf.
const ENTAILED = [false, true, true, true, false, true, true]
// effort: -> weight. The same table as /project, so one plan cannot read two ways.
export const WEIGHT = { S: 1, M: 3, L: 8, XL: 20 }
const TRAILER = /^(UI-Gate|Design-Critic):/m

const num = (v) => (typeof v === 'number' && Number.isFinite(v) ? v : null)
const json = (f, d) => { try { return JSON.parse(fs.readFileSync(f, 'utf8')) } catch { return d } }

// Each gh call that leaves this module is counted against the live view (gh-calls.log).
export function noteGh(args) {
  const f = env.SWARM_GH_CALLS
  if (!f) return
  try { fs.appendFileSync(f, `${Math.floor(Date.now() / 1000)}\tlive-view\t${args[0] || ''} ${args[1] || ''}\n`) } catch {}
}

// Below the floor the gather and the title reads wait for the reset; the tick keeps its read.
export function allowanceLow(now = Date.now() / 1000) {
  const pct = Number(env.GH_ALLOWANCE_LOW_PCT || 10)
  let rows = []
  try { rows = fs.readFileSync(env.SWARM_GH_ALLOWANCE || '', 'utf8').trim().split('\n') } catch { return null }
  for (const r of rows) {
    const [res, left, limit, reset] = r.split('\t')
    if (Number(reset) > now && Number(limit) > 0 && Number(left) * 100 < Number(limit) * pct) {
      return { resource: res, left: Number(left), limit: Number(limit), reset: Number(reset) }
    }
  }
  return null
}

// The backoff every caller shares once GitHub refuses the token (scripts/gh-batch.sh):
// gh-backoff holds every call, gh-backoff.search the search bucket alone. Each file's
// first field is the epoch it ends; 0 when none holds.
const backoffFile = () => env.SWARM_GH_BACKOFF
  || (env.SWARM_GH_ALLOWANCE ? path.join(path.dirname(env.SWARM_GH_ALLOWANCE), 'gh-backoff') : '')
function backoffUntil(f, now) {
  if (!f) return 0
  try { const u = Number(fs.readFileSync(f, 'utf8').split('\t')[0]); return u > now ? u : 0 } catch { return 0 }
}
export const ghBackoff = (now = Date.now() / 1000) => backoffUntil(backoffFile(), now)
export const searchBackoff = (now = Date.now() / 1000) => { const f = backoffFile(); return f ? backoffUntil(`${f}.search`, now) : 0 }
// The calls that spend the search bucket, as gh-batch.sh's _gh_is_search reads them.
export function isSearch(args) {
  const [a, b, ...rest] = args || []
  if (a === 'search') return true
  if (a === 'api') return [b, ...rest].some((x) => /^\/?search\//.test(String(x)))
  if ((a === 'issue' || a === 'pr') && b === 'list') return rest.some((x) => x === '--search' || x === '-S' || String(x).startsWith('--search='))
  return false
}
// True while a backoff that covers this call holds: it is not made, the last read stands.
export const ghHeld = (args, now = Date.now() / 1000) => ghBackoff(now) > 0 || (isSearch(args) && searchBackoff(now) > 0)

// The open PRs the tick last read, while they are young enough to stand in for a call.
function sharedPrs(maxAge = Number(env.SWARM_PRS_MAX_AGE || 300)) {
  const f = env.SWARM_PRS_FILE
  if (!f) return null
  try {
    if ((Date.now() - fs.statSync(f).mtimeMs) / 1000 > maxAge) return null
    const rows = JSON.parse(fs.readFileSync(f, 'utf8'))
    return Array.isArray(rows) ? rows : null
  } catch { return null }
}

// What the gather learnt about PRs and plans, kept on disk between gathers (each is
// a process of its own): a merged or closed PR is final, a branch with no PR stays
// so until it shows in the shared open list, and a plan's issues change slowly.
// Without it every gather asked once per agent branch and once per plan, ~320/h.
const NONE_TTL = () => Number(env.SWARM_PR_NONE_TTL || 900)
const PLAN_TTL = () => Number(env.SWARM_PLAN_TTL || 600)
function memoFile() {
  if (env.SWARM_PR_MEMO) return env.SWARM_PR_MEMO
  return env.SWARM_PRS_FILE ? path.join(path.dirname(env.SWARM_PRS_FILE), 'live-view-memo.json') : ''
}
function loadMemo() {
  const m = json(memoFile(), null)
  return { prs: (m && m.prs) || {}, plans: (m && m.plans) || {} }
}
function saveMemo(m, now = Date.now() / 1000) {
  const f = memoFile()
  if (!f) return
  const young = (o, age) => Object.fromEntries(Object.entries(o).filter(([, v]) => v && now - v.at < age))
  try {
    fs.writeFileSync(`${f}.${process.pid}`, JSON.stringify({ prs: young(m.prs, 7 * 86400), plans: young(m.plans, 86400) }))
    fs.renameSync(`${f}.${process.pid}`, f)
  } catch {}
}

function sh(cmd, args, opts = {}) {
  if (cmd === GH()) { if (ghHeld(args)) return null; noteGh(args) }
  try {
    return execFileSync(cmd, args, { encoding: 'utf8', timeout: 20_000, stdio: ['ignore', 'pipe', 'ignore'], ...opts })
  } catch { return null }
}

// ---- the derivation, pure ---------------------------------------------------

// A repair or reenter run is at the first step of the repair order its record has
// not finished. Read from the build's steps or the PR, it drew "7 of 7 · Merged"
// over a run that was in self-check (measured 2026-10-20 on a repair of a green PR).
export function progressOf(f, driver) {
  const p = buildProgressOf(f, driver)
  const done = driver && Array.isArray(driver.done) ? driver.done : []
  if (!(driver && (driver.mode === 'repair' || done.includes('reenter')))) return p
  const fin = new Set(done)
  const at = REPAIR_ORDER.findIndex((s) => !fin.has(s))
  const now = at < 0 ? REPAIR_ORDER.length - 1 : at
  const steps = REPAIR_ORDER.map((s, i) => ({ name: REPAIR_NAME[s],
    state: fin.has(s) ? 'done' : i === now ? 'now' : 'todo' }))
  return { ...p, repair: true, step: now + 1, of: REPAIR_ORDER.length, steps, unreadable: [] }
}

function buildProgressOf(f, driver) {
  const has = (v) => v !== null && v !== undefined
  const pr = f && f.pr
  const merged = pr ? pr.state === 'MERGED' : null
  const prRead = !!(f && f.prRead)
  const green = pr ? pr.state === 'MERGED' || (pr.state === 'OPEN' && !pr.fail && !pr.pending) : false
  // A record has to SAY something to be read. An empty done-list, or one naming
  // steps this table does not know, is not evidence that nothing is done — read
  // as one it drew "step 1 of 7" over a ticket whose PR had already merged.
  const claimed = driver && Array.isArray(driver.done)
    ? driver.done.map((x) => DRIVER_STEP[x]) : null
  const d = claimed && claimed.length && claimed.every((n) => n !== undefined) ? driver.done : null

  // Per step: true done, false not yet, null cannot be read.
  let at
  if (d) {
    const reached = d.map((s) => DRIVER_STEP[s]).filter((n) => n !== undefined)
    const top = reached.length ? Math.max(...reached) : -1
    // Steps 0-5 are the step-runner's record; only Merged, which it has no step
    // for, comes from the PR. Letting a green PR mark step 5 done here would put
    // PR ahead of Review on the bar, which reads as a bug rather than as work.
    at = STEPS.map((_, i) => (i === 6 ? (prRead ? merged === true : null) : i <= top))
  } else {
    at = [
      f && f.claim ? true : null,
      // The ticket names two facts for this cell — "a plan file OR first commit"
      // — so a written plan counts before anything is committed. Build is "commits
      // on the branch", with no threshold named, so it is not given an invented
      // one: the two move together on a run that writes no plan, which is what
      // the spec says rather than what looks tidiest.
      f && f.planFile ? true : has(f && f.commits) ? f.commits >= 1 : null,
      has(f && f.commits) ? f.commits >= 1 : null,
      f && has(f.pushed) ? !!f.pushed : null,
      f && Array.isArray(f.trailers) && f.trailers.length > 0 ? true
        : f && f.stampsReviews === true ? false : null,
      prRead ? green : null,
      prRead ? merged === true : null,
    ]
  }
  // The bar is a SEQUENCE, so a step nobody could read that sits BEFORE one known
  // done was passed — a branch cannot merge without being pushed. Without this the
  // row fills past its own cursor (Merged lit on a card headed step 5 of 7) and a
  // progress bar that does that means nothing.
  //
  // But only four of the seven are entailed that way, and the partition IS the
  // validity condition: Plan, Build, Check and PR are git-mechanical, so a later
  // merge genuinely proves them. Set up and Review are about what somebody DID.
  // A merge proves no reviewer looked — this project's approval-gate rules exist
  // because ~25 PRs merged without one — so backfilling Review would put a claim
  // about a person on the screen, deduced from a fact about git.
  // Repairs `false` as well as `null`, and only a MECHANICAL done sets the mark.
  //
  // Both halves were learned the hard way. Merging deletes the branch, so
  // `git ls-remote` then exits 2 — a genuine "no such ref" — and Check read
  // false: a fact read correctly whose meaning had expired, drawing "the gates
  // were never run" over work that merged through them. And a review trailer is
  // earned BEFORE the push in this pipeline, so a `true` there proves nothing
  // mechanical; counting it moved the cursor to PR on a branch that had never
  // left the Mac.
  for (let i = at.length - 1, seen = false; i >= 0; i--) {
    if (at[i] === true && ENTAILED[i]) seen = true
    else if (seen && at[i] !== true && ENTAILED[i]) at[i] = true
  }
  const redPr = !!(pr && pr.state === 'OPEN' && pr.fail > 0)
  // Where the work IS, which is not the same as the first gap in the row. The
  // first gap alone put the cursor behind the work: a merged ticket whose branch
  // carried no review trailer read "STEP 5 OF 7 · waiting on its reviewer", in
  // the present tense and in the happening-now colour, about work that had
  // already shipped. So the cursor is the later of the first known-unfinished
  // step and the step after the furthest one PROVEN done — a skipped step sits
  // behind the cursor as an unlit cell, which is what a skipped step is.
  const firstFalse = at.findIndex((v) => v === false)
  const firstUnread = at.findIndex((v) => v === null)
  const proven = at.reduce((p, v, i) => (v === true && ENTAILED[i] ? i + 1 : p), 0)
  const start = firstFalse >= 0 ? firstFalse : (firstUnread >= 0 ? firstUnread : 0)
  const now = Math.max(start, proven)
  const stepNo = Math.min(now + 1, STEPS.length)
  const steps = STEPS.map((name, i) => ({
    name,
    state: i === 5 && redPr ? 'bad'
      : at[i] === true ? 'done'
      : at[i] === null ? 'unknown'
      : i === now ? 'now' : 'todo',
  }))
  return {
    step: redPr ? 6 : stepNo,   // 1-based: "STEP 5 OF 7"
    of: STEPS.length,
    steps,
    commits: num(f && f.commits),
    reviewRounds: driver?.counters?.review_rounds == null ? null
      : Number(driver.counters.review_rounds) || 0,
    pr: pr ? String(pr.number) : '',
    // The page has to tell a green PR waiting to merge from one that merged and
    // from one somebody closed. Without the state it said "merged" about all
    // three — the most consequential word this page prints, printed about open
    // work.
    prState: pr ? String(pr.state) : '',
    checksFail: pr ? num(pr.fail) : null,
    checksPending: pr ? num(pr.pending) : null,
    unreadable: steps.filter((s) => s.state === 'unknown').map((s) => s.name),
  }
}

// One bar per plan with an agent working. A plan whose issue list could not be
// read is still listed, with nulls: a bar that vanishes reads as "no plan" and a
// zeroed one reads as "no progress", and both are the wrong answer.
export function plansOf(live, plans, name = (id) => id) {
  const working = new Map()
  for (const a of live || []) {
    const id = String(a.project ?? '')
    if (!id) continue
    working.set(id, (working.get(id) || 0) + 1)
  }
  return [...working.keys()].sort().map((id) => {
    const p = plans && plans[id]
    const total = p ? p.weightTotal : 0
    return {
      id,
      name: name(id),
      pct: p && total > 0 ? Math.round((p.weightDone / total) * 100) : null,
      done: p ? num(p.done) : null,
      jobs: p ? num(p.jobs) : null,
      working: working.get(id),
      unestimated: p ? num(p.unestimated) : null,
    }
  })
}

// A title written as engineering notes is not a title a person can read. Prefer
// the operator's own word for it; otherwise cut the notes back to the clause that
// names the thing.
export function shortTitle(title, override, project, name = (x) => x) {
  if (override) return String(override)
  const full = String(title ?? '')
  let s = full.replace(/^[a-z]+(\([^)]*\))?:\s*/i, '').replace(/^#?([A-Za-z]+-)?\d+:\s*/, '')
  const parts = s.split(/\s+·\s+/)
  const withColon = parts.find((x) => /:\s/.test(x))
  if (withColon) {
    const cut = withColon.indexOf(': ')
    const before = withColon.slice(0, cut), after = withColon.slice(cut + 2).trim()
    // "One Desk: times inside quiet hours" is a programme labelling its own
    // ticket, so the name is what comes AFTER the colon. Otherwise three agents
    // on one programme render as three identically-named cards on a page whose
    // only job is telling them apart. "the driver: build-ticket runs …" is not
    // that shape, and its name is the clause before.
    const flat = (x) => String(x).toLowerCase().replace(/[^a-z0-9]/g, '')
    const label = flat(name(project))
    s = (label && flat(before).startsWith(label) && after) ? after : before
  } else {
    s = parts[0]
  }
  s = s.replace(/^([A-Za-z]+-)?\d+\s+/, '').trim()
  if (!s) s = full.trim()
  if (s.length > 52) s = s.slice(0, 52).replace(/\s+\S*$/, '') + '…'
  return s.charAt(0).toUpperCase() + s.slice(1)
}

// Effort-weighted, epics excluded, the unsized counted rather than zeroed.
export function weigh(issues) {
  const rows = (issues || [])
    .filter((i) => !(i.labels || []).some((l) => l.name === 'epic' || l.name === 'programme'))
    .map((i) => ({
      closed: i.state === 'CLOSED',
      w: (i.labels || []).map((l) => String(l.name).replace(/^effort:/, ''))
        .find((n) => WEIGHT[n] !== undefined) || null,
    }))
  return {
    jobs: rows.length,
    done: rows.filter((r) => r.closed).length,
    weightDone: rows.filter((r) => r.closed && r.w).reduce((s, r) => s + WEIGHT[r.w], 0),
    weightTotal: rows.filter((r) => r.w).reduce((s, r) => s + WEIGHT[r.w], 0),
    unestimated: rows.filter((r) => !r.w).length,
  }
}

// ---- reading the facts ------------------------------------------------------

const env = process.env
const GH = () => env.SWARM_GH || 'gh'
const GIT = () => env.SWARM_GIT || 'git'
const CLAIM_LOCK = () => env.SWARM_CLAIM_LOCK || ''

// Does this repo stamp a review verdict on its commits at all? Read from its own
// trunk, never assumed: without it "no trailer" reads as "not reviewed" in a repo
// that has never stamped one, which is a step reported false for a fact nobody
// records.
function stampsReviews(slug, seen) {
  if (seen.has(slug)) return seen.get(slug)
  let v = null
  for (const tr of ['develop', 'main']) {
    const out = sh(GH(), ['api', `repos/${slug}/commits?sha=${tr}&per_page=60`,
      '--jq', '[.[].commit.message] | join("\\n")'])
    if (out != null) { v = TRAILER.test(out); break }
  }
  seen.set(slug, v)
  return v
}

// Exit 2 is "no such ref" — a real false. Anything else (128: no credential
// helper on a private repo; the network down) is NOT an answer, and folding it
// into false draws Check as a definite step from a call that never returned.
function pushedOf(slug, branch) {
  try {
    execFileSync(GIT(), ['ls-remote', '--exit-code', '--heads', `https://github.com/${slug}.git`, branch],
      { encoding: 'utf8', timeout: 20_000, stdio: ['ignore', 'pipe', 'ignore'] })
    return true
  } catch (e) { return e && e.status === 2 ? false : null }
}

export function rollupOf(p) {
  // Each check by its newest run: one still going counts as newest, then the latest finish.
  const newest = new Map()
  for (const c of p.statusCheckRollup || []) {
    if (!c) continue
    const name = String(c.name || c.context || '')
    const going = c.state ? /PENDING|EXPECTED/.test(c.state) : !c.conclusion
    const at = going ? Infinity : Date.parse(c.completedAt || c.startedAt || c.createdAt || '') || 0
    const o = newest.get(name)
    if (!o || at >= o.at) newest.set(name, { c, at })
  }
  const roll = [...newest.values()].map((x) => x.c)
  // Only a check that blocks the merge can make the cell red: the trunk's required set
  // (the live view's ruleset read) less the project's report-only list.
  let req = null
  try { const v = JSON.parse(fs.readFileSync(env.SWARM_REQUIRED_CHECKS_FILE || '', 'utf8')); if (Array.isArray(v.contexts) && v.contexts.length) req = new Set(v.contexts) } catch {}
  let off = []
  try { off = JSON.parse(env.SWARM_NONBLOCKING_CHECKS || '[]') } catch {}
  const blocks = (c) => { const n = String(c.name || c.context || ''); return !off.includes(n) && (!req || req.has(n)) }
  const bad = /FAILURE|TIMED_OUT|CANCELLED|ACTION_REQUIRED/
  const busy = /IN_PROGRESS|QUEUED|PENDING|WAITING/
  return {
    number: String(p.number), state: p.state || 'OPEN', total: roll.length,
    // A commit status carries only a state: PENDING is waiting, FAILURE/ERROR is red.
    fail: roll.filter((c) => blocks(c) && (bad.test(c.conclusion || '') || /FAILURE|ERROR/.test(c.state || ''))).length,
    pending: roll.filter((c) => (c.state
      ? /PENDING|EXPECTED/.test(c.state)
      : busy.test(c.status || '') || !(c.conclusion || ''))).length,
  }
}

function prOf(slug, branch, shared = null, sharedSlug = '', memo = { prs: {} }, now = Date.now() / 1000) {
  // An open PR in the shared copy is answered from it; only a branch it lacks asks GitHub.
  const covered = !!shared && slug === sharedSlug
  const key = `${slug} ${branch}`
  const hit = covered
    ? shared.filter((p) => p.headRefName === branch).sort((a, b) => a.number - b.number).pop() : null
  if (hit) { memo.prs[key] = { state: 'OPEN', at: now }; return { prRead: true, pr: rollupOf(hit) } }
  const m = memo.prs[key]
  if (m && (m.state === 'MERGED' || m.state === 'CLOSED') && m.pr) return { prRead: true, pr: m.pr }
  // A PR opens before it can merge, so a branch with none that is still missing from
  // a fresh open list has none yet — re-asked only after NONE_TTL.
  if (covered && m && m.state === 'NONE' && now - m.at < NONE_TTL()) return { prRead: true, pr: null }
  const out = sh(GH(), ['pr', 'list', '--repo', slug, '--head', branch, '--state', 'all',
    '--limit', '5', '--json', 'number,state,statusCheckRollup'])
  if (out == null) return { prRead: false, pr: null }
  let rows = []
  try { rows = JSON.parse(out) } catch { return { prRead: false, pr: null } }
  if (!rows.length) { memo.prs[key] = { state: 'NONE', at: now }; return { prRead: true, pr: null } }
  const p = rows.sort((a, b) => a.number - b.number).pop()
  const pr = rollupOf(p)
  memo.prs[key] = pr.state === 'MERGED' || pr.state === 'CLOSED' ? { state: pr.state, pr, at: now } : { state: 'OPEN', at: now }
  return { prRead: true, pr }
}

// The branch, from the local worktree when it is still there and from the forge
// when it is not. A card that forgets how much was built the moment the tree is
// swept is wrong rather than merely thin.
function branchOf(slug, branch, worktree) {
  let commits = null, trailers = null
  const live = worktree && (fs.existsSync(path.join(worktree, '.git')))
  if (live) {
    const trunk = ['origin/develop', 'origin/main']
      .find((t) => sh(GIT(), ['-C', worktree, 'rev-parse', '-q', '--verify', t]) != null)
    if (trunk) {
      const n = sh(GIT(), ['-C', worktree, 'rev-list', '--count', `${trunk}..HEAD`])
      if (n != null) commits = Number(String(n).trim())
      const body = sh(GIT(), ['-C', worktree, 'log', `${trunk}..HEAD`, '--format=%B'])
      if (body != null) trailers = [...new Set((body.match(/^(UI-Gate|Design-Critic):/gm) || [])
        .map((m) => m.replace(':', '')))]
    }
  }
  if (commits == null) {
    for (const tr of ['develop', 'main']) {
      const out = sh(GH(), ['api', `repos/${slug}/compare/${tr}...${branch}`,
        '--jq', '{a: .ahead_by, m: [.commits[].commit.message] | join("\\n")}'])
      if (out == null) continue
      try {
        const j = JSON.parse(out)
        commits = num(j.a)
        trailers = [...new Set((String(j.m).match(/^(UI-Gate|Design-Critic):/gm) || [])
          .map((m) => m.replace(':', '')))]
      } catch {}
      break
    }
  }
  return { commits, trailers }
}

// facts(tickets, opts) — one pass, one entry per ticket that has a claim record.
// A ticket with no claim record is absent, which is what makes its whole bar read
// `unknown` rather than `not started`.
export function facts(tickets, { repo = '', queueRepo = '', driverDir = '', memo = { prs: {}, plans: {} } } = {}) {
  const cl = CLAIM_LOCK()
  const owner = String(repo).split('/')[0]
  const seen = new Map()
  const out = {}
  const shared = sharedPrs()
  for (const t of tickets) {
    if (!/^[0-9]+$/.test(String(t))) continue
    let rec = null
    if (cl) {
      // Windows cannot exec a .sh file itself; hand it to bash by its full path.
      // A bare 'bash' resolves to System32's WSL launcher under Task Scheduler.
      const [cmd, args] = process.platform === 'win32' && /\.sh$/.test(cl)
        ? [env.SWARM_BASH || 'bash', [cl, 'show', String(t)]] : [cl, ['show', String(t)]]
      const raw = sh(cmd, args, { env: { ...env, CLAIM_REPO: queueRepo || env.CLAIM_REPO || '' } })
      if (raw != null) { try { rec = JSON.parse(raw) } catch {} }
    }
    if (!rec || !rec.branch) continue
    const slug = rec.repo ? `${owner}/${rec.repo}` : repo
    const { commits, trailers } = branchOf(slug, rec.branch, rec.worktree)

    const dir = driverDir ? path.join(driverDir, String(t)) : ''
    out[String(t)] = {
      claim: true, branch: rec.branch, commits, pushed: pushedOf(slug, rec.branch),
      // The ticket's wording for Plan is "a plan file or first commit", and the
      // step-runner writes one before it commits anything.
      planFile: !!(dir && fs.existsSync(path.join(dir, 'steps', 'plan.json'))),
      trailers: trailers || [], stampsReviews: stampsReviews(slug, seen),
      ...prOf(slug, rec.branch, shared, repo, memo),
      driver: dir ? json(path.join(dir, 'state.json'), null) : null,
    }
  }
  return out
}

// plans(ids, opts) — the issue list per plan, weighed. One call per plan.
export function plans(ids, { repo = '', prefix = 'project:', memo = { plans: {} } } = {}, now = Date.now() / 1000) {
  const out = {}
  for (const id of ids) {
    if (!/^[A-Za-z0-9:_.-]+$/.test(String(id))) continue
    const key = `${repo} ${prefix}${id}`
    const m = memo.plans[key]
    if (m && m.weighed && now - m.at < PLAN_TTL()) { out[id] = m.weighed; continue }
    const raw = sh(GH(), ['issue', 'list', '--repo', repo, '--label', `${prefix}${id}`,
      '--state', 'all', '--limit', '400', '--json', 'number,state,labels'])
    if (raw == null) continue
    try { out[id] = weigh(JSON.parse(raw)); memo.plans[key] = { weighed: out[id], at: now } } catch {}
  }
  return out
}

// `node progress.mjs --gather '<json>'` — one refresh in a process of its own,
// printed as JSON. The reads are synchronous git and forge calls, ~45 s a pass.
export function gather({ tickets = [], ids = [], repo = '', queueRepo = '', driverDir = '', prefix = 'project:' } = {}) {
  const memo = loadMemo()
  const out = { tickets: facts(tickets, { repo, queueRepo, driverDir, memo }), plans: plans(ids, { repo, prefix, memo }) }
  saveMemo(memo)
  return out
}
if (process.argv[2] === '--gather' && process.argv[1]
    && import.meta.url === pathToFileURL(path.resolve(process.argv[1])).href) {
  let args = {}
  try { args = JSON.parse(process.argv[3] || '{}') } catch {}
  process.stdout.write(JSON.stringify(gather(args)))
}
