# rrun (Windows/PowerShell shim) — forwards to WSL ~/.local/bin/rrun so payloads cross
# shell boundaries as data, never as escaped strings. Installed by install.ps1 into
# %USERPROFILE%\.local\bin (PowerShell resolves `rrun` -> rrun.ps1 via PATH).
#   * wsl.exe -e      : direct exec, WSL default shell never re-parses argv ($ survives)
#   * script operand  : ONLY the script-source arg is translated C:\x -> /mnt/c/x;
#                       everything after -c is opaque data, never touched
#   * host "local"    : ps -> powershell.exe -EncodedCommand here; bash/sh -> wsl bash.
#                       Bounded by the 32767-char process command-line limit
#                       (~12KB ps payload); use a file + -File beyond that.
#   * $HOME trampoline: sh -c '... "$@"' expands $HOME inside WSL; payload args pass
#                       as untouched positional params (no hardcoded WSL username).
# usage mirrors WSL rrun:  rrun [-s ps|bash|sh] [-J jumps] [-n] <host[,hop2,...]|local> <script|-|-c "cmds">
# history: v1 2026-08-10 created from transcript-error audit; v1.1 $HOME trampoline,
#          CLIXML suppression; v1.2 review fixes — -n honored in local mode (was
#          EXECUTING on dry-run), -c args no longer path-translated, -s validated,
#          -J rejected for host local; v1.3 "local -c" with no command now exits 2
#          (out-of-range $rest[1] was silently $null -> empty successful run);
#          v1.4 local ps payloads never textually modified (prefix broke
#          param()/using — scriptblock wrapper instead).
$ErrorActionPreference = 'Stop'

function Fail([string]$msg) {
  # usage errors: plain stderr + exit 2. (Write-Error under EAP=Stop would THROW
  # before reaching exit, aborting the caller instead of returning a status.)
  [Console]::Error.WriteLine($msg)
  exit 2
}

function ToWsl([string]$p) {
  $r = (Resolve-Path -LiteralPath $p).Path -replace '\\', '/'
  if ($r -match '^([A-Za-z]):(.*)$') { return "/mnt/$($Matches[1].ToLower())$($Matches[2])" }
  return $r
}

$rest = @($args)
$opts = @(); $shell = ''; $dry = $false; $jump = $false
while ($rest.Count -gt 0 -and $rest[0] -like '-*' -and $rest[0] -ne '-c' -and $rest[0] -ne '-') {
  switch ($rest[0]) {
    '-s' {
      if ($rest.Count -lt 2 -or @('ps', 'bash', 'sh') -notcontains $rest[1]) {
        Fail 'rrun: -s must be ps, bash or sh'
      }
      $shell = $rest[1]; $opts += @('-s', $rest[1]); $rest = @($rest[2..($rest.Count)])
    }
    '-J' {
      if ($rest.Count -lt 2) { Fail 'rrun: -J needs an argument' }
      $jump = $true; $opts += @('-J', $rest[1]); $rest = @($rest[2..($rest.Count)])
    }
    '-n' { $dry = $true; $opts += '-n'; $rest = @($rest[1..($rest.Count)]) }
    default { Fail "rrun: unknown option '$($rest[0])'" }
  }
}
if ($rest.Count -lt 2) {
  Fail 'usage: rrun [-s ps|bash|sh] [-J jumps] [-n] <host[,hop2,...]|local> <script | - | -c "cmds">'
}
$hostSpec = $rest[0]; $rest = @($rest[1..($rest.Count - 1)])

if ($hostSpec -eq 'local') {
  if ($jump) { Fail 'rrun: -J is meaningless with host "local"' }
  $src = $rest[0]
  switch ($src) {
    '-c' {
      if ($rest.Count -lt 2) { Fail 'rrun: -c needs a command string' }
      $payload = $rest[1]
    }
    '-'  { $payload = [Console]::In.ReadToEnd() }
    default { $payload = [IO.File]::ReadAllText((Resolve-Path -LiteralPath $src).Path) }
  }
  if (-not $shell) { $shell = if ($src -match '\.(sh|bash)$') { 'bash' } else { 'ps' } }
  if ($shell -eq 'ps') {
    # payload text never modified (a prepended statement broke param()/using,
    # which must be a script's first statements): a fixed wrapper sets
    # ProgressPreference (suppresses "#< CLIXML ... Preparing modules" stderr
    # noise) and runs the decoded source as its own scriptblock
    $pb64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($payload))
    $wrapper = '$ProgressPreference=''SilentlyContinue''; & ([scriptblock]::Create([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String(''{0}''))))' -f $pb64
    $b64 = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($wrapper))
    if ($dry) { Write-Output "powershell -NoProfile -ExecutionPolicy Bypass -EncodedCommand $b64"; exit 0 }
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -EncodedCommand $b64
    exit $LASTEXITCODE
  } else {
    $b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($payload))
    if ($dry) { Write-Output "wsl -e bash -c `"echo $b64 | base64 -d | $shell`""; exit 0 }
    & wsl.exe -e bash -c "echo $b64 | base64 -d | $shell"
    exit $LASTEXITCODE
  }
}

# remote: translate ONLY the script-source operand (a real local file) to a /mnt
# path. Arguments following -c (and "-") are opaque payload data — never touched.
if ($rest[0] -ne '-c' -and $rest[0] -ne '-' -and (Test-Path -LiteralPath $rest[0] -PathType Leaf)) {
  $rest[0] = ToWsl $rest[0]
}
& wsl.exe -e sh -c 'exec "$HOME/.local/bin/rrun" "$@"' rrun @opts $hostSpec @rest
exit $LASTEXITCODE
