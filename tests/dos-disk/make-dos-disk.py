#!/usr/bin/env python3
"""make-dos-disk.py: a disk that starts FreeDOS, made from nothing but
FreeDOS 1.3's boot floppy and the files the test scripts name.

  make-dos-disk.py --freedos <x86BOOT.img> --out <image>
                   (--floppy 360 | --hdd <cylinders>:<heads>:<sectors> --mbr <mbr.bin>)
                   [--cluster <sectors>] [--autoexec <text>] [--config <text>]
                   [--put <DOS path>=<file>]... [--put-zip <DOS folder>=<zip>]...
  make-dos-disk.py --read <image> <DOS path>      prints a file of the disk

The test scripts' FreeDOS disks (tests/hdd-dos made the first one, a 10 MB
hard disk; this does the same for any size and for a 360 KB floppy):

- one FAT12 file system, on the whole floppy, or on one active partition
  from cylinder 0, head 1, of a hard disk whose master boot record is ours
  (tests/hdd-dos/mbr.asm);
- its boot sector is the floppy's FreeDOS FAT12 boot code with the file
  system's own BPB (the drive, the geometry, where it starts): that code
  reads all it needs from the BPB, so it starts FreeDOS from a 360 KB
  floppy or a hard disk as it does from its own 1.44 MB one;
- the files are the floppy's KERNEL.SYS and FREEDOS\\BIN\\COMMAND.COM, an
  AUTOEXEC.BAT and a CONFIG.SYS if given, and the test's own files (--put,
  --put-zip: every file of a zip into a folder). Folders are made as needed.

Every date in the file system is 2026-01-01 00:00, so an image is the same
every time it is made. No FreeDOS file and no game is in this repository:
the test scripts make the image from the files they are given.

FAT12 holds fewer than 4085 clusters: a larger hard disk takes larger
clusters (--cluster, sectors a cluster; 8 is 4 KB, 16 is 8 KB).
"""
import argparse
import struct
import sys
import zipfile

DATE = ((2026 - 1980) << 9) | (1 << 5) | 1     # 2026-01-01
FLOPPIES = {
    # KB: sectors a track, heads, cylinders, sectors a cluster, root entries, media
    360: (9, 2, 40, 2, 112, 0xFD),
}


def fat12_read(img, start=0):
    """the files of a FAT12 file system at sector `start`: {path: bytes}"""
    base = start * 512
    bps, spc, res, nf, rootn, tot, media, fatsz = struct.unpack_from("<HBHBHHBH", img, base + 11)
    fat = img[base + res * bps:base + (res + fatsz) * bps]
    root = base + (res + nf * fatsz) * bps
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
            if seen > 65536:
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
            name = e[:8].rstrip().decode("ascii", "replace")
            ext = e[8:11].rstrip().decode("ascii", "replace")
            full = path + name + ("." + ext if ext else "")
            c, size = struct.unpack_from("<HI", e, 26)
            if e[11] & 0x10:
                if name not in (".", ".."):
                    walk(chain(c), full + "\\")
            else:
                files[full] = chain(c, size)

    walk(img[root:data], "")
    return files


def short_name(name):
    """'KROZ.1' -> b'KROZ    1  ', as a directory entry holds it"""
    name = name.upper()
    base, _, ext = name.partition(".")
    if not base or len(base) > 8 or len(ext) > 3:
        sys.exit("not an 8.3 name: %s" % name)
    return (base.ljust(8) + ext.ljust(3)).encode("ascii")


class Fat12:
    """a FAT12 file system being written: sectors, clusters, folders"""

    def __init__(self, sectors, spc, rootn, media, spt, heads, hidden, drive, label):
        self.spc, self.rootn = spc, rootn
        self.res, self.nfats = 1, 2
        clusters = (sectors - self.res - rootn * 32 // 512) // spc
        if clusters >= 4085:
            sys.exit("%d clusters: too many for FAT12; give --cluster a larger size" % clusters)
        self.fatsz = (clusters * 3 // 2 + 3 + 511) // 512
        self.root_at = self.res + self.nfats * self.fatsz
        self.data_at = self.root_at + rootn * 32 // 512
        self.clusters = (sectors - self.data_at) // spc
        self.img = bytearray(sectors * 512)
        self.fat = bytearray(self.fatsz * 512)
        self.next = 2
        self.bpb = (512, spc, self.res, self.nfats, rootn, sectors if sectors < 65536 else 0, media,
                    self.fatsz, spt, heads, hidden, sectors if sectors >= 65536 else 0)
        self.drive, self.label = drive, label
        self.set(0, 0xF00 | media)
        self.set(1, 0xFFF)
        # folders: path -> list of 32-byte entries; "" is the root
        self.dirs = {"": [self.volume_entry()]}
        self.dir_cluster = {}

    def volume_entry(self):
        e = bytearray(32)
        e[0:11] = self.label
        e[11] = 0x08
        struct.pack_into("<HH", e, 22, 0, DATE)
        return e

    def set(self, c, v):
        o = c * 3 // 2
        w = struct.unpack_from("<H", self.fat, o)[0]
        w = (w & 0x000F) | (v << 4) if c & 1 else (w & 0xF000) | v
        struct.pack_into("<H", self.fat, o, w)

    def alloc(self, nbytes):
        n = max(1, (nbytes + self.spc * 512 - 1) // (self.spc * 512))
        first = self.next
        if first + n - 2 > self.clusters:
            sys.exit("the disk is full")
        for k in range(n):
            self.set(self.next, self.next + 1 if k < n - 1 else 0xFFF)
            self.next += 1
        return first, n

    def write(self, first, body):
        o = (self.data_at + (first - 2) * self.spc) * 512
        self.img[o:o + len(body)] = body

    def folder(self, path):
        """make the folder (and its parents); returns its path, upper case"""
        path = path.upper().strip("\\")
        if path in self.dirs:
            return path
        parent, _, name = path.rpartition("\\")
        self.folder(parent)
        e = bytearray(32)
        e[0:11] = short_name(name)
        e[11] = 0x10
        struct.pack_into("<HH", e, 22, 0, DATE)
        self.dirs[parent].append(e)
        self.dirs[path] = []
        self.dir_cluster[path] = (e, parent)
        return path

    def put(self, path, body):
        parent, _, name = path.upper().replace("/", "\\").rpartition("\\")
        parent = self.folder(parent) if parent else ""
        first, _ = self.alloc(len(body))
        self.write(first, body)
        e = bytearray(32)
        e[0:11] = short_name(name)
        e[11] = 0x20
        struct.pack_into("<HHHI", e, 22, 0, DATE, first, len(body))
        self.dirs[parent].append(e)

    def finish(self, boot_code):
        # folders: each gets its clusters, with "." and ".." first
        for path in sorted(p for p in self.dirs if p):
            entry, parent = self.dir_cluster[path]
            size = (len(self.dirs[path]) + 2) * 32
            first, n = self.alloc(size)
            struct.pack_into("<H", entry, 26, first)
            dot = bytearray(32)
            dot[0:11] = b".          "
            dot[11] = 0x10
            struct.pack_into("<HHH", dot, 22, 0, DATE, first)
            dotdot = bytearray(32)
            dotdot[0:11] = b"..         "
            dotdot[11] = 0x10
            up = self.dir_cluster[parent][0] if parent else None
            struct.pack_into("<HHH", dotdot, 22, 0, DATE, struct.unpack_from("<H", up, 26)[0] if up else 0)
            self.dirs[path] = [dot, dotdot] + self.dirs[path]
            self._dir_at = getattr(self, "_dir_at", {})
            self._dir_at[path] = first
        for path, first in getattr(self, "_dir_at", {}).items():
            self.write(first, b"".join(bytes(e) for e in self.dirs[path]))
        root = b"".join(bytes(e) for e in self.dirs[""])
        if len(root) > self.rootn * 32:
            sys.exit("too many files in the root folder")
        self.img[self.root_at * 512:self.root_at * 512 + len(root)] = root
        for k in range(self.nfats):
            o = (self.res + k * self.fatsz) * 512
            self.img[o:o + len(self.fat)] = self.fat
        boot = bytearray(boot_code[:512])
        struct.pack_into("<HBHBHHBHHHII", boot, 11, *self.bpb)
        boot[0x24] = self.drive
        boot[0x2B:0x36] = self.label
        self.img[:512] = boot
        return bytes(self.img)


def main():
    if len(sys.argv) > 1 and sys.argv[1] == "--read":
        disk = open(sys.argv[2], "rb").read()
        start = 0
        if disk[0x1FE:0x200] == b"\x55\xaa" and disk[0x1BE] == 0x80:
            start = struct.unpack_from("<I", disk, 0x1BE + 8)[0]
        files = fat12_read(disk, start)
        want = sys.argv[3].upper()
        if want not in files:
            sys.exit("no %s on %s: %s" % (want, sys.argv[2], " ".join(sorted(files))))
        sys.stdout.buffer.write(files[want])
        return
    ap = argparse.ArgumentParser()
    ap.add_argument("--freedos", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--floppy", type=int)
    ap.add_argument("--hdd")
    ap.add_argument("--mbr")
    ap.add_argument("--cluster", type=int, default=8)
    ap.add_argument("--autoexec")
    ap.add_argument("--config")
    ap.add_argument("--put", action="append", default=[])
    ap.add_argument("--put-zip", action="append", default=[])
    a = ap.parse_args()
    floppy = open(a.freedos, "rb").read()
    fd = fat12_read(floppy)
    label = b"CHIMERA    "
    if a.floppy:
        spt, heads, cyl, spc, rootn, media = FLOPPIES[a.floppy]
        fs = Fat12(spt * heads * cyl, spc, rootn, media, spt, heads, 0, 0x00, label)
    else:
        cyl, heads, spt = map(int, a.hdd.split(":"))
        total = cyl * heads * spt
        fs = Fat12(total - spt, a.cluster, 512, 0xF8, spt, heads, spt, 0x80, label)
    # KERNEL.SYS first, then the shell: the boot code reads the kernel
    fs.put("KERNEL.SYS", fd["KERNEL.SYS"])
    fs.put("COMMAND.COM", fd["FREEDOS\\BIN\\COMMAND.COM"])
    if a.config:
        fs.put("CONFIG.SYS", a.config.replace("\\n", "\r\n").encode("ascii"))
    if a.autoexec:
        fs.put("AUTOEXEC.BAT", a.autoexec.replace("\\n", "\r\n").encode("ascii"))
    for p in a.put:
        dest, _, src = p.partition("=")
        fs.put(dest, open(src, "rb").read())
    for p in a.put_zip:
        dest, _, src = p.partition("=")
        z = zipfile.ZipFile(src)
        for name in sorted(z.namelist()):
            if not name.endswith("/"):
                fs.put(dest.rstrip("\\") + "\\" + name.upper(), z.read(name))
    part = fs.finish(floppy[:512])
    if a.floppy:
        disk = part
    else:
        def chs(lba):
            c, r = divmod(lba, heads * spt)
            h, s = divmod(r, spt)
            return bytes([h, (s + 1) | ((c >> 2) & 0xC0), c & 0xFF])
        mbr = bytearray(open(a.mbr, "rb").read())
        mbr[0x1BE:0x1CE] = bytes([0x80]) + chs(spt) + bytes([0x01]) + chs(total - 1) + struct.pack("<II", spt, total - spt)
        disk = bytes(mbr) + bytes((spt - 1) * 512) + part
        assert len(disk) == total * 512
    open(a.out, "wb").write(disk)
    print("%s: %d bytes, %d files" % (a.out, len(disk), 2 + len(a.put) + bool(a.config) + bool(a.autoexec)))


if __name__ == "__main__":
    main()
