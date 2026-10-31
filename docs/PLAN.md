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

## 2. The owner's decisions (user-decided, 2026-10-31)

The owner accepted every recommendation the first round put to them. Each
answers an entry this section held as "awaiting the owner".

- **Licence.** 86Box's LZW routines (its Teledisk .td0 reader) are kept, so
  the package is GPL-3.0-or-later, as upstream's own builds are. Nothing
  changed: the package already said so.
- **Machines.** A curated list, added one at a time, each with a test. The
  first five (the Xi 8088, IBM PC 1981 and 1982, IBM XT, IBM AT) stay; a
  486 and a Pentium board come with the recompiler.
- **Controller.** System id `PC` and the PCem core's controller layout,
  button for button, so a PC movie's columns mean the same in both cores.
  Kept as it is.
- **Floppies** are writable, with no write-protect setting. Already so
  (section 3, "disks the machine writes").
- **Publishing.** A public repository and a roster row come after the IBM
  machines have run with the owner's ROMs. Until then the repository stays
  local.
- **Frame rate.** 100 frames a second (10 ms of machine time a frame), like
  the PCem core; a setting changes it. Kept.

### Proper nouns are never translated or bent (user-decided, 2026-10-31)

The owner's rule for every language table: the names of programs, chips,
machines, games and companies (86Box, PCem, IBM, Hercules, the XTIDE
Universal BIOS, the 8088, Chimera, Windows...) are written as they are. A
language whose grammar puts endings on names says the sentence with a
common noun beside the name instead ("86Box-emulaattorin", "a 8088
processzorhoz", "tegn-ROM fra IBM"). No case ending, genitive "s" or other
letters are glued to a name; a particle in another script (Korean,
Japanese) is fine.

Found and fixed by hand: 23 texts in 7 tables. Finnish (8: "86Boxin",
"IBM:n", "8088:lle", "XT:lle", "EGA:lla"), Hungarian (4: "8088-hoz",
"XT-hez", "PS/2-es", "EGA-nak"), Danish, Norwegian and Swedish (2 each:
"IBMs", "IBM:s"), Turkish (1: "VGA'nin") and English itself (4: "86Box's
ROM set" is now "the ROM set of 86Box"). The other 19 tables already wrote
every name whole.

The check is `tools/check-names.py`, a leg of the gate beside Chimera's own
`tools/check-proper-nouns.py` (which knows only Chimera's names). It reads
all 26 tables, English too, and fails when a name the English text holds is
missing from a translation, when a letter of any script but Chinese,
Japanese and Korean is glued to a name or to a placeholder (`%1` stands for
a machine's or a card's name), or when an ending is hung on one with an
apostrophe, a colon or a hyphen ("IBM'in", "IBM:n", "IBM-a"; a hyphen and a
word of four letters or more is a compound and is allowed, as is "PS/2-mus",
a mouse, by name). Seen to fail with the last bent text still in place
(Turkish "VGA'nin": "VGA is not there as itself"), and to pass after it.

### Free ROMs: the XTIDE Universal BIOS in the package, GLaBIOS in the tests (user-decided, 2026-10-31)

The owner accepted the second round's two recommendations:

- **The XTIDE Universal BIOS is carried in the package** as the ROM of
  86Box's XT-IDE cards, built from its pinned source (revision 638, GPL-2.0-
  or-later, as built and proved in the second round), the way the Fuse and
  ZEsarUX cores carry their machines' ROMs: the core answers for the file
  from memory, so the user is never asked for it. No change to Chimera: the
  package simply stops declaring that file as firmware. Done: the log entry
  "the XTIDE Universal BIOS is carried" below.
- **GLaBIOS (GPL-3.0) is built from source in the gate**, so the IBM PC and
  XT machine definitions are tested without IBM's ROMs. This does not
  replace running those machines with IBM's own BIOS, which the owner's ROM
  set now allows. Not done yet: see the log entry "GLaBIOS" below.

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
  GPL-2.0-or-later and cost old-compression .td0 images. The owner kept
  them (section 2).
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

### 2026-10-31: FreeDOS from a hard disk, through the XTIDE Universal BIOS

- **Why the free XTIDE BIOS did not find the drive.** 86Box's "PC/XT
  XTIDE" card (`hdc_xtide.c`) is an XT-IDE revision 1: the drive's
  registers at 300h to 307h, the data's high byte at 308h, the alternate
  status at 30Eh, no interrupt. Upstream's XT build of the XTIDE Universal
  BIOS is made with `MODULE_8BIT_IDE_ADVANCED`, and with that module its
  first controller is an XT-CF card at 300h (`DEVICE_8BIT_XTCF_PIO8`,
  `Src/Main.asm`), whose registers are elsewhere: "Master at 300h: not
  found". Without the module (it serves only XT-CF and JR-IDE cards, which
  86Box's card is not) the default is `DEVICE_8BIT_XTIDE_REV1` at 300h,
  which is the card. Not the port, not the card variant: the build's
  default device.
- **The build** (`tests/xtide-bios/build.sh`): revision 638 from the
  project's Subversion repository (fetched over HTTP, its tree pinned by
  hash in `xub.ref`), upstream's XT set of modules less that one, nasm,
  padded to 8 KB with its checksum. `__DATE__` is set to r638's date, so
  the image is the same whatever day it is built (sha1 1d1fc68f...). A
  second image with the module, as upstream builds it, is the negative
  control.
- **The disk** (`tests/hdd-dos/make-hdd.py`): 10 MB, 306/4/17, one active
  FAT12 partition from cylinder 0, head 1; our boot record (`mbr.asm`, 8088
  code); the partition's boot sector is FreeDOS's FAT12 boot code from the
  floppy with the partition's own BPB (drive 80h, 17 hidden sectors), which
  reads all it needs from the BPB; KERNEL.SYS and COMMAND.COM from the
  floppy; our AUTOEXEC.BAT sets `HDBOOT=%COMSPEC%` and writes C:\WROTE.TXT.
  The image is made by the gate from FREEDOS_FLOPPY; no FreeDOS file is in
  the repository.
- **Measured.** On the Xi 8088 at 4.77 MHz with no floppy: the XTIDE BIOS
  reports "Master at 300h: 86B_HD00", FreeDOS's kernel and FreeCOM start
  from C:, and by frame 3000 the machine's memory holds
  `HDBOOT=C:\COMMAND.COM` (the batch file holds `%COMSPEC%`, so only the
  running shell writes that). With upstream's build: "not found", no
  marker. The sandbox gives the native stream for all 3000 frames. Through
  a project, Export Save Data gives the disk back with C:\WROTE.TXT holding
  FreeDOS's line, and the project's file is unchanged. Gate, 31 passed, 0
  failed, 0 skipped. Broken on purpose (the XTIDE BIOS built the upstream
  way): both new legs failed.
- **Not tested**: the AT card (`xtide_at`), which needs an AT, whose BIOS
  is not free; a larger disk with EBIOS or translation.

### 2026-10-31: a CD-ROM drive, its audio made in place

- **Patch 0007**: 86Box makes CD audio on a thread of its own, woken by
  `sound_poll` every fifth 20 ms block of the main stream to make the next
  100 ms. Under `CHIMERA_CORE` the same code is a function, `sound_cd_fill`,
  that `sound_poll` calls in place at that moment; no thread and no event is
  created. The thread version is upstream's, untouched, in the `#else`.
- **The drive**: a `cdrom` slot (an ISO, or a cue with its tracks), an ATAPI
  drive at 8x as the second drive of the hard disk controller (the XT-IDE
  card's first channel, slave). A disc with no hard disk controller is
  refused by name (`error.cdrom_needs_controller`). Three new texts, in the
  26 tables.
- **The mixer was wrong for CD audio, found by the test.** The other streams
  were added to the cards' stream 2048 samples (43 ms) late, on the
  assumption, written in the sound entry above, that no block is longer
  than 28 ms. A CD block is 100 ms, so most of each landed in ring slots
  the main stream had already passed and came out 170 ms later in the wrong
  place: the gate's 1 kHz tone was in 203 of its 250 blocks. Each stream now
  has its own delay; CD audio's is 120 ms (100 ms for its block and one main
  block to spare), FM and wavetables keep 43 ms, and the ring is 16384
  samples. The earlier claim that CD audio was mixed had never been run: no
  CD drive could be configured.
- **The test disc** (`tests/cd/make-cd.sh`): an ISO 9660 track made with
  xorriso (one file; the same bytes every time) and 5 s of a 1 kHz tone as an
  audio track (left peak 8000, right 4000), one cue. The probe asks the
  drive for its table of contents, reads sector 16 and plays track 2 with
  PLAY AUDIO(10), each command up to four times (the first after a disc goes
  in answers "unit attention").
- **Measured.** Gate, 33 passed, 0 failed, 0 skipped: with the cue, sector
  16 reads 01h "CD001" (status 50h), track 2 starts at sector 184 (the ISO's
  length), and with no sound card the tone peaks at 7998 in all 250 of the
  20 ms blocks of its 5 s, from frame 1045 to 1543, with silence before it;
  the ISO alone reads the same sector and refuses PLAY (status 51h, no track
  2). The sandbox gives the native stream for 2200 frames, sound included;
  a state saved and loaded before every frame, and one saved at frame 1300
  (mid-tone) and loaded in another process, end as the straight run. Broken
  on purpose: the old mixer (203 blocks, the leg failed), a stale state in
  the CD run (the end differs).
- **Not tested**: a CD read by DOS (no free ATAPI driver for an XT-IDE card
  is used here; on an AT the card is a plain IDE port, for which FreeDOS has
  drivers - not run, for want of a free AT BIOS); CD audio through a sound
  card's CD input and mixer volume (the run has no sound card); disc
  swapping (only the slot's first file is in the drive, as for floppies).

### 2026-10-31 (third round): the XTIDE Universal BIOS is carried

- **What changed.** The core now holds the ROMs of both of 86Box's XT-IDE
  cards and answers for them from memory (`chimera_builtin_rom` in
  `chimera-plat.c`); the package no longer declares them as firmware, so
  Chimera never asks for them. The build makes them from the XTIDE
  Universal BIOS's source, revision 638 (`waterbox/xtide-bios`, moved from
  `tests/`): `build.sh` assembles them with nasm, and `embed.py` writes them
  into the build as C arrays after checking each image's SHA-1 against the
  one proved here, so another assembler that writes other bytes stops the
  build. `XUB_SRC` (meson option `xub_src`) is now needed by every build,
  not only by the tests. A carried ROM wins over a mounted file of the same
  name; only the native build's `CHIMERA_86BOX_NO_BUILTIN_ROMS` turns that
  off, for the test scripts' negative control.
- **The two images.** The XT card's is the second round's (upstream's XT
  set less `MODULE_8BIT_IDE_ADVANCED`, SHA-1 `1d1fc68f`). The AT card's is
  upstream's AT set as it is (`DEFINES_AT`, SHA-1 `28c3090c`); it is proved
  on the IBM AT in the entry "IBM's machines" below.
- **The licence.** XUB is GPL-2.0-or-later; `waterbox/xtide-bios/COPYING`
  (its copyright line and licence text) travels in the package's licence
  list, with the source revision's address.
- **What it changed in the tests.** Every probe run has an XT-IDE card, so
  it now runs the real XUB instead of 8 KB of zeros: XUB finds the drive,
  then waits for a second one that is not there, and the probe starts at
  about frame 1540 instead of 800. Every frame number of the probe's runs
  moved 1000 later (2500 frames a run), and the CD runs' 490 (the tone now
  plays from frame 1535). The lag-frame leg asked that the run with input
  read controls in at least as many frames as the idle run; with XUB the
  run with input reads fewer (159 against 179: a key makes the probe read
  both disks again, and it reads no control while it waits). That order
  never meant anything, so the leg now asks for lag frames in both runs and
  different counts.
- **Texts.** The two firmware texts of the hard disk ROM are gone from the
  26 tables, and the controller setting's text says the core brings that
  BIOS ("Each needs its ROM file" was the sentence before).
- **Measured.** Gate, 33 passed, 0 failed, 0 skipped (FreeDOS, the CD, the
  engine and the window included). Broken on purpose: with the carried ROM
  turned off and no file of that name, FreeDOS's hard disk run left no
  `HDBOOT=C:\COMMAND.COM` in memory (0 against 1), so the hard disk leg
  fails. (86Box does not refuse an XT-IDE card without its ROM; it runs
  without one. The core no longer depends on that.)

### 2026-10-31 (third round): IBM's machines, with IBM's ROMs

The owner supplied 86Box's ROM set at tag v6.0 for local tests
(`PCBOX_ROMS`; never on a public runner, never in the repository).

- **SHA-1s pinned.** `tools/pin-roms.py` reads each file the package
  declares from the set and writes its SHA-1 into `tools/rom-sha1.json`;
  `tools/gen-config.py` puts it in the declaration (`sha1`), so Chimera
  takes only that file. 27 files are declared now; 26 are pinned. One is not
  in the set: `machines/ibmxt/BIOS_5160_08NOV82_U19_6359116.BIN`, the second
  chip of the XT's "(Alt)" BIOS, which 86Box offers but its ROM set does not
  hold; it stays declared by name. With `--copy` the same tool is how the
  gate takes the files out of the set, each checked against its pin.
- **Cassette BASIC: a file the declaration missed.** The IBM PC (1981 and
  1982) reads IBM's cassette BASIC from files of its own
  (`ibm-basic-1.00.rom`, `ibm-basic-1.10.rom`, or the four chips' files)
  whenever 86Box's `enable_basic` is on, which is its default. The package
  did not declare them, so the PC was refused at load ("these ROM files are
  missing") with every file the frontend had asked for given: found the
  first time it ran. Now a setting, "Cassette BASIC from IBM"
  (`cassetteBasic`, on by default, written into the machine's section of
  the configuration), and the BASIC file is required while it is on. The
  XT's BASIC is in its BIOS chips and needs nothing more.
- **Memory beyond the motherboard.** 86Box's IBM PC takes 64 KB on its
  motherboard and the XT 256 KB; more was cut to that, silently. A real
  machine had a memory card, and DOS games want 640 KB: on an 8-bit machine
  a `memoryKB` above the motherboard's is now the motherboard full plus
  86Box's generic PC/XT memory card for the rest, up to 640 KB. The BIOS
  counts it through the switches 86Box sets from both. The card's memory is
  a second memory domain, "Memory Card RAM" (it starts at the address where
  the motherboard's ends; 86Box keeps it in the card's own buffer), and the
  runners' `--dump-ram` writes every domain in turn. The IBM PC's 1981 BIOS
  reads four memory switches and counts at most 544 KB (with 640 it counted
  128); the 1982 BIOS counts 640.
- **The character ROM and EGA/VGA.** 86Box reads IBM's character ROM
  (`mda.rom`) at every video reset, whatever the card, but only CGA, MDA
  and Hercules draw with it. The package asks for it only for those three,
  and the core refused an EGA or VGA machine without it (found by the EGA
  test's control). The core now lets that file be missing when the card
  does not draw with it; EGA and VGA run with no character ROM.
- **The IBM AT's empty CMOS.** The core keeps no CMOS memory between runs,
  so the AT's BIOS says "161-System Options Not Set-(Run SETUP)" and waits
  for F1 (and F1 held during the keyboard test gives "301-Keyboard Error"
  instead). After F1 it starts from a 360 KB floppy, but not from a 1.44 MB
  one: it knows a drive's kind only from the CMOS. Not changed: running
  IBM's SETUP disk inside the machine would set it for that run only, and a
  CMOS kept with the project is a question for the owner (questions).
- **What ran, with IBM's own BIOS** (the gate's new legs, which SKIP without
  `PCBOX_ROMS`):
  - each machine's BIOS: the IBM PC (1981, 544 KB) and PC (1982, 640 KB) and
    the XT (640 KB) count their memory and go into IBM's cassette BASIC; the
    AT counts 512 KB and stops at the 161 message. The PC with its BASIC file
    taken away is refused naming it; with cassette BASIC off it runs.
  - FreeDOS on all four, from a 360 KB floppy the gate makes from FreeDOS
    1.3's boot floppy (the floppy round 1 used is 1.44 MB, which the PC and
    XT cannot read): `tests/dos-disk/make-dos-disk.py` writes a FAT12 floppy
    or hard disk with FreeDOS's boot code, kernel and shell and the test's
    files. AUTOEXEC.BAT sets `FDBOOT=%COMSPEC%`, and
    `FDBOOT=A:\COMMAND.COM` is in memory by frame 12000 on each (the AT is
    given F1 at frame 3000). Sandbox == native on each, 12000 frames.
  - the AT card's XTIDE Universal BIOS, the core's: FreeDOS from the hard
    disk of the Xi 8088's test, on the IBM AT; with the carried ROM turned
    off, no marker. Sandbox == native, 8000 frames.
  - each video card with IBM's ROMs: MDA 720x350, Hercules 720x350, CGA
    640x200 on the XT; EGA 640x350 and VGA 720x400 on the AT, both with no
    character ROM; each picture lit. Control: the EGA with 16 KB of zeros as
    its BIOS lights no pixel.
- **Broken on purpose, each seen to fail:** the BIOS leg at first (the
  1981 PC at 544 KB still testing its memory at frame 6000, and the refusal
  naming more files than the leg expected: it now runs 9000 frames and
  reads the first file named); the video leg at first (the EGA refused for
  want of the character ROM, the bug above); FreeDOS on the 1981 PC with
  64 KB, no memory card: no marker by frame 12000; the AT's hard disk with
  the carried ROM off: no marker (the leg's own control).
- **Gate**, with `PCBOX_ROMS`, `FREEDOS_FLOPPY` and Kroz (next entry): 39
  passed, 0 failed, 0 skipped, in 10 minutes.
- **Typing.** `tests/keys.py` turns a script of typed text and keys into the
  runners' `--key` options (a shifted character holds Shift from the frame
  before: keys of one frame are pressed in the table's order); the runners
  now take 4096 input events instead of 128.

### 2026-10-31 (third round): a real game, Kingdom of Kroz II

- **The game.** Kingdom of Kroz II (Scott Miller, Apogee, 1990; freeware
  since 2009), from the owner's copy of its archive, `1kroz.zip` (SHA-1
  `6f9fcb06...`): INSTALL.BAT, DEICE.EXE (id Software's installer), KROZ.DAT
  and KROZ.1. It calls itself "Kingdom of Kroz Version 1.0" in its installer
  and "Kingdom of Kroz II ... Version 2.0" in the game. A CGA text game for
  an XT: it suits the IBM XT.
- **The machine.** An IBM XT with IBM's BIOS, 640 KB (256 on the
  motherboard, 384 on the memory card), CGA, and the XT-IDE card with the
  XTIDE Universal BIOS the core carries. The disk is made by the gate: 10 MB,
  FreeDOS (kernel and shell, from its boot floppy) and the archive in
  `C:\KRZINST` (`make-dos-disk.py --put-zip`). Nothing of the game is in the
  repository; `PCBOX_KROZ` names the zip.
- **Installed inside DOS** by its own installer, typed by the movie
  (`tests/games/kroz.keys`): at FreeDOS's prompt (frame 7000) `cd krzinst`,
  `install`; DEICE asks the drive (C), the folder (`\KROZ`, as offered) and
  whether to create it (Y), joins KROZ.1 into KROZ.EXE, and the batch file
  runs it: PKSFX 2.04g unpacks KINGDOM.EXE, CATALOG.EXE and ORDER.FRM and
  the archive is deleted (`C:\KROZ>` by frame 13000). Then `kingdom`, and
  its questions: colour (C), slow PC (S), a key at the title, novice (N), a
  key at the instructions, a key at the registration notice, B to begin.
  Level 1 is on screen at frame 18250; a key starts it, and the movie walks
  four steps right and two up (`kroz-play.keys`).
- **Measured.** Gate legs, which SKIP without `PCBOX_KROZ`, `PCBOX_ROMS`
  and `FREEDOS_FLOPPY`: the level's picture is lit (53,692 pixels at frame
  18250); the player, found by its yellow in the play field, moves from
  (259,67) to (270,56) against the run that stood still; 18900 frames,
  sandbox == native, the motherboard's and the card's memory. The same
  input as a movie in a project: `chimera-run` runs it, and a second
  `chimera-run` in a new process replays it; both end with the same memory
  as each other and as the sandbox runner, and Export Save Data gives the
  disk back with `C:\KROZ\KINGDOM.EXE` (53,707 bytes) in it, the project's
  file unchanged.
- **Broken on purpose:** the movie with the six steps taken out ends with
  memory that is not the sandbox runner's (the movie leg fails); without the
  steps the player stays at (259,67) (the play leg fails).
- **A wrong first check.** The first version of the leg looked for the score
  to change; it does not (the six steps pick nothing up, and the panel says
  the same with and without them), and the leg failed. It now compares the
  player's place.
- **Not tested**: playing past the first steps; Kroz's sound (the PC
  speaker, which the frame's sound carries, was not looked at).

### 2026-10-31 (third round): a 486 and a Pentium, and the recompiler

- **Two boards.** The ASUS PCI/I-486SP3 (Intel 420TX, Award BIOS 4.50,
  `486sp3`) and the ASUS P/I-P55T2P4 (Intel 430HX, Award BIOS 4.51PG,
  `p55t2p4`), each with its one BIOS file from the ROM set, now declared
  (`MACHINE_FILES` in `gen-config.py`) and pinned. Neither board's devices
  start a thread. Their hard disk goes on the board's own IDE port: a new
  controller choice, "Internal", refused by name on a machine that has no
  such port (86Box's table lets any machine name it). Memory up to the
  boards' 128 MB and 512 MB; only 16 MB was run.
- **The recompiler is in the build** (meson option `dynarec`, now on by
  default): 86Box's older x86-64 recompiler, `src/codegen`. The source
  list picked up the newer one, `codegen_new`, too (both define the same
  library): it is left out. A setting, "Recompiler" (`recompiler`, off by
  default), turns it on for a 386-class processor and up; with it off the
  same build interprets. The two are two machines (their streams differ
  from the first frame), so the setting is part of a movie. `check-wbx`:
  clean.
- **Faults are not its fast path.** Read in the source: the recompiler
  gets its code memory from `plat_mmap` (ours: ordinary memory, read,
  write and run), finds code the machine overwrites with the dirty masks
  the memory write functions keep, and has no page protection, no signal
  handler and no host CPU test (`codegen/`, `cpu/386_dynarec*.c`). What it
  emits is SSE2 at most, the baseline.
- **Found: the same machine was not the same in the sandbox (patch
  0008).** With the recompiler on, the Pentium's sandbox run left the
  native one at frame 1534 (one cycle, in the BIOS at F000:6E10), and the
  sandbox was the same as itself every time. Traced block by block: the
  block starting at F000:6E10 ended one instruction later in the sandbox.
  A block ends when its host code fills `BLOCK_MAX` (1620) bytes, and the
  emitter picks a 5-byte call when the function is within 2 GB of the
  code buffer and a 12-byte one when it is not: in the sandbox the core's
  code and its buffers are near each other, natively they are far apart.
  Code of another length ends blocks elsewhere, and the cycles counted at a
  block's end move. Patch 0008 makes the emitter always take the long form
  (calls, the 32-bit-address shortcuts), under `CHIMERA_CORE`: the code
  is the same length wherever the host puts things. After it, Doom's 7700
  frames are the same natively and in the sandbox. Before it the
  interpreter was already the same both ways.
- **States.** A Pentium with 16 MB is a 57 MB state at FreeDOS's prompt
  and 69 MB in Doom (the 486, 58 MB); saving and loading one before every frame over a whole run is
  slow, so the runners take `--rerecord-from F` (the stale-state control
  moves with it).
- **Measured** (gate legs, which SKIP without `PCBOX_ROMS` and
  `FREEDOS_FLOPPY`): each board starts FreeDOS from a 1.44 MB
  floppy the gate makes (`FDBOOT=A:\COMMAND.COM` by frame 3000, the BIOS
  given F1 at 1500), with the interpreter and with the recompiler,
  natively and in the sandbox, the same stream both ways for each, and the
  interpreter's stream is not the recompiler's. Host time, native, 3000
  frames: 5 s for the 486 either way, 7 s for the Pentium either way (most
  of it the BIOS waiting). With the recompiler on, states saved and loaded
  before every frame from 2500 to 3000, and a state of frame 2900 carried
  to another process, end as the straight run; a stale state is noticed.
  Broken on purpose: with patch 0008 taken out, the Pentium's recompiled
  run in the sandbox leaves the native one at frame 1534 again.
- **Doom.** Doom v1.9 shareware (id Software, 1995), from the owner's copy
  of `doom19s.zip` (SHA-1 `8d0fbbbe...`; `PCBOX_DOOM`), on the P/I-P55T2P4
  with the Pentium at 133 MHz, 16 MB, IBM VGA, no sound card. A 30 MB hard
  disk made by the gate (63 sectors, 16 heads, 61 cylinders; one FAT12
  partition with 8 KB clusters) holds FreeDOS and the archive in
  `C:\DMINST`; the BIOS's defaults find it on the board's IDE port. The
  movie (`tests/games/doom.keys`) presses F1 at the BIOS's CMOS message,
  types `install`, answers DEICE (drive C, `\DOOMS`, create it), lets the
  batch file unpack the game and run SETUP (keyboard only, no music, no
  sound effects, save and launch), and from the title's demo starts a new
  game: Knee-Deep in the Dead at the offered skill. The first level, E1M1,
  is on screen at frame 7600; Tab opens the map, whose foot names it "E1M1:
  HANGAR" (seen in the picture). Measured (legs that SKIP without
  `PCBOX_DOOM`, `PCBOX_ROMS` and `FREEDOS_FLOPPY`): the map's title is drawn
  at frame 7700 (784 red pixels where none are without the map) with the
  recompiler (17 s, native) and with the interpreter (20 s): the game asks
  little of the processor at its first level, so the recompiler is worth 15
  percent here. 7700 frames, sandbox == native. As a movie in a project,
  `chimera-run` ends with the sandbox runner's memory, and Export Save Data
  gives back the disk with `C:\DOOMS\DOOM1.WAD` (4,196,020 bytes) and
  SETUP's `DEFAULT.CFG`; the project's file unchanged. Broken on purpose:
  the same movie with the interpreter ends with other memory, so the
  movie leg would fail; without the map the title's red is 0.
- **Not tested**: playing Doom (the movie only reaches the level); Doom's
  sound (no sound card was given, and SETUP was told none); a Pentium or
  486 with more than 16 MB; other processors the boards take; the boards'
  other BIOS settings (the CMOS defaults were used as loaded); EGA, the
  sound cards or a CD on these boards; the recompiler on any other board.
- **Gate**, with `PCBOX_ROMS`, `FREEDOS_FLOPPY`, `PCBOX_KROZ` and
  `PCBOX_DOOM`: 43 passed, 0 failed, 0 skipped, in 15 minutes.

## 4. Where this stands (2026-10-31, second round)

Local repository `~/chimera-cores/86box`, no remote (publishing waits for
the IBM machines to run with the owner's ROMs, section 2). Upstream 86Box
v6.0 (`4fef696a`), seven patches. Tested against Chimera main `cb46d2b7`
(`~/chimera-scratch-bump`), both builds from clean. The gate
(`waterbox/run-gate.sh`) with `FREE_BIOS_SRC`, `FREEDOS_FLOPPY` and
`XUB_SRC`: 33 passed, 0 failed, 0 skipped (4 min 20 s, run last at the
commit "a CD-ROM drive, with its audio made in place"). Without
`FREEDOS_FLOPPY` and `XUB_SRC` the three FreeDOS legs skip; without
`FREE_BIOS_SRC` only the build, package and text legs run.

**What works, and is tested**

- Both builds (native reference, sandboxed guest), `check-wbx` clean, the
  package (deterministic zip, 26 language tables, Chimera's contract tests
  22/22, `check-core-texts.py` 58 keys, the name check on all 26 tables).
- On the free Xi 8088 (8088 at 4.77 MHz, CGA, AdLib, serial mouse, two
  joysticks, a floppy, a hard disk on an XT-IDE card, an ATAPI CD-ROM
  drive): the BIOS screen, the probe floppy, keyboard, mouse (relative and
  position), joystick buttons, lag frames, FM sound, CD audio, floppy and
  hard disk writes kept in memory, save data export, virtual time, native
  == sandbox, states (every frame, a stale one noticed, carried to another
  process), a project through `chimera-run`, the same project in Chimera's
  Qt window (headless).
- FreeDOS 1.3's boot floppy to its installer (31000 frames, sandbox ==
  native). FreeDOS from a hard disk made by the gate, through the XTIDE
  Universal BIOS built from source for 86Box's card; what FreeDOS writes to
  C: comes back through Export Save Data.
- A CD made by the gate (ISO 9660 track, audio track): read over ATAPI, its
  audio heard in full, sandbox == native and states while it plays.
- Names are never translated or bent in the 26 tables (the owner's rule),
  checked by `tools/check-names.py` and Chimera's `check-proper-nouns.py`.

**Not tested** (each said where it is claimed)

- The IBM PC, PC (1982), XT and AT: declared, their ROM files named, the
  refusals tested; never run, for want of their ROMs. No SHA-1 is pinned.
- The recompiler: 86Box offers it only for a 386-class processor and up
  (`CPU_SUPPORTS_DYNAREC`, from the RapidCAD on); every machine with a free
  BIOS here is an 8088 (the Xi 8088, and GLaBIOS on the IBM PC and XT), so
  nothing free can exercise it. It waits for the owner's 486 and Pentium
  ROMs. `cpu_use_dynarec` stays 0.
- EGA, VGA, MDA, Hercules; every sound card but the AdLib; the sticks'
  axes; the AT XT-IDE card; a CD read by DOS; CD audio through a sound
  card's mixer; disc and disk swapping (only a slot's first file is in its
  drive, floppies included, although the floppy slots take a list).
- Windows (the same package; the frontend test on Windows was not run).

**Next, in order**

1. With the owner's ROM set (`needs_from_user`): run the four IBM machines
   to their BIOS and to FreeDOS, pin each ROM file's SHA-1 in
   `tools/gen-config.py`; then the decision to publish (section 2).
2. A 486 and a Pentium board with the owner's ROMs, and with them the
   recompiler (`-Ddynarec=true`, a setting that is part of the movie),
   compared with the interpreter as two machines.
3. Disk and disc swapping: the slot lists exist, the drives take only the
   first file.
4. GLaBIOS (GPL) as a free BIOS for the IBM PC and XT machines, as the Xi
   8088's free BIOS is: those machines could then be tested without the
   owner's ROMs (only the character ROM stand-in is needed).
5. More machines, each with a test; the threaded video cards (S3, ViRGE,
   Voodoo, Matrox, Mach64) only after their command queues run in place.
6. Windows: the frontend test's scenario on the Windows build.

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
- Upstream's XT build of the XTIDE Universal BIOS defaults to an XT-CF card
  (MODULE_8BIT_IDE_ADVANCED) and does not find the drive on 86Box's XT-IDE
  card; build it without that module. Its version string carries the build
  date: `-D__DATE__` fixes it.
- 86Box keeps a floppy's track in its own memory and writes sectors back to
  the file: a test of whether written blocks are in a state has to use the
  hard disk, which reads its file every time.
- CD audio comes in 100 ms blocks; a stream's delay in the mixer must be
  longer than its block, or it lands in slots already played.
- An absent ATAPI slave reads status 00h, not FFh.
- The Qt window needs the Qt it was built with on `LD_LIBRARY_PATH`.
