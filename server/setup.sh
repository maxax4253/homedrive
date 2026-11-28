#!/usr/bin/env bash
# One-time setup for the HomeDrive server (install.sh runs this for you).
# Run from anywhere:  ~/homedrive/server/setup.sh
set -euo pipefail
cd "$(dirname "$0")"

# Questions come from the terminal even when this is run from a piped installer.
ask() { read -r "$@" < /dev/tty; }

if [ -f .env ]; then
  echo ".env already exists. Starting/updating HomeDrive..."
else
  ask -p "HomeDrive username [max]: " HD_USER
  HD_USER=${HD_USER:-max}
  while true; do
    ask -sp "HomeDrive password: " HD_PASS; echo
    [ -n "$HD_PASS" ] || { echo "Password can't be empty."; continue; }
    if [ "${#HD_PASS}" -lt 8 ]; then
      echo "That's short and easy to guess. 8+ characters is strongly recommended."
      ok=""; ask -p "Use it anyway? [y/N] " ok
      case "$ok" in y|Y|yes) ;; *) continue ;; esac
    fi
    case "$HD_PASS" in *"'"*) echo "Please don't use a ' (single quote)."; continue ;; esac
    break
  done

  ask -p "Folder to keep your files in [$HOME/drive]: " FILES_DIR
  FILES_DIR=${FILES_DIR:-$HOME/drive}
  mkdir -p "$FILES_DIR"

  BIND_IP=$(tailscale ip -4 2>/dev/null | head -1 || true)
  if [ -z "$BIND_IP" ]; then
    echo "Couldn't find a Tailscale IP. Is Tailscale running? (sudo tailscale up)"; exit 1
  fi

  (umask 077
   cat > .env <<ENV
HOMEDRIVE_USERNAME='$HD_USER'
HOMEDRIVE_PASSWORD='$HD_PASS'
FILES_DIR=$FILES_DIR
BIND_IP=$BIND_IP
PUID=$(id -u)
PGID=$(id -g)
ENV
  )
  echo "Saved settings to .env"
fi

mkdir -p data/links
DOCKER="docker"
docker info >/dev/null 2>&1 || DOCKER="sudo docker"
PROFILE=()
grep -q "^LINKS='\?1" .env && PROFILE=(--profile links)
$DOCKER compose --env-file .env "${PROFILE[@]}" up -d --build
IP=$(grep '^BIND_IP=' .env | cut -d= -f2 | tr -d "'")
echo
echo "HomeDrive is running at http://$IP:8090"
echo "Check it with: curl http://$IP:8090/api/health"
