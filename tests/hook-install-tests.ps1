# hook-install-tests.ps1 -- regression suite for hooks/install-hook.ps1 AND its
# removal counterpart hooks/uninstall-hook.ps1.
#
# This is the one part of rrun's lifecycle that edits a file the USER owns and
# may have hand-tuned. "It merged cleanly" therefore has to be a test, not a
# promise. Everything runs against throwaway config dirs; ~/.claude is untouched.
$ErrorActionPreference = 'Continue'
$repo = Split-Path $PSScriptRoot -Parent
$installer = Join-Path $repo 'hooks\install-hook.ps1'
$remover = Join-Path $repo 'hooks\uninstall-hook.ps1'
# must stay byte-identical to what install-hook.ps1 wires -- used to plant
# realistic pre-existing rrun handlers inside shared groups
$rrunCmd = 'bash "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/hooks/rrun-boundary-warn.sh"'
$fail = 0

function Check([string]$name, [bool]$ok, [string]$detail = '') {
  if ($ok) { Write-Host "  PASS  $name" }
  else { Write-Host "  FAIL  $name  $detail"; $script:fail++ }
}
function NewDir { $d = Join-Path ([IO.Path]::GetTempPath()) ("rrun-hooktest-" + [Guid]::NewGuid().ToString('N').Substring(0, 8)); New-Item -ItemType Directory -Force -Path $d | Out-Null; $d }
function ReadJson([string]$d) { Get-Content -Raw (Join-Path $d 'settings.json') | ConvertFrom-Json }
# NOTE: always call OurEntries as @(OurEntries $j).Count, never (OurEntries $j).Count.
# PowerShell unrolls a single-element array returned from a function, so the
# caller gets a SCALAR -- and under Windows PowerShell 5.1 a PSCustomObject has
# no .Count, so the comparison silently comes out $null -ne 1 and the assertion
# fails even though the merge was correct. PS 7 added .Count to every object,
# which hid this until the suite ran on a 5.1 host.
function OurEntries($j) { @(@($j.hooks.PreToolUse) | Where-Object { @($_.hooks) | Where-Object { "$($_.command)" -match 'rrun-boundary-warn' } }) }

Write-Host '[fresh config dir (no settings.json)]'
$d = NewDir
& $installer -ConfigDir $d -RepoRoot $repo -Quiet
$j = ReadJson $d
Check 'creates settings.json with our hook' (@(OurEntries $j).Count -eq 1)
Check 'matcher covers Bash and PowerShell' ((OurEntries $j)[0].matcher -eq 'Bash|PowerShell')
Check 'deploys launcher + detector' ((Test-Path (Join-Path $d 'hooks\rrun-boundary-warn.sh')) -and (Test-Path (Join-Path $d 'hooks\rrun-boundary-warn.py')))
$sh = [IO.File]::ReadAllText((Join-Path $d 'hooks\rrun-boundary-warn.sh'))
Check 'launcher deployed with LF endings (CRLF breaks the shebang)' (-not $sh.Contains("`r"))
Check 'no absolute path baked into the wired command' ((OurEntries $j)[0].hooks[0].command -notmatch '[A-Za-z]:\\|/c/Users')
Remove-Item -Recurse -Force $d -ErrorAction SilentlyContinue

Write-Host '[existing hand-tuned settings.json]'
$d = NewDir
@'
{
  "model": "opus",
  "permissions": { "allow": ["Bash(git status)", "Read"], "deny": ["Bash(rm -rf *)"] },
  "env": { "DEBUG": "true" },
  "hooks": {
    "PreToolUse": [
      { "matcher": "Write", "hooks": [{ "type": "command", "command": "echo someone-elses-hook" }] }
    ],
    "PostToolUse": [
      { "matcher": "Edit", "hooks": [{ "type": "command", "command": "prettier --write" }] }
    ]
  }
}
'@ | Set-Content -Path (Join-Path $d 'settings.json') -Encoding UTF8
& $installer -ConfigDir $d -RepoRoot $repo -Quiet
$j = ReadJson $d
Check 'our hook added' (@(OurEntries $j).Count -eq 1)
Check "someone else's PreToolUse hook survives" (@(@($j.hooks.PreToolUse) | Where-Object { $_.matcher -eq 'Write' }).Count -eq 1)
Check 'PostToolUse hooks survive' ($j.hooks.PostToolUse[0].hooks[0].command -eq 'prettier --write')
Check 'unrelated top-level keys survive' ($j.model -eq 'opus' -and $j.env.DEBUG -eq 'true')
Check 'nested permissions survive (ConvertTo-Json depth)' (@($j.permissions.allow).Count -eq 2 -and @($j.permissions.deny).Count -eq 1)
Check 'backup written' (Test-Path (Join-Path $d 'settings.json.rrun-bak'))

Write-Host '[idempotency: three runs]'
& $installer -ConfigDir $d -RepoRoot $repo -Quiet
& $installer -ConfigDir $d -RepoRoot $repo -Quiet
$j = ReadJson $d
Check 'still exactly one rrun entry after 3 runs' (@(OurEntries $j).Count -eq 1)
Check "still exactly one of someone else's" (@(@($j.hooks.PreToolUse) | Where-Object { $_.matcher -eq 'Write' }).Count -eq 1)
Remove-Item -Recurse -Force $d -ErrorAction SilentlyContinue

Write-Host '[malformed settings.json]'
$d = NewDir
'{ this is not json' | Set-Content -Path (Join-Path $d 'settings.json') -Encoding UTF8
$threw = $false
try { & $installer -ConfigDir $d -RepoRoot $repo -Quiet 2>$null } catch { $threw = $true }
Check 'refuses to guess, throws instead of clobbering' $threw
Check 'REGRESSION: corrupt file is NOT backed up (would clobber a good backup)' (-not (Test-Path (Join-Path $d 'settings.json.rrun-bak')))
Check 'original left intact' ((Get-Content -Raw (Join-Path $d 'settings.json')).Trim() -eq '{ this is not json')
Remove-Item -Recurse -Force $d -ErrorAction SilentlyContinue

Write-Host '[corrupt settings must not destroy the last GOOD backup]'
# The failure sequence this guards: settings valid -> rrun runs (good backup
# exists) -> settings later corrupted -> rerun. The old code copied the corrupt
# file over the good backup BEFORE parsing -- destroying the recovery copy at
# exactly the moment it was needed.
$d = NewDir
'{ "model": "opus" }' | Set-Content -Path (Join-Path $d 'settings.json') -Encoding UTF8
& $installer -ConfigDir $d -RepoRoot $repo -Quiet
$bak = Join-Path $d 'settings.json.rrun-bak'
Check 'good backup exists after a clean run' ((Get-Content -Raw $bak | ConvertFrom-Json).model -eq 'opus')
'{ truncated garba' | Set-Content -Path (Join-Path $d 'settings.json') -Encoding UTF8
$threw = $false
try { & $installer -ConfigDir $d -RepoRoot $repo -Quiet 2>$null } catch { $threw = $true }
Check 'rerun on corrupt settings throws' $threw
Check 'REGRESSION: good backup survives the corrupt rerun (install)' ((Get-Content -Raw $bak | ConvertFrom-Json).model -eq 'opus')
$threw = $false
try { & $remover -ConfigDir $d -Quiet 2>$null } catch { $threw = $true }
Check 'uninstall on corrupt settings throws' $threw
Check 'REGRESSION: good backup survives the corrupt rerun (uninstall)' ((Get-Content -Raw $bak | ConvertFrom-Json).model -eq 'opus')
Remove-Item -Recurse -Force $d -ErrorAction SilentlyContinue

Write-Host '[shared matcher group: other handlers survive install AND uninstall]'
# A user may legitimately append their own handler to OUR matcher group. The
# old code treated any group containing an rrun-matching handler as wholly
# rrun's and dropped it -- deleting the user's handler on update or uninstall.
$d = NewDir
# built from objects, not string templating: $rrunCmd contains "$"/quotes that
# regex-replacement rules would mis-handle
[pscustomobject]@{
  hooks = [pscustomobject]@{
    PreToolUse = @([pscustomobject]@{
      matcher = 'Bash|PowerShell'
      hooks   = @(
        [pscustomobject]@{ type = 'command'; command = 'echo KEEP-ME' },
        [pscustomobject]@{ type = 'command'; shell = 'bash'; command = $rrunCmd; timeout = 10 }
      )
    })
  }
} | ConvertTo-Json -Depth 10 | Set-Content -Path (Join-Path $d 'settings.json') -Encoding UTF8
& $installer -ConfigDir $d -RepoRoot $repo -Quiet
$j = ReadJson $d
$allCmds = @($j.hooks.PreToolUse | ForEach-Object { @($_.hooks) } | ForEach-Object { "$($_.command)" })
Check 'REGRESSION: co-tenant handler survives self-update' ($allCmds -contains 'echo KEEP-ME')
Check 'exactly one rrun handler after self-update' (@($allCmds | Where-Object { $_ -eq $rrunCmd }).Count -eq 1)
& $remover -ConfigDir $d -Quiet
$j = ReadJson $d
$allCmds = @(@($j.hooks.PreToolUse) | ForEach-Object { @($_.hooks) } | ForEach-Object { "$($_.command)" })
Check 'REGRESSION: co-tenant handler survives uninstall' ($allCmds -contains 'echo KEEP-ME')
Check 'rrun handler gone after uninstall' (@($allCmds | Where-Object { $_ -eq $rrunCmd }).Count -eq 0)
Remove-Item -Recurse -Force $d -ErrorAction SilentlyContinue

Write-Host '[namespace collision: similar-named foreign handler is never ours]'
# Ownership is exact command identity, not substring: a foreign handler whose
# command merely CONTAINS 'rrun-boundary-warn' must survive both operations.
$d = NewDir
@'
{
  "hooks": {
    "PreToolUse": [
      { "matcher": "Bash",
        "hooks": [{ "type": "command", "command": "/opt/audit/rrun-boundary-warn-logger --tee" }] }
    ]
  }
}
'@ | Set-Content -Path (Join-Path $d 'settings.json') -Encoding UTF8
& $installer -ConfigDir $d -RepoRoot $repo -Quiet
$j = ReadJson $d
$lookalike = @($j.hooks.PreToolUse | ForEach-Object { @($_.hooks) } | Where-Object { "$($_.command)" -match 'logger' })
Check 'REGRESSION: lookalike foreign handler survives install' (@($lookalike).Count -eq 1)
& $remover -ConfigDir $d -Quiet
$j = ReadJson $d
$lookalike = @(@($j.hooks.PreToolUse) | ForEach-Object { @($_.hooks) } | Where-Object { "$($_.command)" -match 'logger' })
Check 'REGRESSION: lookalike foreign handler survives uninstall' (@($lookalike).Count -eq 1)
Check 'our entry really was removed around it' (-not ((Get-Content -Raw (Join-Path $d 'settings.json')) -match 'rrun-boundary-warn\.sh'))
Remove-Item -Recurse -Force $d -ErrorAction SilentlyContinue

Write-Host '[uninstall round-trip on a hand-tuned config]'
$d = NewDir
@'
{
  "model": "opus",
  "permissions": { "allow": ["Read"] },
  "hooks": {
    "PreToolUse": [
      { "matcher": "Write", "hooks": [{ "type": "command", "command": "echo someone-elses-hook" }] }
    ],
    "PostToolUse": [
      { "matcher": "Edit", "hooks": [{ "type": "command", "command": "prettier --write" }] }
    ]
  }
}
'@ | Set-Content -Path (Join-Path $d 'settings.json') -Encoding UTF8
& $installer -ConfigDir $d -RepoRoot $repo -Quiet
& $remover -ConfigDir $d -Quiet
$j = ReadJson $d
Check 'rrun entry gone' (@(OurEntries $j).Count -eq 0)
Check "someone else's PreToolUse group untouched" (@(@($j.hooks.PreToolUse) | Where-Object { $_.matcher -eq 'Write' }).Count -eq 1)
Check 'PostToolUse untouched' ($j.hooks.PostToolUse[0].hooks[0].command -eq 'prettier --write')
Check 'unrelated top-level keys untouched' ($j.model -eq 'opus' -and @($j.permissions.allow).Count -eq 1)
Check 'hook files removed' (-not ((Test-Path (Join-Path $d 'hooks\rrun-boundary-warn.sh')) -or (Test-Path (Join-Path $d 'hooks\rrun-boundary-warn.py'))))
Check 'idempotent: second uninstall is a no-op' ($(& $remover -ConfigDir $d -Quiet; $?))
Remove-Item -Recurse -Force $d -ErrorAction SilentlyContinue

Write-Host ''
if ($fail -gt 0) { Write-Host "$fail FAILURE(S)"; exit $fail }
Write-Host 'ALL PASS'
exit 0
