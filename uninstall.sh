#!/bin/bash
#
# Remove the queue and the installed filter. The printer is untouched.
#
set -euo pipefail
QUEUE="${QUEUE:-Apeos_2350_HBPL}"
DEST="/Library/Printers/FUJIFILM/Apeos2350"
PPD_DEST="/Library/Printers/PPDs/Contents/Resources/FUJIFILM Apeos 2350 NDA HBPL.ppd"

[ "$(id -u)" = "0" ] || { echo "must run as root:  sudo $0" >&2; exit 1; }

if lpstat -p "$QUEUE" >/dev/null 2>&1; then
  lpadmin -x "$QUEUE"
  echo "Removed queue '$QUEUE'."
else
  echo "No queue named '$QUEUE'."
fi

if [ -d "$DEST" ]; then
  rm -rf "$DEST"
  echo "Removed $DEST."
fi

# The PPD is what System Settings lists as the installed driver; remove it too,
# otherwise the driver stays visible for new queues after the filter is gone.
for f in "$PPD_DEST" "/Library/Printers/PPDs/Contents/Resources/._FUJIFILM Apeos 2350 NDA HBPL.ppd"; do
  if [ -e "$f" ]; then
    rm -f "$f"
    echo "Removed $f."
  fi
done
