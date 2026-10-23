#!/usr/bin/env python3
"""Rewrite drive paths in the DIS/VAR 80 batch files of an exported disk tree (TIFILES files, as written
by tools/timt/CopyTree.java export), for moving several hard disks into directories of one IDE disk.

usage: repath.py [--devices-only] TREE LETTER=DEVICE=DIR [...]

  e.g. repath.py --devices-only tree E=HDS1=MAIN F=HDS2=GAMES G=HDS3=DEVELOP

With --devices-only only the device names are rewritten (HDS2.X -> SCS6.GAMES.X): MDOS can map a drive
letter to a directory (ASSIGN F=C:\\GAMES, no trailing period), so the drive paths can stay.

hloberg's MAME Geneve disks are HDS1-3 (HFDC), mapped to E:, F:, G:. On the MiSTer they become
directories of the IDE disk SCS6. (assigned to C:):

  CD F:\\X.Y         -> CD C:\\GAMES.X.Y      (MDOS takes C:\\dir.dir for CD and PATH)
  F:\\X.Y, F:X, HDS2.X -> SCS6.GAMES.X...     (programs and DIR take the device form)
  F:  (a line alone)  -> C: and CD C:\\GAMES;  a following "CD \\X" goes to C:\\GAMES.X
"""
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from tidsk import tifiles_text  # noqa: E402


def records(tif):
    data, out = tif[128:], []
    for s in range(0, len(data), 256):
        sec, i = data[s:s + 256], 0
        while i < len(sec) and sec[i] != 0xff:
            n = sec[i]
            out.append(sec[i + 1:i + 1 + n].decode("latin-1"))
            i += 1 + n
    return out


def rewrite(lines, maps, devices_only=False):
    letters = {l: d for l, _, d in maps}
    devices = {v: d for _, v, d in maps}
    out, cur = [], None
    for line in lines:
        s = line.strip()
        if devices_only:
            line = re.sub(r"\b(HDS\d|WDS\d)\.", lambda m: "SCS6." + devices[m.group(1)] + "." if m.group(1) in devices else m.group(0), line)
            out.append(line)
            continue
        m = re.fullmatch(r"([A-Z]):", s.upper())
        if m and m.group(1) in letters:
            cur = letters[m.group(1)]
            out += ["C:", "CD C:\\" + cur]
            continue
        m = re.fullmatch(r"CD\s+\\(\S*)", s, re.I)
        if m and cur:
            out.append("CD C:\\" + cur + ("." + m.group(1).replace("\\", ".") if m.group(1) else ""))
            continue
        if not re.match(r"\s*(ECHO|REM)\b", line, re.I):
            if re.match(r"\s*PATH\b", line, re.I):        # the short form keeps PATH within 80 columns
                line = re.sub(r"\b([A-Z]):\\", lambda m: "C:\\" + letters[m.group(1)] + "." if m.group(1) in letters else m.group(0), line)
            line = re.sub(r"\b(CD\s+)([A-Z]):\\",
                          lambda m: m.group(1) + "C:\\" + letters[m.group(2)] + "." if m.group(2) in letters else m.group(0),
                          line, flags=re.I)
            line = re.sub(r"\b([A-Z]):\\?(?=[A-Z0-9;])",
                          lambda m: "SCS6." + letters[m.group(1)] + "." if m.group(1) in letters else m.group(0), line)
        line = re.sub(r"\b(HDS\d|WDS\d)\.", lambda m: "SCS6." + devices[m.group(1)] + "." if m.group(1) in devices else m.group(0), line)
        if len(line) > 80:
            print("too long:", line, file=sys.stderr)
        out.append(line)
    return out


def main():
    a = sys.argv[1:]
    devices_only = a[0] == "--devices-only"
    if devices_only:
        a = a[1:]
    tree, maps = a[0], [tuple(x.split("=")) for x in a[1:]]
    changed = 0
    for d, _, fs in os.walk(tree):
        for f in fs:
            p = os.path.join(d, f)
            tif = open(p, "rb").read()
            if len(tif) < 128 or tif[:8] != b"\x07TIFILES" or (tif[10] & 0x83) != 0x80 or tif[13] != 80:
                continue
            recs = records(tif)
            new = rewrite(recs, maps, devices_only)
            if new != recs:
                open(p, "wb").write(tifiles_text(tif[16:26].decode("latin-1").strip(), new))
                changed += 1
                print(os.path.relpath(p, tree))
                for a, b in zip(recs, new) if len(recs) == len(new) else []:
                    if a != b:
                        print("   ", a, "->", b)
    print("%d files changed" % changed, file=sys.stderr)


if __name__ == "__main__":
    main()
