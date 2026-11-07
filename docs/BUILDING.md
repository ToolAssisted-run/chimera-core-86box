# Building the 86Box core

Placeholders: `<chimera>` is a checkout of Chimera, built (its engine,
`chimera-run`, its window and `test-packages`); `<minibox>` is
`<chimera>/extern/chimera-common-minibox`.

## Requirements

- Linux on x86-64, gcc and g++, meson and ninja, python3. nasm and cmake for
  the free test BIOS and the boot probe, xorriso for the test CD. Nothing else: 86Box's optional
  libraries (Qt, SDL, OpenAL, libslirp, libsndfile, FreeType, libpng, zlib)
  are not used.
- miniBox built twice, the host library and the C++ guest toolchain:

  ```sh
  meson setup <minibox>/build/meson-linux <minibox> && meson compile -C <minibox>/build/meson-linux
  meson setup <minibox>/build/meson-cpp <minibox> -Dguest_cpp=true && meson compile -C <minibox>/build/meson-cpp
  ```

## Sources

```sh
git clone <this repository> && cd chimera-core-86box
git submodule update --init          # extern/86box at the v6.0 release
```

The XTIDE Universal BIOS (GPL-2.0-or-later), the ROM of 86Box's XT-IDE
hard disk cards, is built into the core from its source, revision 638. Fetch
it once into a folder of its own (no svn needed, wget over HTTP; the exact
command is in `waterbox/xtide-bios/xub.ref`) and say where it is with
`XUB_SRC`. The build checks the source tree's hash and the SHA-1 of each
image it makes (`waterbox/xtide-bios/embed.py`): another nasm that writes
other bytes stops the build rather than put an untested ROM in the package.

The patches are applied by the build itself (`meson.build` runs
`waterbox/apply-patches.sh`), which judges the series as a whole: a pristine
tree gets all of it, a tree that has all of it is left alone, anything else
is an error naming the files.

## The two builds

```sh
meson setup build/meson-native -Dminibox_dir=<minibox> -Dxub_src=<xub>
ninja -C build/meson-native -j4                 # run-native, run-wbx, list-machines
XUB_SRC=<xub> sh waterbox/setup-guest.sh -m <minibox>   # writes the cross file, sets up build/meson-guest
ninja -C build/meson-guest -j4 core.wbx
sh <minibox>/source/guest/check-wbx.sh build/meson-guest/core.wbx
```

Both compile the same list of upstream sources (`waterbox/sources.py`, read
from upstream's CMakeLists.txt files) and the same core files, with 86Box's
older x86-64 recompiler (`src/codegen`; meson option `dynarec`, on by
default; the newer one, `codegen_new`, is left out). The native
build is the reference the gate compares the sandbox with.

## The package

```sh
XUB_SRC=<xub> sh waterbox/build-package.sh -m <minibox> [-o <folder>]
```

It regenerates the declaration from 86Box's tables and refuses a committed
`waterbox/waterbox.config` that differs, builds the guest, checks it, and
writes `86box.chimeraCore` (default `build/Cores`). The zip is
deterministic: the same commit gives the same file. The version is the
commit (`<commit>+local` for a local build) and that commit's date.

To use it, put the file in Chimera's `cores` folder (or point
`CHIMERA_CORES_DIR` at its folder).

## The gate

```sh
git clone https://github.com/skiselev/8088_bios.git <src>   # check out the commit tests/free-bios/8088_bios.ref names
CHIMERA_ROOT=<chimera> XUB_SRC=<xub> FREE_BIOS_SRC=<src> [FREEDOS_FLOPPY=<x86BOOT.img>] \
    LD_LIBRARY_PATH=<the window's Qt lib folder> sh waterbox/run-gate.sh
```

Two more inputs add legs, each saying SKIP with the reason when it is
absent. They are for local tests: never on a public runner, never in the
repository, never named beyond what the legs need:

- `PCBOX_ROMS`: a folder holding the ROM set of 86Box at tag v6.0. The gate
  copies out the files the package declares, each checked against its
  pinned SHA-1 (`tools/pin-roms.py --copy`), and runs the IBM PC (1981 and
  1982), XT and AT with IBM's BIOS, FreeDOS on each, the AT's XT-IDE card,
  the AT's CMOS written from the settings (FreeDOS from a 1.44 MB floppy
  with no key pressed; its control leaves the CMOS empty, native build only,
  `CHIMERA_86BOX_EMPTY_CMOS`), and the MDA, Hercules, CGA, EGA and VGA
  cards with IBM's ROMs.
- `PCBOX_KROZ`: Kingdom of Kroz II's archive, `1kroz.zip`. With
  `PCBOX_ROMS` and `FREEDOS_FLOPPY`, the gate makes a FreeDOS hard disk with
  the archive on it, installs the game inside DOS on the IBM XT with its own
  installer, plays the first level, and replays the same input as a movie
  through `chimera-run` in two processes.
- `PCBOX_DOOM`: Doom v1.9 shareware's archive, `doom19s.zip`. With
  `PCBOX_ROMS` and `FREEDOS_FLOPPY`, the gate installs it inside DOS on the
  Pentium board and starts its first level, with the recompiler and with
  the interpreter.
- `PCBOX_ALLEYCAT` and `PCBOX_POP`: the owner's Alley Cat disk (180 KB, it
  starts by itself) and Prince of Persia disk (720 KB). With `PCBOX_ROMS`
  (and `FREEDOS_FLOPPY` for Prince of Persia, whose disk does not start by
  itself), the gate starts each and plays its first moves: Alley Cat on
  the IBM PC (1982), Prince of Persia from drive B under FreeDOS on the
  486 board. Each leg knows its disk by SHA-1.

With `PCBOX_ROMS` the gate also runs the 486 and Pentium boards, both
ways (interpreter and recompiler), natively and in the sandbox, and their
states. No key is pressed on them: the core writes the CMOS each board's
Award BIOS writes when it loads its defaults (below). The gate records it
again from the boards' BIOS files and compares it with the header, checks
the CMOS of every run holds it, and runs each board once with it left out
(native build only, `CHIMERA_86BOX_NO_AWARD_CMOS`), when FreeDOS must not
start.

## The Award boards' default CMOS

An Award BIOS keeps its own settings in its CMOS past the standard bytes,
with checksums of its own; with them missing it stops at "CMOS checksum
error" and waits for F1. `waterbox/award-cmos.h` holds, for each Award
board, what its BIOS writes when it loads its defaults, and the core
writes that at power-on. It is generated: after adding an Award board (a
row in the tool's `BOARDS`) or changing how a board is set up, record it
again from the owner's ROM set and commit the result:

```sh
python3 tools/pin-roms.py --copy waterbox/waterbox.config <ROM set of 86Box, v6.0> build/roms
python3 tools/record-award-cmos.py --runner build/meson-native/run-native --roms build/roms --write waterbox/award-cmos.h
```

`--check` records again and says whether the header still holds the same
bytes; `--print --set name=value` prints each block recorded with a
setting changed, which is how to find out what the block depends on.

`XUB_SRC` is the XTIDE Universal BIOS's source, as for the builds. With
`FREEDOS_FLOPPY` the gate also makes a FreeDOS hard disk and starts FreeDOS
from it through the ROM the core carries; its negative control hands the
card upstream's own XT build instead (native build only,
`CHIMERA_86BOX_NO_BUILTIN_ROMS`).

What it does, in order: both builds, `check-wbx`, the package, Chimera's
contract tests on the package alone, the code's text keys; then, with the
free BIOS: the refusals (missing ROM files, a CPU a machine does not take, a BIOS
choice the core does not offer),
the native reference reaching the BIOS screen and running the probe floppy,
determinism and its negative control, input (keyboard, serial mouse,
joystick buttons, lag frames), FM sound, virtual time and its negative
control, the sandbox against the native reference, states (save and load
before every frame, a stale state noticed, a state carried to another
process), the CD-ROM drive (a disc it makes: data read, audio heard, the
sandbox and states), FreeDOS from its floppy and from a hard disk (optional), a
project through `chimera-run`, and the project in Chimera's window
(`waterbox/tests/run-frontend.sh`, headless). Before the machines: the
texts, Chimera's text check and the name check (`tools/check-names.py`).

Without `FREE_BIOS_SRC` only the build and package legs run; that is what a
runner without the BIOS source can prove. No leg needs a commercial ROM.

## Troubleshooting

- `the series does not apply`: the submodule moved without the patches
  being rebased; `git -C extern/86box status` shows what is there.
- `waterbox/waterbox.config is not what tools/gen-config.py writes`: run the
  command it prints and commit the result.
- A load error `error.roms_missing` names the ROM files of 86Box's set that
  the chosen machine reads; their firmware ids are those paths with `/` as
  `_`.
- The window test fails with `libQt6Core.so.6`: put the Qt the window was
  built with on `LD_LIBRARY_PATH`.

## Two CPUs

CI builds and tests the core twice, once for each CPU, on a runner of that
CPU (x86_64 on ubuntu-24.04, aarch64 on ubuntu-24.04-arm): a package is
machine code for one CPU, and the guest is built for the CPU it is built on.
A nightly carries both packages, `<id>-<version>-x86_64.chimeraCore` and
`<id>-<version>-aarch64.chimeraCore`. On aarch64 the linked `core.wbx` goes
through miniBox's `wbx-tp-rewrite.py`, which points its thread-pointer reads
at the machine's slot.
