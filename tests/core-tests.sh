#!/usr/bin/env bash
# Mocked-ssh regression tests for bin/rrun (the core). Needs only bash, base64,
# iconv — runs on ubuntu CI, WSL, or any Linux box. ssh is replaced by a stub
# that records its argv and stdin, so composition and armoring are asserted
# without any network.
set -u
cd "$(dirname "$0")/.."
RRUN=bin/rrun
fail=0
check() {  # check <name> <ok(0/1)>
  if [[ $2 == 0 ]]; then echo "  PASS  $1"; else echo "  FAIL  $1"; fail=$((fail+1)); fi
}

work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
export STUB_OUT="$work/out"
mkdir -p "$work/bin"
cat > "$work/bin/ssh" <<'STUB'
#!/usr/bin/env bash
printf '%s\0' "$@" > "$STUB_OUT.argv"
cat > "$STUB_OUT.stdin"
STUB
chmod +x "$work/bin/ssh"
stubpath="$work/bin:$PATH"
argv() { mapfile -d '' ARGV < "$STUB_OUT.argv"; }

echo '[syntax]'
bash -n "$RRUN"; check 'core parses (bash -n)' $?
bash -n bin/rrun-shim.bash; check 'gitbash shim parses (bash -n)' $?

echo '[composition]'
out=$("$RRUN" -n examplehost -c 'Get-Date')
[[ $out == 'ssh -o BatchMode=yes examplehost powershell'* && $out == *EncodedCommand* ]]
check 'ps dry-run composes' $?

out=$("$RRUN" -n -s bash h1,h2 -c 'echo hi')
[[ $out == 'ssh -o BatchMode=yes h1 ssh'* && $out == *h2* && $out == *base64* ]]
check 'multi-hop dry-run composes' $?

payload='tricky "double\" $dollar `backtick` | ; & payload'
PATH="$stubpath" "$RRUN" -s bash examplehost -c "$payload" < /dev/null
argv
b64=$(sed -n 's/^echo \([A-Za-z0-9+/=]*\) | base64 -d | bash$/\1/p' <<<"${ARGV[-1]}")
[[ -n $b64 && $(printf %s "$b64" | base64 -d) == "$payload" ]]
check 'bash payload survives armoring byte-for-byte' $?

PATH="$stubpath" "$RRUN" examplehost -c 'Get-Date # metachars $x "y"' < /dev/null
argv
b64=${ARGV[-1]##* }
wrapper=$(printf %s "$b64" | base64 -d | iconv -f UTF-16LE -t UTF-8)
pb64=$(sed -n "s/.*FromBase64String('\([A-Za-z0-9+/=]*\)').*/\1/p" <<<"$wrapper")
[[ $(printf %s "$pb64" | base64 -d) == 'Get-Date # metachars $x "y"' && $wrapper == "\$ProgressPreference='SilentlyContinue'; & ([scriptblock]::Create("* ]]
check 'ps payload survives untouched inside scriptblock wrapper' $?

# REGRESSION: the wrapper must carry the exit-propagation epilogue, else a
# failing remote ps payload exits 0 (the & operator masks it) and callers
# can't tell success from failure — the whole point of a transport tool.
[[ $wrapper == *'if (-not $?) { exit 1 }'* ]]
check 'ps wrapper propagates payload failure (exit-code epilogue present)' $?

# REGRESSION: payload text must NEVER be modified — a prepended statement broke
# param()/using payloads (must be a script's first statements) — and must keep
# trailing newlines ($(cat) capture used to strip them). cmp = byte-for-byte.
printf 'using namespace System.Text\nparam($x)\nWrite-Output ok\n\n' > "$work/payload.ps1"
PATH="$stubpath" "$RRUN" examplehost "$work/payload.ps1" < /dev/null
argv
wrapper=$(printf %s "${ARGV[-1]##* }" | base64 -d | iconv -f UTF-16LE -t UTF-8)
sed -n "s/.*FromBase64String('\([A-Za-z0-9+/=]*\)').*/\1/p" <<<"$wrapper" | tr -d '\n' | base64 -d > "$work/decoded"
cmp -s "$work/payload.ps1" "$work/decoded"
check 'ps file payload byte-for-byte: using/param first lines, trailing newlines' $?

printf 'echo ok\n\n\n' > "$work/payload.sh"
PATH="$stubpath" "$RRUN" -s bash examplehost "$work/payload.sh" < /dev/null
argv
sed -n 's/^echo \([A-Za-z0-9+/=]*\) | base64 -d | bash$/\1/p' <<<"${ARGV[-1]}" | tr -d '\n' | base64 -d > "$work/decoded"
cmp -s "$work/payload.sh" "$work/decoded"
check 'bash file payload byte-for-byte: trailing newlines preserved' $?

PATH="$stubpath" "$RRUN" -s bash h1,h2 -c 'echo deep' < /dev/null
argv
inner_b64=$(sed -n "s/^ssh -o BatchMode=yes h2 'echo \([A-Za-z0-9+/=]*\) | base64 -d | bash'$/\1/p" <<<"${ARGV[-1]}")
layer=$(printf %s "$inner_b64" | base64 -d)
b64=$(sed -n 's/^echo \([A-Za-z0-9+/=]*\) | base64 -d | bash$/\1/p' <<<"$layer")
[[ $(printf %s "$b64" | base64 -d) == 'echo deep' ]]
check 'multi-hop unwraps layer-by-layer to original payload' $?

echo '[streaming]'
RRUN_STREAM_LIMIT=10 PATH="$stubpath" "$RRUN" -s bash examplehost -c 'echo big-payload' < /dev/null
argv
[[ ${ARGV[-1]} == 'base64 -d | bash' && $(base64 -d < "$STUB_OUT.stdin") == 'echo big-payload' ]]
check 'large bash payload streams over stdin' $?

RRUN_STREAM_LIMIT=10 PATH="$stubpath" "$RRUN" examplehost -c 'Get-BigThing' < /dev/null
argv
decoded=$(base64 -d < "$STUB_OUT.stdin")
bootb64=$(sed -n 's/^powershell -NoProfile -ExecutionPolicy Bypass -EncodedCommand \([A-Za-z0-9+/=]*\)$/\1/p' <<<"${ARGV[-1]}")
boot=$(printf %s "$bootb64" | base64 -d | iconv -f UTF-16LE -t UTF-8)
[[ -n $bootb64 && $boot == *'FromBase64String([Console]::In.ReadToEnd())'* && $boot == *scriptblock* && $boot == *'if (-not $?) { exit 1 }'* && $decoded == 'Get-BigThing' ]]
check 'large ps payload streams behind fixed scriptblock bootstrap (with exit epilogue)' $?

# REGRESSION: the ps streaming bootstrap must be INERT in the remote sshd shell
# (cmd, PowerShell via DefaultShell, or a POSIX sh). A bare "-Command iex(...)"
# was re-parsed by a PowerShell DefaultShell, corrupting $-bearing payloads.
[[ ${ARGV[-1]} =~ ^powershell\ -NoProfile\ -ExecutionPolicy\ Bypass\ -EncodedCommand\ [A-Za-z0-9+/=]+$ ]]
check 'ps streaming bootstrap contains only shell-inert characters' $?

RRUN_STREAM_LIMIT=10 "$RRUN" h1,h2 -c 'Get-Date' 2>"$work/err"; rc=$?
[[ $rc == 2 ]] && grep -q 'use -J' "$work/err"
check 'oversized ps payload on nested hops fails fast, advises -J' $?

echo '[validation]'
"$RRUN" -s bash 'h1;rm -rf /' -c x 2>/dev/null; [[ $? == 2 ]]
check 'metacharacter host token rejected' $?
"$RRUN" -- -oProxyCommand=evil -c x 2>/dev/null; [[ $? == 2 ]]
check 'option-shaped host token (leading -) rejected' $?
"$RRUN" -s bash 'h1,-V' -c x 2>/dev/null; [[ $? == 2 ]]
check 'option-shaped intermediate hop rejected' $?
out=$("$RRUN" -n -J 'jump;evil' examplehost -c x)
[[ $out == *'jump\;evil'* ]]
check 'dry-run %q-quotes metachar -J argument (paste-safe)' $?
"$RRUN" -s zsh examplehost -c x 2>/dev/null; [[ $? == 2 ]]
check 'unknown -s rejected' $?
"$RRUN" -s 2>/dev/null; [[ $? == 2 ]]
check 'missing option argument rejected' $?
"$RRUN" examplehost -c 2>/dev/null; [[ $? != 0 ]]
check 'missing -c string rejected' $?

echo
if [[ $fail == 0 ]]; then echo 'ALL PASS'; else echo "$fail FAILURE(S)"; fi
exit "$fail"
