#!/usr/bin/env bash
# Self-test for lib/command-words.sh: the command word a segment really runs.
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/tests/lib/suite.sh" || exit 1
. "$(dirname "$0")/command-words.sh"; fail=0
# <want words joined by |, or "none"> <segment>
t(){ want=$1; got=none
  command_words "$2" && got=$(IFS='|'; printf '%s' "${CMD_WORDS[*]}")
  mark=OK; [ "$got" = "$want" ] || { mark=MISMATCH; fail=1; }
  printf '%-8s want=%-28s got=%-28s %s\n' "$mark" "$want" "$got" "$2"; }
t 'git|push|origin|HEAD:uat'   'git push origin HEAD:uat'
t 'git|push|origin|HEAD:uat'   'ALLOW_TRUNK_PUSH=uat git push origin HEAD:uat'
t 'git|push'                   'A=1 B="two words" git push'
t 'git|push'                   'env ALLOW_TRUNK_PUSH=uat git push'
t 'git|push'                   'env -i -u GIT_DIR -- X=1 git push'
t '/usr/bin/git|push'          'command /usr/bin/git push'
t 'git|-C|/a b|push'           'sudo -u bob env Y=2 git -C "/a b" push'
t 'git|push'                   '$(git push'
t 'git|push'                   '( X=1 git push'
t 'echo|X=1 git push'          'echo "X=1 git push"'
t 'gh|api|-f|q=a b'            "gh api -f q='a b'"
t none                         'X=1'
t none                         '   '
# The regex form agrees on what precedes the command word.
r(){ want=$1; got=no; printf '%s' "$2" | grep -qE "^${CMD_PREFIX_ERE}git[[:space:]]+push" && got=yes
  mark=OK; [ "$got" = "$want" ] || { mark=MISMATCH; fail=1; }
  printf '%-8s regex want=%-3s got=%-3s %s\n' "$mark" "$want" "$got" "$2"; }
r yes 'git push'
r yes 'ALLOW_TRUNK_PUSH=uat git push'
r yes 'A="two words" B='"'"'x y'"'"' git push'
r yes 'env -u GIT_DIR X=1 git push'
r yes 'command /usr/bin/git push'
r no  'echo git push'
r no  'X=1 echo git push'
suite_end "$fail"
