# 86Box as a Chimera core: plan and log

Chimera issue 408 asks for 86Box, the PC emulator that grew out of PCem and
is still developed. Chimera already has a PCem core
(`chimera-core-pcem`), and this core is built the same way: the emulator's
own machine code with a small platform layer of ours in place of its
window, its sound output and its threads.

This file is the design log. Dated sections say what was decided, why, and
what was measured. The last section, "Where this stands", is what another
person picks the work up from.

## 1. Feasibility (2026-10-31)

Read from 86Box's source at the commit pinned below, not from its website.

### The upstream and its licence

- Upstream: `https://github.com/86Box/86Box`, pinned at tag `v6.0`, commit
  `4fef696a4eead1d55a28d6ac0e5bd2864e5454da` (2026-05-30), the latest
  release. Master is the 7.0 development line; a release is pinned so the
  ROM set that matches it is also a release (`86Box/roms` tag `v6.0`).
- Licence at that commit: `COPYING` is the GPL version 2 text and
  `README.md` says "version 2 or later". Every file this core compiles was
  searched for GPL version 3, AGPL and "non-commercial" terms: none (the only
  hits were in the Qt and SDL front ends and their imgui copy, which this
  core does not compile). The parts that would bring other terms - Discord
  Game SDK (not free), Ghostscript (AGPL, loaded at run time by the printer),
  FluidSynth, munt, the network back ends (libslirp, pcap) - are left out.
  So the core may be modified and distributed as a binary with its sources.
- Answer: yes.

### Is it a new core, or a machine for the PCem core?

A new core. 86Box is a different emulator now (about 780,000 lines of C
and C++ outside its user interface, against PCem's 250,000; 500 machines,
150 video cards, 1170 distinct ROM file names). The PCem core stays as it
is. The PCem core's `docs/UPSTREAM.md` (2026-09-20) compared the two and
chose PCem for that core because of speed on Windows XP and because PCem
had fewer threads and clock reads to remove; this core takes on exactly
that work. It is a second PC core, not a replacement.

### One thread on one clock

86Box's main loop calls `pc_run()` once per millisecond of machine time; each
call runs `cpu_exec(cpu speed / 1000)` cycles, and every device timer runs
off the emulated cycle counter. A frame of this core is a fixed number of
those calls (10 at 100 frames a second, the same cadence as the PCem core
and the TASVideos PCem movies). Nothing in it waits on the host.

Places where the host reaches the machine, found by searching the source
(the platform layer of ours replaces the ones in the front end):

| Where | What | What this core does |
|---|---|---|
| `nvr.c` `time()` + `localtime` | the CMOS clock is set from the host's date at power-on | a setting, the machine's start date (patch) |
| `utils/random.c` | `rdtsc` in inline assembly and `srand(rdtsc)`, used by the bus mouse and one Super I/O chip. The sandbox does NOT stop a guest reading the processor's time stamp counter, so this would differ silently from run to run | a fixed-seed generator kept in machine memory (patch) |
| `sound/snd_sn76489.c` | `srand(time(NULL))` at reset | no reseeding (patch) |
| `86box.c` | the log file's header date; the speed statistics | log only; `plat_get_ticks` of ours counts machine time |
| `video/nv/nv_rivatimer.c` | a wall-clock timer that runs device code (NVIDIA RIVA cards) | those cards are not offered |
| `minivhd`, `cdrom_image_viso.c`, `scsi_tape.c` | dates for files 86Box creates | not reached: no disk is created inside the machine, no folder is turned into a CD |
| `plat_timer_read` in the Voodoo, Matrox and Mach64 code | statistics | ours returns a counter |

Threads that the emulated machine starts (`thread_create`):

| Thread | When it runs | What this core does |
|---|---|---|
| the picture hand-over (`video.c`, one per monitor) | always | done in place, on the one thread (patch, as the TASVideos 86Box branch did) |
| CD audio (`sound.c`) | a machine with a CD drive | to be done in place before CD drives are offered |
| floppy and hard disk sounds (`sound.c`) | only when drive sounds are on | off |
| S3, S3 ViRGE, Voodoo, Matrox, Mach64, PGC command queues | those video cards | not offered until each is made single-threaded |
| MIDI synthesizers, network back ends, gdb stub, VFIO | left out of the build | - |

The platform layer's `thread_create` refuses any thread it does not know
with a load error that names it, so a device that needs one cannot slip in
unnoticed. Waits with a time limit never happen on one thread.

### The picture

Way 1 of `porting-a-core.md`: every video card draws in C into a 2048x2048
32-bit bitmap per monitor, and the platform's `blit_func` is handed the
rectangle to show. No GPU, no OpenGL. One monitor.

### The recompiler

86Box has an interpreter and two recompilers; on x86-64 the default is the
older one (`src/codegen`). It gets its code memory from `plat_mmap`
(ours), and finds self-modifying code with dirty masks the memory write
functions keep - no page protection, no fault handler, no SIGSEGV fast path
anywhere outside the front ends. So it meets both conditions of
`new-core.md` section 1 by construction. The interpreter is a setting away
(`cpu_use_dynarec`), and interpreter and recompiler are not guaranteed to
give the same machine, so the setting is part of a movie. The first
machines here are 8088 and 286 class and run on the interpreter; the
recompiler comes when a Pentium-class machine does.

### What the user brings

Machine and video BIOS images, which are mostly copyrighted. 86Box keeps
them in a separate repository, `https://github.com/86Box/roms` (tag
`v6.0` matches the pinned emulator). The package declares each file by its
path in that set; the user points Chimera at the files. Nothing of it is
in this repository.

### What CI can run

A machine whose BIOS may be distributed: the Xi 8088 (`xi8088`), made for
Sergey Kiselev's 8088 BIOS (GPL-3.0). The gate builds that BIOS from source
with nasm, exactly as the PCem core's gate does (`tests/free-bios/`), and
uses a stand-in for IBM's character ROM made from a free font. On that
machine the gate boots a floppy whose program it builds itself
(`tests/boot-probe/`), which shows a counter and the keys it reads. 86Box
also offers GLaBIOS (GPL-3.0) as a BIOS choice on the IBM PC and XT
machines; it is a second free route if it is wanted later.

### Memory

The machine's RAM comes from `plat_mmap` (ours: ordinary guest memory);
lookup tables are allocated like PCem's. An XT or AT with a few MB is a
small state; a Pentium with 64 MB is a few hundred MB, as the PCem core
measured. The layout starts small and grows with the machines offered.

### The answer

Feasible. The route is the PCem core's, with more threads and clock reads
to remove, a different file layer (86Box asks the platform to open every
file, so no `fopen` renaming is needed) and a curated list of machines
rather than all 500.

## 2. Decisions awaiting the owner

- **A new public repository** (`chimera-core-86box`) and a roster row: not
  done; this repository is local only.
- **Which machines to offer first.** The default taken here: the Xi 8088
  (free BIOS, the CI machine), then the IBM PC 5150, IBM XT 5160 and IBM AT
  as the machines most people have ROMs for, then one 486 and one Pentium
  board once the recompiler is in. All 500 would mean about 1,000 firmware
  entries in the package; a curated list is what is offered.
- **The frame rate.** 100 frames a second (10 ms of machine time a frame),
  like the PCem core, so the two PC cores and the TASVideos PCem movies use
  the same cadence. A setting can change it.
- **The licence of the package**: GPL-3.0-or-later, because 86Box's
  Teledisk reader carries LGPL-3.0-or-later LZW routines (upstream's own
  builds are in the same position). The default taken: keep them, as
  upstream does. The alternative is to leave them out, keep the package
  GPL-2.0-or-later, and not read .td0 images saved with the old
  compression.
- **The controller** is the PCem core's, name for name, so the two PC
  cores' movies have the same columns. The default taken; a different
  layout (players, headers for the keyboard's columns) would be a choice
  for both PC cores at once.

## 3. Log

### 2026-10-31: the native reference, virtual time, the guest, states

- **The build.** Meson, twice from one list of sources: natively
  (`build/meson-native`: `run-native`, `run-wbx`) and for the miniBox guest
  (`build/meson-guest`: `core.wbx`, through the cross file
  `waterbox/setup-guest.sh` writes). `waterbox/sources.py` reads the list
  from upstream's own `CMakeLists.txt` files (715 files) and leaves out what
  reaches the host or needs a library the core does not carry: the user
  interfaces, sound and MIDI outputs, network back ends (the network cards
  stay), printers, host serial ports, munt, the GDB stub. libpng,
  libsndfile and zlib are stood in for by headers in `waterbox/compat` (a
  screenshot, a CD track kept as a separate sound file and an encrypted
  `.mdx` image are what is lost; each says so).
- **The platform layer** (`waterbox/chimera-plat.c`) is upstream's
  interface layer for one thread and no host: every path becomes a mounted
  name (ROMs as `machines_xi8088_bios-xi8088-128k.bin`, the path in 86Box's
  ROM set with `/` as `_`), nothing is opened for writing in either build,
  the configuration is composed in memory from the settings
  (`cinterface.c`), the clock is machine milliseconds, and a thread a
  device asks for is refused with its name (Init then refuses the machine).
- **Patches** (all behind `CHIMERA_CORE`): 0001 the RTC starts at the
  project's date (UTC); 0002 random numbers from the core's generator, not
  `rdtsc` or the time; 0003 the picture handed over in place, no blit
  thread; 0004 the configuration read as bytes (glibc's `fgetws` crashes
  on a memory stream); 0005 no hard disk sounds (their mixer is a thread).
  Compile options: `rand`/`srand` renamed to the core's generator in every
  C file (glibc's and musl's differ), ESFM's inline assembly off (the large
  code model cannot take its addressing), `__thread` off (one thread).
- **The free PC.** The Xi 8088 with Sergey Kiselev's BIOS built from source
  (`tests/free-bios`, from the PCem core). 86Box's default for this machine
  is the 128 KB image (`bios-xi8088-128k.bin`, read at E0000 with its halves
  swapped); upstream's "noide" image is exactly that. A trap found on the
  way: 86Box's "is this machine available" accepts either of the machine's
  two files, and the machine then runs with whichever its configuration
  names, so with only the 64 KB file it passed the check and ran with no
  BIOS (a black screen, no error). The package must ask for the file the
  configuration will read.
- **The probe** (`tests/boot-probe`): a boot sector of 8088 code that counts
  BIOS timer ticks and keys read into a block at 0000:7E00 and shows them.
  The first version used a 32-bit move and `rol ax, 4`, which an 8088 does
  not have, and went nowhere: the CPU is an 8088.
- **Measured.** The gate, 14 passed, 0 failed, 0 skipped: the BIOS screen
  is reached natively (7097 lit pixels at frame 600); the probe counts 114
  timer ticks by frame 1500; two runs give the same per-frame stream; a
  host stalled 20 ms before every frame changes nothing, and on the host's
  clock two runs a second apart differ (control); the sandbox gives the
  native reference's stream for all 1500 frames, and the same memory and
  sound; save and load before every frame, and a state carried to another
  process, end where the straight run does; a stale state is noticed
  (control). A state of the Xi 8088 with 640 KB is 3.6 MB. Broken on
  purpose and seen to fail: the sandbox leg (guest clock one second off),
  the BIOS-screen leg (no character ROM: 0 lit pixels), the probe leg (no
  floppy: no block).

### 2026-10-31: input

- **The controller** is the PCem core's, name for name and in the same
  order (a PC movie's columns mean the same in both cores): the 101/102-key
  keyboard, three mouse buttons, two buttons on each of two gameport sticks;
  axes Mouse X/Y (relative, this frame's movement), Mouse Position X/Y
  (0..65535 across the picture), Joystick 1 and 2 X/Y (0..65535, 32767 at
  rest). `waterbox/chimera-input.c` holds the order and each key's scan
  code. Keys are levels: a key whose state changed since the last frame is
  pressed or released in 86Box's keyboard, in table order.
- **The mouse.** 86Box's mice are relative and keep what a report could
  not carry, so a long move arrives whole. A position becomes the movement
  that reaches it from the last one, in pixels of the picture, open loop;
  a relative axis that moved wins for its direction (the DOSBox-X and PCem
  cores' rule). 86Box's mice report only while its window "holds the
  pointer" (`mouse_capture`); the core sets it, since the movie is the
  mouse. Found because the first mouse test moved nothing.
- **Lag frames** (patch 0006): every port read goes past
  `chimera_port_read`, which only looks; a frame in which the program read
  the keyboard controller (0x60, a PS/2 mouse too), the game port, a serial
  port's data or a bus mouse is not a lag frame.
- **The probe** now also powers a serial mouse on COM1 (DTR and RTS) and
  counts and sums the bytes it reads. It polls once a timer tick, so bytes
  that come faster are lost to the UART's overrun: what it counts is less
  than what the mouse sent, the same in every run.
- **Measured.** The gate, 17 passed, 0 failed, 0 skipped. The probe's run
  now carries input (A held at frame 1200, a move at 1300, a position from
  1350), so every comparison - native twice, sandbox against native, a
  state before every frame, a state in another process - compares a
  machine that was given input. A held 5 frames reads as one key, scan code
  1E, 'a' (none in the idle run); the serial mouse gives 1 byte idle (its
  'M'), 3 with a move, 19 with a move and a position; 5 frames read a
  control in the idle run and 25 with input, of 1500. Broken on purpose and
  seen to fail: no key handed over, no movement handed over, every frame
  counted as read.
- **Joysticks**, a second commit: the probe reads the game port (0x201)
  every timer tick and keeps the last value. With the setting
  `joystick=2axis_2button` and stick 1 button 1 and stick 2 button 2 held to
  the end it reads 0x60, idle 0xF0 (gate, 18 passed). The first try held
  the buttons to the frame before the last and read 0xF0: a press must
  still be held on the frame that is looked at (gates.md, F). The probe now
  reads a control every tick, so about 120 of 1500 frames read one, idle or
  not. The sticks' axes are not tested: the probe does not time the game
  port's axis pulses.

### 2026-10-31: sound

- 86Box hands its sound over as up to four streams, each at its own rate
  and in blocks when its own timer says: the cards at 48000 Hz (20 ms
  blocks), the FM synthesizers at 49716 Hz, wavetables and CD audio at
  44100 Hz. Chimera takes one stream at one rate. `waterbox/chimera-audio.c`
  keeps the cards' stream as it comes and converts each other stream to
  48000 Hz (linear interpolation, in whole numbers), adding it to the
  cards' stream 2048 samples (43 ms) later than the moment it stands for.
  A block of another stream is at most 28 ms long, so it has always arrived
  before the samples it is added to, whatever order the timers fire in:
  nothing is late and nothing is dropped. FM music is therefore 43 ms
  behind the cards' sound, the same in every run. All of it is ordinary
  memory, so a state carries it.
- The probe plays one held FM note on an AdLib at start. Gate, 19 passed:
  the loudest sample after frame 1000 is 2042 with an AdLib and 0 with no
  card; 15 s give 719040 samples (48000 a second, less the cards' 20 ms
  block not finished by the last frame). The probe's run now has the AdLib,
  so the sandbox, state and stream legs compare FM sound too. Broken on
  purpose and seen to fail: the FM stream not added.
- A trap of the gate's own: a setting given twice to the runners is read as
  the first, so a leg that needs another value starts from the settings
  without it.

### 2026-10-31: the package, the engine, the window

- **The declaration is generated** (`tools/gen-config.py`) from 86Box's own
  tables as the pinned 86Box reports them: `list-machines`, a native-only
  program built with the emulator, prints each offered machine's memory,
  CPUs, FPUs, BIOS choices with their files, and the video cards, sound
  cards and mice 86Box lets it have. `build-package.sh` regenerates it and
  refuses a committed `waterbox.config` that differs.
- **Five machines** for now: the Xi 8088, the IBM PC (1981 and 1982), the
  IBM XT and the IBM AT. Video: CGA, MDA, Hercules, EGA, VGA. Sound: none,
  AdLib, Game Blaster, Tandy, SSI-2001, Sound Blaster 1.0 to 16 (none of
  them needs a ROM). Floppy drives, mice, joysticks, the clock at start and
  the frame rate are settings. A choice is "id - Name" (the PCem core's
  convention), so no names need translating; `auto` for the BIOS and the
  CPU means the machine's own, and memory 0 means the most its
  motherboard takes.
- **Firmware**: one entry per ROM file of 86Box's ROM set, its id the path
  in the set with `/` as `_`, required when the machine and BIOS (or the
  video card) that read it are chosen. No SHA-1 is pinned: the ROMs were
  not available here (the owner supplies them), so a file is known by its
  name. Pinning the hashes is the first thing to do with the ROM set.
- **What the core refuses, by name.** A CPU, BIOS, video card, sound card
  or mouse the machine does not take, with the list of what it takes. ROM
  files: 86Box's own interface switches to another machine whose ROMs are
  there, and its "available" check is satisfied by any of a machine's BIOS
  choices; the core instead watches every ROM file the machine reads while
  it is built and refuses it, naming the files. The Xi 8088 with only its
  64 KB file used to run with no BIOS and a black screen; now it is refused
  naming the 128 KB file.
- **Texts**: 47 keys in `waterbox/languages/en.json` and the 25 other
  languages Chimera has, translated by an AI model (Claude), checked by
  Chimera's rules (same keys, same placeholders); nobody who speaks them has
  read them.
- **Licence**: 86Box is GPL-2.0-or-later, but its Teledisk (.td0) reader
  uses LZW routines under LGPL-3.0-or-later, so the package is GPL-3.0-or-
  later, as 86Box's own builds are. Leaving the LZW routines out would keep
  GPL-2.0-or-later and cost old-compression .td0 images: the owner's call
  (section 2).
- **Measured.** Gate, 25 passed, 0 failed, 0 skipped: the package builds
  (reproducibly: the same zip twice); Chimera's contract tests, 22 passed;
  `check-core-texts.py`, 47 keys all named; a project made with
  `chimera-run --new-project` (the probe floppy in its slot, a movie
  holding A) runs through the engine and ends with the sandbox runner's
  memory; Chimera's Qt window, headless, runs the project 1500 frames and
  ends with the native build's memory (and not the memory of a run without
  the key), a project at 7.16 MHz ends with the native build's memory at
  that speed, and the package's 106 key bindings and 4 axis bindings are
  the window's. Broken on purpose and seen to fail: the window run with the
  movie holding another key; the refusal with the ROM check after the
  machine is built taken out (the Xi 8088 then ran 600 frames with 0 lit
  pixels).
- The window needs the Qt it was built with on `LD_LIBRARY_PATH` here
  (`~/qt/6.12.0/gcc_64/lib`); the gate passes the environment through.

### 2026-10-31: disks the machine writes, and a hard disk

- **Writable disks over read-only files** (`waterbox/chimera-overlay.c`). A
  disk image 86Box opens for update gets a stdio stream (fopencookie, which
  glibc and musl both have) whose writes are kept in the machine's memory,
  4 KiB blocks copied from the file on first write; everything else reads
  from the file. The user's file is never changed, a state carries what was
  written, and a large image costs nothing until written. An overlay
  belongs to its file's name for the session, so 86Box closing and
  reopening an image (a hard reset, a disk swapped back) finds the writes.
  Floppies are no longer write-protected.
- **A hard disk**: a slot (`hdd`, raw images), and a setting for its
  controller, the XT-IDE cards with the XTIDE Universal BIOS (`xtide` for an
  8-bit machine, `xtide_at_1ch` for an AT), which take any geometry and need
  nothing from the machine's BIOS. The geometry is worked out from the
  image's size (the first usual shape that divides it). A hard disk with no
  controller is refused by name.
- **Tested on the free PC without the card's BIOS.** The XTIDE Universal
  BIOS in the free 8088 BIOS's repository (r625) loads ("Found BIOS
  extension ROM at D0000") but reports "Master at 300h: not found" with
  86Box's XT-IDE card: its default build is not configured for the card's
  register layout, and the configured builds there are for other cards. So
  the probe drives the card's registers itself (an 8-bit XT-IDE rev 1: data
  high byte at +8), the gate gives the card 8 KB of zeros as its ROM, and the
  probe writes "HD" to sector 2 and reads it back. The probe became a loader
  in the boot sector and a program in sectors 3 to 9; it no longer fit in
  one sector.
- **Floppies keep their writes in 86Box's own buffers too**: 86Box reads a
  track into memory and writes sectors back to the file, so for a floppy
  the overlay matters when the image is opened again, not between a write
  and a read. The hard disk reads its file every time, so it shows the
  overlay: with the written blocks put on purpose in memory no state
  carries, the state of frame 1150 loaded in another process read sector 2
  of the hard disk back as 0000 instead of "HD" (the session leg failed);
  as built it reads "HD".
- **Measured.** Gate, 26 passed, 0 failed, 1 skipped (FreeDOS, no floppy
  given this run): the floppy write and read succeed and read "WR"; the hard
  disk reads "HD" with status 50h; both files are unchanged afterwards; the
  sandbox, state and engine legs now run with the hard disk (the engine leg
  through a project's `hdd` slot). Texts: 55 keys, 26 languages.
- **Not tested**: a hard disk through the XTIDE Universal BIOS (needs a
  build configured for 86Box's card: 86Box's ROM set has one), any
  operating system installed on or booted from a hard disk, the AT card.

### 2026-10-31: save data

- Emulator > Export Save Data (the engine's `ce_session_savedata_*`,
  `chimera-run --export-savedata`) gives every disk the machine opened for
  writing as a file: the project's file with what the machine wrote over
  it, under the file's own name, read out through a 256 KB window in
  memory no state carries (the PCem core's way). Handed back into the same
  slot, the machine carries on from it.
- Gate, 27 passed, 0 failed, 1 skipped: through a project, both images
  come out the size of the project's files with exactly one sector changed,
  sector 2, holding "WR" and "HD". Broken on purpose (two bytes of the
  first window zeroed) and seen to fail. Not tested: an exported image
  given back into a new project (the probe writes the sector again at
  start, so it could not tell).

## 4. Where this stands (2026-10-31)

Local repository `~/chimera-cores/86box`, no remote. Upstream 86Box v6.0
(`4fef696a`), six patches. The gate (`waterbox/run-gate.sh`): 27 passed,
0 failed, 1 skipped without `FREEDOS_FLOPPY`; 28 with it (the FreeDOS leg
passed in the run of 2026-10-31 that added it, 26 legs then).

**What works, and is tested**

- Both builds (native reference, sandboxed guest), `check-wbx` clean, the
  package (deterministic zip, 26 language tables, Chimera's contract tests
  22/22), from a fresh clone too.
- On the free Xi 8088 (8088 at 4.77 MHz, CGA, AdLib, serial mouse, two
  joysticks, a floppy and a hard disk on an XT-IDE card): the BIOS screen,
  the gate's probe floppy, keyboard, mouse (relative and position), joystick
  buttons, lag frames, FM sound mixed to 48000 Hz, floppy and hard disk
  writes kept in memory, save data export, virtual time, native == sandbox
  over 1500 frames, states (every frame, a stale one noticed, carried to
  another process), a project through `chimera-run`, and the same project
  in Chimera's Qt window, headless. FreeDOS 1.3's boot floppy boots to its
  installer and takes a key, the sandbox matching the native build for
  31000 frames.
- Speed: 60 s of machine time in 7.8 s natively and 7.8 s in the sandbox
  (an 8088 at 4.77 MHz, about 7.7 times real time); a state is about 4 MB.

**Not tested** (each said where it is claimed)

- The IBM PC, PC (1982), XT and AT: declared, their ROM files named, the
  refusals tested; never run, for want of their ROMs. No SHA-1 is pinned.
- EGA, VGA, MDA, Hercules; every sound card but the AdLib; the Game
  Blaster's, Tandy's and SID's sound; the sticks' axes.
- A hard disk through the XTIDE Universal BIOS (the free build here is not
  configured for 86Box's card; 86Box's ROM set has one that is), any
  operating system on a hard disk, the AT card; an exported image given
  back into a project.
- Windows (the same package; the frontend test on Windows was not run).

**Next, in order**

1. With the owner's ROM set (`needs_from_user`): run the four IBM machines
   to their BIOS and to FreeDOS, pin each ROM file's SHA-1 in
   `tools/gen-config.py`, and boot a disk through the XTIDE BIOS from 86Box's
   set. Add a game each to the gate that runs where the ROMs are.
2. The recompiler (`-Ddynarec=true` builds `src/codegen`; a setting, part
   of the machine) and a 486 and a Pentium board: the same route, the
   interpreter against the recompiler compared as two machines.
3. CD-ROMs: make the CD audio thread run in place (patch), a slot, an IDE
   or proprietary interface.
4. More machines, each with a test; the threaded video cards (S3, ViRGE,
   Voodoo, Matrox, Mach64) only after their command queues run in place.
5. Windows: the frontend test's scenario on the Windows build.

**Traps hit** (so the next person does not)

- 86Box's "is this machine there" (`machine_available`) is satisfied by
  ANY of a machine's BIOS files; a machine set to one BIOS with another's
  file runs with no BIOS and a black screen. The core watches the files the
  machine actually reads while it is built (`plat_fopen`) and treats
  "asked about" (`plat_file_check`, a presence check of every variant)
  separately.
- 86Box's own interface switches to another machine or video card when one
  is missing (`pc_init_modules`): refuse before calling it.
- glibc's `fgetws` crashes on an `fmemopen` stream (patch 0004).
- A setting given twice to the runners is read as the first.
- The probe must be 8088 code (no 32-bit moves, no `rol ax, 4`); a 360 KB
  floppy track has 9 sectors (a loader reading 8 from sector 3 failed and
  retried for ever).
- The free XTIDE Universal BIOS image needs padding to 8 KB and its
  checksum fixed before a BIOS will run it, and even then its default build
  does not find a drive on 86Box's XT-IDE card.
- 86Box keeps a floppy's track in its own memory and writes sectors back to
  the file: a test of whether written blocks are in a state has to use the
  hard disk, which reads its file every time.
- The Qt window needs the Qt it was built with on `LD_LIBRARY_PATH`.
