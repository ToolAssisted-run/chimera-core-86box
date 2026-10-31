#!/usr/bin/env python3
"""make-tone.py <out.bin>: 5 seconds of a 1 kHz tone at 44100 Hz, stereo,
16-bit little-endian, as CD audio sectors (2352 bytes, 588 frames each):
375 sectors. The left channel's peak is 8000, the right's 4000, so a test
can tell the channels apart."""
import math
import struct
import sys

frames = 375 * 588
out = bytearray()
for i in range(frames):
    v = math.sin(2 * math.pi * 1000 * i / 44100)
    out += struct.pack("<hh", int(round(8000 * v)), int(round(4000 * v)))
open(sys.argv[1], "wb").write(out)
