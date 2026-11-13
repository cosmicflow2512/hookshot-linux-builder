#!/usr/bin/env bash
set -euo pipefail
CONFIG_DIR=${CONFIG_DIR:-/config}
mkdir -p "$CONFIG_DIR/logs" "$CONFIG_DIR/ssh" "$CONFIG_DIR/home"
chmod 700 "$CONFIG_DIR/ssh"
# Schluessel fuer das Deploy per rsync/SSH: einmal erzeugt, der oeffentliche Teil steht im Log und in der Web-UI.
if [[ ! -f $CONFIG_DIR/ssh/id_ed25519 ]]; then
    ssh-keygen -q -t ed25519 -N '' -C hookshot-linux-builder -f "$CONFIG_DIR/ssh/id_ed25519"
fi
echo "SSH-Schluessel fuer das Deploy: $(cat "$CONFIG_DIR/ssh/id_ed25519.pub")"
exec python3 -u /app/webui/app.py
