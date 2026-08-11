# install-state-tests.ps1 -- regression suite for lib/install-state.ps1: the
# ownership manifest and the env-restore decision table that install.ps1 /
# uninstall.ps1 drive. Runs under BOTH PowerShell editions (CI + test.ps1),
# touches only temp files, never the real user environment.
#
# Each named regression here is a deterministic ownership bug that shipped in
# uninstall v1.0, which reconstructed ownership from current values instead of
# recorded history (external-review round 11, finding 1).
$ErrorActionPreference = 'Continue'
$repo = Split-Path $PSScriptRoot -Parent
. (Join-Path $repo 'lib\install-state.ps1')
$fail = 0
function Check([string]$name, [bool]$ok, [string]$detail = '') {
  if ($ok) { Write-Host "  PASS  $name" }
  else { Write-Host "  FAIL  $name  $detail"; $script:fail++ }
}

$WANT = 'C:/Users/u/.rrun/bash_env'

Write-Host '[env-restore decision table]'
$r = Resolve-EnvRestore $null $null 'utf-8'
Check 'REGRESSION: pre-existing value rrun never set is LEFT (was deleted when it equaled utf-8)' ($r.Action -eq 'leave-not-ours')
$r = Resolve-EnvRestore 'utf-8' $null 'utf-8'
Check 'pre-existing value with recorded prior, never set by rrun -> left' ($r.Action -eq 'leave-not-ours')
$r = Resolve-EnvRestore $null 'utf-8' 'utf-8'
Check 'rrun set it over nothing, unchanged since -> delete' ($r.Action -eq 'delete')
$r = Resolve-EnvRestore 'C:/Users/u/.bashrc' $WANT $WANT
Check 'REGRESSION: migrated BASH_ENV restores the pre-install value (was deleted)' ($r.Action -eq 'restore' -and $r.Value -eq 'C:/Users/u/.bashrc')
$r = Resolve-EnvRestore $null $WANT 'D:/somewhere/else'
Check 'user changed it after install -> left (their change wins)' ($r.Action -eq 'leave-changed')
$r = Resolve-EnvRestore $null $WANT $null
Check 'user deleted it after install -> left (nothing to undo)' ($r.Action -eq 'leave-changed')
$r = Resolve-EnvRestore $null $WANT ($WANT.ToUpper())
Check 'comparison is exact (case-sensitive): differing case counts as changed' ($r.Action -eq 'leave-changed')

Write-Host '[manifest round-trip]'
$tmp = Join-Path ([IO.Path]::GetTempPath()) ("rrun-statetest-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
$mf = Join-Path $tmp 'install-state.json'
$s = New-RrunState -PriorBashEnv 'C:/x/.bashrc' -PriorPythonIoEncoding '' `
  -PriorPathHadEntry $true -PriorBashrcExisted $true -PriorBashProfileExisted $false
Check 'empty-string prior normalizes to null (one representation of absence)' ($null -eq $s.prior.pythonIoEncoding)
$s.set.pathEntryAdded = $false
$s.set.bashEnv = $WANT
$s.set.bashProfileCreated = $true
$s.claudeConfigDir = 'C:/Users/u/.claude'
$s.wslDistro = 'Ubuntu'
Write-RrunState $s $mf
$r2 = Read-RrunState $mf
Check 'round-trip preserves prior values' ($r2.prior.bashEnv -eq 'C:/x/.bashrc' -and $null -eq $r2.prior.pythonIoEncoding)
Check 'round-trip preserves booleans' ($r2.prior.pathHadEntry -eq $true -and $r2.prior.bashProfileExisted -eq $false -and $r2.set.bashProfileCreated -eq $true)
Check 'round-trip preserves set/dir/distro' ($r2.set.bashEnv -eq $WANT -and $r2.claudeConfigDir -eq 'C:/Users/u/.claude' -and $r2.wslDistro -eq 'Ubuntu')
# a reread manifest must feed the decision table identically to a fresh one
$r = Resolve-EnvRestore $r2.prior.bashEnv $r2.set.bashEnv $WANT
Check 'reread manifest drives restore correctly' ($r.Action -eq 'restore' -and $r.Value -eq 'C:/x/.bashrc')

Write-Host '[manifest robustness]'
Check 'missing manifest reads as $null' ($null -eq (Read-RrunState (Join-Path $tmp 'nope.json')))
[IO.File]::WriteAllText($mf, '{ corrupt not json')
Check 'corrupt manifest reads as $null, never throws (uninstall must degrade, not abort)' ($null -eq (Read-RrunState $mf))
Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue

Write-Host '[Invoke-Native: the 5.1 stderr-throws-under-EAP=Stop class]'
# Windows PowerShell 5.1 can raise a terminating NativeCommandError when a
# native child writes to stderr under EAP=Stop -- killing an installer before
# its $LASTEXITCODE check runs. Invoke-Native is the centralized guard; this
# runs under both editions via test.ps1 and CI.
$threw = $false
$out = ''
try {
  & {
    $ErrorActionPreference = 'Stop'
    Invoke-Native { cmd.exe /c 'echo benign-diagnostic 1>&2 & exit /b 0' } 2>&1 | Out-Null
  }
} catch { $threw = $true }
Check 'stderr-writing native under EAP=Stop does not throw' (-not $threw)
Check 'exit code 0 survives' ($LASTEXITCODE -eq 0) "exit=$LASTEXITCODE"
& { $ErrorActionPreference = 'Stop'; Invoke-Native { cmd.exe /c 'exit /b 3' } } 2>$null
Check 'non-zero exit code passes through (3)' ($LASTEXITCODE -eq 3) "exit=$LASTEXITCODE"
$restored = & {
  $ErrorActionPreference = 'Stop'
  Invoke-Native { cmd.exe /c 'exit /b 0' } | Out-Null
  $ErrorActionPreference
}
Check 'caller EAP restored after the call' ($restored -eq 'Stop') "eap=$restored"

Write-Host ''
if ($fail -gt 0) { Write-Host "$fail FAILURE(S)"; exit $fail }
Write-Host 'ALL PASS'
exit 0
