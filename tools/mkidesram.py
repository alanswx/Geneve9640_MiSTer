#!/usr/bin/env python3
"""Build the Nouspikel IDE card's 512 KiB SRAM image with Fred Kaal's IDE DSR, as IDELOAD would.

usage: mkidesram.py IDEDSR14.dsk OUT.bin

SRAM pages are 8 KiB; >4000-4FFF always shows page 0, >5000-5FFF the upper half of the selected page.
IDE-P00L goes to page 0 at >4000, IDE-Pnn H to page nn (decimal) at >5000. The clock code in P00L is
for the bq4847 (MAME's default clock chip), so IDE-BQ4852 is not applied.
"""
import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.abspath(__file__))


def tifile(dsk, name):
    tmp = "/tmp/_mkidesram_%d.tfi" % os.getpid()
    subprocess.run([sys.executable, "-I", os.path.join(ROOT, "tidsk.py"), dsk, "--extract", name, tmp],
                   check=True, stdout=subprocess.DEVNULL)
    data = open(tmp, "rb").read()[128:]
    os.remove(tmp)
    return data


def main():
    dsk, out = sys.argv[1], sys.argv[2]
    sram = bytearray(512 * 1024)
    names = subprocess.run([sys.executable, "-I", os.path.join(ROOT, "tidsk.py"), dsk],
                           check=True, capture_output=True, text=True).stdout.split()
    for name in sorted(set(n for n in names if re.fullmatch(r"IDE-P\d\d[HL]", n))):
        d = tifile(dsk, name)
        size = int.from_bytes(d[2:4], "big")
        addr = int.from_bytes(d[4:6], "big")
        page = int(name[5:7])
        body = d[6:6 + size]
        base = page * 0x2000 + (addr - 0x4000)
        sram[base:base + len(body)] = body
        print("%-9s page %2d @ >%04X size >%04X" % (name, page, addr, size))
    open(out, "wb").write(sram)


if __name__ == "__main__":
    main()
