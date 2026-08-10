# rrun — zero-escaping remote & cross-shell execution

**Version 2.3.5** (core v2.3.5, ps shim v1.9, bash shim v1.8) · Windows + WSL + any ssh-reachable host

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
4. **Streaming for large payloads**: a base64-embedded command can exceed the remote command-line limit — 8,191 chars via `cmd.exe` on stock Windows OpenSSH, which caps embedded PowerShell payloads near 3 KB (UTF-16LE+base64 is ~2.67× expansion). When the composed command would exceed `RRUN_STREAM_LIMIT` (default 6000) on a single-hop (or `-J`) target, rrun automatically streams the base64 over stdin behind a small fixed bootstrap instead. Oversized payloads on nested-hop chains to PowerShell targets fail fast with advice to use `-J`.

## Components & install paths

| Repo file | Installs to | Role |
|---|---|---|
| `bin/rrun` | WSL `~/.local/bin/rrun` | Core: encodes payload, composes ssh command, multi-hop armoring. POSIX-only deps (bash, base64, iconv, ssh) — also works standalone on any Linux box. |
| `bin/rrun-shim.bash` | `%USERPROFILE%\.local\bin\rrun` | Git Bash entry point. `MSYS_NO_PATHCONV=1` + `wsl -e` + Windows→`/mnt` path translation + `local` host mode. |
| `bin/rrun.ps1` | `%USERPROFILE%\.local\bin\rrun.ps1` | PowerShell entry point (PowerShell resolves `rrun` → `rrun.ps1` via PATH). Same features as the bash shim. |
| `profile/bash_env.sh` | `~/.rrun/bash_env` (always refreshed on reinstall) + a marker-delimited sourcing block maintained in `~/.bashrc` | `wsl`/`adb` wrapper functions with `MSYS_NO_PATHCONV=1`; `PYTHONIOENCODING` export. Kept as a dedicated tiny file so `BASH_ENV` never has to run a full `.bashrc` (which may early-return for non-interactive shells, or run unrelated init). |
| `install.ps1` | — | Idempotent, self-updating installer; verifies by running the full test suite. |
| `test.ps1` / `tests/core-tests.sh` | — | Installed-artifact smoke suite (Windows) / mocked-ssh core regression suite (any Linux; runs in CI). |

`%USERPROFILE%\.local\bin` is added to the user PATH if not already present.

## Environment variables set (user level, via installer)

| Variable | Value | Why |
|---|---|---|
| `BASH_ENV` | `<home>/.rrun/bash_env` (forward slashes) | Non-interactive, non-login bash (what Claude Code's Bash tool spawns) reads *no* profile — `BASH_ENV` is the only hook that reaches it, loading the `wsl`/`adb` wrappers. Points at the dedicated file, not `.bashrc`. Not clobbered if already set to something unrelated (a previous rrun `.bashrc` value is migrated). |
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

**Caveats**:
- **Streamed** (large) payloads cannot read stdin — the channel carries the payload itself (`ps` and `bash`/`sh` alike). Non-streamed `bash`/`sh` payloads read the real ssh channel as of 2.3.3 (they used to read their own script text from the decode pipe). Payloads should still be non-interactive (`BatchMode=yes`).
- **rrun is transparent: payload exit codes pass through untouched and no code is reserved.** When the *transport itself* fails to decode the payload on the target (e.g. no `base64` there), rrun exits **125 and prints `rrun: ... decode failed` on stderr** — the stderr marker, not the number, is what identifies a transport failure (a payload is free to `exit 125` and that passes through like any other code). Multi-hop intermediate hosts additionally need a POSIX-compatible login shell (final targets are wrapped in `sh -c`, so csh/fish login shells are fine there).
- **Script-file operands are payload transport, not remote file staging.** `bash`/`sh` payloads execute from a trap-cleaned temp file on the target (`$0`/`BASH_SOURCE` point there, never at your original path; `ps` payloads run as an anonymous scriptblock — no `$PSScriptRoot`). Final `bash`/`sh` targets therefore need `mktemp` and `rm` alongside `sh` + `base64` (present on any ordinary Linux/busybox).
- **Known issue — Windows sshd streamed-session race**: streamed sessions to a Windows OpenSSH host can nondeterministically wedge *remotely* before the payload runs (observed 15–45%, bursty, on a pwsh-`DefaultShell` host; the stuck `powershell.exe` sits at ~0.1 s CPU and the ssh channel never closes). Controlled A/B testing shows it is independent of rrun version, payload content, and payload success/failure — it is a host-side race in the sshd → DefaultShell → `powershell.exe` stdin chain, not an rrun quoting/transport bug. Small (non-streamed) payloads are unaffected. Workarounds: wrap streamed calls in a timeout and retry (as `test.ps1` now does), or — if the remote `DefaultShell` is PowerShell, whose command line takes ~32 K chars instead of `cmd.exe`'s 8,191 — raise `RRUN_STREAM_LIMIT` (e.g. `30000`) so mid-size payloads avoid streaming entirely.
- `local` mode is bounded by the 32,767-char Windows process command line. The double encoding (payload → UTF-8 base64, embedded in a wrapper → UTF-16LE → base64) costs ~3.6 command-line chars per payload byte, so the practical ceiling is **~9 KB** of PowerShell payload; beyond that, use a file with `powershell -File`.
- PowerShell payload files are decoded by their BOM (UTF-8/16/32); **BOM-less files are treated as UTF-8**. Legacy ANSI-code-page scripts without a BOM will misdecode — save them with a BOM (or as UTF-8) first.
- `BatchMode=yes` is always on — key auth only, no password prompts; rrun never auto-accepts host keys.

## Install

**Humans**: clone, then in PowerShell run `.\install.ps1`. Re-run any time — it's idempotent *and* self-updating (refreshes `~/.rrun/bash_env` and the `.bashrc` block contents). It finishes by running `test.ps1`, which needs no remote host; add `.\test.ps1 -TargetHost <host>` afterwards for real ssh round-trips including the streaming path. `tests/core-tests.sh` runs the core against a mocked ssh on any Linux (and in CI on every push).

**Claude / AI agents**: point the agent at this repo and say "install this" — `CLAUDE.md` contains the exact steps and post-install rules of engagement.

**Linux-only hosts**: copy `bin/rrun` to `~/.local/bin/`, `chmod +x` — the core has no Windows dependencies.

## Changelog

- **2.3.5** (2026-08-10) — external-review round 6. **Bug (the real one)**: the PowerShell shim read *every* local file operand with `ReadAllText` — BOM-decode into a .NET string, re-encode as UTF-8 — so `rrun.ps1 -s bash local <file>` delivered *text* preservation, not *byte* preservation (a UTF-16LE or legacy-encoded shell file reached WSL transformed; core and Git Bash shim were unaffected). File operands now ride as **raw bytes** (`ReadAllBytes`); only the `ps` path decodes them to text (BOM-aware, same contract as the remote wrapper). CI regression with no WSL required: unusual-byte file → `-n -s bash local` → base64 extracted from the dry-run must equal the file bytes. **Hygiene**: all tempfile wrappers now install cleanup traps (`EXIT` + `HUP`/`INT`/`TERM`) so an interrupted wrapper never leaves the decoded payload (possibly containing secrets) on the target; the EXIT trap preserves the executor's exit status, and a new regression TERMs the wrapper's process group mid-payload and verifies the file disappears. **Docs**: script-file operands documented as payload transport, not remote staging (`$0`/`BASH_SOURCE` point at the temp file, no `$PSScriptRoot`); `mktemp`+`rm` added to the stated final-target requirements.
- **2.3.4** (2026-08-10) — external-review round 5: **execution is byte-for-byte again**. 2.3.3's status-checked decode used `s=$(echo <b64> | base64 -d)` — and command substitution strips trailing newlines, so a payload ending in backslash-newline (a line continuation) was executed with a trailing literal backslash instead and changed behavior (`<>` became `<\>`): the sender-side `$(cat)` class fixed in 2.3.0, accidentally recreated on the receiver. The embedded bash/sh path (core + both shims' local mode) now decodes to a **temp file** like the streaming path — exact bytes, honest decoder status, and the payload keeps the real stdin, all three at once. New regression *executes* the composed command with a backslash-newline-final payload and demands file semantics. Hop layers keep the `$(...)` form deliberately: their decoded text is rrun's own generated one-line ssh command, never user payload bytes. **Transparency contract stated correctly**: rrun reserves no exit codes — payload codes pass through untouched (a payload may `exit 125`); a transport decode failure is identified by the `rrun: ... decode failed` **stderr marker**, with 125 merely the code rrun uses for itself.
- **2.3.3** (2026-08-10) — external-review round 4: **the POSIX transport's exit status now always represents the remote executor**. (a) **Silent-success bug (the important one)**: `echo <b64> | base64 -d | shell` reports the *shell's* status — no pipefail exists in a POSIX login shell — so a missing/broken remote `base64` fed EOF to the shell and rrun exited **0 while the payload never ran**. Decoding is now a status-checked two-step (`s=$(echo <b64> | base64 -d) || exit 125; exec shell -c "$s"`; streamed variant decodes to a temp file), wrapped in `sh -c` so even csh/fish login shells parse it; **exit 125 = transport decode failure**, and the payload's own exit code is what rrun returns. Applied to the core (embedded + streamed + hop layers) and both shims' local bash/sh mode. Side effect, documented: non-streamed bash/sh payloads now read the real stdin instead of their own script text. (b) **False-failure bug**: under the core's `pipefail`, a large streamed script that exits before draining stdin SIGPIPEs the local `printf` (141) and rrun reported failure for a successful remote run; streamed sends are now judged by `PIPESTATUS[1]` (the ssh element) alone. Both bugs regression-tested by *executing* the real composed commands (sabotaged `base64` → 125 + nothing runs; healthy → payload's output and `exit 7` surface; no-stdin-reading ssh stub + 200 KB payload → exit 0). **Tests**: `test.ps1`'s timed-run helper now passes host/path as positional `$1..$3` instead of interpolating them into bash source (the tool's own payload-as-data rule). **Release hygiene**: tags added for 2.3.1+ — the newest tag no longer points at a version with the known false-success exit-code bug.
- **2.3.2** (2026-08-10) — external-review round 3 fixes. **Bug (the substantive one)**: remote/bash-shim ps payload files were unconditionally decoded as **UTF-8** after their byte-perfect transport — but Windows PowerShell's own `Out-File`/`>` default is **UTF-16LE**, so a perfectly ordinary `.ps1` arrived intact and then parsed as garbage (the ps shim's `local` mode was already BOM-aware via `ReadAllText`, so local and remote disagreed). Both wrappers (embedded + streaming bootstrap) now decode through a BOM-detecting `StreamReader`: UTF-8/16/32 BOMs honored, BOM-less = UTF-8 (documented; legacy BOM-less ANSI scripts still need re-saving). UTF-16LE functional regressions added in `shim-local-tests.ps1` (CI), `test.ps1` (ps shim local, bash shim local, real remote host), and a structural check in `core-tests.sh`. **Dry-run honesty**: the core renders `-n` output with bash `%q` quoting, which is *not* PowerShell-paste-safe (backslash isn't an escape there) — `rrun.ps1` now prints a stderr notice on remote dry-runs saying so (stdout stays machine-parseable). **Docs**: local ps payload ceiling corrected from ~12 KB to **~9 KB** (double base64 ≈ 3.6 chars/byte under the 32,767-char command line). **Installer**: `.bash_profile` integration now uses the same marker-managed block as `.bashrc` — the old "file mentions `.bashrc`" heuristic was fooled by comments.
- **2.3.1** (2026-08-10) — **failures are loud again.** 2.3.0's `& ([scriptblock]::Create(...))` wrapper masked payload failures: a remote/local ps command that failed (Write-Error, command-not-found, native non-zero) exited **0**, so callers and scripts saw false success — even though the error text was still printed to stderr. The wrapper now appends `if (-not $?) { exit 1 }` *inside* the scriptblock (where `$?` still reflects the payload's last statement, before the `&` operator masks it), reproducing a bare `powershell -Command` exit code exactly: any failure → non-zero, explicit `exit N` → N, error-then-recovery → 0. Verified on PowerShell 5.1 and pwsh 7, over a real Windows sshd, and on the streaming path. New exit-code + stderr-visibility regressions in `shim-local-tests.ps1` (Windows CI gate), `test.ps1`, and structural epilogue checks in `core-tests.sh`. Real-host verification also *surfaced* (not caused — confirmed by controlled A/B against the v2.3.0 bootstrap) a pre-existing Windows-sshd streamed-session race, now documented under Caveats; `test.ps1`'s real-host streamed checks run under a 60 s timeout with sweep-and-retry so a remote wedge is a loud WARN/FAIL instead of a silently hung suite, and the streamed-success exit code is now asserted (previously only the output text was checked).
- **2.3.0** (2026-08-10) — payload text is now NEVER modified. **Bugs**: the `$ProgressPreference` statement was prepended to ps payloads before encoding, breaking any script starting with `param()` or `using` (both must be a script's first statements); payloads now ride as untouched UTF-8 base64 inside a fixed wrapper that sets the preference and executes the decoded source as its own scriptblock — small remote, streamed remote, and both local shim paths. File/stdin sources are also encoded straight into base64 — the previous `$(cat)` capture stripped trailing newlines, so "byte-for-byte" is now literally true (`cmp`-verified in tests). **Hardening**: `install.ps1` passes the repo path to the WSL shell as positional data (`$1`) instead of interpolating it into shell source. **CI**: new `windows-latest` job runs the PowerShell shim's local mode with real `powershell.exe` (`tests/shim-local-tests.ps1`) — Windows semantics are now a merge gate, not just a manual suite.
- **2.2.1** (2026-08-10) — post-release review fixes. **Bug**: the large-payload ps streaming bootstrap rode as a bare `-Command iex(...)`; when the remote sshd's shell is PowerShell (`DefaultShell`, e.g. pwsh), that outer shell re-parsed the bootstrap — it evaluated the parenthesized subexpression itself and re-quoted the payload through a second `-Command` layer, silently corrupting `$`-bearing statements (verified against a real pwsh-DefaultShell host; stock `cmd.exe` sshd passed it through unharmed). The bootstrap now travels as `-EncodedCommand`, inert under cmd, PowerShell, and POSIX shells. **Hardening**: host tokens starting with `-` rejected (ssh would parse them as options); dry-run `%q`-quotes every ssh argv element (metachar `-J` args printed unquoted); PowerShell shim rejects `local -c` with no command (was a silent empty success). **Tests**: bootstrap-inertness and option-shaped-host regressions in `core-tests.sh`; `test.ps1 -TargetShell ps` now does a real large-payload streaming round-trip against a Windows host, and a no-remote-needed gateway-emulation section pipes a `$`-bearing probe through the composed command under all three sshd shells (cmd.exe, PowerShell 5.1, pwsh 7) exactly as sshd would invoke them.
- **2.2.0** (2026-08-10) — external-review fixes. **Bugs**: `-n local` no longer *executes* the payload (dry-run safety); `-c` arguments are opaque — only the script-source operand gets Windows→`/mnt` translation (previously `-c ./deploy.sh` could be rewritten to a local `/mnt/...` path). **Transport**: automatic stdin-streaming for payloads whose composed command exceeds `RRUN_STREAM_LIMIT` (default 6000; Windows `cmd.exe` 8191-char ceiling), fail-fast with `-J` advice for oversized nested-hop ps targets. **Hardening**: host tokens validated (only payload is armored; hop names are interpolated), `-s` validated in core and shims, missing-optarg errors, `cat --`, `%q` paste-safe dry-run output. **Install**: `BASH_ENV` now points at dedicated `~/.rrun/bash_env` (tiny, always refreshed; migrated automatically from the old `.bashrc` target); `.bashrc` marker block *replaced* on rerun, `.bash_profile` repaired if it doesn't source `.bashrc`; installer verifies via the full test suite. **CI**: mocked-ssh core regression suite (`tests/core-tests.sh`) on every push.
- **2.1.0** (2026-08-10) — Windows shims (Git Bash + PowerShell) with `wsl -e`, path translation, `local` host; `$HOME` trampoline removes hardcoded usernames; CLIXML progress suppression; `bashrc` wrappers + `BASH_ENV` delivery; installer.
- **2.0.0** (2026-08-10) — bash/sh targets, comma multi-hop with per-layer re-armoring, `-J`, `-n`, extension autodetect.
- **1.0.0** — PowerShell `-EncodedCommand` over ssh, single hop.
