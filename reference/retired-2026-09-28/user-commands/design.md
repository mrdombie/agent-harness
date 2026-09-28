---
description: Build a Maktura/SocialHub UI surface on ONE branch / ONE PR. Phase 0 sends Dom a concept mockup (Artifact URL) → Phase 1 builds the real page from @maktura/ui with stubs → PAUSE at the worktree URL (port 3000+NNN, nothing merged) → Phase 2 wires real fetches on the same branch → one PR. Usage: /design <surface-name> "<goal-shaped brief>"
---

You are running `/design` for the Maktura/SocialHub repo at `/Users/dominabox/.claude/skills/social-hub`.

`/design` is the **single UI workflow** (it absorbed `/meta`, `/critic`, `/impeccable`). The
`maktura-design` skill owns the pipeline: **intake interview → reuse inventory → design brain →
concept mockup → build the real page from the kit (stubs) → Function Manifest → auto-critic →
composition + contrast gates → PAUSE at the worktree URL → wire → ONE PR**.

**Doctrine: one medium for APPROVAL, a sketch for the FIRST LOOK.**

What Dom approves is the rendered page built from `@maktura/ui` at the real route — byte-for-byte
what ships. No parity targets, no design-phase PRs, and the kit owns the look: anything the design
needs that the kit lacks gets built INTO `packages/ui`, never approximated inline.

But he sees a **concept mockup first**, before that page exists. This was added 2026-08-15 after a
`/design` run where his first sight of the work cost a missing `.env`, a Turbopack failure and a
port collision — three infrastructure problems in a row, none of them about the design. The
mockup is a concept sketch to react to, **never a build target**: it is not parity-checked, not
committed to the repo, and the moment the real page exists it is dead.

His standing rule (`feedback_claude_mockup_before_any_visible_ui`) always outranks this file. If
you find yourself reasoning that a surface is too small to sketch, that is the reasoning the rule
exists to overrule.

## Args parsing

Invoked: `/design $ARGUMENTS` → parse as `<surface-name> "<brief>"` (kebab-case surface, quoted
goal-shaped brief). Missing surface → ask for it. Missing brief → the skill's Step-0 intake
interview covers it. A purely visual brief ("three cards and a chart") passes through — the skill
reframes via the interview.

## Context: where the brief comes from

1. **Coding agent claiming a design ticket (PREFERRED)** — `/claim NNNN` first (worktree at
   `$TMPDIR/sh-NNN-<slug>-<hash>`, branch `sh-NNN/<slug>`), then `/design` from inside it.
   The skill reuses the branch; `/finish` parses it cleanly.
2. **PM ad-hoc** — no prior `/claim`; the skill creates `design/<surface>` and warns that
   `/finish` needs a ticket + rename. Prefer Path 1 — filing + `/claim` costs ~30 seconds.

## Hand off

Invoke the `maktura-design` skill with `<surface-name>` and `<brief>`.

**Phase 0 (concept)** — after intake + reuse inventory, before writing any page code: build a
single self-contained HTML concept. The intake also dispatches a **blind behaviour list** — a
subagent given the screen's job and nothing else, which returns what a competent version of this
screen must support; it ships with the sketch so Dom can check the drawing against it.
 Show the states that carry the design decision (the populated
case, the empty case, and any control whose absence is itself a decision), plus a short "what
changed and why" if this replaces an existing surface. Then **stop**. Cheap to redraw, so redraw
rather than defend.

⚠️ **Deliver it by OPENING it, not by pasting a link.** Dom runs the VSCode extension, where a
`claude.ai/code/artifact/...` URL is not clickable — it does nothing at all. Publish the Artifact
too (it is the durable, shareable copy), but the hand-off is:

```bash
cp "$SCRATCH/<surface>.html" ~/Documents/maktura-mockups/<surface>.html
open ~/Documents/maktura-mockups/<surface>.html
```

**Use REAL data, never invented people.** You have production; query it. Made-up names hide the
thing the sketch exists to test — on 2026-08-15 an invented roster showed "1 pending invite" where
the workspace actually had 4, and read at a density the real data does not have. `WebFetch`
succeeding proves only that *you* can see it. It is not evidence Dom can.

**Phase 1 (build)** — only after the concept lands: **the build plan first** — every component
with its file, props and states, and one row per blind behaviour saying what covers it. Written to
the worktree, not shown — the only thing that reaches Dom is a behaviour nothing covers, and a
behaviour with nothing against it is closed before any component is written.
Then worktree, kit-first component split, state
hook with realistic stubs, page as pure composition, Manifest, critic (SLOP|SHIP), composition +
contrast gates, commit on the branch. **No push, no PR, no merge.** Pause with the preview URL.

**Phase 2 (wire)** — only after explicit approval of the rendered page ("ship it" / "looks good" /
"wire it up" / "go"), same branch: stubs → real fetches per repo convention, loading/error states,
mutations, issues filed for missing endpoints, gates, Manifest reconciled (zero stubs), then the
ONE PR (via `/finish` on the ticket path, or direct `gh pr` on the ad-hoc path).

## Serving the preview — read this before you start a dev server

Every item below cost a real round-trip with Dom on 2026-08-15. None is optional.

**Port is `3000 + last 3 digits of the ticket`** (#9017 → 3017), not a fixed 3010.
`~/maktura-dev` is Dom's persistent dev environment and **permanently owns 3010**, so a hardcoded
3010 silently loses the bind and serves HIS tree instead of yours — the preview looks stale or
404s and nothing says why. Check the port is free first, and if it isn't, take the next free one
and say which:

```bash
PORT=$((3000 + ${TICKET_KEY: -3}))
until ! lsof -tiTCP:$PORT -sTCP:LISTEN >/dev/null 2>&1; do PORT=$((PORT+1)); done
```

**Copy `.env` into the worktree.** A fresh worktree carries `.env.example` only. Without a real
`.env` there is no `AUTH_SECRET`, so auth throws `MissingSecret` on every request and every route
bounces — which reads as "the page is broken", not "the env is missing".

```bash
cp "$MAIN_REPO/.env" "$WORKTREE/.env"
```

**Run webpack, not Turbopack.** The worktree's `node_modules` is a symlink to the main clone, and
Turbopack rejects it — *"Symlink [project]/node_modules is invalid, it points out of the filesystem
root"* — which breaks route-tree resolution and 404s every app route while still serving `/`.

```bash
cd "$WORKTREE" && NEXT_PUBLIC_DEV_FIXTURES=1 \
  npx dotenv -e .env -- npx next dev apps/web -p "$PORT" --webpack
```

A local `next build` in a worktree needs the tracked `apps/*/node_modules` + `packages/*/node_modules` symlinks deleted first (Turbopack: 'points out of filesystem root'); `git checkout --` them back before committing.

**`NEXT_PUBLIC_DEV_FIXTURES=1` or the stubs do not render.** Seed fixtures are opt-in (#6788) and
OFF by default, so without it a Phase-1 preview shows real (usually empty) data and the design
reads as broken.

**Kit edits in `packages/ui` are INVISIBLE to the preview** — `node_modules/@maktura/ui` resolves to the main repo; `readlink -f` it and grep your new prop there before trusting any screenshot.

**Render evidence is real data at three widths.** Fixtures OFF (`NEXT_PUBLIC_DEV_FIXTURES` unset), real rows, captured at 1280 / 1440 / 1920 plus the empty state — seeded frames at one width passed two reviewers and a critic while the room was broken.

**Playwright against `npm run dev`: never wait on `networkidle`** (the HMR socket keeps it busy; a click before React attaches does nothing) and never trust a `/dev` harness that replaces `window.fetch` — it makes `route()` a no-op, so every "state" shot is the same state.

**An AUTHED preview needs four more things:** the worktree's own `apps/api` (point `API_BASE_URL` at it), `AUTH_URL`/`NEXTAUTH_URL`/`NEXT_PUBLIC_APP_URL` overridden to `$PORT`, and a seeded tenant — any miss reads as 'sign-in is broken'.

**Prove the route serves before handing over the URL.** Not the root — the actual route, and
confirm the process serving that port is YOUR worktree:

```bash
curl -s -o /dev/null -w "%{http_code} %{redirect_url}\n" "http://localhost:$PORT/<route>"
ps aux | grep "[n]ext dev" | grep "$PORT" | grep -o "$(basename "$WORKTREE")"
```

A 307 to `/login` is correct and expected — the route resolved. A 404 means it did not.

**Clean up your servers when the phase ends.** Kill by worktree path, never by port, so you cannot
take down `~/maktura-dev`:

```bash
for p in $(ps aux | grep "[s]h-$TICKET_KEY-" | awk '{print $2}'); do kill "$p"; done
```

## When the user replies between phases

- **Approval of the concept** → Phase 1 on the branch.
- **Approval of the rendered page** → Phase 2, same worktree/branch.
- **Iteration feedback** → stay in the phase you are in. In Phase 0 redraw the mockup and
  republish to the SAME Artifact URL (same file path keeps the link). In Phase 1 the preview
  hot-reloads; re-run critic + gates after material changes; pause again.
- **Any remark on a prototype** → first write the interaction flow as numbered steps in the chat and get it agreed, then change the prototype to match; a remark readable two ways → ask, don't rebuild.
- **"Ship as-is"** → PR with stubs (rare; static/catalogue pages) — dev-seed fallback rules apply.

## What you do NOT do

- Treat the Phase-0 mockup as a binding target, parity-check against it, or commit it to the repo.
- Skip Phase 0 because the change looks small.
- Open a PR or merge anything before the Phase-1 approval.
- Skip the pause, bulk-produce surfaces, or delegate design craft to sub-agents. (The blind
  behaviour list is the one subagent this path uses — cartography, not craft, and it only works
  because that agent has not read the repo.)
- Branch a second time for wiring; install dependencies; take screenshots for the user
  (they review the live preview; screenshots are for the critic only).
- Hand over a URL you have not curled, or kill anything on 3010.
