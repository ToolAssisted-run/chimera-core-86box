#!/bin/sh
# build.sh <out dir>: assembles the probe (nasm) and writes probe.img, a
# 360 KB floppy that boots it.
set -eu
here="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$1"
out="$(cd "$1" && pwd)"
command -v nasm >/dev/null 2>&1 || { echo "no nasm: install nasm"; exit 1; }
nasm -f bin -o "$out/probe.bin" "$here/probe.asm"
python3 "$here/make-floppy.py" "$out/probe.bin" "$out/probe.img"
echo "probe.img: sha1 $(sha1sum "$out/probe.img" | cut -c1-40)"
