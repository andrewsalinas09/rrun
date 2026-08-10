# Instructions for Claude (or any AI agent) working in this repo

This repo is **rrun** — a zero-escaping cross-shell/remote execution tool. Read README.md for the design. Two jobs you may be asked to do here:

## 1. Install on this machine

On Windows (with WSL + Git Bash):

1. Run `install.ps1` from the PowerShell tool: `& <repo>\install.ps1`. It is idempotent and verifies itself (step 5 dry-runs every entry point). It will not clobber an existing `BASH_ENV` or `PYTHONIOENCODING`.
2. If a `setx`-level step is blocked by sandboxing, run that single step with elevated permission rather than skipping it — `BASH_ENV` is what makes the fixes reach non-interactive tool shells.
3. Tell the user to **restart their Claude Code session / terminals** — PATH, `BASH_ENV`, and `PYTHONIOENCODING` are process-start env.
4. Smoke test after restart (needs a real ssh host with key auth):
   - `rrun -n examplehost -c hostname` from both Bash and PowerShell tools (dry-run, no ssh needed)
   - `rrun local -c "Get-Date"` (no ssh needed)
   - `bash -c 'type wsl'` should print `wsl is a function` (proves BASH_ENV loaded)
5. Recommend adding the "Payload-as-data" and rrun usage rules below to the user's global `~/.claude/CLAUDE.md`.

On a pure-Linux machine: copy `bin/rrun` to `~/.local/bin/`, `chmod +x` — done.

## 2. Rules of engagement once installed (put these in the user's global CLAUDE.md)

- **Payload-as-data rule**: never pass non-trivial payloads through nested interpreter layers as escaped strings. Write tool → file → run the file, or use `rrun`. More than one level of quoting = switch patterns.
- Use `rrun` instead of hand-quoting any `ssh`/`wsl bash -c`/nested `powershell -Command` invocation. Default target shell is `ps`; pass `-s bash` for Linux hosts.
- No heredocs in the Windows Bash tool (CRLF corrupts them) — Write tool → file → run.
- The Windows Bash tool is Git Bash (MSYS): it mangles POSIX-looking args to native exes. The installed `wsl`/`adb` wrappers handle those two; prefix `MSYS_NO_PATHCONV=1` for others.
- **RSI rule**: when a failure belongs to a class this tool was built to eliminate, fix the tool (and note it in the file header + commit), not just the instance.

## Repo conventions

- `bin/rrun` and `bin/rrun-shim.bash` MUST keep LF endings (enforced via .gitattributes); CRLF breaks them at runtime.
- Version history lives in each file's header comment and README's changelog — update both when behavior changes.
- Hardcoded usernames/paths are forbidden in `bin/` — resolve `$HOME`/`%USERPROFILE%` at runtime (see the `sh -c '... "$@"' rrun` trampoline).
