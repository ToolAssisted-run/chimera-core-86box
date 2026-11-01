#!/usr/bin/env python3
"""Proper nouns are never translated or bent (the owner, 2026-10-31).

The names of programs, chips, machines, cards and companies this core's texts
hold - 86Box, PCem, IBM, Hercules, the XTIDE Universal BIOS, the 8088 and
the rest in NAMES - are written as they are in every language. A language
whose grammar puts endings on names says the sentence with a common noun
beside the name instead ("emulatoru 86Box", "86Box-emulaattorin"). This
checks every table in waterbox/languages, English too:

- every name an English text holds is in that text in every language, whole;
- no letter is glued to a name, before or after it, in any script but
  Korean's, Japanese's and Chinese's (their particles leave the name whole);
- no ending is hung on a name with an apostrophe, a colon or a hyphen:
  "86Box's", "IBM'in", "IBM:n", "IBM-a", "86Box-hoz" (a hyphen and a word of
  four letters or more is a compound, "XT-kone", and is allowed).

Chimera's contract tests (test-packages) check Chimera's names (Chimera,
Windows, Lua...); this one knows the core's.

  tools/check-names.py [<languages folder>]

Prints each problem as language key: what, text; exits 1 when there is any.
"""
import json
import os
import re
import sys
import unicodedata

NAMES = [
    # programs
    "86Box", "PCem", "XTIDE Universal BIOS", "XTIDE", "FreeDOS", "Chimera", "TAStudio", "Lua", "Windows",
    # companies and their products
    "IBM", "Hercules", "AdLib", "Sound Blaster", "Tandy",
    # machines, buses and ports
    "PC/XT", "PC/AT", "XT", "AT", "PS/2", "COM1", "Xi 8088",
    # cards
    "CGA", "MDA", "EGA", "VGA",
    # chips
    "8088", "8087", "286", "287", "386", "486", "Pentium",
    # the ports and buses the boards have
    "IDE",
]
# a name inside another name is not counted twice: "XT" in "PC/XT"
APOS = "'’ʼ:"
# whole words of three letters or fewer that make a compound after a hyphen,
# not an ending: Danish, Norwegian and Swedish "PS/2-mus" (a PS/2 mouse)
COMPOUND_WORDS = {"mus"}


def is_glue(ch):
    """a letter that would bend a name: any letter but CJK, kana and Hangul"""
    if not ch.isalpha():
        return False
    n = unicodedata.name(ch, "")
    return not n.startswith(("CJK", "HIRAGANA", "KATAKANA", "HANGUL"))


def is_cjk(ch):
    return ch.isalpha() and not is_glue(ch)


def spans(text):
    """each name where it stands, the longest first: "XT" inside "PC/XT" is PC/XT's"""
    taken = []
    for name in sorted(NAMES, key=len, reverse=True):
        for m in re.finditer(re.escape(name), text):
            a, b = m.start(), m.end()
            if any(a < y and x < b for x, y, _ in taken):
                continue
            before = text[a - 1] if a else ""
            after = text[b] if b < len(text) else ""
            # part of a longer number or of a word of the same letters: "18088", "DATA", "XTIDE"
            if before.isdigit() or after.isdigit() or (before and is_glue(before) and after and is_glue(after)):
                continue
            if name[-1].isalpha() and after.isupper() or name[0].isalpha() and before.isupper():
                continue
            taken.append((a, b, name))
    return taken


def problems(code, key, text, english):
    for name in NAMES:
        if any(n == name for _, _, n in spans(english)) and not any(
                n == name and not glued(text, a, b) for a, b, n in spans(text)):
            yield "%s is not there as itself" % name
    for a, b, name in spans(text):
        g = glued(text, a, b)
        if g:
            yield "%s: %s" % (g, text[max(0, a - 3):b + 5])
    # a placeholder stands for a name too (a machine, a card, a file)
    for m in re.finditer(r"%\d", text):
        g = glued(text, m.start(), m.end())
        if g:
            yield "%s: %s" % (g.replace("the name", "a placeholder"), text[max(0, m.start() - 3):m.end() + 5])


def glued(text, a, b):
    before = text[a - 1] if a else ""
    after = text[b] if b < len(text) else ""
    if before and is_glue(before):
        return "letters glued before the name"
    if after and is_glue(after):
        return "letters glued after the name"
    if after and after in APOS + "-":
        ending = re.match(r"[^\W\d_]+", text[b + 1:])
        if ending and any(is_glue(c) for c in ending.group(0)):
            if after in APOS or (len(ending.group(0)) <= 3 and ending.group(0) not in COMPOUND_WORDS):
                return "an ending hung on the name"
    return ""


def table(path):
    with open(path, encoding="utf-8") as f:
        t = json.load(f)["texts"]
    return {k: " | ".join(v.values()) if isinstance(v, dict) else v for k, v in t.items()}


def main():
    folder = sys.argv[1] if len(sys.argv) > 1 else os.path.join(
        os.path.dirname(os.path.abspath(__file__)), "..", "waterbox", "languages")
    english = table(os.path.join(folder, "en.json"))
    bad = 0
    for name in sorted(os.listdir(folder)):
        if not name.endswith(".json"):
            continue
        code = name[:-5]
        for key, text in sorted(table(os.path.join(folder, name)).items()):
            for p in problems(code, key, text, english.get(key, "")):
                print("%s %s: %s: %s" % (code, key, p, text.replace("\n", " ")))
                bad += 1
    print("%d names bent or missing" % bad, file=sys.stderr)
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
