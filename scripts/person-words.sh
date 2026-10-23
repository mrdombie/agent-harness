# person-words.sh — how a person's comment is read, in one place. Sourced by
# scripts/person-stop.sh (does a person's word stop the work?) and driver/ai-step.sh
# (which answers bind every step?), so the two read the same comment the same way.
#
# PERSON_WORDS_JQ is jq definitions, prepended to a filter:
#   person_opener   the body opens, after whitespace or markdown, with "Cleared:" or
#                   "PM answer": a person's call. It never raises a finding, and it
#                   clears every finding a person named before it.
#   owner_answered  the body opens with the driver's "**The owner answered**" relay.
#   finding_line    a line that GRADES a Critical: "Critical:", "Critical (why):",
#                   "Critical —", "[Critical]", "grade: Critical". Not a count of none
#                   ("0 Critical", "Critical: 0").
#   finding         the body's first finding line, or null; null for an opener.
#
# A GRADE WORD IS NOT A GRADE. On 2026-10-23 a "Cleared: the Critical (…) is fixed"
# and a hold-lift note ending "Only a Critical blocks." each refused a ship as a
# person's blocking finding, because any line naming Critical was read as one.
# shellcheck disable=SC2034
PERSON_WORDS_JQ='
  def person_opener: (. // "") | test("^[\\s#*_]*(Cleared[*_]*\\s*:|PM answer\\b)"; "i");
  def owner_answered: (. // "") | test("^\\s*\\*\\*The owner answered\\*\\*");
  def finding_line:
    ( test("(?<![/\\w])\\[\\s*Critical\\s*\\]")
      or test("(?i)\\bgrade\\**\\s*[:=]\\s*\\**\\s*Critical\\b")
      or test("(?<![/\\w])Critical\\**\\s*(\\([^)\\n]*\\))?\\s*\\**\\s*(:|—|–|\\s-\\s)") )
    and (test("(?i)\\b(0|no|zero|none|any)\\s+\\**Critical") | not)
    and (test("Critical\\**\\s*[:=]\\s*\\**\\s*(0|none)\\b"; "i") | not);
  def finding: (. // "") as $b
    | if ($b | person_opener) then null
      else ([$b | split("\n")[] | select(finding_line)] | first) end;
'
