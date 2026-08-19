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
#   * host "adb[:serial]"   : run the payload on an Android device via adb shell.
#                             Handled HERE, not forwarded to WSL — the adb client
#                             and the USB device are both Windows-side (WSL2 has
#                             no USB passthrough). Defaults to -s sh; streams the
#                             payload over stdin past RRUN_STREAM_LIMIT so the
#                             32767-char Windows command line can't truncate it.
# usage mirrors WSL rrun:  rrun [-s ps|bash|sh|wsl] [-J jumps] [-n] <host[,hop2,...]|local|adb[:serial]> <script|-|-c "cmds">
# history: v1 2026-08-10 created from transcript-error audit; v1.1 $HOME trampoline,
#          CLIXML suppression; v1.2 review fixes — -n honored in local mode (was
#          EXECUTING on dry-run), -c args no longer path-translated, -s validated,
#          -J rejected for host local; v1.3 local payloads never textually
#          modified (prefix broke param()/using — scriptblock wrapper instead)
#          and encoded straight from file/stdin (trailing newlines preserved);
#          v1.4 wrapper appends `if (-not $?) { exit 1 }` so failing local ps
#          payloads exit non-zero (the & operator otherwise masked failures);
#          v1.5 BOM-detecting decode (UTF-16LE .ps1 files no longer garbage),
#          size-limit doc corrected to ~9KB; v1.6 status-honest local bash/sh
#          decode (broken base64 -> loud 125, not silent success); v1.7
#          file-backed decode — execution byte-for-byte ($(...) stripped
#          trailing newlines, changing backslash-newline-final payloads);
#          v1.8 cleanup traps — decoded payload file never outlives an
#          interrupted wrapper; v1.9 explicitly empty -c is a valid no-op
#          program (only a MISSING argument is an error) — matches core+ps shim;
#          v1.10 2026-08-11 adb transport (host "adb"/"adb:<serial>"). `adb
#          shell` is a boundary that eats hand-quoted payloads exactly like the
#          ones this shim already covers: a find(1) with escaped parens sent
#          from Git Bash arrived at the device stripped, matched nothing, and
#          exited 0 — a silent wrong answer. Handled locally rather than
#          forwarded (adb + USB are Windows-side); TMPDIR pinned to
#          /data/local/tmp (Android has no /tmp and mktemp is the wrapper's
#          first statement); stdin-streaming above RRUN_STREAM_LIMIT so the
#          32767-char Windows command line cannot truncate a big payload;
#          v1.11 2026-08-19 -s wsl (bash inside WSL on a Windows host, core
#          v2.9): accepted and forwarded for remote hosts; for host "local"
#          it IS -s bash (this machine is the Windows host — the payload runs
#          under bash in this machine's WSL); rejected for adb targets.
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
      case ${2:-} in ps|bash|sh|wsl) ;; *) echo "rrun: -s must be ps, bash, sh or wsl" >&2; exit 2 ;; esac
      shell=$2; opts+=(-s "$2"); shift 2 ;;
    -J) jump=1; opts+=(-J "${2:?rrun: -J needs an argument}"); shift 2 ;;
    -n) dry=1; opts+=(-n); shift ;;
    *)  echo "rrun: unknown option '$1'" >&2; exit 2 ;;
  esac
done
if (( $# < 2 )); then
  echo 'usage: rrun [-s ps|bash|sh|wsl] [-J jumps] [-n] <host[,hop2,...]|local> <script | - | -c "cmds">' >&2
  exit 2
fi
host=$1; shift

# adb targets are handled HERE, never forwarded to WSL: the adb client and the
# USB device both live on the Windows side, and WSL2 has no USB passthrough — a
# forwarded `adb` would find no binary (or, worse, a second adb server that sees
# no devices). Same reasoning as host "local".
if [[ $host == adb || $host == adb:* ]]; then
  if (( jump )); then echo 'rrun: -J is meaningless for an adb target' >&2; exit 2; fi
  serial=""
  [[ $host == adb:* ]] && serial=${host#adb:}
  if [[ -n $serial && ! $serial =~ ^[A-Za-z0-9._:-]+$ ]]; then
    echo "rrun: invalid adb serial '$serial' (allowed: letters, digits, . _ : -)" >&2
    exit 2
  fi
  src=$1
  case "$src" in
    -c) pb64=$(printf %s "${2?rrun: -c needs a command string}" | base64 -w0) ;;
    -)  pb64=$(base64 -w0) ;;
    *)  pb64=$(base64 -w0 < "$src") ;;
  esac
  # Stock Android ships /system/bin/sh and neither bash nor PowerShell.
  [[ -z $shell ]] && shell=sh
  if [[ $shell == ps || $shell == wsl ]]; then
    echo "rrun: -s $shell is not valid for an adb target (Android has neither PowerShell nor WSL); use -s sh" >&2
    exit 2
  fi
  # TMPDIR pinned because mktemp is this wrapper's first statement and Android
  # has no /tmp; trap body single-quoted (never \"-escaped) so no argument
  # boundary can eat it — the ps-shim v1.12 lesson applies to any native argv.
  pre="TMPDIR=\${TMPDIR:-/data/local/tmp}; t=\$(mktemp) || exit 125; trap 'rm -f \"\$t\"' 0; trap exit 1 2 15;"
  post="|| { echo rrun: adb decode failed >&2; exit 125; }; $shell \"\$t\""
  run="$pre echo $pb64 | base64 -d > \"\$t\" $post"
  args=(); [[ -n $serial ]] && args=(-s "$serial")
  # adb.exe is a native Windows process, so the whole command counts against the
  # 32767-char command-line limit. Past the threshold the payload rides on stdin
  # instead (adb forwards stdin to the device), which costs the payload its own
  # stdin but keeps arbitrarily large scripts working.
  stream=0
  if (( ${#run} > ${RRUN_STREAM_LIMIT:-6000} )); then
    stream=1
    run="$pre base64 -d > \"\$t\" $post"
  fi
  if (( dry )); then
    dryout=$(printf '%q ' adb "${args[@]}" shell "$run")
    if (( stream )); then printf 'printf %%s %s | %s\n' "$pb64" "${dryout% }"
    else printf '%s\n' "${dryout% }"
    fi
    exit 0
  fi
  # MSYS_NO_PATHCONV=1: Git Bash otherwise rewrites the device's /data/local/tmp
  # and /sdcard paths into C:/Program Files/Git/... before adb ever sees them.
  if (( stream )); then
    set +e +o pipefail
    printf %s "$pb64" | env MSYS_NO_PATHCONV=1 adb "${args[@]}" shell "$run"
    exit "${PIPESTATUS[1]}"
  fi
  exec env MSYS_NO_PATHCONV=1 adb "${args[@]}" shell "$run"
fi

if [[ $host == local ]]; then
  if (( jump )); then echo 'rrun: -J is meaningless with host "local"' >&2; exit 2; fi
  src=$1
  # straight to base64 — a $(cat) capture would strip trailing newlines
  case "$src" in
    # ${2?...} not ${2:?...}: an explicitly empty command is a valid no-op
    # program; only a MISSING argument is an error (matches core + ps shim).
    -c) pb64=$(printf %s "${2?rrun: -c needs a command string}" | base64 -w0) ;;
    -)  pb64=$(base64 -w0) ;;
    *)  pb64=$(base64 -w0 < "$src") ;;
  esac
  if [[ -z $shell ]]; then
    case "$src" in *.sh|*.bash) shell=bash ;; *) shell=ps ;; esac
  fi
  # host "local" IS the Windows machine that has the WSL: -s wsl and -s bash
  # mean the same thing here (payload runs under bash inside this machine's WSL).
  [[ $shell == wsl ]] && shell=bash
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
    # file-backed status-honest decode (see core v2.3.5): a plain pipeline hid
    # decoder failures (silent success), s=$(...) stripped trailing newlines at
    # execution time, and the traps clean the decoded payload up on normal exit
    # and catchable signals. Exit status = the executor's own.
    run="t=\$(mktemp) || exit 125; trap \"rm -f \\\"\$t\\\"\" 0; trap exit 1 2 15; echo $b64 | base64 -d > \"\$t\" || { echo rrun: local decode failed >&2; exit 125; }; $shell \"\$t\""
    if (( dry )); then
      printf 'wsl -e bash -c %q\n' "$run"
      exit 0
    fi
    exec env MSYS_NO_PATHCONV=1 wsl.exe -e bash -c "$run"
  fi
fi

# remote: translate ONLY the script-source operand (a real local file) to a /mnt
# path. Arguments following -c (and "-") are opaque payload data — never touched.
if [[ ${1:-} != -c && ${1:-} != - && -f ${1:-} ]]; then
  set -- "$(xlate "$1")" "${@:2}"
fi
exec env MSYS_NO_PATHCONV=1 wsl.exe -e sh -c 'exec "$HOME/.local/bin/rrun" "$@"' rrun "${opts[@]}" "$host" "$@"
