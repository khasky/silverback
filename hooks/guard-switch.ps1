# PowerShell twin of guard-switch.sh: the same command, file and messages.
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
$envelope = '<command-name>\s*/silverback:guard\s*</command-name>'
$literal = '^\s*/silverback:guard(\s+(.*))?$'
$argText = ''
if ($prompt -cmatch $envelope) {
  if ($prompt -cmatch '<command-args>([^<]*)</command-args>') { $argText = $Matches[1] }
} elseif ($prompt -cmatch $literal) {
  $argText = [string]$Matches[2]
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
  }
}
# One line per switch: its state and the command that changes it.
function Get-Line([string]$name) {
  $now = Get-Switch $name
  $flip = if ($name -eq 'verify') { 'on|observe|off' } elseif ($now -eq 'on') { 'off' } else { 'on' }
  "$(Get-Label $name): $now (/silverback:guard $name $flip)"
}

$words = @($argText.ToLowerInvariant() -split '\s+' | Where-Object { $_ })
$title = 'silverback guard:'
$valid = $words.Count -eq 2 -and (($words[0] -match '^(push|delete|history|files)$' -and $words[1] -match '^(on|off)$') -or
  ($words[0] -eq 'verify' -and $words[1] -match '^(on|observe|off)$'))
if ($valid) {
  if ((Get-Switch $words[0]) -eq $words[1]) {
    $title += " $(Get-Label $words[0]) is already $($words[1])."
  } else {
    $null = New-Item -ItemType Directory -Force -Path (Split-Path $switchFile)
    $lines = @()
    if (Test-Path -LiteralPath $switchFile) { $lines = @(Get-Content -LiteralPath $switchFile | Where-Object { $_ -notlike "$($words[0])=*" }) }
    if ($words[1] -ne 'on') { $lines += "$($words[0])=$($words[1])" }
    [IO.File]::WriteAllText("$switchFile.tmp", (($lines | ForEach-Object { "$_`n" }) -join ''))
    Move-Item -Force -LiteralPath "$switchFile.tmp" -Destination $switchFile
    $title += " $(Get-Label $words[0]) turned $($words[1])."
  }
} elseif ($words.Count -ne 0) {
  $title += ' usage: /silverback:guard [push|delete|history|files] [on|off], /silverback:guard verify [on|observe|off].'
}

$reason = $title
foreach ($name in $switches) { $reason += '\n' + (Get-Line $name) }
[Console]::Out.WriteLine('{"decision":"block","reason":"' + $reason + '"}')
exit 0
