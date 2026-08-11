# tests/matrix — the environment matrix

rrun's bugs are environment-shaped by construction (see CLAUDE.md §4): the
tool exists to cross environment boundaries, so one dev box — or CI's two
well-groomed runners — cannot find its failures. This directory runs the core
(`bin/rrun`) across containerized environment *combinations*, over **real ssh
between containers**, including multi-hop chains where only the intermediate
host holds the next key.

## Run it

```bash
bash tests/matrix/matrix.sh            # everything (builds images on first run)
bash tests/matrix/matrix.sh pwsh hop   # only scenarios whose name matches a substring
```

Any Linux with docker works (WSL, CI's ubuntu runner). Exit code = number of
failed scenarios. Runs in CI as the `env-matrix` job.

## Architecture

- **One user-defined docker network per run** — containers reach each other
  by container name (DNS).
- **Per-link ssh keys**: for a chain `sender → h1 → h2`, the sender's key
  opens only `h1`, and `h1`'s key opens `h2` — the exact "intermediate holds
  the keys" topology nested hops exist for. The `topology-honesty` cell
  proves the sender *cannot* shortcut past a hop.
- **known_hosts is pre-seeded** by `ssh-keyscan` (retried — doubling as sshd
  readiness detection), because rrun never auto-accepts host keys.
- **The sender is a container too**, with the repo's `bin/rrun` bind-mounted,
  so sender-side userland (bash version, base64 flavor, iconv) is itself a
  matrix axis. `sender-run.sh` builds the payload, runs rrun, and grades the
  result against the scenario's expectation.

## Images (all small, env-driven via the shared `entrypoint.sh`)

| Image | Base | Axis it contributes |
|---|---|---|
| `Dockerfile.node` | ubuntu 24.04 | modern GNU baseline; csh/fish preinstalled for `LOGIN_SHELL` cells |
| `Dockerfile.alpine` | alpine 3.20 | busybox userland, ash login shell, musl libc; `PKGS` build-arg adds bash/musl-utils for hop/sender roles |
| `Dockerfile.dropbear` | alpine 3.20 | dropbear sshd (routers/embedded); openssh client kept for hop roles |
| `Dockerfile.pwsh` | ubuntu 24.04 | pwsh target (`powershell` by symlink) and pwsh-as-gateway (`LOGIN_SHELL=/usr/bin/pwsh` = the DefaultShell re-parse class) |
| `Dockerfile.macsim` | bash:3.2 | macOS *proxy* sender: bash 3.2 (what macOS ships) + `bsd-base64.sh` (no `-w`, single-line encode) |

Runtime knobs (set per-cell via `image^ENV=VAL` in the chain spec):
`LOGIN_SHELL` rewrites root's shell; `SABOTAGE` is a comma list of
`stub-base64` (present but broken), `rm-mktemp`, `rm-bash` (genuinely absent).

## Adding a cell

One line in `matrix.sh`:

```bash
scenario <name> <sender_image> '<chain spec>' <ps|bash|sh> <zero|small|large> <expect> [mode]
```

Expectations: `ok` (marker + exact exit code), `decodefail` (loud 125 +
stderr marker, payload never ran), `rc125`, `hopfail`, `denied`, `gwflat`
(output intact, exit flattened to 1 — pwsh gateways), `xfail` (suspected
breakage; an unexpected pass FAILS the suite so fixes get promoted to `ok`),
`probe` (discovery: report, never gate). Modes: `normal`, `stdin`, `jump`
(ProxyJump), `shortcut` (topology honesty).

New environment suspicion → new image or `SABOTAGE`/`LOGIN_SHELL` knob + one
scenario line. Suspected-broken cells start as `xfail`/`probe`, get promoted
to `ok` when fixed.

## What the first run found (all fixed or pinned in 2.5.0)

1. **macOS/BSD senders died at `base64 -w0`** (GNU-only flag) — confirmed the
   CLAUDE.md suspicion; fixed by `b64enc()` in the core, and the macos-sim
   cells now demand full success (including streamed-large under bash 3.2).
2. **Hop requirements were mapped to the wrong hosts**: the hop-decode layer
   executes on chain hosts 2..N (final included), while the *first* hop only
   parses `ssh next '<quoted>'` — csh works there and a csh *mid*-hop fails
   loudly. The layer now runs `exec sh -c`, so `bash` is required nowhere.
3. **pwsh sshd gateways flatten non-zero exit codes to 1** (`pwsh -c`
   semantics); output is byte-perfect and zero survives. Documented in the
   README caveats; pinned exact by the `gwflat` cells.
4. Probes: alpine/musl senders fully work — busybox `base64 -w0` and
   musl-utils `iconv` → UTF-16LE are both fine.

## The Windows lane (`matrix-win.ps1`, since 2.6.0)

The axes Linux containers cannot host: **real Windows PowerShell 5.1, real
Windows OpenSSH sshd** (Win32-OpenSSH in servercore), pwsh 7, and the
cmd / powershell(5.1) / pwsh `DefaultShell` gateway axis — selected at
runtime via `DEFAULT_SHELL` (see `ep-win.ps1`). The sender runs `bin/rrun`
under **Git Bash (MSYS)** — itself an axis, and the only configuration where
the core runs with no WSL anywhere.

Requirements: docker Windows engine — locally that means the Containers +
Microsoft-Hyper-V features and `DockerCli.exe -SwitchDaemon` (the Linux lane
is unaffected: WSL integration always talks to the Linux engine); GitHub's
`windows-2022` runner has it natively. Since 2.7.0 the lane is **split by
`-Mode`** so CI can gate on what is deterministic: `win-matrix` runs
`-Mode deterministic` (small + UTF-16LE cells, no streaming so the wedge race
cannot flake it) as a **required** job, and `win-matrix-stress` runs
`-Mode stress` (the streamed-large cells that deliberately walk into the
wedge race, with retries) as an advisory `continue-on-error` job. The
PowerShell-gateway exit-code flattening (`exit 5 -> 1` on 5.1 AND pwsh;
`exit 5 -> 5` on cmd) is **pinned as an assertion** in both modes — if a
future OpenSSH/PowerShell restores fidelity, CI says so loudly.

First-run findings:
- **The streamed-session wedge race reproduces on demand** — on every
  gateway, cmd.exe included (one run: 3/3 wedges on cmd, 2/3 on 5.1, 1/3 on
  pwsh), correcting the belief that it was pwsh-`DefaultShell`-specific.
  Streamed cells run with timeout + 5 retries and LOUD per-run wedge counts:
  the flake is the measurement.
- **5.1 gateways flatten non-zero exit codes to 1, exactly like pwsh** —
  PowerShell-family behavior, both editions (README caveat updated).
- Green otherwise: exact exit codes through cmd, UTF-16LE decode on real
  5.1, streamed payloads un-reparsed.

Windows-container gotchas already banked as comments at their point of use:
case-sensitive GitHub release-tag URLs; `net user` prompting on >14-char
passwords (no stdin in builds) and failing opaquely in build-time
`powershell -Command` (user creation lives in the entrypoint, under `-File`);
WinNAT rejecting host-IP port bindings; `docker cp` unsupported against
running Hyper-V containers (mount volumes at start); Git Bash ssh resolving
home from the Windows profile and IGNORING `$HOME` (per-run config rides an
`ssh -F` wrapper on `PATH`); `administrators_authorized_keys` needs
SYSTEM/Administrators *ownership*, not just the right ACLs, and sshd only
says so at `LogLevel DEBUG3`.

### Windows lane: current status (2026-08-11)

Working and findings-verified, with one caveat: under a wedge BURST the lane
gets slow (each wedge costs a 75 s timeout + a sweep), and one full-green run
of the final file-redirect version is still outstanding -- an earlier version
hung forever because attempt output was captured via `$(...)` command
substitution, which blocks until every pipe writer exits, and an MSYS
`timeout` kill can orphan the streamed pipeline's ssh against a wedged
session. Attempt output now goes to files (control returns when the timeout
fires), the sweep clears the remote side between tries, and container boots
are staggered with one retry (simultaneous Hyper-V starts can kill a
container at boot). Only the stress half stays `continue-on-error` (with a
hard `timeout-minutes`); the deterministic half gates.

## Known gaps (planned lanes)

- **Real macOS**: macos-sim is a faithful-in-two-ways proxy, not a Mac; a
  `macos-latest` CI sender job would close the gap.
- sshd *version* axis (old OpenSSH releases), and randomized tool-version
  interleaving instead of curated combinations.
- Cross-OS chains (Linux hop -> Windows final target): the two docker
  engines have separate networks, so this needs host-published ports as the
  bridge.
