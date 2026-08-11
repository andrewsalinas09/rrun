# uninstall.ps1 -- reverses install.ps1, loudly. Removes the WSL core, the
# Windows shims, the ~/.rrun dir, the marker-managed shell blocks, and the
# Claude Code boundary hook (settings.json is MERGED, never clobbered -- only
# rrun's own handler is removed, individually, via hooks/uninstall-hook.ps1).
#
# Ownership comes from the install-state MANIFEST (~/.rrun/install-state.json,
# written by install.ps1 BEFORE it modified anything): a user env var is
# restored to its recorded pre-install value only if its current value still
# equals what rrun set -- changed since install means the user's change wins,
# with a warning. The PATH entry and a created ~/.bash_profile are removed only
# if the manifest says rrun created them. Without a manifest (pre-2.7.0
# install), only things PROVABLY rrun's are removed: files under rrun-owned
# paths, marker-delimited blocks, and a BASH_ENV whose value names rrun's own
# ~/.rrun/bash_env; unprovable state (PYTHONIOENCODING=utf-8, the PATH entry)
# is left with loud instructions instead of guessed at.
#
# Finishes with a self-check and exits non-zero if anything rrun-shaped
# survived. Re-running after a partial failure is safe (idempotent); the
# manifest is deleted LAST so a failed run can still use it on retry.
#
# history: v1.0 2026-08-11 created -- also enables clean A/B "tool absent"
#          experiment arms (docs/agent-adoption-experiments.md).
#          v2.0 2026-08-11 (external-review round 11, finding 1) manifest-based
#          ownership: v1.0 reconstructed ownership from current values, which
#          deleted a pre-existing user PYTHONIOENCODING=utf-8, removed a
#          pre-existing PATH entry once the dir emptied, could not identify a
#          .bash_profile the installer created, and targeted the current WSL
#          distro/config dir rather than the installed-into ones. Hook removal
#          moved to hooks/uninstall-hook.ps1 (regression-tested; filters
#          handlers individually by exact identity).
param(
  [switch]$KeepClaudeHook,  # leave the advisory hook wired
  [switch]$KeepEnv          # leave user env vars untouched
)
$ErrorActionPreference = 'Stop'
$repo = $PSScriptRoot
. (Join-Path $repo 'lib\install-state.ps1')

$statePath = Get-RrunStatePath
$state = Read-RrunState $statePath
if ($state) {
  Write-Host "manifest: $statePath (installed $($state.installedAt))"
} else {
  Write-Warning ('no install-state manifest found (pre-2.7.0 install, or already removed). ' +
    'Marker/path-provable items will be removed; env vars and the PATH entry that cannot ' +
    'be proven rrun''s will be left with instructions.')
}

Write-Host '[1/6] WSL core'
# target the distro the core was installed INTO (the default can change later);
# fall back to the current default when unknown
$distro = if ($state -and $state.wslDistro) { "$($state.wslDistro)" } else { '' }
if ($distro) { Invoke-Native { wsl.exe -d $distro -e sh -c 'rm -f "$HOME/.local/bin/rrun"' 2>$null } }
if (-not $distro -or $LASTEXITCODE -ne 0) {
  if ($distro) { Write-Warning "distro '$distro' (from manifest) unreachable -- trying the default distro" }
  Invoke-Native { wsl.exe -e sh -c 'rm -f "$HOME/.local/bin/rrun"' 2>$null }
}
if ($LASTEXITCODE -eq 0) { Write-Host '  removed ~/.local/bin/rrun (WSL)' }
else { Write-Warning 'WSL unavailable -- ~/.local/bin/rrun (WSL) not removed' }

Write-Host '[2/6] Windows shims'
$dest = Join-Path $env:USERPROFILE '.local\bin'
foreach ($f in 'rrun', 'rrun.ps1') {
  $p = Join-Path $dest $f
  if (Test-Path $p) { Remove-Item -Force $p; Write-Host "  removed $p" }
}
$weAddedPath = [bool]($state -and $state.set.pathEntryAdded)
if ((Test-Path $dest) -and -not (Get-ChildItem -Force $dest)) {
  if ($weAddedPath) {
    Remove-Item -Force $dest
    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    if (($userPath -split ';') -contains $dest) {
      $keep = @(($userPath -split ';') | Where-Object { $_ -and ($_.TrimEnd('\') -ne $dest.TrimEnd('\')) })
      [Environment]::SetEnvironmentVariable('Path', ($keep -join ';'), 'User')
      Write-Host "  removed empty $dest and its user-PATH entry (manifest: rrun added it)"
    } else {
      Write-Host "  removed empty $dest (its PATH entry was already gone)"
    }
  } else {
    # empty dir, but the PATH entry (and so probably the dir) predates rrun --
    # or there is no manifest to prove otherwise. Not ours to delete.
    Write-Host "  left empty $dest and its PATH entry (pre-existing or unproven; remove manually if unwanted)"
  }
} elseif (Test-Path $dest) {
  Write-Host "  left $dest and its PATH entry (other files live there)"
}

Write-Host '[3/6] Shell integration marker blocks'
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
# a .bash_profile the INSTALLER created (manifest-recorded) is deleted outright
# if nothing but its original sourcing line remains; user additions keep it
$bp = Join-Path $env:USERPROFILE '.bash_profile'
if ($state -and $state.set.bashProfileCreated -and (Test-Path $bp)) {
  $rest = ((Get-Content -Raw $bp) -replace "`r", '').Trim()
  if ($rest -eq '' -or $rest -eq '[ -f ~/.bashrc ] && . ~/.bashrc') {
    Remove-Item -Force $bp
    Write-Host '  removed ~/.bash_profile (manifest: rrun created it; no user content)'
  } else {
    Write-Host '  left ~/.bash_profile (rrun created it, but it now has user content)'
  }
}

Write-Host '[4/6] User environment variables'
if ($KeepEnv) {
  Write-Host '  skipped (-KeepEnv)'
} else {
  $wantEnv = ($env:USERPROFILE -replace '\\', '/') + '/.rrun/bash_env'
  function Restore-UserEnv([string]$Name, $Prior, $Set) {
    $cur = [Environment]::GetEnvironmentVariable($Name, 'User')
    $dec = Resolve-EnvRestore $Prior $Set $cur
    switch ($dec.Action) {
      'delete'  { [Environment]::SetEnvironmentVariable($Name, $null, 'User'); Write-Host "  removed $Name (rrun set it; nothing to restore)" }
      'restore' { [Environment]::SetEnvironmentVariable($Name, $dec.Value, 'User'); Write-Host "  restored $Name to its pre-install value '$($dec.Value)'" }
      'leave-changed'  { Write-Warning "$Name is '$cur' -- changed since rrun set it; left untouched" }
      'leave-not-ours' { if ($cur) { Write-Host "  left $Name='$cur' (rrun never set it)" } }
    }
  }
  if ($state) {
    Restore-UserEnv 'BASH_ENV' $state.prior.bashEnv $state.set.bashEnv
    Restore-UserEnv 'PYTHONIOENCODING' $state.prior.pythonIoEncoding $state.set.pythonIoEncoding
  } else {
    # no manifest: remove only what the VALUE proves is rrun's. BASH_ENV
    # pointing into ~/.rrun can only be rrun's (that is rrun's private dir);
    # PYTHONIOENCODING=utf-8 is a value anyone might set -- not provable.
    $cur = [Environment]::GetEnvironmentVariable('BASH_ENV', 'User')
    if ($cur -eq $wantEnv) {
      [Environment]::SetEnvironmentVariable('BASH_ENV', $null, 'User')
      Write-Host '  removed BASH_ENV (points at rrun''s own ~/.rrun/bash_env)'
    } elseif ($cur) {
      Write-Warning "BASH_ENV is '$cur' (not rrun's value) -- left untouched"
    }
    $pio = [Environment]::GetEnvironmentVariable('PYTHONIOENCODING', 'User')
    if ($pio) {
      Write-Warning ("PYTHONIOENCODING is '$pio' -- without a manifest, ownership cannot be proven; left untouched. " +
        "If rrun set it, remove it with: [Environment]::SetEnvironmentVariable('PYTHONIOENCODING', `$null, 'User')")
    }
  }
}

Write-Host '[5/6] Claude Code boundary hook'
if ($KeepClaudeHook) {
  Write-Host '  skipped (-KeepClaudeHook)'
} else {
  # prefer the config dir the hook was actually installed into (manifest);
  # CLAUDE_CONFIG_DIR may have changed since
  $cfgDir = if ($state -and $state.claudeConfigDir) { "$($state.claudeConfigDir)" }
            elseif ($env:CLAUDE_CONFIG_DIR) { $env:CLAUDE_CONFIG_DIR }
            else { Join-Path $env:USERPROFILE '.claude' }
  & (Join-Path $repo 'hooks\uninstall-hook.ps1') -ConfigDir $cfgDir
}

Write-Host '[6/6] Boundary env file + manifest'
# LAST: everything above may still need the manifest on a retried partial run
$rrunDir = Join-Path $env:USERPROFILE '.rrun'
if (Test-Path $rrunDir) { Remove-Item -Recurse -Force $rrunDir; Write-Host '  removed ~/.rrun (env file + install-state manifest)' }

Write-Host ''
Write-Host '[verify] nothing rrun-shaped should remain'
$fail = 0
function Check([string]$name, [bool]$ok) {
  if ($ok) { Write-Host "  PASS  $name" } else { Write-Host "  FAIL  $name"; $script:fail++ }
}
Invoke-Native { wsl.exe -e sh -c 'test ! -f "$HOME/.local/bin/rrun"' 2>$null }
Check 'WSL core gone' ($LASTEXITCODE -eq 0)
Check 'Windows shims gone' (-not (Test-Path (Join-Path $dest 'rrun')) -and -not (Test-Path (Join-Path $dest 'rrun.ps1')))
Check '~/.rrun gone (manifest included)' (-not (Test-Path $rrunDir))
foreach ($f in '.bashrc', '.bash_profile') {
  $p = Join-Path $env:USERPROFILE $f
  Check "$f block gone" (-not ((Test-Path $p) -and ((Get-Content -Raw $p) -match 'claude-shell-boundary')))
}
if (-not $KeepClaudeHook) {
  $sp = Join-Path $cfgDir 'settings.json'
  Check 'settings.json entry gone' (-not ((Test-Path $sp) -and ((Get-Content -Raw $sp) -match 'rrun-boundary-warn')))
  Check 'hook files gone' (-not ((Test-Path (Join-Path $cfgDir 'hooks\rrun-boundary-warn.sh')) -or (Test-Path (Join-Path $cfgDir 'hooks\rrun-boundary-warn.py'))))
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
