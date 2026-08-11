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

## Known gaps (planned lanes)

- **Windows containers**: PowerShell 5.1, real Windows sshd, cmd.exe's 8191
  limit, the streamed-wedge race — `mcr.microsoft.com/windows/servercore`
  has all of it; needs the Windows Containers feature on the host (GitHub
  `windows-2022` runners can run them in CI).
- **Real macOS**: macos-sim is a faithful-in-two-ways proxy, not a Mac; a
  `macos-latest` CI sender job would close the gap.
- sshd *version* axis (old OpenSSH releases), and randomized tool-version
  interleaving instead of curated combinations.
