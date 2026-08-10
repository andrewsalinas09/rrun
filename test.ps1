# test.ps1 — rrun smoke tests over the INSTALLED artifacts. No remote host
# required: dry-runs verify composition through every entry point, host "local"
# verifies real execution. Pass -TargetHost (and optionally -TargetShell) to add
# real ssh round-trips, including the large-payload streaming path.
# Core-logic regressions live separately in tests/core-tests.sh (mocked ssh, CI).
# Exit code = number of failures. This is the gate for the RSI loop.
param(
  [string]$TargetHost = '',
  [string]$TargetShell = 'bash'
)
$ErrorActionPreference = 'Continue'
$repo = $PSScriptRoot
$script:fail = 0

function Check([string]$name, [bool]$ok, [string]$detail = '') {
  if ($ok) { Write-Host "  PASS  $name" }
  else     { Write-Host "  FAIL  $name  $detail"; $script:fail++ }
}
function ToWslPath([string]$p) {
  $r = $p -replace '\\', '/'
  if ($r -match '^([A-Za-z]):(.*)$') { return "/mnt/$($Matches[1].ToLower())$($Matches[2])" }
  return $r
}

Write-Host '[repo sources]'
wsl.exe -e bash -n (ToWslPath (Join-Path $repo 'bin\rrun')) 2>&1 | Out-Null
Check 'core syntax (bash -n)' ($LASTEXITCODE -eq 0)
$shimTxt = Get-Content -Raw (Join-Path $repo 'bin\rrun-shim.bash')
Check 'no hardcoded usernames in shims' (-not (($shimTxt + (Get-Content -Raw (Join-Path $repo 'bin\rrun.ps1'))) -match '/home/[a-z]+[a-z0-9]*/'))

Write-Host '[installed: WSL core]'
$out = (wsl.exe -e sh -c '"$HOME/.local/bin/rrun" -n examplehost -c hostname' 2>&1) -join ' '
Check 'dry-run composes ssh command' ($out -like 'ssh -o BatchMode=yes examplehost powershell*' -and $out -match 'EncodedCommand')
$out = (wsl.exe -e sh -c '"$HOME/.local/bin/rrun" -n -s bash h1,h2 -c true' 2>&1) -join ' '
Check 'multi-hop re-armors per layer' ($out -like 'ssh -o BatchMode=yes h1 ssh*' -and $out -match 'h2' -and $out -match 'base64')

Write-Host '[installed: PowerShell shim]'
$shim = Join-Path $env:USERPROFILE '.local\bin\rrun.ps1'
$out = (& $shim -n examplehost -c hostname 2>&1) -join ' '
Check 'dry-run via ps shim' ($out -like 'ssh -o BatchMode=yes examplehost powershell*')
$out = (& $shim -n local -c 'Write-Output SHOULD-NOT-RUN' 2>&1) -join ' '
Check 'REGRESSION: -n local dry-runs, never executes' ($out -notmatch 'SHOULD-NOT-RUN\s*$' -and $out -match 'EncodedCommand')
$tmpDir = Join-Path $env:TEMP "rrun-test-$PID"
New-Item -ItemType Directory -Force -Path $tmpDir | Out-Null
Set-Content -Path (Join-Path $tmpDir 'deploy.sh') -Value 'echo remote-side-script'
Push-Location $tmpDir
$out = (& $shim -n -s bash examplehost -c './deploy.sh' 2>&1) -join ' '
Pop-Location
Check 'REGRESSION: -c args stay opaque (no /mnt rewrite)' ($out -notmatch '/mnt/')
$out = & $shim local -c 'Write-Output rrun-selftest-ok' 2>&1 | Out-String
Check 'local ps executes' ($out -match 'rrun-selftest-ok')
Check 'local ps output free of CLIXML noise' ($out -notmatch 'CLIXML')
$out = & $shim -s bash local -c 'echo rrun-selftest-ok' 2>&1 | Out-String
Check 'local bash (via WSL) executes' ($out -match 'rrun-selftest-ok')
$payloadOut = & $shim -s bash local -c 'V=$(echo armored); echo "sub:$V"' 2>&1 | Out-String
Check 'payload $(subst) and $VAR survive transport' ($payloadOut -match 'sub:armored')
& $shim -s zsh examplehost -c 'x' 2>$null
Check 'invalid -s rejected by shim' ($LASTEXITCODE -eq 2)
& $shim local -c 2>$null
Check 'REGRESSION: local -c with no command exits 2' ($LASTEXITCODE -eq 2)

Write-Host '[installed: Git Bash shim]'
$gitBash = "$env:ProgramFiles\Git\bin\bash.exe"
if (Test-Path $gitBash) {
  $out = (& $gitBash -c '"$HOME/.local/bin/rrun" -n examplehost -c hostname' 2>&1) -join ' '
  Check 'dry-run via bash shim' ($out -like 'ssh -o BatchMode=yes examplehost powershell*')
  $out = (& $gitBash -c '"$HOME/.local/bin/rrun" -n local -c hostname' 2>&1) -join ' '
  Check 'REGRESSION: bash shim -n local dry-runs' ($out -match 'EncodedCommand')
  $out = & $gitBash -c '"$HOME/.local/bin/rrun" -s bash local -c "echo rrun-selftest-ok"' 2>&1 | Out-String
  Check 'bash shim local mode' ($out -match 'rrun-selftest-ok')
} else {
  Write-Host '  SKIP  Git Bash not found'
}

Write-Host '[gateway shells (local emulation of sshd DefaultShell)]'
# The streaming bootstrap must survive whatever shell the remote sshd hands it
# to: cmd.exe (stock), powershell.exe 5.1, or pwsh 7 (custom DefaultShell) — a
# bare "-Command iex(...)" bootstrap was silently corrupted by a pwsh gateway.
# Extract the REAL composed command from a dry-run, then pipe a $-bearing probe
# payload through each local shell invoked exactly as sshd would.
$dry = (wsl.exe -e sh -c 'RRUN_STREAM_LIMIT=10 "$HOME/.local/bin/rrun" -n examplehost -c x' 2>&1) -join ' '
if ($dry -match ' examplehost (.+)$') {
  $remoteCmd = $Matches[1] -replace '\\ ', ' '
  $probe = '$ProgressPreference=''SilentlyContinue''; $x = ''rrun-gw-ok''; Write-Output "gw:[$x]"'
  $probeB64 = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($probe))
  $out = $probeB64 | cmd.exe /c $remoteCmd 2>&1 | Out-String
  Check 'streaming bootstrap inert under cmd.exe gateway' ($out -match 'gw:\[rrun-gw-ok\]') $out
  $out = $probeB64 | powershell.exe -NoProfile -c $remoteCmd 2>&1 | Out-String
  Check 'streaming bootstrap inert under PowerShell 5.1 gateway' ($out -match 'gw:\[rrun-gw-ok\]') $out
  if (Get-Command pwsh -ErrorAction SilentlyContinue) {
    $out = $probeB64 | pwsh -NoProfile -c $remoteCmd 2>&1 | Out-String
    Check 'streaming bootstrap inert under pwsh 7 gateway' ($out -match 'gw:\[rrun-gw-ok\]') $out
  } else { Write-Host '  SKIP  pwsh not installed' }
} else {
  Check 'dry-run parse for gateway emulation' $false $dry
}

Write-Host '[core regression suite (mocked ssh, in WSL)]'
wsl.exe -e bash (ToWslPath (Join-Path $repo 'tests\core-tests.sh'))
Check 'tests/core-tests.sh all pass' ($LASTEXITCODE -eq 0)

if ($TargetHost) {
  Write-Host "[remote: $TargetHost]"
  $out = & $shim -s $TargetShell $TargetHost -c 'echo rrun-remote-ok' 2>&1 | Out-String
  Check "real ssh round-trip ($TargetShell)" ($out -match 'rrun-remote-ok')
  if ($TargetShell -in @('bash', 'sh')) {
    # large payload -> exercises the stdin-streaming transport end to end
    $lines = @('echo rrun-big-start') + (1..400 | ForEach-Object { "# padding line $_ to push the payload well past the streaming threshold" }) + @('echo rrun-big-ok')
    $bigFile = Join-Path $tmpDir 'big-payload.sh'
    [IO.File]::WriteAllText($bigFile, ($lines -join "`n") + "`n")
    $out = & $shim -s $TargetShell $TargetHost $bigFile 2>&1 | Out-String
    Check 'large payload streams via stdin (real host)' ($out -match 'rrun-big-ok')
  }
  if ($TargetShell -eq 'ps') {
    # REGRESSION: large ps payload over the streaming bootstrap, against a REAL
    # Windows sshd — the shell behind sshd (cmd or PowerShell DefaultShell) must
    # not re-parse the bootstrap or expand $-bearing payload statements. A bare
    # "-Command iex(...)" bootstrap corrupted these on pwsh-DefaultShell hosts.
    $lines = @('$marker = ''rrun-big-ps-ok''', 'Write-Output "got:[$marker]"') +
      (1..400 | ForEach-Object { "# padding line $_ to push the payload well past the streaming threshold" })
    $bigFile = Join-Path $tmpDir 'big-payload.ps1'
    [IO.File]::WriteAllText($bigFile, ($lines -join "`n") + "`n")
    $out = & $shim $TargetHost $bigFile 2>&1 | Out-String
    Check 'large ps payload streams via stdin (real Windows host)' ($out -match 'got:\[rrun-big-ps-ok\]')
    Check 'ps streaming payload not re-parsed by remote shell' ($out -notmatch 'not recognized|CommandNotFoundException')
  }
}
Remove-Item -Recurse -Force $tmpDir -ErrorAction SilentlyContinue

Write-Host ''
if ($script:fail -eq 0) { Write-Host 'ALL PASS' } else { Write-Host "$($script:fail) FAILURE(S)" }
exit $script:fail
