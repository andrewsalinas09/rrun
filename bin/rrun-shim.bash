#!/usr/bin/env bash
# rrun (Windows/Git Bash shim) — forwards to WSL ~/.local/bin/rrun so payloads cross
# shell boundaries as data, never as escaped strings. Installed by install.ps1 as
# %USERPROFILE%\.local\bin\rrun. Class fixes baked in:
#   * wsl.exe -e            : direct exec, WSL default shell never re-parses argv
#                             (the classic "$VAR silently vanished" failure)
#   * MSYS_NO_PATHCONV=1    : Git Bash otherwise rewrites /home/... args to
#                             C:/Program Files/Git/home/...
#   * existing-file args    : translated C:\x -> /mnt/c/x so WSL rrun can read them
#   * host "local"          : run payload right here — ps -> powershell -EncodedCommand,
#                             bash/sh -> armored pipe through wsl bash. No ssh.
#   * $HOME trampoline      : `sh -c '... "$@"' rrun args...` expands $HOME inside WSL
#                             while payload args pass as untouched positional params.
# usage mirrors WSL rrun:  rrun [-s ps|bash|sh] [-J jumps] [-n] <host[,hop2,...]|local> <script|-|-c "cmds">
# history: v1 2026-08-10 created from transcript-error audit; v1.1 $HOME trampoline
#          (no hardcoded WSL user), CLIXML suppression in local ps mode.
set -euo pipefail

xlate() {  # absolute Windows path -> /mnt/<d>/... for WSL
  local w d
  w=$(cygpath -am "$1"); w=${w//\\//}
  d=${w:0:1}; d=${d,,}
  printf '/mnt/%s%s' "$d" "${w:2}"
}

# split leading options from host/payload args
opts=() shell=""
while [[ ${1:-} == -* && ${1:-} != -c && ${1:-} != - ]]; do
  case $1 in
    -s) shell=$2; opts+=(-s "$2"); shift 2 ;;
    -J) opts+=(-J "$2"); shift 2 ;;
    *)  opts+=("$1"); shift ;;
  esac
done
if (( $# < 2 )); then
  echo 'usage: rrun [-s ps|bash|sh] [-J jumps] [-n] <host[,hop2,...]|local> <script | - | -c "cmds">' >&2
  exit 2
fi
host=$1; shift

if [[ $host == local ]]; then
  src=$1
  case "$src" in
    -c) payload=${2:?rrun: -c needs a command string} ;;
    -)  payload=$(cat) ;;
    *)  payload=$(cat "$src") ;;
  esac
  if [[ -z $shell ]]; then
    case "$src" in *.sh|*.bash) shell=bash ;; *) shell=ps ;; esac
  fi
  if [[ $shell == ps ]]; then
    # ProgressPreference: suppress "#< CLIXML ... Preparing modules" stderr noise
    b64=$(printf %s "\$ProgressPreference='SilentlyContinue'; $payload" | iconv -f UTF-8 -t UTF-16LE | base64 -w0)
    exec powershell.exe -NoProfile -ExecutionPolicy Bypass -EncodedCommand "$b64"
  else
    b64=$(printf %s "$payload" | base64 -w0)
    exec env MSYS_NO_PATHCONV=1 wsl.exe -e bash -c "echo $b64 | base64 -d | $shell"
  fi
fi

# remote: translate args that are existing local files (script payloads) to /mnt paths;
# heuristic — a host/flag name that happens to match a local file would misfire, acceptable.
fwd=()
for a in "$@"; do
  if [[ $a != -* && -f $a ]]; then fwd+=("$(xlate "$a")"); else fwd+=("$a"); fi
done
exec env MSYS_NO_PATHCONV=1 wsl.exe -e sh -c 'exec "$HOME/.local/bin/rrun" "$@"' rrun "${opts[@]}" "$host" "${fwd[@]}"
