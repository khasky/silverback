# PowerShell twin of guard.sh for agents that run Windows hooks through
# PowerShell (Codex): the same rule tables, the same messages, exit 2 to block.
# scripts/lint.py runs both scripts against the same commands.
$ErrorActionPreference = 'Stop'

$raw = [Console]::In.ReadToEnd()

# Codex sends a turn_id with every tool call and Claude Code does not. Codex
# parses an "ask" decision but runs the call anyway (checked on codex-cli
# 0.169), so there every ask rule denies instead, and the switch that turns the
# rule off is named in the reason.
$codex = $raw -match '"turn_id"\s*:'
# Kimi Code documents deny and no ask, so there ask rules deny too.
$kimi = $raw -match '"client_type"\s*:\s*"kimi'
# Copilot CLI (its hooks file sets SILVERBACK_AGENT) reads the decision from
# top-level fields and denies an exit-2 call without showing the reason.
$copilot = $env:SILVERBACK_AGENT -eq 'copilot'
function Write-Decision([string]$message, [string]$switch) {
  $message = "silverback: $message"
  if ($copilot) {
    [Console]::Out.WriteLine((@{ permissionDecision = 'ask'; permissionDecisionReason = $message } | ConvertTo-Json -Compress))
    return
  }
  $decision = 'ask'
  if ($kimi) {
    $decision = 'deny'
    $message += ' Kimi Code cannot ask for approval, so the call is blocked: the user runs it.'
  } elseif ($codex) {
    $decision = 'deny'
    $message += ' Codex cannot ask for approval, so the call is blocked: the user runs it'
    if ($switch) { $message += ", or turns this check off with /silverback:guard $switch off" }
    $message += '.'
  }
  [Console]::Out.WriteLine('{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"' + $decision + '","permissionDecisionReason":"' + $message + '"}}')
}

try {
  $payload = $raw | ConvertFrom-Json
} catch {
  # A payload that names a command the guard cannot read (cut off, or in a
  # shape it does not parse) goes to the user rather than through unchecked.
  if ($raw -match '"command"\s*:') {
    Write-Decision 'the guard could not read this command. Approve only if you have read it.' ''
  }
  exit 0
}
$toolInput = $payload.tool_input
if ($toolInput -is [string]) { $toolInput = $toolInput | ConvertFrom-Json }
$command = [string]$toolInput.command
if (-not $command) { exit 0 }
# A newline separates commands the way ; does. Known ceiling: a command
# assembled at run time (a variable, a script file, git commit -F) is not seen.
$command = $command -replace "`r?`n", '; '

# A pattern starting with (?-i) is matched case-sensitively (git branch -D
# deletes unmerged work, -d does not); every other pattern ignores case.
function Test-Command([string]$pattern) {
  return [regex]::IsMatch($command, $pattern, 'IgnoreCase')
}

# A segment starts at the line start or after ; & | ( or $( and runs to the
# next separator, so [^;&|]* keeps a flag tied to the git call it belongs to.
$start = '(^|[;&|(]|\$\()\s*'
$secret = '[A-Za-z0-9_]*(KEY|TOKEN|SECRET|PASSWORD|PASSWD|CREDENTIAL)[A-Za-z0-9_]*'
$gitcall = 'git\s[^;&|]*'
$end = '(\s|$|[;&|)])'

# Block rules: pattern, exception pattern (a match lets the command through),
# message.
$blockRules = @(
  # Printing the environment, from the shell or from an interpreter one-liner.
  # A listing reduced to variable names prints no value, and it is how an agent
  # finds a missing variable, so it goes through.
  @{ Pattern = "(^|[^A-Za-z0-9_-])printenv([^A-Za-z0-9_-]|$)|$start(env|set)\s*($|[;&|)])|declare\s+-[A-Za-z0-9]*p|/proc/\S*/environ|(Get-ChildItem|gci|dir|ls|Get-Item|gi)\s+(-Path\s+)?env:(\*|[\s;|]|$)|(print|pprint|dumps)\s*\(\s*(dict\()?os\.environ\s*\)|console\.(log|dir|table)\s*\(\s*process\.env\s*\)|stringify\(\s*process\.env\s*[),]|GetEnvironmentVariables\(\s*\)"
     Unless = '[|]\s*(select(-object)?\s+(-expandproperty\s+)?name|%\s*[{]\s*[$]_\.name|cut\s+-d\s*.?=.?\s*-f\s*1)\s*($|[|;&)])'
     Message = 'printing the environment. Its output enters the transcript with every credential in it: read the one value the task needs, or send both streams to the null device.' },
  # Printing one variable whose name marks a secret: a bare PowerShell $env:X
  # statement, or echo/printf/Write-* of it. Testing that it is set, or
  # passing it to a command, prints nothing.
  @{ Pattern = "$start\`$env:$secret\s*($|[;|)])|(echo|printf|print|Write-Host|Write-Output)\s[^;&|]*\`$(env:)?\{?$secret"
     Unless = ''
     Message = 'printing a secret variable. Its value enters the transcript: test that it is set ([ -n "$X" ], Test-Path env:X) instead of printing it.' },
  # Printing a file whose whole content is secrets. A template (.env.example)
  # holds none and goes through.
  @{ Pattern = $start + '(sudo\s+)?(cat|type|Get-Content|gc|less|more|head|tail|bat|nl|strings|xxd|od)\s([^;&|]*[\s/\\"''])?(\.env(\.[A-Za-z0-9_-]+)?|credentials|\.netrc|\.npmrc|\.pypirc|\.git-credentials|\.pgpass|id_(rsa|ed25519|ecdsa|dsa))' + $end
     Unless = '\.env\.(example|sample|template|dist|defaults)'
     Message = 'printing a secrets file (.env, credentials, a private key). Its content enters the transcript: list the variable names (cut -d= -f1 .env) or test that the one the task needs is set.' },
  # A CLI printing its own stored credential.
  @{ Pattern = 'gh\s+auth\s+(token|status[^;&|]*(--show-token|\s-t))|print-(access|identity)-token|az\s+account\s+get-access-token|aws\s[^;&|]*(get-session-token|export-credentials)|heroku\s+auth:token'
     Unless = ''
     Message = 'printing a stored CLI credential. Its value enters the transcript: a status command (gh auth status) shows whether one is set.' },
  # A recursive delete of the root, home, working directory or .git.
  # rm -rf build stays ordinary work.
  @{ Pattern = $start + '(sudo\s+)?(rm|Remove-Item)\s([^;&|]*\s)?(-[dfirv]*r[dfirv]*|--recursive|-rec[A-Za-z]*)\s([^;&|]*\s)?(/|/\*|~/?|\.{1,2}/?|\*|\.git/?|\$HOME/?)(\s|$|[;&|)])'
     Unless = ''
     Message = 'recursively deleting the root, the home or working directory, or .git.' },
  # Overwriting a disk or a filesystem.
  @{ Pattern = 'dd\s[^;&|]*of=/dev/|(^|[^A-Za-z0-9_-])mkfs(\.[A-Za-z0-9]+)?\s|Format-Volume|Clear-Disk'
     Unless = ''
     Message = 'overwriting a disk or a filesystem.' },
  # Discarding uncommitted work or stashed work. Unstaging (restore --staged)
  # keeps the changes and goes through.
  @{ Pattern = $gitcall + '(reset[^;&|]*\s--hard|clean[^;&|]*\s(-[A-Za-z0-9]*f|--force)|checkout[^;&|]*\s(--\s+)?(\.|:/|\*)' + $end + '|(checkout|switch)[^;&|]*\s(-f|--force|--discard-changes)' + $end + '|restore[^;&|]*\s(\.|:/|\*)' + $end + '|stash\s+(drop|clear))'
     Unless = 'restore[^;&|]*--staged'
     Message = 'discarding uncommitted or stashed work for good (git reset --hard, git checkout -- ., git restore ., git clean -f, git stash drop).' },
  # Rewriting what a remote already has: a force push, a deleted remote branch,
  # a mirror push, or a rewrite of the whole history.
  @{ Pattern = $gitcall + 'push[^;&|]*(\s(-[A-Za-z0-9]*[fd][A-Za-z0-9]*|--force[^\s;&|]*|--mirror|--delete|--prune)' + $end + '|\s[+][^\s;&|]+|\s:[^\s;&|]+)|' + $gitcall + 'filter-(branch|repo)'
     Unless = ''
     Message = 'force-pushing, deleting a remote branch, or rewriting the whole history. These change what others already have.' },
  # Skipping git hooks: the flag, a hooks path override, or a hook manager's
  # off switch in the environment.
  @{ Pattern = $gitcall + '(--no-verify|core\.hooksPath)|' + $gitcall + 'commit[^;&|]*\s-[A-Za-z0-9]*n[A-Za-z0-9]*' + $end + '|(^|[\s;&|])(HUSKY=0|HUSKY_SKIP_HOOKS=1|LEFTHOOK=0|SKIP=\S+)\s[^;&|]*git\s|\$env:(HUSKY|LEFTHOOK)\s*=\s*[''"]?0'
     Unless = ''
     Message = 'skipping git hooks. A failing hook is a check: fix what it reports.' },
  @{ Pattern = '(drop\s+(table|database|schema)|truncate\s+(table\s+)?[A-Za-z_])'
     Unless = ''
     Message = 'dropping or emptying a table or database.' },
  @{ Pattern = 'delete\s+from\s'
     Unless = 'delete\s+from\s[^;]*\swhere\s'
     Message = 'deleting every row of a table (DELETE without WHERE).' },
  @{ Pattern = '(curl|wget|iwr|irm|Invoke-WebRequest|Invoke-RestMethod)\s[^;&|]*[|]\s*(sudo\s+)?((ba|z|da)?sh|iex|Invoke-Expression|pwsh|powershell)(\s|$|[;&|)])|(iex|Invoke-Expression)\s*[(]\s*(irm|iwr|Invoke-RestMethod|Invoke-WebRequest)|(^|[^A-Za-z0-9_-])(ba|z)?sh\s+(-c\s+)?\S{0,3}(<|[$])[(]\s*(curl|wget)'
     Unless = ''
     Message = 'running a script downloaded from the network without reading it.' },
  # The switch file turns ask rules off. Only the user changes it, with /silverback:guard or /silverback:rules.
  @{ Pattern = '[/\\]\.silverback([/\\\s"'']|$)'
     Unless = ''
     Message = 'touching the guard switch file. Only the user changes it, with /silverback:guard or /silverback:rules.' }
)

$issues = @()
foreach ($rule in $blockRules) {
  if ((Test-Command $rule.Pattern) -and (-not $rule.Unless -or -not (Test-Command $rule.Unless))) {
    $issues += $rule.Message
  }
}
if ($issues.Count -gt 0) {
  if ($copilot) {
    $reason = ($issues | ForEach-Object { "Blocked by the silverback guard: $_" }) -join ' '
    [Console]::Out.WriteLine((@{ permissionDecision = 'deny'; permissionDecisionReason = $reason } | ConvertTo-Json -Compress))
    exit 0
  }
  foreach ($issue in $issues) { [Console]::Error.WriteLine("Blocked by the silverback guard: $issue") }
  exit 2
}

# An AI coding agent named as co-author: a GitHub app ([bot]), the address an
# agent signs with, or the agent's name. A human co-author passes. Sources:
# the agent-dora and CHAOSS disclosure detection lists and the tools' own
# commits; an entry is an address or a product name, never a company domain
# a person could write from.
$agent = '\[bot\]|@(anthropic\.com|openai\.com|cursor\.com|aider\.chat|all-hands\.dev|ampcode\.com|charm\.land|factory\.ai|opencode\.ai|windsurf\.(ai|com)|continue\.dev|kiro\.dev|cline\.bot|roocode\.com|kilocode\.ai|kilo\.ai|block\.xyz|aaif\.ai|augmentcode\.com|warp\.dev|zed\.dev|air\.dev|mistral\.ai|charlielabs\.ai|x\.ai|muse\.dev)|(copilot@github|gemini-code-assist@google|junie@jetbrains|qwen-coder@alibabacloud|it\+v0agent@vercel|noreply@meta)\.com|[0-9]+\+copilot@|(^|[^A-Za-z0-9])(claude|anthropic|copilot|codex|chatgpt|openai|cursor|gemini|jules|devin|aider|openhands|amp|crush|opencode|droid|windsurf|cascade|kiro|amazon-q|cline|roo code|roomote|kilo code|goose|augment|junie|mistral vibe|qwen-coder|v0agent|lovable|gpt-engineer|codegen|grok|muse code|coderabbit|mentat|sweep|greptile|cody|codium|replit)([^A-Za-z0-9]|$)'

# Ask rules: pattern, second pattern that must match too (a trailer sits in
# the message body, past the segment the commit call is in), exception
# pattern, message, and the switch the user turns the rule off with
# (/silverback:guard <switch> off, written to the switch file by
# guard-switch). Whether a prompt asked for the push or the rewrite cannot be
# read from its words in every language, so the user confirms the call itself.
$askRules = @(
  @{ Pattern = $gitcall + 'commit'
     Also = "co-authored-by\s*:[^;]*($agent)"
     Message = 'this commit names an AI agent as co-author. Commits carry no assistant trace: approve only if you asked for it.' },
  @{ Pattern = $gitcall + 'push(\s|$)'
     Message = 'this pushes to a remote. Approve only if you asked for it.'
     Switch = 'push' },
  # Any other recursive delete: what it removes is not in git or any remote.
  @{ Pattern = $start + '(sudo\s+)?(rm|rmdir|rd|del|erase|ri|Remove-Item)\s([^;&|]*\s)?(-[dfirv]*r[dfirv]*|--recursive|-rec[A-Za-z]*|/s)(\s|$|[;&|)])|(^|[^A-Za-z0-9_-])find\s[^;&|]*\s(-delete|-exec\s+rm)(\s|$)'
     Message = 'this deletes a directory and everything in it. Approve only if you asked for it.'
     Switch = 'delete' },
  # Rewriting local commits: an amend, a rebase, a forced branch delete. The
  # steps that finish or abandon a rebase already under way pass.
  @{ Pattern = $gitcall + 'commit[^;&|]*--amend|git\s([^;&|]*\s)?rebase' + $end
     Unless = 'rebase\s+--(abort|continue|skip|quit|edit-todo|show-current-patch)'
     Message = 'this rewrites or discards commits (amend, rebase). Approve only if you asked for it.'
     Switch = 'history' },
  @{ Pattern = '(?-i)' + $gitcall + 'branch[^;&|]*\s(-[A-Za-z0-9]*D|--delete[^;&|]*--force|--force[^;&|]*--delete)' + $end
     Message = 'this deletes a branch whether or not it was merged. Approve only if you asked for it.'
     Switch = 'history' }
)
$userHome = if ($env:USERPROFILE) { $env:USERPROFILE } else { $env:HOME }
$switchFile = Join-Path $userHome '.silverback/guard'
$switchesOff = @()
if (Test-Path -LiteralPath $switchFile) { $switchesOff = @(Get-Content -LiteralPath $switchFile) }
foreach ($rule in $askRules) {
  if ($rule.Switch -and $switchesOff -contains "$($rule.Switch)=off") { continue }
  if ((Test-Command $rule.Pattern) -and (-not $rule.Also -or (Test-Command $rule.Also)) -and
      (-not $rule.Unless -or -not (Test-Command $rule.Unless))) {
    Write-Decision $rule.Message $rule.Switch
    exit 0
  }
}
exit 0
