#!/bin/bash
# The window test: the package loaded by Chimera's window (run headless: it
# needs no display), not by its headless runner. The machine is the Xi 8088
# with the free BIOS the gate builds, booting the gate's probe floppy. Three
# things are asked:
#  - a project run for a number of frames in the window, with the key A held
#    from the movie, leaves the machine's whole memory byte for byte what the
#    native build leaves with the same key held;
#  - a setting of the project reaches the machine: with another processor
#    speed the memory at that frame is another, and is the native build's
#    with that speed;
#  - the keys the package ships become Chimera's keys.
#
# Usage: waterbox/tests/run-frontend.sh --chimera-root <chimera checkout> \
#            --package <86box.chimeraCore> --roms <folder of the free BIOS> \
#            --probe <probe.img> [--frames N]
# Needs: Chimera built with its window, the package, the native build. A
# window built against a Qt of its own (Chimera's tools/ci-chimera.sh puts
# one in ~/qt) needs that Qt's lib folder on LD_LIBRARY_PATH.
# (After chimera-core-fuse's.)
set -u

here="$(cd "$(dirname "$0")" && pwd)"
wb="$(cd "$here/.." && pwd)"
root="$(cd "$wb/.." && pwd)"
frames=1500
chimera_root="" package="" roms="" probe=""
while [ $# -gt 0 ]; do
	case "$1" in
		--chimera-root) chimera_root="$2"; shift ;;
		--package) package="$2"; shift ;;
		--roms) roms="$2"; shift ;;
		--probe) probe="$2"; shift ;;
		--frames) frames="$2"; shift ;;
		*) echo "unknown option: $1" >&2; exit 2 ;;
	esac
	shift
done
for v in chimera_root package roms probe; do
	[ -n "${!v}" ] && [ -e "${!v}" ] || { echo "say --${v//_/-} (it is not there: '${!v}')" >&2; exit 2; }
done
chimera_root="$(cd "$chimera_root" && pwd)"
package="$(cd "$(dirname "$package")" && pwd)/$(basename "$package")"
roms="$(cd "$roms" && pwd)"
probe="$(cd "$(dirname "$probe")" && pwd)/$(basename "$probe")"

chimera_exe="$chimera_root/build/meson-linux/source/ui/chimera"
crun="$chimera_root/build/dll/chimera-run"
rn="$root/build/meson-native/run-native"
[ -x "$chimera_exe" ] || { echo "Chimera's window is not built: $chimera_exe" >&2; exit 1; }
[ -x "$rn" ] || { echo "the native build is not there: $rn" >&2; exit 1; }

work="$(mktemp -d)"
cleanup() { rm -rf "$work"; }
trap cleanup EXIT
fw_bios=machines_xi8088_bios-xi8088-128k.bin
fw_font=video_mda_mda.rom
firmware="{\"$fw_bios\": \"$roms/$fw_bios\", \"$fw_font\": \"$roms/$fw_font\"}"

# Chimera's window, run headless: the package's own folder as the cores
# folder, its settings, cache and recovery files the run's own, and nothing
# carried over from a Chimera installed on this machine
export ALSOFT_DRIVERS=null CHIMERA_CORES_DIR="$(dirname "$package")" CHIMERA_QT_CACHE="$work/qt-cache" \
	CHIMERA_QT_RECOVERY="$work/qt-recovery" CHIMERA_QT_HASHES="$work/qt-file-hashes.txt" \
	CHIMERA_QT_CHIMERA_SETTINGS="$work/no-chimera-config.ini"

ok=0
failed=0
report() { printf '%-16s %-6s %s\n' "$1" "$2" "$3"; case "$2" in PASS) ok=$((ok + 1)) ;; *) failed=$((failed + 1)) ;; esac; }

base='"machine": "xi8088 - [8088] Xi8088", "video": "cga - IBM CGA", "memoryKB": 640, "sound": "adlib - AdLib"'
python3 "$here/settings-config.py" "$work/window-settings.json" '{}' "$firmware"

# a project of the probe floppy, its settings and a movie that holds A
# (button 29) from the runners' frame 1200 for 5 frames
make_project() { # <tag> <settings JSON>
	local dir="$work/project.$1"
	mkdir -p "$dir" && cp "$probe" "$dir/probe.img"
	python3 "$here/make-movie.py" "$package" "$frames" --key 1200:5:29 > "$dir/movie.txt" || return 1
	"$crun" --new-project "$dir/$1.chimeraProject" "$package" --file "floppy_a=$dir/probe.img" \
		--movie "$dir/movie.txt" --settings "$2" \
		--firmware "$fw_bios=$roms/$fw_bios" --firmware "$fw_font=$roms/$fw_font" > "$dir/make.log" 2>&1 \
		&& echo "$dir/$1.chimeraProject"
}
run_window() { # <tag> <settings JSON> <frames> [lua]
	local tag="$1" job="$work/job.$1.txt" out="$work/$1.ram.bin"
	[ "${4:-}" = dump-controls.lua ] && out="$work/$1.controls.json"
	printf 'frames=%s\nout=%s\nmeta=%s\nshot=\n' "$3" "$out" "$work/$tag.meta.txt" > "$job"
	local project
	project="$(make_project "$tag" "$2")" || { echo "no project made" > "$work/$tag.log"; return 1; }
	( cd "$chimera_root" && MINIHAWK_JOB="$job" timeout 900 "$chimera_exe" --headless \
		"--config=$work/window-settings.json" "--core=$package" "--lua=$here/${4:-frontend-ram.lua}" \
		"--project=$project" ) > "$work/$tag.log" 2>&1
	[ -f "$work/$tag.meta.txt" ] && grep -q "^status=OK" "$work/$tag.meta.txt"
}
native_ram() { # <tag> <harness options...>
	local tag="$1"; shift
	local key="--key 1200:5:29"
	[ "$tag" = nokey ] && key=""
	"$rn" "$work/native-dir.$tag" --roms "$roms" --set "machine=xi8088" --set "video=cga" --set memoryKB=640 \
		--set "sound=adlib" --file "floppy_a=$probe" --frames "$frames" $key \
		--dump-ram "$work/native.$tag.ram.bin" "$@" > "$work/native.$tag.txt" 2>&1
}

if ! native_ram base; then
	report "window:memory" FAIL "the native runner failed: $(tail -1 "$work/native.base.txt")"
elif ! run_window base "{$base}" "$frames"; then
	report "window:memory" FAIL "Chimera did not finish the run: $(grep '^detail=' "$work/base.meta.txt" 2>/dev/null) $(tail -2 "$work/base.log" | tr '\n' ' ' | cut -c1-300)"
elif cmp -s "$work/native.base.ram.bin" "$work/base.ram.bin" && native_ram nokey \
     && ! cmp -s "$work/native.nokey.ram.bin" "$work/base.ram.bin"; then
	report "window:memory" PASS "the probe run $frames frames in Chimera's window with A held from the movie: the memory ($(wc -c < "$work/base.ram.bin") bytes) is the native build's, and not what it is with no key"
else
	report "window:memory" FAIL "the memory differs from the native build's"
fi

if ! native_ram fast --set "cpu=8088/7159092"; then
	report "window:setting" FAIL "the native runner failed: $(tail -1 "$work/native.fast.txt")"
elif ! run_window fast "{$base, \"cpu\": \"8088/7159092 - 8088 7.16 MHz\"}" "$frames"; then
	report "window:setting" FAIL "Chimera did not finish the run: $(tail -2 "$work/fast.log" | tr '\n' ' ' | cut -c1-300)"
elif cmp -s "$work/native.fast.ram.bin" "$work/fast.ram.bin" && ! cmp -s "$work/fast.ram.bin" "$work/base.ram.bin"; then
	report "window:setting" PASS "with the project's processor at 7.16 MHz the memory at frame $frames is another, and is the native build's at that speed"
else
	report "window:setting" FAIL "7.16 MHz: same as native $(cmp -s "$work/native.fast.ram.bin" "$work/fast.ram.bin" && echo yes || echo no); differs from 4.77 $(cmp -s "$work/fast.ram.bin" "$work/base.ram.bin" && echo no || echo yes)"
fi

# the keys the package ships are the machine's when nobody changed them
if run_window keys "{$base}" 1 dump-controls.lua; then
	if python3 "$here/check-keybinds.py" "$work/keys.controls.json" "$wb/default_keybinds.json" "PC Keyboard, Mouse and Joysticks" > "$work/keys.txt" 2>&1; then
		report "window:keys" PASS "$(cat "$work/keys.txt")"
	else
		report "window:keys" FAIL "$(head -1 "$work/keys.txt")"
	fi
else
	report "window:keys" FAIL "Chimera did not finish the run: $(tail -2 "$work/keys.log" | tr '\n' ' ' | cut -c1-300)"
fi

echo
echo "$ok ok, $failed failed"
[ "$failed" -eq 0 ]
