# Which of $names does this settings.json register?
#
# A hook name is a PATH COMPONENT, not a substring: matching `keep-working.sh`
# anywhere in the command string also matches a machine's own
# `my-keep-working.sh`, which then gets silently un-registered and reported
# under the plugin's name. Split on "/" and compare the first token of each
# part — no regex, so there is nothing to escape and an escaping slip cannot
# quietly match nothing.
def parts($c): $c | split("/") | map(split(" ")[0] | split("\"")[0] | split("'")[0]);
[ .hooks // {} | .[][].hooks[].command ]
| map(parts(.)) | flatten
| map(select(. as $p | $names | index($p) != null))
| unique | .[]
