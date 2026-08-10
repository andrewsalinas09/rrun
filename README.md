# rrun — zero-escaping remote & cross-shell execution

**Version 2.1.0** (core v2.1, shims v1.1) · Windows + WSL + any ssh-reachable host

Run a script or command on any host, through any chain of shells (PowerShell ↔ Git Bash ↔ WSL ↔ ssh ↔ remote bash/PowerShell), **without writing a single escape character**. Payloads travel as base64 — inert in every parser — and are decoded only by the shell that executes them.

Born from an audit of 402 failed shell commands in Claude Code transcripts: the dominant self-inflicted failure classes were all interpreter-boundary escaping bugs. This repo fixes each class at the tool level instead of per-incident.

## The problem

Every interpreter layer eats one level of quoting. A command like

```
wsl bash -c 'ssh host "powershell -Command \"\$f = ...\""'
```

crosses four parsers; hand-counting which one consumes each `$` and `"` fails routinely:

| Failure class (audit count) | Symptom |
|---|---|
| WSL argv re-parsing (47) | `$VAR` silently expands to empty in the wrong shell (`cp: cannot stat '/rrun'`) |
| Heredoc corruption (20) | `unexpected EOF while looking for matching '` from CRLF/quote interplay |
| Nested `powershell -Command "$var"` (16) | outer shell interpolates `$var` away → `Missing expression after '='` |
| MSYS path mangling | `/home/x` rewritten to `C:/Program Files/Git/home/x` |
| cp1252 stdout (7) | `UnicodeEncodeError` the moment Python prints UTF-8 |
| CLIXML noise | `#< CLIXML ...` progress records polluting captured stderr |

## The principle

1. **Payload-as-data**: the script never appears inside a quoted string. It is base64-encoded (`[A-Za-z0-9+/=]` — no metacharacters exist), transported, and decoded by its executor: PowerShell natively via `-EncodedCommand` (UTF-16LE), POSIX shells via `echo <b64> | base64 -d | bash`.
2. **Per-layer re-armoring for multi-hop**: for `hostA,hostB` chains, the command each intermediate host runs is `ssh next 'echo <b64> | base64 -d | bash'` — the quoted part is itself pure base64, so quoting depth stays at one regardless of hop count.
3. **No shell re-parsing at the WSL boundary**: shims invoke `wsl.exe -e` (direct exec), so the WSL default shell never expands your argv.

## Components & install paths

| Repo file | Installs to | Role |
|---|---|---|
| `bin/rrun` | WSL `~/.local/bin/rrun` | Core: encodes payload, composes ssh command, multi-hop armoring. POSIX-only deps (bash, base64, iconv, ssh) — also works standalone on any Linux box. |
| `bin/rrun-shim.bash` | `%USERPROFILE%\.local\bin\rrun` | Git Bash entry point. `MSYS_NO_PATHCONV=1` + `wsl -e` + Windows→`/mnt` path translation + `local` host mode. |
| `bin/rrun.ps1` | `%USERPROFILE%\.local\bin\rrun.ps1` | PowerShell entry point (PowerShell resolves `rrun` → `rrun.ps1` via PATH). Same features as the bash shim. |
| `profile/bashrc-snippet.sh` | appended to `~/.bashrc` (+ `~/.bash_profile` created if absent) | `wsl`/`adb` wrapper functions with `MSYS_NO_PATHCONV=1`; `PYTHONIOENCODING` export. |
| `install.ps1` | — | Idempotent installer + verifier for all of the above. |

`%USERPROFILE%\.local\bin` is added to the user PATH if not already present.

## Environment variables set (user level, via installer)

| Variable | Value | Why |
|---|---|---|
| `BASH_ENV` | `<home>/.bashrc` (forward slashes) | Non-interactive, non-login bash (what Claude Code's Bash tool spawns) reads *no* profile — `BASH_ENV` is the only hook that reaches it, loading the `wsl`/`adb` wrappers. Not clobbered if already set. |
| `PYTHONIOENCODING` | `utf-8` | Kills the cp1252 `UnicodeEncodeError` class for Python stdio. Deliberately *not* `PYTHONUTF8=1`, which would also change file-open defaults. |
| `MSYS_NO_PATHCONV` | (per-call, in wrappers/shims — never global) | Global disable would break tools that want `/c/…` → `C:\…` translation. |

Environment changes require new terminal/Claude sessions to take effect.

## Usage

```
rrun [-s ps|bash|sh] [-J jumphosts] [-n] <host[,hop2,...]|local> <script | - | -c "cmds">
```

| Flag/arg | Meaning |
|---|---|
| `-s ps\|bash\|sh` | Target shell on the **final** host. Default `ps` (Windows targets); `*.sh`/`*.bash` scripts autodetect `bash`. Linux targets need `-s bash` (or a `.sh` file). |
| `-J jumphosts` | Native ssh ProxyJump — preferred for hops when your machine can auth straight to the final host. |
| `-n` | Dry-run: print the composed ssh invocation. |
| `host,hop2,...` | Nested-hop chain for when intermediate hosts hold the keys. Payload runs on the **last** host. Hop names resolve per-hop (from the *previous* host's ssh config); intermediate hops need `base64` + `bash` and pre-existing known_hosts/keys — rrun never auto-accepts host keys. |
| `local` | Run the payload on this machine (shims only) — replaces every nested `powershell -Command "..."` pattern. |
| `script \| - \| -c` | Script file (Windows paths auto-translate to `/mnt/...`), stdin, or inline string. |

```bash
rrun -s bash pi 'C:\path\to\diagnose.sh'   # Windows-pathed script on a Linux host
rrun winbox -c 'Get-Process | Sort CPU'    # PowerShell on a Windows host (default -s ps)
rrun -s bash pi,sensor01 collect.sh        # two-hop: local -> pi -> sensor01
rrun -J pi -s bash sensor01 collect.sh     # same reach via ProxyJump (needs direct auth)
rrun local -c '$PSVersionTable'            # local PowerShell, no quoting hazards
echo 'uname -a' | rrun -s bash pi -        # payload from stdin
```

**Caveats**: in `bash`/`sh` mode the payload's stdin is the decode pipe, so interactively-prompting scripts won't work. `BatchMode=yes` is always on — key auth only, no password prompts.

## Install

**Humans**: clone, then in PowerShell run `.\install.ps1`. Re-run any time; it's idempotent. Verify with `.\test.ps1` — 11 checks needing no remote host (dry-run composition through every entry point, real execution via `local` mode, CLIXML cleanliness, `$(subst)` survival); add `-TargetHost <host>` for a real ssh round-trip.

**Claude / AI agents**: point the agent at this repo and say "install this" — `CLAUDE.md` contains the exact steps and post-install rules of engagement.

**Linux-only hosts**: copy `bin/rrun` to `~/.local/bin/`, `chmod +x` — the core has no Windows dependencies.

## Changelog

- **2.1.0** (2026-08-10) — Windows shims (Git Bash + PowerShell) with `wsl -e`, path translation, `local` host; `$HOME` trampoline removes hardcoded usernames; CLIXML progress suppression; `bashrc` wrappers + `BASH_ENV` delivery; installer.
- **2.0.0** (2026-08-10) — bash/sh targets, comma multi-hop with per-layer re-armoring, `-J`, `-n`, extension autodetect.
- **1.0.0** — PowerShell `-EncodedCommand` over ssh, single hop.
