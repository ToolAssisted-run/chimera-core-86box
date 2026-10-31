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
refusal() { rm -rf "$work/refuse"; "$rn" "$work/refuse" "$@" --frames 1 2>&1 | sed -n 's/^Init: //p' | tr '\037' '|'; }
r_pc=$(refusal --roms "$roms" --set machine=ibmpc)
mkdir -p "$work/roms64"; cp "$work/free-bios/machines_xi8088_bios-xi8088.bin" "$work/free-bios/video_mda_mda.rom" "$work/roms64/"
r_64=$(refusal --roms "$work/roms64" --set machine=xi8088)
r_cpu=$(refusal --roms "$roms" --set machine=ibmat --set cpu=8088/4772728)
if [ "$r_pc" = "error.roms_missing|[8088] IBM PC (1981)|machines_ibmpc_BIOS_IBM5150_19OCT81_5700671_U33.BIN" ] \
   && [ "$r_64" = "error.roms_missing|[8088] Xi8088|machines_xi8088_bios-xi8088-128k.bin" ] \
   && [ "$r_cpu" = "error.cpu_not_taken|8088/4772728|286/6000000, 286/8000000" ]; then
	report PASS "refused, by name: missing ROMs, a CPU" "IBM PC without its BIOS; Xi 8088 with only the 64 KB file; an 8088 in an AT"
else
	report FAIL "refused, by name: missing ROMs, a CPU" "[$r_pc] [$r_64] [$r_cpu]"
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
	report PASS "states: a stale state is noticed" "negative control: frame 749's state loaded at frame 750"
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
