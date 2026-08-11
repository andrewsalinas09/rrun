# Sweep payload for the Windows lane: kill WEDGED streamed-session shells so
# the next streaming retry starts clean (the race is bursty -- consecutive
# blind retries inside a burst all lose; test.ps1 proved sweep-then-retry on
# real hosts). Delivered by rrun itself as a SMALL payload: non-streamed
# sessions are immune to the race. A wedged shell is an -EncodedCommand
# powershell/pwsh older than 30s with under 1s of CPU; this sweep's own
# process is excluded by $PID and by its age.
Get-CimInstance Win32_Process -Filter "Name='powershell.exe' OR Name='pwsh.exe'" | ForEach-Object {
  if ($_.ProcessId -ne $PID -and $_.CommandLine -match 'EncodedCommand' -and
      ((Get-Date) - $_.CreationDate).TotalSeconds -gt 30) {
    $p = Get-Process -Id $_.ProcessId -ErrorAction SilentlyContinue
    if ($p -and $p.TotalProcessorTime.TotalSeconds -lt 1) {
      Stop-Process -Id $_.ProcessId -Force
    }
  }
}
Write-Output swept
