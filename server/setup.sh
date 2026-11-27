#!/usr/bin/env bash
# One-time setup for the HomeDrive server. Run from the server/ folder:
#   ./setup.sh
set -euo pipefail
cd "$(dirname "$0")"

if [ -f .env ]; then
  echo ".env already exists. Starting/updating HomeDrive..."
else
  read -rp "HomeDrive username [max]: " HD_USER
  HD_USER=${HD_USER:-max}
  read -rsp "HomeDrive password: " HD_PASS; echo
  [ -n "$HD_PASS" ] || { echo "Password can't be empty."; exit 1; }

  read -rp "Folder to serve [$HOME/drive]: " FILES_DIR
  FILES_DIR=${FILES_DIR:-$HOME/drive}
  mkdir -p "$FILES_DIR"

  BIND_IP=$(tailscale ip -4 2>/dev/null | head -1 || true)
  if [ -z "$BIND_IP" ]; then
    echo "Couldn't find a Tailscale IP. Is Tailscale running?"; exit 1
  fi

  umask 077
  cat > .env <<EOF
HOMEDRIVE_USERNAME=$HD_USER
HOMEDRIVE_PASSWORD=$HD_PASS
FILES_DIR=$FILES_DIR
BIND_IP=$BIND_IP
PUID=$(id -u)
PGID=$(id -g)
EOF
  echo "Saved settings to .env"
fi

mkdir -p data
docker compose --env-file .env up -d --build
IP=$(grep '^BIND_IP=' .env | cut -d= -f2)
echo
echo "HomeDrive is running at http://$IP:8090"
echo "Check it with: curl http://$IP:8090/api/health"
