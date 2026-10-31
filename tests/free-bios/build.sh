#!/bin/sh
# build.sh <source checkout> <out dir>: the test script's free PC.
#
# Every machine 86Box has needs a BIOS, and the ones in its ROM set are not
# ours to put on a public CI runner. Sergey Kiselev's 8088 BIOS is free
# (GPL-3.0), and 86Box's Xi 8088 machine is built for it. This builds it
# from the commit 8088_bios.ref names, with nasm and cmake, in a copy of the
# checkout, and makes the two files a test needs, each under the name of the
# firmware the package declares for it:
#
#   machines_xi8088_bios-xi8088-128k.bin
#                                     the BIOS as 86Box loads it by default:
#                                     upstream's 128 KB "noide" image, read
#                                     at 0xE0000 with its halves swapped, so
#                                     the BIOS is in the top 32 KB
#   machines_xi8088_bios-xi8088.bin   the same for the machine's "64 KB"
#                                     setting: the image's first 64 KB
#   video_mda_mda.rom                 a stand-in for IBM's character ROM,
#                                     made from the BIOS's own 8x8 font
#                                     (make-font-rom.py), so the CGA shows
#                                     the BIOS's screen
#
# For the tests only: neither file is in the package. (After the PCem
# core's tests/free-bios, chimera issue 260.)
set -eu
src="$(cd "$1" && pwd)"
mkdir -p "$2"
out="$(cd "$2" && pwd)"
here="$(cd "$(dirname "$0")" && pwd)"
want="$(sed -n 's/^commit //p' "$here/8088_bios.ref")"
have="$(git -C "$src" rev-parse HEAD 2>/dev/null || echo "not a git checkout")"
if [ "$have" != "$want" ]; then
	echo "the source is at $have, not at $want (tests/free-bios/8088_bios.ref)"
	exit 1
fi
command -v nasm >/dev/null 2>&1 || { echo "no nasm: install nasm"; exit 1; }
command -v cmake >/dev/null 2>&1 || { echo "no cmake: install cmake"; exit 1; }
rm -rf "$out"
mkdir -p "$out/build"
cp -a "$src/." "$out/src"
(cd "$out/build" && cmake "$out/src" > cmake.log 2>&1 && make bios-xi8088.bin > make.log 2>&1)
cp "$out/build/bios-xi8088-noide.rom" "$out/machines_xi8088_bios-xi8088-128k.bin"
# the first 64 KB of upstream's "noide" image: 32 KB of 0xFF, then the BIOS
head -c 65536 "$out/build/bios-xi8088-noide.rom" > "$out/machines_xi8088_bios-xi8088.bin"
python3 "$here/make-font-rom.py" "$out/src/src/fnt00-7F.inc" "$out/src/src/fnt80-FF.inc" "$out/video_mda_mda.rom" > /dev/null
echo "machines_xi8088_bios-xi8088-128k.bin: $(wc -c < "$out/machines_xi8088_bios-xi8088-128k.bin") bytes, sha1 $(sha1sum "$out/machines_xi8088_bios-xi8088-128k.bin" | cut -c1-40), built with $(nasm -v)"
