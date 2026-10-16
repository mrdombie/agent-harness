## Lesson
<!--
Owed on a fix: a bug label, a repair or approved-merge spawn, a fix: title or fix/
branch, or a pull request that closes or references a bug. The `Every fix ships a lesson` check reads this section; text inside
this comment does not count, so write the lines below it.

- Principle: one sentence naming the CLASS of mistake, readable by someone who never
  saw the bug. Not the instance ("a missing reading never counts as safe to go", not
  "the CPU sampler returned null").
- Guard: the test, lint rule or gate file this pull request adds or changes in
  substance that enforces the principle, as a path in backticks. A doc, a workflow,
  a whitespace edit or a rename is not a guard.
- Before/after: how you saw the guard fail on the pre-fix code and pass on the fix.
- Reach: the sibling it also catches, or the search that shows there are none.

Only when no machine check can hold it, replace the Guard with one line of at
least eight words:
Not automatable because <the reason>
and put the principle in the project's rules file. Those are counted.

On a pull request that is not a fix, delete this section.
-->
- Principle:
- Guard: ``
- Before/after:
- Reach:
