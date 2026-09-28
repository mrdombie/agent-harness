---
description: Maktura — drain release-notes-buffer.tsv into a draft changelog PR (run weekly).
---

# Release notes — weekly draft

#2182 — Renders the per-ticket buffer rows that `/finish` has accumulated into a markdown patch on `apps/web/src/content/changelog.md`, opens a PR titled `chore(changelog): week ending YYYY-MM-DD`, and drains the buffer to its archive sibling. Human edits the draft before merge — Maktura's voice rules (plain English, "We shipped", outcome-first) live with the reviewer, not in the rendering logic.

## When to run

Weekly, on Sunday — same cadence the parent #2174 spec called for. Also valid to run ad-hoc after a heavy ship day. The skill is idempotent: re-running with an empty buffer is a one-line "nothing to drain" and exits clean.

## Why a skill, not a BullMQ cron

The parent spec proposed a Sunday 18:00 UTC BullMQ scheduler entry. We didn't ship that variant — opening a GitHub PR from Railway requires `GITHUB_TOKEN` + an `@octokit/rest` dependency that nothing else in `apps/api` uses. Adding both for one weekly job didn't justify the ops surface.

The buffer is `~/.claude/socialhub-tickets/release-notes-buffer.tsv` — local to the dev's machine. The dev is already in Claude every time `/finish` runs, so adding one more weekly Claude trigger is consistent with the Maktura workflow's shape. If the cron is genuinely wanted later, the buffer moves to a Postgres table and the worker hooks into the existing api octokit instance.

## Workflow

### Step 0 — Repo guard + check buffer

```bash
BUFFER="$HOME/.claude/socialhub-tickets/release-notes-buffer.tsv"
ARCHIVE="$HOME/.claude/socialhub-tickets/release-notes-buffer.archive.tsv"

test -f "$BUFFER" || { echo "Buffer empty — nothing to draft. Run /finish a few times and try again."; exit 0; }
ROWS=$(wc -l < "$BUFFER" | tr -d ' ')
[ "$ROWS" = "0" ] && { echo "Buffer file exists but is empty. Nothing to draft."; exit 0; }
echo "$ROWS row(s) to drain."
```

### Step 1 — Create a worktree off freshly-fetched develop

```bash
CONFIG="$HOME/.claude/socialhub-tickets/config.json"
test -f "$CONFIG" || { echo "config.json missing — re-run scripts/bootstrap-queue.sh from your maktura clone." >&2; exit 1; }
REPO_PATH=$(jq -r '.repos.maktura // empty' "$CONFIG")
[ -n "$REPO_PATH" ] && [ -d "$REPO_PATH/.git" ] || { echo "config.json has no valid maktura path — re-run scripts/bootstrap-queue.sh." >&2; exit 1; }
TODAY=$(date -u +%Y-%m-%d)
HASH=$(openssl rand -hex 3)
TMP_BASE="${TMPDIR:-/tmp}"; TMP_BASE="${TMP_BASE%/}"
WORKTREE="$TMP_BASE/changelog-draft-${TODAY}-${HASH}"
BRANCH="chore/changelog-${TODAY}"

git -C "$REPO_PATH" fetch origin develop --quiet
git -C "$REPO_PATH" worktree add "$WORKTREE" -b "$BRANCH" origin/develop
cd "$WORKTREE"
```

### Step 2 — Render the buffer into a changelog block

Group rows by `merge-date`, then per-date render the rows under a `## YYYY-MM-DD` heading. Each row becomes one bullet using the buffer's `category` (default `IMPROVED`) and `title`:

```bash
# Emit the markdown to a temp file. Awk groups by date + sorts each
# date desc. Categories map: NEW → New, IMPROVED → Improved, FIXED → Fixed.
DRAFT=$(mktemp)
awk -F'\t' '
  { rows[$2] = rows[$2] $0 "\n" }
  END {
    # Sort dates desc
    n = 0
    for (d in rows) dates[++n] = d
    for (i = 1; i <= n; i++)
      for (j = i + 1; j <= n; j++)
        if (dates[j] > dates[i]) { tmp = dates[i]; dates[i] = dates[j]; dates[j] = tmp }
    for (i = 1; i <= n; i++) {
      print "## " dates[i]
      split(rows[dates[i]], rs, "\n")
      for (k in rs) {
        if (rs[k] == "") continue
        split(rs[k], cols, "\t")
        cat = cols[4]; title = cols[5]
        label = (cat == "NEW") ? "New" : (cat == "FIXED") ? "Fixed" : "Improved"
        printf "- [%s] **%s** — _Draft: rewrite in plain English before merging. Source: %s (PR #%s)._\n", label, title, cols[1], cols[3]
      }
      print ""
    }
  }
' "$BUFFER" > "$DRAFT"

echo "=== draft ==="
cat "$DRAFT"
```

The placeholder body (`Draft: rewrite in plain English ...`) is deliberate — the reviewer rewrites each line in the PR. Auto-paraphrasing the title would produce AI-shaped copy that violates Maktura's voice rules. The draft is a skeleton; the human is the author.

### Step 3 — Splice into the existing changelog.md

The changelog already has dated headings. The draft block goes ABOVE today's existing entries — pre-pended to the file, not appended.

```bash
CHANGELOG="apps/web/src/content/changelog.md"
TMP=$(mktemp)
# Keep the file's header (everything before the first ## YYYY heading), then
# draft, then the existing dated entries.
awk -v draft_file="$DRAFT" '
  BEGIN { drafted = 0 }
  /^## 2[0-9]{3}-/ {
    if (!drafted) {
      while ((getline line < draft_file) > 0) print line
      drafted = 1
    }
  }
  { print }
' "$CHANGELOG" > "$TMP"
mv "$TMP" "$CHANGELOG"
```

### Step 4 — Commit + push + PR

```bash
git add "$CHANGELOG"
git commit -m "chore(changelog): week ending $TODAY (draft from #2182 buffer)"
git push -u origin "$BRANCH" --quiet

PR_BODY=$(cat <<BODY
## What

Auto-drafted by \`/release-notes-draft\` from the \`/finish\` buffer. **Every line is a placeholder** — rewrite in plain English per the brand-guide voice rules before merging:

- Outcome-first ("Library loads faster", not "we added a thumbnail index")
- "We shipped" not "feature was deployed"
- No \`#NNNN\` ticket refs in the user-facing copy
- Category audit: bump entries from \`[Improved]\` to \`[New]\` where it's an entirely new surface; to \`[Fixed]\` where it's a bug fix

## Tickets drained from the buffer

$(awk -F'\t' '{printf "- %s — PR #%s — %s\n", $1, $3, $5}' "$BUFFER")
BODY
)
gh pr create --repo mrdombie/maktura --base develop \
  --title "chore(changelog): week ending $TODAY" \
  --body "$PR_BODY" \
  --label "area:HYGIENE,type:chore"
```

### Step 5 — Drain the buffer to the archive

The PR is now open and the buffer rows are accounted for; archive them so the next run starts empty.

```bash
cat "$BUFFER" >> "$ARCHIVE"
: > "$BUFFER"
echo "Buffer drained ($ROWS rows) to release-notes-buffer.archive.tsv"
```

### Step 6 — Clean up the worktree

```bash
: "${REPO_PATH:?REPO_PATH unset — run Step 1 resolution block first}"
cd "$REPO_PATH"
git worktree remove --force "$WORKTREE"
```

### Step 7 — Report

Tell the user: PR URL + line count drafted + reminder that the copy needs the human-rewrite pass.

## What you don't do

- Don't merge the PR — human review is the entire gate. The draft is intentionally low-quality so the reviewer is forced to read every line.
- Don't write the per-entry body for the reviewer — auto-paraphrasing the ticket title makes AI-shaped copy. Leave it as the placeholder.
- Don't run multiple times in a row — the buffer drain happens at Step 5, so a second run would draft nothing. The skill exits cleanly when the buffer is empty.
- Don't modify the archive — it's the audit trail.

## If something breaks

- `gh pr create` fails with conflicts → the changelog has been edited on develop since the last branch refresh; `git worktree remove` + rerun.
- The draft renders empty despite a non-empty buffer → check the awk parser; the buffer may have malformed TSV rows from a failed `/finish` call. Manually inspect + fix the file, then rerun.
- The buffer file is missing → no `/finish` has run since the last drain. Nothing to do.
