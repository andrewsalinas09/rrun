# rrun boundary fixes — installed to ~/.rrun/bash_env by install.ps1 (always
# refreshed on reinstall; do not hand-edit — changes go in the repo).
# Reaches non-interactive shells directly via the user env var BASH_ENV (kept
# deliberately tiny: BASH_ENV runs for EVERY non-interactive bash, and pointing
# it at a full .bashrc would run unrelated init — or nothing, if the .bashrc
# early-returns for non-interactive shells). Interactive shells get the same
# file through a sourcing block install.ps1 maintains in ~/.bashrc.

# MSYS path conversion rewrites POSIX-looking args (/home/..., /sdcard/...) to
# C:/Program Files/Git/... when invoking native exes. wsl and adb take non-Windows
# paths by design — disable conversion for them only (a global disable would break
# tools that DO want /c/... -> C:\... translation).
wsl() { MSYS_NO_PATHCONV=1 command wsl.exe "$@"; }
adb() { MSYS_NO_PATHCONV=1 command adb "$@"; }

# Python stdout/stderr on Windows default to cp1252 -> UnicodeEncodeError the moment
# a script prints UTF-8 (micro sign, smart quotes extracted from docx, etc.).
export PYTHONIOENCODING=utf-8
