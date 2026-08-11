#!/usr/bin/env bash
# Windows-container lane sender (invoked by matrix-win.ps1). Runs under GIT
# BASH on the host -- deliberately: the sender is itself an axis here (MSYS
# userland: GNU bash/base64/iconv, Git Bash ssh), and the core runs directly,
# no WSL involved. ssh resolves per-cell Host aliases from $HOME/.ssh/config,
# where HOME is a scratch dir owned by this run.
#
# argv: <tmp_windows_path> <name:port:gateway>...
# Exit code = failures. Gateways: cmd expects EXACT exit codes; powershell /
# pwsh cells PROBE exit-code fidelity (Linux pwsh flattens to 1 -- whether
# Windows PowerShell 5.1 does too is exactly what this lane measures).
set -uo pipefail
tmpw=$1; shift
tmp=$(cygpath -u "$tmpw")
repo=$(cd "$(dirname "$0")/../.." && pwd)
RRUN="$repo/bin/rrun"

# Git Bash's OpenSSH resolves its home from the WINDOWS PROFILE database and
# IGNORES $HOME (measured: with HOME exported it still read /c/Users/<user>),
# so a per-run config CANNOT be delivered via HOME. Instead, put an `ssh`
# wrapper first on PATH that pins -F <per-run config>; rrun's contract is
# "invokes ssh from PATH with your ssh config", so this is legitimate harness
# plumbing -- and the user's real ~/.ssh is never read or written.
cfg="$tmp/ssh_config"
mkdir -p "$tmp/bin"
cp "$tmp/key" "$tmp/id_ed25519"; chmod 600 "$tmp/id_ed25519"
printf '#!/bin/sh\nexec /usr/bin/ssh -F "%s" "$@"\n' "$cfg" > "$tmp/bin/ssh"
chmod +x "$tmp/bin/ssh"
export PATH="$tmp/bin:$PATH"
{
  echo "UserKnownHostsFile $tmp/known_hosts"
  echo "IdentityFile $tmp/id_ed25519"
  echo "IdentitiesOnly yes"
  echo "StrictHostKeyChecking yes"
} > "$cfg"

fail=0
# on FAIL, surface the last captured stderr -- a cleanup-deleted err file has
# already cost one debugging round trip
lasterr=''
check() {
  if [[ $2 == 0 ]]; then echo "  PASS  $1"; return; fi
  echo "  FAIL  $1"
  [[ -n $lasterr && -s $lasterr ]] && echo "        stderr: $(tail -c 300 "$lasterr" | tr '\n' ' ')"
  fail=$((fail+1))
}
note()  { echo "  $1"; }

for triple in "$@"; do
  IFS=: read -r name port gw <<<"$triple"
  {
    echo "Host $name"
    echo "  HostName 127.0.0.1"
    echo "  Port $port"
    echo "  User test"
  } >> "$cfg"

  echo "=== $name (gateway=$gw)"
  # hyperv containers + first sshd start are slow; the scan doubles as
  # readiness detection and host-key learning (rrun never auto-accepts)
  ok=0
  for _ in $(seq 1 150); do
    if ssh-keyscan -T 2 -p "$port" 127.0.0.1 >> "$tmp/known_hosts" 2>/dev/null &&
       grep -q "\[127.0.0.1\]:$port" "$tmp/known_hosts"; then ok=1; break; fi
    sleep 2
  done
  check "$name: sshd reachable (host key learned)" $((1-ok))
  [[ $ok == 1 ]] || continue

  # small ps payload: output + exit-code fidelity through this gateway
  p="$tmp/p-$name.ps1"
  printf 'Write-Output "WMX-%s"\nexit 5\n' "$name" > "$p"
  # ALL attempt output goes to FILES, never $(...) command substitution: a
  # substitution blocks until every pipe writer exits, and an MSYS `timeout`
  # kill can orphan the streamed pipeline's ssh -- against a WEDGED session
  # that writer never exits and the whole suite hangs forever (it happened;
  # a file redirect returns control the moment timeout fires).
  lasterr="$tmp/err-$name"
  timeout 60 bash "$RRUN" "$name" "$p" > "$tmp/out-$name" 2>"$lasterr"; rc=$?
  out=$(cat "$tmp/out-$name")
  [[ $out == *"WMX-$name"* ]]; check "$name: small ps payload output arrives" $?
  if [[ $gw == cmd ]]; then
    [[ $rc == 5 ]]; check "$name: exact exit code 5 through cmd gateway" $?
  else
    note "PROBE $name: exit code through $gw gateway = $rc (payload exited 5)"
  fi

  # UTF-16LE (BOM) payload file: the remote BOM-aware decode against a REAL
  # Windows PowerShell 5.1, not a pwsh stand-in
  u16="$tmp/u16-$name.ps1"
  printf '\xff\xfe' > "$u16"
  printf 'Write-Output "WMX-u16-%s"\n' "$name" | iconv -f UTF-8 -t UTF-16LE >> "$u16"
  timeout 60 bash "$RRUN" "$name" "$u16" > "$tmp/out-$name" 2>/dev/null; rc=$?
  out=$(cat "$tmp/out-$name")
  [[ $out == *"WMX-u16-$name"* ]]; check "$name: UTF-16LE payload file decodes remotely" $?

  # large payload -> the streaming path. The documented Windows-sshd wedge
  # race makes this nondeterministic: timeout + retry, wedges counted LOUDLY
  # (this lane is where the race finally becomes reproducible-by-anyone).
  big="$tmp/big-$name.ps1"
  { printf 'param([string]$m = "WMX-big-%s")\nWrite-Output "got:[$m]"\n' "$name"
    i=1; while [ $i -le 400 ]; do echo "# padding line $i to push past the streaming threshold"; i=$((i+1)); done
    echo 'exit 7'; } > "$big"
  # 5 attempts with a SWEEP between them: the race is bursty (measured 5/5
  # wedges on a pwsh gateway), so blind retries inside a burst all lose.
  # After each wedge, rrun itself delivers win-sweep.ps1 as a small payload
  # (non-streamed sessions are immune) to kill the stuck shell, exactly the
  # sweep-then-retry pattern test.ps1 uses against real hosts. A cell that
  # STILL wedges out is a loud FAIL -- that is signal, not noise.
  wedges=0 rc=0 out=''
  for _try in 1 2 3 4 5; do
    timeout 75 bash "$RRUN" "$name" "$big" > "$tmp/out-$name" 2>"$tmp/errbig-$name"; rc=$?
    out=$(cat "$tmp/out-$name")
    if [[ $rc == 124 ]]; then
      wedges=$((wedges+1))
      timeout 45 bash "$RRUN" "$name" "$repo/tests/matrix/win-sweep.ps1" >/dev/null 2>&1
      sleep 2
      continue
    fi
    break
  done
  [[ $wedges -gt 0 ]] && note "WARN $name: streamed session wedged $wedges time(s) of 5 (known Windows-sshd race; swept between tries)"
  [[ $out == *"got:[WMX-big-$name]"* ]]; check "$name: streamed large ps payload arrives un-reparsed (param() intact)" $?
  if [[ $gw == cmd ]]; then
    [[ $rc == 7 ]]; check "$name: streamed exit code 7 through cmd gateway" $?
  else
    note "PROBE $name: streamed exit code through $gw gateway = $rc (payload exited 7)"
  fi
done

echo
if [[ $fail == 0 ]]; then echo 'WIN LANE: ALL PASS'; else echo "WIN LANE: $fail FAILURE(S)"; fi
exit "$fail"
