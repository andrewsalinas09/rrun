# test.ps1 -- rrun smoke tests over the INSTALLED artifacts. No remote host
# required: dry-runs verify composition through every entry point, host "local"
# verifies real execution. Pass -TargetHost (and optionally -TargetShell) to add
# real ssh round-trips, including the large-payload streaming path.
# Core-logic regressions live separately in tests/core-tests.sh (mocked ssh, CI).
# Exit code = number of failures. This is the gate for the RSI loop.
param(
  [string]$TargetHost = '',
  [string]$TargetShell = 'bash',
  # e.g. -TargetHops 'pi,localhost' -- a real nested chain (each hop must be
  # able to ssh to the next; hosts 2..N, final included, need a POSIX login
  # shell + base64 + sh -- the hop layer runs `exec sh -c`, bash required
  # nowhere since 2.5.0)
  [string]$TargetHops = ''
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

# Streamed (large-payload) sessions to a Windows sshd can wedge remotely BEFORE
# the payload runs -- a nondeterministic host-side race, independent of payload
# content and rrun version (see README known issues). A wedged check must be a
# LOUD failure, never a silently hung suite: WSL `timeout` maps a wedge to exit
# 124, we sweep the stuck remote process, and retry.
function Invoke-RrunStreamTimed([string]$RemoteHost, [string]$File, [int]$TimeoutSec = 60) {
  # host/path ride as positional args ($1..$3), never interpolated into the
  # bash source -- the same payload-as-data rule the tool itself enforces.
  # PS-side 2>&1 is REQUIRED in addition to the bash-side one: remote error text
  # arrives as a "#< CLIXML" stream, which PowerShell deserializes and re-routes
  # to its error stream -- without this merge it vanishes from the capture.
  $out = wsl.exe -e bash -c 'timeout "$1" "$HOME/.local/bin/rrun" "$2" "$3" 2>&1' rrun-timed $TimeoutSec $RemoteHost (ToWslPath $File) 2>&1 | Out-String
  @{ Out = $out; Exit = $LASTEXITCODE }
}
# PS 5.1-safe sweep: kill wedged EncodedCommand powershell.exe instances (old
# enough to be a stuck streamed session, near-zero CPU) so retries start clean.
$script:sweepCmd = 'Get-CimInstance Win32_Process -Filter "Name=''powershell.exe''" | ForEach-Object { if ($_.ProcessId -ne $PID -and $_.CommandLine -match "EncodedCommand" -and ((Get-Date) - $_.CreationDate).TotalSeconds -gt 45) { $p = Get-Process -Id $_.ProcessId -ErrorAction SilentlyContinue; if ($p -and $p.TotalProcessorTime.TotalSeconds -lt 1) { Stop-Process -Id $_.ProcessId -Force } } }'
function Invoke-RrunStreamRetry([string]$RemoteHost, [string]$File, [string]$ShimPath) {
  $r = $null
  for ($try = 1; $try -le 3; $try++) {
    $r = Invoke-RrunStreamTimed $RemoteHost $File
    if ($r.Exit -ne 124) { return $r }
    Write-Host "  WARN  streamed session wedged remotely (known Windows-sshd race; see README) -- sweeping, retry $try/3"
    & $ShimPath $RemoteHost -c $script:sweepCmd 2>$null | Out-Null
  }
  return $r
}

Write-Host '[repo sources]'
wsl.exe -e bash -n (ToWslPath (Join-Path $repo 'bin\rrun')) 2>&1 | Out-Null
Check 'core syntax (bash -n)' ($LASTEXITCODE -eq 0)
$shimTxt = Get-Content -Raw (Join-Path $repo 'bin\rrun-shim.bash')
Check 'no hardcoded usernames in shims' (-not (($shimTxt + (Get-Content -Raw (Join-Path $repo 'bin\rrun.ps1'))) -match '/home/[a-z]+[a-z0-9]*/'))
# Windows PowerShell 5.1 reads BOM-less .ps1 as ANSI, so a UTF-8 em dash becomes
# a stray quote and the file stops parsing. This shipped once; never again.
$nonAscii = @(Get-ChildItem -Path $repo -Filter *.ps1 -Recurse -File | Where-Object {
  [IO.File]::ReadAllBytes($_.FullName) | Where-Object { $_ -gt 127 } | Select-Object -First 1
} | ForEach-Object { $_.Name })
Check 'all .ps1 sources are pure ASCII (5.1 parses BOM-less .ps1 as ANSI)' ($nonAscii.Count -eq 0) ($nonAscii -join ', ')

Write-Host '[installed: WSL core]'
$out = (wsl.exe -e sh -c '"$HOME/.local/bin/rrun" -n examplehost -c hostname' 2>&1) -join ' '
Check 'dry-run composes ssh command' ($out -like 'ssh -o BatchMode=yes examplehost powershell*' -and $out -match 'EncodedCommand')
$out = (wsl.exe -e sh -c '"$HOME/.local/bin/rrun" -n -s bash h1,h2 -c true' 2>&1) -join ' '
Check 'multi-hop re-armors per layer' ($out -like 'ssh -o BatchMode=yes h1 ssh*' -and $out -match 'h2' -and $out -match 'base64')

Write-Host '[installed: PowerShell shim]'
$shim = Join-Path $env:USERPROFILE '.local\bin\rrun.ps1'
$out = (& $shim -n examplehost -c hostname 2>$null) -join ' '
Check 'dry-run via ps shim' ($out -like 'ssh -o BatchMode=yes examplehost powershell*')
# the notice is written via [Console]::Error.WriteLine, which in-process 2>&1
# cannot intercept -- run the shim as a child powershell so stderr is a real
# redirectable handle
$all = (& powershell.exe -NoProfile -File $shim -n examplehost -c hostname 2>&1) -join ' '
Check 'remote dry-run warns on stderr that output is bash-quoted (stdout clean)' ($all -match 'bash-quoted' -and $out -notmatch 'bash-quoted')
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
$out = & $shim local -c 'param([string]$Name = ''rrun-param-ok'') Write-Output "p:[$Name]"' 2>&1 | Out-String
Check 'REGRESSION: param() payload runs (payload text never modified)' ($out -match 'p:\[rrun-param-ok\]') $out.Trim()
$out = & $shim local -c "using namespace System.Text`n[StringBuilder]::new().Append('rrun-using-ok').ToString()" 2>&1 | Out-String
Check 'REGRESSION: using-namespace payload runs' ($out -match 'rrun-using-ok') $out.Trim()
# failures must be loud AND non-zero (a swallowed error status defeats the tool)
$err = & $shim local -c 'no-such-command-xyz' 2>&1 | Out-String
Check 'REGRESSION: failing local ps payload exits non-zero' ($LASTEXITCODE -ne 0) "exit=$LASTEXITCODE"
Check 'REGRESSION: local ps failure text visible on stderr' ($err -match 'not recognized') $err.Trim()
& $shim local -c 'exit 3' 2>$null
Check 'local ps preserves explicit exit code (3)' ($LASTEXITCODE -eq 3) "exit=$LASTEXITCODE"
# REGRESSION: UTF-16LE .ps1 files (Windows PowerShell's Out-File/> default) must
# decode as source text, not UTF-8 garbage -- the wrapper detects BOMs. The e is
# built with [char] so this test file itself stays pure ASCII.
$u16File = Join-Path $tmpDir 'u16-payload.ps1'
[IO.File]::WriteAllText($u16File, ('$s = ' + "'caf$([char]0xE9)'" + '; Write-Output ("u16len:" + $s.Length)'), [Text.Encoding]::Unicode)
$out = & $shim local $u16File 2>&1 | Out-String
Check 'REGRESSION: UTF-16LE payload file decodes (ps shim local)' ($out -match 'u16len:4') $out.Trim()
$out = & $shim -s bash local -c 'echo rrun-selftest-ok' 2>&1 | Out-String
Check 'local bash (via WSL) executes' ($out -match 'rrun-selftest-ok')
$payloadOut = & $shim -s bash local -c 'V=$(echo armored); echo "sub:$V"' 2>&1 | Out-String
Check 'payload $(subst) and $VAR survive transport' ($payloadOut -match 'sub:armored')
& $shim -s zsh examplehost -c 'x' 2>$null
Check 'invalid -s rejected by shim' ($LASTEXITCODE -eq 2)
& $shim local -c 2>$null
Check 'REGRESSION: local -c with no command exits 2' ($LASTEXITCODE -eq 2)

Write-Host '[PowerShell edition matrix]'
# Both shipped 5.1-only bugs (native-arg quoting mangling \" ; native stderr
# throwing under EAP=Stop) passed every pwsh-7 run. Exercise both editions.
& (Join-Path $repo 'tests\ps-edition-checks.ps1')
Check "shim checks pass under ambient PowerShell ($($PSVersionTable.PSVersion))" ($LASTEXITCODE -eq 0)
$ps51 = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
if (Test-Path $ps51) {
  & $ps51 -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'tests\ps-edition-checks.ps1')
  Check 'shim checks pass under Windows PowerShell 5.1 (the DEFAULT powershell.exe)' ($LASTEXITCODE -eq 0)
} else {
  Write-Host '    SKIP  Windows PowerShell 5.1 not present'
}

Write-Host '[installed: Git Bash shim]'
$gitBash = "$env:ProgramFiles\Git\bin\bash.exe"
if (Test-Path $gitBash) {
  # Run a script FILE, never `bash -c '<script containing quotes>'`. Windows
  # PowerShell 5.1 STRIPS double quotes from native-command arguments and
  # word-splits them, so the -c script arrived at bash shredded into separate
  # argv elements (measured: six instead of one) and the local-mode check failed
  # under 5.1 while passing under pwsh 7. The shim itself was never at fault --
  # the identical command run natively from Git Bash works. This is the repo's
  # own payload-as-data rule applied to the harness: the script is a file, the
  # operands are plain arguments, and nothing needs quoting to survive.
  $gbHelper = Join-Path $tmpDir 'gb-run.sh'
  [IO.File]::WriteAllText($gbHelper, '"$HOME/.local/bin/rrun" "$@"' + "`n")
  $gb = $gbHelper -replace '\\', '/'
  $out = (& $gitBash $gb -n examplehost -c hostname 2>&1) -join ' '
  Check 'dry-run via bash shim' ($out -like 'ssh -o BatchMode=yes examplehost powershell*')
  $out = (& $gitBash $gb -n local -c hostname 2>&1) -join ' '
  Check 'REGRESSION: bash shim -n local dry-runs' ($out -match 'EncodedCommand')
  $out = & $gitBash $gb -s bash local -c 'echo rrun-selftest-ok' 2>&1 | Out-String
  Check 'bash shim local mode' ($out -match 'rrun-selftest-ok') $out.Trim()
  $u16Fwd = $u16File -replace '\\', '/'
  $out = & $gitBash $gb local $u16Fwd 2>&1 | Out-String
  Check 'REGRESSION: UTF-16LE payload file decodes (bash shim local)' ($out -match 'u16len:4') $out.Trim()
} else {
  Write-Host '  SKIP  Git Bash not found'
}

Write-Host '[gateway shells (local emulation of sshd DefaultShell)]'
# The streaming bootstrap must survive whatever shell the remote sshd hands it
# to: cmd.exe (stock), powershell.exe 5.1, or pwsh 7 (custom DefaultShell) -- a
# bare "-Command iex(...)" bootstrap was silently corrupted by a pwsh gateway.
# Extract the REAL composed command from a dry-run, then pipe a $-bearing probe
# payload through each local shell invoked exactly as sshd would.
$dry = (wsl.exe -e sh -c 'RRUN_STREAM_LIMIT=10 "$HOME/.local/bin/rrun" -n examplehost -c x' 2>&1) -join ' '
if ($dry -match ' examplehost (.+)$') {
  $remoteCmd = $Matches[1] -replace '\\ ', ' '
  $probe = 'param([string]$Who = ''rrun-gw-ok'') $x = $Who; Write-Output "gw:[$x]"'
  $probeB64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($probe))
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

Write-Host '[Claude Code boundary hook]'
# The hook fails OPEN at runtime (it must never block a tool call), so a missing
# Python 3 would leave it silently inert forever. Surface that HERE instead.
$py = $null
foreach ($c in 'python3', 'python', 'py') {
  if (-not (Get-Command $c -ErrorAction SilentlyContinue)) { continue }
  # `python3` on Windows is often the Microsoft Store stub: on PATH, exits 49.
  try { & $c -c 'import sys; sys.exit(0 if sys.version_info[0]==3 else 1)' 2>$null } catch { continue }
  if ($LASTEXITCODE -eq 0) { $py = $c; break }
}
Check 'dependency: a working Python 3 is on PATH (else the hook is inert)' ($null -ne $py) `
  'install Python 3 and re-run install.ps1, or use install.ps1 -SkipClaudeHook'
if ($py) {
  & $py (Join-Path $repo 'tests\hook-tests.py')
  Check 'tests/hook-tests.py all pass' ($LASTEXITCODE -eq 0)
  & $py (Join-Path $repo 'tests\source-hygiene.py') | Out-Null
  Check 'tests/source-hygiene.py all pass (ASCII .ps1, LF, no hardcoded paths)' ($LASTEXITCODE -eq 0)
}
& (Join-Path $repo 'tests\hook-install-tests.ps1') | Out-Null
Check 'tests/hook-install-tests.ps1 all pass (settings.json merge/removal is safe)' ($LASTEXITCODE -eq 0)
& (Join-Path $repo 'tests\install-state-tests.ps1') | Out-Null
Check 'tests/install-state-tests.ps1 all pass (ownership manifest + env restore)' ($LASTEXITCODE -eq 0)

if ($TargetHost) {
  Write-Host "[remote: $TargetHost]"
  $out = & $shim -s $TargetShell $TargetHost -c 'echo rrun-remote-ok' 2>&1 | Out-String
  Check "real ssh round-trip ($TargetShell)" ($out -match 'rrun-remote-ok')
  if ($TargetShell -eq 'ps') {
    # small payload -- non-streamed, exercises the remote BOM-aware decode
    $out = & $shim $TargetHost $u16File 2>&1 | Out-String
    Check 'REGRESSION: UTF-16LE payload decodes on remote Windows host' ($out -match 'u16len:4') $out.Trim()
  }
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
    # Windows sshd -- the shell behind sshd (cmd or PowerShell DefaultShell) must
    # not re-parse the bootstrap or expand $-bearing payload statements. A bare
    # "-Command iex(...)" bootstrap corrupted these on pwsh-DefaultShell hosts.
    $lines = @('param([string]$marker = ''rrun-big-ps-ok'')', 'Write-Output "got:[$marker]"') +
      (1..400 | ForEach-Object { "# padding line $_ to push the payload well past the streaming threshold" })
    $bigFile = Join-Path $tmpDir 'big-payload.ps1'
    [IO.File]::WriteAllText($bigFile, ($lines -join "`n") + "`n")
    $r = Invoke-RrunStreamRetry $TargetHost $bigFile $shim
    Check 'large ps payload streams via stdin (real Windows host)' ($r.Out -match 'got:\[rrun-big-ps-ok\]')
    Check 'ps streaming payload not re-parsed by remote shell' ($r.Out -notmatch 'not recognized|CommandNotFoundException')
    Check 'REGRESSION: streamed ps success exits zero (real host)' ($r.Exit -eq 0) "exit=$($r.Exit)"
    # a failing streamed payload must also carry its non-zero status back.
    # exit 124 is the local timeout wrapper (a wedge), NOT the payload's status --
    # it must never satisfy the non-zero assertion.
    $failLines = @('no-such-command-xyz') + (1..400 | ForEach-Object { "# padding line $_ to push the payload well past the streaming threshold" })
    $failFile = Join-Path $tmpDir 'big-fail.ps1'
    [IO.File]::WriteAllText($failFile, ($failLines -join "`n") + "`n")
    $r = Invoke-RrunStreamRetry $TargetHost $failFile $shim
    Check 'REGRESSION: failing streamed ps payload exits non-zero (real host)' ($r.Exit -ne 0 -and $r.Exit -ne 124) "exit=$($r.Exit)"
    Check 'REGRESSION: streamed ps failure text visible (real host)' ($r.Out -match 'not recognized') $r.Out.Trim()
  }
}
if ($TargetHops) {
  Write-Host "[nested hops: $TargetHops]"
  # Payload reports the byte count + md5 of the file it executed from, so a
  # short or corrupted stream is caught -- not merely a missing marker -- and
  # exits 7 so status propagation through every layer is checked too.
  $lines = @('echo START') +
    (1..900 | ForEach-Object { "# padding line $_ to push the payload past the streaming threshold" }) +
    @('echo "BYTES:$(wc -c < "$0") MD5:$(md5sum < "$0" | cut -d" " -f1)"', 'echo END', 'exit 7')
  $hopFile = Join-Path $tmpDir 'hop-payload.sh'
  [IO.File]::WriteAllText($hopFile, ($lines -join "`n") + "`n")
  $bytes = [IO.File]::ReadAllBytes($hopFile)
  $md5 = ([BitConverter]::ToString([Security.Cryptography.MD5]::Create().ComputeHash($bytes)) -replace '-', '').ToLower()

  $out = (& $shim -s bash $TargetHops -c 'echo nested-small-ok' 2>&1 | Out-String)
  Check 'small payload over nested hops' ($out -match 'nested-small-ok') $out.Trim()

  # the case that used to die locally with E2BIG: an embedded payload grows
  # 4/3 per hop, so a big script blew past the 128KiB argv ceiling
  $out = wsl.exe -e bash -c 'timeout 180 "$HOME/.local/bin/rrun" -s bash "$1" "$2" 2>&1' rrun-hops $TargetHops (ToWslPath $hopFile) 2>&1 | Out-String
  $hopExit = $LASTEXITCODE
  Check 'REGRESSION: large payload streams THROUGH nested hops (was E2BIG)' ($out -match 'END') $out.Trim()
  Check 'nested streamed payload arrives byte-for-byte (md5 verified)' (($out -match "BYTES:$($bytes.Length)\b") -and ($out -match "MD5:$md5")) $out.Trim()
  Check 'nested streamed payload exit code propagates (7)' ($hopExit -eq 7) "exit=$hopExit"
}
Remove-Item -Recurse -Force $tmpDir -ErrorAction SilentlyContinue

Write-Host ''
if ($script:fail -eq 0) { Write-Host 'ALL PASS' } else { Write-Host "$($script:fail) FAILURE(S)" }
exit $script:fail
