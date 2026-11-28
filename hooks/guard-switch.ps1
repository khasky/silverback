# PowerShell twin of guard-switch.sh: the same commands, file and messages.
# scripts/lint.py runs both scripts against the same prompts.
$ErrorActionPreference = 'Stop'

try {
  $prompt = [string]([Console]::In.ReadToEnd() | ConvertFrom-Json).prompt
} catch {
  exit 0
}
$prompt = $prompt -replace '[\r\n\t]', ' '

# Typed as text the command arrives as is; an interactive session can wrap it
# as <command-name>/silverback:guard</command-name><command-args>push off</command-args>.
$envelope = '<command-name>\s*/silverback:(guard|rules)\s*</command-name>'
$literal = '^\s*/silverback:(guard|rules)(\s+(.*))?$'
$argText = ''
if ($prompt -cmatch $envelope) {
  $command = $Matches[1]
  if ($prompt -cmatch '<command-args>([^<]*)</command-args>') { $argText = $Matches[1] }
} elseif ($prompt -cmatch $literal) {
  $command = $Matches[1]
  $argText = [string]$Matches[3]
} else {
  exit 0
}

$userHome = if ($env:USERPROFILE) { $env:USERPROFILE } else { $env:HOME }
$switchFile = Join-Path $userHome '.silverback/guard'
$switches = 'push', 'delete', 'history', 'files', 'verify'
# A switch is on unless the file holds name=<state>.
function Get-Switch([string]$name) {
  $found = @()
  if (Test-Path -LiteralPath $switchFile) { $found = @(Get-Content -LiteralPath $switchFile | Where-Object { $_ -like "$name=*" }) }
  if ($found.Count) { $found[-1].Substring($name.Length + 1) } else { 'on' }
}

function Get-Label([string]$name) {
  switch ($name) {
    'push' { 'push prompt' }
    'delete' { 'recursive-delete prompt' }
    'history' { 'history-rewrite prompt' }
    'files' { 'protected-file prompt' }
    'verify' { 'verification check' }
    'rules' { 'ruleset' }
  }
}
# One line per switch: its state and the command that changes it.
function Get-Line([string]$name) {
  $now = Get-Switch $name
  $flip = if ($name -eq 'verify') { 'on|observe|off' } elseif ($now -eq 'on') { 'off' } else { 'on' }
  if ($name -eq 'rules') { "$(Get-Label $name): $now (/silverback:rules $flip)" }
  else { "$(Get-Label $name): $now (/silverback:guard $name $flip)" }
}

$words = @($argText.ToLowerInvariant() -split '\s+' | Where-Object { $_ })
$name = ''
$value = ''
if ($command -eq 'rules') {
  $title = 'silverback rules:'
  $usage = 'usage: /silverback:rules [on|off].'
  if ($words.Count -eq 1 -and $words[0] -match '^(on|off)$') { $name = 'rules'; $value = $words[0] }
} else {
  $title = 'silverback guard:'
  $usage = 'usage: /silverback:guard [push|delete|history|files] [on|off], /silverback:guard verify [on|observe|off].'
  if ($words.Count -eq 2 -and (($words[0] -match '^(push|delete|history|files)$' -and $words[1] -match '^(on|off)$') -or
      ($words[0] -eq 'verify' -and $words[1] -match '^(on|observe|off)$'))) { $name = $words[0]; $value = $words[1] }
}
if ($name) {
  if ((Get-Switch $name) -eq $value) {
    $title += " $(Get-Label $name) is already $value."
  } else {
    $null = New-Item -ItemType Directory -Force -Path (Split-Path $switchFile)
    $lines = @()
    if (Test-Path -LiteralPath $switchFile) { $lines = @(Get-Content -LiteralPath $switchFile | Where-Object { $_ -notlike "$name=*" }) }
    if ($value -ne 'on') { $lines += "$name=$value" }
    [IO.File]::WriteAllText("$switchFile.tmp", (($lines | ForEach-Object { "$_`n" }) -join ''))
    Move-Item -Force -LiteralPath "$switchFile.tmp" -Destination $switchFile
    $title += " $(Get-Label $name) turned $value."
  }
} elseif ($words.Count -ne 0) {
  $title += " $usage"
}

$reason = $title
if ($command -eq 'rules') {
  $reason += '\n' + (Get-Line 'rules') + '\nA change reaches the main session at its next start (a new session or /clear) and subagents at once. The guard hooks stay as /silverback:guard sets them.'
} else {
  foreach ($switch in $switches) { $reason += '\n' + (Get-Line $switch) }
}
[Console]::Out.WriteLine('{"decision":"block","reason":"' + $reason + '"}')
exit 0
