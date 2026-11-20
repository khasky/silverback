#!/usr/bin/env bash
# PreToolUse guard for shell tools, in the shape of Anthropic's
# bash_command_validator example: a table of (pattern, message) rules run over
# the command; every matching block rule is reported and exit 2 blocks the
# call, with stderr handed to the agent as the reason. The ask rules hand the
# call to the user instead: a push, a commit naming an AI agent as co-author,
# a recursive delete, and a rewrite of commits.
# Known ceiling: the patterns see the command text, not its syntax, so a
# forbidden word inside a quoted argument matches too.
set -euo pipefail

payload=$(cat)

# Codex sends a turn_id with every tool call and Claude Code does not. Codex
# parses an "ask" decision but runs the call anyway (checked on codex-cli
# 0.169), so there every ask rule denies instead, and the switch that turns the
# rule off is named in the reason.
codex=0
if printf '%s' "$payload" | grep -q '"turn_id"[[:space:]]*:'; then codex=1; fi
# Kimi Code documents deny and no ask, so there ask rules deny too.
kimi=0
if printf '%s' "$payload" | grep -q '"client_type"[[:space:]]*:[[:space:]]*"kimi'; then kimi=1; fi
# Copilot CLI (its hooks file sets SILVERBACK_AGENT) reads the decision from
# top-level fields and denies an exit-2 call without showing the reason.
copilot=0
if [ "${SILVERBACK_AGENT:-}" = copilot ]; then copilot=1; fi

# Prints the decision for an ask rule: $1 the message, $2 its switch (or empty).
decide() {
  if [ "$copilot" = 1 ]; then
    printf '{"permissionDecision":"ask","permissionDecisionReason":"silverback: %s"}\n' "$1"
    return
  fi
  local message="silverback: $1" decision=ask
  if [ "$kimi" = 1 ]; then
    decision=deny
    message="$message Kimi Code cannot ask for approval, so the call is blocked: the user runs it."
  elif [ "$codex" = 1 ]; then
    decision=deny
    message="$message Codex cannot ask for approval, so the call is blocked: the user runs it"
    if [ -n "$2" ]; then message="$message, or turns this check off with /silverback:guard $2 off"; fi
    message="$message."
  fi
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"%s","permissionDecisionReason":"%s"}}\n' \
    "$decision" "$message"
}

# Only git and the OS shell are assumed, so the command field is pulled out with
# a regex instead of a JSON parser. JSON escapes stay in the text; an escaped
# newline becomes a command separator. Known ceiling: a command assembled at run
# time (a variable, a script file, git commit -F) is not seen.
command=$(printf '%s' "$payload" |
  grep -oE '"command"[[:space:]]*:[[:space:]]*"([^"\\]|\\.)*"' |
  head -n 1 |
  sed -E 's/^"command"[[:space:]]*:[[:space:]]*"//; s/"$//; s/\\n/; /g') || true
if [ -z "$command" ]; then
  # A payload that names a command the guard cannot read (cut off, or in a
  # shape it does not parse) goes to the user rather than through unchecked.
  if printf '%s' "$payload" | grep -qE '"command"[[:space:]]*:'; then
    decide 'the guard could not read this command. Approve only if you have read it.' ''
  fi
  exit 0
fi

# A pattern starting with "CASE:" is matched case-sensitively (git branch -D
# deletes unmerged work, -d does not); every other pattern ignores case.
matches() {
  case $1 in
    CASE:*) printf '%s' "$command" | grep -qE -- "${1#CASE:}" ;;
    *) printf '%s' "$command" | grep -qEi -- "$1" ;;
  esac
}

# A segment starts at the line start or after ; & | ( or $( and runs to the
# next separator, so [^;&|]* keeps a flag tied to the git call it belongs to.
start='(^|[;&|(]|\$\()[[:space:]]*'
secret='[[:alnum:]_]*(KEY|TOKEN|SECRET|PASSWORD|PASSWD|CREDENTIAL)[[:alnum:]_]*'
gitcall='git[[:space:]][^;&|]*'
end='([[:space:]]|$|[;&|)])'

# Block rules, three fields each: pattern, exception pattern (a match lets the
# command through), message.
block_rules=(
  # Printing the environment, from the shell or from an interpreter one-liner.
  # A listing reduced to variable names prints no value, and it is how an agent
  # finds a missing variable, so it goes through.
  "(^|[^[:alnum:]_-])printenv([^[:alnum:]_-]|$)|${start}(env|set)[[:space:]]*($|[;&|)])|declare[[:space:]]+-[[:alnum:]]*p|/proc/[^[:space:]]*/environ|(Get-ChildItem|gci|dir|ls|Get-Item|gi)[[:space:]]+(-Path[[:space:]]+)?env:(\*|[[:space:];|]|$)|(print|pprint|dumps)[[:space:]]*\\([[:space:]]*(dict\\()?os\\.environ[[:space:]]*\\)|console\\.(log|dir|table)[[:space:]]*\\([[:space:]]*process\\.env[[:space:]]*\\)|stringify\\([[:space:]]*process\\.env[[:space:]]*[),]|GetEnvironmentVariables\\([[:space:]]*\\)"
  '[|][[:space:]]*(select(-object)?[[:space:]]+(-expandproperty[[:space:]]+)?name|%[[:space:]]*[{][[:space:]]*[$]_\.name|cut[[:space:]]+-d[[:space:]]*.?=.?[[:space:]]*-f[[:space:]]*1)[[:space:]]*($|[|;&)])'
  'printing the environment. Its output enters the transcript with every credential in it: read the one value the task needs, or send both streams to the null device.'
  # Printing one variable whose name marks a secret: a bare PowerShell $env:X
  # statement, or echo/printf/Write-* of it. Testing that it is set, or
  # passing it to a command, prints nothing.
  "${start}\\\$env:${secret}[[:space:]]*(\$|[;|)])|(echo|printf|print|Write-Host|Write-Output)[[:space:]][^;&|]*\\\$(env:)?\\{?${secret}"
  ''
  'printing a secret variable. Its value enters the transcript: test that it is set ([ -n "$X" ], Test-Path env:X) instead of printing it.'
  # Printing a file whose whole content is secrets. A template (.env.example)
  # holds none and goes through.
  "${start}(sudo[[:space:]]+)?(cat|type|Get-Content|gc|less|more|head|tail|bat|nl|strings|xxd|od)[[:space:]]([^;&|]*[[:space:]/\\\\\"'])?(\\.env(\\.[[:alnum:]_-]+)?|credentials|\\.netrc|\\.npmrc|\\.pypirc|\\.git-credentials|\\.pgpass|id_(rsa|ed25519|ecdsa|dsa))${end}"
  '\.env\.(example|sample|template|dist|defaults)'
  'printing a secrets file (.env, credentials, a private key). Its content enters the transcript: list the variable names (cut -d= -f1 .env) or test that the one the task needs is set.'
  # A CLI printing its own stored credential.
  'gh[[:space:]]+auth[[:space:]]+(token|status[^;&|]*(--show-token|[[:space:]]-t))|print-(access|identity)-token|az[[:space:]]+account[[:space:]]+get-access-token|aws[[:space:]][^;&|]*(get-session-token|export-credentials)|heroku[[:space:]]+auth:token'
  ''
  'printing a stored CLI credential. Its value enters the transcript: a status command (gh auth status) shows whether one is set.'
  # A recursive delete of the root, home, working directory or .git.
  # rm -rf build stays ordinary work.
  "${start}"'(sudo[[:space:]]+)?(rm|Remove-Item)[[:space:]]([^;&|]*[[:space:]])?(-[dfirv]*r[dfirv]*|--recursive|-rec[[:alpha:]]*)[[:space:]]([^;&|]*[[:space:]])?(/|/\*|~/?|\.{1,2}/?|\*|\.git/?|\$HOME/?)([[:space:]]|$|[;&|)])'
  ''
  'recursively deleting the root, the home or working directory, or .git.'
  # Overwriting a disk or a filesystem.
  "dd[[:space:]][^;&|]*of=/dev/|(^|[^[:alnum:]_-])mkfs(\\.[[:alnum:]]+)?[[:space:]]|Format-Volume|Clear-Disk"
  ''
  'overwriting a disk or a filesystem.'
  # Discarding uncommitted work or stashed work. Unstaging (restore --staged)
  # keeps the changes and goes through.
  "${gitcall}(reset[^;&|]*[[:space:]]--hard|clean[^;&|]*[[:space:]](-[[:alnum:]]*f|--force)|checkout[^;&|]*[[:space:]](--[[:space:]]+)?(\\.|:/|\\*)${end}|(checkout|switch)[^;&|]*[[:space:]](-f|--force|--discard-changes)${end}|restore[^;&|]*[[:space:]](\\.|:/|\\*)${end}|stash[[:space:]]+(drop|clear))"
  'restore[^;&|]*--staged'
  'discarding uncommitted or stashed work for good (git reset --hard, git checkout -- ., git restore ., git clean -f, git stash drop).'
  # Rewriting what a remote already has: a force push, a deleted remote branch,
  # a mirror push, or a rewrite of the whole history.
  "${gitcall}push[^;&|]*([[:space:]](-[[:alnum:]]*[fd][[:alnum:]]*|--force[^[:space:];&|]*|--mirror|--delete|--prune)${end}|[[:space:]][+][^[:space:];&|]+|[[:space:]]:[^[:space:];&|]+)|${gitcall}filter-(branch|repo)"
  ''
  'force-pushing, deleting a remote branch, or rewriting the whole history. These change what others already have.'
  # Skipping git hooks: the flag, a hooks path override, or a hook manager's
  # off switch in the environment.
  "${gitcall}(--no-verify|core\\.hooksPath)|${gitcall}commit[^;&|]*[[:space:]]-[[:alnum:]]*n[[:alnum:]]*${end}|(^|[[:space:];&|])(HUSKY=0|HUSKY_SKIP_HOOKS=1|LEFTHOOK=0|SKIP=[^[:space:]]+)[[:space:]][^;&|]*git[[:space:]]|\\\$env:(HUSKY|LEFTHOOK)[[:space:]]*=[[:space:]]*['\"]?0"
  ''
  'skipping git hooks. A failing hook is a check: fix what it reports.'
  '(drop[[:space:]]+(table|database|schema)|truncate[[:space:]]+(table[[:space:]]+)?[[:alpha:]_])'
  ''
  'dropping or emptying a table or database.'
  'delete[[:space:]]+from[[:space:]]'
  'delete[[:space:]]+from[[:space:]][^;]*[[:space:]]where[[:space:]]'
  'deleting every row of a table (DELETE without WHERE).'
  '(curl|wget|iwr|irm|Invoke-WebRequest|Invoke-RestMethod)[[:space:]][^;&|]*[|][[:space:]]*(sudo[[:space:]]+)?((ba|z|da)?sh|iex|Invoke-Expression|pwsh|powershell)([[:space:]]|$|[;&|)])|(iex|Invoke-Expression)[[:space:]]*[(][[:space:]]*(irm|iwr|Invoke-RestMethod|Invoke-WebRequest)|(^|[^[:alnum:]_-])(ba|z)?sh[[:space:]]+(-c[[:space:]]+)?[^[:space:]]{0,3}(<|[$])[(][[:space:]]*(curl|wget)'
  ''
  'running a script downloaded from the network without reading it.'
  # The switch file turns ask rules off. Only the user changes it, with /silverback:guard.
  '[/\\]\.silverback([/\\[:space:]"'"'"']|$)'
  ''
  'touching the guard switch file. Only the user changes it, with /silverback:guard.'
)

issues=()
for ((i = 0; i < ${#block_rules[@]}; i += 3)); do
  if matches "${block_rules[i]}" && { [ -z "${block_rules[i + 1]}" ] || ! matches "${block_rules[i + 1]}"; }; then
    issues+=("${block_rules[i + 2]}")
  fi
done
if [ ${#issues[@]} -gt 0 ]; then
  if [ "$copilot" = 1 ]; then
    reason=$(printf 'Blocked by the silverback guard: %s ' "${issues[@]}" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')
    printf '{"permissionDecision":"deny","permissionDecisionReason":"%s"}\n' "${reason% }"
    exit 0
  fi
  printf 'Blocked by the silverback guard: %s\n' "${issues[@]}" >&2
  exit 2
fi

# An AI coding agent named as co-author: a GitHub app ([bot]), the address an
# agent signs with, or the agent's name. A human co-author passes. Sources:
# the agent-dora and CHAOSS disclosure detection lists and the tools' own
# commits; an entry is an address or a product name, never a company domain
# a person could write from.
agent='\[bot\]|@(anthropic\.com|openai\.com|cursor\.com|aider\.chat|all-hands\.dev|ampcode\.com|charm\.land|factory\.ai|opencode\.ai|windsurf\.(ai|com)|continue\.dev|kiro\.dev|cline\.bot|roocode\.com|kilocode\.ai|kilo\.ai|block\.xyz|aaif\.ai|augmentcode\.com|warp\.dev|zed\.dev|air\.dev|mistral\.ai|charlielabs\.ai|x\.ai|muse\.dev)|(copilot@github|gemini-code-assist@google|junie@jetbrains|qwen-coder@alibabacloud|it\+v0agent@vercel|noreply@meta)\.com|[0-9]+\+copilot@|(^|[^A-Za-z0-9])(claude|anthropic|copilot|codex|chatgpt|openai|cursor|gemini|jules|devin|aider|openhands|amp|crush|opencode|droid|windsurf|cascade|kiro|amazon-q|cline|roo code|roomote|kilo code|goose|augment|junie|mistral vibe|qwen-coder|v0agent|lovable|gpt-engineer|codegen|grok|muse code|coderabbit|mentat|sweep|greptile|cody|codium|replit)([^A-Za-z0-9]|$)'

# Ask rules, five fields each: pattern, second pattern that must match too
# (a trailer sits in the message body, past the segment the commit call is
# in), exception pattern, message, and the switch the user turns the rule off
# with (/silverback:guard <switch> off, written to the switch file by
# guard-switch). Whether a prompt asked for the push or the rewrite cannot be
# read from its words in every language, so the user confirms the call itself.
ask_rules=(
  "${gitcall}commit"
  "co-authored-by[[:space:]]*:[^;]*(${agent})"
  ''
  'this commit names an AI agent as co-author. Commits carry no assistant trace: approve only if you asked for it.'
  ''
  "${gitcall}push([[:space:]]|$)"
  ''
  ''
  'this pushes to a remote. Approve only if you asked for it.'
  'push'
  # Any other recursive delete: what it removes is not in git or any remote.
  "${start}"'(sudo[[:space:]]+)?(rm|rmdir|rd|del|erase|ri|Remove-Item)[[:space:]]([^;&|]*[[:space:]])?(-[dfirv]*r[dfirv]*|--recursive|-rec[[:alpha:]]*|/s)([[:space:]]|$|[;&|)])|(^|[^[:alnum:]_-])find[[:space:]][^;&|]*[[:space:]](-delete|-exec[[:space:]]+rm)([[:space:]]|$)'
  ''
  ''
  'this deletes a directory and everything in it. Approve only if you asked for it.'
  'delete'
  # Rewriting local commits: an amend, a rebase, a forced branch delete. The
  # steps that finish or abandon a rebase already under way pass.
  "${gitcall}commit[^;&|]*--amend|git[[:space:]]([^;&|]*[[:space:]])?rebase${end}"
  ''
  'rebase[[:space:]]+--(abort|continue|skip|quit|edit-todo|show-current-patch)'
  'this rewrites or discards commits (amend, rebase). Approve only if you asked for it.'
  'history'
  "CASE:${gitcall}branch[^;&|]*[[:space:]](-[[:alnum:]]*D|--delete[^;&|]*--force|--force[^;&|]*--delete)${end}"
  ''
  ''
  'this deletes a branch whether or not it was merged. Approve only if you asked for it.'
  'history'
)
switch_file="$HOME/.silverback/guard"
for ((i = 0; i < ${#ask_rules[@]}; i += 5)); do
  switch="${ask_rules[i + 4]}"
  if [ -n "$switch" ] && grep -qxF "$switch=off" "$switch_file" 2>/dev/null; then
    continue
  fi
  if matches "${ask_rules[i]}" && { [ -z "${ask_rules[i + 1]}" ] || matches "${ask_rules[i + 1]}"; } &&
    { [ -z "${ask_rules[i + 2]}" ] || ! matches "${ask_rules[i + 2]}"; }; then
    decide "${ask_rules[i + 3]}" "$switch"
    exit 0
  fi
done
exit 0
