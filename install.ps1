# install.ps1 — deploys rrun + shell-boundary class fixes on Windows + WSL.
# Idempotent AND self-updating: rerunning refreshes every installed artifact,
# including the ~/.rrun/bash_env file and the sourcing block in ~/.bashrc.
# Requires: Windows 10/11, WSL with a default Linux distro, Git Bash (for the bash shim).
# Pure-Linux machines: skip this; just copy bin/rrun to ~/.local/bin and chmod +x.
$ErrorActionPreference = 'Stop'
$repo = $PSScriptRoot

function ToWslPath([string]$p) {
  $r = $p -replace '\\', '/'
  if ($r -match '^([A-Za-z]):(.*)$') { return "/mnt/$($Matches[1].ToLower())$($Matches[2])" }
  return $r
}

Write-Host '[1/6] WSL core -> ~/.local/bin/rrun'
$srcWsl = ToWslPath (Join-Path $repo 'bin\rrun')
# the repo path rides as $1 (positional data), never interpolated into shell
# source — a path containing $ ( ) etc. must not be parsed by the WSL shell
$sh = 'mkdir -p "$HOME/.local/bin" && tr -d ''\r'' < "$1" > "$HOME/.local/bin/rrun" && chmod +x "$HOME/.local/bin/rrun" && bash -n "$HOME/.local/bin/rrun"'
wsl.exe -e sh -c $sh sh $srcWsl
if ($LASTEXITCODE -ne 0) { throw 'WSL core install failed (is a WSL distro installed and running?)' }

Write-Host '[2/6] Windows shims -> %USERPROFILE%\.local\bin'
$dest = Join-Path $env:USERPROFILE '.local\bin'
New-Item -ItemType Directory -Force -Path $dest | Out-Null
# bash shim must land with LF endings and no BOM or Git Bash chokes on the shebang
$bashShim = (Get-Content -Raw (Join-Path $repo 'bin\rrun-shim.bash')) -replace "`r", ''
[IO.File]::WriteAllText((Join-Path $dest 'rrun'), $bashShim)
Copy-Item (Join-Path $repo 'bin\rrun.ps1') (Join-Path $dest 'rrun.ps1') -Force

$userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
if (($userPath -split ';') -notcontains $dest) {
  [Environment]::SetEnvironmentVariable('Path', "$userPath;$dest", 'User')
  Write-Host "  added $dest to user PATH (takes effect in new sessions)"
}

Write-Host '[3/6] Boundary env file -> ~/.rrun/bash_env (always refreshed)'
$rrunDir = Join-Path $env:USERPROFILE '.rrun'
New-Item -ItemType Directory -Force -Path $rrunDir | Out-Null
$envFile = Join-Path $rrunDir 'bash_env'
$snippet = (Get-Content -Raw (Join-Path $repo 'profile\bash_env.sh')) -replace "`r", ''
[IO.File]::WriteAllText($envFile, $snippet)

Write-Host '[4/6] Shell integration (~/.bashrc, ~/.bash_profile)'
$srcLine = '[ -f "$HOME/.rrun/bash_env" ] && . "$HOME/.rrun/bash_env"'
$block = "# >>> claude-shell-boundary >>>`n$srcLine`n# <<< claude-shell-boundary <<<"
$blockPat = '(?s)# >>> claude-shell-boundary >>>.*?# <<< claude-shell-boundary <<<'
$rc = Join-Path $env:USERPROFILE '.bashrc'
if (Test-Path $rc) {
  $txt = (Get-Content -Raw $rc) -replace "`r", ''
  if ($txt -match $blockPat) {
    # replace between markers so reruns propagate updates (never treat the
    # marker's mere presence as "already current")
    $txt = [regex]::Replace($txt, $blockPat, [Text.RegularExpressions.MatchEvaluator] { $block })
  } else {
    $txt = $txt.TrimEnd("`n") + "`n`n$block`n"
  }
} else {
  $txt = "$block`n"
}
[IO.File]::WriteAllText($rc, $txt)
$bp = Join-Path $env:USERPROFILE '.bash_profile'
if (-not (Test-Path $bp)) {
  [IO.File]::WriteAllText($bp, "[ -f ~/.bashrc ] && . ~/.bashrc`n")
  Write-Host '  created ~/.bash_profile -> sources ~/.bashrc'
} elseif (((Get-Content -Raw $bp) -notmatch '\.bashrc') -and ((Get-Content -Raw $bp) -notmatch '\.rrun')) {
  [IO.File]::AppendAllText($bp, "`n$srcLine`n")
  Write-Host '  ~/.bash_profile did not source ~/.bashrc — appended bash_env source line'
}

Write-Host '[5/6] User environment variables'
$wantEnv = ($env:USERPROFILE -replace '\\', '/') + '/.rrun/bash_env'
$oldDefault = ($env:USERPROFILE -replace '\\', '/') + '/.bashrc'
$curBashEnv = [Environment]::GetEnvironmentVariable('BASH_ENV', 'User')
if ((-not $curBashEnv) -or ($curBashEnv -eq $oldDefault)) {
  [Environment]::SetEnvironmentVariable('BASH_ENV', $wantEnv, 'User')
  Write-Host "  BASH_ENV=$wantEnv  (loads wrappers into non-interactive bash, e.g. Claude's Bash tool)"
} elseif ($curBashEnv -ne $wantEnv) {
  Write-Warning "BASH_ENV already set to '$curBashEnv' — left untouched; source $wantEnv from it manually."
}
if (-not [Environment]::GetEnvironmentVariable('PYTHONIOENCODING', 'User')) {
  [Environment]::SetEnvironmentVariable('PYTHONIOENCODING', 'utf-8', 'User')
  Write-Host '  PYTHONIOENCODING=utf-8'
}

Write-Host '[6/6] Verify — full smoke suite'
& (Join-Path $repo 'test.ps1')
if ($LASTEXITCODE -ne 0) { throw "verification failed: $LASTEXITCODE test(s) did not pass" }

Write-Host ''
Write-Host 'Installed. Restart terminals / Claude Code sessions so PATH, BASH_ENV and'
Write-Host 'PYTHONIOENCODING take effect. Smoke test against a real host:'
Write-Host '  rrun -s bash <linux-host> -c "hostname"     (Linux target)'
Write-Host '  rrun <windows-host> -c "Get-Date"           (Windows target, default -s ps)'
Write-Host '  rrun local -c "Get-Date"                    (this machine, no ssh)'
