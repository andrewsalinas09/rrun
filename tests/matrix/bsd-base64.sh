#!/bin/sh
# BSD/macOS-flavored base64 shim for the macos-sim sender image. Faithful in
# the two ways that matter to rrun: `-w` DOES NOT EXIST (GNU-only -- macOS
# base64 errors on it), and plain encoding emits a single unwrapped line.
# Decoding (-d/-D/--decode) is passed through. Calls busybox directly so the
# shim (installed at /usr/local/bin/base64, ahead of busybox on PATH) never
# recurses into itself.
for a in "$@"; do
  case "$a" in
    -w*|--wrap*) echo "base64: invalid option -- w" >&2; exit 64 ;;
  esac
done
case "${1:-}" in
  -d|-D|--decode) shift; exec /bin/busybox base64 -d "$@" ;;
  '') /bin/busybox base64 | tr -d '\n'; echo ;;
  *) echo "base64: usage not supported by macos-sim shim: $*" >&2; exit 64 ;;
esac
