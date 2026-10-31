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
- Two floppy drives and a hard disk (on an XT-IDE card, whose ROM, the free
  XTIDE Universal BIOS, is built into the core). What the machine
  writes stays in its memory and its states, and Emulator > Export Save
  Data gives the disks back as files; your own files are never changed.
- A CD-ROM drive (an ISO, or a cue with data and audio tracks), the second
  drive on the hard disk controller.
- Every machine needs its ROM files from 86Box's ROM set
  (https://github.com/86Box/roms, tag `v6.0`), which you supply. Chimera's
  Firmware window asks for exactly the files the chosen machine reads.

## Building

[docs/BUILDING.md](docs/BUILDING.md) has every step. In short, with a built
Chimera checkout:

```sh
git submodule update --init
export XUB_SRC=<XTIDE Universal BIOS r638>       # waterbox/xtide-bios/xub.ref says how to fetch it
sh waterbox/build-package.sh -m <chimera>/extern/chimera-common-minibox   # -> build/Cores/86box.chimeraCore
CHIMERA_ROOT=<chimera> FREE_BIOS_SRC=<8088_bios checkout> sh waterbox/run-gate.sh
```

[AGENTS.md](AGENTS.md) is the guide for an AI coding agent;
[docs/PLAN.md](docs/PLAN.md) is the design log and says where the work
stands.

## Licence

This repository's files are GPL-2.0-or-later. The built package is
GPL-3.0-or-later, because one part of 86Box it contains is LGPL-3.0-or-later
([LICENSE](LICENSE) says which). The package carries one ROM, the XTIDE
Universal BIOS (GPL-2.0-or-later), built from its source; no other ROM, BIOS
or game is in this repository or in the package.
