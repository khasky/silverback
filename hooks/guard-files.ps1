# PowerShell twin of guard-files.sh for agents that run Windows hooks through
# PowerShell (Codex): the same paths, the same messages. scripts/lint.py runs
# both scripts against the same edits.
$ErrorActionPreference = 'Stop'

$raw = [Console]::In.ReadToEnd()
$codex = $raw -match '"turn_id"\s*:'
try {
  $payload = $raw | ConvertFrom-Json
} catch {
  exit 0
}
$toolInput = $payload.tool_input
if ($toolInput -is [string]) { $toolInput = $toolInput | ConvertFrom-Json }

# The edited paths: file_path, notebook_path or (Copilot CLI) path of an edit tool, or every
# "*** Add/Update/Delete File:" and "*** Move to:" line of an apply_patch.
$paths = @()
foreach ($name in 'file_path', 'notebook_path', 'path') {
  if ($toolInput.$name) { $paths += [string]$toolInput.$name }
}
if ($toolInput.command) {
  foreach ($match in [regex]::Matches([string]$toolInput.command, '(?m)^\*\*\* ((Add|Update|Delete) File|Move to): (.+?)\r?$')) {
    $paths += $match.Groups[3].Value
  }
}
$paths = @($paths | ForEach-Object { $_ -replace '\\', '/' })
if ($paths.Count -eq 0) { exit 0 }

$userHome = if ($env:USERPROFILE) { $env:USERPROFILE } else { $env:HOME }
$switchFile = Join-Path $userHome '.silverback/guard'
if ((Test-Path -LiteralPath $switchFile) -and @(Get-Content -LiteralPath $switchFile) -contains 'files=off') { exit 0 }

# Instruction files every agent reads, agent settings and hooks, the git and
# CI gates, and the agents' memory stores.
$protected = '(^|/)(AGENTS(\.override)?\.md|CLAUDE(\.local)?\.md|GEMINI\.md|QWEN\.md|MEMORY\.md|\.gitignore|\.pre-commit-config\.ya?ml|lefthook\.ya?ml|copilot-instructions\.md)$|(^|/)\.(claude|codex|gemini|qwen|cursor|kimi-code|devin|windsurf)/(settings[^/]*\.json|config\.toml|hooks[^/]*|rules/|agents/|policies/)|(^|/)\.(husky|githooks)/|(^|/)\.github/(workflows|hooks)/|(^|/)\.claude/projects/[^/]+/memory/|(^|/)\.(codex|qwen)/(memories|projects/[^/]+/memory)/'
$hit = $paths | Where-Object { [regex]::IsMatch($_, $protected, 'IgnoreCase') } | Select-Object -First 1
if (-not $hit) { exit 0 }
$hit = $hit -replace '"', ''

$message = "silverback: this edits $hit, a file that steers or gates the agent (instructions, agent settings, hooks, CI, .gitignore) or holds its memory. Approve only if you asked for this edit."
$decision = 'ask'
if ($raw -match '"client_type"\s*:\s*"kimi') {
  # Kimi Code documents deny and no ask.
  $decision = 'deny'
  $message += ' Kimi Code cannot ask for approval, so the edit is blocked: the user makes it.'
} elseif ($codex) {
  $decision = 'deny'
  $message += ' Codex cannot ask for approval, so the edit is blocked: the user makes it, or turns this check off with /silverback:guard files off.'
}
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
# Copilot CLI (its hooks file sets SILVERBACK_AGENT) reads top-level fields.
if ($env:SILVERBACK_AGENT -eq 'copilot') {
  [Console]::Out.WriteLine((@{ permissionDecision = $decision; permissionDecisionReason = $message } | ConvertTo-Json -Compress))
  exit 0
}
[Console]::Out.WriteLine('{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"' + $decision + '","permissionDecisionReason":"' + $message + '"}}')
exit 0
