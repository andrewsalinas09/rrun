# >>> claude-shell-boundary >>>
# Class fixes for recurring Git Bash (MSYS) shell-boundary failures.
# Installed by rrun's install.ps1; loaded into non-interactive tool shells via
# the user env var BASH_ENV, and into interactive shells via ~/.bashrc.

# MSYS path conversion rewrites POSIX-looking args (/home/..., /sdcard/...) to
# C:/Program Files/Git/... when invoking native exes. wsl and adb take non-Windows
# paths by design — disable conversion for them only (a global disable would break
# tools that DO want /c/... -> C:\... translation).
wsl() { MSYS_NO_PATHCONV=1 command wsl.exe "$@"; }
adb() { MSYS_NO_PATHCONV=1 command adb "$@"; }

# Python stdout/stderr on Windows default to cp1252 -> UnicodeEncodeError the moment
# a script prints UTF-8 (micro sign, smart quotes extracted from docx, etc.).
export PYTHONIOENCODING=utf-8
# <<< claude-shell-boundary <<<
