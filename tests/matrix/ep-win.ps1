# ep-win.ps1 -- entrypoint for the Windows matrix node container (see
# Dockerfile.winnode). Env-driven like the Linux entrypoint.sh:
#   C:\keys (ro mount) : authorized_keys installed as
#                        administrators_authorized_keys (the test user is an
#                        admin, so no user profile is needed before first
#                        logon -- profiles do not exist in a fresh container)
#   DEFAULT_SHELL      : cmd (default) | powershell (5.1) | pwsh (7) -- the
#                        sshd gateway axis, via HKLM:\SOFTWARE\OpenSSH
$ErrorActionPreference = 'Stop'

# admin ssh user, created HERE because `net user` fails opaquely in build-time
# `powershell -Command` RUN steps (works fine under -File). Password unused
# (pubkey only) and MUST stay 14 chars or fewer -- longer makes net user
# PROMPT (Y/N) about pre-Windows-2000 compatibility, and there is no stdin.
net user test 'Rrun#2026aBcd' /add /passwordchg:no | Out-Null
net localgroup Administrators test /add | Out-Null

New-Item -ItemType Directory -Force -Path C:\ProgramData\ssh | Out-Null
& 'C:\Program Files\OpenSSH\ssh-keygen.exe' -A

@'
PasswordAuthentication no
PubkeyAuthentication yes
Match Group administrators
       AuthorizedKeysFile __PROGRAMDATA__/ssh/administrators_authorized_keys
'@ | Set-Content -Encoding ascii C:\ProgramData\ssh\sshd_config

Copy-Item C:\keys\authorized_keys C:\ProgramData\ssh\administrators_authorized_keys
# ACL AND OWNER both matter: sshd requires this file to be OWNED by SYSTEM or
# the Administrators group -- a copy made by ContainerAdministrator is owned
# by that account, and sshd then refuses auth with only a DEBUG3-level "Bad
# owner" trace (cost this lane a four-round debugging session to find)
icacls C:\ProgramData\ssh\administrators_authorized_keys /inheritance:r /grant 'Administrators:F' /grant 'SYSTEM:F' | Out-Null
icacls C:\ProgramData\ssh\administrators_authorized_keys /setowner 'NT AUTHORITY\SYSTEM' | Out-Null

New-Item -Path 'HKLM:\SOFTWARE\OpenSSH' -Force | Out-Null
switch ($env:DEFAULT_SHELL) {
  'powershell' { Set-ItemProperty 'HKLM:\SOFTWARE\OpenSSH' -Name DefaultShell -Value 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe' }
  'pwsh'       { Set-ItemProperty 'HKLM:\SOFTWARE\OpenSSH' -Name DefaultShell -Value 'C:\Program Files\PowerShell\7\pwsh.exe' }
  default      { Remove-ItemProperty 'HKLM:\SOFTWARE\OpenSSH' -Name DefaultShell -ErrorAction SilentlyContinue }
}

# sshd refuses host keys with permissive ACLs; the shipped fixer handles it
& 'C:\Program Files\OpenSSH\FixHostFilePermissions.ps1' -Confirm:$false

Start-Service sshd
Write-Host "rrun win node up: DEFAULT_SHELL=$($env:DEFAULT_SHELL)"
while ($true) { Start-Sleep -Seconds 3600 }
