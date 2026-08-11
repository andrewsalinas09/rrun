# rrun (Windows/PowerShell shim) -- forwards to WSL ~/.local/bin/rrun so payloads cross
# shell boundaries as data, never as escaped strings. Installed by install.ps1 into
# %USERPROFILE%\.local\bin (PowerShell resolves `rrun` -> rrun.ps1 via PATH).
#   * wsl.exe -e      : direct exec, WSL default shell never re-parses argv ($ survives)
#   * script operand  : ONLY the script-source arg is translated C:\x -> /mnt/c/x;
#                       everything after -c is opaque data, never touched
#   * host "local"    : ps -> powershell.exe -EncodedCommand here; bash/sh -> wsl bash.
#                       Bounded by the 32767-char process command-line limit;
#                       double base64 costs ~3.6 chars/byte -> ~9KB ps payload.
#                       Use powershell -File directly beyond that.
#   * $HOME trampoline: sh -c '... "$@"' expands $HOME inside WSL; payload args pass
#                       as untouched positional params (no hardcoded WSL username).
#   * host "adb[:serial]": payload runs on an Android device via adb shell. Handled
#                       here, not forwarded to WSL -- adb + USB are Windows-side
#                       (WSL2 has no USB passthrough). Defaults to -s sh; streams
#                       over stdin past RRUN_STREAM_LIMIT so the 32767-char
#                       Windows command line cannot truncate a big payload.
# usage mirrors WSL rrun:  rrun [-s ps|bash|sh] [-J jumps] [-n] <host[,hop2,...]|local|adb[:serial]> <script|-|-c "cmds">
# history: v1 2026-08-10 created from transcript-error audit; v1.1 $HOME trampoline,
#          CLIXML suppression; v1.2 review fixes -- -n honored in local mode (was
#          EXECUTING on dry-run), -c args no longer path-translated, -s validated,
#          -J rejected for host local; v1.3 "local -c" with no command now exits 2
#          (out-of-range $rest[1] was silently $null -> empty successful run);
#          v1.4 local ps payloads never textually modified (prefix broke
#          param()/using -- scriptblock wrapper instead); v1.5 wrapper appends
#          `if (-not $?) { exit 1 }` so failing local ps payloads exit non-zero
#          (the & operator otherwise swallowed the failure -> false success);
#          v1.6 remote dry-run prints a stderr notice that the output is
#          bash-quoted (not PowerShell paste-safe); ~9KB size doc fix;
#          v1.7 status-honest local bash/sh decode (broken base64 -> loud
#          125, not silent success); v1.8 file-backed decode -- execution
#          byte-for-byte ($(...) stripped trailing newlines, changing
#          backslash-newline-final payloads); v1.9 file operands read as RAW
#          BYTES (ReadAllText BOM-decoded + UTF-8 re-encoded bash/sh files --
#          text preservation, not bytes) + cleanup traps on the temp file;
#          v1.10 stdin (-) is raw process stdin bytes too (last text-typed
#          ingestion path; Console.In re-encoded UTF-16/binary stdin);
#          v1.11 native stderr no longer THROWS under Windows PowerShell 5.1 --
#          `& native.exe` raises a terminating NativeCommandError while
#          EAP=Stop the moment the child writes to stderr, so a payload that
#          merely printed a warning made the shim throw instead of returning
#          the payload's exit code (transparency violation). pwsh 7 does not
#          do this, so it survived every local run; a real install on a 5.1
#          host caught it. EAP is relaxed around all three native calls;
#          v1.12 local bash/sh path worked ONLY under pwsh 7: the wrapper's
#          trap used \"-escaped quotes, and Windows PowerShell 5.1 re-quotes
#          native arguments with legacy rules that mangle them, so bash got a
#          truncated `trap "rm -f \"` -> "trap: usage: trap [-lp] ..." and the
#          entire -s bash local path failed. Trap body now uses single quotes;
#          nothing with escaped quotes may cross as a native argument;
#          v1.13 2026-08-11 adb transport (host "adb"/"adb:<serial>"). `adb
#          shell` is another boundary that eats hand-quoted payloads: a find(1)
#          with escaped parens arrived at the device stripped, matched nothing
#          and exited 0 -- a silent wrong answer, the class this tool exists to
#          kill. TMPDIR pinned to /data/local/tmp (Android has no /tmp and
#          mktemp is the wrapper's first statement); stdin-streaming above
#          RRUN_STREAM_LIMIT.
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

if ($hostSpec -eq 'adb' -or $hostSpec -like 'adb:*') {
  # Handled HERE, never forwarded to WSL: the adb client and the USB device are
  # both Windows-side and WSL2 has no USB passthrough, so a forwarded 'adb'
  # would find no binary (or a second adb server that sees no devices).
  if ($jump) { Fail 'rrun: -J is meaningless for an adb target' }
  $serial = ''
  if ($hostSpec -like 'adb:*') { $serial = $hostSpec.Substring(4) }
  if ($serial -and $serial -notmatch '^[A-Za-z0-9._:-]+$') {
    Fail "rrun: invalid adb serial '$serial' (allowed: letters, digits, . _ : -)"
  }
  $src = $rest[0]
  $payloadBytes = $null
  switch ($src) {
    '-c' {
      if ($rest.Count -lt 2) { Fail 'rrun: -c needs a command string' }
      $payloadBytes = [Text.Encoding]::UTF8.GetBytes($rest[1])
    }
    '-' {
      # raw process stdin, byte-for-byte (see the local branch's note)
      $ms = New-Object IO.MemoryStream
      [Console]::OpenStandardInput().CopyTo($ms)
      $payloadBytes = $ms.ToArray()
    }
    default { $payloadBytes = [IO.File]::ReadAllBytes((Resolve-Path -LiteralPath $src).Path) }
  }
  # Stock Android ships /system/bin/sh and neither bash nor PowerShell.
  if (-not $shell) { $shell = 'sh' }
  if ($shell -eq 'ps') {
    Fail 'rrun: -s ps is not valid for an adb target (Android has no PowerShell); use -s sh'
  }
  $pb64 = [Convert]::ToBase64String($payloadBytes)
  # TMPDIR is pinned because mktemp is this wrapper's FIRST statement and Android
  # has no /tmp. The trap body uses single quotes, never \"-escaped quotes: 5.1
  # re-quotes native arguments with legacy rules that mangle those (see v1.12).
  $pre = 'TMPDIR=${TMPDIR:-/data/local/tmp}; t=$(mktemp) || exit 125; trap ''rm -f "$t"'' 0; trap exit 1 2 15;'
  $post = '|| { echo rrun: adb decode failed >&2; exit 125; }; ' + $shell + ' "$t"'
  $run = $pre + ' echo ' + $pb64 + ' | base64 -d > "$t" ' + $post
  $limit = if ($env:RRUN_STREAM_LIMIT) { [int]$env:RRUN_STREAM_LIMIT } else { 6000 }
  # adb.exe is a native Windows process, so the command counts against the
  # 32767-char command-line limit. Past the threshold the payload rides on stdin
  # (adb forwards it to the device); that costs the payload its own stdin but
  # keeps arbitrarily large scripts working.
  $stream = $run.Length -gt $limit
  if ($stream) { $run = $pre + ' base64 -d > "$t" ' + $post }
  $argv = @()
  if ($serial) { $argv += @('-s', $serial) }
  $argv += @('shell', $run)
  if ($dry) {
    if ($stream) { Write-Output "printf %s $pb64 | adb $($argv -join ' ')" }
    else { Write-Output "adb $($argv -join ' ')" }
    exit 0
  }
  $ErrorActionPreference = 'Continue'   # see v1.11: native stderr must not throw
  if ($stream) { $pb64 | & adb.exe @argv } else { & adb.exe @argv }
  exit $LASTEXITCODE
}

if ($hostSpec -eq 'local') {
  if ($jump) { Fail 'rrun: -J is meaningless with host "local"' }
  $src = $rest[0]
  $payloadBytes = $null
  switch ($src) {
    '-c' {
      if ($rest.Count -lt 2) { Fail 'rrun: -c needs a command string' }
      $payload = $rest[1]
    }
    '-'  {
      # `-` means RAW PROCESS STDIN, byte-for-byte (matching the core, which
      # pipes stdin straight into base64). Console.In.ReadToEnd() decoded to a
      # .NET string and re-encoded as UTF-8, transforming UTF-16/legacy/binary
      # stdin. PowerShell object-pipeline input is deliberately NOT what `-`
      # means -- that would compromise byte semantics.
      # Consequence, documented in the README: `Get-Content x | rrun host -`
      # does NOT feed those objects here; the raw handle is read instead (and
      # can block on a console). DON'T try to detect that with
      # $MyInvocation.ExpectingInput -- measured True for BOTH the object
      # pipeline AND `cmd /c "... -" < file`, which is the supported raw-stdin
      # form the CI regression uses, so a guard on it would reject the very
      # invocation this path exists to serve.
      $ms = New-Object IO.MemoryStream
      [Console]::OpenStandardInput().CopyTo($ms)
      $payloadBytes = $ms.ToArray()
    }
    default {
      # file operands ride as RAW BYTES. ReadAllText would BOM-decode and later
      # re-encode as UTF-8 -- text preservation, not byte preservation: a
      # UTF-16LE shell file reached WSL deterministically transformed. Only the
      # ps path needs source TEXT (decoded BOM-aware below); bash/sh get the
      # original bytes, exactly like the core and the Git Bash shim.
      $payloadBytes = [IO.File]::ReadAllBytes((Resolve-Path -LiteralPath $src).Path)
    }
  }
  if (-not $shell) { $shell = if ($src -match '\.(sh|bash)$') { 'bash' } else { 'ps' } }
  if ($shell -eq 'ps') {
    # payload text never modified (a prepended statement broke param()/using,
    # which must be a script's first statements): a fixed wrapper sets
    # ProgressPreference (suppresses "#< CLIXML ... Preparing modules" stderr
    # noise) and runs the decoded source as its own scriptblock. The epilogue
    # exits non-zero when the payload's last statement failed ($? read INSIDE
    # the scriptblock, before the & operator masks it) so failures aren't
    # silently swallowed. [char]10 keeps it off the payload's final line.
    if ($null -ne $payloadBytes) {
      # BOM-aware decode, same contract as the remote wrapper: UTF-8/16/32
      # BOMs honored, BOM-less = UTF-8
      $payload = (New-Object IO.StreamReader((New-Object IO.MemoryStream(,$payloadBytes)), $true)).ReadToEnd()
    }
    $pb64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($payload))
    $wrapper = '$ProgressPreference=''SilentlyContinue''; & ([scriptblock]::Create([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String(''' + $pb64 + ''')) + [char]10 + ''if (-not $?) { exit 1 }''))'
    $b64 = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($wrapper))
    if ($dry) { Write-Output "powershell -NoProfile -ExecutionPolicy Bypass -EncodedCommand $b64"; exit 0 }
    # Native stderr must NOT become a terminating error. Under Windows
    # PowerShell 5.1 (the DEFAULT powershell.exe), `& native.exe` raises a
    # terminating NativeCommandError while EAP=Stop as soon as the child writes
    # to stderr -- so a payload that merely PRINTS A WARNING made rrun throw
    # instead of returning the payload's exit code. That breaks the transparency
    # contract: rrun reserves nothing and adds no semantics of its own. pwsh 7
    # does not do this, which is why it went unnoticed until a real install ran
    # on a 5.1 host. See v1.11.
    $ErrorActionPreference = 'Continue'
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -EncodedCommand $b64
    exit $LASTEXITCODE
  } else {
    $b64 = if ($null -ne $payloadBytes) { [Convert]::ToBase64String($payloadBytes) }
           else { [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($payload)) }
    # file-backed status-honest decode (see core v2.3.5): a plain pipeline hid
    # decoder failures (silent success), s=$(...) stripped trailing newlines at
    # execution time, and the traps clean the decoded payload up on normal exit
    # and catchable signals. Exit status = the executor's own.
    # The trap body uses SINGLE quotes: 'rm -f "$t"', never "rm -f \"$t\"".
    # Windows PowerShell 5.1 re-quotes native-command arguments with legacy
    # rules that mangle backslash-escaped quotes, so the \" form arrived at bash
    # as `trap "rm -f \"` -> `trap: usage: trap [-lp] ...` and the whole local
    # bash/sh path failed. pwsh 7 passes it through intact, so this was invisible
    # until a real 5.1 host ran it. Same class the tool exists to kill -- a
    # metacharacter eaten at an argument boundary -- so the rule is rrun's own:
    # nothing with escaped quotes may cross as a native argument. (The payload
    # itself already crosses as inert base64; only this wrapper was at risk.)
    $run = 't=$(mktemp) || exit 125; trap ''rm -f "$t"'' 0; trap exit 1 2 15; echo ' + $b64 + ' | base64 -d > "$t" || { echo rrun: local decode failed >&2; exit 125; }; ' + $shell + ' "$t"'
    if ($dry) { Write-Output "wsl -e bash -c `"$run`""; exit 0 }
    $ErrorActionPreference = 'Continue'   # see v1.11 note above: native stderr must not throw
    & wsl.exe -e bash -c $run
    exit $LASTEXITCODE
  }
}

# remote: translate ONLY the script-source operand (a real local file) to a /mnt
# path. Arguments following -c (and "-") are opaque payload data -- never touched.
if ($rest[0] -ne '-c' -and $rest[0] -ne '-' -and (Test-Path -LiteralPath $rest[0] -PathType Leaf)) {
  $rest[0] = ToWsl $rest[0]
}
if ($dry) {
  # the core renders dry-runs with bash %q quoting -- paste-safe for bash/WSL,
  # NOT for PowerShell (backslash escapes mean nothing here, so a metachar arg
  # could re-parse). Warn on stderr; stdout stays machine-parseable.
  [Console]::Error.WriteLine('rrun: dry-run below is bash-quoted (run it from bash/WSL; not PowerShell paste-safe)')
}
# see v1.11 note: a REMOTE payload writing to stderr must not make the shim throw
$ErrorActionPreference = 'Continue'
& wsl.exe -e sh -c 'exec "$HOME/.local/bin/rrun" "$@"' rrun @opts $hostSpec @rest
exit $LASTEXITCODE
