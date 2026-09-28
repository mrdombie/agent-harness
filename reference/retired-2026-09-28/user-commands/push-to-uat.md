---
description: Maktura — MANUAL OVERRIDE to promote develop's current state to UAT by fast-forwarding the `uat` branch (normal promotion is the automated review gate). Watches the deploy and smoke-tests health endpoints.
---

You are a Maktura dev agent promoting whatever's currently on `develop` to UAT.

**This is the MANUAL OVERRIDE path.** Normal `develop → uat` promotion is owned by the automated review gate ([`docs/operations/automated-code-review.md`](../../docs/operations/automated-code-review.md)), which reviews newly-merged commits in batches and promotes the passing ones on its own cadence. Use `/push-to-uat` only when a human needs to promote *now* — e.g. an urgent demo before the gate's next cycle. `/finish` does **not** promote to UAT.

## How UAT updates work

UAT is `socialhub-uat.up.railway.app`. All three Railway services (web, api, worker) auto-deploy from the **`uat` branch** (NOT `develop`). `/finish` lands work on `develop`; the review gate (or this manual override) is what advances `uat`.

The mechanism is a fast-forward: `uat` is reset to develop's HEAD when /push-to-uat fires. Multiple `/finish` merges accumulate on develop and ship together on the next promote — normally gate-driven, or via this override.

Dispatching `promote-uat.yml` right after a merge defers (green, no promotion) until the develop-tip `Typecheck + Unit tests` run (~17 min) has a verdict — `gh run list --branch develop` and wait, or fast-forward here.

If Railway is still configured to watch `develop` directly (i.e. SH-163's old setup), tell the user the branch needs to be switched in the Railway dashboard for web/api/worker — and that until they switch, every `/finish` merge will already have hit UAT. Don't proceed silently.

## Repo guard (run first)

```bash
git remote get-url origin 2>/dev/null | grep -q "mrdombie/maktura" || { echo "Not in the Maktura repo. cd into your maktura clone (path in ~/.claude/socialhub-tickets/config.json under .repos.maktura) first."; exit 1; }
```

## Workflow

### 1. Confirm the working tree is clean

```bash
git status --porcelain
```

If there are uncommitted changes, stop and tell the user. Don't promote with dirty work in the tree.

### 2. Sync develop + uat

```bash
git fetch origin develop uat 2>&1 | tail -5
DEVELOP_SHA=$(git rev-parse origin/develop)
UAT_SHA=$(git rev-parse origin/uat 2>/dev/null || echo "<no-uat-branch>")
echo "develop is at $DEVELOP_SHA"
echo "uat is at     $UAT_SHA"
```

If `origin/uat` doesn't exist yet, this is first-run after the Railway switch. Create it from develop:

```bash
git push origin "origin/develop:refs/heads/uat"
```

Then continue.

### 3. Show what's about to ship

The diff between `uat` and `develop` is what UAT is about to gain:

```bash
echo "=== Commits landing on UAT ==="
git log --oneline "$UAT_SHA..$DEVELOP_SHA"
echo ""
echo "=== Files changed ==="
git diff --stat "$UAT_SHA..$DEVELOP_SHA" | tail -20
echo ""
echo "=== Migrations in this batch (if any) ==="
git diff --name-only "$UAT_SHA..$DEVELOP_SHA" | grep '^prisma/migrations/' || echo "(none)"
```

If there are no commits between uat and develop, tell the user: *"UAT is already on develop's HEAD. Nothing to promote."* Skip to step 6 (smoke-test) so they get a health check anyway.

If there are migrations in the batch, surface them prominently — Railway will run them on deploy and a broken migration will leave UAT in a half-deployed state.

### 4. Confirm and promote

Ask the user explicitly:
> *"Ready to promote N commit(s) on develop to UAT? [list summary above]"*

Wait for affirmative confirmation (yes / ship it / confirmed). Anything else, stop.

On confirmation, fast-forward `uat` to develop's HEAD:

```bash
git push origin "origin/develop:refs/heads/uat"
```

This is a fast-forward push (no `-f`). It fails if `uat` has commits develop doesn't. That should be impossible under the documented flow — if it fails, stop and surface to the user. They likely have a hot-fix on `uat` that needs to be cherry-picked back to develop first.

### 5. Watch the deploy

Railway sees the `uat` branch tip move and triggers a deploy on each service. Show the user the latest build status:

```bash
echo "=== Web ===" && railway logs --service web --build 2>&1 | tail -5
echo "=== API ===" && railway logs --service api --build 2>&1 | tail -5
echo "=== Worker ===" && railway logs --service worker --build 2>&1 | tail -5
```

If `railway` CLI isn't authenticated, tell the user to run `railway login` and skip ahead to the smoke-test (it'll catch failures even without log access).

### 6. Smoke-test UAT health endpoints

Wait up to 5 minutes for the deploy to land, polling every 30s. Stop early if all are 200.

```bash
for i in 1 2 3 4 5 6 7 8 9 10; do
  WEB=$(curl -s -o /dev/null -w "%{http_code}" https://socialhub-uat.up.railway.app/api/health)
  WORKER=$(curl -s -o /dev/null -w "%{http_code}" https://socialhub-uat.up.railway.app/api/health/worker)
  echo "Attempt $i: web=$WEB worker=$WORKER"
  if [ "$WEB" = "200" ] && [ "$WORKER" = "200" ]; then
    echo "✅ UAT healthy"
    break
  fi
  sleep 30
done
```

If after 5 minutes either is non-200, tell the user which service is unhealthy and link them to:

```
railway logs --service web | tail -50
railway logs --service api | tail -50
railway logs --service worker | tail -50
```

### 7. Report

Report ONE line:

- ✅ `Promoted develop@<sha7> to UAT — web/worker 200 — N commit(s) shipped`
- ⚠️ `Promoted develop@<sha7> to UAT but worker heartbeat is 503 — check railway logs --service worker`
- ⏭️ `UAT already on develop's HEAD — nothing to promote — health 200`
- ❌ `Promote failed — <reason>` (didn't ship)

For the success case, also list (in 1-2 lines) the SH-NNN tickets that just shipped — pulled from the commit subjects in step 3.

## If UAT goes red after a promote

If health returns non-200 after a promote, the user's options:

1. **Roll UAT back to its previous SHA**:
   ```bash
   git push origin "$UAT_SHA:refs/heads/uat" --force-with-lease
   ```
   This force-pushes uat back to its prior tip. Railway redeploys to that. Use only if you saved `$UAT_SHA` from step 2 (which the workflow does).

2. **Revert the bad commit on develop**, then re-promote: `git revert <bad-sha> && git push origin develop`, then re-run /push-to-uat. UAT moves forward to a healthy state.

3. **Hot-fix forward** if the issue is small.

Use `--force-with-lease` not `-f` so we don't trample concurrent pushes.

## Don't

- Don't merge a still-open PR from this command. That's `/finish`'s job. If the user's on a feature branch and wants to ship, route them to `/finish` first.
- Don't run a database migration without surfacing it. If the develop→uat diff includes `prisma/migrations/`, flag it in step 3 and again in step 4's confirm.
- Don't redeploy a service manually unless the auto-deploy didn't fire (>3 min after push with no build log). If you need to: `railway redeploy --service <name>` and tell the user.
- Don't touch production. UAT only.
- Don't `--force-push` uat unless rolling back per the recovery section above.
