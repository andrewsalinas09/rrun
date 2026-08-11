# install-hook.ps1 -- deploy the rrun boundary advisory and wire it into a Claude
# Code settings.json. Split out of install.ps1 so it can be tested in isolation
# against throwaway config dirs: this is the one part of the install that edits a
# file the user owns and may have hand-tuned, so "it didn't clobber anything" has
# to be a regression test, not an intention.
#
# Contract:
#   * merges -- never rewrites settings.json wholesale; unrelated keys, and other
#     people's hooks (including other PreToolUse entries), survive untouched
#   * idempotent -- identifies its own entry by the script name in the command,
#     so re-running updates in place instead of stacking duplicates
#   * backs up to settings.json.rrun-bak before touching an existing file
#   * refuses to guess on malformed JSON: throws with the backup path
#
# history: v1.0 2026-08-10 created (external-review round 10).
param(
  [Parameter(Mandatory = $true)][string]$ConfigDir,
  [Parameter(Mandatory = $true)][string]$RepoRoot,
  [switch]$Quiet
)
$ErrorActionPreference = 'Stop'

$hookDir = Join-Path $ConfigDir 'hooks'
New-Item -ItemType Directory -Force -Path $hookDir | Out-Null

# launcher must land LF -- Git Bash chokes on a CRLF shebang. .py tolerates both.
$launcher = (Get-Content -Raw (Join-Path $RepoRoot 'hooks\rrun-boundary-warn.sh')) -replace "`r", ''
[IO.File]::WriteAllText((Join-Path $hookDir 'rrun-boundary-warn.sh'), $launcher)
Copy-Item (Join-Path $RepoRoot 'hooks\rrun-boundary-warn.py') (Join-Path $hookDir 'rrun-boundary-warn.py') -Force

$settingsPath = Join-Path $ConfigDir 'settings.json'
# ${CLAUDE_CONFIG_DIR:-$HOME/.claude} so the wired command follows the same rule
# at runtime that the installer used at install time -- no absolute path baked in.
$hookCmd = 'bash "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/hooks/rrun-boundary-warn.sh"'

$settings = [pscustomobject]@{}
if (Test-Path $settingsPath) {
  Copy-Item $settingsPath "$settingsPath.rrun-bak" -Force
  $raw = (Get-Content -Raw $settingsPath).Trim()
  if ($raw) {
    try { $settings = $raw | ConvertFrom-Json } catch {
      throw "settings.json is not valid JSON ($settingsPath) -- fix or move it, then re-run. Backup: $settingsPath.rrun-bak"
    }
  }
}

function Get-Prop($o, $n) { if ($o.PSObject.Properties.Name -contains $n) { $o.$n } else { $null } }
function Set-Prop($o, $n, $v) {
  if ($o.PSObject.Properties.Name -contains $n) { $o.$n = $v }
  else { $o | Add-Member -NotePropertyName $n -NotePropertyValue $v }
}

$entry = [pscustomobject]@{
  matcher = 'Bash|PowerShell'
  hooks   = @([pscustomobject]@{ type = 'command'; shell = 'bash'; command = $hookCmd; timeout = 10 })
}

$hooksObj = Get-Prop $settings 'hooks'
if (-not $hooksObj) { $hooksObj = [pscustomobject]@{} }
$pre = @(@(Get-Prop $hooksObj 'PreToolUse') | Where-Object { $_ })
# Drop only OUR previous entry (self-updating); everyone else's stays.
$kept = @($pre | Where-Object {
  -not (@($_.hooks) | Where-Object { "$($_.command)" -match 'rrun-boundary-warn' })
})
Set-Prop $hooksObj 'PreToolUse' ([object[]]($kept + $entry))
Set-Prop $settings 'hooks' $hooksObj

# -Depth 100: the default of 2 silently truncates nested settings into strings.
[IO.File]::WriteAllText($settingsPath, ($settings | ConvertTo-Json -Depth 100))
if (-not $Quiet) { Write-Host "  hook installed -> $hookDir" }
