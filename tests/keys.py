#!/usr/bin/env python3
"""keys.py <chimera-input.c> <script>: a person's typing, as the test
runners' options (--key F:N:INDEX, gate-harness.h).

The script has a line per action, its first word the frame it starts at
(the runners count from 1); "#" starts a comment:

  3000 type cd krzinst\\n    each character pressed for 4 frames, released
                            for 4 ("\\n" is Enter); lower case, digits and
                            . \\ : - space, the keys of a PC keyboard
  3500 key Enter 5          a key by its name in the controller, held for
                            that many frames (4 when not given)
  3600 key Left Shift+F10 5 keys held together

The button's index is its place in chimera-input.c's table, which is the
package's declaration (tools/gen-config.py reads the same table).
"""
import re
import sys

CHARS = {" ": ["Space"], "\n": ["Enter"], ".": ["Period"], "\\": ["Backslash"], "-": ["Minus"],
         ":": ["Left Shift", "Semicolon"], "/": ["Slash"], ",": ["Comma"], "=": ["Equals"],
         "*": ["Left Shift", "8"]}


def main():
    src = open(sys.argv[1]).read()
    table = src[src.index("buttons[] = {"):src.index("};", src.index("buttons[] = {"))]
    names = re.findall(r'\{ "([^"]+)", (?:0x[0-9A-Fa-f]+|0) \}', table)
    index = {n: i for i, n in enumerate(names)}
    out = []
    for raw in open(sys.argv[2]):
        line = raw.split("#", 1)[0].rstrip("\n")
        if not line.strip():
            continue
        frame, verb, rest = line.strip().split(" ", 2)
        frame = int(frame)
        if verb == "type":
            text = rest.replace("\\n", "\n")
            for ch in text:
                keys = CHARS.get(ch) or ([ch.upper()] if ch.isalnum() else None)
                if not keys or any(k not in index for k in keys):
                    sys.exit("no key for %r" % ch)
                # a shift is held from the frame before the key and past it:
                # keys of one frame are pressed in the table's order
                for k in keys[:-1]:
                    out.append("--key %d:6:%d" % (frame, index[k]))
                out.append("--key %d:4:%d" % (frame + (len(keys) > 1), index[keys[-1]]))
                frame += 10 if len(keys) > 1 else 8
        elif verb == "key":
            parts = rest.rsplit(" ", 1)
            held = 4
            if len(parts) == 2 and parts[1].isdigit():
                rest, held = parts[0], int(parts[1])
            for k in rest.split("+"):
                if k not in index:
                    sys.exit("no key called %r" % k)
                out.append("--key %d:%d:%d" % (frame, held, index[k]))
        else:
            sys.exit("no such action: " + verb)
    print(" ".join(out))


if __name__ == "__main__":
    main()
