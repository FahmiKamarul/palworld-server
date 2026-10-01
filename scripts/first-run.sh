#!/usr/bin/env bash
# First-time setup on a fresh Ubuntu/Debian VM:
#   installs Docker + Compose, creates .env, opens the data folder to the container, starts the server.
# Safe to run again — every step skips itself if already done.
set -euo pipefail
cd "$(dirname "$0")/.."

if ! command -v docker >/dev/null 2>&1; then
  echo ">> Installing Docker..."
  curl -fsSL https://get.docker.com | sudo sh
  sudo usermod -aG docker "$USER"
fi
if ! sudo docker compose version >/dev/null 2>&1; then
  echo ">> Installing Docker Compose plugin..."
  sudo apt-get update && sudo apt-get install -y docker-compose-plugin
fi

if [ ! -f .env ]; then
  cp .env.example .env
  chmod 600 .env
  echo ">> Created .env — set ADMIN_PASSWORD (and DISCORD_WEBHOOK_URL if you want Discord), then run:"
  echo "     nano .env && ./scripts/first-run.sh"
  exit 0
fi
if grep -q '^ADMIN_PASSWORD=change-me$' .env; then
  echo "!! ADMIN_PASSWORD in .env is still 'change-me'. Edit it first: nano .env"
  exit 1
fi

# The container runs as UID/GID 1000 (PUID/PGID in compose.yaml) and must own its data folder.
mkdir -p palworld
sudo chown -R 1000:1000 palworld

sudo docker compose up -d
echo
echo ">> Server is starting. The first boot downloads the game server (a few minutes)."
echo "   Watch it:   sudo docker compose logs -f      (Ctrl+C to stop watching)"
echo "   Ready when 'sudo docker ps' shows (healthy) — about 3 minutes on first boot."
