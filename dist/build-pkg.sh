#!/bin/bash
#
# Build a double-clickable macOS installer (.pkg) and a disk image (.dmg) for
# the FUJIFILM Apeos 2350 NDA HBPL driver.
#
#   ./build-pkg.sh
#   VERSION=1.1 ./build-pkg.sh
#
# Output: dist/out/Apeos2350NDA-HBPL-<version>.pkg
#         dist/out/Apeos2350NDA-HBPL-<version>.dmg
#
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"

VERSION="${VERSION:-1.8}"
IDENT="com.apeos2350nda.hbpl"
BASENAME="Apeos2350NDA-HBPL-$VERSION"
OUT="$HERE/out"
PKGROOT="$HERE/pkgroot"
STAGE="$HERE/dmg-stage"

FILTER_REL="Library/Printers/FUJIFILM/Apeos2350/rastertohbpl"
PPD_REL="Library/Printers/PPDs/Contents/Resources/FUJIFILM Apeos 2350 NDA HBPL.ppd"

say() { printf '\033[1m==>\033[0m %s\n' "$*"; }

say "Building the filter (universal: arm64 + x86_64)"
"$ROOT/build.sh"

say "Staging payload"
rm -rf "$PKGROOT"
mkdir -p "$PKGROOT/Library/Printers/FUJIFILM/Apeos2350"
mkdir -p "$PKGROOT/Library/Printers/PPDs/Contents/Resources"

install -m 755 "$ROOT/bin/rastertohbpl" "$PKGROOT/$FILTER_REL"
install -m 644 "$ROOT/COPYING" "$PKGROOT/Library/Printers/FUJIFILM/Apeos2350/COPYING.txt"
install -m 644 "$HERE/README-install.txt" \
        "$PKGROOT/Library/Printers/FUJIFILM/Apeos2350/README.txt"
install -m 755 "$HERE/set-printer-address.sh" \
        "$PKGROOT/Library/Printers/FUJIFILM/Apeos2350/set-printer-address.sh"

# Bake the final filter path into the PPD: inside an installed package there is
# nobody left to substitute @FILTER@.
sed "s|@FILTER@|/Library/Printers/FUJIFILM/Apeos2350/rastertohbpl|" \
    "$ROOT/ppd/FUJIFILM-Apeos-2350-NDA-HBPL.ppd" > "$PKGROOT/$PPD_REL"
chmod 644 "$PKGROOT/$PPD_REL"

# Extended attributes would otherwise be packaged as AppleDouble "._*"
# sidecar files inside the payload.
xattr -rc "$PKGROOT" 2>/dev/null || true

if ! cupstestppd "$PKGROOT/$PPD_REL" >/dev/null 2>&1; then
  cupstestppd -v "$PKGROOT/$PPD_REL" | head -20
  echo "ERROR: staged PPD failed cupstestppd" >&2
  exit 1
fi
say "PPD validates"

mkdir -p "$OUT"
rm -f "$OUT/$BASENAME.pkg"

say "pkgbuild"
PKGBUILD_ARGS=(
  --root "$PKGROOT"
  --scripts "$HERE/scripts"
  --identifier "$IDENT"
  --version "$VERSION"
)
# Keeps the payload root-owned where the tool supports it.  The post-install
# script force-chowns anyway, because CUPS refuses to run a filter that is not
# root-owned.
if pkgbuild --root "$PKGROOT" --identifier "$IDENT.probe" --version 0 \
            --ownership recommended "$OUT/.ownership-probe.pkg" >/dev/null 2>&1; then
  PKGBUILD_ARGS+=(--ownership recommended)
fi
rm -f "$OUT/.ownership-probe.pkg"
pkgbuild "${PKGBUILD_ARGS[@]}" "$OUT/$BASENAME.pkg"

say "Packaging the distributable archive"
rm -rf "$STAGE"
mkdir -p "$STAGE"
cp "$OUT/$BASENAME.pkg" "$STAGE/"
cp "$HERE/README-install.txt" "$STAGE/INSTALL.txt"
cp "$ROOT/COPYING" "$STAGE/GPL-2.0.txt"
xattr -rc "$STAGE" 2>/dev/null || true

say "Packaging corresponding source (GPLv2 requires it when shipping binaries)"
SRCTAR="$OUT/$BASENAME-src.tar.gz"
rm -f "$SRCTAR"
tar czf "$SRCTAR" -C "$ROOT" \
    --exclude 'build' --exclude 'bin' \
    --exclude 'dist/out' --exclude 'dist/pkgroot' --exclude 'dist/dmg-stage' \
    src ppd build.sh install.sh uninstall.sh README.md COPYING tools

rm -f "$OUT/$BASENAME.dmg" "$OUT/$BASENAME.zip"
ARCHIVE="$OUT/$BASENAME.dmg"
if ! hdiutil create -quiet -volname "Apeos 2350 NDA HBPL $VERSION" \
                    -srcfolder "$STAGE" -ov -format UDZO "$ARCHIVE" 2>/dev/null \
   || [ ! -f "$ARCHIVE" ]; then
  # Some environments (sandboxes, CI) cannot create disk images.  A zip is an
  # equally good way to hand the package to someone.
  ARCHIVE="$OUT/$BASENAME.zip"
  rm -f "$ARCHIVE"
  (cd "$STAGE" && ditto -c -k . "$ARCHIVE")
fi

say "Done"
ls -lh "$OUT/$BASENAME.pkg" "$ARCHIVE" "$SRCTAR" | sed 's/^/    /'
echo
echo "    Payload:"
pkgutil --payload-files "$OUT/$BASENAME.pkg" | sed 's/^/      /'
