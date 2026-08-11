#!/usr/bin/env bash
# tests/matrix/matrix.sh -- the ENVIRONMENT MATRIX (CLAUDE.md section 4).
#
# rrun's bugs are environment-shaped by construction: one dev box cannot find
# them, and CI's two well-groomed runners cannot either. This suite runs the
# rrun core across containerized environment combinations, over REAL ssh
# between containers, including multi-hop chains where only the intermediate
# holds the next key.
#
# Axes covered (each has confirmed or suspected bug yield -- see CLAUDE.md):
#   * userland: GNU (ubuntu) vs busybox/musl (alpine) vs BSD-ish (macos-sim)
#   * sender bash: modern 5.x vs macOS's 3.2; sender base64: GNU -w0 vs BSD
#   * sshd: OpenSSH vs dropbear
#   * login shell on hops/targets: bash, ash, dash, csh, fish, pwsh
#   * pwsh as sshd gateway (the DefaultShell re-parse class, v2.2.1)
#   * missing/broken deps: base64 broken, mktemp absent, bash absent
#   * topology: single hop, nested 2-3 hop chains, ProxyJump, streamed large
#     payloads through all of them (md5-verified), stdin, exit codes
#
# Windows-only axes (PowerShell 5.1, Windows sshd, cmd.exe limits) CANNOT run
# in Linux containers -- they live in test.ps1 / tests/ps-edition-checks.ps1,
# and a Windows-container lane is the planned complement to this file.
#
# Run from any Linux with docker (WSL, CI): bash tests/matrix/matrix.sh
# Optional: pass scenario-name substrings to run a subset, e.g.
#   bash tests/matrix/matrix.sh pwsh dropbear
# Exit code = number of failed scenarios.
set -euo pipefail
cd "$(dirname "$0")"
REPO=$(cd ../.. && pwd)

RUNID="mx$$"
NET="rrun-$RUNID"
FILTER=("$@")

TMPROOT=$(mktemp -d)
cleanup() {
  docker ps -aq --filter "label=rrun-matrix=$RUNID" | xargs -r docker rm -f >/dev/null 2>&1 || true
  docker network rm "$NET" >/dev/null 2>&1 || true
  rm -rf "$TMPROOT"
}
trap cleanup EXIT

echo '[build] matrix images'
build() { echo "  $1"; docker build -q -t "$1" "${@:2}" . >/dev/null; }
build rrun-mx-node          -f Dockerfile.node
build rrun-mx-alpine        -f Dockerfile.alpine
build rrun-mx-alpine-bash   -f Dockerfile.alpine --build-arg PKGS=bash
build rrun-mx-alpine-sender -f Dockerfile.alpine --build-arg 'PKGS=bash musl-utils'
build rrun-mx-dropbear      -f Dockerfile.dropbear --build-arg PKGS=bash
build rrun-mx-pwsh          -f Dockerfile.pwsh
build rrun-mx-macsim        -f Dockerfile.macsim

docker network inspect "$NET" >/dev/null 2>&1 || docker network create "$NET" >/dev/null

pass=0 fail=0 skip=0
declare -a FAILED=()

# scenario <name> <sender_image> <chain_spec> <tshell> <size> <expect> [mode]
#   chain_spec: comma-joined node specs, each `image[^ENV=VAL...]`
#   (short image names get the rrun-mx- prefix)
scenario() {
  local name=$1 sender_img=rrun-mx-$2 chainspec=$3 tshell=$4 size=$5 expect=$6 mode=${7:-normal}

  if ((${#FILTER[@]})); then
    local hit=0 f
    for f in "${FILTER[@]}"; do [[ $name == *"$f"* ]] && hit=1; done
    if ((!hit)); then skip=$((skip+1)); return 0; fi
  fi
  echo "=== $name  (sender=$2 chain=$chainspec -s $tshell $size expect=$expect${mode:+ mode=$mode})"

  local tmp="$TMPROOT/$name"; mkdir -p "$tmp"
  local specs=() names=() i
  IFS=, read -ra specs <<<"$chainspec"
  local n=${#specs[@]}

  # per-LINK keys: key0 = sender; key i lives on node i and opens node i+1.
  # jump mode instead authorizes key0 everywhere (ProxyJump auths as the
  # sender at every stop; intermediates hold no keys of their own).
  for ((i=0; i<n; i++)); do ssh-keygen -q -t ed25519 -N '' -f "$tmp/key$i"; done
  for ((i=1; i<=n; i++)); do
    local kdir="$tmp/keys$i"; mkdir -p "$kdir"
    if [[ $mode == jump ]]; then cp "$tmp/key0.pub" "$kdir/authorized_keys"
    else cp "$tmp/key$((i-1)).pub" "$kdir/authorized_keys"; fi
    if [[ $mode != jump ]] && ((i < n)); then cp "$tmp/key$i" "$kdir/id_ed25519"; fi

    local spec=${specs[$((i-1))]} img envflags=()
    img="rrun-mx-${spec%%^*}"
    if [[ $spec == *^* ]]; then
      local kv rest=${spec#*^}
      while [[ -n $rest ]]; do
        kv=${rest%%^*}; envflags+=(-e "$kv")
        [[ $rest == *^* ]] && rest=${rest#*^} || rest=''
      done
    fi
    local cname="rrun-$RUNID-$name-$i"
    docker run -d --name "$cname" --hostname "n$i" --network "$NET" \
      --label "rrun-matrix=$RUNID" -v "$kdir":/keys:ro "${envflags[@]}" "$img" >/dev/null
    names+=("$cname")
  done

  # teach each hop the NEXT hop's host key (retry doubles as sshd readiness);
  # jump mode needs none of this -- intermediates only forward TCP there
  local setup_ok=1
  if [[ $mode != jump ]]; then
    for ((i=0; i<n-1; i++)); do
      local from=${names[$i]} to=${names[$((i+1))]} ok=0 t
      for t in $(seq 1 40); do
        if docker exec "$from" sh -c "ssh-keyscan -T 2 $to >> /root/.ssh/known_hosts 2>/dev/null && grep -q $to /root/.ssh/known_hosts"; then
          ok=1; break
        fi
        sleep 0.5
      done
      if ((!ok)); then echo "  FAIL  $name -- setup: keyscan $to from $from never succeeded"; setup_ok=0; break; fi
    done
  fi

  local rc=0
  if ((setup_ok)); then
    local sdir="$tmp/keys0"; mkdir -p "$sdir"; cp "$tmp/key0" "$sdir/id_ed25519"
    local chain; chain=$(IFS=,; echo "${names[*]}")
    docker run --rm --network "$NET" --label "rrun-matrix=$RUNID" \
      -v "$REPO/bin/rrun":/usr/local/bin/rrun:ro \
      -v "$sdir":/keys:ro \
      -v "$PWD/sender-run.sh":/sender-run.sh:ro \
      -e "CHAIN=$chain" -e "TSHELL=$tshell" -e "SIZE=$size" -e "MODE=$mode" \
      -e "EXPECT=$expect" -e "FINAL=n$n" -e "RUNID=$RUNID" \
      --entrypoint bash "$sender_img" /sender-run.sh 2>&1 | sed 's/^/  /' || rc=$?
  else
    rc=90
  fi

  docker rm -f "${names[@]}" >/dev/null 2>&1 || true
  if ((rc == 0)); then pass=$((pass+1)); else fail=$((fail+1)); FAILED+=("$name (rc=$rc)"); fi
}

# --- the matrix ------------------------------------------------------------
# baseline transport claims on the modern-GNU node
scenario baseline-small        node 'node'                bash small ok
scenario baseline-stdin        node 'node'                bash small ok stdin
scenario baseline-2hop-large   node 'node,node'           bash large ok
scenario topology-honesty      node 'node,node'           bash small denied shortcut
scenario proxyjump             node 'node,node'           bash small ok jump
scenario mixed-3hop-large      node 'node,alpine-bash,node' bash large ok

# busybox/musl userland (alpine)
scenario alpine-target-sh      node 'alpine'              sh   small ok
scenario alpine-target-large   node 'alpine'              sh   large ok
scenario alpine-hop-large      node 'alpine-bash,node'    bash large ok
scenario alpine-sender         alpine-sender 'node'       bash small probe
scenario alpine-sender-ps      alpine-sender 'pwsh'       ps   small probe

# non-OpenSSH sshd
scenario dropbear-target       node 'dropbear'            sh   small ok
scenario dropbear-hop          node 'dropbear,node'       bash small ok

# login-shell axis, position-sensitive (matrix discovery, fixed in core v2.4):
# the FIRST chain host only parses `ssh next '<quoted>'` -- csh/dash/no-bash
# are all fine there. Hosts 2..N (INCLUDING the final of a chain) execute the
# hop-decode layer: POSIX login shell + base64 + sh required -- so csh at
# position 2 must fail LOUDLY, while bash is needed nowhere at all.
scenario csh-login-target      node 'node^LOGIN_SHELL=/bin/csh'      bash small ok
scenario fish-login-target     node 'node^LOGIN_SHELL=/usr/bin/fish' bash small ok
scenario csh-first-hop         node 'node^LOGIN_SHELL=/bin/csh,node' bash small ok
scenario csh-mid-hop           node 'node,node^LOGIN_SHELL=/bin/csh,node' bash small hopfail
scenario nobash-first-hop      node 'node^LOGIN_SHELL=/bin/dash^SABOTAGE=rm-bash,node' bash small ok
scenario nobash-mid-hop        node 'node,node^LOGIN_SHELL=/bin/dash^SABOTAGE=rm-bash,node' bash small ok
scenario nobash-target-sh      node 'node^LOGIN_SHELL=/bin/dash^SABOTAGE=rm-bash'      sh small ok
scenario chain-final-minimal   node 'node,alpine'         sh   small ok

# broken/missing deps on the target: transport must fail loudly, never
# silently succeed (the v2.3.3 class)
scenario broken-b64-target     node 'node^SABOTAGE=stub-base64' bash small decodefail
scenario nomktemp-target       node 'node^SABOTAGE=rm-mktemp'   bash small rc125

# PowerShell targets and gateways (Linux pwsh; `powershell` by symlink).
# gwflat = matrix discovery: a pwsh sshd gateway flattens NON-ZERO payload
# exit codes to 1 (`pwsh -c` semantics) while output arrives byte-perfect and
# zero still round-trips as zero. Documented in the README caveats.
scenario pwsh-target-small     node 'pwsh'                            ps   small ok
scenario pwsh-target-large     node 'pwsh'                            ps   large ok
scenario pwsh-gateway-zero     node 'pwsh^LOGIN_SHELL=/usr/bin/pwsh'  ps   zero  ok
scenario pwsh-gateway-small    node 'pwsh^LOGIN_SHELL=/usr/bin/pwsh'  ps   small gwflat
scenario pwsh-gateway-large    node 'pwsh^LOGIN_SHELL=/usr/bin/pwsh'  ps   large gwflat
scenario pwsh-gateway-bash     node 'pwsh^LOGIN_SHELL=/usr/bin/pwsh'  bash small gwflat

# macOS proxy sender: bash 3.2 + BSD base64 (no -w flag). This cell CONFIRMED
# the CLAUDE.md suspicion (sender died on `base64 -w0`); core v2.4's b64enc()
# fallback fixed the class, so the cell now demands full success.
scenario macos-sim-sender      macsim 'node'              bash small ok
scenario macos-sim-large       macsim 'node'              bash large ok
# ---------------------------------------------------------------------------

echo
echo "matrix: $pass passed, $fail failed, $skip skipped"
if ((fail)); then printf '  FAILED: %s\n' "${FAILED[@]}"; fi
exit "$fail"
