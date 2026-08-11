# uninstall.ps1 -- reverses install.ps1, loudly. Removes the WSL core, the
# Windows shims, the ~/.rrun env file, the marker-managed shell blocks, the
# rrun-set user environment variables, and the Claude Code boundary hook
# (settings.json is MERGED, never clobbered -- only rrun's own entry is
# removed, with a backup, exactly mirroring hooks/install-hook.ps1).
#
# What it deliberately does NOT touch:
#   * BASH_ENV / PYTHONIOENCODING values that rrun did not set (left with a
#     warning -- install.ps1 never clobbered them either)
#   * ~/.bashrc / ~/.bash_profile beyond the marker block (user files)
#   * %USERPROFILE%\.local\bin and its PATH entry if OTHER files live there
#     (the directory and PATH entry are removed only when rrun was the sole
#     occupant)
#
# Finishes with a self-check and exits non-zero if anything rrun-shaped
# survived. Re-running after a partial failure is safe (idempotent).
#
# history: v1.0 2026-08-11 created -- also enables clean A/B "tool absent"
#          experiment arms (docs/agent-adoption-experiments.md).
param(
  [switch]$KeepClaudeHook,  # leave the advisory hook wired
  [switch]$KeepEnv          # leave user env vars untouched
)
$ErrorActionPreference = 'Stop'

Write-Host '[1/6] WSL core'
wsl.exe -e sh -c 'rm -f "$HOME/.local/bin/rrun"' 2>$null
if ($LASTEXITCODE -eq 0) { Write-Host '  removed ~/.local/bin/rrun (WSL)' }
else { Write-Warning 'WSL unavailable -- ~/.local/bin/rrun (WSL) not removed' }

Write-Host '[2/6] Windows shims'
$dest = Join-Path $env:USERPROFILE '.local\bin'
foreach ($f in 'rrun', 'rrun.ps1') {
  $p = Join-Path $dest $f
  if (Test-Path $p) { Remove-Item -Force $p; Write-Host "  removed $p" }
}
if ((Test-Path $dest) -and -not (Get-ChildItem -Force $dest)) {
  Remove-Item -Force $dest
  $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
  $kept = @(($userPath -split ';') | Where-Object { $_ -and ($_.TrimEnd('\') -ne $dest.TrimEnd('\')) })
  if (($userPath -split ';') -contains $dest) {
    [Environment]::SetEnvironmentVariable('Path', ($kept -join ';'), 'User')
    Write-Host "  removed empty $dest and its user-PATH entry"
  }
} elseif (Test-Path $dest) {
  Write-Host "  left $dest and its PATH entry (other files live there)"
}

Write-Host '[3/6] Boundary env file'
$rrunDir = Join-Path $env:USERPROFILE '.rrun'
if (Test-Path $rrunDir) { Remove-Item -Recurse -Force $rrunDir; Write-Host '  removed ~/.rrun' }

Write-Host '[4/6] Shell integration marker blocks'
$blockPat = '(?s)\n?\n?# >>> claude-shell-boundary >>>.*?# <<< claude-shell-boundary <<<\n?'
foreach ($f in '.bashrc', '.bash_profile') {
  $p = Join-Path $env:USERPROFILE $f
  if (-not (Test-Path $p)) { continue }
  $txt = (Get-Content -Raw $p) -replace "`r", ''
  if ($txt -match '# >>> claude-shell-boundary >>>') {
    $txt = [regex]::Replace($txt, $blockPat, "`n")
    [IO.File]::WriteAllText($p, $txt.TrimEnd("`n") + "`n")
    Write-Host "  removed marker block from ~/$f"
  }
}

Write-Host '[5/6] User environment variables'
if ($KeepEnv) {
  Write-Host '  skipped (-KeepEnv)'
} else {
  $wantEnv = ($env:USERPROFILE -replace '\\', '/') + '/.rrun/bash_env'
  $cur = [Environment]::GetEnvironmentVariable('BASH_ENV', 'User')
  if ($cur -eq $wantEnv) {
    [Environment]::SetEnvironmentVariable('BASH_ENV', $null, 'User')
    Write-Host '  removed BASH_ENV'
  } elseif ($cur) {
    Write-Warning "BASH_ENV is '$cur' (not rrun's value) -- left untouched"
  }
  $pio = [Environment]::GetEnvironmentVariable('PYTHONIOENCODING', 'User')
  if ($pio -eq 'utf-8') {
    # install.ps1 only ever sets this when it was absent, so utf-8 is almost
    # certainly ours -- but it cannot be proven; -KeepEnv preserves it.
    [Environment]::SetEnvironmentVariable('PYTHONIOENCODING', $null, 'User')
    Write-Host '  removed PYTHONIOENCODING (was utf-8; use -KeepEnv to preserve)'
  } elseif ($pio) {
    Write-Warning "PYTHONIOENCODING is '$pio' (not rrun's value) -- left untouched"
  }
}

Write-Host '[6/6] Claude Code boundary hook'
if ($KeepClaudeHook) {
  Write-Host '  skipped (-KeepClaudeHook)'
} else {
  $cfgDir = if ($env:CLAUDE_CONFIG_DIR) { $env:CLAUDE_CONFIG_DIR } else { Join-Path $env:USERPROFILE '.claude' }
  $settingsPath = Join-Path $cfgDir 'settings.json'
  if (Test-Path $settingsPath) {
    Copy-Item $settingsPath "$settingsPath.rrun-bak" -Force
    $raw = (Get-Content -Raw $settingsPath).Trim()
    $settings = if ($raw) {
      try { $raw | ConvertFrom-Json } catch {
        throw "settings.json is not valid JSON ($settingsPath) -- fix or move it, then re-run. Backup: $settingsPath.rrun-bak"
      }
    } else { [pscustomobject]@{} }
    $hooksObj = if ($settings.PSObject.Properties.Name -contains 'hooks') { $settings.hooks } else { $null }
    if ($hooksObj -and ($hooksObj.PSObject.Properties.Name -contains 'PreToolUse')) {
      $kept = @(@($hooksObj.PreToolUse) | Where-Object {
        $_ -and -not (@($_.hooks) | Where-Object { "$($_.command)" -match 'rrun-boundary-warn' })
      })
      if ($kept.Count) { $hooksObj.PreToolUse = [object[]]$kept }
      else { $hooksObj.PSObject.Properties.Remove('PreToolUse') }
      if (-not $hooksObj.PSObject.Properties.Name) { $settings.PSObject.Properties.Remove('hooks') }
      [IO.File]::WriteAllText($settingsPath, ($settings | ConvertTo-Json -Depth 100))
      Write-Host "  removed rrun entry from settings.json (backup: settings.json.rrun-bak)"
    }
  }
  foreach ($f in 'rrun-boundary-warn.sh', 'rrun-boundary-warn.py') {
    $p = Join-Path (Join-Path $cfgDir 'hooks') $f
    if (Test-Path $p) { Remove-Item -Force $p; Write-Host "  removed $p" }
  }
}

Write-Host ''
Write-Host '[verify] nothing rrun-shaped should remain'
$fail = 0
function Check([string]$name, [bool]$ok) {
  if ($ok) { Write-Host "  PASS  $name" } else { Write-Host "  FAIL  $name"; $script:fail++ }
}
wsl.exe -e sh -c 'test ! -f "$HOME/.local/bin/rrun"' 2>$null
Check 'WSL core gone' ($LASTEXITCODE -eq 0)
Check 'Windows shims gone' (-not (Test-Path (Join-Path $dest 'rrun')) -and -not (Test-Path (Join-Path $dest 'rrun.ps1')))
Check '~/.rrun gone' (-not (Test-Path $rrunDir))
$rc = Join-Path $env:USERPROFILE '.bashrc'
Check 'bashrc block gone' (-not ((Test-Path $rc) -and ((Get-Content -Raw $rc) -match 'claude-shell-boundary')))
if (-not $KeepClaudeHook) {
  $cfgDir = if ($env:CLAUDE_CONFIG_DIR) { $env:CLAUDE_CONFIG_DIR } else { Join-Path $env:USERPROFILE '.claude' }
  $sp = Join-Path $cfgDir 'settings.json'
  Check 'settings.json entry gone' (-not ((Test-Path $sp) -and ((Get-Content -Raw $sp) -match 'rrun-boundary-warn')))
  Check 'hook files gone' (-not (Test-Path (Join-Path $cfgDir 'hooks\rrun-boundary-warn.sh')))
}

Write-Host ''
if ($fail -eq 0) {
  Write-Host 'Uninstalled. Restart terminals / Claude Code sessions -- PATH, BASH_ENV and'
  Write-Host 'PYTHONIOENCODING changes are process-start environment. Reinstall any time'
  Write-Host 'with: .\install.ps1'
} else {
  Write-Host "$fail item(s) survived -- see FAIL lines above."
}
exit $fail
