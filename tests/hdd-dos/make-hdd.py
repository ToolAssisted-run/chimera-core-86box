#!/usr/bin/env python3
"""make-hdd.py <FreeDOS 1.3 x86BOOT.img> <mbr.bin> <out.img>
make-hdd.py --read <disk.img> <FILE.EXT>   prints a file of its partition

The test scripts' hard disk: a 10 MB image (306 cylinders, 4 heads, 17
sectors, the shape the core gives a file of that size) with one active
FAT12 partition from cylinder 0, head 1, that boots FreeDOS. Made here,
from nothing but the FreeDOS boot floppy:

- the master boot record is ours (mbr.asm);
- the partition's boot sector is the floppy's FreeDOS FAT12 boot code with
  the partition's own BPB (drive 80h, 17 hidden sectors, 4 heads, 17
  sectors a track): that code reads the drive, the geometry and where the
  partition starts from its BPB, so it boots a hard disk as it boots a
  floppy;
- the files are the floppy's KERNEL.SYS and FREEDOS\\BIN\\COMMAND.COM, and an
  AUTOEXEC.BAT of ours that sets HDBOOT to the shell's own path and writes a
  file to C:. "HDBOOT=C:\\COMMAND.COM" in the machine's memory can only come
  from the shell running from the hard disk, since the batch file says
  %COMSPEC%, not the path.

No FreeDOS file is in this repository: the gate makes the image from the
floppy it is given (FREEDOS_FLOPPY).
"""
import struct
import sys

CYL, HEADS, SPT = 306, 4, 17
TOTAL = CYL * HEADS * SPT
START = SPT                      # cylinder 0, head 1, sector 1
SIZE = TOTAL - START
SPC, RES, NFATS, ROOTN = 8, 1, 2, 512

AUTOEXEC = (b"@ECHO OFF\r\n"
            b"SET HDBOOT=%COMSPEC%\r\n"
            b"ECHO written by FreeDOS on the hard disk> C:\\WROTE.TXT\r\n"
            b"ECHO FreeDOS started from the hard disk.\r\n")


def fat12_files(img):
    """the floppy's files: {path: bytes}"""
    bps, spc, res, nf, rootn, tot, media, fatsz = struct.unpack_from("<HBHBHHBH", img, 11)
    fat = img[res * bps:(res + fatsz) * bps]
    root = (res + nf * fatsz) * bps
    data = root + rootn * 32

    def nxt(c):
        v = struct.unpack_from("<H", fat, c * 3 // 2)[0]
        return v >> 4 if c & 1 else v & 0xFFF

    def chain(c, size=None):
        out = bytearray()
        seen = 0
        while 2 <= c < 0xFF8:
            o = data + (c - 2) * spc * bps
            out += img[o:o + spc * bps]
            c = nxt(c)
            seen += 1
            if seen > 4096:
                raise ValueError("a FAT chain that does not end")
        return bytes(out[:size]) if size is not None else bytes(out)

    files = {}

    def walk(buf, path):
        for i in range(0, len(buf), 32):
            e = buf[i:i + 32]
            if e[0] == 0:
                break
            if e[0] == 0xE5 or e[11] == 0x0F or e[11] & 0x08:
                continue
            name = e[:8].rstrip().decode("ascii")
            ext = e[8:11].rstrip().decode("ascii")
            full = path + name + ("." + ext if ext else "")
            c, size = struct.unpack_from("<HI", e, 26)
            if e[11] & 0x10:
                if name not in (".", ".."):
                    walk(chain(c), full + "\\")
            else:
                files[full] = chain(c, size)

    walk(img[root:data], "")
    return files


def chs(lba):
    c, r = divmod(lba, HEADS * SPT)
    h, s = divmod(r, SPT)
    return bytes([h, (s + 1) | ((c >> 2) & 0xC0), c & 0xFF])


def main():
    if sys.argv[1] == "--read":
        disk = open(sys.argv[2], "rb").read()
        files = fat12_files(disk[START * 512:])
        if sys.argv[3] not in files:
            sys.exit("no %s on %s: %s" % (sys.argv[3], sys.argv[2], " ".join(sorted(files))))
        sys.stdout.buffer.write(files[sys.argv[3]])
        return
    floppy = open(sys.argv[1], "rb").read()
    mbr = bytearray(open(sys.argv[2], "rb").read())
    files = fat12_files(floppy)
    # 8.3 names as a directory entry holds them: 8 letters, then 3
    put = [("KERNEL  SYS", files["KERNEL.SYS"]),
           ("COMMAND COM", files["FREEDOS\\BIN\\COMMAND.COM"]),
           ("AUTOEXECBAT", AUTOEXEC)]

    clusters = (SIZE - RES - ROOTN * 32 // 512) // SPC   # an upper bound; FAT12 needs < 4085
    fatsz = (clusters * 3 // 2 + 3 + 511) // 512
    assert clusters < 4085
    root_at = RES + NFATS * fatsz
    data_at = root_at + ROOTN * 32 // 512

    part = bytearray(SIZE * 512)
    # the boot sector: FreeDOS's code, our BPB
    boot = bytearray(floppy[:512])
    struct.pack_into("<HBHBHHBHHHII", boot, 11, 512, SPC, RES, NFATS, ROOTN, SIZE, 0xF8, fatsz, SPT, HEADS, START, 0)
    boot[0x24] = 0x80                                   # the drive
    boot[0x2B:0x36] = b"CHIMERA HD "                    # the volume's label
    part[:512] = boot

    fat = bytearray(fatsz * 512)

    def setfat(c, v):
        o = c * 3 // 2
        w = struct.unpack_from("<H", fat, o)[0]
        w = (w & 0x000F) | (v << 4) if c & 1 else (w & 0xF000) | v
        struct.pack_into("<H", fat, o, w)

    setfat(0, 0xFF8)
    setfat(1, 0xFFF)
    rootdir = bytearray(ROOTN * 32)
    rootdir[0:11] = b"CHIMERA HD "
    rootdir[11] = 0x08
    nextc = 2
    for i, (name, body) in enumerate(put, start=1):
        n = max(1, (len(body) + SPC * 512 - 1) // (SPC * 512))
        first = nextc
        for k in range(n):
            setfat(nextc, nextc + 1 if k < n - 1 else 0xFFF)
            nextc += 1
        o = (data_at + (first - 2) * SPC) * 512
        part[o:o + len(body)] = body
        e = bytearray(32)
        e[0:11] = name.encode()
        e[11] = 0x20
        # 2026-01-01 00:00: a fixed date, so the image is the same every time
        struct.pack_into("<HHHI", e, 22, 0, ((2026 - 1980) << 9) | (1 << 5) | 1, first, len(body))
        rootdir[32 * i:32 * i + 32] = e
    for k in range(NFATS):
        o = (RES + k * fatsz) * 512
        part[o:o + len(fat)] = fat
    part[root_at * 512:root_at * 512 + len(rootdir)] = rootdir

    entry = bytes([0x80]) + chs(START) + bytes([0x01]) + chs(TOTAL - 1) + struct.pack("<II", START, SIZE)
    mbr[0x1BE:0x1CE] = entry
    disk = bytes(mbr) + bytes((START - 1) * 512) + bytes(part)
    assert len(disk) == TOTAL * 512
    open(sys.argv[3], "wb").write(disk)
    print("%s: %d bytes, %d/%d/%d, FAT12 partition at sector %d, %d files" %
          (sys.argv[3], len(disk), CYL, HEADS, SPT, START, len(put)))


if __name__ == "__main__":
    main()
