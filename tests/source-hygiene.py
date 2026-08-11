#!/usr/bin/env python3
"""Repo source invariants that are invisible until they break on someone else's box.

Runs anywhere Python 3 runs, on both CI jobs. Each rule here exists because the
corresponding bug actually shipped.

1. .ps1 sources must be PURE ASCII.
   Windows PowerShell 5.1 -- the default `powershell.exe` on every Windows box --
   reads a BOM-less .ps1 as the ANSI code page, NOT UTF-8. A UTF-8 em dash
   (E2 80 94) therefore decodes to three cp1252 chars, one of which is a double
   quote, which terminates a string early and produces a cascade of nonsense
   parse errors far from the real line. This shipped: install.ps1 died on a
   remote Windows host with "Unexpected token 'Verify'" and "The string is
   missing the terminator", while working fine locally under pwsh 7 (which
   defaults to UTF-8). Whether it breaks depends only on whether the mangled
   quote lands inside a string or a comment -- so "it parses today" is luck, not
   safety. A BOM would also fix it, but BOMs are invisible and easily stripped
   by editors; ASCII cannot be lost silently.

2. LF-critical files must contain no CR.
   The bash core, the Git Bash shim and the hook launcher break at runtime on
   CRLF (a CRLF shebang line is not a valid interpreter path).

3. No hardcoded home paths in shipped sources.
   They must resolve $HOME / %USERPROFILE% at runtime.
"""
import glob
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
os.chdir(ROOT)
fails = []


def check(ok, label, detail=""):
    print("  %s  %s%s" % ("PASS" if ok else "FAIL", label, "" if ok else "   <- " + detail))
    if not ok:
        fails.append(label)


print("[.ps1 sources are pure ASCII (Windows PowerShell 5.1 reads BOM-less .ps1 as ANSI)]")
for f in sorted(set(glob.glob("*.ps1") + glob.glob("*/*.ps1"))):
    raw = open(f, "rb").read()
    bad = [(i, b) for i, b in enumerate(raw) if b > 0x7F]
    if bad:
        i, b = bad[0]
        line = raw[:i].count(b"\n") + 1
        detail = "%d non-ASCII byte(s); first 0x%02X at line %d" % (len(bad), b, line)
    else:
        detail = ""
    check(not bad, f, detail)

print("[LF-critical files contain no CR]")
for f in ["bin/rrun", "bin/rrun-shim.bash", "profile/bash_env.sh"] + sorted(glob.glob("hooks/*.sh")) + sorted(glob.glob("tests/*.sh")):
    if not os.path.exists(f):
        continue
    raw = open(f, "rb").read()
    check(b"\r" not in raw, f, "contains CR (breaks the shebang / function bodies)")

print("[no hardcoded home paths in shipped sources]")
PAT = re.compile(rb"/home/[a-z][a-z0-9_-]*/|[A-Za-z]:\\\\Users\\\\[a-z][a-z0-9_-]*|/c/Users/[a-z][a-z0-9_-]*", re.I)
for f in sorted(glob.glob("bin/*") + glob.glob("hooks/*")):
    if os.path.isdir(f):
        continue
    raw = open(f, "rb").read()
    hits = PAT.findall(raw)
    check(not hits, f, "hardcoded: %r" % (hits[:3],))

print("")
if fails:
    print("%d FAILURE(S)" % len(fails))
    sys.exit(1)
print("ALL PASS")
