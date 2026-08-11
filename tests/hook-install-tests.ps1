# hook-install-tests.ps1 — regression suite for hooks/install-hook.ps1.
#
# This is the one part of rrun's install that edits a file the USER owns and may
# have hand-tuned. "It merged cleanly" therefore has to be a test, not a promise.
# Everything runs against throwaway config dirs; the real ~/.claude is untouched.
$ErrorActionPreference = 'Continue'
$repo = Split-Path $PSScriptRoot -Parent
$installer = Join-Path $repo 'hooks\install-hook.ps1'
$fail = 0

function Check([string]$name, [bool]$ok, [string]$detail = '') {
  if ($ok) { Write-Host "  PASS  $name" }
  else { Write-Host "  FAIL  $name  $detail"; $script:fail++ }
}
function NewDir { $d = Join-Path ([IO.Path]::GetTempPath()) ("rrun-hooktest-" + [Guid]::NewGuid().ToString('N').Substring(0, 8)); New-Item -ItemType Directory -Force -Path $d | Out-Null; $d }
function ReadJson([string]$d) { Get-Content -Raw (Join-Path $d 'settings.json') | ConvertFrom-Json }
function OurEntries($j) { @(@($j.hooks.PreToolUse) | Where-Object { @($_.hooks) | Where-Object { "$($_.command)" -match 'rrun-boundary-warn' } }) }

Write-Host '[fresh config dir (no settings.json)]'
$d = NewDir
& $installer -ConfigDir $d -RepoRoot $repo -Quiet
$j = ReadJson $d
Check 'creates settings.json with our hook' ((OurEntries $j).Count -eq 1)
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
Check 'our hook added' ((OurEntries $j).Count -eq 1)
Check "someone else's PreToolUse hook survives" (@(@($j.hooks.PreToolUse) | Where-Object { $_.matcher -eq 'Write' }).Count -eq 1)
Check 'PostToolUse hooks survive' ($j.hooks.PostToolUse[0].hooks[0].command -eq 'prettier --write')
Check 'unrelated top-level keys survive' ($j.model -eq 'opus' -and $j.env.DEBUG -eq 'true')
Check 'nested permissions survive (ConvertTo-Json depth)' (@($j.permissions.allow).Count -eq 2 -and @($j.permissions.deny).Count -eq 1)
Check 'backup written' (Test-Path (Join-Path $d 'settings.json.rrun-bak'))

Write-Host '[idempotency: three runs]'
& $installer -ConfigDir $d -RepoRoot $repo -Quiet
& $installer -ConfigDir $d -RepoRoot $repo -Quiet
$j = ReadJson $d
Check 'still exactly one rrun entry after 3 runs' ((OurEntries $j).Count -eq 1)
Check "still exactly one of someone else's" (@(@($j.hooks.PreToolUse) | Where-Object { $_.matcher -eq 'Write' }).Count -eq 1)
Remove-Item -Recurse -Force $d -ErrorAction SilentlyContinue

Write-Host '[malformed settings.json]'
$d = NewDir
'{ this is not json' | Set-Content -Path (Join-Path $d 'settings.json') -Encoding UTF8
$threw = $false
try { & $installer -ConfigDir $d -RepoRoot $repo -Quiet 2>$null } catch { $threw = $true }
Check 'refuses to guess, throws instead of clobbering' $threw
Check 'backup taken before the throw' (Test-Path (Join-Path $d 'settings.json.rrun-bak'))
Check 'original left intact' ((Get-Content -Raw (Join-Path $d 'settings.json')).Trim() -eq '{ this is not json')
Remove-Item -Recurse -Force $d -ErrorAction SilentlyContinue

Write-Host ''
if ($fail -gt 0) { Write-Host "$fail FAILURE(S)"; exit $fail }
Write-Host 'ALL PASS'
exit 0
