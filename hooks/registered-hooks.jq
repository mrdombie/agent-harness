# The path-component rule, used by BOTH the report and the rewrite.
#
#   `jq --argjson names '[...]' -f registered-hooks.jq settings.json`   -> names registered
#   `jq --argjson names '[...]' --arg mode strip -f … settings.json`    -> settings.json with them gone
#
# ONE FILE, because the report and the rewrite disagreeing is worse than either
# being wrong: the command says "un-registered N" and nothing was removed. That
# happened — the rewrite carried its own inlined copy of this rule.
#
# A hook name is a PATH COMPONENT, not a substring. Matching `keep-working.sh`
# anywhere in the command also matches a machine's own `my-keep-working.sh`,
# which then gets silently un-registered and reported under the plugin's name.
# Split on the shell separators as well as "/" — `hooks/x.sh; echo done` yields
# the token `x.sh;` and matched nothing.
# Quotes are stripped from anywhere in the token, not just the front: a token
# can end in one (`bash -c "…/keep-working.sh"`) as easily as begin with one.
def parts($c):
  $c | [splits("[/ \t;&|<>()]")] | map(gsub("[\"']"; "")) | map(select(length > 0));
def owns($c): parts($c) | any(. as $p | $names | index($p) != null);

# $ARGS.named, not $mode: an undefined $mode is a jq COMPILE error, and the
# detection call site sends stderr to /dev/null — so a missing --arg read as
# "this settings.json registers nothing", which is the silently-inert answer.
if ($ARGS.named.mode // "") == "strip" then
  .hooks |= (
    with_entries(
      .value |= ( map(.hooks |= map(select(owns(.command) | not)))
                | map(select((.hooks | length) > 0)) )
    ) | with_entries(select((.value | length) > 0))
  )
else
  [ .hooks // {} | .[][].hooks[].command ] | map(parts(.)) | flatten
  | map(select(. as $p | $names | index($p) != null)) | unique | .[]
end
