# install.ps1 — deploys rrun + shell-boundary class fixes on Windows + WSL.
# Idempotent: safe to re-run; existing settings are respected, not clobbered.
# Requires: Windows 10/11, WSL with a default Linux distro, Git Bash (for the bash shim).
# Pure-Linux machines: skip this; just copy bin/rrun to ~/.local/bin and chmod +x.
$ErrorActionPreference = 'Stop'
$repo = $PSScriptRoot

function ToWslPath([string]$p) {
  $r = $p -replace '\\', '/'
  if ($r -match '^([A-Za-z]):(.*)$') { return "/mnt/$($Matches[1].ToLower())$($Matches[2])" }
  return $r
}

Write-Host '[1/5] WSL core -> ~/.local/bin/rrun'
$srcWsl = ToWslPath (Join-Path $repo 'bin\rrun')
$sh = 'mkdir -p "$HOME/.local/bin" && tr -d ''\r'' < "{0}" > "$HOME/.local/bin/rrun" && chmod +x "$HOME/.local/bin/rrun" && bash -n "$HOME/.local/bin/rrun"' -f $srcWsl
wsl.exe -e sh -c $sh
if ($LASTEXITCODE -ne 0) { throw 'WSL core install failed (is a WSL distro installed and running?)' }

Write-Host '[2/5] Windows shims -> %USERPROFILE%\.local\bin'
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

Write-Host '[3/5] Git Bash profile (~/.bashrc, ~/.bash_profile)'
$marker  = '# >>> claude-shell-boundary >>>'
$rc      = Join-Path $env:USERPROFILE '.bashrc'
$snippet = (Get-Content -Raw (Join-Path $repo 'profile\bashrc-snippet.sh')) -replace "`r", ''
if (-not (Test-Path $rc) -or ((Get-Content -Raw $rc) -notlike "*$marker*")) {
  [IO.File]::AppendAllText($rc, "`n" + $snippet)
  Write-Host '  appended boundary-fix block to ~/.bashrc'
} else {
  Write-Host '  ~/.bashrc already has the boundary-fix block'
}
$bp = Join-Path $env:USERPROFILE '.bash_profile'
if (-not (Test-Path $bp)) {
  [IO.File]::WriteAllText($bp, "[ -f ~/.bashrc ] && . ~/.bashrc`n")
  Write-Host '  created ~/.bash_profile -> sources ~/.bashrc'
}

Write-Host '[4/5] User environment variables'
$wantEnv = ($env:USERPROFILE -replace '\\', '/') + '/.bashrc'
$curBashEnv = [Environment]::GetEnvironmentVariable('BASH_ENV', 'User')
if (-not $curBashEnv) {
  [Environment]::SetEnvironmentVariable('BASH_ENV', $wantEnv, 'User')
  Write-Host "  BASH_ENV=$wantEnv  (loads wrappers into non-interactive bash, e.g. Claude's Bash tool)"
} elseif ($curBashEnv -ne $wantEnv) {
  Write-Warning "BASH_ENV already set to '$curBashEnv' — left untouched; source $wantEnv from it manually."
}
if (-not [Environment]::GetEnvironmentVariable('PYTHONIOENCODING', 'User')) {
  [Environment]::SetEnvironmentVariable('PYTHONIOENCODING', 'utf-8', 'User')
  Write-Host '  PYTHONIOENCODING=utf-8'
}

Write-Host '[5/5] Verify (dry-run through every entry point)'
wsl.exe -e sh -c '"$HOME/.local/bin/rrun" -n examplehost -c hostname'
if ($LASTEXITCODE -ne 0) { throw 'WSL core verify failed' }
& (Join-Path $dest 'rrun.ps1') -n examplehost -c hostname
if ($LASTEXITCODE -ne 0) { throw 'PowerShell shim verify failed' }

Write-Host ''
Write-Host 'Installed. Restart terminals / Claude Code sessions so PATH, BASH_ENV and'
Write-Host 'PYTHONIOENCODING take effect. Smoke test against a real host:'
Write-Host '  rrun -s bash <linux-host> -c "hostname"     (Linux target)'
Write-Host '  rrun <windows-host> -c "Get-Date"           (Windows target, default -s ps)'
Write-Host '  rrun local -c "Get-Date"                    (this machine, no ssh)'
