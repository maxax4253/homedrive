#!/usr/bin/env bash
# HomeDrive server installer. On the Linux machine that will hold your files, run:
#
#   curl -fsSL https://raw.githubusercontent.com/maxax4253/homedrive/main/install.sh | bash
#
# It installs Docker and Tailscale if needed, downloads HomeDrive, asks for a
# username/password, and starts the server. Safe to run again to repair or update.
#
# Unattended installs (used by the automatic tests on fresh machines):
#   HOMEDRIVE_UNATTENDED=1 HD_PASSWORD=... [HD_USER=max HD_FILES_DIR=~/drive HD_BIND_IP=...]
#   HOMEDRIVE_SKIP_TAILSCALE=1   don't install/connect Tailscale (then HD_BIND_IP is required)
#   HOMEDRIVE_REPO / HOMEDRIVE_REF   install from another copy or commit
set -euo pipefail

REPO="${HOMEDRIVE_REPO:-https://github.com/maxax4253/homedrive.git}"
DIR="${HOMEDRIVE_DIR:-$HOME/homedrive}"
UNATTENDED="${HOMEDRIVE_UNATTENDED:-0}"

say()  { printf '\n\033[1;34m==>\033[0m %s\n' "$*"; }
fail() { printf '\n\033[1;31mError:\033[0m %s\n' "$*" >&2; exit 1; }

[ "$(uname -s)" = "Linux" ] || fail "Run this on the Linux server, not on your Mac."
[ "$(id -u)" -ne 0 ] || fail "Run this as your normal user (not root). It uses sudo when it needs to."
command -v apt-get >/dev/null || fail "This installer supports Debian, Ubuntu and Linux Mint for now."
if [ "$UNATTENDED" != "1" ]; then
  [ -r /dev/tty ] || fail "Run this from an interactive terminal (it needs to ask you a few questions)."
fi

say "Checking for git and curl"
missing=()
command -v git  >/dev/null || missing+=(git)
command -v curl >/dev/null || missing+=(curl)
if [ ${#missing[@]} -gt 0 ]; then
  sudo apt-get update -qq
  sudo apt-get install -y "${missing[@]}"
fi

say "Checking for Docker"
if ! command -v docker >/dev/null; then
  # Use the distro's own Docker package. Docker's get.docker.com script picks the
  # wrong repository on Linux Mint, so we avoid it.
  sudo apt-get update -qq
  sudo apt-get install -y docker.io
fi
if ! docker compose version >/dev/null 2>&1 && ! sudo docker compose version >/dev/null 2>&1; then
  sudo apt-get install -y docker-compose-v2 2>/dev/null \
    || sudo apt-get install -y docker-compose-plugin 2>/dev/null \
    || sudo apt-get install -y docker-compose \
    || fail "Couldn't install Docker Compose."
fi
sudo systemctl enable --now docker >/dev/null 2>&1 || true
if ! id -nG "$USER" | grep -qw docker; then
  sudo usermod -aG docker "$USER"
  echo "Added $USER to the docker group (takes effect next time you log in)."
fi

if [ "${HOMEDRIVE_SKIP_TAILSCALE:-0}" = "1" ]; then
  say "Skipping Tailscale (HOMEDRIVE_SKIP_TAILSCALE=1)"
else
  say "Checking for Tailscale"
  if ! command -v tailscale >/dev/null; then
    curl -fsSL https://tailscale.com/install.sh | sh
  fi
  if [ -z "$(tailscale ip -4 2>/dev/null | head -1)" ]; then
    [ "$UNATTENDED" != "1" ] || fail "Tailscale isn't connected (connect it first, or set HD_BIND_IP)."
    echo "Tailscale isn't connected yet. Follow the link below to sign in:"
    sudo tailscale up < /dev/tty
  fi
fi

say "Downloading HomeDrive to $DIR"
if [ -d "$DIR/.git" ]; then
  git -C "$DIR" pull --ff-only
else
  git clone "$REPO" "$DIR"
fi
if [ -n "${HOMEDRIVE_REF:-}" ]; then
  git -C "$DIR" checkout -q "$HOMEDRIVE_REF"
fi

say "Installing the 'homedrive' command"
sudo install -m 755 "$DIR/homedrive" /usr/local/bin/homedrive

say "Setting up the server"
if [ "$UNATTENDED" = "1" ]; then
  "$DIR/server/setup.sh"
else
  "$DIR/server/setup.sh" < /dev/tty
fi

say "Installing the app helper (lets the Mac app turn share links on/off)"
sudo HOMEDRIVE_DIR="$DIR" /usr/local/bin/homedrive install-agent

cat <<EOF

HomeDrive is installed.

  Manage it with:   homedrive status | update | logs | restart | stop
  On your Mac run:  curl -fsSL https://raw.githubusercontent.com/maxax4253/homedrive/main/install-mac.sh | bash

EOF
