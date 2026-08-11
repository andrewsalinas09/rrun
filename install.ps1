# install.ps1 -- deploys rrun + shell-boundary class fixes on Windows + WSL.
# Idempotent AND self-updating: rerunning refreshes every installed artifact,
# including the ~/.rrun/bash_env file and the sourcing block in ~/.bashrc.
# Requires: Windows 10/11, WSL with a default Linux distro, Git Bash (for the bash shim).
# Pure-Linux machines: skip this; just copy bin/rrun to ~/.local/bin and chmod +x.
#
# history: 2026-08-11 (2.7.0) ownership manifest written BEFORE any
#          modification (lib/install-state.ps1) so uninstall restores prior
#          state instead of guessing from current values; fresh .bash_profile
#          is marker-managed + manifest-recorded (was untracked, so uninstall
#          could not identify it); native calls (wsl.exe) go through
#          Invoke-Native so 5.1's stderr-throws-under-EAP=Stop class cannot
#          abort the installer before its $LASTEXITCODE check runs.
param(
  # Skip installing the Claude Code boundary-advisory hook (see hooks/). The
  # rest of rrun is unaffected -- the hook is a habit guard, not a dependency.
  [switch]$SkipClaudeHook
)
$ErrorActionPreference = 'Stop'
$repo = $PSScriptRoot
. (Join-Path $repo 'lib\install-state.ps1')

function Find-Python3 {
  # Returns the name of a WORKING python3, or $null. Name lookup alone is not
  # enough: on Windows `python3` is commonly the Microsoft Store stub -- present
  # on PATH, exits 49, prints "Python was not found". So each candidate must
  # actually run and report major version 3.
  foreach ($c in 'python3', 'python', 'py') {
    if (-not (Get-Command $c -ErrorAction SilentlyContinue)) { continue }
    try { & $c -c 'import sys; sys.exit(0 if sys.version_info[0]==3 else 1)' 2>$null } catch { continue }
    if ($LASTEXITCODE -eq 0) { return $c }
  }
  return $null
}

function ToWslPath([string]$p) {
  $r = $p -replace '\\', '/'
  if ($r -match '^([A-Za-z]):(.*)$') { return "/mnt/$($Matches[1].ToLower())$($Matches[2])" }
  return $r
}

Write-Host '[1/8] Ownership manifest -> ~/.rrun/install-state.json'
# Recorded BEFORE anything is modified: uninstall can only restore prior state
# if the prior state was captured while it still existed. On rerun the ORIGINAL
# manifest is kept -- capturing "prior" values now would record rrun's own.
$dest = Join-Path $env:USERPROFILE '.local\bin'
$wantEnv = ($env:USERPROFILE -replace '\\', '/') + '/.rrun/bash_env'
$statePath = Get-RrunStatePath
$state = Read-RrunState $statePath
if (-not $state) {
  $curBashEnv = [Environment]::GetEnvironmentVariable('BASH_ENV', 'User')
  # Upgrade from a pre-manifest install: BASH_ENV already carries rrun's own
  # value, which is certainly not a user prior -- record absence. (Anything
  # else, including the old-default ~/.bashrc value, IS recorded as prior and
  # comes back on uninstall: it cannot be proven to be rrun's doing.)
  if ($curBashEnv -eq $wantEnv) { $curBashEnv = $null }
  $state = New-RrunState `
    -PriorBashEnv $curBashEnv `
    -PriorPythonIoEncoding ([Environment]::GetEnvironmentVariable('PYTHONIOENCODING', 'User')) `
    -PriorPathHadEntry (([Environment]::GetEnvironmentVariable('Path', 'User') -split ';') -contains $dest) `
    -PriorBashrcExisted (Test-Path (Join-Path $env:USERPROFILE '.bashrc')) `
    -PriorBashProfileExisted (Test-Path (Join-Path $env:USERPROFILE '.bash_profile'))
  Write-RrunState $state $statePath
  Write-Host "  recorded pre-install state -> $statePath"
} else {
  Write-Host "  manifest exists (installed $($state.installedAt)) -- prior state preserved"
}

Write-Host '[2/8] WSL core -> ~/.local/bin/rrun'
$srcWsl = ToWslPath (Join-Path $repo 'bin\rrun')
# the repo path rides as $1 (positional data), never interpolated into shell
# source -- a path containing $ ( ) etc. must not be parsed by the WSL shell
$sh = 'mkdir -p "$HOME/.local/bin" && tr -d ''\r'' < "$1" > "$HOME/.local/bin/rrun" && chmod +x "$HOME/.local/bin/rrun" && bash -n "$HOME/.local/bin/rrun"'
Invoke-Native { wsl.exe -e sh -c $sh sh $srcWsl }
if ($LASTEXITCODE -ne 0) { throw 'WSL core install failed (is a WSL distro installed and running?)' }
# record WHICH distro received the core: the default distro can change later,
# and uninstall must target the one actually written to
$distro = (Invoke-Native { wsl.exe -e sh -c 'echo "$WSL_DISTRO_NAME"' } | Select-Object -First 1)
if ($LASTEXITCODE -eq 0 -and $distro) { $state.wslDistro = "$distro".Trim() }

Write-Host '[3/8] Windows shims -> %USERPROFILE%\.local\bin'
New-Item -ItemType Directory -Force -Path $dest | Out-Null
# bash shim must land with LF endings and no BOM or Git Bash chokes on the shebang
$bashShim = (Get-Content -Raw (Join-Path $repo 'bin\rrun-shim.bash')) -replace "`r", ''
[IO.File]::WriteAllText((Join-Path $dest 'rrun'), $bashShim)
Copy-Item (Join-Path $repo 'bin\rrun.ps1') (Join-Path $dest 'rrun.ps1') -Force

$userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
if (($userPath -split ';') -notcontains $dest) {
  [Environment]::SetEnvironmentVariable('Path', "$userPath;$dest", 'User')
  $state.set.pathEntryAdded = $true
  Write-Host "  added $dest to user PATH (takes effect in new sessions)"
}

Write-Host '[4/8] Boundary env file -> ~/.rrun/bash_env (always refreshed)'
$rrunDir = Join-Path $env:USERPROFILE '.rrun'
New-Item -ItemType Directory -Force -Path $rrunDir | Out-Null
$envFile = Join-Path $rrunDir 'bash_env'
$snippet = (Get-Content -Raw (Join-Path $repo 'profile\bash_env.sh')) -replace "`r", ''
[IO.File]::WriteAllText($envFile, $snippet)

Write-Host '[5/8] Shell integration (~/.bashrc, ~/.bash_profile)'
$srcLine = '[ -f "$HOME/.rrun/bash_env" ] && . "$HOME/.rrun/bash_env"'
$block = "# >>> claude-shell-boundary >>>`n$srcLine`n# <<< claude-shell-boundary <<<"
$blockPat = '(?s)# >>> claude-shell-boundary >>>.*?# <<< claude-shell-boundary <<<'
function Set-MarkerBlock([string]$Path) {
  # replace between markers so reruns propagate updates (never treat the
  # marker's mere presence as "already current"); append the block if absent
  if (Test-Path $Path) {
    $txt = (Get-Content -Raw $Path) -replace "`r", ''
    if ($txt -match $blockPat) {
      $txt = [regex]::Replace($txt, $blockPat, [Text.RegularExpressions.MatchEvaluator] { $block })
    } else {
      $txt = $txt.TrimEnd("`n") + "`n`n$block`n"
    }
  } else {
    $txt = "$block`n"
  }
  [IO.File]::WriteAllText($Path, $txt)
}
Set-MarkerBlock (Join-Path $env:USERPROFILE '.bashrc')
$bp = Join-Path $env:USERPROFILE '.bash_profile'
if (-not (Test-Path $bp)) {
  # manifest-recorded so uninstall can identify (and remove) a file WE created;
  # an untracked creation used to survive every uninstall invisibly
  [IO.File]::WriteAllText($bp, "[ -f ~/.bashrc ] && . ~/.bashrc`n")
  Set-MarkerBlock $bp
  $state.set.bashProfileCreated = $true
  Write-Host '  created ~/.bash_profile -> sources ~/.bashrc (manifest-recorded)'
} else {
  # marker-managed block here too -- a content heuristic ("mentions .bashrc")
  # was fooled by comments like "# we do not source .bashrc here". Sourcing
  # bash_env twice (via .bashrc AND here) is harmless: it only defines
  # functions and exports.
  Set-MarkerBlock $bp
}

Write-Host '[6/8] User environment variables'
$oldDefault = ($env:USERPROFILE -replace '\\', '/') + '/.bashrc'
$curBashEnv = [Environment]::GetEnvironmentVariable('BASH_ENV', 'User')
if ((-not $curBashEnv) -or ($curBashEnv -eq $oldDefault) -or ($curBashEnv -eq $wantEnv)) {
  # the old-default (~/.bashrc) value is migrated, but its pre-install value is
  # already in the manifest -- uninstall RESTORES it rather than deleting
  [Environment]::SetEnvironmentVariable('BASH_ENV', $wantEnv, 'User')
  $state.set.bashEnv = $wantEnv
  Write-Host "  BASH_ENV=$wantEnv  (loads wrappers into non-interactive bash, e.g. Claude's Bash tool)"
} else {
  Write-Warning "BASH_ENV already set to '$curBashEnv' -- left untouched; source $wantEnv from it manually."
}
if (-not [Environment]::GetEnvironmentVariable('PYTHONIOENCODING', 'User')) {
  [Environment]::SetEnvironmentVariable('PYTHONIOENCODING', 'utf-8', 'User')
  $state.set.pythonIoEncoding = 'utf-8'
  Write-Host '  PYTHONIOENCODING=utf-8'
}

Write-Host '[7/8] Claude Code boundary hook -> <claude-config>/hooks'
# Advisory PreToolUse hook: warns when a Bash/PowerShell command hand-crosses an
# interpreter boundary rrun already covers. Warn-only, never blocks, and
# "# no-rrun" in a command silences it. See hooks/rrun-boundary-warn.py for why
# a prose rule was not enough.
if ($SkipClaudeHook) {
  Write-Host '  skipped (-SkipClaudeHook)'
} else {
  $cfgDir = if ($env:CLAUDE_CONFIG_DIR) { $env:CLAUDE_CONFIG_DIR } else { Join-Path $env:USERPROFILE '.claude' }
  # merge + deploy lives in hooks/install-hook.ps1 so it can be regression-tested
  # against throwaway config dirs (tests/hook-install-tests.ps1)
  & (Join-Path $repo 'hooks\install-hook.ps1') -ConfigDir $cfgDir -RepoRoot $repo
  # CLAUDE_CONFIG_DIR can change later; uninstall must target the dir actually wired
  $state.claudeConfigDir = $cfgDir

  # Fail LOUD here, not silently at runtime: the launcher deliberately exits 0
  # when no interpreter exists (it must never block a tool call), so a missing
  # dependency would otherwise leave a hook that is silently inert forever.
  $py = Find-Python3
  if ($py) {
    Write-Host "  dependency OK: Python 3 via '$py'"
  } else {
    Write-Warning @'
Python 3 was NOT found, so the boundary hook is installed but INERT.
It fails open by design (it will never block your commands) -- but it will also
never warn you. To activate it, install Python 3 and re-run install.ps1:
  winget install Python.Python.3.13     (or https://python.org/downloads)
Ask Claude to run that for you if you would rather not. Prefer no hook at all?
Re-run with:  .\install.ps1 -SkipClaudeHook
'@
  }
}

# persist what this run actually did (prior.* untouched -- see step 1)
Write-RrunState $state $statePath

Write-Host '[8/8] Verify -- full smoke suite'
& (Join-Path $repo 'test.ps1')
if ($LASTEXITCODE -ne 0) { throw "verification failed: $LASTEXITCODE test(s) did not pass" }

Write-Host ''
Write-Host 'Installed. Restart terminals / Claude Code sessions so PATH, BASH_ENV and'
Write-Host 'PYTHONIOENCODING take effect. Smoke test against a real host:'
Write-Host '  rrun -s bash <linux-host> -c "hostname"     (Linux target)'
Write-Host '  rrun <windows-host> -c "Get-Date"           (Windows target, default -s ps)'
Write-Host '  rrun local -c "Get-Date"                    (this machine, no ssh)'
