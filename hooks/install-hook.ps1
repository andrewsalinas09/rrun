# install-hook.ps1 -- deploy the rrun boundary advisory and wire it into a Claude
# Code settings.json. Split out of install.ps1 so it can be tested in isolation
# against throwaway config dirs: this is the one part of the install that edits a
# file the user owns and may have hand-tuned, so "it didn't clobber anything" has
# to be a regression test, not an intention.
#
# Contract:
#   * merges -- never rewrites settings.json wholesale; unrelated keys, and other
#     people's hooks (including other PreToolUse entries, and other handlers
#     sharing OUR matcher group), survive untouched
#   * idempotent -- identifies its own handler by EXACT command equality, so
#     re-running updates in place instead of stacking duplicates, and a foreign
#     handler that merely mentions 'rrun-boundary-warn' is never treated as ours
#   * backs up to settings.json.rrun-bak only AFTER the existing file parses,
#     so a corrupt settings.json can never overwrite the last good backup
#   * refuses to guess on malformed JSON: throws, pointing at any prior backup
#   * rewritten JSON is re-parsed from a temp file, then atomically replaces
#     settings.json
#
# history: v1.0 2026-08-10 created (external-review round 10).
#          v1.1 2026-08-11 (round 11, findings 2+3) self-update filters
#          handlers individually instead of dropping any group containing a
#          substring match (which deleted other people's handlers from a shared
#          group); backup moved after validation; temp-file + re-parse + atomic
#          replace on write. Removal counterpart: uninstall-hook.ps1.
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
  $raw = (Get-Content -Raw $settingsPath).Trim()
  if ($raw) {
    try { $settings = $raw | ConvertFrom-Json } catch {
      # do NOT refresh the backup here: settings.json is corrupt, and copying
      # it over .rrun-bak would destroy the last known-good copy at exactly
      # the moment the user needs it
      $note = if (Test-Path "$settingsPath.rrun-bak") { " The previous good backup at $settingsPath.rrun-bak was left untouched." } else { '' }
      throw "settings.json is not valid JSON ($settingsPath) -- fix or move it, then re-run.$note"
    }
  }
  Copy-Item $settingsPath "$settingsPath.rrun-bak" -Force
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
# Drop only OUR previous handler (self-updating), by exact command identity,
# filtering handler-by-handler: a group that also carries someone else's
# handler keeps that handler (and the group); only a group left empty goes.
$kept = @(foreach ($group in $pre) {
  $foreign = @(@($group.hooks) | Where-Object { "$($_.command)" -cne $hookCmd })
  if ($foreign.Count -eq @($group.hooks).Count) { $group }
  elseif ($foreign.Count) { $group.hooks = [object[]]$foreign; $group }
})
Set-Prop $hooksObj 'PreToolUse' ([object[]]($kept + $entry))
Set-Prop $settings 'hooks' $hooksObj

# -Depth 100: the default of 2 silently truncates nested settings into strings.
# write -> re-parse -> atomic replace: a truncated write must never land.
$tmp = "$settingsPath.rrun-tmp"
[IO.File]::WriteAllText($tmp, ($settings | ConvertTo-Json -Depth 100))
$null = (Get-Content -Raw $tmp) | ConvertFrom-Json
Move-Item -Force $tmp $settingsPath
if (-not $Quiet) { Write-Host "  hook installed -> $hookDir" }
