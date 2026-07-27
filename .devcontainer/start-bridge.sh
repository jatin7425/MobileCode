#!/usr/bin/env bash
#
# Brings the MobileCode SSH bridge up automatically when a Codespace starts.
#
# Runs from devcontainer.json's postStartCommand, so there is nothing to run by
# hand. It authorises the public key from the MOBILECODE_PUBLIC_KEY Codespaces
# secret, which is why the app only ever shows you a *public* key: the private
# half stays in the phone's keychain and never travels.
#
# No secret set means no key to authorise, and the script exits quietly rather
# than standing up an sshd nobody can log into.

set -euo pipefail

if [ -z "${MOBILECODE_PUBLIC_KEY:-}" ]; then
  echo "MOBILECODE_PUBLIC_KEY is not set; skipping the MobileCode bridge."
  echo "Generate a key in the app's Settings, then add its public half as a"
  echo "Codespaces secret named MOBILECODE_PUBLIC_KEY at:"
  echo "  https://github.com/settings/codespaces"
  exit 0
fi

exec "$(dirname "$0")/../tools/codespace-bridge.sh" "$MOBILECODE_PUBLIC_KEY"
