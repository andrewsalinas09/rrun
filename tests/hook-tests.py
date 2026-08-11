#!/usr/bin/env python3
"""Regression suite for the rrun boundary-advisory hook.

Runs anywhere Python 3 runs (CI Linux + Windows, dev machines). Tests the
detector directly, and the launcher end-to-end when bash is available.

The negatives matter more than the positives here: a warn-only hook that cries
wolf on ordinary work trains you to ignore it, which is worse than no hook.
"""
import json
import os
import shutil
import subprocess
import sys

# Loading the detector by path would otherwise litter hooks/__pycache__ into a
# source directory that install.ps1 deploys from.
sys.dont_write_bytecode = True

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
HOOKS = os.path.join(ROOT, "hooks")
sys.path.insert(0, HOOKS)

import importlib.util

spec = importlib.util.spec_from_file_location(
    "rrun_boundary_warn", os.path.join(HOOKS, "rrun-boundary-warn.py"))
detector = importlib.util.module_from_spec(spec)
spec.loader.exec_module(detector)

# Real commands that hand-cross a boundary rrun covers. Several are verbatim
# from the session that motivated this hook.
MUST_WARN = [
    ("MSYS_NO_PATHCONV=1 wsl.exe -e bash -lc 'grep -n \"^set \" bin/rrun'", "wsl"),
    ("wsl.exe -e bash -c \"$(wsl.exe -e wslpath 'C:\\x.sh' | tr -d '\\r')\"", "wsl"),
    ("wsl -e bash /tmp/probe.sh", "wsl"),
    ("MSYS_NO_PATHCONV=1 wsl.exe -e sh -c 'command -v jq'", "wsl"),
    ("ssh pi \"ssh -o BatchMode=yes localhost echo ok\"", "nested ssh"),
    ("ssh -o BatchMode=yes pi 'ssh andrew hostname'", "nested ssh"),
    ("powershell -Command \"& { Get-Date }\"", "nested pwsh"),
    ("pwsh -c 'Get-Process | Sort CPU'", "nested pwsh"),
]

# Must stay silent. Ordinary work, rrun's own forms, and near-miss lookalikes.
MUST_BE_SILENT = [
    # rrun itself -- the entire point of the hook
    "rrun -s bash local -c 'grep -c \"^#\" bin/rrun'",
    "rrun -s bash pi,localhost -c 'echo ok'",
    "rrun pi,andrew -c 'Get-Date -Format o'",
    "rrun -s bash local 'C:\\path\\probe.sh'",
    "rrun -n -s bash h1,h2 -c x",
    "echo 'uname -a' | rrun -s bash pi -",
    # wsl management + non-shell -e targets
    "wsl --list --verbose",
    "wsl -l -v",
    "wsl --shutdown",
    "wsl -e python3 analyze.py",
    "wsl -e wslpath 'C:\\x'",
    # ordinary local work
    "git status --short",
    "git diff 38957a5 e90ce13 -- bin/rrun",
    "bash tests/core-tests.sh",
    "python tests/hook-tests.py",
    "ls -la ~/.claude/",
    "grep -rn 'bash -c' README.md",
    # a single ssh is fine -- only NESTED ssh is the pattern
    "ssh pi 'uname -s'",
    "ssh -o BatchMode=yes pi hostname",
    # substrings that must not trip the word-boundary guards
    "cat /mnt/c/tools/wslfoo/bash-notes.txt",
    "./sshkeys/rotate.sh --dry-run",
    # escape hatch
    "wsl.exe -e bash -lc 'echo hi'  # no-rrun: debugging rrun itself",
    "ssh a \"ssh b uptime\"  # no-rrun",
]

fails = []


def check(ok, label, detail=""):
    print("  %s  %s%s" % ("PASS" if ok else "FAIL", label,
                          "" if ok else "   <- " + detail))
    if not ok:
        fails.append(label)


print("[detector: must warn]")
for cmd, kind in MUST_WARN:
    got = detector.advise(cmd)
    check(bool(got) and kind.split()[0] in got, cmd[:64], "got %r" % got)

print("[detector: must stay silent]")
for cmd in MUST_BE_SILENT:
    got = detector.advise(cmd)
    check(got == "", cmd[:64], "FALSE POSITIVE: %r" % got)

print("[detector: payload handling]")
check(detector.advise("") == "", "empty command is silent")
check(detector.advise("wsl -e bash -c x # no-rrun") == "", "escape hatch suppresses")

def find_bash():
    """A bash that can actually see Windows paths.

    On Windows, `bash` on PATH is usually C:\\WINDOWS\\system32\\bash.exe -- the
    WSL launcher, which cannot resolve a Windows path and exits 127. Claude Code
    runs `shell: bash` hooks under Git Bash (already an rrun prerequisite on
    Windows), so that is what we must test against. Same failure class as the
    MSYS path-mangling gotcha in the README.
    """
    if os.name != "nt":
        return shutil.which("bash")
    cands = []
    git = shutil.which("git")
    if git:  # <git>/cmd/git.exe -> <git>/bin/bash.exe
        cands.append(os.path.join(os.path.dirname(os.path.dirname(git)), "bin", "bash.exe"))
    for env in ("PROGRAMFILES", "PROGRAMFILES(X86)"):
        base = os.environ.get(env)
        if base:
            cands.append(os.path.join(base, "Git", "bin", "bash.exe"))
    found = shutil.which("bash")
    if found and "system32" not in found.lower():
        cands.append(found)
    return next((c for c in cands if os.path.exists(c)), None)


# The launcher must emit valid JSON with the documented shape, and must fail
# open (exit 0, no output) on garbage input rather than blocking a tool call.
launcher = os.path.join(HOOKS, "rrun-boundary-warn.sh")
bash = find_bash()
if bash and os.path.exists(launcher):
    print("[launcher: end-to-end via %s]" % os.path.basename(bash))

    def run(payload):
        # relative name + cwd: keeps the path sane whichever bash we found
        p = subprocess.run([bash, os.path.basename(launcher)], input=payload,
                           capture_output=True, text=True, cwd=HOOKS)
        return p.returncode, p.stdout.strip()

    rc, out = run(json.dumps(
        {"tool_name": "Bash", "tool_input": {"command": "wsl -e bash -c 'x'"}}))
    ok = rc == 0 and out.startswith("{")
    doc = json.loads(out) if ok else {}
    check(ok, "warns on a matching command (exit 0, JSON out)", "rc=%s out=%r" % (rc, out[:80]))
    check(doc.get("hookSpecificOutput", {}).get("hookEventName") == "PreToolUse",
          "emits hookEventName=PreToolUse")
    check("additionalContext" in doc.get("hookSpecificOutput", {}),
          "emits additionalContext for the model")
    check("permissionDecision" not in doc.get("hookSpecificOutput", {}),
          "WARN ONLY: never emits a permissionDecision")

    rc, out = run(json.dumps(
        {"tool_name": "Bash", "tool_input": {"command": "git status"}}))
    check(rc == 0 and out == "", "silent on a clean command")

    rc, out = run("not json at all")
    check(rc == 0 and out == "", "fails OPEN on malformed payload (never blocks)")

    rc, out = run("{}")
    check(rc == 0 and out == "", "fails OPEN on an empty payload")
else:
    print("[launcher: SKIPPED -- no usable bash found]")
    print("  (on Windows this means Git Bash is missing, which rrun itself needs)")

print("")
if fails:
    print("%d FAILURE(S)" % len(fails))
    sys.exit(1)
print("ALL PASS")
