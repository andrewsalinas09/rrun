# shim-local-tests.ps1 -- Windows CI tests for the PowerShell shim's "local" ps
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

# REGRESSION: UTF-16LE .ps1 files (Windows PowerShell's Out-File/> default) must
# decode as source text, not UTF-8 garbage. The e rides via [char] so this test
# file itself stays ASCII.
$u16 = Join-Path $env:TEMP "rrun-ci-u16-$PID.ps1"
[IO.File]::WriteAllText($u16, ('$s = ' + "'caf$([char]0xE9)'" + '; Write-Output ("u16len:" + $s.Length)'), [Text.Encoding]::Unicode)
$out = & $shim local $u16 2>&1 | Out-String
Check 'REGRESSION: UTF-16LE payload file decodes (BOM-aware)' ($out -match 'u16len:4') $out.Trim()
Remove-Item $u16 -ErrorAction SilentlyContinue

# REGRESSION: bash/sh FILE operands must ride as raw bytes. ReadAllText
# BOM-decoded them and re-encoded as UTF-8, so a UTF-16LE (or any non-UTF-8)
# shell file reached WSL transformed -- text preservation, not bytes. No WSL
# needed: pull the base64 out of the dry-run and compare to the file bytes.
$rawFile = Join-Path $env:TEMP "rrun-ci-raw-$PID.sh"
$rawBytes = [byte[]](0xFF, 0xFE, 0x68, 0x69, 0x0A, 0x00, 0xE9, 0x0D, 0x0A, 0x0A, 0x0A)
[IO.File]::WriteAllBytes($rawFile, $rawBytes)
$dry = & $shim -n -s bash local $rawFile 2>&1 | Out-String
$m = [regex]::Match($dry, 'echo ([A-Za-z0-9+/=]+) \| base64')
Check 'REGRESSION: bash file operand rides as raw bytes (b64 == file bytes)' ($m.Success -and ($m.Groups[1].Value -eq [Convert]::ToBase64String($rawBytes))) $dry.Trim()

# ...and stdin (-) must be raw bytes too -- it was the last text-typed ingestion
# path (Console.In.ReadToEnd re-encoded UTF-16/binary stdin as UTF-8). cmd.exe's
# `<` hands the child the raw file handle; a PowerShell pipe would re-encode.
# -Command (not -File): powershell.exe -File tries to bind a bare `-` as a
# parameter name and dies before the script runs; in-language invocation is the
# canonical entry (PATH-resolved `rrun`) and parses `-` as a plain argument.
$cmdLine = 'powershell -NoProfile -ExecutionPolicy Bypass -Command "& ''{0}'' -n -s bash local -" < "{1}"' -f $shim, $rawFile
$dry = cmd /c $cmdLine 2>&1 | Out-String
$m = [regex]::Match($dry, 'echo ([A-Za-z0-9+/=]+) \| base64')
Check 'REGRESSION: stdin (-) rides as raw bytes (b64 == piped bytes)' ($m.Success -and ($m.Groups[1].Value -eq [Convert]::ToBase64String($rawBytes))) $dry.Trim()
Remove-Item $rawFile -ErrorAction SilentlyContinue

$out = & $shim -n local -c 'Write-Output SHOULD-NOT-RUN' 2>&1 | Out-String
Check 'REGRESSION: -n local dry-runs, never executes' ($out -notmatch 'SHOULD-NOT-RUN\s*$' -and $out -match 'EncodedCommand')

# REGRESSION (v1.11): a payload that writes to STDERR must not make the shim
# THROW. Under Windows PowerShell 5.1 -- the default powershell.exe -- a native
# command raises a terminating NativeCommandError while EAP=Stop as soon as the
# child writes to stderr, so rrun threw instead of returning the payload's exit
# code. That is a transparency violation: rrun reserves nothing. Invoked
# IN-PROCESS with & on purpose; running the shim as a -File child would swallow
# the throw into an exit code and hide the bug (it did, on the first attempt).
$threw = $false
try { $out = & $shim local -c '[Console]::Error.WriteLine("stderr-noise"); exit 0' 2>&1 | Out-String }
catch { $threw = $true }
Check 'REGRESSION: stderr-writing payload does not make the shim throw' (-not $threw)
Check 'REGRESSION: stderr-writing payload still exits 0' ($LASTEXITCODE -eq 0) "exit=$LASTEXITCODE"
$threw = $false
try { $out = & $shim local -c 'no-such-command-xyz' 2>&1 | Out-String } catch { $threw = $true }
Check 'REGRESSION: failing payload returns a code rather than throwing' (-not $threw)

# Failures must be LOUD (stderr text) AND non-zero exit -- a transport that
# swallows either is worse than useless for debugging. Exit codes must match a
# bare `powershell -Command`: any failure -> non-zero, explicit `exit N` -> N.
$err = & $shim local -c 'no-such-command-xyz' 2>&1 | Out-String
Check 'REGRESSION: failing payload exits non-zero (not a false success)' ($LASTEXITCODE -ne 0) "exit=$LASTEXITCODE"
Check 'REGRESSION: failure text is visible on stderr' ($err -match 'no-such-command-xyz' -and $err -match 'not recognized') $err.Trim()
& $shim local -c 'Write-Error boom' 2>$null
Check 'REGRESSION: Write-Error payload exits non-zero' ($LASTEXITCODE -ne 0) "exit=$LASTEXITCODE"
& $shim local -c 'Write-Output fine' 2>$null
Check 'success payload exits zero' ($LASTEXITCODE -eq 0) "exit=$LASTEXITCODE"
& $shim local -c 'exit 3' 2>$null
Check 'explicit exit code preserved (exit 3 -> 3)' ($LASTEXITCODE -eq 3) "exit=$LASTEXITCODE"
& $shim local -c "Write-Error mid`nWrite-Output recovered" 2>$null
Check 'recovered payload (error then success) exits zero, like bare -Command' ($LASTEXITCODE -eq 0) "exit=$LASTEXITCODE"

& $shim local -c 2>$null
Check 'REGRESSION: local -c with no command exits 2' ($LASTEXITCODE -eq 2)

& $shim -s zsh local -c 'x' 2>$null
Check 'invalid -s rejected' ($LASTEXITCODE -eq 2)

# -s wsl local IS -s bash local (this machine is the Windows host with the
# WSL). Dry-run only: CI runners have no WSL, and -n must compose without one.
$out = & $shim -n -s wsl local -c 'echo ci-wsl' 2>&1 | Out-String
Check '-s wsl local composes the WSL bash form (dry-run)' ($out -match 'wsl -e bash -c') $out.Trim()
& $shim -s wsl adb -c 'x' 2>$null
Check '-s wsl rejected for adb targets (Android has no WSL)' ($LASTEXITCODE -eq 2)

Write-Host ''
if ($script:fail -eq 0) { Write-Host 'ALL PASS' } else { Write-Host "$($script:fail) FAILURE(S)" }
exit $script:fail
