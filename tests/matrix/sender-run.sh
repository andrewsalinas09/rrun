#!/usr/bin/env bash
# Runs INSIDE the sender container (mounted by matrix.sh; bash-3.2-compatible:
# no mapfile, no assoc arrays -- the macos-sim sender is bash 3.2).
#
# env in: CHAIN  comma list of container DNS names (rrun's hostspec)
#         TSHELL ps|bash|sh    SIZE small|large    MODE normal|stdin|jump
#         EXPECT ok|decodefail|rc125|hopfail|xfail|probe
#         FINAL  hostname of the last node    RUNID  unique run marker
# exit: 0 pass, 1 fail, 90 setup failure (not an rrun verdict)
set -uo pipefail
IFS=, read -ra NODES <<<"$CHAIN"

mkdir -p /root/.ssh && chmod 700 /root/.ssh
install -m 600 /keys/id_ed25519 /root/.ssh/id_ed25519
scan() {  # readiness + host-key learning in one motion (rrun never auto-accepts)
  local h=$1 i
  for i in $(seq 1 40); do
    ssh-keyscan -T 2 "$h" >> /root/.ssh/known_hosts 2>/dev/null &&
      grep -q "$h" /root/.ssh/known_hosts && return 0
    sleep 0.5
  done
  return 1
}
scan "${NODES[0]}" || { echo "SETUP-FAIL: keyscan ${NODES[0]}"; exit 90; }
if [[ $MODE == jump || $MODE == shortcut ]]; then
  # jump: the TARGET's host key is verified by the sender through the tunnel.
  # shortcut: host-key check happens BEFORE auth, so the denial being tested
  # must come from auth, not from an unknown host key.
  scan "${NODES[1]}" || { echo "SETUP-FAIL: keyscan ${NODES[1]}"; exit 90; }
fi

mark="MX-$RUNID"
want_rc=0 want_out=''
case "$TSHELL-$SIZE" in
  ps-zero)   # success (exit 0) payload -- for gateway cells where non-zero
             # codes are flattened but ZERO must still come back as zero
    p=/tmp/p.ps1
    printf 'Write-Output "%s-ps0"\n' "$mark" > "$p"
    want_rc=0 want_out="$mark-ps0" ;;
  *-zero)
    p=/tmp/p.sh
    printf 'echo "%s-sh0"\n' "$mark" > "$p"
    want_rc=0 want_out="$mark-sh0" ;;
  ps-small)
    p=/tmp/p.ps1
    printf 'Write-Output "%s-ps"\nexit 5\n' "$mark" > "$p"
    want_rc=5 want_out="$mark-ps" ;;
  ps-large)
    # param() must stay the first statement, and the $-bearing marker proves
    # no gateway shell re-parsed the payload (the v2.2.1 corruption class)
    p=/tmp/p.ps1
    { printf 'param([string]$m = "%s-psbig")\n$x = $m\nWrite-Output "got:[$x]"\n' "$mark"
      i=1; while [ $i -le 400 ]; do echo "# padding line $i to push past the streaming threshold"; i=$((i+1)); done
      echo 'exit 7'; } > "$p"
    want_rc=7 want_out="got:[$mark-psbig]" ;;
  *-small)
    p=/tmp/p.sh
    printf 'echo "%s-$(hostname)"\nexit 5\n' "$mark" > "$p"
    want_rc=5 want_out="$mark-$FINAL" ;;
  *-large)
    # payload reports byte count + md5 of the file it EXECUTES FROM ($0), so a
    # short or corrupted stream fails loudly, not just a missing marker
    p=/tmp/p.sh
    { printf 'echo "BYTES:$(wc -c < "$0") MD5:$(md5sum < "$0" | cut -d" " -f1) %s-big"\n' "$mark"
      i=1; while [ $i -le 900 ]; do echo "# padding line $i to push past the streaming threshold"; i=$((i+1)); done
      echo 'exit 7'; } > "$p"
    md5=$(md5sum < "$p" | cut -d' ' -f1)
    want_rc=7 want_out="BYTES:$(wc -c < "$p") MD5:$md5 $mark-big" ;;
esac

case "$MODE" in
  jump)
    out=$(timeout 90 rrun -J "${NODES[0]}" -s "$TSHELL" "${NODES[1]}" "$p" 2>/tmp/err); rc=$? ;;
  shortcut)
    # harness honesty: the sender holds NO key the second node accepts, so
    # going at it directly must be denied -- proving that chain scenarios
    # really route through their hops
    out=$(timeout 30 rrun -s bash "${NODES[1]}" "$p" 2>/tmp/err); rc=$? ;;
  stdin)
    # embedded (small) bash payloads read the REAL ssh channel (v2.3.3)
    out=$(printf 'stdin-data' | timeout 90 rrun -s bash "$CHAIN" -c 'cat; exit 5' 2>/tmp/err); rc=$?
    want_rc=5 want_out='stdin-data' ;;
  *)
    out=$(timeout 90 rrun -s "$TSHELL" "$CHAIN" "$p" 2>/tmp/err); rc=$? ;;
esac

got_ok() { [[ $rc == "$want_rc" && $out == *"$want_out"* ]]; }
detail() { echo "rc=$rc (want $want_rc) out=[$(printf %s "$out" | tail -c 300)] err=[$(tail -c 300 /tmp/err 2>/dev/null)]"; }

case "$EXPECT" in
  ok)
    if got_ok; then echo "RESULT PASS"; exit 0; fi
    echo "RESULT FAIL $(detail)"; exit 1 ;;
  decodefail)  # transport contract: loud 125 + stderr marker, payload NEVER ran
    if [[ $rc == 125 && $out != *"$mark"* ]] && grep -q 'decode failed' /tmp/err; then
      echo "RESULT PASS (decode failure loud, payload never ran)"; exit 0; fi
    echo "RESULT FAIL $(detail)"; exit 1 ;;
  rc125)       # transport failure without the decode marker (e.g. no mktemp)
    if [[ $rc == 125 && $out != *"$mark"* ]]; then
      echo "RESULT PASS (rc=125, payload never ran)"; exit 0; fi
    echo "RESULT FAIL $(detail)"; exit 1 ;;
  hopfail)     # a hop missing its documented deps must fail loudly, not run
    if [[ $rc != 0 && $out != *"$mark"* ]]; then
      echo "RESULT PASS (hop failed loudly, rc=$rc)"; exit 0; fi
    echo "RESULT FAIL $(detail)"; exit 1 ;;
  denied)      # ssh auth denial (transport rc 255), payload never ran
    if [[ $rc == 255 && $out != *"$mark"* ]]; then
      echo "RESULT PASS (denied as required, rc=255)"; exit 0; fi
    echo "RESULT FAIL $(detail)"; exit 1 ;;
  gwflat)      # pwsh/powershell sshd gateways FLATTEN non-zero exit codes to 1
               # (`pwsh -c` maps any failing native command to 1). Output must
               # arrive byte-perfect; the exact-1 pin means a future fidelity
               # fix flips this cell loudly instead of passing unnoticed.
    if [[ $rc == 1 && $out == *"$want_out"* ]]; then
      echo "RESULT PASS (output intact; exit flattened to 1 by gateway, documented)"; exit 0; fi
    echo "RESULT FAIL $(detail)"; exit 1 ;;
  xfail)       # documented/suspected breakage: failing is the expected result
    if got_ok; then
      echo "RESULT FAIL XPASS -- expected failure PASSED; promote this scenario to 'ok'"; exit 1; fi
    echo "RESULT PASS (XFAIL as expected) $(detail)"; exit 0 ;;
  probe)       # discovery cell: report, never gate
    if got_ok; then echo "RESULT PROBE worked: $(detail)"; else echo "RESULT PROBE failed: $(detail)"; fi
    exit 0 ;;
  *) echo "SETUP-FAIL: unknown EXPECT '$EXPECT'"; exit 90 ;;
esac
