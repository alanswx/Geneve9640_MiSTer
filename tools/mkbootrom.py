#!/usr/bin/env python3
"""Build games/Geneve/boot.rom for the MiSTer core.

usage: mkbootrom.py OUT genbt100.bin ddcc1.u3 [genbt200.bin [IDE_SRAM.bin [ti99_speech.zip [gnmbt100.bin [gnmbt200.bin]]]]]

  00000-03FFF  boot EPROM 1.00 (genbt100.bin, MAME geneve set)
  04000-05FFF  Myarc DDCC-1 DSR (ddcc1.u3, MAME ti99_ddcc1 set)
  06000-09FFF  boot EPROM 2.00 (genbt200.bin), for OSD "Boot ROM 2.00"
  10000-8FFFF  IDE card SRAM, 512 KiB (tools/mkidesram.py), for OSD "IDE card On"
  90000-97FFF  speech ROM: MAME ti99_speech.zip (cd2325a.u2a + cd2326a.u2b), each byte bit-reversed
               for the TMS6100 model (as the TI-99/4A MiSTer core's createSystemRoms.py does)
  98000-9BFFF  Genmod boot EPROM 1.00 (gnmbt100.bin, MAME genmod set), for OSD "Genmod On"
  9C000-9FFFF  Genmod boot EPROM 2.00 (gnmbt200.bin), for OSD "Genmod On" + "Boot ROM 2.00"

Use "-" for a part to skip it (the space is filled with FF).
"""
import sys
import zipfile


def load(name, size):
    d = open(name, "rb").read()
    if len(d) != size:
        raise SystemExit("%s: %d bytes, expected %d" % (name, len(d), size))
    return d


def speech_rom(name):
    if name.lower().endswith(".zip"):
        with zipfile.ZipFile(name) as z:
            d = z.read("cd2325a.u2a") + z.read("cd2326a.u2b")
    else:
        d = load(name, 0x8000)
    return bytes(int("{:08b}".format(b)[::-1], 2) for b in d)


def main():
    a = sys.argv[1:]
    if len(a) < 3:
        raise SystemExit(__doc__)
    out = bytearray(load(a[1], 0x4000) + load(a[2], 0x2000))
    if len(a) > 3:
        out += load(a[3], 0x4000) if a[3] != "-" else b"\xff" * 0x4000
    if len(a) > 4:
        out = out.ljust(0x10000, b"\xff")
        out += load(a[4], 0x80000) if a[4] != "-" else b"\x00" * 0x80000
    if len(a) > 5:
        out += speech_rom(a[5]) if a[5] != "-" else b"\xff" * 0x8000
    for i in (6, 7):
        if len(a) > i:
            out += load(a[i], 0x4000) if a[i] != "-" else b"\xff" * 0x4000
    open(a[0], "wb").write(out)
    print("%s: %d bytes" % (a[0], len(out)))


if __name__ == "__main__":
    main()
