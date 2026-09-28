---
name: repo-wide-format
enabled: true
event: bash
conditions:
  - field: command
    operator: regex_match
    pattern: npm\s+run\s+format(\s|$)
  - field: command
    operator: not_contains
    pattern: --
---

🛑 **Never run a repo-wide format.**

`prettier --check "apps/**"` on `origin/develop` reports **260 unformatted files**. Formatting
them all is a 260-file churn commit that collides with every open branch and buries your actual
diff.

**Format only what you touched:**

```bash
git diff --name-only --diff-filter=ACMR origin/develop...HEAD -- '*.ts' '*.tsx' \
  | xargs npx prettier --write
```

Files unformatted on develop and **untouched by your branch are not yours to fix**. Leave them.
