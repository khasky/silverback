# PowerShell twin of verify.sh for agents that run Windows hooks through
# PowerShell (Codex): the same events, mark and messages. scripts/lint.py runs
# both scripts through the same session.
param([Parameter(Mandatory = $true)][ValidateSet('edit', 'ran', 'prompt', 'stop')][string]$Step)

$ErrorActionPreference = 'Stop'
$raw = [Console]::In.ReadToEnd()
if ($raw -notmatch '"session_id"\s*:\s*"([A-Za-z0-9_-]+)"') { exit 0 }
$session = $Matches[1]
$userHome = if ($env:USERPROFILE) { $env:USERPROFILE } else { $env:HOME }
$dir = Join-Path $userHome '.silverback/state'
$mark = Join-Path $dir "$session.edited"

switch ($Step) {
  'edit' {
    $null = New-Item -ItemType Directory -Force -Path $dir
    [IO.File]::WriteAllText($mark, '')
  }
  { $_ -in 'ran', 'prompt' } {
    Remove-Item -LiteralPath $mark -Force -ErrorAction SilentlyContinue
  }
  'stop' {
    if (-not (Test-Path -LiteralPath $mark)) { exit 0 }
    # A turn the check already sent back ends the second time.
    if ($raw -match '"stop_hook_active"\s*:\s*true') { exit 0 }
    Remove-Item -LiteralPath $mark -Force
    $switchFile = Join-Path $userHome '.silverback/guard'
    $mode = 'on'
    if (Test-Path -LiteralPath $switchFile) {
      $found = @(Get-Content -LiteralPath $switchFile | Where-Object { $_ -like 'verify=*' })
      if ($found.Count) { $mode = $found[-1].Substring(7) }
    }
    if ($mode -eq 'observe') {
      $stamp = [DateTime]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
      [IO.File]::AppendAllText((Join-Path $userHome '.silverback/verify.log'), "$stamp $session files edited after the last command`n")
    } elseif ($mode -ne 'off' -and $raw -match '"client_type"\s*:\s*"kimi') {
      # Kimi Code documents a Stop block as exit 2 with the reason on stderr.
      [Console]::Error.WriteLine('silverback: files were edited after the last command ran. Run the check that exercises the change and cite its result, or say in the reply which check did not run and why. A change with nothing to run (prose, a comment) says so in one line.')
      exit 2
    } elseif ($mode -ne 'off') {
      [Console]::Out.WriteLine('{"decision":"block","reason":"silverback: files were edited after the last command ran. Run the check that exercises the change and cite its result, or say in the reply which check did not run and why. A change with nothing to run (prose, a comment) says so in one line."}')
    }
  }
}
exit 0
