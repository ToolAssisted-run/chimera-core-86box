#!/bin/sh
# The 86Box core's gate: the core and its native reference, leg by leg,
# each saying what it compared. Read Chimera's docs/gates.md first; every leg
# here has been run broken on purpose and seen to fail, and where a leg has a
# negative control the control runs as part of the gate.
#
#   CHIMERA_ROOT=<chimera checkout> [MINIBOX_DIR=<miniBox>] \
#   XUB_SRC=<XTIDE Universal BIOS r638, waterbox/xtide-bios/xub.ref> \
#   FREE_BIOS_SRC=<checkout of tests/free-bios/8088_bios.ref> \
#       waterbox/run-gate.sh
#
# XUB_SRC is needed by the builds themselves: the core carries the XT-IDE
# cards' ROM, built from that source.
#
# Optional, each adding legs that say SKIP without it:
#   FREEDOS_FLOPPY   FreeDOS 1.3's boot floppy (FD13-FloppyEdition, 144m/x86BOOT.img)
#   PCBOX_ROMS       the ROM set of 86Box, tag v6.0 (the owner's, for local
#                    tests only: never on a public runner)
#   PCBOX_KROZ       Kingdom of Kroz II's archive, 1kroz.zip
#   PCBOX_DOOM       Doom v1.9 shareware's archive, doom19s.zip
#   PCBOX_ALLEYCAT   the owner's Alley Cat disk (180 KB, starts by itself)
#   PCBOX_POP        the owner's Prince of Persia disk (720 KB)
#
# Without FREE_BIOS_SRC (and nasm and cmake) no machine runs: the legs that
# need one say SKIP, with that reason. A gate that skipped everything is not
# a pass.
set -u
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/.." && pwd)"
[ -n "${CHIMERA_ROOT:-}" ] || { echo "say where Chimera is: CHIMERA_ROOT=<chimera checkout>" >&2; exit 2; }
chimera_root="$(cd "$CHIMERA_ROOT" && pwd)"
mb="${MINIBOX_DIR:-$chimera_root/extern/chimera-common-minibox}"
[ -n "${XUB_SRC:-}" ] || { echo "say where the XTIDE Universal BIOS r638 is: XUB_SRC=<folder> (waterbox/xtide-bios/xub.ref)" >&2; exit 2; }
XUB_SRC="$(cd "$XUB_SRC" && pwd)"
export XUB_SRC
work="$root/build/gate"
rm -rf "$work"
mkdir -p "$work"

pass=0; fail=0; skip=0
report() {
	case "$1" in
		PASS) pass=$((pass + 1)) ;;
		FAIL) fail=$((fail + 1)) ;;
		SKIP) skip=$((skip + 1)) ;;
	esac
	printf '%-5s %-46s %s\n' "$1" "$2" "${3:-}"
}
finish() {
	printf '\n%d passed, %d failed, %d skipped\n' "$pass" "$fail" "$skip"
	[ "$pass" -eq 0 ] && { echo "NOTHING RAN"; exit 1; }
	[ "$fail" -eq 0 ] || exit 1
	exit 0
}

# ------------------------------------------------------------ the builds
native="$root/build/meson-native"
guest="$root/build/meson-guest"
if [ -f "$native/build.ninja" ]; then
	meson configure "$native" "-Dxub_src=$XUB_SRC" > "$work/setup-native.log" 2>&1
else
	meson setup "$native" "$root" "-Dminibox_dir=$mb" "-Dxub_src=$XUB_SRC" > "$work/setup-native.log" 2>&1
fi
if ninja -C "$native" -j4 > "$work/build-native.log" 2>&1; then
	report PASS "the native reference builds" "run-native, run-wbx"
else
	report FAIL "the native reference builds" "see build/gate/build-native.log"
fi
if [ -f "$guest/build.ninja" ]; then
	meson configure "$guest" "-Dxub_src=$XUB_SRC" > "$work/setup-guest.log" 2>&1
else
	sh "$here/setup-guest.sh" -m "$mb" > "$work/setup-guest.log" 2>&1
fi
if ninja -C "$guest" -j4 core.wbx > "$work/build-guest.log" 2>&1; then
	report PASS "the guest builds" "core.wbx"
else
	report FAIL "the guest builds" "see build/gate/build-guest.log"
fi
if sh "$mb/source/guest/check-wbx.sh" "$guest/core.wbx" > "$work/check-wbx.log" 2>&1 \
   && grep -q " clean " "$work/check-wbx.log" && ! grep -q "declares PT_TLS" "$work/check-wbx.log"; then
	report PASS "core.wbx is sandbox-clean" "check-wbx: no thread locals, no %fs, nothing below rsp"
else
	report FAIL "core.wbx is sandbox-clean" "$(tail -1 "$work/check-wbx.log")"
fi

# ------------------------------------------------------------ the package
# built into this repository's build/Cores, never into the Chimera checkout
pkgdir="$root/build/Cores"
pkg="$pkgdir/86box.chimeraCore"
if sh "$here/build-package.sh" -m "$mb" -o "$pkgdir" > "$work/package.log" 2>&1; then
	report PASS "the package builds" "$(grep 'package sha1' "$work/package.log")"
else
	report FAIL "the package builds" "$(tail -2 "$work/package.log" | tr '\n' ' ')"
fi
tp="$chimera_root/build/meson-linux/source/ui/test-packages"
if [ ! -x "$tp" ]; then
	report SKIP "Chimera's contract tests" "no test-packages at $tp (Chimera built with its window)"
elif [ "$(ls "$pkgdir")" != "86box.chimeraCore" ]; then
	report FAIL "Chimera's contract tests" "build/Cores holds more than this package: $(ls "$pkgdir" | tr '\n' ' ')"
elif env -u DISPLAY "$tp" "$pkgdir" > "$work/contract.log" 2>&1; then
	report PASS "Chimera's contract tests" "$(grep -c '^PASS' "$work/contract.log") passed"
else
	report FAIL "Chimera's contract tests" "$(grep -m1 '^FAIL' "$work/contract.log")"
fi
if python3 "$chimera_root/tools/check-core-texts.py" "$root" > "$work/texts.log" 2>&1; then
	report PASS "the code's texts are keys of the English table" "$(tail -1 "$work/texts.log")"
else
	report FAIL "the code's texts are keys of the English table" "$(tail -1 "$work/texts.log")"
fi
# Proper nouns are never translated or bent (the owner, 2026-10-31): the
# core's names (86Box, IBM, the 8088...) by tools/check-names.py, Chimera's
# own (Chimera, Windows...) by Chimera's checker, over all 26 tables.
if python3 "$root/tools/check-names.py" "$here/languages" > "$work/names.log" 2>&1 \
   && python3 "$chimera_root/tools/check-proper-nouns.py" "$here" >> "$work/names.log" 2>&1; then
	report PASS "names are written as they are, in every table" "$(ls "$here/languages" | wc -l) tables"
else
	report FAIL "names are written as they are, in every table" "$(grep -m1 -v "bent or missing\\|proper nouns changed" "$work/names.log" | cut -c1-120)"
fi

rn="$native/run-native"
rw="$native/run-wbx"
wbx="$guest/core.wbx"
cfg="$here/waterbox.config"

# ---------------------------------------------- a free PC, built from source
# 86Box's ROM set is not ours to put on a public runner. Sergey Kiselev's
# 8088 BIOS is free (GPL-3.0) and 86Box's Xi 8088 is made for it; the
# gate builds it, and a boot floppy of its own (tests/boot-probe).
fb="${FREE_BIOS_SRC:-}"
if [ -z "$fb" ]; then
	report SKIP "every leg that runs a machine" "needs FREE_BIOS_SRC (a checkout of tests/free-bios/8088_bios.ref), nasm and cmake"
	finish
fi
if ! sh "$root/tests/free-bios/build.sh" "$fb" "$work/free-bios" > "$work/free-bios.log" 2>&1; then
	report FAIL "free PC: the BIOS builds" "$(tail -2 "$work/free-bios.log" | tr '\n' ' ')"
	finish
fi
roms="$work/roms"
mkdir -p "$roms"
cp "$work/free-bios/machines_xi8088_bios-xi8088-128k.bin" "$work/free-bios/video_mda_mda.rom" "$roms/"
if ! sh "$root/tests/boot-probe/build.sh" "$work/probe" > "$work/probe.log" 2>&1; then
	report FAIL "free PC: the probe floppy builds" "$(tail -2 "$work/probe.log" | tr '\n' ' ')"
	finish
fi
report PASS "free PC: the BIOS and the probe floppy build" "$(tail -1 "$work/free-bios.log" | cut -d, -f1-2)"
# A hard disk for the probe: 10 MB of zeros (306 cylinders, 4 heads, 17
# sectors), on an XT-IDE card. The probe drives the card's registers itself.
# The card's ROM is the XTIDE Universal BIOS the core carries: it finds the
# drive, looks for a second one (which takes it until about frame 1540) and
# boots the floppy, so the probe starts about 750 frames later than on a
# machine without the card. Every frame number of the probe's run below is
# 1000 later than it was before the core carried that ROM.
python3 -c "import sys; open(sys.argv[1], 'wb').write(bytes(306 * 4 * 17 * 512))" "$work/hdd10.img"

# (a setting given twice is read as the first: a leg that needs another value
# starts from $xi_base)
xi_base="--roms $roms --set machine=xi8088 --set video=cga --set memoryKB=640 --set floppyA=525_2dd --set mouse=msserial --set joystick=2axis_2button --set hardDiskController=xtide"
xi="$xi_base --set sound=adlib"
probe="--file floppy_a=$work/probe/probe.img --file hdd=$work/hdd10.img"
# the probe's run: the key A (button 29) held at frame 2200, the mouse moved
# 30 to the right at 2300 and its position moved at 2350 - so every leg that
# compares the probe's run compares a machine that was given input
# and the first stick's first button and the second's second (buttons 106
# and 109) held from 2200 to the end
input="--key 2200:5:29 --axis 2300:1:0:30 --axis 2350:100:3:50000 --key 2200:301:106 --key 2200:301:109"
n=0
native_run() { n=$((n + 1)); rm -rf "$work/n$n"; "$rn" "$work/n$n" "$@" 2> "$work/n$n.err"; }
lit() { python3 - "$1" <<'PY'
import sys
d = open(sys.argv[1], 'rb').read().split(b'\n', 3)[3]
print(sum(1 for i in range(0, len(d), 3) if d[i] | d[i + 1] | d[i + 2]))
PY
}
word_at() { python3 -c "import struct,sys; d=open(sys.argv[1],'rb').read(); print(struct.unpack_from('<H', d, int(sys.argv[2], 16))[0])" "$1" "$2"; }

# ------------------------------------------- 0. what the core refuses
# A machine whose ROM files are not all there is refused with the files'
# names, never switched for another or run without them. The Xi 8088 with
# only its 64 KB file is the case that once ran with no BIOS and said
# nothing (86Box's "available" is satisfied by either of its two files).
# The XT's "(Alt)" BIOS, whose second file is not in the ROM set of 86Box
# v6.0, is not offered, and is refused when it is asked for anyway.
refusal() { rm -rf "$work/refuse"; "$rn" "$work/refuse" "$@" --frames 1 2>&1 | sed -n 's/^Init: //p' | tr '\037' '|'; }
r_pc=$(refusal --roms "$roms" --set machine=ibmpc)
mkdir -p "$work/roms64"; cp "$work/free-bios/machines_xi8088_bios-xi8088.bin" "$work/free-bios/video_mda_mda.rom" "$work/roms64/"
r_64=$(refusal --roms "$work/roms64" --set machine=xi8088)
r_cpu=$(refusal --roms "$roms" --set machine=ibmat --set cpu=8088/4772728)
r_alt=$(refusal --roms "$roms" --set machine=ibmxt --set bios=ibm5160_1501512_6359116)
if [ "$r_pc" = "error.roms_missing|[8088] IBM PC (1981)|machines_ibmpc_BIOS_IBM5150_19OCT81_5700671_U33.BIN" ] \
   && [ "$r_64" = "error.roms_missing|[8088] Xi8088|machines_xi8088_bios-xi8088-128k.bin" ] \
   && [ "$r_cpu" = "error.cpu_not_taken|8088/4772728|286/6000000, 286/8000000" ] \
   && [ "${r_alt%%|ibm5160_1501512_5000027, *}" = "error.bios_not_taken|ibm5160_1501512_6359116" ] \
   && ! grep -q 6359116 "$cfg"; then
	report PASS "refused, by name: missing ROMs, a CPU, a BIOS" "IBM PC without its BIOS; Xi 8088 with only the 64 KB file; an 8088 in an AT; the XT's (Alt) BIOS, not offered"
else
	report FAIL "refused, by name: missing ROMs, a CPU, a BIOS" "[$r_pc] [$r_64] [$r_cpu] [$r_alt]"
fi

# ------------------------------------------- 1. the native reference runs
# The BIOS screen: lit, and not the picture of a moment before it (a machine
# that shows one still picture is not running).
native_run $xi --frames 600 --ppm "$work/bios-59.ppm" --ppm-at 59 > /dev/null
native_run $xi --frames 600 --ppm "$work/bios-600.ppm" > /dev/null
l600=$(lit "$work/bios-600.ppm" 2>/dev/null || echo 0)
if [ "${l600:-0}" -gt 5000 ] && ! cmp -s "$work/bios-59.ppm" "$work/bios-600.ppm"; then
	report PASS "native: the Xi 8088 reaches its BIOS screen" "$l600 lit pixels at frame 600, not frame 59's picture"
else
	report FAIL "native: the Xi 8088 reaches its BIOS screen" "${l600:-0} lit pixels; see build/gate/bios-600.ppm"
fi
# The probe: it booted, it found the BIOS timer running, and its block is
# in the machine's memory where the gate reads it.
native_run $xi $probe $input --frames 2500 --dump-ram "$work/probe-native.ram" --digests "$work/probe-native.dig" > "$work/probe-native.txt"
probe_dir="$work/n$n"
ticks=$(word_at "$work/probe-native.ram" 7e00 2>/dev/null || echo 0)
if [ "$(dd if="$work/probe-native.ram" bs=1 skip=$((0x7e06)) count=4 2>/dev/null)" = "PRB1" ] && [ "${ticks:-0}" -gt 50 ]; then
	report PASS "native: the probe floppy boots and runs" "$ticks timer ticks counted by frame 2500"
else
	report FAIL "native: the probe floppy boots and runs" "ticks=${ticks:-?}; see build/gate/n$n.err"
fi

# ---------------------------------------- 2. one machine, every time
native_run $xi $probe $input --frames 2500 --digests "$work/probe-native2.dig" > /dev/null
if cmp -s "$work/probe-native.dig" "$work/probe-native2.dig" && [ "$(wc -l < "$work/probe-native.dig")" -eq 2500 ]; then
	report PASS "native: two runs give the same stream" "2500 frames: machine clock, cycles and picture of each"
else
	report FAIL "native: two runs give the same stream" "see build/gate/probe-native*.dig"
fi
# negative control: the stream sees another machine (a faster CPU)
native_run $xi $probe $input --set cpu=8088/7159092 --frames 2500 --digests "$work/probe-fast.dig" > /dev/null
if [ -s "$work/probe-fast.dig" ] && ! cmp -s "$work/probe-native.dig" "$work/probe-fast.dig"; then
	report PASS "native: the stream notices a faster CPU" "negative control"
else
	report FAIL "native: the stream notices a faster CPU" "it did not: the legs comparing streams are blind"
fi

# ------------------------------------------------------------ 3. input
# The probe keeps what it read: keys at 7E02 (how many) and 7E04 (the last
# one's scan code and character), bytes from the serial mouse at 7E0A. The
# idle run is the control: the press came when the probe was there to read
# it (it boots at about frame 800), and nothing else made the numbers move.
# The probe polls the serial port once a timer tick, so bytes that come
# faster are lost to the UART's overrun; the counts are what it read, the
# same in every run, and more movement reads more.
native_run $xi $probe --frames 2500 --dump-ram "$work/idle.ram" > "$work/idle.txt"
k_idle=$(word_at "$work/idle.ram" 7e02); k=$(word_at "$work/probe-native.ram" 7e02); last=$(word_at "$work/probe-native.ram" 7e04)
if [ "$k_idle" = 0 ] && [ "$k" = 1 ] && [ "$last" = $((0x1e61)) ]; then
	report PASS "input: a key held reaches the program" "A held 5 frames: one key, scan code 1E, 'a' (idle run: none)"
else
	report FAIL "input: a key held reaches the program" "keys idle=$k_idle pressed=$k last=$last"
fi
m_idle=$(word_at "$work/idle.ram" 7e0a); m=$(word_at "$work/probe-native.ram" 7e0a)
native_run $xi $probe --key 2200:5:29 --axis 2300:1:0:30 --frames 2500 --dump-ram "$work/rel.ram" > /dev/null
m_rel=$(word_at "$work/rel.ram" 7e0a)
if [ "$m_idle" = 1 ] && [ "$m_rel" -gt "$m_idle" ] && [ "$m" -gt "$m_rel" ]; then
	report PASS "input: the mouse moves the machine" "serial mouse bytes: idle $m_idle (its 'M'), a move $m_rel, a move and a position $m"
else
	report FAIL "input: the mouse moves the machine" "serial mouse bytes: idle $m_idle, a move $m_rel, both $m"
fi
j_idle=$(od -An -tu1 -j $((0x7e0e)) -N1 "$work/idle.ram" | tr -d ' '); j=$(od -An -tu1 -j $((0x7e0e)) -N1 "$work/probe-native.ram" | tr -d ' ')
if [ "$j_idle" = $((0xf0)) ] && [ "$j" = $((0x60)) ]; then
	report PASS "input: joystick buttons reach the game port" "port 0x201 reads F0 idle, 60 with stick 1 button 1 and stick 2 button 2 held"
else
	report FAIL "input: joystick buttons reach the game port" "port 0x201: idle $j_idle, held $j (wanted 240 and 96)"
fi
lag_idle=$(sed -n 's/.*inputFrames=\([0-9]*\).*/\1/p' "$work/idle.txt"); lag=$(sed -n 's/.*inputFrames=\([0-9]*\).*/\1/p' "$work/probe-native.txt")
# The probe reads the game port once a timer tick (and wakes for each key),
# so most of its 2500 frames read no control: those are lag frames. The two
# runs need not read the same number: a key makes the probe read both disks
# again, and while it waits for them it reads no control (with the carried
# XTIDE BIOS the run with input reads fewer frames than the idle one).
if [ -n "$lag_idle" ] && [ "$lag_idle" -gt 0 ] && [ "$lag_idle" -lt 400 ] && [ "$lag" -gt 0 ] && [ "$lag" -lt 400 ] \
   && [ "$lag" != "$lag_idle" ]; then
	report PASS "input: frames nobody read are lag frames" "frames that read a control: idle $lag_idle, with input $lag, of 2500"
else
	report FAIL "input: frames nobody read are lag frames" "idle ${lag_idle:-?}, with input ${lag:-?}"
fi

# ------------------------------------------------------------ 3a. disks
# The probe writes "WR" and the timer to sector 2 of its floppy at start,
# and "HD" to sector 2 of the hard disk, and reads both back (again after
# every key). The frontend mounts files read-only; the core keeps what the
# machine writes in the machine's memory (waterbox/chimera-overlay.c), so
# the writes succeed, read back, and the files are the same files
# afterwards. That the written blocks are in a state is the session leg's to
# show: the state of frame 2150, after the writes, is loaded in another
# process, and the key at 2200 reads the hard disk's sector again.
before=$(sha1sum < "$work/probe/probe.img"); hd_before=$(sha1sum < "$work/hdd10.img")
hd_status=$(od -An -tu1 -j $((0x7e16)) -N1 "$work/probe-native.ram" | tr -d ' '); hd_word=$(word_at "$work/probe-native.ram" 7e18)
w_status=$(word_at "$work/probe-native.ram" 7e14); w_word=$(word_at "$work/probe-native.ram" 7e10); r_status=$(word_at "$work/probe-native.ram" 7e12)
if [ "$w_status" = 1 ] && [ "$r_status" = 1 ] && [ "$w_word" = $((0x5257)) ] && [ "$(sha1sum < "$work/probe/probe.img")" = "$before" ] \
   && [ "$(sha1sum < "$probe_dir/probe.img")" = "$before" ] \
   && [ "$hd_status" = $((0x50)) ] && [ "$hd_word" = $((0x4448)) ] && [ "$(sha1sum < "$work/hdd10.img")" = "$hd_before" ] \
   && [ "$(sha1sum < "$probe_dir/hdd10.img")" = "$hd_before" ]; then
	report PASS "disks: sectors written read back" "floppy: BIOS write and read, 'WR'; hard disk: written and read on the card, 'HD', status 50h; both files unchanged"
else
	report FAIL "disks: sectors written read back" "floppy write AX=$w_status, read AX=$r_status, word=$w_word; hard disk status=$hd_status word=$hd_word"
fi

# ------------------------------------------------------------ 3b. sound
# The probe plays one held note on an AdLib's FM chip. 86Box hands FM over as
# a stream of its own at 49716 Hz, which the core converts and adds to the
# cards' 48000 Hz (waterbox/chimera-audio.c): the note must be in the
# frame's sound with an AdLib, and nothing without one (the BIOS's beep is
# over by frame 2000). And the count: 48000 a second, less the block of 20
# ms the cards have not finished by the last frame.
native_run $xi_base $probe --set sound=none --frames 2500 --digests "$work/nosound.dig" > /dev/null
peak=$(awk '$1 > 2000 && $5 > m { m = $5 } END { print m + 0 }' "$work/probe-native.dig")
peak_none=$(awk '$1 > 2000 && $5 > m { m = $5 } END { print m + 0 }' "$work/nosound.dig")
pairs=$(sed -n 's/.*audioPairs=\([0-9]*\).*/\1/p' "$work/probe-native.txt")
if [ "$peak" -gt 500 ] && [ "$peak_none" = 0 ] && [ "${pairs:-0}" -le 1200000 ] && [ "${pairs:-0}" -ge 1199040 ]; then
	report PASS "sound: an AdLib's FM note is in the frame's sound" "loudest after frame 2000: $peak (no card: 0); $pairs samples in 25 s"
else
	report FAIL "sound: an AdLib's FM note is in the frame's sound" "loudest $peak (no card: $peak_none); ${pairs:-?} samples in 25 s"
fi

# ----------------------------------------------------- 4. virtual time
# A host that stalls (20 ms before every frame, 6 s in all) does not move
# the machine: the clock the BIOS shows is the project's, not the host's.
native_run $xi --frames 300 --stall-ms 20 --digests "$work/stall.dig" > /dev/null
native_run $xi --frames 300 --digests "$work/nostall.dig" > /dev/null
if [ -s "$work/stall.dig" ] && cmp -s "$work/stall.dig" "$work/nostall.dig"; then
	report PASS "virtual time: a stalled host changes nothing" "300 frames, 20 ms stall before each"
else
	report FAIL "virtual time: a stalled host changes nothing" "see build/gate/stall.dig"
fi
# negative control: on the host's clock (as upstream reads it, the native
# build's CHIMERA_86BOX_HOST_CLOCK) two runs a second apart differ - the
# BIOS screen shows the time it was switched on at
CHIMERA_86BOX_HOST_CLOCK=1 native_run $xi --frames 600 --digests "$work/host1.dig" > /dev/null
sleep 1.2
CHIMERA_86BOX_HOST_CLOCK=1 native_run $xi --frames 600 --digests "$work/host2.dig" > /dev/null
if [ -s "$work/host1.dig" ] && ! cmp -s "$work/host1.dig" "$work/host2.dig"; then
	report PASS "virtual time: on the host's clock the runs differ" "negative control"
else
	report FAIL "virtual time: on the host's clock the runs differ" "they did not: the leg above is blind"
fi

# ------------------------------------------- 5. the sandbox is the same machine
"$rw" "$wbx" "$cfg" $xi $probe $input --frames 2500 --dump-ram "$work/probe-wbx.ram" --digests "$work/probe-wbx.dig" > "$work/probe-wbx.txt" 2> "$work/probe-wbx.err"
if [ -s "$work/probe-wbx.dig" ] && cmp -s "$work/probe-native.dig" "$work/probe-wbx.dig" \
   && cmp -s "$work/probe-native.ram" "$work/probe-wbx.ram" \
   && [ "$(sed 's/^end //' "$work/probe-native.txt" | tail -1)" = "$(sed 's/^end //' "$work/probe-wbx.txt" | tail -1)" ]; then
	report PASS "sandbox == native" "2500 frames: every frame's clock, cycles and picture; memory, sound at the end"
else
	report FAIL "sandbox == native" "see build/gate/probe-wbx.* and probe-native.*"
fi

# ---------------------------------------------------------- 6. states
"$rw" "$wbx" "$cfg" $xi $probe $input --frames 2500 --rerecord > "$work/rerecord.txt" 2> "$work/rerecord.err"
if [ "$(tail -1 "$work/rerecord.txt")" = "$(tail -1 "$work/probe-wbx.txt")" ]; then
	report PASS "states: save and load before every frame" "2500 frames end as the straight run"
else
	report FAIL "states: save and load before every frame" "see build/gate/rerecord.*"
fi
HARNESS_BREAK_STALE_STATE=1 "$rw" "$wbx" "$cfg" $xi $probe $input --frames 2500 --rerecord > "$work/stale.txt" 2> "$work/stale.err"
if grep -q '^end ' "$work/stale.txt" && [ "$(tail -1 "$work/stale.txt")" != "$(tail -1 "$work/probe-wbx.txt")" ]; then
	report PASS "states: a stale state is noticed" "negative control: frame 1249's state loaded at frame 1250"
else
	report FAIL "states: a stale state is noticed" "it was not: the leg above is blind"
fi
"$rw" "$wbx" "$cfg" $xi $probe $input --frames 2500 --save-state "$work/s2150.state" --at 2150 > "$work/session1.txt" 2>&1
"$rw" "$wbx" "$cfg" $xi $probe $input --frames 2500 --state "$work/s2150.state" > "$work/session2.txt" 2> "$work/session2.err"
if [ "$(tail -1 "$work/session2.txt")" = "$(tail -1 "$work/probe-wbx.txt")" ]; then
	report PASS "states: another process carries on from a state" "saved at frame 2150, ends as the straight run at 2500"
else
	report FAIL "states: another process carries on from a state" "see build/gate/session*"
fi


# ------------------------------------------------ 6a. the CD-ROM drive
# A disc made here (tests/cd: an ISO 9660 track and 5 s of a 1 kHz tone as
# an audio track, one cue), in an ATAPI drive on the XT-IDE card. The probe
# reads the table of contents and sector 16 and plays track 2; the machine
# has no sound card, so what is heard is the CD audio, which a thread of
# 86Box's used to make and patch 0007 makes in place. The tone's left
# channel peaks at 8000; at 44100 Hz it lasts 500 frames whatever the
# machine's own rate.
if ! command -v xorriso > /dev/null 2>&1; then
	report SKIP "CD-ROM: the disc is read and its audio heard" "needs xorriso to make the test disc"
elif ! sh "$root/tests/cd/make-cd.sh" "$work/cd" > "$work/cd.log" 2>&1; then
	report FAIL "CD-ROM: the disc is read and its audio heard" "$(tail -1 "$work/cd.log")"
else
	cdrun="$xi_base --set sound=none $probe --file cdrom=$work/cd/probe-cd.cue --file support=$work/cd/probe-cd.iso"
	cdrun="$cdrun --file support=$work/cd/probe-cd-tone.bin --frames 3000"
	native_run $cdrun --dump-ram "$work/cd-native.ram" --digests "$work/cd-native.dig" > "$work/cd-native.txt"
	native_run $xi_base --set sound=none $probe --file "cdrom=$work/cd/probe-cd.iso" --frames 2500 --dump-ram "$work/cd-iso.ram" > /dev/null
	cd_block() { python3 -c "import sys; d=open(sys.argv[1],'rb').read()[0x7e1c:0x7e2a]; print(d.hex())" "$1" 2>/dev/null; }
	blk=$(cd_block "$work/cd-native.ram"); blk_iso=$(cd_block "$work/cd-iso.ram")
	# the tone: its peak, how many of the main stream's 20 ms blocks hold it
	# (5 s: 250, every one of them, with no gap) and from the first to the last
	tone=$(awk '$5 > 7000 { if (!f) f = $1; l = $1; n++; if ($5 > m) m = $5 } END { print m + 0, n + 0, l - f }' "$work/cd-native.dig")
	quiet=$(awk '$1 > 1100 && $1 < 1500 && $5 > m { m = $5 } END { print m + 0 }' "$work/cd-native.dig")
	set -- $tone
	# status 50h, 01h "CD001", play 50h, TOC 50h, track 2 at sector 184 (the
	# ISO's length); the ISO alone: read, but no track 2 to play (51h, error)
	if [ "$blk" = 50000143443030315050000000b8 ] && [ "$blk_iso" = 50000143443030315150000000b8 ] \
	   && [ "$1" -ge 7900 ] && [ "$1" -le 8000 ] && [ "$2" -ge 249 ] && [ "$2" -le 251 ] \
	   && [ "$3" -ge $(($2 * 2 - 4)) ] && [ "$3" -le $(($2 * 2)) ] && [ "$quiet" = 0 ]; then
		report PASS "CD-ROM: the disc is read and its audio heard" "sector 16 reads CD001 (ISO and cue); track 2 at sector 184; the tone peaks at $1 in $2 blocks of 20 ms, no gap; silence before it"
	else
		report FAIL "CD-ROM: the disc is read and its audio heard" "block $blk, ISO $blk_iso, tone (peak, blocks, frames) $tone, before it $quiet"
	fi
	"$rw" "$wbx" "$cfg" $cdrun --digests "$work/cd-wbx.dig" > "$work/cd-wbx.txt" 2> "$work/cd-wbx.err"
	"$rw" "$wbx" "$cfg" $cdrun --rerecord > "$work/cd-rerecord.txt" 2> "$work/cd-rerecord.err"
	"$rw" "$wbx" "$cfg" $cdrun --save-state "$work/cd1800.state" --at 1800 > /dev/null 2>&1
	"$rw" "$wbx" "$cfg" $cdrun --state "$work/cd1800.state" > "$work/cd-session.txt" 2> "$work/cd-session.err"
	if [ -s "$work/cd-wbx.dig" ] && cmp -s "$work/cd-native.dig" "$work/cd-wbx.dig" \
	   && [ "$(tail -1 "$work/cd-rerecord.txt")" = "$(tail -1 "$work/cd-wbx.txt")" ] \
	   && [ "$(tail -1 "$work/cd-session.txt")" = "$(tail -1 "$work/cd-wbx.txt")" ]; then
		report PASS "CD-ROM: sandbox == native, and states" "3000 frames with the tone playing from about 1535: every frame the same; a state before every frame; a state at 1800 in another process"
	else
		report FAIL "CD-ROM: sandbox == native, and states" "see build/gate/cd-*"
	fi
fi

# ------------------------------------------------- 6b. a real system: FreeDOS
# FreeDOS 1.3's boot floppy (GPL; "FD13-FloppyEdition.zip", 144m/x86BOOT.img,
# from freedos.org), named by its SHA-1, on the free Xi 8088 at 4.77 MHz: it
# loads its kernel (about frame 2000), starts FreeCOM and the installer, and
# at frame 30000 asks "Do you want to proceed [Y,N]?". N is typed at 30000.
# The sandbox must give the native run's stream for all 31000 frames, and
# the picture with the N must not be the picture without it.
#   FREEDOS_FLOPPY   the path of that x86BOOT.img
fd="${FREEDOS_FLOPPY:-}"
fd_sha1=7f687f2d0b89ab2e4992b4800c89b8fb2c251a6a
if [ -z "$fd" ]; then
	report SKIP "FreeDOS boots and takes a key" "needs FREEDOS_FLOPPY (FreeDOS 1.3 FD13-FloppyEdition 144m/x86BOOT.img)"
elif [ "$(sha1sum "$fd" | cut -c1-40)" != "$fd_sha1" ]; then
	report FAIL "FreeDOS boots and takes a key" "FREEDOS_FLOPPY is not the 1.3 boot floppy (sha1 $fd_sha1)"
else
	fdos="--roms $roms --set machine=xi8088 --set video=cga --set memoryKB=640 --set floppyA=35_2hd --file floppy_a=$fd"
	native_run $fdos --frames 31000 --key 30000:5:48 --digests "$work/fdos-native.dig" --ppm "$work/fdos-n.ppm" > /dev/null
	native_run $fdos --frames 31000 --ppm "$work/fdos-nokey.ppm" > /dev/null
	"$rw" "$wbx" "$cfg" $fdos --frames 31000 --key 30000:5:48 --digests "$work/fdos-wbx.dig" > /dev/null 2>&1
	l_fd=$(lit "$work/fdos-n.ppm" 2>/dev/null || echo 0)
	if [ -s "$work/fdos-wbx.dig" ] && cmp -s "$work/fdos-native.dig" "$work/fdos-wbx.dig" && [ "${l_fd:-0}" -gt 5000 ] \
	   && ! cmp -s "$work/fdos-n.ppm" "$work/fdos-nokey.ppm"; then
		report PASS "FreeDOS boots and takes a key" "31000 frames, sandbox == native; the installer's question answered N"
	else
		report FAIL "FreeDOS boots and takes a key" "see build/gate/fdos-*"
	fi
fi

# --------------------------- 6c. FreeDOS from a hard disk, through the XTIDE BIOS
# The XTIDE Universal BIOS (GPL) the core carries, built from source for
# 86Box's XT-IDE card (waterbox/xtide-bios: upstream's XT build starts with
# an XT-CF card at 300h and does not find the drive; without
# MODULE_8BIT_IDE_ADVANCED it starts with the XT-IDE revision 1 that 86Box
# emulates). A 10 MB disk made here (tests/hdd-dos: our boot record, the
# floppy's FreeDOS boot code, kernel and shell, our AUTOEXEC.BAT). No floppy
# in the drive: the machine boots from the hard disk, and the shell sets
# HDBOOT to its own path. The negative control hands the card upstream's
# build instead, in the native build (CHIMERA_86BOX_NO_BUILTIN_ROMS).
if [ -z "$fd" ] || [ "$(sha1sum "$fd" | cut -c1-40)" != "$fd_sha1" ]; then
	report SKIP "FreeDOS starts from a hard disk" "needs FREEDOS_FLOPPY (as above)"
elif ! sh "$root/waterbox/xtide-bios/build.sh" "$XUB_SRC" "$work/xub" > "$work/xub.log" 2>&1 \
     || ! nasm -f bin "$root/tests/hdd-dos/mbr.asm" -o "$work/mbr.bin" > "$work/hdd-dos.log" 2>&1 \
     || ! python3 "$root/tests/hdd-dos/make-hdd.py" "$fd" "$work/mbr.bin" "$work/hdd-dos.img" >> "$work/hdd-dos.log" 2>&1; then
	report FAIL "FreeDOS starts from a hard disk" "$(tail -1 "$work/xub.log" "$work/hdd-dos.log" | tr '\n' ' ')"
else
	xroms="$work/xub-roms"; croms="$work/xub-control-roms"; mkdir -p "$xroms" "$croms"
	cp "$roms/machines_xi8088_bios-xi8088-128k.bin" "$roms/video_mda_mda.rom" "$xroms/"
	cp "$roms/machines_xi8088_bios-xi8088-128k.bin" "$roms/video_mda_mda.rom" "$croms/"
	cp "$work/xub/ide_xt_upstream_default.bin" "$croms/hdd_xtide_ide_xt.bin"
	hdos="--set machine=xi8088 --set video=cga --set memoryKB=640 --set floppyA=525_2dd --set hardDiskController=xtide"
	hdos="$hdos --file hdd=$work/hdd-dos.img --frames 3000"
	native_run --roms "$xroms" $hdos --digests "$work/hdos-native.dig" --dump-ram "$work/hdos-native.ram" --ppm "$work/hdos-native.ppm" > /dev/null
	CHIMERA_86BOX_NO_BUILTIN_ROMS=1 native_run --roms "$croms" $hdos --dump-ram "$work/hdos-control.ram" --ppm "$work/hdos-control.ppm" > /dev/null
	"$rw" "$wbx" "$cfg" --roms "$xroms" $hdos --digests "$work/hdos-wbx.dig" > /dev/null 2>&1
	booted=$(grep -a -c 'HDBOOT=C:\\COMMAND.COM' "$work/hdos-native.ram" 2>/dev/null)
	control=$(grep -a -c 'HDBOOT=C:\\COMMAND.COM' "$work/hdos-control.ram" 2>/dev/null)
	if [ "${booted:-0}" -ge 1 ] && [ "${control:-1}" = 0 ] && [ "$(wc -l < "$work/hdos-native.dig")" -eq 3000 ] \
	   && cmp -s "$work/hdos-native.dig" "$work/hdos-wbx.dig"; then
		report PASS "FreeDOS starts from a hard disk" "the carried XUB r638 finds the drive at 300h, the shell runs from C: (HDBOOT=C:\\COMMAND.COM); upstream's XT build: not found; 3000 frames, sandbox == native"
	else
		report FAIL "FreeDOS starts from a hard disk" "marker ${booted:-0}, control ${control:-?}; see build/gate/hdos-*"
	fi
	# What FreeDOS writes to C: is kept: through a project, Export Save Data
	# gives the disk back with C:\WROTE.TXT in it, and the project's file is
	# unchanged.
	crun="$chimera_root/build/dll/chimera-run"
	hp="$work/hdd-project"; mkdir -p "$hp"; cp "$work/hdd-dos.img" "$hp/"
	python3 "$here/tests/make-movie.py" "$pkg" 3000 > "$hp/movie.txt"
	fwb=machines_xi8088_bios-xi8088-128k.bin; fwf=video_mda_mda.rom
	if [ ! -x "$crun" ]; then
		report SKIP "FreeDOS's writes to C: are kept" "no chimera-run at $crun"
	elif "$crun" --new-project "$hp/p.chimeraProject" "$pkg" --file "hdd=$hp/hdd-dos.img" --movie "$hp/movie.txt" \
		--settings '{"machine": "xi8088 - [8088] Xi8088", "video": "cga - IBM CGA", "memoryKB": 640, "hardDiskController": "xtide - PC/XT XTIDE"}' \
		--firmware "$fwb=$xroms/$fwb" --firmware "$fwf=$xroms/$fwf" > "$hp/make.log" 2>&1 \
	   && "$crun" --project "$hp/p.chimeraProject" "$pkg" --firmware "$fwb=$xroms/$fwb" --firmware "$fwf=$xroms/$fwf" \
		--frames 3000 --export-savedata "$hp/export" > "$hp/run.log" 2>&1 \
	   && [ "$(python3 "$root/tests/hdd-dos/make-hdd.py" --read "$hp/export/hdd-dos.img" WROTE.TXT 2>/dev/null | tr -d "\r")" = "written by FreeDOS on the hard disk" ] \
	   && cmp -s "$hp/hdd-dos.img" "$work/hdd-dos.img"; then
		report PASS "FreeDOS's writes to C: are kept" "chimera-run --export-savedata: C:\\WROTE.TXT in the exported disk; the project's file unchanged"
	else
		report FAIL "FreeDOS's writes to C: are kept" "no C:\\WROTE.TXT in the exported disk, or the project's file changed; see build/gate/hdd-project"
	fi
fi

# ------------------------------------------- 8. IBM's machines, with IBM's ROMs
# The ROM set of 86Box (https://github.com/86Box/roms, tag v6.0), which the
# owner supplies for local tests and which is never on a public runner:
#   PCBOX_ROMS   the folder of that set (it holds machines/, video/, ...)
# The gate copies the files the package declares out of it, each checked
# against the SHA-1 the package pins (tools/pin-roms.py --copy), and runs
# IBM's own machines with IBM's own BIOS: the IBM PC (1981 and 1982), the XT
# and the AT. The character ROM is IBM's here, not the free stand-in.
pr="${PCBOX_ROMS:-}"
if [ -z "$pr" ]; then
	report SKIP "IBM machines: their BIOS runs" "needs PCBOX_ROMS (the ROM set of 86Box, tag v6.0)"
	report SKIP "IBM machines: FreeDOS from a floppy" "needs PCBOX_ROMS and FREEDOS_FLOPPY"
	report SKIP "IBM AT: FreeDOS from its XT-IDE card" "needs PCBOX_ROMS and FREEDOS_FLOPPY"
	report SKIP "IBM AT: the CMOS is set from the settings" "needs PCBOX_ROMS and FREEDOS_FLOPPY"
	report SKIP "IBM video cards draw with IBM's ROMs" "needs PCBOX_ROMS"
elif ! python3 "$root/tools/pin-roms.py" --copy "$cfg" "$pr" "$work/ibm-roms" > "$work/ibm-roms.log" 2>&1; then
	report FAIL "IBM machines: their BIOS runs" "$(tail -1 "$work/ibm-roms.log")"
else
	ir="$work/ibm-roms"
	# The BIOS's POST counts the memory and leaves it at 0040:0013 (the PC's
	# 1981 BIOS reads four memory switches, which say at most 544 KB); the
	# picture is lit. The PC, XT and AT go into IBM's cassette BASIC with no
	# disk (the AT's clock memory, its CMOS, is written from the settings at
	# power-on, so it no longer stops at "161-System Options Not Set"). And
	# the BASIC file is asked for by name while cassette BASIC is on, and not
	# when it is off.
	ok=""; bad=""
	for spec in ibmpc:544 ibmpc82:640 ibmxt:640 ibmat:512; do
		m=${spec%:*}; kb=${spec#*:}
		native_run --roms "$ir" --set machine=$m --set video=cga --set memoryKB=$kb --frames 9000 \
			--dump-ram "$work/ibm-$m.ram" --ppm "$work/ibm-$m.ppm" > /dev/null
		got=$(word_at "$work/ibm-$m.ram" 413 2>/dev/null); l=$(lit "$work/ibm-$m.ppm" 2>/dev/null || echo 0)
		if [ "$got" = "$kb" ] && [ "${l:-0}" -gt 1000 ]; then ok="$ok $m:${got}KB"; else bad="$bad $m:${got:-?}KB,lit=$l"; fi
	done
	mkdir -p "$work/ibm-nobasic"; cp "$ir"/* "$work/ibm-nobasic/"; rm "$work/ibm-nobasic/machines_ibmpc_ibm-basic-1.00.rom"
	r_basic=$(refusal --roms "$work/ibm-nobasic" --set machine=ibmpc --set video=cga)
	r_nob=$(refusal --roms "$work/ibm-nobasic" --set machine=ibmpc --set video=cga --set cassetteBasic=false)
	# (86Box also looks for the four chips' files when the one file is not
	# there, and the refusal names everything it looked for)
	if [ -z "$bad" ] && [ "${r_basic%%, *}" = "error.roms_missing|[8088] IBM PC (1981)|machines_ibmpc_ibm-basic-1.00.rom" ] && [ -z "$r_nob" ]; then
		report PASS "IBM machines: their BIOS runs" "memory the BIOS counted:$ok; the PC without its BASIC file is refused by name, and runs with cassette BASIC off"
	else
		report FAIL "IBM machines: their BIOS runs" "${bad:-} [$r_basic] [$r_nob]"
	fi

	# FreeDOS on each, from a 360 KB floppy the gate makes out of FreeDOS
	# 1.3's boot floppy (its kernel and shell, and an AUTOEXEC.BAT that sets
	# FDBOOT to the shell's path): the IBM PC and XT cannot read the 1.44 MB
	# floppy. No key is pressed on any of them. The sandbox must give the
	# native run's stream on every machine.
	if [ -z "$fd" ] || [ "$(sha1sum "$fd" | cut -c1-40)" != "$fd_sha1" ]; then
		report SKIP "IBM machines: FreeDOS from a floppy" "needs FREEDOS_FLOPPY (FreeDOS 1.3 FD13-FloppyEdition 144m/x86BOOT.img)"
		report SKIP "IBM AT: FreeDOS from its XT-IDE card" "needs FREEDOS_FLOPPY"
		report SKIP "IBM AT: the CMOS is set from the settings" "needs FREEDOS_FLOPPY"
	else
		python3 "$root/tests/dos-disk/make-dos-disk.py" --freedos "$fd" --out "$work/fd360.img" --floppy 360 \
			--autoexec '@echo off\nset FDBOOT=%COMSPEC%\necho FreeDOS started from a 360 KB floppy.\n' > "$work/fd360.log" 2>&1
		ok=""; bad=""
		for spec in ibmpc:544 ibmpc82:640 ibmxt:640 ibmat:512; do
			m=${spec%:*}; kb=${spec#*:}
			run="--roms $ir --set machine=$m --set video=cga --set memoryKB=$kb --set floppyA=525_2dd --file floppy_a=$work/fd360.img --frames 12000"
			native_run $run --dump-ram "$work/fd-$m.ram" --digests "$work/fd-$m-native.dig" > /dev/null
			"$rw" "$wbx" "$cfg" $run --digests "$work/fd-$m-wbx.dig" > /dev/null 2>&1
			marker=$(grep -a -c 'FDBOOT=A:\\COMMAND.COM' "$work/fd-$m.ram" 2>/dev/null)
			if [ "${marker:-0}" -ge 1 ] && [ "$(wc -l < "$work/fd-$m-native.dig")" -eq 12000 ] \
			   && cmp -s "$work/fd-$m-native.dig" "$work/fd-$m-wbx.dig"; then ok="$ok $m"; else bad="$bad $m(marker ${marker:-0})"; fi
		done
		if [ -z "$bad" ]; then
			report PASS "IBM machines: FreeDOS from a floppy" "FDBOOT=A:\\COMMAND.COM in memory by frame 12000 on$ok; sandbox == native on each"
		else
			report FAIL "IBM machines: FreeDOS from a floppy" "failed:$bad; see build/gate/fd-*"
		fi

		# The AT card's XTIDE Universal BIOS, the core's, on the IBM AT: the
		# hard disk FreeDOS starts from on the Xi 8088 (6c) starts it here.
		# Control: the AT with the carried ROM turned off (native build only)
		# and no file of that name does not.
		if [ -f "$work/hdd-dos.img" ]; then
			atd="--set machine=ibmat --set video=cga --set floppyA=525_2dd --set hardDiskController=xtide_at_1ch"
			atd="$atd --file hdd=$work/hdd-dos.img --frames 8000"
			native_run --roms "$ir" $atd --dump-ram "$work/athd.ram" --digests "$work/athd-native.dig" > /dev/null
			CHIMERA_86BOX_NO_BUILTIN_ROMS=1 native_run --roms "$ir" $atd --dump-ram "$work/athd-control.ram" > /dev/null
			"$rw" "$wbx" "$cfg" --roms "$ir" $atd --digests "$work/athd-wbx.dig" > /dev/null 2>&1
			b=$(grep -a -c 'HDBOOT=C:\\COMMAND.COM' "$work/athd.ram" 2>/dev/null); c=$(grep -a -c 'HDBOOT=C:\\COMMAND.COM' "$work/athd-control.ram" 2>/dev/null)
			if [ "${b:-0}" -ge 1 ] && [ "${c:-1}" = 0 ] && cmp -s "$work/athd-native.dig" "$work/athd-wbx.dig"; then
				report PASS "IBM AT: FreeDOS from its XT-IDE card" "the carried AT build of XUB r638 starts FreeDOS from C: (HDBOOT=C:\\COMMAND.COM); without it: no; 8000 frames, sandbox == native"
			else
				report FAIL "IBM AT: FreeDOS from its XT-IDE card" "marker ${b:-0}, control ${c:-?}; see build/gate/athd-*"
			fi
		else
			report SKIP "IBM AT: FreeDOS from its XT-IDE card" "the hard disk of 6c was not made"
		fi

		# The CMOS is written from the settings at power-on (patch 0009,
		# chimera_cmos_power_on): an IBM AT told it has a 1.44 MB drive A
		# starts FreeDOS from a 1.44 MB floppy with no key pressed, and its
		# CMOS holds the drive (0x10 = 40h), one drive and CGA (0x14 = 21h),
		# 512 KB of base memory and no extended (0x15-0x18), and their
		# checksum (0x2E-0x2F). Control, the native build only: with the CMOS
		# left empty (CHIMERA_86BOX_EMPTY_CMOS) the same run stops at "161"
		# and FreeDOS does not start. The sandbox gives the native stream.
		python3 "$root/tests/dos-disk/make-dos-disk.py" --freedos "$fd" --out "$work/at1440.img" --floppy 1440 \
			--autoexec '@echo off\nset FDBOOT=%COMSPEC%\necho FreeDOS started from a 1.44 MB floppy.\n' > "$work/at1440.log" 2>&1
		atc="--roms $ir --set machine=ibmat --set video=cga --set memoryKB=512 --set floppyA=35_2hd --file floppy_a=$work/at1440.img --frames 6000"
		native_run $atc --dump-ram "$work/atc.ram" --dump-cmos "$work/atc.cmos" --digests "$work/atc-native.dig" > /dev/null
		CHIMERA_86BOX_EMPTY_CMOS=1 native_run $atc --dump-ram "$work/atc-empty.ram" --dump-cmos "$work/atc-empty.cmos" > /dev/null
		"$rw" "$wbx" "$cfg" $atc --digests "$work/atc-wbx.dig" > /dev/null 2>&1
		cm=$(python3 - "$work/atc.cmos" <<'PY'
import sys
c = open(sys.argv[1], 'rb').read()
want = {0x10: 0x40, 0x12: 0, 0x14: 0x21, 0x15: 0x00, 0x16: 0x02, 0x17: 0, 0x18: 0}
bad = ['%02X=%02X' % (k, c[k]) for k, v in want.items() if len(c) < 0x30 or c[k] != v]
s = sum(c[0x10:0x2e]) if len(c) >= 0x30 else -1
if len(c) >= 0x30 and (c[0x2e] << 8 | c[0x2f]) != s:
    bad.append('checksum %02X%02X, not %04X' % (c[0x2e], c[0x2f], s))
print(' '.join(bad) if bad else 'ok')
PY
)
		em=$(python3 -c "import sys; c=open(sys.argv[1],'rb').read(); print('empty' if len(c) >= 0x30 and set(c[0x10:0x2e]) == {0xff} else 'written')" "$work/atc-empty.cmos" 2>/dev/null)
		b=$(grep -a -c 'FDBOOT=A:\\COMMAND.COM' "$work/atc.ram" 2>/dev/null); c=$(grep -a -c 'FDBOOT=A:\\COMMAND.COM' "$work/atc-empty.ram" 2>/dev/null)
		if [ "$cm" = ok ] && [ "${b:-0}" -ge 1 ] && [ "$em" = empty ] && [ "${c:-1}" = 0 ] && cmp -s "$work/atc-native.dig" "$work/atc-wbx.dig"; then
			report PASS "IBM AT: the CMOS is set from the settings" "FreeDOS from a 1.44 MB floppy by frame 6000, no key pressed; CMOS drive, equipment, memory and checksum as the settings say; left empty: no FreeDOS; sandbox == native"
		else
			report FAIL "IBM AT: the CMOS is set from the settings" "CMOS: $cm; marker ${b:-0}; empty control: ${em:-?}, marker ${c:-?}; see build/gate/atc*"
		fi
	fi

	# Each video card draws, with IBM's ROMs: the character ROM for MDA,
	# Hercules and CGA, the EGA's and the VGA's own BIOS - and EGA and VGA
	# without the character ROM, which 86Box reads for every card but which
	# only the first three draw with. Each picture is the card's size and
	# lit. Control: the EGA given 16 KB of zeros as its BIOS draws nothing.
	ok=""; bad=""
	mkdir -p "$work/ibm-nofont"; cp "$ir"/* "$work/ibm-nofont/"; rm "$work/ibm-nofont/video_mda_mda.rom"
	for spec in ibmxt:mda:720x350 ibmxt:hercules:720x350 ibmxt:cga:640x200 ibmat:ega:640x350 ibmat:vga:720x400; do
		m=${spec%%:*}; rest=${spec#*:}; v=${rest%%:*}; size=${rest#*:}
		vr="$ir"; case $v in ega|vga) vr="$work/ibm-nofont" ;; esac
		native_run --roms "$vr" --set machine=$m --set video=$v --frames 3000 --ppm "$work/vid-$v.ppm" > "$work/vid-$v.txt"
		got=$(grep -o 'video=[0-9x]*' "$work/vid-$v.txt" | cut -d= -f2); l=$(lit "$work/vid-$v.ppm" 2>/dev/null || echo 0)
		if [ "$got" = "$size" ] && [ "${l:-0}" -gt 1000 ]; then ok="$ok $v:$got"; else bad="$bad $v:${got:-?},lit=$l"; fi
	done
	mkdir -p "$work/ega-zero"; cp "$ir"/machines_ibmat_* "$work/ega-zero/"
	head -c 16384 /dev/zero > "$work/ega-zero/video_ega_ibm_6277356_ega_card_u44_27128.bin"
	native_run --roms "$work/ega-zero" --set machine=ibmat --set video=ega --frames 3000 --ppm "$work/vid-ega-zero.ppm" > /dev/null
	l0=$(lit "$work/vid-ega-zero.ppm" 2>/dev/null || echo x)
	if [ -z "$bad" ] && [ "$l0" = 0 ]; then
		report PASS "IBM video cards draw with IBM's ROMs" "$ok, each lit (EGA and VGA with no character ROM); the EGA with a BIOS of zeros: 0 lit pixels"
	else
		report FAIL "IBM video cards draw with IBM's ROMs" "${bad:-} EGA with zeros: $l0 lit"
	fi
fi

# ------------------------------------------- 9. a real game: Kingdom of Kroz II
# Kingdom of Kroz II (Apogee, 1990, freeware since 2009), from its own
# archive, 1kroz.zip (its INSTALL.BAT, DEICE.EXE, KROZ.DAT, KROZ.1):
#   PCBOX_KROZ   the path of that zip (SHA-1 below)
# On an IBM XT with IBM's BIOS (PCBOX_ROMS), 640 KB, CGA, and the XT-IDE
# card with the XTIDE Universal BIOS the core carries: a 10 MB hard disk made
# here holds FreeDOS (FREEDOS_FLOPPY) and the archive in C:\KRZINST. The
# movie (tests/games/kroz.keys, then kroz-play.keys) types INSTALL at
# FreeDOS's prompt, answers DEICE (drive C, folder \KROZ, create it), lets
# PKSFX unpack the game, starts KINGDOM, answers its questions, and plays
# the first level: four steps right and two up, and the player moves.
kz="${PCBOX_KROZ:-}"
kz_sha1=6f9fcb068feb9160261741b15f1df0f163fbf2a9
if [ -z "$kz" ] || [ -z "$pr" ] || [ -z "$fd" ] || [ ! -d "${ir:-/nonexistent}" ] || [ ! -f "$work/mbr.bin" ]; then
	report SKIP "Kroz: installed in DOS and played" "needs PCBOX_KROZ (1kroz.zip), PCBOX_ROMS and FREEDOS_FLOPPY"
	report SKIP "Kroz: the movie through chimera-run" "needs PCBOX_KROZ, PCBOX_ROMS and FREEDOS_FLOPPY"
elif [ "$(sha1sum "$kz" | cut -c1-40)" != "$kz_sha1" ]; then
	report FAIL "Kroz: installed in DOS and played" "PCBOX_KROZ is not 1kroz.zip (sha1 $kz_sha1)"
else
	kd="$work/kroz"; mkdir -p "$kd"
	python3 "$root/tests/dos-disk/make-dos-disk.py" --freedos "$fd" --out "$kd/kroz-hd.img" --hdd 306:4:17 \
		--mbr "$work/mbr.bin" --autoexec '@echo off\n' --put-zip "KRZINST=$kz" > "$kd/disk.log" 2>&1
	setup=$(python3 "$root/tests/keys.py" "$here/chimera-input.c" "$root/tests/games/kroz.keys")
	play=$(python3 "$root/tests/keys.py" "$here/chimera-input.c" "$root/tests/games/kroz-play.keys")
	krun="--roms $ir --set machine=ibmxt --set video=cga --set memoryKB=640 --set floppyA=525_2dd"
	krun="$krun --set hardDiskController=xtide --file hdd=$kd/kroz-hd.img --frames 18900"
	native_run $krun $setup $play --ppm "$kd/level.ppm" --ppm-at 18250 --digests "$kd/native.dig" --dump-ram "$kd/native.ram" > /dev/null
	cp "$work/n$n.err" "$kd/native.err"
	native_run $krun $setup --ppm "$kd/still.ppm" > /dev/null
	native_run $krun $setup $play --ppm "$kd/played.ppm" > /dev/null
	"$rw" "$wbx" "$cfg" $krun $setup $play --digests "$kd/wbx.dig" --dump-ram "$kd/wbx.ram" > "$kd/wbx.txt" 2> "$kd/wbx.err"
	# where the player is: the centre of the play field's pixels of its
	# yellow (CGA's bright yellow as 86Box draws it), with the six steps and
	# in the run that stood still
	player() { python3 - "$1" <<'PY'
import sys
d = open(sys.argv[1], 'rb').read().split(b'\n', 3)
w = int(d[1].split()[0])
pts = [(x, y) for y in range(8, 176) for x in range(520) if d[3][(y * w + x) * 3:(y * w + x) * 3 + 3] == b'\xf3\xf3\x4e']
print(sum(x for x, y in pts) // len(pts), sum(y for x, y in pts) // len(pts))
PY
}
	set -- $(player "$kd/still.ppm" 2>/dev/null) $(player "$kd/played.ppm" 2>/dev/null)
	moved=""
	[ $# -eq 4 ] && [ "$3" -ge $(($1 + 5)) ] && [ "$4" -le $(($2 - 5)) ] && moved="($1,$2) to ($3,$4)"
	l_level=$(lit "$kd/level.ppm" 2>/dev/null || echo 0)
	if [ "${l_level:-0}" -gt 20000 ] && [ -n "$moved" ] \
	   && [ -s "$kd/wbx.dig" ] && cmp -s "$kd/native.dig" "$kd/wbx.dig" && cmp -s "$kd/native.ram" "$kd/wbx.ram"; then
		report PASS "Kroz: installed in DOS and played" "level 1 at frame 18250 ($l_level lit pixels); the steps move the player right and up, $moved; 18900 frames, sandbox == native, memory and card memory"
	else
		report FAIL "Kroz: installed in DOS and played" "level $l_level lit, player [$*]; see build/gate/kroz"
	fi
	# The movie: the same input as a movie in a project, run by chimera-run,
	# and replayed by a second chimera-run in a new process; both end with the
	# sandbox runner's memory, and the disk Export Save Data gives back holds
	# the game the installer wrote (C:\KROZ\KINGDOM.EXE).
	crun="$chimera_root/build/dll/chimera-run"
	if [ ! -x "$crun" ]; then
		report SKIP "Kroz: the movie through chimera-run" "no chimera-run at $crun"
	else
		kp="$kd/project"; mkdir -p "$kp"; cp "$kd/kroz-hd.img" "$kp/"
		python3 "$here/tests/make-movie.py" "$pkg" 18900 $setup $play > "$kp/movie.txt"
		fw=""
		for f in machines_ibmxt_BIOS_5160_08NOV82_U18_1501512.BIN machines_ibmxt_BIOS_5160_08NOV82_U19_5000027.BIN video_mda_mda.rom; do
			fw="$fw --firmware $f=$ir/$f"
		done
		"$crun" --new-project "$kp/kroz.chimeraProject" "$pkg" --file "hdd=$kp/kroz-hd.img" --movie "$kp/movie.txt" \
			--settings '{"machine": "ibmxt - [8088] IBM XT (1982)", "video": "cga - IBM CGA", "memoryKB": 640, "hardDiskController": "xtide - PC/XT XTIDE"}' \
			$fw > "$kp/make.log" 2>&1
		for run in 1 2; do
			"$crun" --project "$kp/kroz.chimeraProject" "$pkg" $fw --frames 18900 --dump "System RAM=$kp/ram$run.bin" \
				--dump "Memory Card RAM=$kp/card$run.bin" --export-savedata "$kp/export$run" > "$kp/run$run.log" 2>&1
		done
		cat "$kp/ram1.bin" "$kp/card1.bin" > "$kp/all1.bin" 2>/dev/null
		kex=$(python3 "$root/tests/dos-disk/make-dos-disk.py" --read "$kp/export1/kroz-hd.img" 'KROZ\KINGDOM.EXE' 2>/dev/null | wc -c)
		if [ -s "$kp/ram1.bin" ] && cmp -s "$kp/ram1.bin" "$kp/ram2.bin" && cmp -s "$kp/card1.bin" "$kp/card2.bin" \
		   && cmp -s "$kp/all1.bin" "$kd/wbx.ram" && [ "${kex:-0}" -gt 10000 ] && cmp -s "$kp/kroz-hd.img" "$kd/kroz-hd.img"; then
			report PASS "Kroz: the movie through chimera-run" "18900 frames twice, in two processes: the same memory, and the sandbox runner's; the exported disk holds C:\\KROZ\\KINGDOM.EXE ($kex bytes); the project's file unchanged"
		else
			report FAIL "Kroz: the movie through chimera-run" "see build/gate/kroz/project ($(tail -1 "$kp/run1.log" | cut -c1-100))"
		fi
	fi
fi

# ------------------------------------- 10. a 486 and a Pentium: the recompiler
# The ASUS PCI/I-486SP3 (a 486DX2 at 66 MHz, Award BIOS 4.50) and the ASUS
# P/I-P55T2P4 (a Pentium at 133 MHz, Award BIOS 4.51PG), with their own
# BIOS from the ROM set (PCBOX_ROMS), 16 MB, IBM VGA. 86Box's recompiler
# runs a 386-class processor and up; the setting "recompiler" chooses it or
# the interpreter, two machines. Each board starts FreeDOS from a 1.44 MB
# floppy made here, with each, natively and in the sandbox. No key is
# pressed: the core writes the CMOS each board's own BIOS writes when it
# loads its defaults (its settings block past the standard bytes, with the
# block's own checksums, and its defaults for the standard bytes the
# settings do not decide), recorded by tools/record-award-cmos.py into
# waterbox/award-cmos.h, then the standard bytes from the settings; so the
# BIOS does not stop at "CMOS checksum error" to wait for F1. The CMOS after
# each run must hold the recorded block, and with the block left out
# (CHIMERA_86BOX_NO_AWARD_CMOS, the native build only) FreeDOS must not
# start: the leg fails if the core stops writing it.
if [ -z "$pr" ] || [ -z "$fd" ] || [ ! -d "${ir:-/nonexistent}" ]; then
	report SKIP "Award boards: the CMOS block is recorded again" "needs PCBOX_ROMS and FREEDOS_FLOPPY"
	report SKIP "486 and Pentium: FreeDOS, both ways" "needs PCBOX_ROMS and FREEDOS_FLOPPY"
	report SKIP "486 and Pentium: states, recompiler on" "needs PCBOX_ROMS and FREEDOS_FLOPPY"
else
	pd="$work/pc32"; mkdir -p "$pd"
	# The tool that made waterbox/award-cmos.h, run again on the boards' own
	# BIOS files: it must record the same bytes.
	if python3 "$root/tools/record-award-cmos.py" --runner "$rn" --roms "$ir" --check "$here/award-cmos.h" > "$pd/record.log" 2>&1; then
		report PASS "Award boards: the CMOS block is recorded again" "$(tail -1 "$pd/record.log")"
	else
		report FAIL "Award boards: the CMOS block is recorded again" "$(tail -1 "$pd/record.log")"
	fi
	python3 "$root/tests/dos-disk/make-dos-disk.py" --freedos "$fd" --out "$pd/fd1440.img" --floppy 1440 \
		--autoexec '@echo off\nset FDBOOT=%COMSPEC%\necho FreeDOS started from a 1.44 MB floppy.\n' > "$pd/disk.log" 2>&1
	ok=""; bad=""
	for spec in 486sp3:i486dx2/66666666 p55t2p4:pentium_p54c/133333333; do
		m=${spec%%:*}; cpu=${spec#*:}
		for r in false true; do
			brun="--roms $ir --set machine=$m --set cpu=$cpu --set video=vga --set memoryKB=16384 --set recompiler=$r"
			brun="$brun --set floppyA=35_2hd --file floppy_a=$pd/fd1440.img --frames 3000"
			t0=$(date +%s%N)
			native_run $brun --dump-ram "$pd/$m-$r.ram" --dump-cmos "$pd/$m-$r.cmos" --digests "$pd/$m-$r-native.dig" > /dev/null
			secs=$(( ($(date +%s%N) - t0) / 1000000000 ))
			"$rw" "$wbx" "$cfg" $brun --digests "$pd/$m-$r-wbx.dig" > /dev/null 2> "$pd/$m-$r-wbx.err"
			marker=$(grep -a -c 'FDBOOT=A:\\COMMAND.COM' "$pd/$m-$r.ram" 2>/dev/null)
			blk=$(python3 "$here/tests/award-block.py" "$here/award-cmos.h" "$pd/$m-$r.cmos" $m 2>&1)
			if [ "${marker:-0}" -ge 1 ] && [ "$blk" = ok ] && [ "$(wc -l < "$pd/$m-$r-native.dig")" -eq 3000 ] \
			   && cmp -s "$pd/$m-$r-native.dig" "$pd/$m-$r-wbx.dig"; then ok="$ok $m/$([ $r = true ] && echo recompiler || echo interpreter):${secs}s"
			else bad="$bad $m/$r(marker ${marker:-0}, CMOS block: $blk)"; fi
		done
		# the two are two machines: their streams differ
		cmp -s "$pd/$m-false-native.dig" "$pd/$m-true-native.dig" && bad="$bad $m(interpreter and recompiler gave one stream: is the setting read?)"
		# control: the block left out, the BIOS waits for F1 and FreeDOS does not start
		CHIMERA_86BOX_NO_AWARD_CMOS=1 native_run --roms "$ir" --set machine=$m --set cpu=$cpu --set video=vga --set memoryKB=16384 \
			--set floppyA=35_2hd --file "floppy_a=$pd/fd1440.img" --frames 3000 --dump-ram "$pd/$m-noblock.ram" > /dev/null
		c=$(grep -a -c 'FDBOOT=A:\\COMMAND.COM' "$pd/$m-noblock.ram" 2>/dev/null)
		[ "${c:-1}" = 0 ] || bad="$bad $m(FreeDOS started without the Award block: ${c:-?})"
	done
	if [ -z "$bad" ]; then
		report PASS "486 and Pentium: FreeDOS, both ways" "no key pressed: FDBOOT=A:\\COMMAND.COM by frame 3000, the recorded CMOS block in place, sandbox == native, each:$ok (native, host time); without the block: no FreeDOS; interpreter and recompiler streams differ"
	else
		report FAIL "486 and Pentium: FreeDOS, both ways" "failed:$bad; see build/gate/pc32"
	fi
	# States with the recompiler on, where the machine is tens of MB: saved
	# and loaded before every frame from 2500 to 3000 (FreeDOS running), the
	# run ends as the straight one; a state saved at 2900 carries on in
	# another process; a stale state loaded once is noticed (control).
	ok=""; bad=""
	for spec in 486sp3:i486dx2/66666666 p55t2p4:pentium_p54c/133333333; do
		m=${spec%%:*}; cpu=${spec#*:}
		brun="--roms $ir --set machine=$m --set cpu=$cpu --set video=vga --set memoryKB=16384 --set recompiler=true"
		brun="$brun --set floppyA=35_2hd --file floppy_a=$pd/fd1440.img --frames 3000"
		"$rw" "$wbx" "$cfg" $brun > "$pd/$m-straight.txt" 2>&1
		"$rw" "$wbx" "$cfg" $brun --rerecord-from 2500 > "$pd/$m-rerecord.txt" 2>&1
		HARNESS_BREAK_STALE_STATE=1 "$rw" "$wbx" "$cfg" $brun --rerecord-from 2500 > "$pd/$m-stale.txt" 2>&1
		"$rw" "$wbx" "$cfg" $brun --save-state "$pd/$m.state" --at 2900 > "$pd/$m-save.txt" 2>&1
		"$rw" "$wbx" "$cfg" $brun --state "$pd/$m.state" > "$pd/$m-session.txt" 2>&1
		end=$(grep '^end ' "$pd/$m-straight.txt")
		size=$(sed -n 's/^saved frame=[0-9]* bytes=\([0-9]*\).*/\1/p' "$pd/$m-save.txt")
		if [ -n "$end" ] && [ "$(grep '^end ' "$pd/$m-rerecord.txt")" = "$end" ] && [ "$(grep '^end ' "$pd/$m-session.txt")" = "$end" ] \
		   && grep -q '^end ' "$pd/$m-stale.txt" && [ "$(grep '^end ' "$pd/$m-stale.txt")" != "$end" ]; then
			ok="$ok $m:$((${size:-0} / 1048576))MB"
		else
			bad="$bad $m"
		fi
	done
	if [ -z "$bad" ]; then
		report PASS "486 and Pentium: states, recompiler on" "a state before every frame 2500-3000 and one carried to another process end as the straight run; a stale one is noticed; state sizes:$ok"
	else
		report FAIL "486 and Pentium: states, recompiler on" "failed:$bad; see build/gate/pc32"
	fi
fi

# ------------------------------------------- 11. Doom, on the Pentium
# Doom v1.9 shareware (id Software, 1995), from its own archive,
# doom19s.zip (INSTALL.BAT, DEICE.EXE, DOOMS_19.DAT, DOOMS_19.1 and .2):
#   PCBOX_DOOM   the path of that zip (SHA-1 below)
# On the P/I-P55T2P4 with the recompiler, 16 MB, IBM VGA, no sound card,
# and a 30 MB hard disk made here on the board's IDE port: FreeDOS and the
# archive in C:\DMINST. The movie (tests/games/doom.keys) installs it with
# DEICE inside DOS, answers SETUP, and starts a new game: E1M1, whose map
# (Tab) names the level in red at its foot. No key is pressed for the BIOS:
# the core writes the board's recorded CMOS (section 10), whose hard disk
# types are the BIOS's own "detect". The same input with the
# interpreter reaches the same place; and as a movie in a project,
# chimera-run gives back the disk with the game the installer wrote.
dm="${PCBOX_DOOM:-}"
dm_sha1=8d0fbbbeba5ecb692a99f97e55dfb5365cfe5b77
if [ -z "$dm" ] || [ -z "$pr" ] || [ -z "$fd" ] || [ ! -d "${ir:-/nonexistent}" ] || [ ! -f "$work/mbr.bin" ]; then
	report SKIP "Doom: installed in DOS, to E1M1" "needs PCBOX_DOOM (doom19s.zip), PCBOX_ROMS and FREEDOS_FLOPPY"
	report SKIP "Doom: the movie through chimera-run" "needs PCBOX_DOOM, PCBOX_ROMS and FREEDOS_FLOPPY"
elif [ "$(sha1sum "$dm" | cut -c1-40)" != "$dm_sha1" ]; then
	report FAIL "Doom: installed in DOS, to E1M1" "PCBOX_DOOM is not doom19s.zip (sha1 $dm_sha1)"
else
	dd="$work/doom"; mkdir -p "$dd"
	python3 "$root/tests/dos-disk/make-dos-disk.py" --freedos "$fd" --out "$dd/doom-hd.img" --hdd 61:16:63 \
		--cluster 16 --mbr "$work/mbr.bin" --autoexec '@echo off\n' --put-zip "DMINST=$dm" > "$dd/disk.log" 2>&1
	keys=$(python3 "$root/tests/keys.py" "$here/chimera-input.c" "$root/tests/games/doom.keys")
	drun="--roms $ir --set machine=p55t2p4 --set cpu=pentium_p54c/133333333 --set video=vga --set memoryKB=16384"
	drun="$drun --set floppyA=35_2hd --set hardDiskController=internal --file hdd=$dd/doom-hd.img --frames 7700"
	t0=$(date +%s%N)
	native_run $drun --set recompiler=true $keys --ppm "$dd/map-recompiler.ppm" --digests "$dd/native.dig" --dump-ram "$dd/native.ram" > /dev/null
	s_rec=$(( ($(date +%s%N) - t0) / 1000000000 )); t0=$(date +%s%N)
	native_run $drun --set recompiler=false $keys --ppm "$dd/map-interpreter.ppm" > /dev/null
	s_int=$(( ($(date +%s%N) - t0) / 1000000000 ))
	native_run $drun --set recompiler=true $(echo "$keys" | sed 's/--key 7600:4:[0-9]*//') --ppm "$dd/nomap.ppm" > /dev/null
	"$rw" "$wbx" "$cfg" $drun --set recompiler=true $keys --digests "$dd/wbx.dig" --dump-ram "$dd/wbx.ram" > /dev/null 2> "$dd/wbx.err"
	# the map's title: red letters in the strip above the status bar
	title() { python3 - "$1" <<'PY'
import sys
d = open(sys.argv[1], 'rb').read().split(b'\n', 3)
w = int(d[1].split()[0])
b = d[3]
print(sum(1 for y in range(318, 332) for x in range(170) if b[(y * w + x) * 3] > 150 and b[(y * w + x) * 3 + 1] < 80))
PY
}
	t_rec=$(title "$dd/map-recompiler.ppm" 2>/dev/null || echo 0); t_int=$(title "$dd/map-interpreter.ppm" 2>/dev/null || echo 0)
	t_none=$(title "$dd/nomap.ppm" 2>/dev/null || echo x)
	if [ "${t_rec:-0}" -gt 300 ] && [ "${t_int:-0}" -gt 300 ] && [ "$t_none" = 0 ] \
	   && [ -s "$dd/wbx.dig" ] && cmp -s "$dd/native.dig" "$dd/wbx.dig" && cmp -s "$dd/native.ram" "$dd/wbx.ram"; then
		report PASS "Doom: installed in DOS, to E1M1" "the map's title at frame 7700 ($t_rec red pixels; none without the map) with the recompiler (${s_rec}s) and the interpreter (${s_int}s); 7700 frames, sandbox == native"
	else
		report FAIL "Doom: installed in DOS, to E1M1" "title recompiler $t_rec interpreter $t_int without map $t_none; see build/gate/doom"
	fi
	crun="$chimera_root/build/dll/chimera-run"
	if [ ! -x "$crun" ]; then
		report SKIP "Doom: the movie through chimera-run" "no chimera-run at $crun"
	else
		dp="$dd/project"; mkdir -p "$dp"; cp "$dd/doom-hd.img" "$dp/"
		python3 "$here/tests/make-movie.py" "$pkg" 7700 $keys > "$dp/movie.txt"
		fw="--firmware machines_p55t2p4_0207_j2.bin=$ir/machines_p55t2p4_0207_j2.bin --firmware video_vga_ibm_vga.bin=$ir/video_vga_ibm_vga.bin"
		"$crun" --new-project "$dp/doom.chimeraProject" "$pkg" --file "hdd=$dp/doom-hd.img" --movie "$dp/movie.txt" \
			--settings '{"machine": "p55t2p4 - [i430HX] ASUS P/I-P55T2P4", "cpu": "pentium_p54c/133333333 - Pentium (P54C) 133 MHz", "video": "vga - IBM VGA", "memoryKB": 16384, "floppyA": "35_2hd - 3.5\" 1.44M", "hardDiskController": "internal - Internal", "recompiler": true}' \
			$fw > "$dp/make.log" 2>&1
		"$crun" --project "$dp/doom.chimeraProject" "$pkg" $fw --frames 7700 --dump "System RAM=$dp/ram.bin" \
			--export-savedata "$dp/export" > "$dp/run.log" 2>&1
		wad=$(python3 "$root/tests/dos-disk/make-dos-disk.py" --read "$dp/export/doom-hd.img" 'DOOMS\DOOM1.WAD' 2>/dev/null | wc -c)
		cfgd=$(python3 "$root/tests/dos-disk/make-dos-disk.py" --read "$dp/export/doom-hd.img" 'DOOMS\DEFAULT.CFG' 2>/dev/null | wc -c)
		if [ -s "$dp/ram.bin" ] && cmp -s "$dp/ram.bin" "$dd/wbx.ram" && [ "${wad:-0}" -gt 1000000 ] && [ "${cfgd:-0}" -gt 0 ] \
		   && cmp -s "$dp/doom-hd.img" "$dd/doom-hd.img"; then
			report PASS "Doom: the movie through chimera-run" "7700 frames: the memory is the sandbox runner's; the exported disk holds C:\\DOOMS\\DOOM1.WAD ($wad bytes) and SETUP's DEFAULT.CFG; the project's file unchanged"
		else
			report FAIL "Doom: the movie through chimera-run" "wad $wad cfg $cfgd; see build/gate/doom/project ($(tail -1 "$dp/run.log" | cut -c1-100))"
		fi
	fi
fi

# ------------------------------------------- 12. the owner's game disks
# Two of the owner's own disks, for local tests only, never in the
# repository or on a public runner:
#   PCBOX_ALLEYCAT   Alley Cat (IBM, 1984), a 180 KB disk that starts itself
#   PCBOX_POP        Prince of Persia (Broderbund, 1990), its 720 KB disk
# Each from switching on to playing, with the input in tests/games: the
# picture is the game's, the first moves move the player against a run that
# stood still, and the sandbox gives the native run's stream and memory.
ac="${PCBOX_ALLEYCAT:-}"
ac_sha1=c4e1b163b14fbffe3bef97816d5b7db142c593f1
if [ -z "$ac" ] || [ ! -d "${ir:-/nonexistent}" ]; then
	report SKIP "Alley Cat: started and played" "needs PCBOX_ALLEYCAT (its 180 KB disk) and PCBOX_ROMS"
elif [ "$(sha1sum "$ac" | cut -c1-40)" != "$ac_sha1" ]; then
	report FAIL "Alley Cat: started and played" "PCBOX_ALLEYCAT is not the disk the test was made with (sha1 $ac_sha1)"
else
	# The IBM PC (1982) with IBM's BIOS, CGA, the disk in a 5.25" drive A.
	# The cat is black; the bins' outlines are black too, so the cat is where
	# the two runs' pictures differ in the strip along the alley's floor.
	ad="$work/alleycat"; mkdir -p "$ad"; cp "$ac" "$ad/disk.img"
	setup=$(python3 "$root/tests/keys.py" "$here/chimera-input.c" "$root/tests/games/alleycat.keys")
	play=$(python3 "$root/tests/keys.py" "$here/chimera-input.c" "$root/tests/games/alleycat-play.keys")
	arun="--roms $ir --set machine=ibmpc82 --set video=cga --set memoryKB=256 --set floppyA=525_2dd --file floppy_a=$ad/disk.img --frames 7600"
	native_run $arun $setup --ppm "$ad/still.ppm" > /dev/null
	native_run $arun $setup $play --ppm "$ad/played.ppm" --digests "$ad/native.dig" --dump-ram "$ad/native.ram" > /dev/null
	"$rw" "$wbx" "$cfg" $arun $setup $play --digests "$ad/wbx.dig" --dump-ram "$ad/wbx.ram" > /dev/null 2> "$ad/wbx.err"
	set -- $(python3 - "$ad/still.ppm" "$ad/played.ppm" <<'PY'
import sys
def load(p):
    d = open(p, 'rb').read().split(b'\n', 3)
    return int(d[1].split()[0]), d[3]
w, a = load(sys.argv[1])
_, b = load(sys.argv[2])
def black(buf, x, y):
    return buf[(y * w + x) * 3:(y * w + x) * 3 + 3] == b'\0\0\0'
def where(p, q):
    pts = [x for y in range(176, 200) for x in range(w) if black(p, x, y) and not black(q, x, y)]
    return sum(pts) // len(pts) if pts else -1
lit = sum(1 for i in range(0, len(b), 3) if b[i:i + 3] != b'\0\0\0')
print(where(a, b), where(b, a), lit)
PY
)
	if [ $# -eq 3 ] && [ "$1" -ge 0 ] && [ "$2" -ge $(($1 + 100)) ] && [ "$3" -gt 50000 ] \
	   && [ -s "$ad/wbx.dig" ] && cmp -s "$ad/native.dig" "$ad/wbx.dig" && cmp -s "$ad/native.ram" "$ad/wbx.ram"; then
		report PASS "Alley Cat: started and played" "the alley at frame 7600 ($3 lit pixels); the right arrow takes the cat from x=$1 to x=$2; 7600 frames, sandbox == native"
	else
		report FAIL "Alley Cat: started and played" "cat [$*]; see build/gate/alleycat"
	fi
fi
pp="${PCBOX_POP:-}"
pp_sha1=d45c2299a2d48de0897e9e5a7a366090192eb5f7
if [ -z "$pp" ] || [ ! -d "${ir:-/nonexistent}" ] || [ -z "$fd" ]; then
	report SKIP "Prince of Persia: started and played" "needs PCBOX_POP (its 720 KB disk), PCBOX_ROMS and FREEDOS_FLOPPY"
elif [ "$(sha1sum "$pp" | cut -c1-40)" != "$pp_sha1" ]; then
	report FAIL "Prince of Persia: started and played" "PCBOX_POP is not the disk the test was made with (sha1 $pp_sha1)"
else
	# The ASUS PCI/I-486SP3 (no F1: its recorded CMOS), 4 MB, VGA; FreeDOS
	# from a floppy made here in A, the game's disk in a 3.5" 720 KB drive B.
	# The prince is the white of his clothes.
	ppd="$work/pop"; mkdir -p "$ppd"; cp "$pp" "$ppd/disk.img"
	python3 "$root/tests/dos-disk/make-dos-disk.py" --freedos "$fd" --out "$ppd/dos.img" --floppy 1440 --autoexec '@echo off\n' > "$ppd/dos.log" 2>&1
	setup=$(python3 "$root/tests/keys.py" "$here/chimera-input.c" "$root/tests/games/pop.keys")
	play=$(python3 "$root/tests/keys.py" "$here/chimera-input.c" "$root/tests/games/pop-play.keys")
	prun="--roms $ir --set machine=486sp3 --set cpu=i486dx2/66666666 --set video=vga --set memoryKB=4096 --set floppyA=35_2hd"
	prun="$prun --set floppyB=35_2dd --file floppy_a=$ppd/dos.img --file floppy_b=$ppd/disk.img --frames 9060"
	native_run $prun $setup --ppm "$ppd/still.ppm" > /dev/null
	native_run $prun $setup $play --ppm "$ppd/played.ppm" --digests "$ppd/native.dig" --dump-ram "$ppd/native.ram" > /dev/null
	"$rw" "$wbx" "$cfg" $prun $setup $play --digests "$ppd/wbx.dig" --dump-ram "$ppd/wbx.ram" > /dev/null 2> "$ppd/wbx.err"
	prince() { python3 - "$1" <<'PY'
import sys
d = open(sys.argv[1], 'rb').read().split(b'\n', 3)
w = int(d[1].split()[0]); b = d[3]
pts = [x for y in range(0, 380) for x in range(w) if min(b[(y * w + x) * 3:(y * w + x) * 3 + 3]) > 200]
print(len(pts), sum(pts) // len(pts) if pts else -1)
PY
}
	set -- $(prince "$ppd/still.ppm" 2>/dev/null) $(prince "$ppd/played.ppm" 2>/dev/null)
	if [ $# -eq 4 ] && [ "$1" -gt 200 ] && [ "$3" -gt 200 ] && [ "$4" -ge $(($2 + 20)) ] \
	   && [ -s "$ppd/wbx.dig" ] && cmp -s "$ppd/native.dig" "$ppd/wbx.dig" && cmp -s "$ppd/native.ram" "$ppd/wbx.ram"; then
		report PASS "Prince of Persia: started and played" "from drive B under FreeDOS, no key for the BIOS; level 1; the right arrow runs the prince from x=$2 to x=$4; 9060 frames, sandbox == native"
	else
		report FAIL "Prince of Persia: started and played" "prince [$*]; see build/gate/pop"
	fi
fi

# ------------------------------------------- 7. through the engine, and the window
# A project, as a person makes one: the probe floppy in its slot, the
# settings, the firmware, a movie that holds A at frame 2200. chimera-run runs
# it; the machine's memory at the end must be the sandbox runner's.
crun="$chimera_root/build/dll/chimera-run"
if [ ! -x "$crun" ]; then
	report SKIP "a project runs through the engine" "no chimera-run at $crun"
else
	pj="$work/project"; mkdir -p "$pj"; cp "$work/probe/probe.img" "$work/hdd10.img" "$pj/"
	python3 "$here/tests/make-movie.py" "$pkg" 2500 --key 2200:5:29 > "$pj/movie.txt"
	fwb=machines_xi8088_bios-xi8088-128k.bin; fwf=video_mda_mda.rom
	if "$crun" --new-project "$pj/p.chimeraProject" "$pkg" --file "floppy_a=$pj/probe.img" --file "hdd=$pj/hdd10.img" \
		--movie "$pj/movie.txt" \
		--settings '{"machine": "xi8088 - [8088] Xi8088", "video": "cga - IBM CGA", "memoryKB": 640, "sound": "adlib - AdLib", "hardDiskController": "xtide - PC/XT XTIDE"}' \
		--firmware "$fwb=$roms/$fwb" --firmware "$fwf=$roms/$fwf" > "$pj/make.log" 2>&1 \
	   && "$crun" --project "$pj/p.chimeraProject" "$pkg" --firmware "$fwb=$roms/$fwb" --firmware "$fwf=$roms/$fwf" \
		--frames 2500 --dump "System RAM=$pj/engine.ram" \
		--export-savedata "$pj/export" > "$pj/run.log" 2>&1; then
		"$rw" "$wbx" "$cfg" --roms "$roms" --set machine=xi8088 --set video=cga --set memoryKB=640 --set sound=adlib \
			--set hardDiskController=xtide --file "floppy_a=$pj/probe.img" --file "hdd=$pj/hdd10.img" \
			--frames 2500 --key 2200:5:29 --dump-ram "$pj/wbx.ram" > /dev/null 2>&1
		if cmp -s "$pj/engine.ram" "$pj/wbx.ram" && [ "$(word_at "$pj/engine.ram" 7e02)" = 1 ] \
		   && [ "$(word_at "$pj/engine.ram" 7e18)" = $((0x4448)) ]; then
			report PASS "a project runs through the engine" "chimera-run --project: floppy and hard disk slots, 2500 frames, the memory is the sandbox runner's, A read, 'HD' read back"
		else
			report FAIL "a project runs through the engine" "the memory differs from the sandbox runner's (see build/gate/project)"
		fi
		# Emulator > Export Save Data: each disk as it stands - the project's
		# file with the machine's writes over it, and nothing else changed
		exported=$(python3 - "$pj" <<'PY'
import sys
d = sys.argv[1]
ok = 0
for name, word in (("probe.img", b"WR"), ("hdd10.img", b"HD")):
    a = open(d + "/" + name, "rb").read()
    b = open(d + "/export/" + name, "rb").read()
    changed = [i for i in range(0, len(a), 512) if a[i:i + 512] != b[i:i + 512]]
    ok += len(a) == len(b) and changed == [512] and b[512:514] == word
print(ok)
PY
)
		if [ "$exported" = 2 ]; then
			report PASS "save data: the disks export as they stand" "chimera-run --export-savedata: both images, the project's file with only the written sector changed"
		else
			report FAIL "save data: the disks export as they stand" "see build/gate/project/export"
		fi
	else
		report FAIL "a project runs through the engine" "$(tail -1 "$pj/make.log" "$pj/run.log" | tr '\n' ' ')"
	fi
fi
win="$chimera_root/build/meson-linux/source/ui/chimera"
if [ ! -x "$win" ]; then
	report SKIP "Chimera's window" "no window at $win"
elif env -u DISPLAY bash "$here/tests/run-frontend.sh" --chimera-root "$chimera_root" --package "$pkg" \
	--roms "$roms" --probe "$work/probe/probe.img" > "$work/frontend.log" 2>&1; then
	report PASS "Chimera's window" "$(tail -1 "$work/frontend.log"): memory, a setting, the keys (build/gate/frontend.log)"
else
	report FAIL "Chimera's window" "$(grep -m1 FAIL "$work/frontend.log")"
fi

finish
