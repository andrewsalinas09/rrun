#!/usr/bin/env bash
# rrun boundary advisory — launcher (v1.0).
#
# Installed by install.ps1 to <claude-config-dir>/hooks/ and wired as a
# PreToolUse hook. Finds a working Python 3 and runs the detector next to it.
#
# FAILS OPEN, ALWAYS. This is an advisory attached to every Bash/PowerShell tool
# call; if anything here goes wrong it must exit 0 silently rather than block or
# delay real work. A noisy guard that breaks the toolchain would be worse than
# the habit it corrects.
#
# Why probe instead of just picking `python3`: on Windows, `python3` is commonly
# the Microsoft Store *stub* — it exists on PATH, exits 49, and prints "Python
# was not found" (measured on the dev machine this was written on). Name lookup
# alone would therefore select a non-interpreter and the hook would silently do
# nothing. So each candidate must actually execute and report major version 3.
#
# history: v1.0 2026-08-10 created (external-review round 10) — a prose rule in
#          CLAUDE.md did not reliably fire, because the boundary-crossing is
#          usually incidental to the goal; this triggers on command SHAPE.
set -u

# Directory of this script — the detector lives beside it.
dir=$(CDPATH= cd -- "$(dirname -- "$0")" 2>/dev/null && pwd) || exit 0
det="$dir/rrun-boundary-warn.py"
[ -f "$det" ] || exit 0

py=""
for c in python3 python py; do
  command -v "$c" >/dev/null 2>&1 || continue
  # must be a REAL python 3, not a Store stub / python 2
  "$c" -c 'import sys; sys.exit(0 if sys.version_info[0] == 3 else 1)' >/dev/null 2>&1 || continue
  py=$c
  break
done
[ -n "$py" ] || exit 0   # no usable interpreter: stay silent, never block

exec "$py" "$det"
