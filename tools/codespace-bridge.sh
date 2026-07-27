#!/usr/bin/env bash
#
# Makes a Codespace reachable from the MobileCode app.
#
# A Codespace has no public SSH endpoint — `gh codespace ssh` reaches it by
# tunnelling through GitHub's Dev Tunnels service, which a phone cannot do.
# What a Codespace *can* do is forward a port as an HTTPS URL that accepts a
# WebSocket upgrade. So we run sshd on loopback and put a WebSocket-to-TCP
# bridge in front of it, then forward the bridge's port.
#
# Run this inside the Codespace, once per Codespace:
#
#   ./tools/codespace-bridge.sh "$(cat ~/.ssh/id_ed25519.pub)"
#
# where the key is the *public* half of the key pair you added to the app.

set -euo pipefail

PUBLIC_KEY="${1:-}"
BRIDGE_PORT="${MOBILECODE_BRIDGE_PORT:-2222}"
SSHD_PORT="${MOBILECODE_SSHD_PORT:-2223}"
STATE_DIR="$HOME/.mobilecode"

GENERATED_KEY=""
if [ -z "$PUBLIC_KEY" ]; then
  # No key supplied: mint one dedicated to this app. Better than reusing an
  # existing key, because revoking it is just removing a line from
  # authorized_keys and it grants nothing anywhere else.
  echo "==> No key given; generating one for MobileCode"
  mkdir -p "$STATE_DIR"
  if [ ! -f "$STATE_DIR/id_ed25519" ]; then
    ssh-keygen -q -t ed25519 -N '' -C 'mobilecode' -f "$STATE_DIR/id_ed25519"
  fi
  PUBLIC_KEY="$(cat "$STATE_DIR/id_ed25519.pub")"
  GENERATED_KEY="$STATE_DIR/id_ed25519"
fi

echo "==> Installing sshd and websocat"
if ! command -v sshd >/dev/null 2>&1 && ! [ -x /usr/sbin/sshd ]; then
  sudo apt-get update -qq
  sudo apt-get install -y -qq openssh-server
fi

if ! command -v websocat >/dev/null 2>&1; then
  sudo curl -fsSL -o /usr/local/bin/websocat \
    https://github.com/vi/websocat/releases/latest/download/websocat.x86_64-unknown-linux-musl
  sudo chmod +x /usr/local/bin/websocat
fi

echo "==> Authorising your key"
mkdir -p "$HOME/.ssh"
touch "$HOME/.ssh/authorized_keys"
chmod 700 "$HOME/.ssh"
chmod 600 "$HOME/.ssh/authorized_keys"
if ! grep -qxF "$PUBLIC_KEY" "$HOME/.ssh/authorized_keys"; then
  echo "$PUBLIC_KEY" >>"$HOME/.ssh/authorized_keys"
fi

echo "==> Configuring sshd on loopback:$SSHD_PORT"
mkdir -p "$STATE_DIR"
if [ ! -f "$STATE_DIR/host_ed25519" ]; then
  ssh-keygen -q -t ed25519 -N '' -f "$STATE_DIR/host_ed25519"
fi

cat >"$STATE_DIR/sshd_config" <<EOF
Port $SSHD_PORT
# Loopback only. The bridge is the sole way in, so sshd is never exposed
# directly even though the forwarded port is public.
ListenAddress 127.0.0.1
HostKey $STATE_DIR/host_ed25519
AuthorizedKeysFile $HOME/.ssh/authorized_keys
PidFile $STATE_DIR/sshd.pid
UsePAM no
# Keys only. The forwarded port is reachable by anyone who learns the URL,
# so a guessable password must not be an option.
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
StrictModes no
PermitUserEnvironment no
EOF

sudo mkdir -p /run/sshd
pkill -F "$STATE_DIR/sshd.pid" 2>/dev/null || true
sudo "$(command -v sshd || echo /usr/sbin/sshd)" -f "$STATE_DIR/sshd_config"

echo "==> Starting WebSocket bridge on :$BRIDGE_PORT"
pkill -f 'websocat .*ws-l' 2>/dev/null || true
nohup websocat --binary \
  "ws-l:0.0.0.0:$BRIDGE_PORT" \
  "tcp:127.0.0.1:$SSHD_PORT" \
  >"$STATE_DIR/websocat.log" 2>&1 &

sleep 1

if [ -n "${CODESPACE_NAME:-}" ] && command -v gh >/dev/null 2>&1; then
  echo "==> Making port $BRIDGE_PORT public"
  gh codespace ports visibility "$BRIDGE_PORT:public" -c "$CODESPACE_NAME"
else
  echo
  echo "Could not set port visibility automatically. In the Ports panel, set"
  echo "port $BRIDGE_PORT to Public."
fi

echo
echo "======================================================================"
echo "In the app, Settings:"
echo
echo "  Username inside the Codespace:  $(whoami)"
echo

if [ -n "$GENERATED_KEY" ]; then
  echo "  Private key — copy everything between the BEGIN and END lines:"
  echo
  cat "$GENERATED_KEY"
  echo
  echo "  This key is authorised only on this Codespace. Remove its line from"
  echo "  ~/.ssh/authorized_keys to revoke it."
else
  echo "  Private key: the half matching the public key you passed in."
fi

echo "======================================================================"
echo
echo "Note: a public forwarded port is reachable by anyone who learns its URL."
echo "sshd here accepts keys only, so your key is what keeps it shut."
