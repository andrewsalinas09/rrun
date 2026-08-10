#!/usr/bin/env bash
# rrun (Windows/Git Bash shim) — forwards to WSL ~/.local/bin/rrun so payloads cross
# shell boundaries as data, never as escaped strings. Installed by install.ps1 as
# %USERPROFILE%\.local\bin\rrun. Class fixes baked in:
#   * wsl.exe -e            : direct exec, WSL default shell never re-parses argv
#   * MSYS_NO_PATHCONV=1    : Git Bash otherwise rewrites /home/... args to
#                             C:/Program Files/Git/home/...
#   * script operand only   : the script-source argument is translated C:\x -> /mnt/c/x;
#                             everything after -c is opaque data, never touched
#   * host "local"          : run payload right here — ps -> powershell -EncodedCommand,
#                             bash/sh -> armored pipe through wsl bash. No ssh.
#                             Bounded by the 32767-char process command-line limit;
#                             double base64 (payload b64 inside a UTF-16LE b64
#                             wrapper) costs ~3.6 chars/byte -> ~9KB ps payload.
#                             Use powershell -File directly beyond that.
#   * $HOME trampoline      : `sh -c '... "$@"' rrun args...` expands $HOME inside WSL
#                             while payload args pass as untouched positional params.
# usage mirrors WSL rrun:  rrun [-s ps|bash|sh] [-J jumps] [-n] <host[,hop2,...]|local> <script|-|-c "cmds">
# history: v1 2026-08-10 created from transcript-error audit; v1.1 $HOME trampoline,
#          CLIXML suppression; v1.2 review fixes — -n honored in local mode (was
#          EXECUTING on dry-run), -c args no longer path-translated, -s validated,
#          -J rejected for host local; v1.3 local payloads never textually
#          modified (prefix broke param()/using — scriptblock wrapper instead)
#          and encoded straight from file/stdin (trailing newlines preserved);
#          v1.4 wrapper appends `if (-not $?) { exit 1 }` so failing local ps
#          payloads exit non-zero (the & operator otherwise masked failures);
#          v1.5 BOM-detecting decode (UTF-16LE .ps1 files no longer garbage),
#          size-limit doc corrected to ~9KB.
set -euo pipefail

xlate() {  # absolute Windows path -> /mnt/<d>/... for WSL
  local w d
  w=$(cygpath -am "$1"); w=${w//\\//}
  d=${w:0:1}; d=${d,,}
  printf '/mnt/%s%s' "$d" "${w:2}"
}

# split leading options from host/payload args
opts=() shell="" dry=0 jump=0
while [[ ${1:-} == -* && ${1:-} != -c && ${1:-} != - ]]; do
  case $1 in
    -s)
      case ${2:-} in ps|bash|sh) ;; *) echo "rrun: -s must be ps, bash or sh" >&2; exit 2 ;; esac
      shell=$2; opts+=(-s "$2"); shift 2 ;;
    -J) jump=1; opts+=(-J "${2:?rrun: -J needs an argument}"); shift 2 ;;
    -n) dry=1; opts+=(-n); shift ;;
    *)  echo "rrun: unknown option '$1'" >&2; exit 2 ;;
  esac
done
if (( $# < 2 )); then
  echo 'usage: rrun [-s ps|bash|sh] [-J jumps] [-n] <host[,hop2,...]|local> <script | - | -c "cmds">' >&2
  exit 2
fi
host=$1; shift

if [[ $host == local ]]; then
  if (( jump )); then echo 'rrun: -J is meaningless with host "local"' >&2; exit 2; fi
  src=$1
  # straight to base64 — a $(cat) capture would strip trailing newlines
  case "$src" in
    -c) pb64=$(printf %s "${2:?rrun: -c needs a command string}" | base64 -w0) ;;
    -)  pb64=$(base64 -w0) ;;
    *)  pb64=$(base64 -w0 < "$src") ;;
  esac
  if [[ -z $shell ]]; then
    case "$src" in *.sh|*.bash) shell=bash ;; *) shell=ps ;; esac
  fi
  if [[ $shell == ps ]]; then
    # payload text never modified (a prefix broke param()/using payloads): fixed
    # wrapper sets ProgressPreference (CLIXML progress noise) and runs the
    # decoded source as its own scriptblock. The epilogue exits non-zero when the
    # payload's last statement failed ($? read INSIDE the scriptblock, where the
    # & operator hasn't yet masked it) so failures surface to the caller.
    # Decode via BOM-detecting StreamReader, not hardcoded UTF-8: PS 5.1 tooling
    # writes UTF-16LE .ps1 files by default; BOM-less sources decode as UTF-8.
    wrapper="\$ProgressPreference='SilentlyContinue'; \$__rb=[Convert]::FromBase64String('$pb64'); & ([scriptblock]::Create((New-Object IO.StreamReader((New-Object IO.MemoryStream(,\$__rb)),\$true)).ReadToEnd() + [char]10 + 'if (-not \$?) { exit 1 }'))"
    b64=$(printf %s "$wrapper" | iconv -f UTF-8 -t UTF-16LE | base64 -w0)
    if (( dry )); then
      printf 'powershell -NoProfile -ExecutionPolicy Bypass -EncodedCommand %s\n' "$b64"
      exit 0
    fi
    exec powershell.exe -NoProfile -ExecutionPolicy Bypass -EncodedCommand "$b64"
  else
    b64=$pb64
    if (( dry )); then
      printf 'wsl -e bash -c %q\n' "echo $b64 | base64 -d | $shell"
      exit 0
    fi
    exec env MSYS_NO_PATHCONV=1 wsl.exe -e bash -c "echo $b64 | base64 -d | $shell"
  fi
fi

# remote: translate ONLY the script-source operand (a real local file) to a /mnt
# path. Arguments following -c (and "-") are opaque payload data — never touched.
if [[ ${1:-} != -c && ${1:-} != - && -f ${1:-} ]]; then
  set -- "$(xlate "$1")" "${@:2}"
fi
exec env MSYS_NO_PATHCONV=1 wsl.exe -e sh -c 'exec "$HOME/.local/bin/rrun" "$@"' rrun "${opts[@]}" "$host" "$@"
