#!/bin/bash
#
# Build the CUPS filter for the FUJIFILM Apeos 2350 NDA.
#
# Everything needed is in this tree: src/rastertohbpl.c (the CUPS filter),
# plus the vendored HBPL v2 encoder by Rick Richardson (foo2hbpl2, GPLv2)
# and Markus Kuhn's JBIG-KIT, which it uses for the page bitmaps.
#
#   ./build.sh                     # universal binary (arm64 + x86_64)
#   ARCHS=arm64 ./build.sh         # single architecture
#   ARCHS="arm64 x86_64" ./build.sh
#
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
cd "$HERE"

CC="${CC:-cc}"
CFLAGS="${CFLAGS:--O2 -Wall -Wno-unused-result -Wno-implicit-function-declaration}"

mkdir -p build bin

# ---------------------------------------------------------------------------
# Pick the architectures.  A universal binary means the driver runs on Intel
# Macs too, which matters when handing it to other people.
# ---------------------------------------------------------------------------
ARCHS="${ARCHS:-}"
if [ -z "$ARCHS" ]; then
  printf 'int main(void){return 0;}\n' > build/.archprobe.c
  if $CC -arch arm64 -arch x86_64 -o build/.archprobe build/.archprobe.c 2>/dev/null; then
    ARCHS="arm64 x86_64"
  else
    ARCHS="$(uname -m)"
  fi
  rm -f build/.archprobe build/.archprobe.c
fi

ARCHFLAGS=""
for a in $ARCHS; do
  ARCHFLAGS="$ARCHFLAGS -arch $a"
done
echo "==> architectures:$ARCHFLAGS"

# ---------------------------------------------------------------------------
# Compile.  The HBPL encoder's main() is renamed so that it can be linked
# into the filter: the CUPS sandbox is happier with one self-contained
# binary than with a filter that exec()s a helper.
# ---------------------------------------------------------------------------
echo "==> compiling HBPL encoder (foo2hbpl2, main renamed)"
$CC $CFLAGS $ARCHFLAGS -c -Dmain=foo2hbpl2_main src/foo2hbpl2.c -Isrc -o build/foo2hbpl2_enc.o

echo "==> compiling JBIG-KIT"
$CC $CFLAGS $ARCHFLAGS -c src/jbig.c    -Isrc -o build/jbig.o
$CC $CFLAGS $ARCHFLAGS -c src/jbig_ar.c -Isrc -o build/jbig_ar.o

echo "==> compiling CUPS filter"
$CC $CFLAGS $ARCHFLAGS -c src/rastertohbpl.c -o build/rastertohbpl.o

echo "==> linking"
$CC -O2 $ARCHFLAGS -o bin/rastertohbpl \
    build/rastertohbpl.o build/foo2hbpl2_enc.o build/jbig.o build/jbig_ar.o

echo "==> built $HERE/bin/rastertohbpl"
lipo -info bin/rastertohbpl 2>/dev/null | sed 's/^/    /' || true
