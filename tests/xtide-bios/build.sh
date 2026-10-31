#!/bin/sh
# build.sh <XUB source> <out dir>: the XTIDE Universal BIOS for 86Box's
# 8-bit XT-IDE card, built from source.
#
# 86Box's "PC/XT XTIDE" card (hdc_xtide.c) is an XT-IDE revision 1: the
# drive's registers at 300h to 307h, the data's high byte at 308h, the
# alternate status at 30Eh, no interrupt. Upstream's XT build of the XTIDE
# Universal BIOS (ide_xt.bin, made with MODULE_8BIT_IDE_ADVANCED) starts
# with its first controller set to an XT-CF card at 300h
# (DEVICE_8BIT_XTCF_PIO8, Src/Main.asm), whose registers are at other
# addresses, so on 86Box's card it says "Master at 300h: not found". The
# same build without MODULE_8BIT_IDE_ADVANCED (the cards that need it -
# XT-CF, JR-IDE - are not 86Box's) starts with DEVICE_8BIT_XTIDE_REV1 at
# 300h, which is the card 86Box emulates. Nothing else is changed: the
# other modules are upstream's XT set (makefile, DEFINES_XT).
#
# Writes hdd_xtide_ide_xt.bin, the firmware id the package declares for the
# card's ROM: 8 KB, its checksum byte set as upstream's Tools/checksum.pl
# does; and ide_xt_upstream_default.bin, the same with upstream's
# MODULE_8BIT_IDE_ADVANCED, for the test scripts' negative control. For the
# tests only: neither is in the package.
set -eu
src="$(cd "$1" && pwd)"
mkdir -p "$2"
out="$(cd "$2" && pwd)"
here="$(cd "$(dirname "$0")" && pwd)"
want="$(sed -n 's/^tree //p' "$here/xub.ref")"
have="$(cd "$src" && find XTIDE_Universal_BIOS/Inc XTIDE_Universal_BIOS/Src Assembly_Library/Inc Assembly_Library/Src -type f \
	| LC_ALL=C sort | xargs sha256sum | sha256sum | cut -c1-64)"
if [ "$have" != "$want" ]; then
	echo "the source tree hashes to $have, not $want (tests/xtide-bios/xub.ref)"
	exit 1
fi
command -v nasm >/dev/null 2>&1 || { echo "no nasm: install nasm"; exit 1; }
defs="MODULE_STRINGS_COMPRESSED MODULE_HOTKEYS MODULE_8BIT_IDE MODULE_EBIOS MODULE_SERIAL MODULE_SERIAL_FLOPPY
MODULE_POWER_MANAGEMENT NO_ATAID_VALIDATION CLD_NEEDED EXTRA_LOOP_UNROLLING_SMALL ELIMINATE_CGA_SNOW"
incs=""
for d in Inc/ Inc/Controllers/ Src/ Src/Handlers/ Src/Handlers/Int13h/ Src/Handlers/Int13h/EBIOS/ Src/Handlers/Int13h/Tools/ \
	Src/Handlers/Int19h/ Src/Device/ Src/Device/IDE/ Src/Device/MemoryMappedIDE/ Src/Device/Serial/ Src/Initialization/ \
	Src/Initialization/AdvancedAta/ Src/Menus/ Src/Menus/BootMenu/ Src/Libraries/ Src/VariablesAndDPTs/; do
	incs="$incs -I$src/XTIDE_Universal_BIOS/$d"
done
for d in Inc/ Src/ Src/Display/ Src/File/ Src/Keyboard/ Src/Menu/ Src/Menu/Dialog/ Src/String/ Src/Time/ Src/Util/ Src/Serial/; do
	incs="$incs -I$src/Assembly_Library/$d"
done
# build <name> <defines...>: one image, padded to 8 KB with its checksum.
# The version string carries the build date (__DATE__, Inc/Version.inc): the
# date of r638 makes the image the same on every day it is built.
build() {
	name="$1"; shift
	dflags=""
	for d in "$@"; do dflags="$dflags -D$d"; done
	# shellcheck disable=SC2086
	(cd "$src/XTIDE_Universal_BIOS" && nasm Src/Main.asm -f bin $incs -Worphan-labels -Ox $dflags -D__DATE__='"2026-06-09"' \
		-l "$out/${name%.bin}.lst" -o "$out/${name%.bin}.raw")
	python3 - "$out/${name%.bin}.raw" "$out/$name" <<'PY'
import sys
data = bytearray(open(sys.argv[1], "rb").read())
size = data[2] * 512
assert data[:2] == b"\x55\xaa" and size == 8192 and len(data) < size, (data[:3], len(data))
data += bytes(size - len(data))
data[-1] = (-sum(data[:-1])) & 0xFF
assert sum(data) & 0xFF == 0
open(sys.argv[2], "wb").write(data)
PY
}
# shellcheck disable=SC2086
build hdd_xtide_ide_xt.bin $defs
# the negative control: upstream's XT set as it is, which starts with an
# XT-CF card at 300h and does not find the drive on 86Box's card
# shellcheck disable=SC2086
build ide_xt_upstream_default.bin $defs MODULE_8BIT_IDE_ADVANCED
echo "hdd_xtide_ide_xt.bin: $(wc -c < "$out/hdd_xtide_ide_xt.bin") bytes, sha1 $(sha1sum "$out/hdd_xtide_ide_xt.bin" | cut -c1-40), XUB r$(sed -n 's/^revision //p' "$here/xub.ref"), $(nasm -v)"
