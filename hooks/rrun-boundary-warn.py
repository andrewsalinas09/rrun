#!/usr/bin/env python3
"""rrun boundary advisory — detector (v1.0).

Reads a Claude Code PreToolUse hook payload on stdin and, when the command
hand-crosses an interpreter boundary that rrun already covers, emits an advisory
naming the rrun equivalent.

WARN ONLY — this never blocks a tool call.

WHY THIS EXISTS
    rrun makes escaping bugs impossible by moving payloads as base64 instead of
    as quoted strings. But the tool only helps if it is reached for, and a prose
    rule ("use rrun instead of hand-quoting ssh / wsl bash -c / nested
    powershell") demonstrably does not fire reliably: the boundary-crossing is
    usually *incidental* to the goal ("grep a file in WSL", "is the host up?"),
    so the "am I hand-quoting?" recognition never happens. This hook triggers on
    the command's SHAPE rather than on someone noticing. Same move rrun itself
    makes: don't ask for careful escaping, remove the opportunity to get it
    wrong.

ESCAPE HATCH
    Put "# no-rrun" anywhere in the command to silence it. This is load-bearing,
    not politeness:
      * when rrun itself is broken, raw wsl/ssh is the ONLY way to diagnose it —
        a hard block would lock you out of repairing the tool;
      * commands that merely *quote* these patterns (a git commit message about
        rrun, a grep for "bash -c") are legitimate.

PYTHON, NOT JQ
    jq is absent from both Git Bash and WSL on a stock Windows dev box. A hook
    whose parser is missing fails silently, which is worse than no hook. The
    launcher (rrun-boundary-warn.sh) locates a working Python 3 and fails open
    if there is none.

history: v1.0 2026-08-10 created (external-review round 10).
         v1.1 2026-08-11 (round 11, finding 8) NESTED_SSH no longer fires on
         two independent sequential ssh commands -- the second ssh must now be
         inside the quote the first one opens.
"""
import json
import re
import sys

# --- detection -------------------------------------------------------------
# The leading guard stops a path like /mnt/c/tools/wslfoo or ./sshkeys from
# matching: these must be the actual programs being invoked, not substrings.
WSL = re.compile(r"(?<![A-Za-z0-9_./-])wsl(\.exe)?(\s|$)")
# A POSIX shell handed a command string, or used as the -e target of wsl.
SHELL = re.compile(r"(-e\s+(ba|z)?sh(\s|$)|(ba|z)?sh\s+-[A-Za-z]*c(\s|$))")
# An ssh whose remote command itself invokes ssh: the second ssh must sit
# INSIDE the quote opened by the first ssh's arguments. The old form
# (ssh\s.*["'].*ssh\s) also matched two independent sequential commands
# (`ssh a 'date'; ssh b uptime`), because .* happily crossed the closing quote
# and a command separator. Now: no quote/separator may appear between the
# first ssh and its opening quote, and the second ssh must appear before that
# same quote closes ((?:(?!\1).)* cannot cross the closing quote).
NESTED_SSH = re.compile(r"ssh\s[^\"';|&]*([\"'])(?:(?!\1).)*ssh\s")
# powershell/pwsh handed a command string from inside another shell.
PS_COMMAND = re.compile(
    r"(?<![A-Za-z0-9_./-])(powershell|pwsh)(\.exe)?\s.*(-Command|-c)\s"
)

CHECKS = (
    (lambda c: bool(WSL.search(c) and SHELL.search(c)),
     "wsl + shell  ->  rrun -s bash local -c '...'   (or: rrun -s bash local <script>)"),
    (lambda c: bool(NESTED_SSH.search(c)),
     "nested ssh   ->  rrun -s bash hop1,hop2 -c '...'"),
    (lambda c: bool(PS_COMMAND.search(c)),
     "nested pwsh  ->  rrun local -c '...'"),
)

ADVICE = (
    "rrun advisory - this command hand-crosses an interpreter boundary that rrun "
    "already covers: {detail}. Payloads should ride as data (base64), not as escaped "
    "strings; that is what rrun is for, and every layer you hand-quote is a layer "
    "that can silently eat a $ or a quote. Prefer re-running it through rrun. If you "
    "are deliberately bypassing rrun -- debugging rrun itself, or a command that "
    "merely quotes these patterns -- add a '# no-rrun' comment to silence this."
)


def advise(command):
    """Return the advisory detail string for a command, or '' if it is clean."""
    if not command or "# no-rrun" in command:
        return ""
    return "; ".join(msg for pred, msg in CHECKS if pred(command))


def main():
    try:
        payload = json.load(sys.stdin)
    except Exception:
        return 0  # a malformed payload must never break the tool call
    command = (payload.get("tool_input") or {}).get("command") or ""
    detail = advise(command)
    if not detail:
        return 0

    json.dump({
        "systemMessage": "rrun advisory: hand-quoted interpreter boundary (%s)" % detail,
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "additionalContext": ADVICE.format(detail=detail),
        },
    }, sys.stdout)
    return 0


if __name__ == "__main__":
    sys.exit(main())
