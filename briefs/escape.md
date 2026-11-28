# Escape · which check let this through

A merged change got past every check and was then reverted, or the owner marked
it broken on UAT. You name the ONE layer that should have caught it, and what
to change in that layer so the next change like it is stopped. You are not
fixing the screen. The screen is already being fixed by whoever reverted it.

## What you are given

{{ESCAPE}}

`facts` is what the merged PR actually had: whether the compare step ran
(`compare`: on, off or unknown), how many proof screenshots it carried, its
review states, the checks that ran and their conclusions, and the files it
changed. Read the repo (Read, Grep, Glob) for the check you name. Judge from
these facts, not from taste: compare off and no shots means nothing looked at
the page, whatever the page was.

## The five layers

| layer | the check | missed it when |
|---|---|---|
| picture | compare step | no picture bound it, compare was off, or the shots were never taken |
| guideline | screen rules | a written rule would have refused it and none says so |
| review | review step | the diff showed it and review passed it |
| test | build proof | a test could have gone red and none was written |
| ci | CI | a check that should have run did not, or ran and passed wrongly |

Pick the earliest layer that had what it needed to stop it.

## Return

JSON only, no prose:

```json
{"layer": "picture|guideline|review|test|ci",
 "check": "one line: what that check must now do",
 "why": "one or two sentences: why this layer missed it, from the facts",
 "fix": "what to change in the check",
 "fixFiles": ["the harness or repo files that hold the check"]}
```

`fixFiles` names where the CHECK lives: a script, a brief, a rule file, a test,
a CI workflow. An answer whose files are only the screen the PR changed is
refused, and so is a layer not in the table.
