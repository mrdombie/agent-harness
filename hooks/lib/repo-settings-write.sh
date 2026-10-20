#!/usr/bin/env bash
# repo-settings-write.sh — is this command a write to the repository's settings?
#
#   . hooks/lib/repo-settings-write.sh; repo_settings_write "<one command>"  # 0 = it is
#   bash hooks/lib/repo-settings-write.sh gh <args…>                        # same, from argv
#
# Builders change code through pull requests, never the repo's settings: a driver
# build added a required check to the live develop ruleset with `gh api` from inside
# a build step, and every open PR's mergeability changed with nobody deciding it.
# Settings are rulesets, branch protection, required checks, collaborators, webhooks,
# secrets and variables, environments, the repo record itself, and anything under an
# org. Reads stay allowed. Shared by the PreToolUse hook (prose runs) and the driver
# step's gh shim, so the two cannot disagree.

_rsw_settings_path() { # <normalised api path>
  printf '%s' "$1" | grep -qE '^orgs/|^repos/[^/]+/[^/]+/?$|^repos/[^/]+/[^/]+/(rulesets|rules|branches/.+/protection|actions/permissions|actions/secrets|actions/variables|dependabot/secrets|collaborators|hooks|environments|keys|teams|topics|pages|transfer|vulnerability-alerts|automated-security-fixes|private-vulnerability-reporting)(/|$)'
}

# repo_settings_write <command text> — 0 when it writes repository settings.
repo_settings_write() {
  local s="$1" toks t i n method="" path="" fields=0 sub2
  # The command word must be gh itself (after any VAR=x prefixes): the same words
  # quoted inside an echo or a brief are not a call.
  s=$(printf '%s' "$s" | sed -E 's/^[[:space:]]*(\(|\$\(|`)?[[:space:]]*//; s/^([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+)*//; s/^(command|exec|env)[[:space:]]+//')
  printf '%s' "$s" | grep -qE '^([^[:space:]]*/)?gh[[:space:]]' || return 1
  read -r -a toks <<<"$(printf '%s' "$s" | tr -d "\"'")"
  n=${#toks[@]}
  sub2="${toks[1]:-} ${toks[2]:-}"
  case "$sub2" in
    "repo edit"*|"repo rename"*|"repo archive"*|"repo unarchive"*|"repo delete"*|"secret set"*|"secret delete"*|"variable set"*|"variable delete"*|"ruleset create"*|"ruleset edit"*|"ruleset delete"*) return 0 ;;
  esac
  [ "${toks[1]:-}" = api ] || return 1
  i=2
  while [ "$i" -lt "$n" ]; do
    t="${toks[$i]}"
    case "$t" in
      -X|--method) i=$((i+1)); method="${toks[$i]:-}" ;;
      -X*) method="${t#-X}" ;;
      --method=*) method="${t#--method=}" ;;
      -f|-F|--field|--raw-field|--input) fields=1; i=$((i+1)) ;;
      -f*|-F*|--field=*|--raw-field=*|--input=*) fields=1 ;;
      -H|--header|-q|--jq|-t|--template|--hostname|--cache|-p|--preview) i=$((i+1)) ;;
      -*) ;;
      *) [ -n "$path" ] || path="$t" ;;
    esac
    i=$((i+1))
  done
  method=$(printf '%s' "$method" | tr '[:lower:]' '[:upper:]')
  [ -n "$method" ] || { [ "$fields" = 1 ] && method=POST || method=GET; }
  path=$(printf '%s' "$path" | sed -E 's#^https?://[^/]+/##; s#^/+##; s#\?.*$##')
  if [ "$path" = graphql ]; then
    printf '%s' "$1" | grep -qE 'mutation' \
      && printf '%s' "$1" | grep -qiE '(create|update|delete)(BranchProtectionRule|RepositoryRuleset)|updateRepository|archiveRepository|transferRepository|(add|remove|update)(Collaborator|Webhook)' \
      && return 0
    return 1
  fi
  case "$method" in POST|PUT|PATCH|DELETE) ;; *) return 1 ;; esac
  _rsw_settings_path "$path"
}

REPO_SETTINGS_WRITE_REASON="A build changes code through its pull request, never the repository's settings (rulesets, branch protection, required checks, collaborators, webhooks, secrets, the repo or org record). Do not make this change: write the exact command under '## After merge (PM step)' in the PR body and as a comment on the ticket, and the PM makes it after the merge. Reading settings is fine."

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  [ $# -gt 0 ] || { echo "usage: repo-settings-write.sh gh <args…>" >&2; exit 2; }
  repo_settings_write "$*"
fi
