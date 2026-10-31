#!/bin/sh
# The 86Box core's gate: the core and its native reference, leg by leg,
# each saying what it compared. Read Chimera's docs/gates.md first; every leg
# here has been run broken on purpose and seen to fail, and where a leg has a
# negative control the control runs as part of the gate.
#
#   CHIMERA_ROOT=<chimera checkout> [MINIBOX_DIR=<miniBox>] \
#   FREE_BIOS_SRC=<checkout of tests/free-bios/8088_bios.ref> \
#       waterbox/run-gate.sh
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
[ -f "$native/build.ninja" ] || meson setup "$native" "$root" "-Dminibox_dir=$mb" > "$work/setup-native.log" 2>&1
if ninja -C "$native" -j4 > "$work/build-native.log" 2>&1; then
	report PASS "the native reference builds" "run-native, run-wbx"
else
	report FAIL "the native reference builds" "see build/gate/build-native.log"
fi
[ -f "$guest/build.ninja" ] || sh "$here/setup-guest.sh" -m "$mb" > "$work/setup-guest.log" 2>&1
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

# (a setting given twice is read as the first: a leg that needs another value
# starts from $xi_base)
xi_base="--roms $roms --set machine=xi8088 --set video=cga --set memoryKB=640 --set floppyA=525_2dd --set mouse=msserial --set joystick=2axis_2button"
xi="$xi_base --set sound=adlib"
probe="--file floppy_a=$work/probe/probe.img"
# the probe's run: the key A (button 29) held at frame 1200, the mouse moved
# 30 to the right at 1300 and its position moved at 1350 - so every leg that
# compares the probe's run compares a machine that was given input
# and the first stick's first button and the second's second (buttons 106
# and 109) held from 1200 to the end
input="--key 1200:5:29 --axis 1300:1:0:30 --axis 1350:100:3:50000 --key 1200:301:106 --key 1200:301:109"
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
native_run $xi $probe $input --frames 1500 --dump-ram "$work/probe-native.ram" --digests "$work/probe-native.dig" > "$work/probe-native.txt"
ticks=$(word_at "$work/probe-native.ram" 7e00 2>/dev/null || echo 0)
if [ "$(dd if="$work/probe-native.ram" bs=1 skip=$((0x7e06)) count=4 2>/dev/null)" = "PRB1" ] && [ "${ticks:-0}" -gt 50 ]; then
	report PASS "native: the probe floppy boots and runs" "$ticks timer ticks counted by frame 1500"
else
	report FAIL "native: the probe floppy boots and runs" "ticks=${ticks:-?}; see build/gate/n$n.err"
fi

# ---------------------------------------- 2. one machine, every time
native_run $xi $probe $input --frames 1500 --digests "$work/probe-native2.dig" > /dev/null
if cmp -s "$work/probe-native.dig" "$work/probe-native2.dig" && [ "$(wc -l < "$work/probe-native.dig")" -eq 1500 ]; then
	report PASS "native: two runs give the same stream" "1500 frames: machine clock, cycles and picture of each"
else
	report FAIL "native: two runs give the same stream" "see build/gate/probe-native*.dig"
fi
# negative control: the stream sees another machine (a faster CPU)
native_run $xi $probe $input --set cpu=8088/7159092 --frames 1500 --digests "$work/probe-fast.dig" > /dev/null
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
native_run $xi $probe --frames 1500 --dump-ram "$work/idle.ram" > "$work/idle.txt"
k_idle=$(word_at "$work/idle.ram" 7e02); k=$(word_at "$work/probe-native.ram" 7e02); last=$(word_at "$work/probe-native.ram" 7e04)
if [ "$k_idle" = 0 ] && [ "$k" = 1 ] && [ "$last" = $((0x1e61)) ]; then
	report PASS "input: a key held reaches the program" "A held 5 frames: one key, scan code 1E, 'a' (idle run: none)"
else
	report FAIL "input: a key held reaches the program" "keys idle=$k_idle pressed=$k last=$last"
fi
m_idle=$(word_at "$work/idle.ram" 7e0a); m=$(word_at "$work/probe-native.ram" 7e0a)
native_run $xi $probe --key 1200:5:29 --axis 1300:1:0:30 --frames 1500 --dump-ram "$work/rel.ram" > /dev/null
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
if [ -n "$lag_idle" ] && [ "$lag_idle" -lt "$lag" ] && [ "$lag" -lt 200 ]; then
	report PASS "input: frames nobody read are lag frames" "frames that read a control: idle $lag_idle, with input $lag, of 1500"
else
	report FAIL "input: frames nobody read are lag frames" "idle ${lag_idle:-?}, with input ${lag:-?}"
fi

# ------------------------------------------------------------ 3b. sound
# The probe plays one held note on an AdLib's FM chip. 86Box hands FM over as
# a stream of its own at 49716 Hz, which the core converts and adds to the
# cards' 48000 Hz (waterbox/chimera-audio.c): the note must be in the
# frame's sound with an AdLib, and nothing without one (the BIOS's beep is
# over by frame 1000). And the count: 48000 a second, less the block of 20
# ms the cards have not finished by the last frame.
native_run $xi_base $probe --set sound=none --frames 1500 --digests "$work/nosound.dig" > /dev/null
peak=$(awk '$1 > 1000 && $5 > m { m = $5 } END { print m + 0 }' "$work/probe-native.dig")
peak_none=$(awk '$1 > 1000 && $5 > m { m = $5 } END { print m + 0 }' "$work/nosound.dig")
pairs=$(sed -n 's/.*audioPairs=\([0-9]*\).*/\1/p' "$work/probe-native.txt")
if [ "$peak" -gt 500 ] && [ "$peak_none" = 0 ] && [ "${pairs:-0}" -le 720000 ] && [ "${pairs:-0}" -ge 719040 ]; then
	report PASS "sound: an AdLib's FM note is in the frame's sound" "loudest after frame 1000: $peak (no card: 0); $pairs samples in 15 s"
else
	report FAIL "sound: an AdLib's FM note is in the frame's sound" "loudest $peak (no card: $peak_none); ${pairs:-?} samples in 15 s"
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
"$rw" "$wbx" "$cfg" $xi $probe $input --frames 1500 --dump-ram "$work/probe-wbx.ram" --digests "$work/probe-wbx.dig" > "$work/probe-wbx.txt" 2> "$work/probe-wbx.err"
if [ -s "$work/probe-wbx.dig" ] && cmp -s "$work/probe-native.dig" "$work/probe-wbx.dig" \
   && cmp -s "$work/probe-native.ram" "$work/probe-wbx.ram" \
   && [ "$(sed 's/^end //' "$work/probe-native.txt" | tail -1)" = "$(sed 's/^end //' "$work/probe-wbx.txt" | tail -1)" ]; then
	report PASS "sandbox == native" "1500 frames: every frame's clock, cycles and picture; memory, sound at the end"
else
	report FAIL "sandbox == native" "see build/gate/probe-wbx.* and probe-native.*"
fi

# ---------------------------------------------------------- 6. states
"$rw" "$wbx" "$cfg" $xi $probe $input --frames 1500 --rerecord > "$work/rerecord.txt" 2> "$work/rerecord.err"
if [ "$(tail -1 "$work/rerecord.txt")" = "$(tail -1 "$work/probe-wbx.txt")" ]; then
	report PASS "states: save and load before every frame" "1500 frames end as the straight run"
else
	report FAIL "states: save and load before every frame" "see build/gate/rerecord.*"
fi
HARNESS_BREAK_STALE_STATE=1 "$rw" "$wbx" "$cfg" $xi $probe $input --frames 1500 --rerecord > "$work/stale.txt" 2> "$work/stale.err"
if grep -q '^end ' "$work/stale.txt" && [ "$(tail -1 "$work/stale.txt")" != "$(tail -1 "$work/probe-wbx.txt")" ]; then
	report PASS "states: a stale state is noticed" "negative control: frame 749's state loaded at frame 750"
else
	report FAIL "states: a stale state is noticed" "it was not: the leg above is blind"
fi
"$rw" "$wbx" "$cfg" $xi $probe $input --frames 1500 --save-state "$work/s900.state" --at 900 > "$work/session1.txt" 2>&1
"$rw" "$wbx" "$cfg" $xi $probe $input --frames 1500 --state "$work/s900.state" > "$work/session2.txt" 2> "$work/session2.err"
if [ "$(tail -1 "$work/session2.txt")" = "$(tail -1 "$work/probe-wbx.txt")" ]; then
	report PASS "states: another process carries on from a state" "saved at frame 900, ends as the straight run at 1500"
else
	report FAIL "states: another process carries on from a state" "see build/gate/session*"
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

# ------------------------------------------- 7. through the engine, and the window
# A project, as a person makes one: the probe floppy in its slot, the
# settings, the firmware, a movie that holds A at frame 1200. chimera-run runs
# it; the machine's memory at the end must be the sandbox runner's.
crun="$chimera_root/build/dll/chimera-run"
if [ ! -x "$crun" ]; then
	report SKIP "a project runs through the engine" "no chimera-run at $crun"
else
	pj="$work/project"; mkdir -p "$pj"; cp "$work/probe/probe.img" "$pj/"
	python3 "$here/tests/make-movie.py" "$pkg" 1500 --key 1200:5:29 > "$pj/movie.txt"
	fwb=machines_xi8088_bios-xi8088-128k.bin; fwf=video_mda_mda.rom
	if "$crun" --new-project "$pj/p.chimeraProject" "$pkg" --file "floppy_a=$pj/probe.img" --movie "$pj/movie.txt" \
		--settings '{"machine": "xi8088 - [8088] Xi8088", "video": "cga - IBM CGA", "memoryKB": 640, "sound": "adlib - AdLib"}' \
		--firmware "$fwb=$roms/$fwb" --firmware "$fwf=$roms/$fwf" > "$pj/make.log" 2>&1 \
	   && "$crun" --project "$pj/p.chimeraProject" "$pkg" --firmware "$fwb=$roms/$fwb" --firmware "$fwf=$roms/$fwf" \
		--frames 1500 --dump "System RAM=$pj/engine.ram" > "$pj/run.log" 2>&1; then
		"$rw" "$wbx" "$cfg" --roms "$roms" --set machine=xi8088 --set video=cga --set memoryKB=640 --set sound=adlib \
			--file "floppy_a=$pj/probe.img" --frames 1500 --key 1200:5:29 --dump-ram "$pj/wbx.ram" > /dev/null 2>&1
		if cmp -s "$pj/engine.ram" "$pj/wbx.ram" && [ "$(word_at "$pj/engine.ram" 7e02)" = 1 ]; then
			report PASS "a project runs through the engine" "chimera-run --project: 1500 frames, the memory is the sandbox runner's, A read"
		else
			report FAIL "a project runs through the engine" "the memory differs from the sandbox runner's (see build/gate/project)"
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
