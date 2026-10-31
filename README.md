# chimera-core-86box

A Chimera core for PCs, built on [86Box](https://86box.net), the PC emulator
that grew out of PCem. Chimera (https://github.com/ToolAssisted-run/chimera)
is a frontend for tool-assisted speedruns; this repository builds one file,
`86box.chimeraCore`, that goes in its `cores` folder.

## What it runs

- Five machines for now: the Xi 8088, the IBM PC (1981 and 1982), the IBM
  XT and the IBM AT, with CGA, MDA, Hercules, EGA or VGA, an AdLib, Game
  Blaster, Tandy, SSI-2001 or Sound Blaster, two floppy drives, a mouse and
  joysticks.
- Floppy disks, read only. Hard disks and CD-ROMs are not there yet.
- Every machine needs its ROM files from 86Box's ROM set
  (https://github.com/86Box/roms, tag `v6.0`), which you supply. Chimera's
  Firmware window asks for exactly the files the chosen machine reads.

## Building

[docs/BUILDING.md](docs/BUILDING.md) has every step. In short, with a built
Chimera checkout:

```sh
git submodule update --init
sh waterbox/build-package.sh -m <chimera>/extern/chimera-common-minibox   # -> build/Cores/86box.chimeraCore
CHIMERA_ROOT=<chimera> FREE_BIOS_SRC=<8088_bios checkout> sh waterbox/run-gate.sh
```

[AGENTS.md](AGENTS.md) is the guide for an AI coding agent;
[docs/PLAN.md](docs/PLAN.md) is the design log and says where the work
stands.

## Licence

This repository's files are GPL-2.0-or-later. The built package is
GPL-3.0-or-later, because one part of 86Box it contains is LGPL-3.0-or-later
([LICENSE](LICENSE) says which). No ROM, BIOS or game is in this repository
or in the package.
