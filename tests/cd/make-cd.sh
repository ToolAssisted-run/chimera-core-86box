#!/bin/sh
# make-cd.sh <out dir>: the test scripts' CD, made here.
#
#   probe-cd.iso       an ISO 9660 image (xorriso), one file, README.TXT
#   probe-cd-tone.bin  5 s of a 1 kHz tone, 44100 Hz stereo 16-bit, as CD
#                      audio sectors (2352 bytes)
#   probe-cd.cue       the two as one disc: track 1 data, track 2 audio
#
# The same bytes every time (SOURCE_DATE_EPOCH fixes xorriso's dates). Ours,
# free to distribute.
set -eu
here="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$1"
out="$(cd "$1" && pwd)"
command -v xorriso >/dev/null 2>&1 || { echo "no xorriso: install xorriso"; exit 1; }
rm -rf "$out/root"
mkdir -p "$out/root"
printf 'A CD made by the tests of the 86Box core for Chimera.\r\n' > "$out/root/README.TXT"
touch -d @1781000000 "$out/root/README.TXT" "$out/root"
rm -f "$out/probe-cd.iso"
SOURCE_DATE_EPOCH=1781000000 xorriso -as mkisofs -quiet -o "$out/probe-cd.iso" -V CHIMERA_CD "$out/root" 2> "$out/xorriso.log"
python3 "$here/make-tone.py" "$out/probe-cd-tone.bin"
cat > "$out/probe-cd.cue" <<'CUE'
FILE "probe-cd.iso" BINARY
  TRACK 01 MODE1/2048
    INDEX 01 00:00:00
FILE "probe-cd-tone.bin" BINARY
  TRACK 02 AUDIO
    INDEX 01 00:00:00
CUE
echo "probe-cd.iso $(wc -c < "$out/probe-cd.iso") bytes ($(($(wc -c < "$out/probe-cd.iso") / 2048)) sectors), probe-cd-tone.bin $(wc -c < "$out/probe-cd-tone.bin") bytes"
