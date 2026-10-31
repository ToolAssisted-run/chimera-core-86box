#!/usr/bin/env python3
"""The 86Box sources this core compiles, one path a line, relative to the
upstream tree's src/ folder.

The list is read from upstream's own CMakeLists.txt files (every
add_executable and add_library block under src/), so it moves with the
pinned upstream, and then narrowed: the user interfaces, the host's sound and
MIDI outputs, the network back ends, the printers and the optional parts
listed in LEFT_OUT are not part of a machine the core runs, and the platform
layer is the core's own (waterbox/chimera-plat.c).

  sources.py <upstream src folder> [--dynarec]

--dynarec adds the x86-64 recompiler (src/codegen) and its timing models.
"""
import os
import re
import sys

# Libraries (CMake target names) that are not built at all.
LEFT_OUT_LIBS = {
    'plat', 'ui', 'imgui',          # the front ends (qt/, unix/)
    'vnc', 'minitrace',             # a VNC server, a tracing aid
    'mt32emu',                      # munt, an MT-32 synthesizer (MIDI out)
    'ctk5',                         # AMD K5 timing: a development-branch CPU
    'dynarec', 'cgt',               # the recompiler: only with --dynarec
}

# Single files that are not built: they reach the host (sound and MIDI
# outputs, networks, a GDB server, Discord, host CD and floppy drives), need a
# library the core does not carry (FreeType, libpng, libsndfile, libslirp,
# libserialport), or start a thread of their own.
LEFT_OUT_FILES = {
    # the host's sound and MIDI outputs; the core's platform layer takes
    # the sound instead
    'sound/openal.c', 'sound/xaudio2.c', 'sound/audio4.c', 'sound/sndio.c',
    'sound/midi_rtmidi.cpp', 'sound/midi_fluidsynth.c', 'sound/midi_mt32.c',
    'sound/midi_opl4.c', 'sound/midi_opl4_yrw801.c', 'sound/midi_soundcanvas.c',
    # a serial port joined to the host: a real port, a file, a pipe, the
    # console (which starts a thread)
    'char/char_serial.c', 'char/char_file.c', 'char/char_pipe.c',
    'char/char_stdio.c',
    # a real serial port on the host
    'device/serial_passthrough.c', 'sound/snd_mpu401_passthrough.c',
    # networks: the core keeps the cards and network.c, not the host's side
    'network/net_pcap.c', 'network/net_slirp.c', 'network/net_switch.c',
    'network/net_vde.c', 'network/net_tap.c', 'network/net_modem.c',
    'network/utils/getline.c',
    # printers that write files through FreeType and libpng
    'printer/png.c', 'printer/prt_escp.c', 'printer/prt_ps.c',
    'printer/prt_text.c', 'printer/prt_cpmap.c',
    # optional
    'gdbstub.c', 'discord.c', 'thread.cpp', 'vnc.c', 'vnc_keymap.c',
    'device/vfio.c',
}

def blocks(text):
    text = re.sub(r'#[^\n]*', '', text)
    for m in re.finditer(r'add_(?:library|executable)\(\s*(\S+)([^)]*)\)', text):
        yield m.group(1), m.group(2).split()
    # network/ gathers its files in a list first: list(APPEND net_sources ...)
    for m in re.finditer(r'list\(\s*APPEND\s+(\S+)([^)]*)\)', text):
        yield m.group(1), m.group(2).split()


def main():
    src = sys.argv[1]
    dynarec = '--dynarec' in sys.argv[2:]
    left_libs = set(LEFT_OUT_LIBS)
    if dynarec:
        left_libs -= {'dynarec', 'cgt'}
    out = []
    for dp, dn, fn in sorted(os.walk(src)):
        dn.sort()
        rel = os.path.relpath(dp, src)
        if rel.split(os.sep)[0] in ('qt', 'unix', 'mac'):
            continue
        # the newer recompiler (codegen_new, upstream's NEW_DYNAREC, off by
        # default on x86-64) defines the same library; the core builds the
        # older one, src/codegen
        if rel.split(os.sep)[0] == 'codegen_new':
            continue
        if 'CMakeLists.txt' not in fn:
            continue
        for lib, words in blocks(open(os.path.join(dp, 'CMakeLists.txt')).read()):
            if lib in left_libs:
                continue
            for w in words:
                if not re.search(r'\.(c|cc|cpp)$', w):
                    continue
                path = os.path.normpath(os.path.join(rel, w))
                if path in LEFT_OUT_FILES:
                    continue
                out.append(path)
    if dynarec:
        # added by target_sources() under if(DYNAREC) and the architecture
        out += ['cpu/386_dynarec_ops.c', 'codegen/codegen_x86-64.c',
                'codegen/codegen_accumulate_x86-64.c']
    missing = [p for p in out if not os.path.exists(os.path.join(src, p))]
    if missing:
        sys.exit('not in the upstream tree: ' + ' '.join(missing))
    seen = set()
    for p in out:
        if p not in seen:
            seen.add(p)
            print(p)


if __name__ == '__main__':
    main()
