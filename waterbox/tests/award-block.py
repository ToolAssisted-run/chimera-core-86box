#!/usr/bin/env python3
"""award-block.py <award-cmos.h> <CMOS dump> <machine>

Prints "ok" when the CMOS a run left (the runners' --dump-cmos) holds the
Award settings block waterbox/award-cmos.h records for that machine, bytes
0x33-0x7F, and "differs" (with the first byte that differs) when not.
"""
import re
import sys


def main():
    header, dump, machine = sys.argv[1:4]
    h = open(header).read()
    first = int(re.search(r"#define AWARD_CMOS_FIRST 0x([0-9A-Fa-f]+)", h).group(1), 16)
    entry = h[h.index('{ "%s"' % machine):]
    arrays = re.findall(r"\{([^{}]*)\}", entry)[:2]
    want = bytes(int(x, 16) for x in re.findall(r"0x([0-9a-f]{2})", arrays[1]))
    c = open(dump, "rb").read()
    got = c[first:first + len(want)]
    if got == want:
        print("ok")
        return
    for i, (a, b) in enumerate(zip(got, want)):
        if a != b:
            print("differs at 0x%02X: %02X, not %02X" % (first + i, a, b))
            return
    print("differs: the CMOS is %d bytes" % len(c))


if __name__ == "__main__":
    main()
