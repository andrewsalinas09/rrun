# rrun (Windows/PowerShell shim) — forwards to WSL ~/.local/bin/rrun so payloads cross
# shell boundaries as data, never as escaped strings. Installed by install.ps1 into
# %USERPROFILE%\.local\bin (PowerShell resolves `rrun` -> rrun.ps1 via PATH).
#   * wsl.exe -e     : direct exec, WSL default shell never re-parses argv ($ survives)
#   * file args      : translated C:\x -> /mnt/c/x for WSL
#   * host "local"   : ps -> powershell.exe -EncodedCommand here; bash/sh -> wsl bash
#   * $HOME trampoline: sh -c '... "$@"' expands $HOME inside WSL; payload args pass
#                      as untouched positional params (no hardcoded WSL username).
# usage mirrors WSL rrun:  rrun [-s ps|bash|sh] [-J jumps] [-n] <host[,hop2,...]|local> <script|-|-c "cmds">
# history: v1 2026-08-10 created from transcript-error audit; v1.1 $HOME trampoline,
#          CLIXML suppression in local ps mode.
$ErrorActionPreference = 'Stop'

function ToWsl([string]$p) {
  $r = (Resolve-Path -LiteralPath $p).Path -replace '\\', '/'
  if ($r -match '^([A-Za-z]):(.*)$') { return "/mnt/$($Matches[1].ToLower())$($Matches[2])" }
  return $r
}

$rest = @($args)
$opts = @(); $shell = ''
while ($rest.Count -gt 0 -and $rest[0] -like '-*' -and $rest[0] -ne '-c' -and $rest[0] -ne '-') {
  switch ($rest[0]) {
    '-s' { $shell = $rest[1]; $opts += @('-s', $rest[1]); $rest = $rest[2..($rest.Count)] }
    '-J' { $opts += @('-J', $rest[1]); $rest = $rest[2..($rest.Count)] }
    default { $opts += $rest[0]; $rest = $rest[1..($rest.Count)] }
  }
}
if ($rest.Count -lt 2) {
  Write-Error 'usage: rrun [-s ps|bash|sh] [-J jumps] [-n] <host[,hop2,...]|local> <script | - | -c "cmds">'
  exit 2
}
$hostSpec = $rest[0]; $rest = $rest[1..($rest.Count - 1)]

if ($hostSpec -eq 'local') {
  $src = $rest[0]
  switch ($src) {
    '-c' { $payload = $rest[1] }
    '-'  { $payload = [Console]::In.ReadToEnd() }
    default { $payload = [IO.File]::ReadAllText((Resolve-Path -LiteralPath $src).Path) }
  }
  if (-not $shell) { $shell = if ($src -match '\.(sh|bash)$') { 'bash' } else { 'ps' } }
  if ($shell -eq 'ps') {
    # suppress "#< CLIXML ... Preparing modules" stderr noise under -EncodedCommand
    $payload = '$ProgressPreference=''SilentlyContinue''; ' + $payload
    $b64 = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($payload))
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -EncodedCommand $b64
    exit $LASTEXITCODE
  } else {
    $b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($payload))
    & wsl.exe -e bash -c "echo $b64 | base64 -d | $shell"
    exit $LASTEXITCODE
  }
}

# remote: translate args that are existing local files (script payloads) to /mnt paths
$fwd = foreach ($a in $rest) {
  if ($a -notlike '-*' -and (Test-Path -LiteralPath $a -PathType Leaf)) { ToWsl $a } else { $a }
}
& wsl.exe -e sh -c 'exec "$HOME/.local/bin/rrun" "$@"' rrun @opts $hostSpec @fwd
exit $LASTEXITCODE
