#!/bin/bash
#
# Re-point the Apeos 2350 NDA queue at a different printer address.
#
#   sudo ./set-printer-address.sh 192.168.1.100
#
# The address is remembered in printer-address.conf, which the driver package's
# post-install script honours, so a later re-install keeps your choice instead
# of re-running Bonjour discovery.
#
set -euo pipefail
PATH=/usr/bin:/bin:/usr/sbin:/sbin
export PATH

DEST=/Library/Printers/FUJIFILM/Apeos2350
QUEUE=Apeos_2350_HBPL
PORT=9100

[ "$(id -u)" = "0" ] || { echo "run with sudo:  sudo $0 <printer-ip>" >&2; exit 1; }

IP="${1:-}"
if [ -z "$IP" ]; then
  echo "usage: sudo $0 <printer-ip>" >&2
  echo >&2
  echo "Tip: the printer's IP is shown on its control panel, or found via" >&2
  echo "     Bonjour:   dns-sd -B _pdl-datastream._tcp local." >&2
  exit 2
fi

case "$IP" in
  *[!0-9.]*) echo "that does not look like an IPv4 address: $IP" >&2; exit 2 ;;
esac

if nc -z -G 3 "$IP" "$PORT" 2>/dev/null; then
  echo "==> $IP:$PORT reachable"
else
  echo "==> WARNING: $IP:$PORT did not answer (printer asleep?).  Setting it anyway."
fi

mkdir -p "$DEST"
echo "$IP" > "$DEST/printer-address.conf"

if lpstat -p "$QUEUE" >/dev/null 2>&1; then
  lpadmin -p "$QUEUE" -E -v "socket://$IP:$PORT"
else
  lpadmin -p "$QUEUE" -E -v "socket://$IP:$PORT" \
          -P "/Library/Printers/PPDs/Contents/Resources/FUJIFILM Apeos 2350 NDA HBPL.ppd" \
          -D "FUJIFILM Apeos 2350 NDA (HBPL)" -o printer-is-shared=false
fi
cupsenable "$QUEUE" 2>/dev/null || true
cupsaccept "$QUEUE" 2>/dev/null || true

echo "==> done"
lpstat -v "$QUEUE"
