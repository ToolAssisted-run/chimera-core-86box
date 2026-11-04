#!/usr/bin/env python3
"""pin-roms.py <waterbox.config> <86Box ROM set, tag v6.0> <out rom-sha1.json>
pin-roms.py --copy <waterbox.config> <86Box ROM set> <out folder>

Writes the SHA-1 of every ROM file the package declares, read from the ROM
set of 86Box the core is built for (version 6.0), into the table
tools/gen-config.py pins them from. A file the set does not hold is listed
as missing: it is declared by its name only, and the frontend takes any
file of that name.

Only the hashes are written: no ROM is copied, and nothing of a file's
contents is in the table.

--copy is the test scripts': every declared file the set holds is copied
into the folder under the name the core gives it (the firmware's id), and
its SHA-1 is checked against the one the package pins. It prints how many
were copied and exits 1, naming them, when a file is not the pinned one.
"""
import hashlib
import json
import os
import sys


def copy(cfg_path, romset, out):
    cfg = json.load(open(cfg_path))
    os.makedirs(out, exist_ok=True)
    n, wrong = 0, []
    for f in cfg["firmware"]:
        path = f["label"].split("\x1f", 1)[1]
        full = os.path.join(romset, path[len("roms/"):])
        if not os.path.isfile(full):
            continue
        data = open(full, "rb").read()
        if "sha1" in f and hashlib.sha1(data).hexdigest() != f["sha1"]:
            wrong.append(path)
            continue
        with open(os.path.join(out, f["id"]), "wb") as fh:
            fh.write(data)
        n += 1
    if wrong:
        print("not the pinned file: " + " ".join(wrong))
        sys.exit(1)
    print("%d files, each its pinned SHA-1" % n)


def main():
    if sys.argv[1] == "--copy":
        copy(*sys.argv[2:5])
        return
    cfg = json.load(open(sys.argv[1]))
    romset = sys.argv[2]
    pins, missing = {}, []
    for f in cfg["firmware"]:
        # the id is the path in the set, '/' as '_'; the label keeps the path
        path = f["label"].split("\x1f", 1)[1]
        full = os.path.join(romset, path[len("roms/"):])
        if os.path.isfile(full):
            pins[path] = hashlib.sha1(open(full, "rb").read()).hexdigest()
        else:
            missing.append(path)
    out = {"_comment": "SHA-1 of each declared ROM file in the ROM set of 86Box, tag v6.0 "
                       "(written by tools/pin-roms.py; read by tools/gen-config.py)",
           "sha1": dict(sorted(pins.items())),
           "notInTheSet": sorted(missing)}
    with open(sys.argv[3], "w") as fh:
        json.dump(out, fh, indent=2)
        fh.write("\n")
    print("%d pinned, %d not in the set: %s" % (len(pins), len(missing), " ".join(missing)))


if __name__ == "__main__":
    main()
