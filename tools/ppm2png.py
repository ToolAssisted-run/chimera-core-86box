#!/usr/bin/env python3
"""ppm2png.py <in.ppm> <out.png>: a picture the harness wrote (P6), as a PNG
a person can look at. Standard library only."""
import struct
import sys
import zlib


def main():
    head, rest = open(sys.argv[1], 'rb').read().split(b'\n', 1)
    if head != b'P6':
        sys.exit('not a P6 picture')
    size, rest = rest.split(b'\n', 1)
    w, h = map(int, size.split())
    _, px = rest.split(b'\n', 1)
    raw = b''.join(b'\x00' + px[y * w * 3:(y + 1) * w * 3] for y in range(h))

    def chunk(t, b):
        return struct.pack('>I', len(b)) + t + b + struct.pack('>I', zlib.crc32(t + b) & 0xffffffff)

    open(sys.argv[2], 'wb').write(b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 2, 0, 0, 0)) +
                                  chunk(b'IDAT', zlib.compress(raw)) + chunk(b'IEND', b''))


if __name__ == '__main__':
    main()
