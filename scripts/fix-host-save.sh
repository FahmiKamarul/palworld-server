#!/usr/bin/env bash
# Co-op/local -> dedicated server "host fix".
# In a co-op/local game the host's character is saved under the special ID
# 00000000000000000000000000000001. A dedicated server gives every player a real ID,
# so after moving the world online the host spawns as a brand-new character.
# This remaps the old host character (level, Pals, items, guild, Pal storage) onto the
# host's new server ID, using NFZ-441's Palworld-Co-op-to-Dedicated-Server-Migration-Tool.
#
#   ./scripts/fix-host-save.sh list                    # show player IDs, newest first
#   ./scripts/fix-host-save.sh <NEW_ID> [OLD_ID]       # OLD_ID defaults to the co-op host ID
#
# See README.md "Moving a co-op / local world online (host fix)" for the full procedure.
set -euo pipefail
cd "$(dirname "$0")/.."

TOOL=migration-tool
TOOL_REPO=https://github.com/NFZ-441/Palworld-Co-op-to-Dedicated-Server-Migration-Tool.git
TOOL_COMMIT=b221d35c08a4f5c929c14313e2108093781a5ee6   # version tested on this server
PST_REPO=https://github.com/deafdudecomputers/PalworldSaveTools.git
PST_COMMIT=1007cc2737d52b84ed4438198c37bba368f10ba4    # version tested on this server
COOP_HOST=00000000000000000000000000000001

SAVES=palworld/Pal/Saved/SaveGames/0
GUS=palworld/Pal/Saved/Config/LinuxServer/GameUserSettings.ini

WORLD_ID=$(sudo grep -oP '^DedicatedServerName=\K[0-9A-Fa-f]{32}' "$GUS" 2>/dev/null || true)
if [ -z "$WORLD_ID" ]; then
  echo "!! Could not read DedicatedServerName from $GUS — import a world first (scripts/import-save.sh)."
  exit 1
fi
WORLD="$SAVES/$WORLD_ID"
PLAYERS="$WORLD/Players"

list_players() {
  echo "Player saves in world $WORLD_ID (newest first):"
  sudo find "$PLAYERS" -maxdepth 1 -name '*.sav' ! -name '*_dps.sav' -printf '  %TY-%Tm-%Td %TH:%TM  %f\n' \
    | sort -r | sed "s/  $COOP_HOST.sav/  $COOP_HOST.sav   <- co-op host (old character)/"
  echo
  echo "The newest file that appeared after the host joined with a throwaway character is the NEW_ID"
  echo "(file name without .sav)."
}

setup_tool() {
  if [ ! -d "$TOOL/.git" ]; then
    git clone -q "$TOOL_REPO" "$TOOL"
    git -C "$TOOL" checkout -q "$TOOL_COMMIT"
  fi
  if [ ! -d "$TOOL/PalworldSaveTools/.git" ]; then
    git clone -q "$PST_REPO" "$TOOL/PalworldSaveTools"
    git -C "$TOOL/PalworldSaveTools" checkout -q "$PST_COMMIT"
  fi
  if [ ! -x "$TOOL/.venv/bin/python" ]; then
    echo ">> Installing Python build tools..."
    sudo apt-get update -qq && sudo apt-get install -y -qq python3-venv python3-dev build-essential git
    python3 -m venv "$TOOL/.venv"
  fi
  if ! "$TOOL/.venv/bin/python" -c 'import ooz' 2>/dev/null; then
    echo ">> Installing pyooz (Oodle decompression for PlM saves)..."
    "$TOOL/.venv/bin/pip" install -q --upgrade pip
    "$TOOL/.venv/bin/pip" install -q git+https://github.com/oMaN-Rod/pyooz.git
  fi
}

if [ "${1:-}" = "list" ]; then
  list_players
  exit 0
fi

NEW_ID=$(echo "${1:-}" | tr 'a-f' 'A-F')
OLD_ID=$(echo "${2:-$COOP_HOST}" | tr 'a-f' 'A-F')
for id in "$NEW_ID" "$OLD_ID"; do
  if ! [[ "$id" =~ ^[0-9A-F]{32}$ ]]; then
    echo "Usage: $0 list | $0 <NEW_ID> [OLD_ID]   (IDs are 32 hex characters)"
    exit 1
  fi
done
for id in "$NEW_ID" "$OLD_ID"; do
  if ! sudo test -f "$PLAYERS/$id.sav"; then
    echo "!! $PLAYERS/$id.sav not found."
    echo "   NEW_ID only exists after the host joins once with a throwaway character. Current players:"
    list_players
    exit 1
  fi
done

setup_tool

STAMP=$(date +%Y-%m-%d_%H-%M-%S)
echo ">> Stopping server..."
sudo docker compose down

# Same format as the container's own backups, so `restore` can use it.
BACKUP="palworld/backups/palworld-save-${STAMP}_before-hostfix.tar.gz"
echo ">> Backing up saves to $BACKUP"
sudo mkdir -p palworld/backups
sudo tar -czf "$BACKUP" -C palworld/Pal --exclude backup Saved/

# The tool runs as you, so take ownership while it works, then give it back to the container.
sudo chown -R "$(id -u):$(id -g)" "$WORLD"
trap 'sudo chown -R 1000:1000 palworld' EXIT

echo ">> Moving character $OLD_ID -> $NEW_ID (with guild fix)..."
if ! "$TOOL/.venv/bin/python" "$TOOL/fix_host_save.py" "$WORLD" "$NEW_ID" "$OLD_ID" --guild-fix; then
  echo
  echo "!! Fix failed. Server left STOPPED. To undo any partial changes:"
  echo "   sudo rm -rf palworld/Pal/Saved && sudo tar -xzf $BACKUP -C palworld/Pal"
  echo "   sudo chown -R 1000:1000 palworld && sudo docker compose up -d"
  exit 1
fi

sudo chown -R 1000:1000 palworld
echo ">> Starting server..."
sudo docker compose up -d
echo
echo "Done. The host can join now and should have their old character back."
echo "If their Pals won't follow/fight: drop each Pal from the party and pick it up again."
