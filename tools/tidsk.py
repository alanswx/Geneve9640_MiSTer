#!/usr/bin/env python3
"""List the files on a TI-99 / Geneve V9T9 sector image (.dsk).

usage: tidsk.py IMAGE [IMAGE...]
       tidsk.py IMAGE --extract NAME OUTFILE     (raw file data, TIFILES header added)
       tidsk.py IMAGE --add-text NAME "line1|line2"  (adds or replaces a DIS/VAR 80 file)
       tidsk.py IMAGE --new VOLNAME TRACKS             (blank DSDD image, 18 sectors/track, 40 or 80 tracks)
       tidsk.py IMAGE --add FILE[=NAME] ...            (TIFILES files; the name defaults to the file name)

The volume information block is sector 0, the file descriptor index sector 1.
"""
import struct
import sys

TYPES = {0x00: "Dis/Fix", 0x80: "Dis/Var", 0x02: "Int/Fix", 0x82: "Int/Var"}


def sector(img, n):
    return img[n * 256:(n + 1) * 256]


def fdrs(img):
    idx = sector(img, 1)
    for i in range(0, 256, 2):
        n = struct.unpack(">H", idx[i:i + 2])[0]
        if n == 0:
            break
        yield n, sector(img, n)


def describe(fdr):
    name = fdr[0:10].decode("latin-1").rstrip()
    flags = fdr[0x0c]
    if flags & 0x01:
        ftype = "Program"
    else:
        ftype = TYPES.get(flags & 0x82, "?")
    sectors = struct.unpack(">H", fdr[0x0e:0x10])[0]
    eof = fdr[0x10]
    reclen = fdr[0x11]
    size = sectors * 256 - ((256 - eof) % 256 if eof else 0) if flags & 0x01 else sectors * 256
    return name, ftype, sectors, reclen, size


def data_sectors(img, fdr):
    out = []
    for i in range(0x1c, 0x100, 3):
        b = fdr[i:i + 3]
        if b == b"\0\0\0":
            break
        start = b[0] | ((b[1] & 0x0f) << 8)
        offs = (b[1] >> 4) | (b[2] << 4)
        need = offs + 1 - len(out)
        out.extend(range(start, start + need))
    return out


def alloc_bitmap(vib):
    return bytearray(vib[0x38:0x100])


AU = [1]          # sectors per bitmap bit: 1, or 2 when the disk has more than 1600 sectors


def bit(bm, n, v=None):
    n //= AU[0]
    i, b = n >> 3, n & 7
    if v is None:
        return (bm[i] >> b) & 1
    if v:
        bm[i] |= 1 << b
    else:
        bm[i] &= ~(1 << b)


def add_text(path, name, lines):
    img = bytearray(open(path, "rb").read())
    vib = img[0:256]
    total = struct.unpack(">H", vib[0x0a:0x0c])[0]
    spt = vib[0x0c]
    bm = alloc_bitmap(vib)
    AU[0] = 2 if total > 1600 else 1
    # remove an existing file of that name
    entries = [(n, bytes(f)) for n, f in fdrs(img)]
    for n, f in list(entries):
        if describe(f)[0] == name:
            for sct in data_sectors(img, f) + [n]:
                bit(bm, sct, 0)
            entries.remove((n, f))
    # records into sectors
    recs = [l.encode("latin-1")[:80] for l in lines]
    secs, cur = [], bytearray()
    for r in recs:
        if len(cur) + 1 + len(r) + 1 > 256:
            secs.append(bytes(cur + b"\xff").ljust(256, b"\0"))
            cur = bytearray()
        cur += bytes([len(r)]) + r
    eof = len(cur)
    secs.append(bytes(cur + b"\xff").ljust(256, b"\0"))
    # allocate the FDR (from sector 2) and the data (contiguous, from sector 34 as TI does)
    def free(start, count):
        n = start
        n -= n % AU[0]
        while n + count <= total:
            if all(not bit(bm, n + k) for k in range(count)):
                return n
            n += AU[0]
        raise SystemExit("disk full")
    fdr_s = free(2, 1)
    bit(bm, fdr_s, 1)
    data_s = free(34, len(secs))
    for k in range(len(secs)):
        bit(bm, data_s + k, 1)
        img[(data_s + k) * 256:(data_s + k + 1) * 256] = secs[k]
    fdr = bytearray(256)
    fdr[0:10] = name.encode("latin-1").ljust(10)
    fdr[0x0c] = 0x80                       # DIS/VAR
    fdr[0x0d] = 3                          # records per sector (80-byte records)
    fdr[0x0e:0x10] = struct.pack(">H", len(secs))
    fdr[0x10] = eof
    fdr[0x11] = 80
    fdr[0x12:0x14] = struct.pack("<H", len(secs))
    last = len(secs) - 1
    fdr[0x1c:0x1f] = bytes([data_s & 0xff, ((data_s >> 8) & 0x0f) | ((last & 0x0f) << 4), last >> 4])
    img[fdr_s * 256:(fdr_s + 1) * 256] = fdr
    entries.append((fdr_s, bytes(fdr)))
    entries.sort(key=lambda e: describe(e[1])[0])
    idx = bytearray(256)
    for i, (n, _) in enumerate(entries):
        idx[2 * i:2 * i + 2] = struct.pack(">H", n)
    img[256:512] = idx
    img[0x38:0x100] = bm
    open(path, "wb").write(img)
    print("added %s (%d records, sectors %d.., FDR %d) to %s" % (name, len(recs), data_s, fdr_s, path))


def new_image(path, vol, tracks):
    total = tracks * 2 * 18
    img = bytearray(total * 256)
    vib = bytearray(256)
    vib[0:10] = vol.encode("latin-1")[:10].ljust(10)
    vib[0x0a:0x0c] = struct.pack(">H", total)
    vib[0x0c] = 18
    vib[0x0d:0x10] = b"DSK"
    vib[0x10] = 0x20                    # not protected
    vib[0x11] = tracks
    vib[0x12] = 2
    vib[0x13] = 2                       # double density
    bm = bytearray(200)
    bm[0] = 0x03 if total <= 1600 else 0x01   # sectors 0 and 1 (one bit per 2 sectors above 1600)
    nbits = total // 8 if total <= 1600 * 8 else 200 * 8
    # sectors past the end of the bitmap range stay usable only if the bitmap covers them
    vib[0x38:0x100] = bm
    img[0:256] = vib
    open(path, "wb").write(img)
    print("new %s: %s, %d tracks, %d sectors" % (path, vol, tracks, total))


def add_file(path, name, tifile):
    """Add a TIFILES file (128-byte header) to the image."""
    raw = open(tifile, "rb").read()
    if raw[0:8] != b"\x07TIFILES":
        raise SystemExit("%s: no TIFILES header" % tifile)
    hdr, data = raw[:128], raw[128:]
    nsec = struct.unpack(">H", hdr[8:10])[0]
    data = data[:nsec * 256].ljust(nsec * 256, b"\0")
    img = bytearray(open(path, "rb").read())
    vib = img[0:256]
    total = struct.unpack(">H", vib[0x0a:0x0c])[0]
    bm = alloc_bitmap(vib)
    AU[0] = 2 if total > 1600 else 1
    entries = [(n, bytes(f)) for n, f in fdrs(img)]
    for n, f in list(entries):
        if describe(f)[0] == name:
            for sct in data_sectors(img, f) + [n]:
                bit(bm, sct, 0)
            entries.remove((n, f))
    def free(start, count):
        n = start
        n -= n % AU[0]
        while n + count <= total:
            if all(not bit(bm, n + k) for k in range(count)):
                return n
            n += AU[0]
        raise SystemExit("disk full (%s)" % name)
    fdr_s = free(2, 1)
    bit(bm, fdr_s, 1)
    data_s = free(34, nsec) if nsec else 0
    for k in range(nsec):
        bit(bm, data_s + k, 1)
        img[(data_s + k) * 256:(data_s + k + 1) * 256] = data[k * 256:(k + 1) * 256]
    fdr = bytearray(256)
    fdr[0:10] = name.encode("latin-1")[:10].ljust(10)
    fdr[0x0c] = hdr[10]                 # flags
    fdr[0x0d] = hdr[11]                 # records per sector
    fdr[0x0e:0x10] = hdr[8:10]          # sectors
    fdr[0x10] = hdr[12]                 # EOF offset
    fdr[0x11] = hdr[13]                 # record length
    fdr[0x12:0x14] = hdr[14:16]         # level 3 records (byte-swapped in both)
    if nsec:
        last = nsec - 1
        fdr[0x1c:0x1f] = bytes([data_s & 0xff, ((data_s >> 8) & 0x0f) | ((last & 0x0f) << 4), last >> 4])
    img[fdr_s * 256:(fdr_s + 1) * 256] = fdr
    entries.append((fdr_s, bytes(fdr)))
    entries.sort(key=lambda e: describe(e[1])[0])
    idx = bytearray(256)
    for i, (n, _) in enumerate(entries):
        idx[2 * i:2 * i + 2] = struct.pack(">H", n)
    img[256:512] = idx
    img[0x38:0x100] = bm
    open(path, "wb").write(img)
    print("added %-10s %4d sectors at %d" % (name, nsec, data_s))


def main():
    a = sys.argv[1:]
    if "--new" in a:
        i = a.index("--new")
        new_image(a[0], a[i + 1], int(a[i + 2]))
        return 0
    if "--add" in a:
        i = a.index("--add")
        import os
        for spec in a[i + 1:]:
            f, _, n = spec.partition("=")
            add_file(a[0], (n or os.path.basename(f)).upper(), f)
        return 0
    if "--add-text" in a:
        i = a.index("--add-text")
        add_text(a[0], a[i + 1].upper(), a[i + 2].split("|"))
        return 0
    if "--extract" in a:
        i = a.index("--extract")
        img = open(a[0], "rb").read()
        want, outf = a[i + 1].upper(), a[i + 2]
        for _, fdr in fdrs(img):
            if describe(fdr)[0] == want:
                data = b"".join(sector(img, s) for s in data_sectors(img, fdr))
                hdr = b"\x07TIFILES" + fdr[0x0e:0x10] + bytes([fdr[0x0c], fdr[0x0d], fdr[0x10], fdr[0x11]]) + fdr[0x12:0x14]
                open(outf, "wb").write(hdr.ljust(128, b"\0") + data)
                print("wrote", outf)
                return 0
        print("not found:", want)
        return 1
    for path in a:
        img = open(path, "rb").read()
        vib = sector(img, 0)
        vol = vib[0:10].decode("latin-1").rstrip()
        total = struct.unpack(">H", vib[0x0a:0x0c])[0]
        print("%s: volume '%s', %d sectors, %d/track, %d tracks, %d sides, density %d" % (
            path, vol, total, vib[0x0c], vib[0x11], vib[0x12], vib[0x13]))
        for _, fdr in fdrs(img):
            name, ftype, secs, reclen, size = describe(fdr)
            print("  %-10s %-8s %4d sectors  rec %3d  %6d bytes" % (name, ftype, secs, reclen, size))
    return 0


if __name__ == "__main__":
    sys.exit(main())
