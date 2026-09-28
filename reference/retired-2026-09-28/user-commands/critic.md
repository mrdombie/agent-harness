---
description: "Critique a screen for AI slop. Pass a /dev route to render + loop, OR hand it a screenshot (attach/paste an image, or give an image path) to judge directly. Usage: /critic <route> | /critic <image.png> | /critic (with an attached screenshot)"
---

You are running `/critic` for the Maktura/SocialHub repo at `/Users/dominabox/.claude/skills/social-hub`.

> Note: the anti-slop critic now also runs **automatically** as a stage of `/design` (Step 9.7) on
> every screen before the build is handed back — review is no longer opt-in. `/critic` remains as a
> standalone convenience for judging a one-off route or a pasted/exported screenshot without running
> the full `/design` flow.

`/critic` judges a screen with the **design-critic** agent against the Maktura design philosophy +
AI-slop signatures, returning **SLOP/SHIP + "the one move."** It runs in one of two modes:

- **Mode A — route** (`/critic pulse-chat`): render the live `/dev/*` screen, then apply the fix and
  re-judge — looping until **SHIP** or 3 iterations. The exemplar that clears the bar is
  `/dev/screens/overview` — the gravity well every other screen matches against.
- **Mode B — screenshot** (`/critic path/to/shot.png`, or just **attach/paste an image** with
  `/critic`): judge the supplied image directly — no server, no render. Critique-only (there's no
  source file to edit), so it stops after the verdict. This is the quickest way to sanity-check any
  mockup, a competitor's screen, a Figma export, or a screen you can't easily route to.

## Args

Invoked: `/critic $ARGUMENTS`

**Detect the mode first:**
- **Image present** → Mode B. Triggered when `$ARGUMENTS` is (or contains) a path/URL ending in
  `.png` / `.jpg` / `.jpeg` / `.webp`, **or** the user attached/pasted one or more screenshots with
  the message. Two paths = treat as light + dark of the same screen. If the image was pasted (no
  path on disk), first save it under `design/critic-gallery/_adhoc/<name>.png` so the design-critic
  subagent can `Read` it (subagents see files, not the chat's inline image). Then go straight to
  **Step 2** with those image path(s); skip Steps 0, 1, 2.5, 3 (no route, no source to edit).
  If the caller ALSO names a route alongside the image (`/critic persona-cc shot.png`), you may run
  the apply/iterate loop against that route's source after the verdict.
- **Route given** → Mode A. `$ARGUMENTS` is a route relative to `/dev/`; strip any leading `/`,
  `dev/`, or full URL.
  - `pulse-chat` → `/dev/pulse-chat`
  - `persona-cc` → `/dev/persona-cc`
  - `screens/overview` → `/dev/screens/overview`  (the exemplar / regression anchor)
  - Screen source file = `apps/web/src/app/dev/<route>/page.tsx` (+ sibling `_parts.tsx` /
    `_components/` if present). This is the only file you edit when applying a fix.
- **Nothing given** → if a screenshot is attached, Mode B; otherwise ask: "A route (e.g.
  `pulse-chat`) or a screenshot to critique?"

## Constants

- Dev URL: `http://localhost:3017/dev/<route>`
- Philosophy: `~/.claude/design/maktura-design-philosophy.md` (fallback: repo
  `docs/design/design-philosophy.md`)
- Critic agent: `design-critic` (global `~/.claude/agents/design-critic.md`; also on develop)
- Gallery (local-only working artifact — **never `git add` it**):
  `/Users/dominabox/.claude/skills/social-hub/design/critic-gallery/<route>/`

## Step 0 — Ensure the dev server is up

```
curl -sf http://localhost:3017/api/version >/dev/null && echo up || echo down
```
If down, start it (background) and wait until `/api/version` responds:
```
cd /Users/dominabox/.claude/skills/social-hub/apps/web && PORT=3017 npm run dev
```
Poll `/api/version` until it returns before screenshotting (first compile can take ~20–40s).

## Step 1 — Screenshot light AND dark

The app toggles theme with a `dark` class on `<html>` (tokens flip via `.dark{}` in globals.css).
`/dev/*` routes are public — no auth needed.

**Primary method — headless script (does NOT touch the user's live browser).** Prefer this; the
Playwright MCP browser collides with any session the user already has open. The helper lives at
`design/critic-gallery/_shot.mjs` (recreate it if missing — it launches `chromium` from the repo's
`playwright`, sets the `dark` class via `page.evaluate`, and writes full-page PNGs). Run:

```
cd /Users/dominabox/.claude/skills/social-hub
node design/critic-gallery/_shot.mjs <route> v<N>
# writes design/critic-gallery/<route-slug>/v<N>-{light,dark}.png
```

**Fallback — Playwright MCP** (only if the headless script can't run): `browser_navigate` →
`http://localhost:3017/dev/<route>`, then for each theme `browser_evaluate`
(`document.documentElement.classList.toggle('dark', <bool>)`) → `browser_take_screenshot`
(full page) → `…/<route>/v<N>-{light,dark}.png`.

Note: if a route 404s while its `page.tsx` exists, the dev server's route manifest is stale —
restart `PORT=3017 npm run dev` to pick up route folders added since it started.

Never wait on `networkidle` against `npm run dev` (the HMR socket keeps it busy; a pre-hydration click silently does nothing) — use `scripts/lib/wait-for-react.ts` (`__react*` keys on the node).

State captures: a `/dev` harness that replaces `window.fetch` makes Playwright `route()` a no-op — override the harness's own stub, and confirm the state shots actually differ before trusting them.

## Step 2 — Run the critic

Spawn the `design-critic` agent (Agent tool, `subagent_type: design-critic`). In the prompt give it:
- the image path(s) — tell it to **Read** each one. Mode A: the light + dark PNGs for this
  iteration. Mode B: whatever screenshot(s) the caller supplied (one is fine).
- the philosophy path (Constants),
- **Mode A only:** the route + the screen's source file path (so it can cite real structure).
  **Mode B:** there's usually no route/source — just say what the screen is if the caller told you;
  the critic judges the rendered pixels regardless.

It returns `VERDICT: SLOP|SHIP`, ranked failures, and **"the one move."** Capture all three.

Mode A: also run the contrast probe — `node ~/.claude/skills/maktura-design/contrast-probe.cjs <url> "main"` — a token proves provenance, not legibility; any sub-AA node is a SLOP-level finding.

(If `subagent_type: design-critic` errors with "agent not found", this session started before the
agent was installed — spawn a `claude`/`general-purpose` agent and tell it to `Read
~/.claude/agents/design-critic.md` and adopt that system prompt verbatim. Fresh sessions resolve
`design-critic` directly.)

## Step 2.5 — Function Manifest cross-check (no dead controls)

Design slop is only half the job — a beautiful screen with a button that does nothing still fails.
Cross-check the rendered screen against its Function Manifest (spec:
`~/.claude/skills/maktura-design/SCREEN-MANIFEST.md`).

1. Look for `apps/web/src/app/dev/<route>/MANIFEST.md` (or the in-product
   `apps/web/src/app/dashboard/<surface>/MANIFEST.md` if this is a real surface).
   - **Missing manifest** → that's the first finding: the screen has no function inventory. Author
     one from the rendered DOM before iterating (walk every interactive element, recurse into nested
     drawers/modals/sub-routes), then continue.
2. Enumerate every interactive element actually present in the rendered screen — use the DOM/snapshot,
   not just the screenshot (buttons, links, inputs, menu items, clickable cards, drawer/modal
   triggers, and the controls inside any nested surface you can open).
3. **Diff both directions:**
   - a control on screen that's **missing from the manifest** → fail (orphan control / forgotten in spec),
   - a manifest control that **isn't on screen** → fail (spec drift / control dropped),
   - a control whose manifest state is `stub` on a surface that should be wired, or that resolves to
     **nothing** when exercised → fail (dead control).
4. Treat any of these as a **SLOP-level finding** alongside the design critique — a dead or
   undocumented control outranks a styling nit. Fold the highest-leverage one into the iterate loop.

## Step 3 — Apply + iterate

- **SHIP** → record (Step 4) and stop. Report the verdict + why it isn't generic.
- **SLOP** → **batch, don't drip.** Take the critic's WHOLE ranked failure list, not just "the one move",
  and fix every item in one pass — then rebuild once, re-screenshot once, re-judge once. Loop that way
  until **SHIP** or 3 rounds. "The one move" is the priority order within the batch, not the batch size.
  Dom, 2026-09-22: one-fix-per-rebuild cost a 15-item design pass ~13 hours and five runs; minor items
  (padding, radius, spacing, copy) never justify their own rebuild. Only split a round when two fixes
  genuinely conflict, and say which two.
- `@maktura/ui` / `@/components/*` primitives only — never hand-roll a control that exists.
- Brand tokens only: `--paper / --paper-card / --ink / --rule / --coral / --mango` and friends.
  **Never** `slate-*`, `bg-white`, `text-gray-*`, or hex greys.
- Motion through `@/components/motion` (FadeIn / Rise / Stagger), never raw `<motion.div>`.
- No new dependencies. Keep the screen's existing data shape (these are stubbed dev screens).
- Apply the critic's ONE move, not a redesign — minimal, surgical, then re-judge.

## Step 4 — Record

Append one row to `design/critic-gallery/LOG.md` (create with a header if missing):

```
| date | route | iterations | final verdict | moves applied | screenshots |
```

Use a real timestamp from `date -u +%Y-%m-%dT%H:%M:%SZ`. List the batch of fixes applied at each
iteration. Point screenshots at the final `v<N>-{light,dark}.png`.

## Output to the user

- Final **VERDICT** + the critic's one-sentence reason.
- Iterations spent and each move applied.
- Paths to the final light/dark screenshots + the live URL `http://localhost:3017/dev/<route>`.
- If shipped a code change, remind: land it via the normal flow (`/design` wire or a ticket +
  `/finish` to develop) — `/critic` only edits the working tree, it does not commit or push.
