#!/usr/bin/env bash
# stranded.sh — work the driver could not push, kept on origin anyway.
#
# A park whose push the pre-push refused, or a repair whose push is withheld because
# auto-merge is armed, used to leave its commits in a bundle on that machine's disk.
# Neither machine could resume the other's work, and one sweep could lose it (40
# commits sat on one VM for days). So the same commits also go to
#
#   refs/stranded/<ticket>/<host>-<utc>
#
# on origin. Not a branch or a tag: no workflow, branch protection or auto-merge reacts
# to it, and no PR head moves. It is a backup copy, so like the bundle it skips the
# local pre-push. `start` and `reenter` restore from the newest one when origin's
# branch lacks its commits; one older than 14 days is deleted only once its commits
# are on the ticket's branch.
STRANDED_NS=refs/stranded

# driver_stranded_push <ticket> <tree> [rev] — sets DRIVER_STRANDED_REF; on a refusal
# sets DRIVER_STRANDED_WHY and returns 1.
driver_stranded_push() {
  local t="$1" wt="$2" rev="${3:-HEAD}" ref out h
  DRIVER_STRANDED_REF=""; DRIVER_STRANDED_WHY=""
  case "$t" in ''|*[!0-9]*) DRIVER_STRANDED_WHY="ticket '$t' is not a number, so no stranded ref"; return 1 ;; esac
  h=$(hostname -s 2>/dev/null || hostname 2>/dev/null); h=$(printf '%s' "$h" | tr -c 'A-Za-z0-9-' '-' | sed 's/-*$//'); [ -n "$h" ] || h=host
  ref="$STRANDED_NS/$t/$h-$(date -u +%Y%m%dT%H%M%SZ)"
  # Skipping the pre-push reaches nothing outside this namespace.
  case "$ref" in "$STRANDED_NS"/[0-9]*/?*) ;; *) DRIVER_STRANDED_WHY="'$ref' is outside $STRANDED_NS/"; return 1 ;; esac
  if ! out=$(env -u PARK_PUSH git -C "$wt" push --no-verify origin "$rev:$ref" 2>&1); then
    DRIVER_STRANDED_WHY="the push to $ref was refused too: $(printf '%s' "$out" | tail -2 | tr '\n' ' ' | cut -c1-200)"; return 1
  fi
  DRIVER_STRANDED_REF="$ref"
}

# driver_stranded_list <ticket> <repo> — "<sha> <ref>" per stranded ref on origin,
# oldest first by the stamp after the host (the host may itself hold dashes).
driver_stranded_list() {
  git -C "$2" ls-remote origin "$STRANDED_NS/$1/*" 2>/dev/null \
    | awk '{n=split($2, p, "-"); print p[n], $1, $2}' | sort | awk '{print $2, $3}'
}

# driver_stranded_restore <ticket> <repo> <base> — fetch the newest stranded ref and,
# when <base> lacks its commits, set DRIVER_STRANDED_SHA to it (empty when there is
# none or <base> has them). DRIVER_STRANDED_FROM names the ref. 1: it could not be fetched.
driver_stranded_restore() {
  local t="$1" repo="$2" base="$3" line sha ref
  DRIVER_STRANDED_FROM=""; DRIVER_STRANDED_SHA=""
  line=$(driver_stranded_list "$t" "$repo" | tail -1)
  [ -n "$line" ] || return 0
  sha=${line%% *}; ref=${line#* }
  DRIVER_STRANDED_FROM="$ref"
  git -C "$repo" fetch -q origin "+$ref:refs/remotes/origin/${ref#refs/}" 2>/dev/null || return 1
  git -C "$repo" cat-file -e "$sha^{commit}" 2>/dev/null || return 1
  [ -n "$base" ] && git -C "$repo" merge-base --is-ancestor "$sha" "$base" 2>/dev/null && return 0
  DRIVER_STRANDED_SHA="$sha"
}

# driver_stranded_expire <ticket> <repo> <branch> — delete each stranded ref older than
# driver.strandedKeepDays (14) whose commits are on origin/<branch>. Anything else stays.
driver_stranded_expire() {
  local t="$1" repo="$2" branch="$3" days cut now sha ref stamp
  days=$(driver_opt driver.strandedKeepDays 14 2>/dev/null || printf 14)
  case "$days" in ''|*[!0-9]*) days=14 ;; esac
  now=$(date -u +%s); cut=$((now - days * 86400))
  cut=$(date -u -r "$cut" +%Y%m%dT%H%M%SZ 2>/dev/null || date -u -d "@$cut" +%Y%m%dT%H%M%SZ 2>/dev/null) || return 0
  git -C "$repo" rev-parse --verify -q "refs/remotes/origin/$branch" >/dev/null 2>&1 || return 0
  driver_stranded_list "$t" "$repo" | while read -r sha ref; do
    stamp=${ref##*-}
    [[ "$stamp" < "$cut" ]] || continue
    git -C "$repo" cat-file -e "$sha^{commit}" 2>/dev/null \
      || git -C "$repo" fetch -q origin "$ref" 2>/dev/null || continue
    git -C "$repo" merge-base --is-ancestor "$sha" "refs/remotes/origin/$branch" 2>/dev/null || continue
    git -C "$repo" push -q --no-verify origin ":$ref" >/dev/null 2>&1 \
      && driver_say "   stranded: $ref is older than $days days and on $branch — removed from origin"
  done
  return 0
}
