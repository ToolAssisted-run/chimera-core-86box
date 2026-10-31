#!/usr/bin/env python3
"""make-floppy.py <probe.bin> <out.img>: a 360 KB floppy image that starts
with the probe (its loader in sector 1, a sector it writes and reads, and
the program in sectors 3 to 9); the rest is zeros."""
import sys

boot = open(sys.argv[1], 'rb').read()
if len(boot) != 4608 or boot[510:512] != b'\x55\xaa':
    sys.exit('not the probe (a boot sector, a sector, 7 sectors): %s' % sys.argv[1])
open(sys.argv[2], 'wb').write(boot + bytes(360 * 1024 - len(boot)))
