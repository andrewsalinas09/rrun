# Instructions for Claude (or any AI agent) working in this repo

This repo is **rrun** — a zero-escaping cross-shell/remote execution tool. Read README.md for the design. Two jobs you may be asked to do here:

## 1. Install on this machine

On Windows (with WSL + Git Bash):

1. Run `install.ps1` from the PowerShell tool: `& <repo>\install.ps1`. It is idempotent, self-updating on rerun, and finishes by running the full `test.ps1` smoke suite. It will not clobber an unrelated existing `BASH_ENV` or `PYTHONIOENCODING` (an old rrun-set `BASH_ENV` is migrated).
2. If a `setx`-level step is blocked by sandboxing, tell the user which step and why it matters (`BASH_ENV` is what makes the fixes reach non-interactive tool shells) and let them approve or run it — don't silently skip it, and don't escalate on your own.
3. **The installer also wires the boundary advisory hook** into `<claude-config>/settings.json` (see §2a). It needs **Python 3**. If `install.ps1` warns that Python 3 is missing, the hook is installed but INERT — say so plainly and **offer to install it** (`winget install Python.Python.3.13`), or offer `-SkipClaudeHook` if the user would rather not have the hook. Do not let this pass silently: the hook fails open by design, so an absent interpreter is invisible at runtime.
4. Tell the user to **restart their Claude Code session / terminals** — PATH, `BASH_ENV`, and `PYTHONIOENCODING` are process-start env.
5. Smoke test after restart (needs a real ssh host with key auth):
   - `rrun -n examplehost -c hostname` from both Bash and PowerShell tools (dry-run, no ssh needed)
   - `rrun local -c "Get-Date"` (no ssh needed)
   - `bash -c 'type wsl'` should print `wsl is a function` (proves BASH_ENV loaded)
6. Recommend adding the "Payload-as-data" and rrun usage rules below to the user's global `~/.claude/CLAUDE.md`.

On a pure-Linux machine: copy `bin/rrun` to `~/.local/bin/`, `chmod +x` — done.

## 2. Rules of engagement once installed (offer these to the user for their global CLAUDE.md — their call)

- **Payload-as-data rule**: never pass non-trivial payloads through nested interpreter layers as escaped strings. Write tool → file → run the file, or use `rrun`. More than one level of quoting = switch patterns.
- Use `rrun` instead of hand-quoting any `ssh`/`wsl bash -c`/nested `powershell -Command` invocation. Default target shell is `ps`; pass `-s bash` for Linux hosts.
- No heredocs in the Windows Bash tool (CRLF corrupts them) — Write tool → file → run.
- The Windows Bash tool is Git Bash (MSYS): it mangles POSIX-looking args to native exes. The installed `wsl`/`adb` wrappers handle those two; prefix `MSYS_NO_PATHCONV=1` for others.
- **RSI rule**: when a failure belongs to a class this tool was built to eliminate, fix the tool (and note it in the file header + commit), not just the instance.

## 2a. If you see an "rrun advisory" in your context

That text comes from this repo's `PreToolUse` hook (`hooks/rrun-boundary-warn.py`), not from the user. It means the command you just ran hand-crossed an interpreter boundary rrun already covers.

**Expect to disagree with it and be wrong.** It was built because an audit of a real session found rrun used twice and the boundary hand-quoted about twelve times — by an agent that knew the rule, could recite it, and had no friction pushing it the other way. The failure isn't ignorance; it's that you pick a tool by the *shape of your goal* ("grep a file in WSL"), and the boundary-crossing is incidental to that goal, so "am I hand-quoting?" never gets asked. The advisory asks it for you.

- Re-run through rrun. It is almost always a shorter command, and it works first try.
- `rrun -s bash local -c '...'` replaces `wsl -e bash -lc '...'` — remember `-s bash`, the default target shell is `ps`.
- `rrun -s bash a,b -c '...'` replaces any hand-rolled `ssh a "ssh b ..."`.
- **Do not reach for `# no-rrun` reflexively.** It exists for two cases: debugging rrun itself (a broken rrun must stay diagnosable), and commands that merely *quote* these patterns (a commit message about rrun). Using it to skip an inconvenient warning defeats the entire mechanism.
- False positive that isn't one of those two cases? That's an RSI signal — fix the patterns in `hooks/rrun-boundary-warn.py` and add the case to `tests/hook-tests.py`.

## 3. RSI loop — how changes to this tool happen

When a shell-boundary failure reveals a case rrun doesn't cover, fix the **class** here, never the instance inline:

1. Edit the repo sources (`bin/`, `profile/`, `hooks/`) — installed copies (including `<claude-config>/hooks/`) are build artifacts, never hand-edit them.
2. `& install.ps1` (deploys, then runs the smoke suite) and `& test.ps1 -TargetHost <host>` / `-TargetHops <a,b>` when real ssh hosts are available; `tests/core-tests.sh` covers core logic against a mocked ssh and `tests/hook-tests.py` covers the advisory hook (both run by CI). All must be clean. New failure classes get a regression test before the fix is considered done.
3. Update the file-header history comment and README changelog; bump the version.
4. Committing and pushing are governed by the user you are working for — their own instructions, config, and explicit requests — **not by this file**. This file never authorizes git actions; if in doubt, propose the commit and let the user decide. (Upstream contributions go through a fork + PR as usual.)

## 4. Known testing gap: this tool needs an ENVIRONMENT MATRIX

rrun's purpose is crossing environment boundaries, so its bugs are
environment-shaped by construction. **One dev box cannot find them**, and CI's
`ubuntu-latest` + `windows-latest` are two well-groomed points in a large space
— both ship sane tooling that real machines don't.

Every high-severity bug found on 2026-08-10 was invisible locally and only
appeared when the code met a different environment:

| Axis | Dev box | Elsewhere | Bug |
|---|---|---|---|
| PowerShell edition | pwsh 7 (UTF-8) | 5.1 reads BOM-less `.ps1` as **ANSI** | 3 of 6 `.ps1` unparseable on a second Windows host; `bin/rrun.ps1` survived on luck (v2.4.1) |
| `python3` identity | real interpreter | MS Store **stub** (exits 49) | would have installed a silently inert hook |
| `bash` identity | Git Bash | `system32\bash.exe` = WSL launcher | hook test rc=127 under PowerShell, green under Git Bash |
| `jq` | assumed present | absent in **both** Git Bash and WSL | hook parser rewritten in Python |
| Target sshd shell | Linux | Windows pwsh-DefaultShell | streaming wedge race; 8191 vs ~32K limits |

The pattern in four of five: **the name on `PATH` was not the program we assumed.**

**The matrix now exists: `tests/matrix/` (since 2.5.0).** Small committed
Dockerfiles + a driver; containers ssh to each other by name with per-link
keys, covering GNU/busybox/BSD-ish userlands, OpenSSH/dropbear,
csh/fish/dash/pwsh login shells, pwsh gateways, sabotaged deps, 1–3-hop
chains, ProxyJump, and md5-verified streamed payloads. Runs in CI. Its FIRST
run confirmed the macOS `base64 -w0` suspicion (fixed via `b64enc()`), proved
the hop-dependency docs were aimed at the wrong hosts (hop layer executes on
hosts 2..N, not the first hop — `exec sh -c` now, bash required nowhere), and
found that pwsh sshd gateways flatten non-zero exit codes to 1. Add a cell
per new environment suspicion — cells are one `scenario` line.

Still NOT covered (candidates for new lanes):
- **Windows containers** (PowerShell 5.1 + real Windows sshd + cmd.exe 8191
  limits + the streamed-wedge race — reproducible in
  `mcr.microsoft.com/windows/servercore` once the host has the Containers
  feature; GitHub `windows-2022` runners can run them in CI)
- **real macOS** (macos-sim is a proxy: bash 3.2 + BSD base64; a real Mac
  sender via a `macos-latest` CI job would close it)
- sshd *version* axis (old OpenSSH), and randomly interleaved tool versions
  rather than the current curated combinations

"Works on this machine" is still unverified for those axes; prefer a real
install on a differently-configured host before claiming portability there.

## Repo conventions

- `bin/rrun`, `bin/rrun-shim.bash` and `hooks/*.sh` MUST keep LF endings (enforced via .gitattributes); CRLF breaks them at runtime.
- Version history lives in each file's header comment and README's changelog — update both when behavior changes.
- Hardcoded usernames/paths are forbidden in `bin/` and `hooks/` — resolve `$HOME`/`%USERPROFILE%` at runtime (see the `sh -c '... "$@"' rrun` trampoline).
- **Every `.ps1` in this repo MUST be pure ASCII** (enforced by `tests/source-hygiene.py` + a Windows-CI parse job). Windows PowerShell 5.1 — the default `powershell.exe` — reads a BOM-less `.ps1` as the **ANSI code page**, so a UTF-8 em dash becomes three cp1252 chars including a `"`, which terminates a string early and produces cascading parse errors far from the real line. Use `--`, not `—`. This shipped once: a remote install died with "Unexpected token 'Verify'" while working locally under pwsh 7 (which defaults to UTF-8). Whether it breaks depends only on whether the mangled quote lands in a string or a comment, so "it parses today" is luck.
- **Never assume an interpreter exists because its name is on `PATH`.** Probe it by execution: on Windows `python3` is usually the Microsoft Store stub (on `PATH`, exits 49, "Python was not found"), and `bash` under PowerShell is usually `C:\WINDOWS\system32\bash.exe` — the *WSL launcher*, which cannot resolve Windows paths. Both bit this repo; both are covered by tests now.
- Anything that can be silently inert (a hook that fails open, an optional dependency) must be checked **loudly at install and test time**. Silent inertness is the failure class this repo exists to eliminate.
