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
