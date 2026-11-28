# PowerShell twin of compact.sh: the same instructions for the compaction
# summary, nothing for Codex.
$ErrorActionPreference = 'Stop'
$raw = [Console]::In.ReadToEnd()
if ($raw -match '"turn_id"\s*:') { exit 0 }
# /silverback:rules off writes rules=off to the switch file: no ruleset then.
$userHome = if ($env:USERPROFILE) { $env:USERPROFILE } else { $env:HOME }
$switchFile = Join-Path $userHome '.silverback/guard'
if ((Test-Path -LiteralPath $switchFile) -and (Get-Content -LiteralPath $switchFile) -ccontains 'rules=off') { exit 0 }
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
[Console]::Out.WriteLine('Keep in the summary, verbatim where it is a command, path or error: the task as the user stated it and every constraint or correction they gave; the files changed; each check run with its exact command and result, and each check not run; the open items. Record a finished step as claimed, with the command that proves it, so the next context re-runs that command before repeating the claim.')
