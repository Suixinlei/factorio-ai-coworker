#!/usr/bin/env bash
# Start a local headless Factorio dev server for the ai-coworker mod.
# Fully isolated from the GUI client: own config/write-data/mods dir,
# so both can run at the same time.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SERVER_DIR="$ROOT/local-server"
SAVE="$SERVER_DIR/saves/dev-map.zip"
MODS_DIR="$SERVER_DIR/mods"
DATA_DIR="$SERVER_DIR/data"
CONFIG="$SERVER_DIR/config.ini"
PW_FILE="$SERVER_DIR/rcon.pw"
LOG_FILE="$SERVER_DIR/server.log"
APP="$HOME/Library/Application Support/Steam/steamapps/common/Factorio/factorio.app/Contents"
FACTORIO="$APP/MacOS/factorio"

mkdir -p "$SERVER_DIR/saves" "$MODS_DIR" "$DATA_DIR"

# Isolated config: headless never touches the GUI client's write-data dir.
cat > "$CONFIG" <<EOF
[path]
read-data=$APP/data
write-data=$DATA_DIR
EOF

# Sync the repo mod into the isolated mods dir as a versioned zip.
MOD_VERSION="$(sed -n 's/.*"version": *"\(.*\)".*/\1/p' "$ROOT/mod/info.json" | head -1)"
MOD_ZIP="$MODS_DIR/ai-coworker_$MOD_VERSION.zip"
STAGING="$SERVER_DIR/.mod-staging"
rm -f "$MODS_DIR"/ai-coworker_*.zip
rm -rf "$STAGING"
mkdir -p "$STAGING/ai-coworker_$MOD_VERSION"
cp -R "$ROOT/mod/" "$STAGING/ai-coworker_$MOD_VERSION/"
(cd "$STAGING" && zip -qr "$MOD_ZIP" "ai-coworker_$MOD_VERSION")
rm -rf "$STAGING"
cat > "$MODS_DIR/mod-list.json" <<EOF
{"mods":[{"name":"base","enabled":true},{"name":"elevated-rails","enabled":true},{"name":"quality","enabled":true},{"name":"space-age","enabled":true},{"name":"ai-coworker","enabled":true,"version":"$MOD_VERSION"}]}
EOF
echo "Packed mod: $MOD_ZIP"

# Deploy the same zip to the GUI client's mods dir so a client connecting to
# this server always has the matching mod version. The client's mod-list.json
# carries no pinned version, so swapping the zip is enough. Skipped silently
# on machines without a GUI client install.
CLIENT_MODS="$HOME/Library/Application Support/factorio/mods"
if [[ -d "$CLIENT_MODS" ]]; then
  rm -f "$CLIENT_MODS"/ai-coworker_*.zip
  cp "$MOD_ZIP" "$CLIENT_MODS/"
  echo "Synced mod to GUI client: $CLIENT_MODS/ai-coworker_$MOD_VERSION.zip"
else
  echo "GUI client mods dir not found ($CLIENT_MODS) — client sync skipped"
fi

# Create a fresh dev map if none exists.
if [[ ! -f "$SAVE" ]]; then
  echo "Creating dev map at $SAVE ..."
  "$FACTORIO" --create "$SAVE" --config "$CONFIG" --mod-directory "$MODS_DIR" "$@"
fi

# Generate an RCON password if missing.
if [[ ! -f "$PW_FILE" ]]; then
  openssl rand -hex 16 > "$PW_FILE"
fi
RCON_PW="$(cat "$PW_FILE")"

# Start the server DETACHED in its own session (start_new_session=True).
# A plain `nohup ... &` keeps it in the calling shell's process group, so
# when the invoking harness reaps its process tree the server gets SIGTERMed
# mid-test (reproduced: server died seconds after an E2E run started in the
# same invocation). A new session makes it survive any invocation pattern.
echo "Starting local headless Factorio server ..."
echo "  game port : 34198"
echo "  rcon port : 27016"
echo "  log       : $LOG_FILE"

"$FACTORIO" --version > /dev/null  # fail fast if the binary is missing
python3 - "$FACTORIO" "$SAVE" "$CONFIG" "$MODS_DIR" "$SERVER_DIR" "$PW_FILE" "$LOG_FILE" <<'PYEOF'
import os
import subprocess
import sys

factorio, save, config, mods_dir, server_dir, pw_file, log_file = sys.argv[1:8]
with open(pw_file) as f:
    rcon_pw = f.read().strip()
with open(log_file, "ab") as log:
    subprocess.Popen(
        [
            factorio,
            "--start-server", save,
            "--port", "34198",
            "--rcon-bind", "127.0.0.1:27016",
            "--rcon-password", rcon_pw,
            "--config", config,
            "--mod-directory", mods_dir,
            "--server-settings", os.path.join(server_dir, "server-settings.json"),
        ],
        stdout=log,
        stderr=subprocess.STDOUT,
        start_new_session=True,  # survive the caller's process-tree reaping
    )
PYEOF
