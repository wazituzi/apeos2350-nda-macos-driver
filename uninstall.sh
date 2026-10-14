#!/bin/bash
#
# Remove the queue and the installed filter. The printer is untouched.
#
set -euo pipefail
QUEUE="${QUEUE:-Apeos_2350_HBPL}"
DEST="/Library/Printers/FUJIFILM/Apeos2350"

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
