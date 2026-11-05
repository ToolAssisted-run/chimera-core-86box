#!/usr/bin/env python3
"""gen-config.py <list-machines> <chimera-input.c> <out waterbox.config>

Writes the package's declaration from 86Box's own tables, as the pinned
86Box reports them (waterbox/list-machines.c), for the machines this core
offers (MACHINES below). What a person reads in it is keys of the
package's language tables (tools/texts.py); the values of a choice are
"id - Name", the id being 86Box's internal name, which the core takes
(cinterface.c strips what follows " - ").
"""
import json
import re
import subprocess
import sys

# One character a button writes into a movie, and the axes: the PCem core's,
# so that a PC movie's columns mean the same in both cores.
MNEMONICS = {
    "Escape": "E",
    "1": "1",
    "2": "2",
    "3": "3",
    "4": "4",
    "5": "5",
    "6": "6",
    "7": "7",
    "8": "8",
    "9": "9",
    "0": "0",
    "Minus": "M",
    "Equals": "E",
    "Backspace": "B",
    "Tab": "T",
    "Q": "Q",
    "W": "W",
    "E": "E",
    "R": "r",
    "T": "T",
    "Y": "Y",
    "U": "U",
    "I": "I",
    "O": "O",
    "P": "P",
    "Left Bracket": "B",
    "Right Bracket": "B",
    "Enter": "E",
    "Left Ctrl": "C",
    "A": "A",
    "S": "S",
    "D": "D",
    "F": "F",
    "G": "G",
    "H": "H",
    "J": "J",
    "K": "K",
    "L": "l",
    "Semicolon": "S",
    "Apostrophe": "A",
    "Backquote": "B",
    "Left Shift": "S",
    "Backslash": "B",
    "Z": "Z",
    "X": "X",
    "C": "C",
    "V": "V",
    "B": "B",
    "N": "N",
    "M": "M",
    "Comma": "C",
    "Period": "P",
    "Slash": "S",
    "Right Shift": "S",
    "Keypad Multiply": "M",
    "Left Alt": "A",
    "Space": "S",
    "Caps Lock": "L",
    "F1": "1",
    "F2": "2",
    "F3": "3",
    "F4": "4",
    "F5": "5",
    "F6": "6",
    "F7": "7",
    "F8": "8",
    "F9": "9",
    "F10": "0",
    "Num Lock": "L",
    "Scroll Lock": "L",
    "Keypad 7": "7",
    "Keypad 8": "8",
    "Keypad 9": "9",
    "Keypad Minus": "M",
    "Keypad 4": "4",
    "Keypad 5": "5",
    "Keypad 6": "6",
    "Keypad Plus": "P",
    "Keypad 1": "1",
    "Keypad 2": "2",
    "Keypad 3": "3",
    "Keypad 0": "0",
    "Keypad Period": "P",
    "F11": "F",
    "F12": "F",
    "Keypad Enter": "E",
    "Right Ctrl": "C",
    "Keypad Divide": "D",
    "Print Screen": "S",
    "Right Alt": "A",
    "Home": "H",
    "Up": "U",
    "Page Up": "U",
    "Left": "L",
    "Right": "R",
    "End": "E",
    "Down": "D",
    "Page Down": "D",
    "Insert": "I",
    "Delete": "D",
    "Left Windows": "W",
    "Right Windows": "W",
    "Menu": "M",
    "Mouse Left": "l",
    "Mouse Right": "r",
    "Mouse Middle": "M",
    "Joystick 1 Button 1": "1",
    "Joystick 1 Button 2": "2",
    "Joystick 2 Button 1": "1",
    "Joystick 2 Button 2": "2"
}
AXES = [
    {
        "name": "Mouse X",
        "min": -128,
        "max": 127,
        "neutral": 0,
        "header": "mX"
    },
    {
        "name": "Mouse Y",
        "min": -128,
        "max": 127,
        "neutral": 0,
        "header": "mY"
    },
    {
        "name": "Mouse Position X",
        "min": 0,
        "max": 65535,
        "neutral": 32768,
        "header": "MPX"
    },
    {
        "name": "Mouse Position Y",
        "min": 0,
        "max": 65535,
        "neutral": 32768,
        "header": "MPY"
    },
    {
        "name": "Joystick 1 X",
        "min": 0,
        "max": 65535,
        "neutral": 32767,
        "header": "J1X"
    },
    {
        "name": "Joystick 1 Y",
        "min": 0,
        "max": 65535,
        "neutral": 32767,
        "header": "J1Y"
    },
    {
        "name": "Joystick 2 X",
        "min": 0,
        "max": 65535,
        "neutral": 32767,
        "header": "J2X"
    },
    {
        "name": "Joystick 2 Y",
        "min": 0,
        "max": 65535,
        "neutral": 32767,
        "header": "J2Y"
    }
]

# The machines offered, and why: the Xi 8088 has a free BIOS (the tests'
# machine); IBM's PC, XT and AT are the machines most people have the ROMs
# of. 86Box has about 500; more are added one at a time, each with a test.
MACHINES = ['xi8088', 'ibmpc', 'ibmpc82', 'ibmxt', 'ibmat',
            # a 486 (Intel 420TX, Award BIOS) and a Pentium (Intel 430HX, Award
            # BIOS), the recompiler's machines: both boards have their IDE ports
            '486sp3', 'p55t2p4']

# BIOS choices 86Box offers that the core does not: the IBM XT's "(Alt)"
# BIOS reads a second chip's file (BIOS_5160_08NOV82_U19_6359116.BIN) that
# the ROM set of 86Box, v6.0, does not hold (the owner, 2026-10-31).
# waterbox/cinterface.c refuses the same ids.
BIOS_LEFT_OUT = {'ibm5160_1501512_6359116'}

# Choices the core offers out of what 86Box lets each machine have.
VIDEO = ['cga', 'mda', 'hercules', 'ega', 'vga']
SOUND = ['none', 'adlib', 'cms', 'tndy', 'ssi2001', 'sb', 'sb2.0', 'sbprov1', 'sbprov2', 'sb16']
MICE = ['none', 'msserial', 'mssystems', 'logibus', 'msbus', 'ps2']
JOYSTICKS = ['none', '2axis_2button', '2axis_4button', '4axis_4button', '2button_gamepad', '4button_gamepad',
             'ch_flightstick_pro', 'thrustmaster_fcs', 'sidewinder_pad']
# Hard disk controllers: the XTIDE Universal BIOS cards, which take any
# geometry and need no machine BIOS support (an XT has none), for an 8-bit
# and a 16-bit machine. (86Box's tables of controllers are not exported by
# list-machines; the names are src/disk/hdc_xtide.c's.)
HDC = [('none', 'None'), ('xtide', 'PC/XT XTIDE'), ('xtide_at_1ch', 'PC/AT XTIDE (Primary Only)'),
       ('internal', 'Internal')]
# The XT-IDE cards' ROMs, the XTIDE Universal BIOS, are carried by the core
# (waterbox/xtide-bios): they are not firmware the user brings.
HDC_FILES = {}
FLOPPY_DRIVES = ['none', '525_1dd', '525_2dd', '525_2qd', '525_2hd', '35_1dd', '35_2dd', '35_2hd', '35_2ed']

# The files a video card reads, by 86Box's paths (src/video): the character
# shapes of the IBM cards, the EGA's and VGA's BIOS.
VIDEO_FILES = {
    'cga': ['roms/video/mda/mda.rom'],
    'mda': ['roms/video/mda/mda.rom'],
    'hercules': ['roms/video/mda/mda.rom'],
    'ega': ['roms/video/ega/ibm_6277356_ega_card_u44_27128.bin'],
    'vga': ['roms/video/vga/ibm_vga.bin'],
}
# Machines without a BIOS choice: the file their default configuration
# reads. (86Box's "is this machine there" asks for either of the Xi 8088's
# two files, and the machine then reads the 128 KB one: see PLAN.md.)
MACHINE_FILES = {
    'xi8088': ['roms/machines/xi8088/bios-xi8088-128k.bin'],
    '486sp3': ['roms/machines/486sp3/awsi2737.bin'],
    'p55t2p4': ['roms/machines/p55t2p4/0207_j2.bin'],
}

# IBM's cassette BASIC for the IBM PC: one 32 KB file (86Box also takes the
# four 8 KB chips' files, and reads them only when this one is missing)
BASIC_FILES = {
    'ibmpc': 'roms/machines/ibmpc/ibm-basic-1.00.rom',
    'ibmpc82': 'roms/machines/ibmpc82/ibm-basic-1.10.rom',
}

# Each declared file's SHA-1 in the ROM set of 86Box, tag v6.0
# (tools/pin-roms.py writes the table). A file the set does not hold is
# declared by name only.
PINS = json.load(open(__file__.rsplit('/', 1)[0] + '/rom-sha1.json'))['sha1'] \
    if __import__('os').path.exists(__file__.rsplit('/', 1)[0] + '/rom-sha1.json') else {}

TEXT_ARG = '\x1f'


def flat(path):
    """the firmware's id: the path in 86Box's ROM set, '/' as '_'
    (chimera-plat.c, chimera_flat_name)"""
    return path[len('roms/'):].replace('/', '_')


def labelled(item):
    return '%s - %s' % (item['id'], item['name'])


def main():
    out = subprocess.run([sys.argv[1]] + MACHINES, capture_output=True, text=True, check=True).stdout
    tables = json.loads(out)['machines']
    by_id = {m['id']: m for m in tables}

    machine_values = [labelled(m) for m in tables]
    settings = []

    def setting(name, display, typ, default, **extra):
        s = {'name': name, 'display': 'setting.%s' % display, 'type': typ, 'default': default}
        s.update(extra)
        s['description'] = extra.pop('description', 'setting.%s.about' % display)
        settings.append(s)

    setting('machine', 'machine', 'enum', labelled(by_id['xi8088']), options=machine_values)

    # BIOS choices, across the machines; 'auto' is each machine's own default
    bios_values = ['auto - the machine\'s default BIOS']
    seen = set()
    for m in tables:
        for b in m['bios']:
            if b['id'].startswith('diag_') or b['id'] in BIOS_LEFT_OUT:
                continue  # diagnostic ROMs: not a BIOS a program runs on
            v = '%s - %s' % (b['id'], b['name'])
            if v not in seen:
                seen.add(v)
                bios_values.append(v)
    setting('bios', 'bios', 'enum', bios_values[0], options=bios_values)

    # CPUs, across the machines; 'auto' is the machine's first
    cpu_values = ['auto - the machine\'s first processor']
    seen = set()
    for m in tables:
        for c in m['cpus']:
            v = '%s/%d - %s %s MHz' % (c['family'], c['rspeed'], c['familyName'], c['name'])
            if v not in seen:
                seen.add(v)
                cpu_values.append(v)
    setting('cpu', 'cpu', 'enum', cpu_values[0], options=cpu_values)

    fpu_values = []
    seen = set()
    for m in tables:
        for c in m['cpus']:
            for f in c['fpus']:
                v = labelled(f)
                if v not in seen:
                    seen.add(v)
                    fpu_values.append(v)
    setting('fpu', 'fpu', 'enum', next(v for v in fpu_values if v.startswith('none ')), options=fpu_values)

    setting('memoryKB', 'memorykb', 'int', 0, min=0, max=max(m['ram']['max'] for m in tables))

    def choices(key, wanted):
        vals = []
        for want in wanted:
            for m in tables:
                hit = next((d for d in m[key] if d['id'] == want), None)
                if hit:
                    vals.append(labelled(hit))
                    break
        return vals

    video_values = choices('video', VIDEO)
    setting('video', 'video', 'enum', video_values[0], options=video_values)
    sound_values = choices('sound', SOUND)
    setting('sound', 'sound', 'enum', sound_values[0], options=sound_values)
    drives = {d['id']: d for d in tables[0]['floppyDrives']}
    drive_values = [labelled(drives[d]) for d in FLOPPY_DRIVES]
    setting('floppyA', 'floppya', 'enum', labelled(drives['525_2dd']), options=drive_values)
    setting('floppyB', 'floppyb', 'enum', labelled(drives['none']), options=drive_values)
    mouse_values = choices('mouse', MICE)
    setting('mouse', 'mouse', 'enum', mouse_values[0], options=mouse_values)
    sticks = {j['id']: j for j in tables[0]['joystick']}
    stick_values = [labelled(sticks[j]) for j in JOYSTICKS]
    setting('joystick', 'joystick', 'enum', stick_values[0], options=stick_values)
    hdc_values = ['%s - %s' % h for h in HDC]
    setting('hardDiskController', 'harddiskcontroller', 'enum', hdc_values[0], options=hdc_values)
    # IBM's cassette BASIC, in ROM on the IBM PC and XT: the PC reads it from
    # files of its own when it is on (86Box's enable_basic)
    setting('cassetteBasic', 'cassettebasic', 'bool', True)
    # the recompiler, for a 386-class processor and up
    setting('recompiler', 'recompiler', 'bool', False)
    setting('clockStart', 'clockstart', 'datetime', 946684800, min=0, max=7258118400)
    setting('framesPerSecond', 'framespersecond', 'int', 100, min=1, max=1000)

    # The firmware: each file a machine's BIOS choice or a video card reads.
    # One entry per file; its condition is every choice that reads it.
    needs = {}   # file -> list of conditions

    def need(path, cond):
        needs.setdefault(path, []).append(cond)

    names = {}
    for m in tables:
        mv = labelled(m)
        names_m = m['name']
        if m['bios']:
            for b in m['bios']:
                if b['id'].startswith('diag_') or b['id'] in BIOS_LEFT_OUT:
                    continue
                bv = '%s - %s' % (b['id'], b['name'])
                choice = [bv] + ([bios_values[0]] if b['id'] == m['biosDefault'] else [])
                for f in b['files']:
                    need(f, {'all': [{'setting': 'machine', 'is': mv}, {'setting': 'bios', 'in': choice}]})
                    names[f] = ('machine', names_m)
        for f in MACHINE_FILES.get(m['id'], []):
            need(f, {'setting': 'machine', 'is': mv})
            names[f] = ('machine', names_m)
    for mid, path in BASIC_FILES.items():
        if mid not in by_id:
            continue
        need(path, {'all': [{'setting': 'machine', 'is': labelled(by_id[mid])}, {'setting': 'cassetteBasic', 'is': True}]})
        names[path] = ('machine', by_id[mid]['name'])
    for v in video_values:
        vid = v.split(' - ')[0]
        for f in VIDEO_FILES.get(vid, []):
            need(f, {'setting': 'video', 'is': v})
            names.setdefault(f, ('video', v.split(' - ', 1)[1]))

    for v in hdc_values:
        for f in HDC_FILES.get(v.split(' - ')[0], []):
            need(f, {'setting': 'hardDiskController', 'is': v})
            names.setdefault(f, ('hdc', v.split(' - ', 1)[1]))

    firmware = []
    for path in sorted(needs):
        conds = needs[path]
        kind, owner = names[path]
        base = path.rsplit('/', 1)[1]
        entry = {
            'id': flat(path),
            'display': 'firmware.%s_rom%s%s%s%s' % (kind, TEXT_ARG, owner, TEXT_ARG, base),
            'description': 'firmware.%s_rom.about%s%s%s%s' % (kind, TEXT_ARG, owner, TEXT_ARG, path),
            'name': base,
            'label': 'firmware.file%s%s' % (TEXT_ARG, path),
            'requiredWhen': conds[0] if len(conds) == 1 else {'any': conds},
        }
        if path in PINS:
            entry['sha1'] = PINS[path]
        if path.endswith('mda.rom'):
            entry['display'] = 'firmware.font_rom' + TEXT_ARG + base
            entry['description'] = 'firmware.font_rom.about' + TEXT_ARG + path
        firmware.append(entry)

    # the buttons, in the order the core's input table has them
    src = open(sys.argv[2]).read()
    table = src[src.index('buttons[] = {'):src.index('};', src.index('buttons[] = {'))]
    buttons = re.findall(r'\{ "([^"]+)", (?:0x[0-9A-Fa-f]+|0) \}', table)
    missing = [b for b in buttons if b not in MNEMONICS]
    if missing:
        sys.exit('no mnemonic for: ' + ', '.join(missing))

    cfg = {
        'coreName': '86Box',
        'systemId': 'PC',
        'systemNames': {'PC': 'IBM PC compatible'},
        'author': 'the 86Box developers (after PCem by Sarah Walker); chimera port',
        'url': 'https://github.com/ToolAssisted-run/chimera-core-86box',
        'runsOn': ['windows-x86_64', 'linux-x86_64', 'macos-x86_64'],
        'romFile': 'rom',
        'deterministic': True,
        'memoryLayoutMiB': [64, 4, 16, 64, 1024],
        '_memoryLayoutMiB_note': 'sbrk, sealed, invisible, plain, mmap. 86Box allocates the machine\'s RAM, its '
                                 'lookup tables, the 2048x2112 screen bitmap and the 16 MB frame buffer with '
                                 'mmap and malloc, which musl sends to the mmap arena; an XT or AT is a few MB of '
                                 'state. The arena is a reservation, committed as it is touched.',
        'video': {
            '_comment': 'The capacity: 86Box draws into a 2048x2048 bitmap. The live size comes from '
                        'GetVideoWidth/Height every frame: 640x200 for CGA text, 720x350 for MDA, 640x480 for VGA.',
            'width': 2048, 'height': 2048, 'virtualWidth': 640, 'virtualHeight': 480,
            'vsyncNumerator': 100, 'vsyncDenominator': 1,
            '_vsync_note': 'A frame is a slice of machine time, not a scanout: 10 ms at 100 frames a second, '
                           'the PCem core\'s cadence. The framesPerSecond setting changes it.',
            'getBgra': 'GetVideoBgra',
        },
        'audio': {
            '_comment': 'The cards\' sound at 48000 Hz, with FM, wavetable and CD audio converted to it '
                        '(waterbox/chimera-audio.c). 86Box hands it over in 20 ms blocks, so a 10 ms frame has '
                        'a block or none.',
            'samplesPerFrame': 48000, 'channels': 2, 'rate': 48000, 'get': 'GetAudio',
        },
        'lag': {'inputWasRead': 'InputWasRead'},
        'extensions': {e: 'PC' for e in ['.img', '.ima', '.dsk', '.vfd', '.fdi', '.86f', '.td0', '.imd', '.mfm']},
        'input': {
            'name': 'PC Keyboard, Mouse and Joysticks',
            '_comment': 'The PCem core\'s controller, name for name and in the same order: a 101/102-key '
                        'keyboard, three mouse buttons and two gameport sticks of two buttons. Past 64 buttons, '
                        'so every button rides SetButton. The order is waterbox/chimera-input.c\'s.',
            'buttons': buttons,
            'mnemonics': {b: MNEMONICS[b] for b in buttons},
            'axes': AXES,
        },
        'settings': settings,
        'firmware': firmware,
    }
    with open(sys.argv[3], 'w') as f:
        json.dump(cfg, f, indent=2, ensure_ascii=False)
        f.write('\n')


if __name__ == '__main__':
    main()
