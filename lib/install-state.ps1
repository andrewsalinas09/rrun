# lib/install-state.ps1 -- ownership manifest + native-exec guard, dot-sourced
# by install.ps1 and uninstall.ps1, and driven directly (no machine mutation)
# by tests/install-state-tests.ps1.
#
# WHY A MANIFEST: uninstall used to reconstruct ownership from CURRENT values,
# which cannot work -- ownership is history, not state. Deterministic
# counterexamples (external-review round 11, finding 1):
#   * a PRE-EXISTING user PYTHONIOENCODING=utf-8 was deleted because it merely
#     EQUALED the value rrun would have set;
#   * a PATH entry for %USERPROFILE%\.local\bin that predated rrun was removed
#     once the directory emptied;
#   * a pre-existing BASH_ENV pointing at ~/.bashrc was assumed to be an old
#     rrun install and silently overwritten, then deleted.
# So install.ps1 now records the pre-install state here BEFORE modifying
# anything, and uninstall.ps1 restores a setting only when its current value
# still equals what rrun set -- if the user changed it after install, it is
# warned about and left alone. No manifest (pre-2.7.0 install)? Uninstall
# falls back to removing only what markers/paths PROVE is rrun's, and leaves
# env/PATH with loud instructions instead of guessing.
#
# history: v1.0 2026-08-11 created (external-review round 11, findings 1-4).
$ErrorActionPreference = 'Stop'

function Invoke-Native([scriptblock]$Cmd) {
  # Run a native executable with $ErrorActionPreference temporarily 'Continue'.
  # Windows PowerShell 5.1 raises a terminating NativeCommandError under
  # EAP=Stop as soon as a native child writes to stderr (even a benign
  # diagnostic, even with 2>$null) -- so an installer that intends to judge the
  # call by $LASTEXITCODE can die before reaching that logic. The exact class
  # already shipped once in bin/rrun.ps1 (v1.11); this helper is the same fix
  # centralized for the install/uninstall lifecycle. Success is decided by the
  # caller from $LASTEXITCODE, which survives this function.
  $prev = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try { & $Cmd } finally { $ErrorActionPreference = $prev }
}

function Get-RrunStatePath {
  Join-Path $env:USERPROFILE '.rrun\install-state.json'
}

function Read-RrunState([string]$Path) {
  # $null on missing OR unparseable: a corrupt manifest must degrade to the
  # same conservative no-manifest path, never abort an uninstall.
  if (-not (Test-Path $Path)) { return $null }
  try { (Get-Content -Raw $Path) | ConvertFrom-Json } catch { $null }
}

function Write-RrunState($State, [string]$Path) {
  New-Item -ItemType Directory -Force -Path (Split-Path $Path -Parent) | Out-Null
  [IO.File]::WriteAllText($Path, ($State | ConvertTo-Json -Depth 10))
}

function New-RrunState(
  [string]$PriorBashEnv,
  [string]$PriorPythonIoEncoding,
  [bool]$PriorPathHadEntry,
  [bool]$PriorBashrcExisted,
  [bool]$PriorBashProfileExisted
) {
  # Empty-string priors normalize to $null ("was absent") so the restore logic
  # has one representation of absence; JSON round-trips $null faithfully.
  [pscustomobject]@{
    version     = 1
    installedAt = (Get-Date).ToString('o')
    prior       = [pscustomobject]@{
      bashEnv            = if ($PriorBashEnv) { $PriorBashEnv } else { $null }
      pythonIoEncoding   = if ($PriorPythonIoEncoding) { $PriorPythonIoEncoding } else { $null }
      pathHadEntry       = $PriorPathHadEntry
      bashrcExisted      = $PriorBashrcExisted
      bashProfileExisted = $PriorBashProfileExisted
    }
    set         = [pscustomobject]@{
      pathEntryAdded     = $false
      bashEnv            = $null
      pythonIoEncoding   = $null
      bashProfileCreated = $false
    }
    claudeConfigDir = $null
    wslDistro       = $null
  }
}

function Resolve-EnvRestore($Prior, $Set, $Current) {
  # The uninstall decision table for one user env var. Returns
  # @{ Action = 'leave-not-ours' | 'leave-changed' | 'delete' | 'restore'; Value = ... }
  #   * rrun never set it            -> leave (whatever is there is the user's)
  #   * user changed it after install-> leave, warn (their change wins)
  #   * rrun set it over nothing     -> delete
  #   * rrun set it over a prior     -> restore the prior value
  if (-not $Set) { return @{ Action = 'leave-not-ours' } }
  if ($Current -cne $Set) { return @{ Action = 'leave-changed' } }
  if (-not $Prior) { return @{ Action = 'delete' } }
  @{ Action = 'restore'; Value = $Prior }
}
