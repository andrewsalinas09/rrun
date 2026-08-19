# ps-edition-checks.ps1 -- shim behaviours that must hold under WHICHEVER
# PowerShell edition runs them. test.ps1 runs this twice: once under the ambient
# edition and once under Windows PowerShell 5.1 explicitly.
#
# Why a separate file: Windows PowerShell 5.1 (the default powershell.exe) and
# pwsh 7 differ in ways that have each shipped a bug --
#   * native-argument quoting: 5.1 re-quotes with legacy rules that MANGLE
#     backslash-escaped quotes, which broke the whole local bash/sh path
#     (`trap "rm -f \"$t\""` arrived truncated -> `trap: usage: ...`)
#   * native stderr: 5.1 raises a terminating NativeCommandError under EAP=Stop,
#     so a payload that merely printed a warning made the shim throw
# Passing under one edition proves nothing about the other. These need a real
# WSL, so they live here rather than in the CI-only shim-local-tests.ps1.
$ErrorActionPreference = 'Continue'
$shim = Join-Path $env:USERPROFILE '.local\bin\rrun.ps1'
$fail = 0
function Check([string]$name, [bool]$ok, [string]$detail = '') {
  if ($ok) { Write-Host "    PASS  $name" }
  else { Write-Host "    FAIL  $name  $detail"; $script:fail++ }
}

Write-Host "  [edition $($PSVersionTable.PSVersion)]"

# REGRESSION: local bash path. Broke entirely under 5.1 because the trap body
# used \"-escaped quotes as a native argument.
$out = & $shim -s bash local -c 'echo rrun-selftest-ok' 2>&1 | Out-String
Check 'local bash executes' ($out -match 'rrun-selftest-ok') $out.Trim()
$out = & $shim -s bash local -c 'V=$(echo armored); echo "sub:$V"' 2>&1 | Out-String
Check 'payload $(subst) and $VAR survive' ($out -match 'sub:armored') $out.Trim()
& $shim -s bash local -c 'exit 7' 2>&1 | Out-Null
Check 'local bash exit code passes through (7)' ($LASTEXITCODE -eq 7) "exit=$LASTEXITCODE"

# -s wsl local IS -s bash local (this machine is the Windows host with the
# WSL) -- must execute, under both editions, through the same native-arg path.
$out = & $shim -s wsl local -c 'echo rrun-wsl-ok' 2>&1 | Out-String
Check 'local wsl (bash inside WSL) executes' ($out -match 'rrun-wsl-ok') $out.Trim()

# REGRESSION: a payload writing to stderr must not make the shim THROW.
$threw = $false
try { & $shim local -c '[Console]::Error.WriteLine("noise"); exit 0' 2>&1 | Out-Null } catch { $threw = $true }
Check 'stderr-writing ps payload does not throw' (-not $threw)
Check 'stderr-writing ps payload still exits 0' ($LASTEXITCODE -eq 0) "exit=$LASTEXITCODE"

if ($fail -gt 0) { Write-Host "  $fail FAILURE(S)"; exit $fail }
exit 0
