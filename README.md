# agent-harness

A project-agnostic agentic development harness. One installable Claude Code plugin holding the skills, agents, hooks and scripts that take a ticket from filed to merged — and **one config file per project** holding everything that differs between repos.

Extracted from [Maktura](https://github.com/mrdombie/maktura), where it ran for six months against ~900 tickets. The README is the one place the origin project is named — `scripts/check-project-agnostic.sh` reads the list below and fails CI if anything else in the repo matches it.

```
origin-names: maktura|socialhub|social-hub|mrdombie
```

## The idea

| Lives in the plugin | Lives in your repo |
|---|---|
| the skills, agents, hooks, scripts | `.claude/harness.json` — your facts |
| the mechanics of claiming, gating, shipping | your own gate scripts and CI |
| the git-safety guard rails | your project-specific rules |

The kit names no project. When it needs a project fact it reads the config, and when the config lacks one it **refuses with the key name** rather than falling back — a silent fallback is how a kit keeps working on the repo it was born in and quietly breaks everywhere else.

## Install

The repo is its own marketplace. In the consuming repo's `.claude/settings.json`:

```json
{
  "extraKnownMarketplaces": {
    "agent-harness": { "source": { "source": "github", "repo": "mrdombie/agent-harness" } }
  },
  "enabledPlugins": { "agent-harness@agent-harness": true }
}
```

Or per machine: `claude plugin marketplace add mrdombie/agent-harness && claude plugin install agent-harness@agent-harness`.

**Depends on [superpowers](https://github.com/obra/superpowers)** — `writing-plans`, `systematic-debugging`, `subagent-driven-development`, `test-driven-development`, `verification-before-completion`, `requesting-code-review`, `receiving-code-review`. The kit's build chain invokes them by name and does not vendor them; [`briefs/facts.json`](briefs/facts.json) is the machine-readable list — and it is the list the driver READS, not prose. The driver parks the ticket when a step's transcript shows none of the skills that file declares for it, and again when the answer claims a skill the transcript never shows.

`brainstorming` is deliberately NOT in that list. It waits on a person, so an unattended step cannot invoke it — the approved spec stands in for it, and `briefs/facts.json` records that under `notInvoked`.

Also needed on the machine: `gh` (authenticated), `jq`, `node`, `python3` (hook self-tests only).

## The config

`.claude/harness.json` in the consuming repo. Every key below except `legacyEnvPrefix`, `sisterRepos`, `design`, `uat`, `law`, `merge`, `mergeLane` and `preApprovedWrites` is required; a missing one refuses by name.

```json
{
  "repo": "you/your-repo",
  "integrationBranch": "develop",
  "trunks": ["develop", "uat", "main"],
  "branchPrefix": "tkt-",
  "stateDir": "~/.claude/your-tickets",
  "sisterRepos": [],
  "legacyEnvPrefix": "",
  "labels": {
    "drafting": "status:drafting",
    "ready": "status:ready",
    "claimed": "status:claimed",
    "inReview": "status:in-review",
    "gated": "status:gated",
    "partial": "status:partial",
    "blocked": "status:blocked",
    "externalBlocked": "status:external-blocked",
    "parked": "status:parked",
    "needsHuman": "status:needs-human",
    "pmDecision": "status:pm-decision",
    "pmTrack": "status:pm-track",
    "hold": "needs:human-approval",
    "decision": ["status:pm-track", "status:pm-decision", "needs:human-approval"]
  },
  "law": "docs/design/design-philosophy.md",
  "standards": "docs/CODING_STANDARDS.md",
  "gates": {
    "local": ["npm run gates"],
    "changed": ["npm run lint:changed", "npm run typecheck:changed", "npm run test:changed"],
    "formatChanged": "npm run format:changed",
    "requiredChecks": ["Typecheck + Unit tests", "Code gates"]
  },
  "review": {
    "rounds": 2,
    "attest": {
      "ui-gate": {
        "owed":   "npm run check:ui-gate-attested --silent -- --base origin/develop --head HEAD",
        "review": "<a command that runs your reviewer and prints its verdict>",
        "record": "scripts/record-verdict.sh ui-gate --sha {{SHA}} --base {{BASE}}"
      }
    }
  },
  "worktreeRoot": "~/your-worktrees",
  "worktree": { "prepare": ["npx prisma generate"], "scratch": ["docs/notes"], "sparseExclude": ["docs/evidence"] },
  "build": { "cacheDirs": ["apps/*/.next", ".turbo"], "cacheIdleMin": 30 },
  "commit": { "parkType": "chore" },
  "driver": { "parkPushEnv": "PARK_PUSH" },
  "design": {
    "kit": "@you/ui",
    "tokens": "packages/ui/src/tokens.ts",
    "surfacePaths": ["apps/web/**", "packages/ui/**"],
    "render": "npm run -s renders",
    "reference": ["docs/design/reference/kit.html"]
  },
  "programmes": { "brief": "scripts/programme-state-brief.sh {{EPIC}}" },
  "preApprovedWrites": { "environments": ["Staging"], "decided": "<who>, <date>" },
}
```

- `trunks` is optional (default: `integrationBranch` alone): every branch an agent must never push to, such as the integration, release and deploy branches. `scripts/check-push-destination.sh --worktrees <repo>` reads it and lists each worktree branch whose upstream is one of them, since a push that names no destination goes to the upstream. The same script with a root (or none) scans the commands written in a tree: a `git push` that names no `src:dst`, or a `worktree add -b` from a remote branch without `--no-track`, is a finding. CI runs it on the kit.
- `gates.changed` — the CHANGED-ONLY checks an agent runs locally, in order. This is what `/agent-harness:finish` and the `gate-runner` agent run; the whole-app form is CI's job. Measured 2026-09-28 before this existed: load sat at 32-40 on 10 cores because every agent ran a whole-app typecheck and a full suite that the push hook and CI then ran again. `no-repo-wide-format.sh` refuses the whole-app form from an unattended run, so this is enforced rather than asked for.
- `gates.prePush` — optional: the command that verifies a push, which the driver's self-check runs as its last gate so the push itself is a formality. Absent, it runs the worktree's own `pre-push` hook as `git push` does; `false` turns it off. `gates.prePushOwed`, optional, is the same checks without a review verdict, run in its place while that verdict is still owed (left out, the check waits for the push). The trial runs with `SIGNOFF_GUARD_DRYRUN=1`, so the sign-off guard refuses without side effects, and its refusal parks for the owner instead of going to fix. Measured 2026-10-17: self-check ran 3 changed-only gates, the pre-push ran 77 checks, and 5 driver runs parked on a check only the push ran (#236).
- `merge.updateBehind` — optional, `agent` (default) or `bot`. Set `bot` when the repo requires PRs to be up to date and runs a bot that brings behind PRs up to date one at a time. Agents then leave a PR that is merely behind to the bot instead of merging the integration branch in themselves, which queued a full extra CI run and landed their PR ahead of the one the bot was landing, restarting it (#79). A conflict is still the agent's. `scripts/behind-pr-action.sh` makes the call.
- `merge.method` — optional, `squash`, `merge` or `rebase`: how the merge lane merges. The lane refuses by name without it, and the coordinator tick only runs the lane where it is set.
- `review.attest` — one entry per reviewer the project attests, and **one entry is all there is**: an interactive `/agent-harness:finish` and the unattended driver ask different questions of the same reviewer, so they read the same row rather than two keys that can disagree about which reviewers exist. A row may name an `agent` in place of a `review` command (the driver then runs that reviewer itself), and `"needsRenders": true` marks a reviewer that judges pictures: with no render on the record it refuses by name instead of running.
  - `owed` — the command that says whether that reviewer is owed on this diff and prints the fingerprint its trailer must carry. `/agent-harness:finish` Step 3.5 runs them all together. A bare string in place of the object is read as this, which is the shape that shipped first.
  - `review` — a command that runs the reviewer and prints its verdict. The driver runs it in the ticket worktree and keeps the output verbatim.
  - `record` — a command that reads that output **on stdin** and writes the trailer, with `{{SHA}}` (the commit reviewed) and `{{BASE}}` (the trunk) substituted. **The driver never writes a verdict**: your recorder reads the reviewer's own words and decides whether there is one to write, which is the whole point of an attestation. A recorder that refuses parks the ticket carrying its message.

  A row with `owed` alone is advisory to the driver and enforced by `/agent-harness:finish`. A row with `review` and `record` is what lets the driver push at all on a project whose pre-push demands a trailer — measured on 2026-09-28, a ticket built test-first with two proved tasks lost 9 commits to exactly that. Absent entirely, the reviewers are advisory and nothing fails when one is skipped — which is the state that let 46 pixel-changing tickets ship with zero verdicts.
- `owns.skills` / `owns.agents` — kit names this project deliberately shadows. Everything else under its `.claude/` that the kit also ships is a duplicate and fails the gate.
- `review.rounds` — how many review rounds before non-blocking findings become follow-up tickets. Two.
- `review.maxRounds` (default 2) and `review.secondOnlyOnNewFiles` (default true) — the driver reviews a change ONCE. A later pass calls the reviewer again only when the fix round touched a file the first review never saw (files changed since the reviewed head, held against the reviewed diff's file list), and that review is graded as round 2: only Critical and Major block. Never past `maxRounds`. A pass that calls no reviewer takes the fix step's red-then-green proofs as the answer to the findings it was given. `secondOnlyOnNewFiles: false` re-reviews every pass up to the ceiling. Measured 2026-10-22: review was 26% of three days of driver usage.
- `claim.preflight` is optional: commands `/agent-harness:claim` runs at Step 0 in the project's checkout, with `$TOOLS` naming a copy of its `scripts/` as on the integration branch (`bash "$TOOLS/scripts/<check>.sh"`), such as a check that the machine's installed jobs match the ones the repo describes. They report and never block.
- `claim.planRules` is optional: the project's own planning rules, one sentence each, that `/agent-harness:claim` prints before the plan names a file (e.g. "extend a service's one home before adding a second client for it").
- `approval.previewOnly` is optional: a command that reads paths on stdin and exits 0 when every one leaves a pixel approval standing (preview pages, fixtures, tests). `/agent-harness:claim` uses it to tell an agent whether a commit voids an approval.
- A sign-off is attached to a commit. `scripts/clear-hold.sh <pr> --sha <shown>` takes the head the operator was shown, refuses (clearing nothing) when the PR has moved since, and ends its comment or review with `<!-- approval-head:<sha> -->`; without `--sha` it clears and records no head. `scripts/approval-kept.sh approved-head <pr>` reads back the newest sign-off: an approving review's own `commit_id`, or a clear-hold comment in its own words, ending in the marker, that a person's removal of the hold followed within 300 seconds. A comment alone counts for nothing, because everything on the operator's token can post one. `approval-kept.sh check <approved> <head> [--screens "<cmd>"]` exits 0 when every commit of the PR's own since then is a merge and none of its screen files changed, or the PR's own change to each one that did is the same: its added and removed lines in `<trunk>...<approved>` against `<trunk>...<head>`, so a clean merge of a trunk edit elsewhere in a file the PR also edits keeps the sign-off. The PR's files are read at both heads, `<trunk>...<approved>` and `<trunk>...<head>`, so a resolution that takes the trunk's version, drops an added screen or undoes a rename still voids. It exits 1 when one did, and 2 when GitHub's comparison cannot be read or the own diff was cut short. A screen is every file that is not a test (`tests.patterns`, `*.test.*`, `*.spec.*`, `__tests__/`, `__mocks__/`) and not under `design.neverScreens` (files that never draw, such as a deploy stamp), unless `design.surfacePathsComplete` is `true`. Then `design.surfacePaths`, or `--screens` (a command reading paths on stdin and printing the screen ones), decides alone. A partial list keeps approvals it should void, so it is never trusted until it is marked complete. The merge lane uses this; a project gate that re-applies a hold after a push should too.
- A project that lists `finish` under `owns.skills` has `/agent-harness:claim` hand over to its own `/finish`; the spawner always runs `/agent-harness:claim` and never a project's own spawn script.
- `gates.formatChanged` — the diff-only formatter, quoted back when a whole-folder format is refused.
- `gates.ratchets` — optional: `[{ "check": "<name the gate's output carries>", "tighten": "<the command that lowers its baseline>", "baseline": ["<path>", …] }]`. When a gate, the pre-push or ship's push fails only because a shrink-only ratchet sits above actual (the code improved), the driver runs that ratchet's `tighten`, refuses and restores any changed baseline in which a number rose or an entry appeared (and any file outside `baseline`, when given), commits the lowered baseline, and runs the gate again. A rise is never tightened; it goes to the fix round. Absent, the command the gate prints after `Lock the cleanup in:` is used; with neither, the red goes to fix with the reason named.
- `driver.formatWrite` is optional: the command the driver runs, with the branch's changed files as arguments, after each build task, after each fix round and before self-check's gates, committing what it changes so a format check never sends work back. Absent, a project with `gates.formatChanged` and prettier in its install gets `prettier --write --ignore-unknown`; `"none"` switches it off. Files already dirty in the tree are left alone.
- `stateDir` — per-machine state (the claims cache, the session label, the auto-skip list). One per project; two projects on one machine must not share it.
- `legacyEnvPrefix` — if your fixtures already pin env vars under an older prefix (`FOO_STATE_DIR`), declare `"FOO"` and the kit reads `HARNESS_X`, then `FOO_X`. The kit itself names no prefix.
- `gates.local` is the list of LOCAL gate commands, and it is the only part of `gates` anything runs. **CI is the one gate:** when `gates.local` holds every `gates.changed` command (or there is no `gates.changed`), it is THE local set — the fast checks — and the driver's self-check runs it and nothing else, with no trial of the project's whole pre-push. The driver's push then carries `HARNESS_LOCAL_GATES_HEAD=<sha>` when the set passed on that head (or on one with the same files), so a pre-push hook that honours it runs nothing twice; the full suite and the slow gates run once, in CI. A `gates.local` that leaves the changed list out is the older whole-app form, and self-check runs `gates.changed` and the pre-push trial as before. `group` names a gate group inside your own runner and `requiredChecks` names the CI checks a pull request waits on — neither is a shell line, and the driver never treats them as one. A flat `{ "<name>": "<command>" }` map is read too; a key whose value is not a string counts as an empty command, so it is named in the "nothing ran" refusal rather than dropped in silence.
- `standards` is the coding-standards document a change is held to, handed to the build step as its own fact. It has **no fallback**: without it the build agent is told there is none, and is told so in a sentence. It used to fall back to `law`, which meant a project with a design philosophy and no `standards` key had its build step told the design philosophy IS the coding standard — a wrong document, which cannot be seen from inside a prompt, where an absence can.
- `worktreeRoot` is optional (default `~/.harness-worktrees/<repo>`): where `/agent-harness:claim` and the driver cut ticket worktrees. `~` is expanded. Never a temp dir — on macOS `$TMPDIR` is a `/var/folders` directory the system prunes file by file, and `/agent-harness:claim` refuses one.
- `worktree.scratch` is optional: extra paths a step's own tooling writes into the worktree that are NOT the change. The driver moves them out into the run record after every model step, so neither the park's `git add -A` nor the ship step's clean-tree check ever sees them. `docs/superpowers` is always swept; a path git TRACKS is never touched, because there it is the change.
- `worktree.sparseExclude` is optional and **off by default**: folders an agent worktree leaves out of its checkout, e.g. `["docs/evidence"]` for committed screenshots, or file globs such as `["docs/evidence/**/*.png"]` to leave out only the images and keep the plan files beside them (measured at about 0.9 GB per worktree, 177 GB across 1,287). Set it and `/agent-harness:claim` and the driver cut worktrees with `scripts/worktree-sparse.sh`: a sparse checkout of everything except those folders. The main checkout is never made sparse. A step that writes new files into an excluded folder stages them with `git add --sparse` (`worktree-sparse.sh add-flag <worktree>` prints the flag only when the tree is sparse); the park and `/agent-harness:finish` already do.
- `build.cacheDirs` is optional: the build-output folders, as globs from a worktree's top level, that the cache pass removes. Default: `.next`, `.turbo`, `.nuxt`, `.svelte-kit` and `.parcel-cache` at the top level and under `apps/*` and `packages/*`. A folder holding a tracked file, or resolving outside the worktree, is never touched. The pass runs when a spawned agent exits (however it exits), on `/agent-harness:finish`, on a park, in the sweeper over every worktree it keeps, and in the coordinator tick before a low-disk alarm.
- `build.cacheIdleMin` is optional (default 30): the sweeper and the coordinator leave a cache folder alone if anything in it changed this recently, and both leave a worktree alone while any process has its working directory there.
- `changelog.branchTrailer` is optional: the commit-message line this project's changelog gate accepts ONCE for a whole branch as a reasoned skip (e.g. `no-changelog-branch`). When every build answer reported `changelog: {skipped}` and no commit on the branch carries the line, self-check adds one empty commit with `<trailer>: <reason>` — no history is rewritten.
- `design.surfacePaths` is optional: the globs this project calls a screen. The compare step matches the branch diff against them to decide whether there is a screen to render at all; without it that step says so and compares nothing. Entries are git pathspecs, so `":(exclude)**/*.test.ts"` takes test files out; a list of only excludes is refused, because git reads it as every other file. With a renderer but no approved picture for the change, compare takes the renders for review and makes no parity check.
- `evidence` is optional: the shape the project's CI leaves when it photographs a pull request, read by `scripts/ci-evidence.sh`. **Evidence comes from CI, not from the agent's machine** (2026-10-16): an agent pushes, opens the pull request held with an `## Evidence routes` list, waits on `ci-evidence.sh wait <pr>` (a shell that costs nothing while CI works), fetches CI's pinned shots with `ci-evidence.sh fetch` and has the design critic judge them (`/agent-harness:finish` Step 5.4). Keys and defaults: `dir` (`docs/evidence` — a commit after a verdict that touches only this folder, or nothing, carries the verdict forward), `begin` / `end` (`<!-- ci-evidence:begin -->` / `<!-- ci-evidence:end -->`, the body block CI writes; links outside it are not CI's evidence), `headMarker` (`ci-evidence-head:`, the commit CI photographed), `captureCheck` (`Capture and pin the evidence`), `decideCheck` (`Does this diff need pixels?`), `routesHeading` (`Evidence routes`). Local capture is a fallback a person switches on with `HARNESS_LOCAL_EVIDENCE=1` when CI evidence is down; the kit never sets it.
- `review.judge` is optional: the independent design critic (`scripts/critic-judge.sh`). **Only it sets the design status** (the owner, 2026-10-20). The coordinator's housekeeping starts it (`CRITIC_JUDGE_LAUNCHER=coordinator`); it refuses anything else, a build run (`HARNESS_DRIVER_RUN`) above all, and `hooks/no-self-design-verdict.sh` denies any session running the design recorder, committing a design-verdict trailer or starting the judge. It fetches only shots CI's own evidence commit wrote, behind a capture run that passed; stale shots hold the PR pending; the approved picture (the PR's own, or the plan's designRef) must pass `picture-evidence.py lint` and have every region shot, or the PR fails before any model runs. A picture with no region markers (approved before them) has its regions derived — its frames, else the PR's `## Evidence routes` at laptop/phone x light/dark — and the status description names the derivation; `scripts/picture-label.py` writes the markers in for good, attributes only. Real data and both widths are owed only by a picture approved on or after `coordinator.critic.realDataFrom` (2026-10-20; the picture's `data-picture-approved`, else its first commit or the ticket's "Picture approved" comment; no date known means exempt). The critic's answer must quote the shot set, name every shot it judged and end in a `FINDINGS … END FINDINGS` block of live findings only; it passes on SHIP, no DRIFT and an empty block. Verdicts live in a ledger only the judge writes (`<stateDir>/swarm/critic-judge/verdicts.tsv`), keyed on the shot set: the same pixels at a new head get the same verdict with no model call, and a PR comment or status description is never read back as one. A red verdict on a signed-off PR adds `labels.pmDecision` to its ticket instead of sending a repair. The judge never posts the status itself: it sends a `repository_dispatch` (payload `sha`, `pr`, `state`, `context`, `description`, `target_url`), and the project's own workflow re-posts it with the Actions token after checking the sender is the owner and the sha is the PR's open head. A ruleset that takes the check from GitHub Actions never counts a status a user token posts, and GitHub reads only the newest one, so a project using the judge must ship that relay. A verdict the ledger holds but never sent (`relayed.tsv`) is sent again from the ledger, with no model call. Keys and defaults: `context` (`Design critic`), `trailer` (`Design-Critic`), `agent` (`agent-harness:design-critic`), `mockGlob` (`.design/*-mock.html`), `turns` (40), `dispatch` (`design-critic-verdict`, the event type the relay listens for). Places, under `coordinator.critic`: `maxLive` (3; `review.judge.maxLive` is read when unset) judges at once — one place is always open, each above it only while the coordinator's room test fits another agent — and `timeoutMin` (20): a run past it is stopped, its place given back and the try counted. PRs owed a judgement start least recently started first. The project's own CI must stop writing that status from a trailer, or the two race.
- **An approved picture is readable from any machine** (`scripts/picture-approve.sh <ticket> <picture.html>`): the moment a picture is approved, the file goes into a secret gist (described `<projectName> #<ticket> approved picture: <file>`; `projectName` in harness.json, else the repo's name) and the ticket gets a comment starting **Picture for any machine** with the gist URL, the raw URL and the file's sha256. Rerun on the same file it does nothing; a new version publishes again. `/agent-harness:needsme`, `/agent-harness:auto` and `/agent-harness:bug` run it where they record an approval.
- **Evidence follows the approved picture** (`shared/picture-rules.md`, `scripts/picture-evidence.py`): every frame of the picture is a named region (`data-evidence-shot`, route, viewport, theme, optional setup); the ship step writes each into `<evidence.dir>/<key>/plan.json` (the key as CI files it, `scripts/evidence-plan.sh`: a `<branchPrefix>NNNN/` branch's ticket, else the PR number) (a shot the builder already planned keeps its setup) and lists them under `## Required evidence`; the independent critic fails the PR while any has no pinned shot. `picture-evidence.py lint` refuses a picture with no regions, without a laptop and a phone frame, or without the real-data cases (`duplicate-names`, `longest-names`, `empty`, `scrolled`) drawn or excused.
- `design.screenOf` is optional: a command that reads paths on stdin and prints the screen slug of each it knows. With it, a change takes on the polish list of every screen it touches, not only the screens its ticket is labelled with: each free item is a finding of the review at its grade (none named: Minor), and Critical, Major and Minor block (`scripts/screen-findings.sh`). The independent critic's open findings on the ticket's PR reach plan, fix and repair as `{{CRITIC_FINDINGS}}`.
- **Evidence owed is work** (`scripts/evidence-gaps.sh`, `scripts/evidence-gaps.py`): a changed UI file that no evidence route or capture-plan shot renders (a page, a layout above it, or anything they import — relative, `@/`/`~/` and workspace-package imports followed), or a drawer, dialog, menu or sheet with no plan shot whose `setup` opens it, is an evidence gap. A plan the PR adds or edits replaces the routes, as CI reads it. The independent critic fails the PR on a gap before any model runs, as an `evidence gap:` finding; the repair and fix steps are handed every evidence-class finding (`{{EVIDENCE_TASKS}}`) as a task answered by an edit to `<evidence.dir>/<key>/plan.json`, and the repair step calls the model for one even when nothing is red, then refuses a repair that leaves the plan unchanged or a gap open. Ship copies the plan's routes into `## Evidence routes` (a repair adds routes only, rewriting nothing). With no picture binding the ticket, ship plans the routes the changed screens render on (fewest that show every changed file, no dynamic segment) at laptop 1440 / phone 390 x light / dark, keeping any shot the plan already has for a route, width and theme. `evidence.coverage.ignoreRoutes` (default `/dev`) names route prefixes whose pages are a component catalogue, not screens.
- **Only CI's shots are evidence**: `ci-evidence.sh` counts a shot only when it is linked at the sha the block names, that commit's subject starts `evidence.commitSubject` (`chore(evidence):`), the commit wrote the file, and CI's capture check passed on its parent. A builder's PNG inside the block is refused by name. A shot CI re-captured byte-identical is in the tree but not in that commit's diff; it still counts when its name is one CI's capture produces for this head (the folder's `plan.json` shot names, else the slugs of `## Evidence routes`) and its blob is one an earlier CI evidence commit on the PR wrote at that path.
- `ci-evidence.sh status` reads `stale` (exit 6 from `wait`) when CI kept shots pinned before a merge that changed one of the PR's own screen files, or a file one of them imports by a relative path; `ci-evidence.sh moved <pr> <from> <head>` is that test, for a project's CI to call before it carries pinned shots forward.
- `design.reference` — a path, or a list of paths, to the approved reference picture(s) that define this project's kit look (HTML or PNG). The `design-critic` agent's picture mode holds every proposed picture against it before the operator sees it, and returns `KIT: MATCH | KIT: DRIFT`; with no reference declared it returns `KIT: DRIFT`, so a project that draws pictures needs one. `scripts/check-picture-mode.sh` refuses a skill that hands the operator a picture without naming picture mode.
- `design.render` is optional, and it is the LOCAL capture: the driver runs it only with `HARNESS_LOCAL_EVIDENCE=1`, and otherwise records that CI owes the pictures after the push. It is a command run in the ticket worktree that prints one render per line as `name<TAB>path<TAB>light|dark<TAB>route`. Its output becomes the renders the compare step holds beside the approved design, and the renders the review step is given. Absent is an absence the reviewer and the pull request are TOLD about in those words; declared and producing nothing is a refusal, because a measurement that could not be made is not a screen that is fine. Exit 3 is the one exception: it means the renderer knows no screen this change touches, and is recorded as an absence in the renderer's own words, exactly as a project with no renderer.
- `programmes.brief` is optional: a command that prints the BRIEF of a programme's state file, with `{{EPIC}}` and `{{FILE}}` substituted. These files are append-only and grow for as long as the programme is open, and a step handed the whole thing designs from the programme's history rather than from its own ticket. The driver finds the file by **what it says** — the state file whose content names the ticket's programme label — never by its filename: on the project this was measured on all 29 files are named for the epic and the label lives in the body, so a filename glob matched none of them.
- `review.diffBytes` is optional (default 400000): how much of the branch diff the review step hands the reviewer. Past it the diff is cut and the cut is STATED beside the file list, because a reviewer handed a silently-shortened diff reviews a change it cannot see the rest of.
- `tiers` is optional. The driver tiers every build by the files it changes (`driver/tier.sh`) and says the tier in the PR body. **screen**: the screen set, a `design.screenOf` mapping, or a route page; the full design process applies. **backend**: product code and no screen; the full review runs, with no compare, no evidence plan and no design-critic verdict owed. **tooling**: every file matches `tiers.toolingPaths` (default `.github/*`, `.claude/*`, `.husky/*`, `docs/*`, `*.md`, `.changeset/*`, `CHANGELOG*`; `*` crosses directories); it gets one review round, in which only Critical and Major block. A later push that touches a screen promotes the build. Tiering is on when `design.surfacePaths` is set. `tiers.enabled` overrides that either way.
- `worktree.prepare` is optional: commands run in every fresh worktree the driver cuts, and in the two trees its red-before-green proof checks out. This is for whatever your repo generates per checkout and gitignores — a generated database client, a build artifact a hook imports. Absent is normal and skipped. Three things are refusals, because a tree that cannot pass your pre-push is better discovered before the build than after it: a command that **fails**, a `prepare` that is **not a list** (a bare string prepares nothing and used to report success), and a **list entry that is not a command**.
- `labels.ownerDecision` is optional (default `needs:owner-decision`): the label a ticket wears while a question only the owner can answer is open on it (`scripts/owner-question.sh`). No spawner takes a ticket wearing it.
- A ticket wears exactly one lifecycle status. Every step sets it with `issue_status_set <n> <status>` (`scripts/issue-status.sh`, sourced by `toolkit-env.sh`), which removes every other status label in the same edit; `scripts/check-status-label-writes.sh` fails CI on any other way of adding one. `labels.pmDecision`, `labels.pmTrack`, any status label in `labels.decision`, and `labels.batched` are markers that sit beside the lifecycle status on purpose: `set` keeps them, `issue_status_mark` adds one, and `--drop` takes one off when its question is answered.
- `labels.pmDecision` (default `status:pm-decision`) is also the label the driver's park puts on a ticket whose question is about its shape — which repo, how it splits, the order, the wording of its acceptance. The PM answers and clears it; the owner's hold label goes only on a question about pixels, a picture, a product or commercial call, or the data model, and on any question the step did not classify.
- `commit.parkType` is optional (default `chore`): the conventional-commit type the driver's park uses for its work-in-progress commit. Your commitlint enum decides; `wip` is not in most of them, and a park whose commit is refused is a park that loses the work.
- `driver.parkPushEnv` is optional (default `PARK_PUSH`): the environment variable the driver's park sets to `1` on its push of a draft branch, so the project's pre-push can let a park through quality checks that work in progress fails by definition. Without it a red check refuses the park's push and the work survives only as a local bundle. Only a park sets it, never on a branch listed in `trunks`; every other push, including the ship, strips it even when the caller's shell has it. A project whose pre-push does not honour it loses nothing: the push is refused and the park bundles the commits as before. A value that is not a variable name sets nothing and the park says so.
- Work a park could not push (the pre-push refused it, or a repair's push is withheld because its PR may have auto-merge armed) also goes to `refs/stranded/<ticket>/<host>-<utc>` on origin, beside the local bundle. Not a branch or tag, so no workflow, branch protection or auto-merge reacts to it, and no PR head moves; like the bundle it skips the pre-push. The next `start` or `reenter` for the ticket, on any machine, resumes from the newest one when origin's branch lacks its commits. One older than `driver.strandedKeepDays` (default 14) is deleted once its commits are on the ticket's branch. `driver.parkRefNoVerify` is no longer read.
- Each coordinator housekeeping pass also keeps the host's own shared state current. `scripts/shared-install.sh` compares origin's `package-lock.json` on the integration branch with the lock the shared clone's install was made from (`node_modules/.harness-shared-install`); when they differ and no build on the host is past its first steps, it moves the shared clone's checkout to the trunk and runs `npm ci --no-audit --no-fund` under a lock and a time limit (`coordinator.sharedInstall.timeoutMin`, 30), putting the old install and checkout back on a failure (retried after `coordinator.sharedInstall.retryMin`, 60). `scripts/stranded-sweep.sh`, at most every `coordinator.strandedSweepEveryMin` (60), pushes any worktree under the worktree root whose commits are on no ref of origin to a stranded ref; never one a live run holds, and it deletes nothing.
- `tests.patterns` is optional (default `["*.test.ts", "*.test.tsx", "*.spec.ts"]`): the globs, matched against the whole path, that name a test file for `scripts/check-deleted-tests.sh`. `HARNESS_TEST_PATTERNS` (space-separated) overrides it. A value that is not a list is a refusal, not the default.
- `tests.db` is optional: a throwaway, migrated database for the driver's proofs and for the build, fix and repair steps' own test runs, e.g. `{"urlTemplate": "postgresql://u:p@localhost:5432/{name}", "admin": "postgresql://u:p@localhost:5432/postgres", "setup": "npx prisma migrate deploy"}`. Each proof half and each such step gets its own database named `hp_<ticket>_<pid>_<n>`, created through `admin` with `createdb`, `setup` run in that tree with `DATABASE_URL` at it, the command run with `DATABASE_URL` exported, and the database dropped with `dropdb` on the way out, a failure, timeout or signal included. `urlTemplate` must hold `{name}`. The driver drops only a database it created in that run and refuses any name outside `hp_`. A database that cannot be created or set up is "the tree could not be prepared" (exit 5), never a red; a step then runs with `DATABASE_URL` unset. Absent, nothing changes.
- `tests.e2eProofs` is optional, default `false`: a proof tree runs no app server, so an e2e browser spec (`e2e/**/*.spec.ts`, or a `playwright test` command) named as a red-then-green proof is turned back before a tree is built, and a proof half whose output shows the app could not be reached (`net::ERR_CONNECTION_REFUSED`, `page.goto: net::ERR_`, `ECONNREFUSED` to localhost) is "never run there" (exit 9), never "still fails". Build, fix and repair are sent back once, told to prove with a unit or DOM test; the e2e spec can still ship as extra coverage. Set it `true` only when the project's own e2e harness brings the app up.
- `lesson` is optional, and `scripts/check-lesson.sh` reads it: `fixLabels` (default `["bug", "type:bug"]` — a PR, or an issue it closes or references, carrying one is a fix), `fixIssueTypes` (default `["Bug"]`), `fixClasses` (default `["repair", "approved-merge"]`, matched as a `<classLabelPrefix><class>` label on the PR), `classLabelPrefix` (default `class:`), `guardPatterns` (default: test, lint and gate globs such as `**/*.test.*`, `**/eslint-rules/**`, `**/*.semgrep.yml`, `**/check-*.*`, `**/gates/**`, plus `tests.patterns`; set, it replaces both) and `guardExclude` (default `*.md`, `*.mdx`, `*.txt`, `*.rst`, `docs/**` and the like). A pattern with no `/` matches the file name anywhere; one with a `/` is anchored at the repo root; `*` stays inside a directory and `**` crosses. It is read at the base commit. `HARNESS_GUARD_PATTERNS` (space-separated) can only narrow the guard set. A value that is not a list is a refusal. The driver's repair step also reads `lesson.check` (default `lesson`): a red check whose name contains it is the lesson check, answered by writing `## Lesson` into the PR body.
- `preApprovedWrites` is optional: environments whose writes (a back-fill, a one-off script, a data fix) the operator has approved in advance. `decided` is required and names who made the call and when. The standing rules say a general policy is not a yes; this is the one exception, and `hooks/standing-rules.sh` appends it to every session as its own section. It never covers an outward-facing action in any environment (publishing to a real account, sending email or messages), any environment not listed, or a command refused at a prompt, and the section says so. Only the operator adds or widens it. Two things hold that line. Only the committed value counts: a working-tree value that differs from `HEAD`'s grants nothing until it is committed. And `hooks/guard-pre-approved-writes.sh` refuses an agent's change to the parsed value (Write, Edit, and the Bash routes that name the file, plus `git commit`, `checkout`, `restore` and `apply`) and tells it to ask the operator. Removing the key stays allowed, since that grants nothing. Both values are pasted into the rules, so they are held to plain tokens: a name is letters, digits and `. _ -` with no spaces, up to 32 characters, and never a word for every environment (`all`, `any`, `every…`, `*`); `decided` is exactly `<name>, YYYY-MM-DD`. Anything else, a `harness.json` that is not one JSON object, or one that names the key twice, grants nothing, and the session is told so.
- `design` is optional: a backend-only project has none, and the design skills refuse on its absence rather than inventing one.
- `panel` is optional and only `/agent-harness:panel` reads it: `dir` (where your rooms live, e.g. `.claude/panel`, required for the panel), `bar` (the gate, default 70), `browser` (a Playwright install for click-checks), `builderPrompts` (your spec-review prompts). The rooms — one file per product area, the people who'd use it — are yours and live in `dir`; the kit ships only the method and the five screen reviewers. Memory and runs stay per machine under `stateDir/panel`.

Read a value with `toolkit_cfg <dotted.key>` after sourcing `scripts/toolkit-env.sh`. Arrays join on spaces, so `for l in $(toolkit_cfg labels.decision)` reads naturally.

The file is read from `origin/<integrationBranch>` after a one-branch fetch (once per process), so a stale checkout cannot hide a key that has merged. The working tree is read only when no remote ref carries the file, and the clone's `HEAD` after that. `HARNESS_CFG_PATH` pins a file and `HARNESS_CFG_REF` a ref; `HARNESS_CFG_FROM` names where the config came from, and the coordinator logs it on every tick.

Env overrides always win over the config: `HARNESS_STATE_DIR`, `HARNESS_REPO_ROOT`, `HARNESS_MAIN_REPO`, `HARNESS_SISTER_REPO`, `HARNESS_CFG_PATH`, `HARNESS_LOGIN`, `HARNESS_KIT_ROOT`.

## What is here

```
skills/    file claim finish release release-stale queue needsme standup
           work auto bug ui-gate cheatsheet claim-status sweep-worktrees project
           panel (+ its five screen reviewers)
agents/    gate-runner frontend-gate design-critic
hooks/     hooks.json + the scripts it runs, each with a .test.sh beside it
scripts/   toolkit-env.sh (the resolver) · claim-lock.sh · reconcile-claims.sh
           overlap-check.sh · spawn-claim.sh · claimable-issues.sh · clear-hold.sh
           approval-kept.sh (does a sign-off survive an update; the head it was given at)
           signoff-push-guard.sh (a pre-push: no screen change after the owner signs)
           check-project-agnostic.sh (CI) · panel-report.py (the panel's report)
           check-deleted-tests.sh (a deleted test is accounted for — see below)
           check-push-destination.sh (every push names its destination; CI)
           coordinator-tick.sh · coordinator-queue.sh · coordinator-judge.sh
           coordinator-notify.sh · coordinator-compare.sh (the coordinator — see below)
           coordinator-sheet.sh (one shared build order across machines — see below)
           merge-lane.sh (the serial merge lane — see below)
           signoff-batch.sh (held PRs green apart from the hold, every reviewer's
           recorded verdict on the head, in batches of five)
           needsme-watch.sh (the shell half of /needsme --watch: asks once, idles free)
           loop-start.sh (a /work or /auto loop's marker for the keep-working hook)
           fix-lock.sh (one fixer per red PR) · pr-watch.sh (waits on a PR in the shell)
driver/    build-ticket: one ticket, seven fixed steps, the model called only for
           the thinking · facts.sh fills the briefs' placeholders and refuses when
           one has no value · prompt-schema.jq derives the shape the model is
           bound to from the contract — see driver/README.md
swarm/     agents that run with no session open: scheduler · queue · repair-watch
           live-view · report · install — see swarm/README.md
rules/     standing-rules.md — put in front of every session by a hook, so a
           second machine behaves like the first
shared/    operator.md · agent-signoff.md
reference/ the copies this plugin replaced, kept for history. Loaded by nothing.
```

Invoke a skill as `/agent-harness:<name>` — plugin skills are namespaced by Claude Code. Agents are `agent-harness:<name>` in the Agent tool.

### Hooks

| Event | Hook | Does |
|---|---|---|
| SessionStart | `standing-rules.sh` | puts `rules/standing-rules.md` in front of the session |
| SessionStart | `precedence.sh` | one line per kit skill this repo overrides |
| PreToolUse (Bash) | `block-push-no-verify.sh` | refuses `git push --no-verify` |
| PreToolUse (Bash) | `block-hookify-rules.sh` | the git-safety rules: hand-released claims, `commit -a`, `commit --no-verify`, `reset --hard`, `git add -A`, `npm install` in a worktree, hand-rolled PRs, hand-rolled ticket branches |
| PreToolUse (Bash) | `no-repo-wide-format.sh` | refuses a formatter over a whole folder, and a whole-app check from an unattended run |
| PreToolUse (Bash) | `no-broad-kill.sh` | refuses a `pkill`/`killall` pattern that would hit a peer agent |
| PreToolUse (Write\|Edit) | `block-write-traps.sh` | a phantom worktree path, an edit in the shared clone, a credential in a memory file, a new command or skill born outside the kit |
| PostToolUse (Bash) | `one-preview-per-agent.sh` | when an agent starts a dev server, stops the ones it left in its other ticket worktrees |
| SessionEnd | `session-end-cleanup.sh` | drops the session's own scratch state |
| Stop | `signoff-backstop.sh` | refuses a hand-back without the sign-off banner while work is live |
| Stop | `ask-dont-narrate.sh` | refuses a hand-back that leaves a decision in prose (the operator's tells, or a question to him); a report's shape alone never fires it |
| Stop | `keep-working.sh` | refuses a hand-back mid-loop while the scope still has runnable tickets (the loop is marked by `scripts/loop-start.sh`) |
| Stop, UserPromptSubmit | `heartbeat.sh` | asks a loop wake with no status to add one plain `Status:` line (the old block still passes); a status naming only a wait gets advice on the next prompt, never a refusal |
| StopFailure (rate_limit) | `usage-limit.sh` | records when the plan's usage limit resets in `$STATE_DIR/usage-hold`, so the coordinator and the scheduler spawn nothing until then |

The git-safety rules are hooks, not hookify rules, on purpose: hookify loads rules with a relative glob on `.claude/hookify.*.local.md`, so every rule is inert unless the session started inside a checkout. A hook reads the command text before bash does and does not care about cwd. **A consuming repo that carried these as hookify rules removes them**, or they fire twice.

### Sign-off comes last

The owner signs a screen after everything else, and nothing they signed changes
afterwards. Four places hold it:

- `signoff-batch.sh` sends a held PR to the owner only once every `review.attest`
  reviewer's recorded verdict (`<Key>: SHIP (<who>) <fingerprint>` in an empty
  commit) is on its head, walking past empty commits, CI evidence commits
  (`evidence.commitPrefix`) and merges that only bring the trunk in.
- The claim and finish skills, every driver step brief and every spawned builder's
  prompt lead with `shared/signoff-last.md`; the review brief says a pixel finding
  on a signed PR is a follow-up. A driver push the guard refuses parks for the owner.
- `scripts/signoff-push-guard.sh` refuses a push whose head differs from the signed
  head in one of the PR's own screens, unless a commit since the sign-off carries
  `pixel-change-after-signoff: <why>` — then it puts the hold back on, comments the
  before and after on the PR, and logs a `lane-hold` line for the owner's next
  batch. Signed means any sign-off, a person removing the hold on GitHub included
  (`approval-kept.sh signed-head`). The trees are compared, not the commits, so a
  merge taking the trunk's side or a force-push back is caught. A screen whose
  tree differs counts only when the PR's own change to it differs too
  (`approval-kept.sh own-changed`), so a clean merge of a trunk edit elsewhere in a
  shared file goes. Only this PR's own commits give a reason; the trunk's squash
  commits carry other PRs' reasons.

The screens are one set, `approval-kept.sh screens`, which the guard and the briefs
share: `design.surfacePaths` plus `design.extraScreens` (files outside those globs
that still draw — a stylesheet, `public/` images, copy an API serves), never tests,
`design.neverScreens` or release notes (Markdown, `docs/`, `.changeset/`, CHANGELOG:
their wording may change after sign-off). A server-only fix is not a screen.
`approval-kept.sh check` keeps a wider rule for the merge lane — with
`surfacePathsComplete` unset every non-test file counts — because there a file
wrongly counted costs one re-sign, and one wrongly missed ships unsigned.

The kit ships no git hook, so the consuming repo's own pre-push calls it: save
stdin once, feed it to every check that reads it, and run the guard last, after
the project's own push checks, so a push they refuse never puts the hold back on:

```sh
REFS=$(cat)
# … the project's own checks, fed "$REFS" where they read stdin …
printf '%s\n' "$REFS" | bash "<kit>/scripts/signoff-push-guard.sh" "$@" || exit 1
```

### Scripts the skills expect in the consuming repo

The kit's own scripts live here and are addressed from the plugin root. A few repo-side conventions are read from the consuming repo's `scripts/` (materialised from `origin/<integrationBranch>` by `toolkit_tools`) when present, and skipped when not: `programme-status.sh`, `programme-state-brief.sh`, `refresh-shared-manifests.sh`, `auto-promote-gated-children.sh`, `queue-health-report.sh`. Child 4 of the extraction (the gates contract) turns those into config. The worktree sweeper used to be one of them; it is now the kit's own `scripts/sweep-orphan-worktrees.sh`, so a project copy is no longer read.

## Adding a skill

Every new skill, command, agent or hook starts **here**, not in a personal `~/.claude` folder: `skills/<name>/SKILL.md`, project facts read from `.claude/harness.json` (refusing by key name when one is missing), a test beside any script, a version bump, a PR. Then update the plugin on each machine. Something only one project needs goes in that project's `.claude/skills/` instead. A skill that exists only in one person's `~/.claude` is one machine away from being lost.

## A deleted test says what replaced it

A pull request that deletes a test file, or deletes `it(` / `test(` cases from
one, fails until its body accounts for each file:

```markdown
## Deleted tests
- `src/desk.test.ts` → covered by `src/desk/one-desk.test.ts`
- `src/export.test.ts` → removed on purpose: CSV export was retired
```

"covered by" must name a test file that exists at head with a live case;
"removed on purpose" must give a reason. A file git sees as **renamed** is not a
deletion, but its cases are compared across the rename. A case turned off —
`.skip`, `.todo`, an `x` prefix, inside a skipped describe, or left out by a
`.only` elsewhere in the file — counts as lost, and a new case in the same file
never stands in for it. A diff, file or tree git could not read refuses (exit 2)
and names the step; it never reports clean. It counts cases, not titles: a case renamed or reworded
where it stands, or moved to another test file in the same diff, is matched to its
new form and owes nothing. Only a drop in the count, or a named case with nothing
like it at head, needs a line. The diff is two dots, base..head, read from the two
commits — never the working tree — and anything the trunk added after the branch
was cut is excluded. Written after a rebuild on the origin project deleted eleven
test files in one merge: one pinned a behaviour the new screen dropped, nothing
went red, and a real user was blocked for a week.

It runs in three places, so skipping a skill does not skip it:

- **CI** — `.github/workflows/deleted-tests.yml` is a reusable workflow. The
  consuming repo calls it on `pull_request` (with `edited` in the types, so fixing
  the body re-runs it) and makes `Deleted tests are accounted for` a required
  check. It reads the pull request's merge commit, so `HEAD^1..HEAD` is exactly
  what merging changes. While this repo is private the caller passes a token that
  can read it as `harness_token`, and the repo's Actions access setting must allow
  the caller's workflows. The kit runs it on itself through
  `kit-deleted-tests.yml`, with `*.test.sh` as its pattern.
- **`/agent-harness:finish`** — Step 5.6, before the merge.
- **The driver's ship step** — its body carries no such section, so a branch that
  deletes a test stays a draft and parks with the files named.

## Every fix ships a lesson

Healing a build is pointless if the same class of mistake comes back. A fix is
known by what it is, not by one tag: a fix label, a `class:repair` or
`class:approved-merge` label, a `fix:` / `fix(scope):` title, a `fix/` or `fix-`
branch, or a bug-typed or bug-labelled issue it closes **or** references
(`Refs #N`, `Part of #N`). A fix pull request fails until its body carries:

```markdown
## Lesson
- Principle: A missing reading never counts as safe to go.
- Guard: `scripts/machine-gate.test.sh`
- Before/after: the new case fails on the old sampler and passes on the fix.
- Reach: it covers the memory and load readers too.
```

The Guard must be an executable test, lint or gate file that the diff (two dots,
base..head) **changes in substance**: naming an old test the fix never touched is
refused, and so are a whitespace-only edit, a pure rename, docs and prose (`*.md`,
`docs/**`) and workflow files. Or, instead of a Guard, one line of at least eight
words, `Not automatable because <reason>`, which passes and prints
`lesson: not-automatable` so a weekly report can count it. HTML comments, fenced
and indented code never count (an unclosed one runs to the end of the body), so the
template's placeholder is not an answer. The block to paste into a PR template is
`templates/pull-request-lesson.md`.

**Everything it judges by comes from the base.** The config is read at the base
commit, the `guard-patterns` input can only narrow the guard set, and when the kit
judges its own pull request the script is taken from the base commit. One gap
GitHub leaves open: on `pull_request`, the calling workflow file is the pull
request's own copy, so protect `.github/workflows/` with CODEOWNERS or a ruleset.
Relabelling a linked issue does not re-run the check; a push, a body edit or a
label change does.

**Rolling it out.** Measured on one consuming repo, 58 of its last 100 merged pull
requests would have failed, 56 of them only for the missing section. Add the
workflow as a check that is not required first, so builders see it and start
writing the section, and make it required once fix pull requests carry it.

The enforcement is CI, not an agent's instructions: `.github/workflows/lesson.yml`
is a reusable workflow the consuming repo calls on `pull_request` (with `edited`,
`labeled` and `unlabeled`, so fixing the body or a label re-runs it) and makes
`Every fix ships a lesson` a required check. Config is read from the base commit,
so a pull request cannot loosen the check that judges it. `/agent-harness:claim`,
`/agent-harness:bug` and `/agent-harness:finish` tell builders to write the lesson
as they go; that is guidance only. The kit runs it on itself through
`kit-lesson.yml`.

## Building one ticket

`driver/build-ticket <ticket>` walks a ticket through seven fixed steps —
start · plan · build · self-check · review · record · ship — calling a model only
for the four that need thinking, one step at a time. It refuses to skip a step,
resumes from the last one that finished, proves each new test red before green
with its own hands, and parks the ticket with the question whenever a step asks
one. Full description, the guarantees and every seam:
[`driver/README.md`](driver/README.md).

`driver/build-ticket <ticket> --repair <brief>` is the same walk for a pull
request that went red, clashes, or came back with a brief after it was handed off.
It re-enters the PR's own branch, never a fresh one, and merges the trunk in for a
clash. It proves each fix, either as a test red then green or as a gate command
green at the head, then runs the same gates, review and ship onto that same PR.
`--brief <brief>` is a repair when the ticket has an open PR, and otherwise a build
with the brief put in front of every step.

It is the replacement for the two hand-copied build commands, not an addition to
them: `docs/design/claim-finish-inventory.md` maps all 178 of their rules to a
driver step, a brief, a hook, a required check, or a named retirement.

## Running without a session open

`swarm/install.sh` puts four timers on the machine: the live view everything
else reads, a scheduler topping each programme up to three agents, a watcher
that brings one agent back to a broken pull request and stops after three, and
a reporter. `swarm/queue.sh add <ticket> --brief <file>` is how a ticket joins
the queue — it replaces writing a launcher by hand. Full description, the rules
it holds to and every setting: [`swarm/README.md`](swarm/README.md).

### The coordinator — a fresh process per check

This is the non-stop path: it keeps working while no window is open.

An overnight `/loop /agent-harness:work <scope>` re-sends its whole conversation
on every wake. `scripts/coordinator-tick.sh` does the same job as one short
process with no model call: it reads the runs that ended, spawns the next queued
ticket through `spawn-claim.sh` while the machine has room, runs `reconcile-claims.sh` and the
dev-server sweep, checks the disk, and writes every event that needs judgement
to a file. Every named ticket's builder is the step driver (Dom, 2026-10-17), with
the run's budget capping each step:
- a new build is `driver/build-ticket <n>`
- a repair or approved-merge run is `build-ticket <n> --repair <brief>`, or
  `--repair-class <class>` when the queue row had no note. It is a repair of the
  ticket's open PR on its own branch, never a fresh build.
- any other run a caller hands a brief (a repair watcher's brief, an owner's answer,
  a resume after a cut) is `build-ticket <n> --brief <brief>`. That is a repair
  when the ticket has an open PR, and otherwise a build with the brief in front of
  every step.

No run with a ticket falls back to the prose claim. `--fg <n>` runs the same
driver in the terminal, with the same brief channel. The prose claim
(`claude -p "/agent-harness:claim"`) builds only pick-next runs, where no ticket
is named. `swarm.builder: "prose"` in `harness.json` puts every run back on it.

How the driver treats a brief:
- **It never acts on a brief's instructions to push, re-arm auto-merge, mark the
  PR ready or hand off.** Briefs written for the prose flow say all of those. The
  driver alone does them, after its own gates and review. Each brief is handed
  over under a preface saying so. Inside a step, `git push`, `gh pr ready`,
  `gh pr merge` and `gh pr create` are refused. Origin's head for the branch is
  checked before and after every step, and a step it moved under is refused
  and parked.
- **Size:** a brief is capped at 4 KB for the steps, with a notice; the whole of
  it is kept beside.
- **A failed lookup loses nothing:** a `--brief` whose PR lookup still fails after
  three tries goes back on the queue with its brief as the note.
- **Expiry:** a build's brief ends when the ticket ships, or when a repair round
  starts.
- **Person-caused parks** are asked through `owner-question.sh` (the owner's label
  and channel). The answer comes back on the queue as a brief. The hold label is
  only the fallback when the question cannot be asked.

Each judgement event gets one fresh `claude -p` with a short brief
(`scripts/coordinator-judge.sh`), a turn cap, a budget and a bounded compact
window — never the session history. State lives in `$STATE_DIR/coordinator/`.
It does not judge a red PR that a session holds through `scripts/fix-lock.sh`, and
it spawns nothing while `$STATE_DIR/usage-hold` (written by the `usage-limit.sh`
hook when any window hits the plan's limit) says the limit holds, nor while the
newest run's usage reading puts a window at `swarm.usageCeiling` or over.
`spawn-claim.sh` itself refuses (exit 75) under the same hold, so no other
spawner can start a run into the wall either, and no judge starts during it. A
run the limit or a lost login cut off goes back to the front of the queue with
its worktree and session named, to resume rather than start over.

A tick is the starts. The merge lane, reconcile, the sweeps, the disk pass and
the judge run in `coordinator-housekeeping.sh`, in the background once the
starts are made, under a lock of their own and at most every
`coordinator.housekeepingEveryMin` (default 5). A run whose last word is a wait
on a human (its status table's "Waiting for" row names you, a sign-off or an
approval, or it says it has no question tool) is not picked again until the
wait moves: a label on the ticket or its PR, a new commit, a comment, or a red
check. The tick log says `skip #N: waiting on a human since run …` until then.

The coordinator shares one GitHub token with every builder, so it reads the
forge once a pass, never once a ticket: one open-PR read, the queue's tickets in
batched GraphQL requests of 50 (`scripts/gh-batch.sh`), the queue re-seeded every
`coordinator.refreshEveryMin` (default 5). When GitHub refuses the token for a
rate limit, every swarm read backs off (4 minutes, doubling to 32) and the tick
works from the last good read while it is under `coordinator.snapshotMaxAgeMin`
(default 15) old; housekeeping's GitHub passes wait for the next run.

```sh
scripts/coordinator-queue.sh seed <scope>[,<scope>…]   # tickets, labels or programme subjects; a list is their union
swarm/install.sh coordinator                # every 2 minutes; SHADOW unless COORDINATOR_SHADOW=0
scripts/coordinator-compare.sh --since <ISO>  # the shadow's calls beside the loop's runs
swarm/install.sh uninstall coordinator
```

**Shadow is the default.** Every act is written to `actions.log` as "would …";
nothing is spawned, killed, posted or notified, and housekeeping runs dry. Run
one shadow night beside the loop and read the compare report before installing
with `COORDINATOR_SHADOW=0`. A green pixel PR or a call for the owner sends a
desktop ping (or `COORDINATOR_NOTIFY_CMD`) and a line in `needs-you.md`, which
`/agent-harness:needsme` reads.

| Key (under `coordinator`) | Default | What it is |
|---|---|---|
| `cap` | unset | An optional hard ceiling on live ticket runs. Unset, the machine decides; `0` spawns nothing; anything not a whole number holds every spawn and says so |
| `keepCpuIdle` | 15 | CPU idle % kept back, read as the median of the recent samples (`swarm.idleSamples`), when filling the machine. Never under `swarm.minCpuIdle` (the hold floor) |
| `agentCpuCores` | 0.8 | Cores one builder uses (measured 2026-10-16: two builders at 167–182%). The idle above `keepCpuIdle` starts as many builders as it fits |
| `rampMin` | 10 | A builder started this many minutes ago or less still counts against the room, because the idle reading has not seen its load yet |
| `minFreeMemGb` | 4 | Free memory (GB) needed to start one more builder: what the kernel reports available (`kern.memorystatus_level`, or `MemAvailable`) less swap in use |
| `rampFreeMemGb` | 8 | Free memory (GB) needed to start more than one builder in a tick, read again before each start after the first; under it, one start a tick |
| `rampMax` | unset | The most starts in one tick. Unset, the room decides |
| `agentMemGb` | 1.5 | Memory (GB) each builder started this tick is charged before the next start (builder trees measure 0.6–1.3 GB) |
| `healingShare` | 0.25 | Share of the ceiling kept for healing (`repair` + `approved-merge`), rounded up: 1 of 4, 2 of 5–8 |
| `healAllAt` | unset | Reds left at which every place heals, counting those waiting and those being healed; once fewer are left, `healingShare` returns. Polish reds (P3, a polish kind, or a polish list) never count. Unset, or not a whole number over 0, is off |
| `processLabel` | `process` | The label of a process fix: it starts first of all, and a hold "for process fixes" still lets it through |
| `polishListFull` | 8 | Unticked items at which a polish list starts on its own while other work can start. Under it, polish starts only when nothing else can |
| `minFreeGb` | 20 | Disk alarm floor |
| `disk.stopBelowGb` · `disk.resumeAtGb` | 30 · 50 | Under `stopBelowGb` free, nothing new starts (a build, a red/green proof) and the auto-clean runs (`scripts/disk-guard.sh`): driver proofs, unused spawn checkouts, idle build folders' installs and caches, the orphan sweep, then stale scratchpad folders over 500 MB. A tree a claim on any host holds, a live process or run is in, or that changed in the last 30 minutes is never touched; when the claims cannot be read, nothing is removed. Starts resume only at `resumeAtGb` |
| `frozenMin` | 20 | A live run whose log has not grown this long is frozen. A driver run's step logs count as growth too (the run record's `progress_paths`) |
| `judges` | 1 | Judgement processes at once |
| `judge.turns` · `judge.budgetUsd` · `judge.compactWindow` | 40 · 5 · 150000 | Each judge's limits |
| `sheet.owner` | unset | The machine (`hostname -s`, compared without case) that keeps the one build order every coordinator works. Unset, no sheet: each machine seeds its own queue as before |
| `sheet.staleMin` | 15 | A sheet older than this starts nothing new on any other machine |
| `sheet.label` · `sheet.title` | `build-sheet` · `Build queue — the shared sheet` | The pinned issue the order is written to |
| `sheet.stopLabels` | `after-launch` | Labels that keep a ticket off the sheet, on top of every label that keeps a ticket from an agent |

**One build order across machines (`coordinator.sheet`).** Two machines that each
own a copy of the work order pick against each other; the order lives in one
shared place. With `sheet.owner` set, the owner's tick writes its startable queue,
in run order, to one pinned issue: who is building what and on which machine
(with the driver's step, which the claim then carries), the numbered order, and
the same order as JSON under `<!-- sheet:v1 … -->`. It writes only when the
content changed, plus a heartbeat every third of `staleMin`, so a quiet tick
costs no call. Every other machine reads that issue once a tick (one REST read,
through the shared backoff, falling back to its last copy while fresh), works
its order in place of seeding its own queue, and skips whatever any host holds:
claims are refs on origin that name their host. A sheet older than `staleMin`,
or none at all, starts nothing new on that machine and the tick says why; it
never falls back to its own order. `scripts/coordinator-sheet.sh show` prints
the sheet as a machine reads it.

**How the coordinator reads a driver run.** It reads one the way it reads any
other run: a run record, the driver's pid as `.child`, `.ended` with its exit code
(0 walked to the hand-off, 20 parked, 2 a configuration refusal), then the
post-exit dev-server stop and the reconcile.
- The driver's own last line (its park or hand-off line) is written to the log as
  the run's `result` line before anything else is appended. That line is the
  verdict the tick records.
- The record names the driver's per-ticket state directory in `progress_paths`.
  The driver prints only between steps while a build step writes there, so a long
  build step is not a frozen run.
- The claim carries the run's `run_id`, so the post-exit stop finds the driver's
  worktree.
- A run's own post-exit reconcile releases its claim even when its driver record
  is fresh.

A spawn that fails or is refused never uses up a place, so one refused entry cannot
hold its class shut. The tick raises a `spawn-failed` event naming the reason, once
per ticket per day.

**What bounds a driver run.**
- **Cost:** `DRIVER_STEP_BUDGET_USD` (set to the run's `CLAIM_BUDGET_USD`) caps
  each model call. The whole run has no single cap; it is bounded by its rounds:
  `DRIVER_MAX_BUILD_TRIES` (5) build attempts and `DRIVER_MAX_REVIEW_ROUNDS` (2)
  review rounds. What a run spent is in
  `$STATE_DIR/driver/<ticket>/state.json` as `.spend`.
- **Time:** model calls have no time limit. `DRIVER_CMD_TIMEOUT` (900 s) bounds
  only the commands the driver runs itself: gates, the red-before-green test runs,
  renders and the push-requires reviews.

**The ceiling follows the machine.** Each tick the ceiling is what is running,
plus as many builders as the spare CPU fits: the median of the recent CPU idle
samples less `keepCpuIdle`,
divided by `agentCpuCores` as a share of the cores — so an idle machine fills in
one tick (Dom, 2026-10-16: "fill all spare room"). Free memory must be at or over
`minFreeMemGb` and the load under the backstop, or nothing starts. A running builder is
never stopped for load. Of that ceiling, healing gets `ceil(ceiling × healingShare)`
places and new work the rest. While both classes have spawnable work each keeps
its share, so a run of red PRs waits its turn instead of stopping new work; a
class with nothing spawnable lends its places to the other, in both directions.
With `healAllAt` set, a tick that counts that many reds left or more (spawnable
reds waiting plus live healing runs, since a red being healed is still left) gives
the whole ceiling to healing, and the split line and `capacity.json` (`healAll`)
say so; once fewer are left the share returns. Polish reds never count toward it:
they are healed in their turn, at their priority, and never stop new building.

**Checks that warn until the release** (owner call 2026-10-21). `release.nonBlockingChecks`
in harness.json lists check names (a run's name, a status context, or
`<workflow> / <job>`, ignoring case); while `release.done` is not true, a red in one
of them is a warning: repair-watch logs it and comments once per head on the pull
request, and nothing repairs it, counts it red or toward heal-all, parks or
fix-rounds on it (the driver's repair, the critic's findings), or waits on it (the
sign-off batch, the merge lane, `pr-watch.sh`). Every check still runs and reports.
`release.done: true`, an empty list or no key is exactly as before. The one switch
is `scripts/release-checks.sh`; every reader of a red asks it.

**Process fixes trump everything** (owner call 2026-10-20). A ticket wearing
`coordinator.processLabel` (default `process`) starts first, in any free place:
ahead of priority, kind order, heal-all, the healing / new split, polish and even an
entry put at the front. The queue, the shared sheet ("Process fixes first: N", each
row "Process fix") and the live view list them at the top. A swarm hold whose
reason says it is "for process fixes" (`install.sh hold "quiet night, for process
fixes"`), or whose file carries an `allow: process` line, lets only those start; a
plain hold holds them too.

**Priority decides, everywhere** (owner call 2026-10-19). The queue runs P0, P1,
P2, P3, then tickets with no priority, across classes: a repair or an approved
merge ranks by its own ticket's priority, read fresh each tick. Within one
priority: repair, approved merge, then new work; within a class, product work
before our own build tooling (`coordinator.toolingLabels`, default
`repo:agent-harness code-health project:ci-throughput project:harness-kit area:OPS
area:HYGIENE area:OPS-CONSOLE`, or a title scope in `coordinator.toolingScopes`,
default `gates ci harness ops pre-push dev`); then new work half-built, feature,
other, polish. An entry put at the front stays first. The healing share still holds;
which red heals first follows priority.

**Polish rides along.** A Minor finding goes on its screen's one polish list
(`scripts/polish-list.sh add <screen-slug> "<text>"`), never a ticket of its own.
A ticket labelled `screen:<slug>` carries that list's unticked items into its plan
and build (`{{POLISH_LIST}}`); the builder fixes them, ticks them, and the PR names
them. Polish new work (P3, a polish kind, a polish list) starts only when nothing
else can, or when a polish list holds `polishListFull` items. Sign-off batches are
ordered by priority too, so polish screens come last.
A reading nobody could take (CPU idle, free memory, load, cores) is no room.
The coordinator records each spawn's class in `run-classes.tsv` beside the queue,
because a spawner (an older install of the kit, or a stand-in) need not
write one; a run with no class anywhere counts as healing when its ticket has an
open PR. The tick log shows
`ceiling: 7 running · room for 1 more: cpu idle 31%, 9 GB free` and
`split: 3 new · 1 healing · 2 reds waiting`, and `capacity.json` beside the queue
holds the same for the live view.

**Starts ramp to the headroom.** After the first start of a tick the room is read
again before each next one: a new CPU sample, never the shared 5-second one, and
the lower of it and the median; the builders started this tick counted against
the fit; and each of them charged `agentMemGb` against free memory, because a
builder started seconds ago has used none of its memory yet. A start that eats the
headroom stops the rest; under `rampFreeMemGb` after the charge, a tick starts one.

**A ticket waiting on the owner is never respawned.** The owner-decision label
(`labels.ownerDecision`, default `needs:owner-decision`) is the one truth for it:
every spawner skips a ticket wearing it. A spawned builder has no question tool;
when only the owner can decide, it runs `scripts/owner-question.sh ask <ticket>
<slug> "<question>"` — the kit hands the rule, with that script's absolute path,
to the builder in `CLAIM_EXTRA`, which a project's own spawn-claim copy appends
too. It labels the ticket, then writes `decision:<ticket>:<slug>` to
`needs-you.md`. A question parks without the sign-off hold. The answer —
`needsme-watch.sh answer <key> "<answer>"`, from the watcher or the board walk —
takes the label off, comments it, and puts the ticket back at the front of the
queue with the answer in its note. A step that fails leaves the answer in
`answers.pending` and the line open, and `owner-question.sh sync` (each live tick,
and each watcher board pass) replays it. An open line whose ticket no longer wears
the label was answered on the ticket: sync ticks it and requeues the ticket.

### The merge lane — one PR into the trunk at a time

A repo without GitHub's merge queue lets every approved PR's auto-merge fire on
its own, so each merge moves the trunk under the next: approved PRs clash or go
red in turn, and two that passed apart can break the trunk together.
`scripts/merge-lane.sh` merges one at a time, and only a head that is up to date
with the trunk and green on every `gates.requiredChecks` check — so the trunk is
always exactly what was tested.

| Step | What the lane does |
|---|---|
| Joins | open, not draft, no hold label, auto-merge armed or the lane label. Live, the label goes on and auto-merge comes off |
| Order | the PR in flight stays head; then the first label (`P0`), then priority (the PR's own P label, else its ticket's; none last), then product before our own tooling, then the oldest approval, then the PR number |
| Behind | `update-branch` against the head it read; a conflict takes it out of the lane with a fixer |
| Checks | waits on pending or missing; a flake (timed out, cancelled, a lost runner) is re-run once; anything else takes it out with the check named and a fixer |
| Green | merged with `merge.method` and `--match-head-commit`; one merge per pass |
| Hold back on | re-cleared through `clear-hold.sh --reason --sha` only when `approval-kept.sh check` keeps it: every commit of the PR's own since approval is a merge (the trunk commits a merge brings do not count) and no screen file in its own diff changed, or the PR's own change to it is the same at both heads; otherwise the owner is told |

A fixer is a `repair` entry in the coordinator's queue, which the tick starts in
a healing place. When no live coordinator has ticked in 15 minutes (it is in
shadow, or not installed) the lane starts the fixer itself if the machine has
room, so a queued fixer is never stranded. The status line is
`$STATE_DIR/coordinator/lane.status`; owner calls land in `needs-you.md`.

```sh
swarm/install.sh merge-lane                     # every 3 minutes; SHADOW unless MERGE_LANE_SHADOW=0
MERGE_LANE_SHADOW=0 swarm/install.sh merge-lane # live
swarm/install.sh uninstall merge-lane
```

The coordinator tick also runs it each pass wherever `merge.method` is set; the
lane's own lock keeps the two from overlapping, and `MERGE_LANE_SHADOW` decides
its mode in both. **Shadow is the default**: it writes "would …" lines to
`actions.log` beside the real merges and touches nothing. A swarm hold stops it.

| Key (under `mergeLane`) | Default | What it is |
|---|---|---|
| `label` | `queue:merge` | Membership that survives auto-merge being turned off. Every pass checks the repo has it; live creates it when missing, shadow logs "would create the lane label" |
| `firstLabel` | `P0` | Owner-flagged PRs that go to the front |
| `flakePattern` | runner-loss wording | Annotation text that makes a failure a flake |

## What it costs

`scripts/usage-report.sh [--since YYYY-MM-DD] [--by ticket|operator|week]` — spend per
spawned run from the records the spawner already leaves (`runs/<id>.json` + the log's
`result` line): ticket, operator, turns, cost, outcome (done / budget / error / died).
Reads records only, never an API. A window writes no run record, so the total is a
floor and the footer says so. `/standup` prints today's line; `/project` shows it per
programme.

## One copy, and it is this one

**The plugin is the only source.** A consuming repo carries no copy of a skill,
agent or hook the plugin ships, and neither does a machine's own `~/.claude`.

This is not tidiness. Claude Code loads from all three places and **does not
deduplicate across them**, so a second copy is a second live version. Measured
2026-09-27 on the estate this kit came from: `/claim` existed three times at
1,268 / 1,118 / 1,052 lines with 474 lines differing between the first two,
`/finish` differed by up to 654 lines across its copies, the review agents had
three and four copies each, and five hooks were registered three times over as
three different versions — firing in order, each one's verdict overwritten by
the next. No agent could say which version it had just run.

Two things keep it that way:

```bash
scripts/check-single-source.sh [<repo>]   # fails when a second copy appears
scripts/retire-duplicates.sh  [--check]   # clears a machine that still carries one
```

`retire-duplicates.sh` **refuses to run before the plugin can take over.** It
compares against the INSTALLED plugin, not the checkout, and stops when that
install does not yet register a hook it is about to remove — otherwise the
machine has no guard at all until the next update. Measured by doing exactly
that on 2026-09-28: ten registrations became one while the running install
registered six of the nine.

**A declared override is not a duplicate.** A project may legitimately shadow a
kit skill — most often because the kit has not extracted that layer yet and the
project's copy carries wiring the kit's does not. It says so in `harness.json`:

```json
"owns": { "skills": ["finish", "claim"], "agents": ["design-critic.md"] }
```

Both this gate and the project's own read that one key, because two gates with
two hardcoded lists is the same defect one level up — they drift, and the one
that drifts low stops failing.

`check-single-source.sh` belongs in a consuming repo's CI. It fails on a repo
copy; it reports a machine copy and only fails on it under `--strict`, because a
repo's CI cannot fix somebody's home directory.

**Precedence, when a copy does exist.** Plugin skills are namespaced, so a repo's
own `.claude/skills/<name>` never collides with the kit's: the repo's is invoked
bare (`/claim`), the kit's is always `/agent-harness:claim`. A per-user
`~/.claude/commands/<name>.md` shadows the same way. That shadow is silent, so
`precedence.sh` prints one line at session start for every kit skill the repo
overrides — a deliberate project override is legitimate; an accidental stale
copy is what the gate above is for.

## Running the tests

```bash
for t in hooks/*.test.sh hooks/lib/*.test.sh scripts/*.test.sh swarm/tests/*.test.sh driver/tests/*.test.sh; do bash "$t"; done
bash scripts/check-project-agnostic.sh
bash scripts/check-push-destination.sh
```

CI runs all of them on every push, and fails by name on a tracked suite no glob
reached — a suite nothing runs reports green by never reporting at all. `check-project-agnostic.sh` reports a control alongside its count — a zero from a strictness probe means clean, suppressed, or never ran, and the control tells you which.

## Not here yet

- The design layer (`/design`, `/critic`, `/flows`, the on-theme reminder hook) still reads its origin repo's kit and law by path. Child 3 of the extraction puts it behind `design.*` in the config. Those five commands are the ones `retire-duplicates.sh` leaves alone and reports rather than moving — the kit ships no copy of them yet, so removing them would lose them.
- The gates contract: `/finish` reads `gates.changed` for the local run, but the rest of the gate shape is still the consuming repo's. Child 4.

## Licence

MIT.

### Telling a status board that claims changed

Set `HARNESS_STATUS_REPO` to a repo that owns a status board, and `claim-lock.sh`
fires a `claim-changed` repository_dispatch at it whenever a claim is taken or
released:

```bash
export HARNESS_STATUS_REPO=owner/status-repo
```

Unset, nothing happens. A board that is down, misconfigured or gone can never
fail a claim — every failure is swallowed.

This exists because a cron cannot stand in for it: measured on the estate this
came from, GitHub delivered 4-7 scheduled runs a day against a request of 48.
