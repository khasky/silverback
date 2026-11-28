#!/usr/bin/env bash
# UserPromptSubmit hook behind /silverback:guard and /silverback:rules. The
# first turns the guard's prompts (push, recursive delete, history rewrite,
# protected files) off or on and sets the verification check at the end of a
# turn to on, observe or off; the second turns the ruleset the plugin's hooks
# put in context off or on, leaving every guard as it is. It answers the
# command itself and blocks the prompt, so no model turn runs and the agent
# never writes the switch file. Any other prompt passes untouched, a bare
# /guard or /rules included: that name may belong to another plugin.
set -euo pipefail

payload=$(cat)
prompt=$(printf '%s' "$payload" |
  grep -oE '"prompt"[[:space:]]*:[[:space:]]*"([^"\\]|\\.)*"' |
  head -n 1 |
  sed -E 's/^"prompt"[[:space:]]*:[[:space:]]*"//; s/"$//; s/\\[nrt]/ /g') || true

# Typed as text the command arrives as is; an interactive session can wrap it
# as <command-name>/silverback:guard</command-name><command-args>push off</command-args>.
envelope='<command-name>[[:space:]]*/silverback:(guard|rules)[[:space:]]*</command-name>'
envelope_args='<command-args>([^<]*)</command-args>'
literal='^[[:space:]]*/silverback:(guard|rules)([[:space:]]+(.*))?$'
args=''
if [[ $prompt =~ $envelope ]]; then
  command=${BASH_REMATCH[1]}
  if [[ $prompt =~ $envelope_args ]]; then
    args=${BASH_REMATCH[1]}
  fi
elif [[ $prompt =~ $literal ]]; then
  command=${BASH_REMATCH[1]}
  args=${BASH_REMATCH[3]}
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
    rules) echo 'ruleset' ;;
  esac
}
# One line per switch: its state and the command that changes it.
line() {
  local now flip
  now=$(state "$1")
  if [ "$1" = verify ]; then
    flip='on|observe|off'
  elif [ "$now" = on ]; then flip=off; else flip=on; fi
  if [ "$1" = rules ]; then
    printf '%s: %s (/silverback:rules %s)' "$(label "$1")" "$now" "$flip"
  else
    printf '%s: %s (/silverback:guard %s %s)' "$(label "$1")" "$now" "$1" "$flip"
  fi
}

read -r -a words <<< "$(printf '%s' "$args" | tr '[:upper:]' '[:lower:]')"
set -- ${words[@]+"${words[@]}"}
name='' value=''
if [ "$command" = rules ]; then
  title='silverback rules:'
  usage='usage: /silverback:rules [on|off].'
  if [ $# -eq 1 ] && [[ $1 =~ ^(on|off)$ ]]; then name=rules value=$1; fi
else
  title='silverback guard:'
  usage='usage: /silverback:guard [push|delete|history|files] [on|off], /silverback:guard verify [on|observe|off].'
  if [ $# -eq 2 ] && { { [[ $1 =~ ^(push|delete|history|files)$ ]] && [[ $2 =~ ^(on|off)$ ]]; } ||
    { [ "$1" = verify ] && [[ $2 =~ ^(on|observe|off)$ ]]; }; }; then name=$1 value=$2; fi
fi
if [ -n "$name" ]; then
  if [ "$(state "$name")" = "$value" ]; then
    title="$title $(label "$name") is already $value."
  else
    mkdir -p "${switch_file%/*}"
    others=$(grep -vE "^$name=" "$switch_file" 2>/dev/null) || true
    {
      if [ -n "$others" ]; then printf '%s\n' "$others"; fi
      if [ "$value" != on ]; then printf '%s=%s\n' "$name" "$value"; fi
    } > "$switch_file.tmp"
    mv -f "$switch_file.tmp" "$switch_file"
    title="$title $(label "$name") turned $value."
  fi
elif [ $# -ne 0 ]; then
  title="$title $usage"
fi

reason=$title
if [ "$command" = rules ]; then
  reason="$reason\\n$(line rules)\\nA change reaches the main session at its next start (a new session or /clear) and subagents at once. The guard hooks stay as /silverback:guard sets them."
else
  for name in $switches; do reason="$reason\\n$(line "$name")"; done
fi
printf '{"decision":"block","reason":"%s"}\n' "$reason"
exit 0
