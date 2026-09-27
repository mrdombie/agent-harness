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

export const STEPS = ['Set up', 'Plan', 'Build', 'Check', 'Review', 'PR', 'Merged']
// The step-runner's own step names, in the same order.
const DRIVER_STEP = { start: 0, plan: 1, build: 2, 'self-check': 3, review: 4, ship: 5 }
// Which steps a LATER step being done proves, in order: Set up and Review are
// about what somebody did and nothing downstream proves them. See progressOf.
const ENTAILED = [false, true, true, true, false, true, true]
// effort: -> weight. The same table as /project, so one plan cannot read two ways.
export const WEIGHT = { S: 1, M: 3, L: 8, XL: 20 }
const TRAILER = /^(UI-Gate|Design-Critic):/m

const num = (v) => (typeof v === 'number' && Number.isFinite(v) ? v : null)
const json = (f, d) => { try { return JSON.parse(fs.readFileSync(f, 'utf8')) } catch { return d } }

function sh(cmd, args, opts = {}) {
  try {
    return execFileSync(cmd, args, { encoding: 'utf8', timeout: 20_000, stdio: ['ignore', 'pipe', 'ignore'], ...opts })
  } catch { return null }
}

// ---- the derivation, pure ---------------------------------------------------

export function progressOf(f, driver) {
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
      has(f && f.commits) ? f.commits >= 1 : null,
      has(f && f.commits) ? f.commits >= 2 : null,
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
  for (let i = at.length - 1, seen = false; i >= 0; i--) {
    if (at[i] === true) seen = true
    else if (seen && at[i] === null && ENTAILED[i]) at[i] = true
  }
  const redPr = !!(pr && pr.state === 'OPEN' && pr.fail > 0)
  // The step being walked is the first one KNOWN to be unfinished. A step nobody
  // could read is a gap, not a place to stop: treating it as the current step
  // loses the marker for where the agent actually is, and every step after an
  // unreadable one then reads as not-yet-reached.
  const now = at.findIndex((v) => v === false)
  const firstUnread = at.findIndex((v) => v === null)
  const stepNo = now >= 0 ? now + 1
    : at.every((v) => v === true) ? STEPS.length
    : (firstUnread >= 0 ? firstUnread : 0) + 1
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

function prOf(slug, branch) {
  const out = sh(GH(), ['pr', 'list', '--repo', slug, '--head', branch, '--state', 'all',
    '--limit', '5', '--json', 'number,state,statusCheckRollup'])
  if (out == null) return { prRead: false, pr: null }
  let rows = []
  try { rows = JSON.parse(out) } catch { return { prRead: false, pr: null } }
  if (!rows.length) return { prRead: true, pr: null }
  const p = rows.sort((a, b) => a.number - b.number).pop()
  const roll = p.statusCheckRollup || []
  const bad = /FAILURE|TIMED_OUT|CANCELLED|ACTION_REQUIRED/
  const busy = /IN_PROGRESS|QUEUED|PENDING|WAITING/
  return {
    prRead: true,
    pr: {
      number: String(p.number), state: p.state, total: roll.length,
      fail: roll.filter((c) => bad.test(c.conclusion || '')).length,
      pending: roll.filter((c) => busy.test(c.status || '') || !(c.conclusion || '')).length,
    },
  }
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
export function facts(tickets, { repo = '', queueRepo = '', driverDir = '' } = {}) {
  const cl = CLAIM_LOCK()
  const owner = String(repo).split('/')[0]
  const seen = new Map()
  const out = {}
  for (const t of tickets) {
    if (!/^[0-9]+$/.test(String(t))) continue
    let rec = null
    if (cl) {
      const raw = sh(cl, ['show', String(t)], { env: { ...env, CLAIM_REPO: queueRepo || env.CLAIM_REPO || '' } })
      if (raw != null) { try { rec = JSON.parse(raw) } catch {} }
    }
    if (!rec || !rec.branch) continue
    const slug = rec.repo ? `${owner}/${rec.repo}` : repo
    const { commits, trailers } = branchOf(slug, rec.branch, rec.worktree)

    out[String(t)] = {
      claim: true, branch: rec.branch, commits, pushed: pushedOf(slug, rec.branch),
      trailers: trailers || [], stampsReviews: stampsReviews(slug, seen),
      ...prOf(slug, rec.branch),
      driver: driverDir ? json(path.join(driverDir, String(t), 'state.json'), null) : null,
    }
  }
  return out
}

// plans(ids, opts) — the issue list per plan, weighed. One call per plan.
export function plans(ids, { repo = '', prefix = 'project:' } = {}) {
  const out = {}
  for (const id of ids) {
    if (!/^[A-Za-z0-9:_.-]+$/.test(String(id))) continue
    const raw = sh(GH(), ['issue', 'list', '--repo', repo, '--label', `${prefix}${id}`,
      '--state', 'all', '--limit', '400', '--json', 'number,state,labels'])
    if (raw == null) continue
    try { out[id] = weigh(JSON.parse(raw)) } catch {}
  }
  return out
}
