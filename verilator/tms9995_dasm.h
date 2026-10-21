// TMS9995 disassembler for the simulation trace. The output format follows MAME's 9900dasm.cpp
// (Raphael Nabet, BSD-3-Clause) so that traces can be compared line by line: "movb *R1+,@>f120".
#pragma once
#include <cstdint>
#include <cstdio>
#include <string>

namespace tms9995_dasm {

// Operand words come from the instruction stream in order (op[0] = PC+2, op[1] = PC+4)
struct Ops {
    const uint16_t *w;
    int n = 0;
    uint16_t next() { return w[n < 2 ? n++ : 1]; }
};

inline std::string arg(int mode, int reg, Ops &ops)
{
    char b[32];
    switch (mode) {
    case 0: snprintf(b, sizeof b, "R%d", reg); break;
    case 1: snprintf(b, sizeof b, "*R%d", reg); break;
    case 2: {
        uint16_t base = ops.next();
        if (reg) snprintf(b, sizeof b, "@>%04x(R%d)", base, reg);
        else snprintf(b, sizeof b, "@>%04x", base);
        break;
    }
    default: snprintf(b, sizeof b, "*R%d+", reg); break;
    }
    return b;
}

inline std::string pad(const char *m)
{
    char b[16];
    snprintf(b, sizeof b, "%-4s ", m);
    return b;
}

// Disassemble the instruction at pc (opcode ir, operand words op1/op2)
inline std::string disasm(uint16_t pc, uint16_t ir, uint16_t op1, uint16_t op2)
{
    uint16_t w[2] = {op1, op2};
    Ops ops{w};
    char b[64];
    int ts = (ir >> 4) & 3, s = ir & 15, td = (ir >> 10) & 3, d = (ir >> 6) & 15;

    // format 1: two-address
    static const char *f1[] = {"szc", "szcb", "s", "sb", "c", "cb", "a", "ab", "mov", "movb", "soc", "socb"};
    if (ir >= 0x4000) {
        std::string src = arg(ts, s, ops);
        std::string dst = arg(td, d, ops);
        return pad(f1[(ir >> 12) - 4]) + src + "," + dst;
    }
    // format 3/9/4: coc czc xor xop ldcr stcr mpy div
    if (ir >= 0x2000) {
        static const char *f3[] = {"coc", "czc", "xor", "xop", "ldcr", "stcr", "mpy", "div"};
        int op = (ir >> 10) & 7;
        std::string src = arg(ts, s, ops);
        if (op == 4 || op == 5 || op == 3) {
            snprintf(b, sizeof b, ",%d", d);
            return pad(f3[op]) + src + b;
        }
        snprintf(b, sizeof b, ",R%d", d);
        return pad(f3[op]) + src + b;
    }
    // format 2: jumps and CRU bit instructions
    if (ir >= 0x1000) {
        static const char *f2[] = {"jmp", "jlt", "jle", "jeq", "jhe", "jgt", "jne", "jnc",
                                   "joc", "jno", "jl", "jh", "jop", "sbo", "sbz", "tb"};
        int op = (ir >> 8) & 15;
        int8_t disp = (int8_t)(ir & 0xff);
        if (op >= 13) snprintf(b, sizeof b, "%s>%04x", pad(f2[op]).c_str(), (uint16_t)(int16_t)disp);
        else snprintf(b, sizeof b, "%s>%04x", pad(f2[op]).c_str(), (uint16_t)(pc + 2 + disp * 2));
        return b;
    }
    // format 5: shifts
    if (ir >= 0x0800 && ir < 0x0c00) {
        static const char *f5[] = {"sra", "srl", "sla", "src"};
        int cnt = (ir >> 4) & 15;
        snprintf(b, sizeof b, cnt ? "%sR%d,%d" : "%sR%d,R%d", pad(f5[(ir >> 8) & 3]).c_str(), s, cnt);
        return b;
    }
    // format 6: single address
    if (ir >= 0x0400 && ir < 0x0800) {
        static const char *f6[] = {"blwp", "b", "x", "clr", "neg", "inv", "inc", "inct",
                                   "dec", "dect", "bl", "swpb", "seto", "abs"};
        int op = (ir >> 6) & 15;
        if (op < 14) return pad(f6[op]) + arg(ts, s, ops);
    }
    // TMS9995: divs, mpys (format 10 style), lst, lwp
    if ((ir & 0xffc0) == 0x0180) return pad("divs") + arg(ts, s, ops);
    if ((ir & 0xffc0) == 0x01c0) return pad("mpys") + arg(ts, s, ops);
    if ((ir & 0xfff0) == 0x0080) { snprintf(b, sizeof b, "%sR%d", pad("lst").c_str(), s); return b; }
    if ((ir & 0xfff0) == 0x0090) { snprintf(b, sizeof b, "%sR%d", pad("lwp").c_str(), s); return b; }
    // format 8: immediate
    if (ir >= 0x0200 && ir < 0x0340) {
        int op = (ir >> 5) & 15;
        static const char *f8[] = {"li", "ai", "andi", "ori", "ci", "stwp", "stst", "lwpi", "limi"};
        if ((ir & 0x10) == 0 && op <= 8) {
            if (op <= 4) { snprintf(b, sizeof b, "%sR%d,>%04x", pad(f8[op]).c_str(), s, ops.next()); return b; }
            if (op <= 6) { snprintf(b, sizeof b, "%sR%d", pad(f8[op]).c_str(), s); return b; }
            snprintf(b, sizeof b, "%s>%04x", pad(f8[op]).c_str(), ops.next());
            return b;
        }
    }
    // format 7: no operands
    switch (ir) {
    case 0x0340: return "idle";
    case 0x0360: return "rset";
    case 0x0380: return "rtwp";
    case 0x03a0: return "ckon";
    case 0x03c0: return "ckof";
    case 0x03e0: return "lrex";
    }
    snprintf(b, sizeof b, "data >%04x", ir);
    return b;
}

} // namespace tms9995_dasm
