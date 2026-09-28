# prompt-schema.jq — the contract, relaxed into the shape a model can be BOUND to.
#
#   jq -f driver/prompt-schema.jq briefs/schemas/<step>.json
#
# `claude -p --json-schema` passes the schema to the API as a tool input schema,
# and that path refuses keywords a draft-07 validator is fine with. Measured
# 2026-09-28 against briefs/schemas/plan.json:
#
#   allOf at the top level  ->  API Error 400 "input_schema does not support
#                               oneOf, allOf, or anyOf at the top level"
#
# So the schema sent to the model is DERIVED from the contract by this filter and
# never written by hand. That is the whole point: a second schema maintained beside
# the first is a check and the thing it checks derived from different inputs, which
# is the defect class this ticket exists to close. What the filter drops, the
# validator still enforces after the answer comes back — briefs/validate.sh reads
# the unrelaxed contract, so nothing is weakened, only unsaid up front.
#
# It is SCHEMA-AWARE and not a key sweep. A blanket `with_entries` also deleted the
# `title` PROPERTY of a plan task, and the model then answered: "I'm unable to
# complete this request due to a schema bug — the schema requires the title
# property" and returned nothing. Keywords are dropped only where a keyword can
# appear; a `properties` map's keys are names and are never touched.

def drop: ["allOf","anyOf","oneOf","not","if","then","else",
           "minItems","maxItems","minLength","maxLength","pattern",
           "minimum","maximum","exclusiveMinimum","exclusiveMaximum",
           "multipleOf","minProperties","maxProperties","$schema","$comment"];
def relax:
  if type != "object" then .
  else
    with_entries(select(.key | IN(drop[]) | not))
    | (if has("properties") then .properties |= with_entries(.value |= relax) else . end)
    | (if has("items") then .items |= (if type=="array" then map(relax) else relax end) else . end)
    | (if (has("additionalProperties") and (.additionalProperties|type)=="object")
       then .additionalProperties |= relax else . end)
    | (if has("definitions") then .definitions |= with_entries(.value |= relax) else . end)
    | (if has("$defs") then ."$defs" |= with_entries(.value |= relax) else . end)
  end;
relax
