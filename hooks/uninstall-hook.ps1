# uninstall-hook.ps1 -- remove the rrun boundary advisory from a Claude Code
# config dir. Mirror of install-hook.ps1, split out of uninstall.ps1 for the
# same reason that was: settings.json is a USER-owned, possibly hand-tuned
# file, so "removal touched nothing else" has to be a regression test
# (tests/hook-install-tests.ps1) against throwaway config dirs, not a promise.
#
# Contract:
#   * ownership is EXACT: a handler is rrun's only if its command equals the
#     one install-hook.ps1 wires -- never a substring match (a foreign handler
#     that merely mentions 'rrun-boundary-warn' is not ours)
#   * handlers are filtered INDIVIDUALLY: a matcher group that also carries
#     someone else's handler keeps that handler and the group; only a group
#     left empty is dropped
#   * settings.json is parsed BEFORE the backup is refreshed, so a corrupt
#     file can never overwrite the last known-good .rrun-bak
#   * the rewritten JSON is re-parsed from a temp file before atomically
#     replacing settings.json
#
# history: v1.0 2026-08-11 created (external-review round 11, finding 2: the
#          old inline removal dropped an entire PreToolUse group when ANY of
#          its handlers substring-matched 'rrun-boundary-warn' -- deleting
#          other people's handlers that shared the group; finding 3: the
#          backup was taken before validation, so a corrupt settings.json
#          clobbered the last good backup exactly when it was needed).
param(
  [Parameter(Mandatory = $true)][string]$ConfigDir,
  [switch]$Quiet
)
$ErrorActionPreference = 'Stop'

# must stay byte-identical to the command install-hook.ps1 wires
$hookCmd = 'bash "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/hooks/rrun-boundary-warn.sh"'

$settingsPath = Join-Path $ConfigDir 'settings.json'
if (Test-Path $settingsPath) {
  $raw = (Get-Content -Raw $settingsPath).Trim()
  $settings = $null
  if ($raw) {
    try { $settings = $raw | ConvertFrom-Json } catch {
      $note = if (Test-Path "$settingsPath.rrun-bak") { " The previous good backup at $settingsPath.rrun-bak was left untouched." } else { '' }
      throw "settings.json is not valid JSON ($settingsPath) -- fix or move it, then re-run.$note"
    }
  }
  $hooksObj = if ($settings -and ($settings.PSObject.Properties.Name -contains 'hooks')) { $settings.hooks } else { $null }
  if ($hooksObj -and ($hooksObj.PSObject.Properties.Name -contains 'PreToolUse')) {
    $changed = $false
    $kept = @(foreach ($group in @($hooksObj.PreToolUse)) {
      if (-not $group) { continue }
      $foreign = @(@($group.hooks) | Where-Object { "$($_.command)" -cne $hookCmd })
      if ($foreign.Count -ne @($group.hooks).Count) {
        $changed = $true
        if ($foreign.Count) { $group.hooks = [object[]]$foreign; $group }
        # else: the group held only our handler -- drop it whole
      } else { $group }
    })
    if ($changed) {
      # backup only now -- the file is known-parseable, so this can never
      # replace a good backup with a corrupt document
      Copy-Item $settingsPath "$settingsPath.rrun-bak" -Force
      if ($kept.Count) { $hooksObj.PreToolUse = [object[]]$kept }
      else { $hooksObj.PSObject.Properties.Remove('PreToolUse') }
      if (-not $hooksObj.PSObject.Properties.Name) { $settings.PSObject.Properties.Remove('hooks') }
      # write -> re-parse -> atomic replace: a truncated write must never land
      $tmp = "$settingsPath.rrun-tmp"
      [IO.File]::WriteAllText($tmp, ($settings | ConvertTo-Json -Depth 100))
      $null = (Get-Content -Raw $tmp) | ConvertFrom-Json
      Move-Item -Force $tmp $settingsPath
      if (-not $Quiet) { Write-Host "  removed rrun entry from settings.json (backup: settings.json.rrun-bak)" }
    }
  }
}

foreach ($f in 'rrun-boundary-warn.sh', 'rrun-boundary-warn.py') {
  $p = Join-Path (Join-Path $ConfigDir 'hooks') $f
  if (Test-Path $p) { Remove-Item -Force $p; if (-not $Quiet) { Write-Host "  removed $p" } }
}
