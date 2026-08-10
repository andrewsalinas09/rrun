# test.ps1 — rrun smoke tests. No remote host required: dry-runs verify command
# composition through every entry point, and host "local" verifies real execution.
# Pass -TargetHost (and optionally -TargetShell) to add one real ssh round-trip.
# Exit code = number of failures. This is the gate for the RSI loop: any change to
# bin/ must pass `install.ps1` then `test.ps1` before commit.
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
$out = wsl.exe -e sh -c '"$HOME/.local/bin/rrun" -n examplehost -c hostname' 2>&1
Check 'dry-run composes ssh command' ("$out" -like 'ssh -o BatchMode=yes examplehost powershell*-EncodedCommand*')
$out = wsl.exe -e sh -c '"$HOME/.local/bin/rrun" -n -s bash h1,h2 -c true' 2>&1
Check 'multi-hop re-armors per layer' ("$out" -match "ssh -o BatchMode=yes h1 ssh -o BatchMode=yes h2 'echo [A-Za-z0-9+/=]+ \| base64 -d \| bash'")

Write-Host '[installed: PowerShell shim]'
$shim = Join-Path $env:USERPROFILE '.local\bin\rrun.ps1'
$out = & $shim -n examplehost -c hostname 2>&1
Check 'dry-run via ps shim' ("$out" -like 'ssh -o BatchMode=yes examplehost powershell*')
$out = & $shim local -c 'Write-Output rrun-selftest-ok' 2>&1 | Out-String
Check 'local ps executes' ($out -match 'rrun-selftest-ok')
Check 'local ps output free of CLIXML noise' ($out -notmatch 'CLIXML')
$out = & $shim -s bash local -c 'echo rrun-selftest-ok' 2>&1 | Out-String
Check 'local bash (via WSL) executes' ($out -match 'rrun-selftest-ok')
$payloadOut = & $shim -s bash local -c 'V=$(echo armored); echo "sub:$V"' 2>&1 | Out-String
Check 'payload $(subst) and $VAR survive transport' ($payloadOut -match 'sub:armored')

Write-Host '[installed: Git Bash shim]'
$gitBash = "$env:ProgramFiles\Git\bin\bash.exe"
if (Test-Path $gitBash) {
  $out = & $gitBash -c '"$HOME/.local/bin/rrun" -n examplehost -c hostname' 2>&1
  Check 'dry-run via bash shim' ("$out" -like 'ssh -o BatchMode=yes examplehost powershell*')
  $out = & $gitBash -c '"$HOME/.local/bin/rrun" -s bash local -c "echo rrun-selftest-ok"' 2>&1 | Out-String
  Check 'bash shim local mode' ($out -match 'rrun-selftest-ok')
} else {
  Write-Host '  SKIP  Git Bash not found'
}

if ($TargetHost) {
  Write-Host "[remote: $TargetHost]"
  $out = & $shim -s $TargetShell $TargetHost -c 'echo rrun-remote-ok' 2>&1 | Out-String
  Check "real ssh round-trip ($TargetShell)" ($out -match 'rrun-remote-ok')
}

Write-Host ''
if ($script:fail -eq 0) { Write-Host 'ALL PASS' } else { Write-Host "$($script:fail) FAILURE(S)" }
exit $script:fail
