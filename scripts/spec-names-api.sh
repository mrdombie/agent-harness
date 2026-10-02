#!/usr/bin/env bash
# spec-names-api.sh < ticket-body — exit 0 when the body names an API route the
# UI depends on, 1 when it names none.
#
# A route, not a heading: "## Backend contract" is required on every screen
# ticket by /claim, including the ones whose contract is "None", so the heading
# says nothing about whether an API exists. A contract that lists endpoints
# names their routes (/api/...) or their source (apps/api/...); one that does
# not, names none. Prose words like "endpoint" decide nothing either.
grep -qE '(^|[^A-Za-z0-9_])(/api/|apps/api/)'
