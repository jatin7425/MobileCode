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

# All arguments joined, not just $1: an ssh public key contains spaces, and
# pasting one unquoted is the obvious thing to do. Taking $1 alone silently
# authorised the string "ssh-ed25519" and left the user with a bridge that
# rejected them for no visible reason.
PUBLIC_KEY="${*:-}"
# Not 2222: Codespaces runs its own sshd there — the one `gh codespace ssh`
# uses — so that port is never free and websocat dies with "Address in use".
BRIDGE_PORT="${MOBILECODE_BRIDGE_PORT:-2224}"
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

case "$PUBLIC_KEY" in
  ssh-ed25519\ *|ssh-rsa\ *|ecdsa-sha2-*\ *) ;;
  *)
    echo "That does not look like an SSH public key:" >&2
    echo "  $PUBLIC_KEY" >&2
    echo >&2
    echo "Expected something starting 'ssh-ed25519 AAAA…'. If you pasted a" >&2
    echo "private key or a file path, use the public half instead." >&2
    exit 1
    ;;
esac

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

# sudo starts sshd, so its pidfile is root-owned and an unprivileged pkill
# cannot signal it. A survivor keeps the port and the new instance dies
# silently — leaving an sshd running with whatever config it started with.
sudo pkill -F "$STATE_DIR/sshd.pid" 2>/dev/null || true
sudo pkill -f "sshd_config" 2>/dev/null || true
sleep 1

SSHD_BIN="$(command -v sshd || echo /usr/sbin/sshd)"

# -t validates the config before we try to run it, so a bad directive is
# reported here rather than as an unexplained "Permission denied" later.
if ! sudo "$SSHD_BIN" -t -f "$STATE_DIR/sshd_config"; then
  echo "sshd rejected its configuration; see above." >&2
  exit 1
fi

sudo "$SSHD_BIN" -f "$STATE_DIR/sshd_config"
sleep 1

if ! (command -v ss >/dev/null 2>&1 && ss -ltn 2>/dev/null | grep -q "127.0.0.1:$SSHD_PORT "); then
  echo "sshd is not listening on 127.0.0.1:$SSHD_PORT." >&2
  exit 1
fi

echo "==> Starting WebSocket bridge on :$BRIDGE_PORT"

# Clear any previous bridge, including one started as root. A survivor holds
# the port, the new websocat dies with "Address in use", and the port stays
# listening — so the failure then looks like a GitHub problem rather than a
# stale process.
pkill -f 'websocat .*ws-l' 2>/dev/null || true
sudo pkill -f 'websocat .*ws-l' 2>/dev/null || true
sleep 1

if (command -v ss >/dev/null 2>&1 && ss -ltn 2>/dev/null | grep -q ":$BRIDGE_PORT "); then
  echo >&2
  echo "Port $BRIDGE_PORT is already held by something that is not our" >&2
  echo "bridge. Identify and stop it, then run this again:" >&2
  echo >&2
  echo "  sudo ss -ltnp | grep $BRIDGE_PORT" >&2
  exit 1
fi

nohup websocat --binary \
  "ws-l:0.0.0.0:$BRIDGE_PORT" \
  "tcp:127.0.0.1:$SSHD_PORT" \
  >"$STATE_DIR/websocat.log" 2>&1 &
bridge_pid=$!

# Check that *our* websocat is alive, not merely that the port is bound.
# Checking the port alone passes on someone else's socket — which is exactly
# how a dead bridge behind a squatted port reported success.
sleep 2
if ! kill -0 "$bridge_pid" 2>/dev/null; then
  echo >&2
  echo "The bridge exited immediately. websocat log:" >&2
  tail -20 "$STATE_DIR/websocat.log" >&2 2>/dev/null || true
  exit 1
fi

if [ -n "${CODESPACE_NAME:-}" ] && command -v gh >/dev/null 2>&1; then
  # GitHub forwards a port when it notices something listening, and that scan
  # is not instant. Setting visibility before the port is registered fails
  # with a 404 — the tunnel genuinely does not know the port yet — so retry
  # rather than treat the first failure as final.
  echo "==> Making port $BRIDGE_PORT public (waiting for GitHub to see it)"
  published=""
  for _ in $(seq 1 20); do
    if gh codespace ports visibility "$BRIDGE_PORT:public" \
         -c "$CODESPACE_NAME" >/dev/null 2>&1; then
      published=yes
      break
    fi
    sleep 3
  done

  if [ -n "$published" ]; then
    echo "    port $BRIDGE_PORT is public"
  else
    echo
    echo "    Could not set it automatically after 60s. Open the PORTS panel,"
    echo "    right-click port $BRIDGE_PORT, and set Port Visibility to Public."
  fi
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
