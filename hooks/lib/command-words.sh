#!/usr/bin/env bash
# command-words.sh — the command a shell segment actually runs, for write-time hooks.
#
#   . hooks/lib/command-words.sh
#   cmd_segments "<command text>"   one segment per line (split on newlines, ; && || |)
#   command_words "<one segment>"   sets CMD_WORDS to the words of the command it runs;
#                                   returns 1 when there is none
#   command_text "<one segment>"    the segment with the same prefix removed, as text
#   CMD_PREFIX_ERE                  the same prefix as an ERE, for hooks that match
#                                   whole command text with a regex
#
# The prefix is what the shell runs before the command word: VAR=value settings,
# the wrappers env (its -i/-u NAME options and settings), command, exec, nohup,
# time and sudo, and an opening ( { $( or backtick. `ALLOW_TRUNK_PUSH=uat git push`
# is a git push; a guard that read the first word saw a setting and let it through.
# Words are split the way the shell splits them: quotes group and are removed.

cmd_segments() { # <command text>
  printf '%s\n' "$1" | sed -E 's/(&&|\|\||;|\|)/\n/g'
}

# _cw_split <text> — CMD_WORDS = the shell words of <text>, quotes removed.
_cw_split() {
  local s=$1 n=${#1} i=0 c q="" w="" have=0
  CMD_WORDS=()
  while [ "$i" -lt "$n" ]; do
    c=${s:$i:1}; i=$((i + 1))
    if [ -n "$q" ]; then
      if [ "$c" = "$q" ]; then q=""
      elif [ "$q" = '"' ] && [ "$c" = '\' ] && [ "$i" -lt "$n" ]; then w+=${s:$i:1}; i=$((i + 1))
      else w+=$c; fi
      continue
    fi
    case "$c" in
      "'" | '"') q=$c; have=1 ;;
      '\') [ "$i" -lt "$n" ] && { w+=${s:$i:1}; i=$((i + 1)); }; have=1 ;;
      ' ' | $'\t') [ "$have" = 1 ] && CMD_WORDS+=("$w"); w=""; have=0 ;;
      *) w+=$c; have=1 ;;
    esac
  done
  [ "$have" = 1 ] && CMD_WORDS+=("$w")
  return 0
}

# _cw_prefix_len — _CW_K = how many leading CMD_WORDS are prefix, not the command.
_cw_prefix_len() {
  local k=0 n=${#CMD_WORDS[@]} w
  while [ "$k" -lt "$n" ]; do
    w=${CMD_WORDS[$k]}
    if [[ $w =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; then k=$((k + 1)); continue; fi
    case "$w" in
      '(' | '{' | '$(' | '`' | '!' | command | exec | nohup | time) k=$((k + 1)) ;;
      env)
        k=$((k + 1))
        while [ "$k" -lt "$n" ]; do
          case "${CMD_WORDS[$k]}" in
            -u | --unset | -C | --chdir | -S | --split-string) k=$((k + 2)) ;;
            --) k=$((k + 1)); break ;;
            -*) k=$((k + 1)) ;;
            *) break ;;
          esac
        done ;;
      sudo)
        k=$((k + 1))
        while [ "$k" -lt "$n" ]; do
          case "${CMD_WORDS[$k]}" in
            -u | -g | -h | -p | -C | -D | -U) k=$((k + 2)) ;;
            --) k=$((k + 1)); break ;;
            -*) k=$((k + 1)) ;;
            *) break ;;
          esac
        done ;;
      *) break ;;
    esac
  done
  _CW_K=$k
}

command_words() { # <one segment>
  _cw_split "$1"
  [ "${#CMD_WORDS[@]}" -gt 0 ] || return 1
  _cw_prefix_len
  [ "$_CW_K" -lt "${#CMD_WORDS[@]}" ] || { CMD_WORDS=(); return 1; }
  CMD_WORDS=("${CMD_WORDS[@]:$_CW_K}")
  # An opener glued to the command word: `(git push`, `$(git push`, `` `git push ``.
  while :; do
    case "${CMD_WORDS[0]:-}" in
      '$('?*) CMD_WORDS[0]=${CMD_WORDS[0]#\$\(} ;;
      '('?* | '{'?* | '`'?*) CMD_WORDS[0]=${CMD_WORDS[0]:1} ;;
      *) break ;;
    esac
  done
  [ "${#CMD_WORDS[@]}" -gt 0 ] && [ -n "${CMD_WORDS[0]}" ]
}

command_text() { # <one segment>
  command_words "$1" || return 1
  printf '%s' "${CMD_WORDS[*]}"
}

# command_is <name> — the command word, path stripped, is <name>.
command_is() { [ "${CMD_WORDS[0]##*/}" = "$1" ]; }

_cw_S='[[:space:]]'
_cw_word="([^;&|[:space:]\"']|\"[^\"]*\"|'[^']*')"
CMD_PREFIX_ERE="(([A-Za-z_][A-Za-z0-9_]*=${_cw_word}*|env(${_cw_S}+(-[uCS]${_cw_S}+[^;&|[:space:]]+|-[^;&|[:space:]]*|[A-Za-z_][A-Za-z0-9_]*=${_cw_word}*))*|sudo(${_cw_S}+-[^;&|[:space:]]*)*|command|exec|nohup|time)${_cw_S}+)*([^;&|[:space:]]*/)?"
