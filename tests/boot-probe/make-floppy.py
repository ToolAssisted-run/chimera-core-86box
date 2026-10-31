#!/usr/bin/env python3
"""make-floppy.py <boot sector> <out.img>: a 360 KB floppy image whose
first sector is the probe; the rest is zeros. The probe reads nothing else
from the disk."""
import sys

boot = open(sys.argv[1], 'rb').read()
if len(boot) != 512 or boot[510:] != b'\x55\xaa':
    sys.exit('not a boot sector: %s' % sys.argv[1])
open(sys.argv[2], 'wb').write(boot + bytes(360 * 1024 - 512))
