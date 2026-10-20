#!/bin/bash
#
# Install the FUJIFILM Apeos 2350 NDA print queue on macOS.
#
#   sudo ./install.sh                 # install / update the queue
#   sudo QUEUE=MyPrinter ./install.sh
#   sudo IP=192.168.1.100 ./install.sh
#   sudo ./install.sh --clean-legacy  # also delete the old broken queues
#   sudo ./install.sh --test          # install, then print a test page
#
# The filter MUST be owned by root: CUPS refuses to execute a filter that is
# owned by a normal user ("Unable to start filter ... Invalid argument"), and
# /usr/libexec/cups/filter is read-only under SIP, so the driver is installed
# into /Library/Printers, exactly like a vendor driver would be.
#
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
QUEUE="${QUEUE:-Apeos_2350_HBPL}"
IP="${IP:-}"
PORT="${PORT:-9100}"
DEFAULT_IP="192.168.1.100"
DEST="/Library/Printers/FUJIFILM/Apeos2350"
PPD_SRC="$HERE/ppd/FUJIFILM-Apeos-2350-NDA-HBPL.ppd"
# Where macOS looks for printer drivers.  The .pkg installs the same path; the
# script has to keep it in sync too, otherwise "System Settings > Printers"
# keeps offering the PPD from whatever version was installed first.
PPD_DEST="/Library/Printers/PPDs/Contents/Resources/FUJIFILM Apeos 2350 NDA HBPL.ppd"

CLEAN_LEGACY=0
RUN_TEST=0
for arg in "$@"; do
  case "$arg" in
    --clean-legacy) CLEAN_LEGACY=1 ;;
    --test)         RUN_TEST=1 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

say() { printf '\033[1m==>\033[0m %s\n' "$*"; }
die() { printf '\033[31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" = "0" ] || die "must run as root:  sudo $0"

# ---------------------------------------------------------------------------
# No address given?  Ask Bonjour.  The printer advertises
# _pdl-datastream._tcp but NOT _ipp._tcp (its IPP endpoint is a stub - see
# README), so a plain CUPS driverless lookup would never find it.
#
# The address comes back through DISC_IP rather than stdout: the function is
# deliberately not run inside a command substitution, because stray output
# would otherwise be captured into the device URI.
# ---------------------------------------------------------------------------
DISC_IP=""
discover_printer() {
  DISC_IP=""
  local tmp p inst host ip
  tmp="$(mktemp -d)" || return 1

  dns-sd -B _pdl-datastream._tcp local. > "$tmp/browse" 2>&1 &
  p=$!; sleep 5; kill "$p" 2>/dev/null; wait "$p" 2>/dev/null

  inst="$(awk '/Apeos|FUJIFILM/ && /_pdl-datastream/ {
                 sub(/^.*_pdl-datastream\._tcp\.[ \t]*/, ""); print; exit
               }' "$tmp/browse")"
  if [ -z "$inst" ]; then rm -rf "$tmp"; return 1; fi
  echo "    Bonjour: $inst"

  dns-sd -L "$inst" _pdl-datastream._tcp local. > "$tmp/lookup" 2>&1 &
  p=$!; sleep 4; kill "$p" 2>/dev/null; wait "$p" 2>/dev/null

  host="$(grep -o 'can be reached at [^ ]*' "$tmp/lookup" | awk '{print $NF}' \
          | sed 's/:[0-9]*$//' | head -1)"
  if [ -z "$host" ]; then rm -rf "$tmp"; return 1; fi

  ip="$(dscacheutil -q host -a name "$host" 2>/dev/null \
        | awk '/^ip_address:/ {print $2; exit}')"
  if [ -z "$ip" ]; then
    ping -c 1 -W 2000 "$host" > "$tmp/ping" 2>&1
    ip="$(sed -n 's/.*(\([0-9][0-9.]*\)).*/\1/p' "$tmp/ping" | head -1)"
  fi
  rm -rf "$tmp"
  [ -n "$ip" ] || return 1
  DISC_IP="$ip"
  return 0
}

if [ -z "$IP" ]; then
  say "Looking for the printer over Bonjour"
  if discover_printer; then
    IP="$DISC_IP"
    echo "    found $IP"
  else
    IP="$DEFAULT_IP"
    echo "    nothing found; falling back to $IP"
    echo "    (override with:  sudo IP=<printer-ip> $0)"
  fi
fi

say "Checking the printer answers on $IP:$PORT"
if ! nc -z -G 3 "$IP" "$PORT" 2>/dev/null; then
  die "TCP $PORT is closed on $IP.  Is the printer awake and on this network?
     Apeos printers sleep: wake it from its panel, then retry."
fi
echo "    reachable"

if [ ! -x "$HERE/bin/rastertohbpl" ]; then
  say "Filter not built yet - building it now"
  "$HERE/build.sh"
fi

say "Installing the filter into $DEST"
install -d -o root -g wheel -m 755 "$DEST"
install -o root -g wheel -m 755 "$HERE/bin/rastertohbpl" "$DEST/rastertohbpl"
ls -l "$DEST/rastertohbpl" | sed 's/^/    /'

say "Generating the PPD"
TMPPPD="$(mktemp /tmp/apeos2350-ppd.XXXXXX)"
trap 'rm -f "$TMPPPD"' EXIT
sed "s|@FILTER@|$DEST/rastertohbpl|" "$PPD_SRC" > "$TMPPPD"
if ! cupstestppd "$TMPPPD" >/dev/null 2>&1; then
  cupstestppd -v "$TMPPPD" | head -20
  die "generated PPD failed cupstestppd"
fi
echo "    PPD valid, filter = $DEST/rastertohbpl"

say "Installing the PPD into /Library/Printers/PPDs"
install -d -o root -g wheel -m 755 "/Library/Printers/PPDs/Contents/Resources"
install -o root -g wheel -m 644 "$TMPPPD" "$PPD_DEST"
ls -l "$PPD_DEST" | sed 's/^/    /'
grep '^\*FileVersion' "$PPD_DEST" | sed 's/^/    /'

if lpstat -p "$QUEUE" >/dev/null 2>&1; then
  say "Updating existing queue '$QUEUE'"
  lpadmin -p "$QUEUE" -E -v "socket://$IP:$PORT" -P "$PPD_DEST"
else
  say "Creating queue '$QUEUE'"
  lpadmin -p "$QUEUE" -E -v "socket://$IP:$PORT" -P "$PPD_DEST" \
          -D "FUJIFILM Apeos 2350 NDA (HBPL)" \
          -o printer-is-shared=false
fi

cupsenable "$QUEUE" 2>/dev/null || true
cupsaccept "$QUEUE" 2>/dev/null || true

# Remove the queue created while developing the AirPrint/URF approach; that
# path cannot work on this device (its IPP endpoint is a stub).
if lpstat -p Apeos_2350_NDA >/dev/null 2>&1; then
  say "Removing the obsolete 'Apeos_2350_NDA' (AirPrint/URF) queue"
  lpadmin -x Apeos_2350_NDA >/dev/null 2>&1 || true
fi
if lpstat -p Apeos_2350_IPP >/dev/null 2>&1; then
  lpadmin -x Apeos_2350_IPP >/dev/null 2>&1 || true
fi

LEGACY="FUJIFILM_Apeos_2350_NDA__4B_58_3A_"
if [ "$CLEAN_LEGACY" = "1" ]; then
  if lpstat -p "$LEGACY" >/dev/null 2>&1; then
    say "Removing the broken legacy queue '$LEGACY'"
    echo "    (raw 9100 + Generic PostScript PPD, but the device has no"
    echo "     PostScript interpreter - it can never have worked)"
    lpadmin -x "$LEGACY" >/dev/null 2>&1 || true
  fi
else
  if lpstat -p "$LEGACY" >/dev/null 2>&1; then
    echo
    echo "NOTE: the old queue '$LEGACY' still exists."
    echo "      It cannot work (raw 9100 + Generic PostScript, no PS in the"
    echo "      device).  Remove it with:"
    echo "          sudo lpadmin -x $LEGACY"
    echo "      or re-run this script with --clean-legacy"
  fi
fi

say "Result"
lpstat -p "$QUEUE" -l | sed 's/^/    /'
echo
lpoptions -p "$QUEUE" -l 2>/dev/null | sed 's/^/    /' || true
echo

if [ "$RUN_TEST" = "1" ]; then
  say "Printing a test page"
  lp -d "$QUEUE" -o media=A4 -t "Apeos 2350 NDA driver test" \
     "$HERE/tools/diagnostic.pdf"
  sleep 2
  lpstat -o "$QUEUE" | sed 's/^/    /'
fi

say "Done.  Print with:  lp -d $QUEUE <file>"
echo "    Make it the default printer:  lpoptions -d $QUEUE"
echo "    Remove it again:              sudo $HERE/uninstall.sh"
