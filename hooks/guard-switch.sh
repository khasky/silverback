#!/usr/bin/env bash
# UserPromptSubmit hook behind /silverback:guard: turns the guard's prompts
# (push, recursive delete, history rewrite, protected files) off or on and
# sets the verification check at the end of a turn to on, observe or off. It
# answers the command itself and blocks the prompt, so no model turn runs and
# the agent never writes the switch file. Any other prompt passes untouched, a
# bare /guard included: that name may belong to another plugin.
set -euo pipefail

payload=$(cat)
prompt=$(printf '%s' "$payload" |
  grep -oE '"prompt"[[:space:]]*:[[:space:]]*"([^"\\]|\\.)*"' |
  head -n 1 |
  sed -E 's/^"prompt"[[:space:]]*:[[:space:]]*"//; s/"$//; s/\\[nrt]/ /g') || true

# Typed as text the command arrives as is; an interactive session can wrap it
# as <command-name>/silverback:guard</command-name><command-args>push off</command-args>.
envelope='<command-name>[[:space:]]*/silverback:guard[[:space:]]*</command-name>'
envelope_args='<command-args>([^<]*)</command-args>'
literal='^[[:space:]]*/silverback:guard([[:space:]]+(.*))?$'
args=''
if [[ $prompt =~ $envelope ]]; then
  if [[ $prompt =~ $envelope_args ]]; then
    args=${BASH_REMATCH[1]}
  fi
elif [[ $prompt =~ $literal ]]; then
  args=${BASH_REMATCH[2]}
else
  exit 0
fi

switch_file="$HOME/.silverback/guard"
switches='push delete history files verify'
# A switch is on unless the file holds name=<state>.
state() {
  local line
  line=$(grep -E "^$1=" "$switch_file" 2>/dev/null | tail -n 1) || true
  if [ -n "$line" ]; then echo "${line#*=}"; else echo on; fi
}

label() {
  case $1 in
    push) echo 'push prompt' ;;
    delete) echo 'recursive-delete prompt' ;;
    history) echo 'history-rewrite prompt' ;;
    files) echo 'protected-file prompt' ;;
    verify) echo 'verification check' ;;
  esac
}
# One line per switch: its state and the command that changes it.
line() {
  local now flip
  now=$(state "$1")
  if [ "$1" = verify ]; then
    flip='on|observe|off'
  elif [ "$now" = on ]; then flip=off; else flip=on; fi
  printf '%s: %s (/silverback:guard %s %s)' "$(label "$1")" "$now" "$1" "$flip"
}

read -r -a words <<< "$(printf '%s' "$args" | tr '[:upper:]' '[:lower:]')"
set -- ${words[@]+"${words[@]}"}
title='silverback guard:'
if [ $# -eq 2 ] && { { [[ $1 =~ ^(push|delete|history|files)$ ]] && [[ $2 =~ ^(on|off)$ ]]; } ||
  { [ "$1" = verify ] && [[ $2 =~ ^(on|observe|off)$ ]]; }; }; then
  if [ "$(state "$1")" = "$2" ]; then
    title="$title $(label "$1") is already $2."
  else
    mkdir -p "${switch_file%/*}"
    others=$(grep -vE "^$1=" "$switch_file" 2>/dev/null) || true
    {
      if [ -n "$others" ]; then printf '%s\n' "$others"; fi
      if [ "$2" != on ]; then printf '%s=%s\n' "$1" "$2"; fi
    } > "$switch_file.tmp"
    mv -f "$switch_file.tmp" "$switch_file"
    title="$title $(label "$1") turned $2."
  fi
elif [ $# -ne 0 ]; then
  title="$title usage: /silverback:guard [push|delete|history|files] [on|off], /silverback:guard verify [on|observe|off]."
fi

reason=$title
for name in $switches; do reason="$reason\\n$(line "$name")"; done
printf '{"decision":"block","reason":"%s"}\n' "$reason"
exit 0
