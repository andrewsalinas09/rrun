# shim-local-tests.ps1 — Windows CI tests for the PowerShell shim's "local" ps
# mode, run against the REPO SOURCE (bin/rrun.ps1) with real powershell.exe
# execution. No WSL or ssh required, so this runs on a stock windows-latest
# runner and gates merges on actual Windows PowerShell semantics (the Ubuntu
# job can only mock them). Exit code = number of failures.
$ErrorActionPreference = 'Continue'
$shim = Join-Path (Split-Path $PSScriptRoot -Parent) 'bin\rrun.ps1'
$script:fail = 0
function Check([string]$name, [bool]$ok, [string]$detail = '') {
  if ($ok) { Write-Host "  PASS  $name" }
  else     { Write-Host "  FAIL  $name  $detail"; $script:fail++ }
}

$out = & $shim local -c 'Write-Output ci-ok' 2>&1 | Out-String
Check 'local ps executes' ($out -match 'ci-ok') $out.Trim()
Check 'output free of CLIXML noise' ($out -notmatch 'CLIXML')

$out = & $shim local -c 'param([string]$Name = ''ci-param-ok'') Write-Output "p:[$Name]"' 2>&1 | Out-String
Check 'REGRESSION: param() payload runs (payload text never modified)' ($out -match 'p:\[ci-param-ok\]') $out.Trim()

$out = & $shim local -c "using namespace System.Text`n[StringBuilder]::new().Append('ci-using-ok').ToString()" 2>&1 | Out-String
Check 'REGRESSION: using-namespace payload runs' ($out -match 'ci-using-ok') $out.Trim()

$out = & $shim -n local -c 'Write-Output SHOULD-NOT-RUN' 2>&1 | Out-String
Check 'REGRESSION: -n local dry-runs, never executes' ($out -notmatch 'SHOULD-NOT-RUN\s*$' -and $out -match 'EncodedCommand')

& $shim local -c 2>$null
Check 'REGRESSION: local -c with no command exits 2' ($LASTEXITCODE -eq 2)

& $shim -s zsh local -c 'x' 2>$null
Check 'invalid -s rejected' ($LASTEXITCODE -eq 2)

Write-Host ''
if ($script:fail -eq 0) { Write-Host 'ALL PASS' } else { Write-Host "$($script:fail) FAILURE(S)" }
exit $script:fail
