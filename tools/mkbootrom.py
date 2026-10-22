#!/usr/bin/env python3
"""Build games/Geneve/boot.rom for the MiSTer core.

usage: mkbootrom.py OUT genbt100.bin ddcc1.u3 [genbt200.bin [IDE_SRAM.bin]]

  00000-03FFF  boot EPROM 1.00 (genbt100.bin, MAME geneve set)
  04000-05FFF  Myarc DDCC-1 DSR (ddcc1.u3, MAME ddcc1 set)
  06000-09FFF  boot EPROM 2.00 (genbt200.bin), for OSD "Boot ROM 2.00"
  10000-8FFFF  IDE card SRAM, 512 KiB (tools/mkidesram.py), for OSD "IDE card On"
"""
import sys


def load(name, size):
    d = open(name, "rb").read()
    if len(d) != size:
        raise SystemExit("%s: %d bytes, expected %d" % (name, len(d), size))
    return d


def main():
    a = sys.argv[1:]
    if len(a) < 3:
        raise SystemExit(__doc__)
    out = bytearray(load(a[1], 0x4000) + load(a[2], 0x2000))
    if len(a) > 3:
        out += load(a[3], 0x4000)
    if len(a) > 4:
        out = out.ljust(0x10000, b"\xff") + load(a[4], 0x80000)
    open(a[0], "wb").write(out)
    print("%s: %d bytes" % (a[0], len(out)))


if __name__ == "__main__":
    main()
