#!/usr/bin/env python3
"""make-movie.py <package> <frames> [--key F:N:INDEX]... [--axis F:N:INDEX:VALUE]...

Writes a movie's text, as Chimera's engine reads it, for the package's
controller: "[Input]", a "LogKey:" line naming the columns (the axes, then
the buttons, as the engine orders a group), a line a frame, "[/Input]".

--key and --axis are the test runners' own (gate-harness.h): from frame F
(the runners count from 1) for N frames, the button or axis of that index in
the package's declaration. The engine counts frames from 0, so the runners'
frame F is the movie's line F - 1. An axis not named holds its neutral.
"""
import json
import sys
import zipfile


def main():
    package, frames = sys.argv[1], int(sys.argv[2])
    cfg = json.loads(zipfile.ZipFile(package).read('waterbox.config'))
    inp = cfg['input']
    buttons, axes, letters = inp['buttons'], inp['axes'], inp['mnemonics']
    keys, axis_events = [], []
    args = sys.argv[3:]
    for i in range(0, len(args), 2):
        if args[i] == '--key':
            f, n, idx = map(int, args[i + 1].split(':'))
            keys.append((f - 1, n, idx))
        elif args[i] == '--axis':
            f, n, idx, value = map(int, args[i + 1].split(':'))
            axis_events.append((f - 1, n, idx, value))
        else:
            sys.exit('no such option: ' + args[i])
    print('[Input]')
    print('LogKey:#' + ''.join(a['name'] + '|' for a in axes) + ''.join(b + '|' for b in buttons))
    for row in range(frames):
        values = []
        for i, a in enumerate(axes):
            v = a.get('neutral', 0)
            for f, n, idx, value in axis_events:
                if idx == i and f <= row < f + n:
                    v = value
            values.append(v)
        held = {idx for f, n, idx in keys if f <= row < f + n}
        cells = ''.join(letters[b] if i in held else '.' for i, b in enumerate(buttons))
        print('|' + ''.join('%5d,' % v for v in values) + cells + '|')
    print('[/Input]')


if __name__ == '__main__':
    main()
