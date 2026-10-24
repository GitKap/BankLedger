#!/bin/sh
# Copies the addon into the Kronos clients that exist here: 1.12 and the 1.14 Classic Era client.
# A new addon or .toc change loads only after a full client restart.
set -e
SRC="$(dirname "$0")/BankLedger/"
for GAME in "/LINUX_DATA/Games/WoW Vanilla" "/LINUX_DATA/Games/WoW1.14/World of Warcraft/_classic_era_"; do
  [ -d "$GAME/Interface" ] || continue
  DEST="$GAME/Interface/AddOns/BankLedger"
  mkdir -p "$DEST"
  rsync -a --delete "$SRC" "$DEST/"
  echo "installed to $DEST"
done
