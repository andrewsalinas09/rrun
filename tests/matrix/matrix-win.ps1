# tests/matrix/matrix-win.ps1 -- the WINDOWS-CONTAINER lane of the
# environment matrix: the axes Linux containers cannot host (CLAUDE.md
# section 4): real PowerShell 5.1, real Windows OpenSSH sshd, cmd.exe command
# lines, and the cmd / powershell(5.1) / pwsh(7) DefaultShell gateway axis --
# including a reproducible testbed for the streamed-session wedge race.
#
# Requires the Docker Desktop WINDOWS engine (desktop-windows context):
# Windows features Containers + Microsoft-Hyper-V, then DockerCli.exe
# -SwitchDaemon. The Linux lane (matrix.sh) is unaffected -- WSL integration
# always talks to the Linux engine.
#
# The sender runs bin/rrun under GIT BASH on the host (itself an axis: MSYS
# userland, no WSL). Exit code = failures.
#
# -Mode splits the lane so CI can GATE on what is deterministic (external-
# review round 11, finding 5):
#   deterministic  small + UTF-16LE cells; no streaming, no wedge race -> the
#                  required CI job
#   stress         streamed-large cells; reproduces the documented Windows-sshd
#                  wedge race with retries -> the advisory CI job
#   all            both (local runs)
param([ValidateSet('all', 'deterministic', 'stress')][string]$Mode = 'all')
$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot

# find a Windows engine: the CURRENT context (CI runners: plain dockerd,
# already windows) or Docker Desktop's desktop-windows context (local dev)
$os = docker info --format '{{.OSType}}' 2>$null
if ($os -ne 'windows') {
  $ctxs = @(docker context ls --format '{{.Name}}' 2>$null)
  if ($ctxs -contains 'desktop-windows') {
    $env:DOCKER_CONTEXT = 'desktop-windows'
    $os = docker info --format '{{.OSType}}' 2>$null
  }
}
if ($os -ne 'windows') {
  Write-Host 'FATAL: no docker Windows engine. Locally: enable the Containers and'
  Write-Host 'Microsoft-Hyper-V Windows features, reboot, then run:'
  Write-Host '  & "$env:ProgramFiles\Docker\Docker\DockerCli.exe" -SwitchDaemon'
  exit 1
}

Write-Host '[build] rrun-mx-winnode (servercore base: first pull is several GB)'
docker build -t rrun-mx-winnode -f Dockerfile.winnode . | Out-Null
if ($LASTEXITCODE) { Write-Host 'FATAL: image build failed'; exit 1 }

$runId = "wmx$PID"
$tmp = Join-Path $env:TEMP "rrun-$runId"
New-Item -ItemType Directory -Force -Path $tmp, (Join-Path $tmp 'keys'), (Join-Path $tmp 'home') | Out-Null
& "$env:SystemRoot\System32\OpenSSH\ssh-keygen.exe" -q -t ed25519 -N '' -f (Join-Path $tmp 'key')
Copy-Item (Join-Path $tmp 'key.pub') (Join-Path $tmp 'keys\authorized_keys')

$variants = @(
  @{ Name = 'win-cmd';  Shell = 'cmd';        Port = 22151 },
  @{ Name = 'win-ps51'; Shell = 'powershell'; Port = 22152 },
  @{ Name = 'win-pwsh'; Shell = 'pwsh';       Port = 22153 }
)
$rc = 1
try {
  foreach ($v in $variants) {
    Write-Host "[run] $($v.Name) (DEFAULT_SHELL=$($v.Shell), 127.0.0.1:$($v.Port))"
    # plain -p PORT:22, NOT -p 127.0.0.1:PORT:22 -- Windows NAT rejects host
    # IPs in port bindings ("does not support host IP addresses in NAT
    # settings"). The sender still connects via 127.0.0.1; WinNAT forwards it.
    # Starts are STAGGERED with a boot-check + one retry: three hyperv
    # containers launched back-to-back can race, one dying at boot with
    # exit -1 and empty logs (observed; solo start of the same image works).
    $cname = "rrun-$runId-$($v.Name)"
    foreach ($attempt in 1, 2) {
      docker run -d --name $cname --label "rrun-matrix=$runId" `
        -e "DEFAULT_SHELL=$($v.Shell)" -p "$($v.Port):22" `
        -v "$tmp\keys:C:\keys:ro" rrun-mx-winnode | Out-Null
      Start-Sleep -Seconds 8
      if ((docker inspect -f '{{.State.Running}}' $cname) -eq 'true') { break }
      Write-Host "  WARN: $($v.Name) died at boot (attempt $attempt); retrying"
      docker rm -f $cname | Out-Null
    }
  }
  $triples = @($variants | ForEach-Object { "$($_.Name):$($_.Port):$($_.Shell)" })
  $env:WIN_LANE_MODE = $Mode
  & "$env:ProgramFiles\Git\bin\bash.exe" win-sender.sh $tmp @triples
  $rc = $LASTEXITCODE
} finally {
  docker ps -aq --filter "label=rrun-matrix=$runId" | ForEach-Object { docker rm -f $_ | Out-Null }
  Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
}
exit $rc
