#!/bin/sh
# Copies the addon into the Kronos client. A new addon or .toc change loads only after a full client restart.
set -e
DEST="/LINUX_DATA/Games/WoW Vanilla/Interface/AddOns/BankLedger"
mkdir -p "$DEST"
rsync -a --delete "$(dirname "$0")/BankLedger/" "$DEST/"
echo "installed to $DEST"
