# Palworld Dedicated Server (Docker)

Everything needed to run a Palworld dedicated server on a Linux VM (tested on Google Cloud,
Ubuntu 22.04), using the [thijsvanloef/palworld-server-docker](https://github.com/thijsvanloef/palworld-server-docker) image.

- Daily backups and a daily restart (cron, built into the container)
- Discord messages when players join and leave
- Scripts to import an existing world and to **migrate a co-op / local host's character** to the server

```
.
├── compose.yaml            # the server: image, ports, all settings
├── .env.example            # secrets template -> copy to .env (never committed)
├── scripts/
│   ├── first-run.sh        # install Docker + start the server on a fresh VM
│   ├── import-save.sh      # put an existing world (zip or folder) onto the server
│   └── fix-host-save.sh    # co-op/local host -> dedicated server character fix
├── cron/crontab.example    # optional host cron jobs (e.g. upload backups to Google Drive)
└── palworld/               # created on first run: game files, saves, backups (not in git)
```

---

## 1. First run

### 1.1 Open the firewall (Google Cloud)

Players connect on **UDP 8211**. Run once, from Cloud Shell or anywhere `gcloud` is logged in:

```bash
gcloud compute firewall-rules create palworld \
  --allow=udp:8211,udp:27015 \
  --direction=INGRESS --source-ranges=0.0.0.0/0
```

Port 8212 (REST API) is published by Docker but should **not** be opened in the firewall
unless you need remote access to it — it is protected only by the admin password.

### 1.2 Install and start

On the VM. The repo is private, so log in to GitHub first (one time):

```bash
sudo apt-get update && sudo apt-get install -y gh   # Ubuntu 22.04+: if not found, see https://github.com/cli/cli/blob/trunk/docs/install_linux.md
gh auth login --hostname github.com --git-protocol https --web   # open the URL it shows, enter the code
```

Then:

```bash
git clone https://github.com/FahmiKamarul/palworld-server.git ~/palworld-docker
cd ~/palworld-docker
./scripts/first-run.sh      # installs Docker, creates .env, then stops and asks you to edit it
nano .env                   # set ADMIN_PASSWORD, and DISCORD_WEBHOOK_URL (optional)
./scripts/first-run.sh      # starts the server
sudo docker compose logs -f # watch the first boot (downloads the game, takes a few minutes)
```

Ready when `sudo docker ps` shows `(healthy)` for `palworld-server` (about 3 minutes on first boot).
Check it answers: `sudo docker exec palworld-server rest-cli info`.

Players connect to `<VM external IP>:8211`.

Fresh server with no world of your own? You're done — the server creates a new world.
Bringing a world from somewhere else? Continue with [section 3](#3-bringing-an-existing-world).

---

## 2. Everyday commands

Run from the repo folder (`cd ~/palworld-docker`).

| What | Command |
|---|---|
| Start / apply `compose.yaml` changes | `sudo docker compose up -d` |
| Stop | `sudo docker compose down` |
| Restart | `sudo docker compose restart` |
| Live logs | `sudo docker compose logs -f` |
| Who's online | `sudo docker exec palworld-server rest-cli players` |
| Server info (version, world ID) | `sudo docker exec palworld-server rest-cli info` |
| Broadcast a message | `sudo docker exec palworld-server rest-cli announce '{"message":"Restarting in 5 min"}'` |
| Save the world now | `sudo docker exec palworld-server rest-cli save` |
| Make a backup now | `sudo docker exec palworld-server backup` |
| Restore a backup (interactive) | `sudo docker exec -it palworld-server restore` |
| Status | `sudo docker ps` |

**Changing settings:** edit `compose.yaml` (all options:
[image docs](https://palworld-server-docker.loef.dev/getting-started/configuration/server-settings)),
then `sudo docker compose up -d`. The container writes them into `PalWorldSettings.ini` on every start —
don't edit that `.ini` by hand, it gets overwritten.

**Settings not taking effect?** If the world folder has a `WorldOption.sav`, it overrides
`PalWorldSettings.ini`. Rename it while the server is stopped:

```bash
sudo docker compose down
mv palworld/Pal/Saved/SaveGames/0/<WORLD_ID>/WorldOption.sav{,.bak}
sudo docker compose up -d
```

**Permissions:** the container runs as UID 1000. After changing anything under `palworld/` by hand:
`sudo chown -R 1000:1000 palworld`

---

## 3. Bringing an existing world

### 3.1 Import the world

Find the world folder — a 32-character ID folder containing `Level.sav` and `Players/`:

- **Co-op / local game (Windows):** `%LOCALAPPDATA%\Pal\Saved\SaveGames\<SteamID>\<WORLD_ID>`
- **Another dedicated server:** `Pal/Saved/SaveGames/0/<WORLD_ID>`

Zip that folder, get it onto the VM (e.g. browser SSH window → ⚙ → *Upload file*), then:

```bash
./scripts/import-save.sh ~/world_save.zip     # or a path to the world folder
```

This stops the server, backs up current saves to `palworld/backups/pre-import-*.tar.gz`, copies the world
in, renames `WorldOption.sav`, sets `DedicatedServerName` in `GameUserSettings.ini` (that is what decides
which world loads — if it doesn't match the folder name, the server silently creates a new world), fixes
permissions and starts the server.

Downloading the zip from Google Drive on the VM (file must be shared "Anyone with the link"):

```bash
wget -O ~/world_save.zip 'https://docs.google.com/uc?export=download&id=<FILE_ID>&confirm=t'
```

### 3.2 Moving a co-op / local world online (host fix)

**Why:** in co-op/local play the host's character is always saved as
`00000000000000000000000000000001`. A dedicated server gives every player a real ID, so after the move
**the host spawns as a brand-new character** (guests are fine — they already have real IDs). The fix
remaps the old host character — level, Pals, inventory, guild, Dimensional Pal Storage — onto the host's
new server ID. It uses
[NFZ-441/Palworld-Co-op-to-Dedicated-Server-Migration-Tool](https://github.com/NFZ-441/Palworld-Co-op-to-Dedicated-Server-Migration-Tool),
which supports the current PlM (Oodle) save format. The script downloads it (pinned to the version tested
here) into `migration-tool/` and installs its dependencies the first time.

**Steps:**

1. Import the world (3.1) and start the server.
2. A **guest** joins first and checks the world looks right (bases, Pals).
3. The **host** joins, creates a throwaway character, walks around a few seconds, leaves.
   This creates the host's new ID.
4. Find the new ID — the newest file:
   ```bash
   ./scripts/fix-host-save.sh list
   ```
   ```
     2026-07-30 11:02  B63A4013000000000000000000000000.sav   <- newest = the host's NEW_ID
     2026-07-29 22:45  00000000000000000000000000000001.sav   <- co-op host (old character)
   ```
5. Run the fix:
   ```bash
   ./scripts/fix-host-save.sh B63A4013000000000000000000000000
   ```
   It stops the server, backs up the world to `palworld/backups/pre-hostfix-*.tar.gz`, moves the old
   character onto the new ID (with `--guild-fix`), fixes permissions and starts the server.
6. The host joins — old character, Pals and guild are back.

**Afterwards**

- Pals won't follow/fight: drop each from the party and pick it up again.
- Dimensional Pal Storage stuck on "retrieving": the `_dps.sav` is from an older game version. Load the
  co-op world once in single-player on the host's PC (the game converts it), copy
  `Players/00000000000000000000000000000001_dps.sav` from there into the server's `Players/` as
  `<NEW_ID>_dps.sav`, re-run step 5, then build a new Dimensional Pal Storage box.
- Map discovery is stored per player on their own PC: in
  `%LOCALAPPDATA%\Pal\Saved\SaveGames\<SteamID>\`, copy `LocalData.sav` from the old world folder into the
  new server world folder (after connecting to the server once, game closed).
- Something went wrong: the script prints the exact restore command; backups are in `palworld/backups/`.

**Other ID swaps:** to move any character from one ID to another (e.g. a player changed Steam account):
`./scripts/fix-host-save.sh <NEW_ID> <OLD_ID>`.

---

## 4. Cron jobs

### Inside the container (configured in `compose.yaml`)

The image runs its own scheduler — nothing to install on the VM. Times are UTC (container clock).

| Setting | This server | Meaning |
|---|---|---|
| `BACKUP_ENABLED` | `true` | Backup to `palworld/backups/` |
| `BACKUP_CRON_EXPRESSION` | default `0 0 * * *` | When to back up (daily 00:00) |
| `DELETE_OLD_BACKUPS` / `OLD_BACKUP_DAYS` | not set | Add `DELETE_OLD_BACKUPS=true` and `OLD_BACKUP_DAYS=30` to auto-delete old backups |
| `AUTO_REBOOT_ENABLED` | `true` | Scheduled restart (keeps memory usage down) |
| `AUTO_REBOOT_CRON_EXPRESSION` | `0 20 * * *` | Daily 20:00 UTC (04:00 Malaysia time) |
| `AUTO_REBOOT_WARN_MINUTES` | `5` | In-game warning before restart |
| `AUTO_REBOOT_EVEN_IF_PLAYERS_ONLINE` | default `false` | Skip the restart if people are playing |
| `AUTO_UPDATE_ENABLED` / `AUTO_UPDATE_CRON_EXPRESSION` | not set | Update the game on a schedule (`UPDATE_ON_BOOT=true` already updates on every restart) |

Cron format: `minute hour day-of-month month day-of-week` — e.g. `0 */6 * * *` = every 6 hours.
Apply changes with `sudo docker compose up -d`. Check the active schedule:

```bash
sudo docker exec palworld-server cat /home/steam/server/crontab
```

### On the VM (optional)

Extra jobs outside the container go in your user crontab — see `cron/crontab.example`:

```bash
crontab -e     # paste lines from cron/crontab.example
crontab -l     # check
```

#### Upload backups to Google Drive

One-time setup with [rclone](https://rclone.org):

1. On the VM: `curl https://rclone.org/install.sh | sudo bash`
2. On your own PC (has a browser): install rclone, run `rclone authorize "drive"`, sign in, copy the token it prints.
3. On the VM (the folder ID is the last part of the Drive folder URL):
   ```bash
   rclone config create gdrive drive scope=drive root_folder_id=<DRIVE_FOLDER_ID> token='<TOKEN>'
   rclone copy ~/palworld-docker/palworld/backups gdrive: --max-age 24h   # test
   ```
4. Add the line from `cron/crontab.example` with `crontab -e` — uploads each night's backup at 00:30.

---

## 5. Discord

1. Discord → your channel → ⚙ Edit Channel → Integrations → Webhooks → New Webhook → **Copy Webhook URL**.
2. Put it in `.env`:
   ```
   DISCORD_WEBHOOK_URL=https://discord.com/api/webhooks/...
   ```
3. `sudo docker compose up -d`

Enabled in `compose.yaml`: player join and leave messages. Other messages you can turn on by adding to
`compose.yaml` (each `=true`):

| Variable | Message |
|---|---|
| `DISCORD_PRE_START_MESSAGE_ENABLED` | Server starting |
| `DISCORD_PRE_SHUTDOWN_MESSAGE_ENABLED` / `DISCORD_POST_SHUTDOWN_MESSAGE_ENABLED` | Shutting down / shut down |
| `DISCORD_PRE_UPDATE_BOOT_MESSAGE_ENABLED` / `DISCORD_POST_UPDATE_BOOT_MESSAGE_ENABLED` | Updating / updated |
| `DISCORD_PRE_BACKUP_MESSAGE_ENABLED` / `DISCORD_POST_BACKUP_MESSAGE_ENABLED` | Backup starting / done |

Custom text: e.g. `DISCORD_PLAYER_JOIN_MESSAGE=player_name joined!`. To send a message type to a different
channel, set `DISCORD_<TYPE>_URL` (e.g. `DISCORD_PLAYER_JOIN_MESSAGE_URL`). Leave `DISCORD_WEBHOOK_URL`
empty to turn Discord off.

**Keep the webhook URL secret** — anyone who has it can post in your channel. If it leaks, delete the
webhook in Discord and create a new one.

---

## Troubleshooting

| Problem | Fix |
|---|---|
| Server made a new, empty world | `DedicatedServerName` in `palworld/Pal/Saved/Config/LinuxServer/GameUserSettings.ini` doesn't match the world folder name — re-run `scripts/import-save.sh`, or fix it by hand with the server stopped |
| Settings in `compose.yaml` ignored | Rename the world's `WorldOption.sav` (section 2) |
| `Permission denied` / server can't save | `sudo chown -R 1000:1000 palworld` |
| Nobody can connect | Firewall rule for UDP 8211 (section 1.1); check `sudo docker compose logs` |
| Host lost their character after moving online | Host fix (section 3.2) |
| "Ghost" player blocks guild invites | Delete `Players/00000000000000000000000000000001.sav` with the server stopped |
