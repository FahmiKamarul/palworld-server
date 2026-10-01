#!/usr/bin/env bash
# Put an existing world (co-op/local save, or a save from another server) onto this server.
#
#   ./scripts/import-save.sh <world.zip | world-folder>
#
# The zip/folder must contain the world folder (the 32-character ID folder holding Level.sav).
# What it does: stops the server, backs up current saves, copies the world in, renames
# WorldOption.sav (it overrides your server settings), points the server at this world,
# fixes permissions, starts the server.
set -euo pipefail
cd "$(dirname "$0")/.."

SRC="${1:-}"
if [ -z "$SRC" ] || [ ! -e "$SRC" ]; then
  echo "Usage: $0 <world.zip | world-folder>"
  exit 1
fi

SAVES=palworld/Pal/Saved/SaveGames/0
GUS=palworld/Pal/Saved/Config/LinuxServer/GameUserSettings.ini
STAMP=$(date +%Y-%m-%d_%H-%M-%S)

TMP=""
if [[ "$SRC" == *.zip ]]; then
  command -v unzip >/dev/null || sudo apt-get install -y unzip
  TMP=$(mktemp -d)
  trap 'rm -rf "$TMP"' EXIT
  unzip -q "$SRC" -d "$TMP"
  SRC="$TMP"
fi

LEVEL=$(find "$SRC" -maxdepth 3 -name Level.sav | head -n 1)
if [ -z "$LEVEL" ]; then
  echo "!! No Level.sav found in $1 — is this a Palworld world folder?"
  exit 1
fi
WORLD_DIR=$(dirname "$LEVEL")
WORLD_ID=$(basename "$WORLD_DIR")
if ! [[ "$WORLD_ID" =~ ^[0-9A-Fa-f]{32}$ ]]; then
  echo "!! Folder containing Level.sav is '$WORLD_ID', expected a 32-character world ID."
  echo "   Zip the world ID folder itself (the one with Level.sav and Players/ inside)."
  exit 1
fi
echo ">> Importing world $WORLD_ID"

echo ">> Stopping server..."
sudo docker compose down

sudo mkdir -p "$SAVES" palworld/backups
if [ -n "$(sudo ls -A "$SAVES")" ]; then
  echo ">> Backing up current saves to palworld/backups/pre-import-$STAMP.tar.gz"
  sudo tar -czf "palworld/backups/pre-import-$STAMP.tar.gz" -C "$SAVES" .
fi
if sudo test -d "$SAVES/$WORLD_ID"; then
  sudo mv "$SAVES/$WORLD_ID" "$SAVES/$WORLD_ID.old-$STAMP"
fi
sudo cp -a "$WORLD_DIR" "$SAVES/$WORLD_ID"

if sudo test -f "$SAVES/$WORLD_ID/WorldOption.sav"; then
  echo ">> Renaming WorldOption.sav -> WorldOption.sav.bak (it would override compose.yaml settings)"
  sudo mv "$SAVES/$WORLD_ID/WorldOption.sav" "$SAVES/$WORLD_ID/WorldOption.sav.bak"
fi

echo ">> Pointing the server at this world (DedicatedServerName=$WORLD_ID)"
if sudo test -f "$GUS"; then
  if sudo grep -q '^DedicatedServerName=' "$GUS"; then
    sudo sed -i "s/^DedicatedServerName=.*/DedicatedServerName=$WORLD_ID/" "$GUS"
  else
    sudo sed -i "/^\[\/Script\/Pal.PalGameLocalSettings\]/a DedicatedServerName=$WORLD_ID" "$GUS"
  fi
else
  sudo mkdir -p "$(dirname "$GUS")"
  printf '[/Script/Pal.PalGameLocalSettings]\nDedicatedServerName=%s\n' "$WORLD_ID" | sudo tee "$GUS" >/dev/null
fi
sed -i "s/WORLD_NAME=.*/WORLD_NAME=$WORLD_ID/" compose.yaml

sudo chown -R 1000:1000 palworld
echo ">> Starting server..."
sudo docker compose up -d

cat <<EOF

Done. World $WORLD_ID is live.
If this world came from a CO-OP / local game, the host's character is still stored under the
co-op ID 00000000000000000000000000000001 and must be migrated — follow
"Moving a co-op / local world online (host fix)" in README.md (scripts/fix-host-save.sh).
EOF
