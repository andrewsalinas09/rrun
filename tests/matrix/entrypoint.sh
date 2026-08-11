#!/bin/sh
# Shared entrypoint for every matrix node image. Env-driven so one image can
# serve many matrix cells:
#   /keys (ro mount)  : id_ed25519 / authorized_keys COPIED into place -- a
#                       bind mount cannot carry the 0600 perms sshd/dropbear
#                       StrictModes demand (drvfs mounts arrive world-writable
#                       and pubkey auth would be silently refused)
#   LOGIN_SHELL       : rewrite root's login shell (csh/fish/dash/pwsh cells)
#   SABOTAGE          : comma list of controlled breakage --
#                       stub-base64 (base64 present but broken),
#                       rm-mktemp / rm-bash (tool genuinely absent)
set -e
mkdir -p /root/.ssh
chmod 700 /root/.ssh
if [ -f /keys/authorized_keys ]; then
  install -m 600 /keys/authorized_keys /root/.ssh/authorized_keys
fi
if [ -f /keys/id_ed25519 ]; then
  install -m 600 /keys/id_ed25519 /root/.ssh/id_ed25519
fi
if [ -n "${LOGIN_SHELL:-}" ]; then
  sed -i 's#^\(root:.*:\)[^:]*$#\1'"$LOGIN_SHELL"'#' /etc/passwd
fi
if [ -n "${SABOTAGE:-}" ]; then
  for item in $(printf %s "$SABOTAGE" | tr ',' ' '); do
    case "$item" in
      stub-base64)
        printf '#!/bin/sh\necho "base64: broken" >&2\nexit 1\n' > /usr/local/bin/base64
        chmod +x /usr/local/bin/base64 ;;
      rm-mktemp)
        if m=$(command -v mktemp); then rm -f "$m"; fi ;;
      rm-bash)
        rm -f /bin/bash /usr/bin/bash ;;
      *) echo "entrypoint: unknown SABOTAGE item '$item'" >&2; exit 1 ;;
    esac
  done
fi
# alpine ships root LOCKED (`!` in shadow), and sshd refuses locked accounts
# even for pubkey auth; `*` = no password, not locked
sed -i 's/^root:!/root:*/' /etc/shadow 2>/dev/null || true
if command -v dropbear >/dev/null 2>&1; then
  exec dropbear -F -E -R -s
fi
exec /usr/sbin/sshd -D -e
