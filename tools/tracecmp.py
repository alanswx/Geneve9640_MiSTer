#!/usr/bin/env python3
"""Compare a MAME debugger trace with the simulation's instruction trace.

MAME trace (trace command with {tracelog "%d %04X %04X ",totalcycles,wp,st}):
    31 F000 C000 0232: sbo  >000a
Simulation trace (verilator/sim_headless.cpp --trace):
    32 F000 C000 0232: 1D0A

Instructions are matched in order on PC, WP and ST. Cycle counts are compared
as differences from the first matched line, so a constant offset is ignored;
the first point where the offset changes is reported as a timing divergence.

usage: tracecmp.py mame.log sim.log [--max N] [--context N] [--timing]
"""
import argparse
import sys


def parse(path, limit):
    out = []
    with open(path, errors="replace") as f:
        for line in f:
            parts = line.split()
            if len(parts) < 4 or not parts[0].isdigit():
                continue
            try:
                cyc = int(parts[0])
                wp = int(parts[1], 16)
                st = int(parts[2], 16)
                pc = int(parts[3].rstrip(":"), 16)
            except ValueError:
                continue
            rest = line.split(":", 1)[1].strip() if ":" in line else ""
            out.append((cyc, wp, st, pc, rest))
            if limit and len(out) >= limit:
                break
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("mame")
    ap.add_argument("sim")
    ap.add_argument("--max", type=int, default=0, help="compare at most N instructions")
    ap.add_argument("--context", type=int, default=6)
    ap.add_argument("--timing", action="store_true", help="also stop at the first cycle-offset change")
    ap.add_argument("--resync", type=int, default=0,
                    help="after a divergence, skip up to N instructions on either side to realign (polling loops)")
    ap.add_argument("--quiet-timing", action="store_true", help="do not print timing changes")
    a = ap.parse_args()

    m = parse(a.mame, a.max)
    s = parse(a.sim, a.max)
    # align on the first MAME instruction
    start = next((i for i, x in enumerate(s) if x[3] == m[0][3] and x[1] == m[0][1]), None)
    if start is None:
        print("cannot align: first MAME PC %04X not in the sim trace" % m[0][3])
        return 1
    s = s[start:]
    offset = s[0][0] - m[0][0]
    i = j = 0
    timing_reported = a.quiet_timing
    resyncs = 0

    def key(x):
        return (x[1], x[2], x[3])

    def aligned(i, j, k=24):
        for t in range(k):
            if i + t >= len(m) or j + t >= len(s) or key(m[i + t]) != key(s[j + t]):
                return False
        return True

    while i < len(m) and j < len(s):
        mc, mw, mst, mpc, mtxt = m[i]
        sc, sw, sst, spc, stxt = s[j]
        if (mw, mst, mpc) != (sw, sst, spc):
            found = None
            if a.resync:
                for d in range(1, a.resync):
                    if aligned(i + d, j):
                        found = (i + d, j); break
                    if aligned(i, j + d):
                        found = (i, j + d); break
            if found is None:
                print("DIVERGE at MAME instruction %d / sim %d (MAME cycle %d, sim cycle %d)" % (i, j, mc, sc))
                for t in range(-a.context, 3):
                    if 0 <= i + t < len(m) and 0 <= j + t < len(s):
                        mm, ss = m[i + t], s[j + t]
                        mark = ">>" if t == 0 else "  "
                        print("%s MAME %8d %04X %04X %04X: %-24s | SIM %8d %04X %04X %04X: %s" % (
                            mark, mm[0], mm[1], mm[2], mm[3], mm[4][:24], ss[0], ss[1], ss[2], ss[3], ss[4]))
                print("matched %d instructions, %d resyncs" % (i, resyncs))
                return 1
            resyncs += 1
            if not a.quiet_timing:
                print("resync at MAME %d (PC %04X): skipped %d MAME / %d sim instructions" % (
                    mc, mpc, found[0] - i, found[1] - j))
            i, j = found
            offset = s[j][0] - m[i][0]
            continue
        d = (sc - mc) - offset
        if d != 0 and not timing_reported:
            timing_reported = True
            print("timing: cycle offset changes by %+d at instruction %d (MAME cycle %d, PC %04X)" % (d, i, mc, mpc))
            if a.timing:
                return 1
        offset = sc - mc
        i += 1
        j += 1
    n = i
    print("match: %d instructions (MAME %d, sim %d lines), %d resyncs" % (n, len(m), len(s), resyncs))
    return 0


if __name__ == "__main__":
    sys.exit(main())
