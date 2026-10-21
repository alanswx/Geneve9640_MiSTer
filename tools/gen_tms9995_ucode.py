#!/usr/bin/env python3
"""Generate rtl/tms9995/tms9995_ucode.svh: the TMS9995 microprograms.

The programs are the ones in MAME's tms9995.cpp (Michael Zapf), so that the
RTL takes the same number of CLKOUT cycles per instruction as MAME. Each
program is a list of micro-operations; MPC indexes into it.
"""
import os
import sys

UOPS = [
    "PREFETCH", "PREFETCH_NO_INT", "MEMORY_READ", "MEMORY_WRITE", "WORD_READ",
    "WORD_WRITE", "OPERAND_ADDR", "INCREG", "INDX", "SET_IMM", "RETADDR",
    "RETADDR1", "CRU_INPUT", "CRU_OUTPUT", "ABORT", "END",
    "ALU_NOP", "ALU_ADD_S_SXC", "ALU_B", "ALU_BLWP", "ALU_C", "ALU_CI",
    "ALU_CLR_SETO", "ALU_DIV", "ALU_DIVS", "ALU_EXTERNAL", "ALU_F3",
    "ALU_IMM_ARITHM", "ALU_JUMP", "ALU_LDCR", "ALU_LI", "ALU_LIMIWP",
    "ALU_LSTWP", "ALU_MOV", "ALU_MPY", "ALU_RTWP", "ALU_SBO_SBZ", "ALU_SHIFT",
    "ALU_SINGLE_ARITHM", "ALU_STCR", "ALU_STSTWP", "ALU_TB", "ALU_X",
    "ALU_XOP", "ALU_INT",
]

# Program name -> micro-operations (tms9995.cpp MICROPROGRAM blocks).
# Unused slots in the operand address derivation program are PREFETCH (0) as in MAME.
PROGS = [
    ("OPAD", ["RETADDR", "PREFETCH", "PREFETCH", "PREFETCH",
              "WORD_READ", "RETADDR", "PREFETCH", "PREFETCH",
              "WORD_READ", "RETADDR", "PREFETCH", "PREFETCH",
              "WORD_READ", "INCREG", "WORD_WRITE", "RETADDR1",
              "WORD_READ", "INDX", "WORD_READ", "RETADDR"]),
    ("ADD_S_SXC", ["OPERAND_ADDR", "MEMORY_READ", "OPERAND_ADDR", "MEMORY_READ",
                   "ALU_ADD_S_SXC", "PREFETCH", "MEMORY_WRITE", "END"]),
    ("B", ["OPERAND_ADDR", "ALU_NOP", "ALU_B", "PREFETCH", "ALU_NOP", "END"]),
    ("BL", ["OPERAND_ADDR", "ALU_NOP", "ALU_B", "PREFETCH", "ALU_NOP",
            "MEMORY_WRITE", "ALU_NOP", "END"]),
    ("BLWP", ["OPERAND_ADDR", "MEMORY_READ", "ALU_BLWP", "MEMORY_WRITE",
              "ALU_BLWP", "MEMORY_WRITE", "ALU_BLWP", "MEMORY_WRITE", "ALU_BLWP",
              "MEMORY_READ", "ALU_BLWP", "PREFETCH", "ALU_NOP", "END"]),
    ("C", ["OPERAND_ADDR", "MEMORY_READ", "OPERAND_ADDR", "MEMORY_READ", "ALU_C",
           "PREFETCH", "ALU_NOP", "END"]),
    ("CI", ["MEMORY_READ", "SET_IMM", "MEMORY_READ", "ALU_CI", "PREFETCH",
            "ALU_NOP", "END"]),
    ("COC_CZC", ["OPERAND_ADDR", "MEMORY_READ", "ALU_F3", "MEMORY_READ", "ALU_F3",
                 "PREFETCH", "ALU_NOP", "END"]),
    ("CLR_SETO", ["OPERAND_ADDR", "ALU_NOP", "ALU_CLR_SETO", "PREFETCH",
                  "MEMORY_WRITE", "END"]),
    ("DIV", ["OPERAND_ADDR", "MEMORY_READ", "ALU_DIV", "MEMORY_READ", "ALU_DIV",
             "ABORT", "MEMORY_READ", "ALU_DIV", "MEMORY_WRITE", "ALU_DIV",
             "PREFETCH", "MEMORY_WRITE", "END"]),
    ("DIVS", ["OPERAND_ADDR", "MEMORY_READ", "ALU_DIVS", "MEMORY_READ", "ALU_DIVS",
              "MEMORY_READ", "ALU_DIVS", "ABORT", "ALU_DIVS", "MEMORY_WRITE",
              "ALU_DIVS", "PREFETCH", "MEMORY_WRITE", "END"]),
    ("EXTERNAL", ["ALU_NOP", "ALU_NOP", "ALU_NOP", "ALU_NOP", "ALU_NOP",
                  "ALU_EXTERNAL", "PREFETCH", "ALU_NOP", "END"]),
    ("IMM_ARITHM", ["MEMORY_READ", "SET_IMM", "MEMORY_READ", "ALU_IMM_ARITHM",
                    "PREFETCH", "MEMORY_WRITE", "END"]),
    ("JUMP", ["ALU_NOP", "ALU_JUMP", "PREFETCH", "ALU_NOP", "END"]),
    ("LDCR", ["ALU_LDCR", "OPERAND_ADDR", "MEMORY_READ", "ALU_LDCR", "WORD_READ",
              "ALU_LDCR", "CRU_OUTPUT", "ALU_NOP", "PREFETCH", "ALU_NOP", "END"]),
    ("LI", ["SET_IMM", "MEMORY_READ", "ALU_LI", "PREFETCH", "MEMORY_WRITE", "END"]),
    ("LIMI_LWPI", ["SET_IMM", "MEMORY_READ", "ALU_NOP", "ALU_LIMIWP", "PREFETCH",
                   "ALU_NOP", "END"]),
    ("LST_LWP", ["MEMORY_READ", "ALU_NOP", "ALU_LSTWP", "PREFETCH", "ALU_NOP", "END"]),
    ("MOV", ["OPERAND_ADDR", "MEMORY_READ", "OPERAND_ADDR", "ALU_MOV", "PREFETCH",
             "MEMORY_WRITE", "END"]),
    ("MPY", ["OPERAND_ADDR", "MEMORY_READ", "ALU_MPY", "MEMORY_READ", "ALU_MPY",
             "MEMORY_WRITE", "ALU_MPY", "PREFETCH", "MEMORY_WRITE", "END"]),
    ("RTWP", ["ALU_RTWP", "MEMORY_READ", "ALU_RTWP", "MEMORY_READ", "ALU_RTWP",
              "MEMORY_READ", "ALU_RTWP", "PREFETCH", "ALU_NOP", "END"]),
    ("SBO_SBZ", ["ALU_SBO_SBZ", "WORD_READ", "ALU_SBO_SBZ", "CRU_OUTPUT", "PREFETCH",
                 "ALU_NOP", "ALU_NOP", "END"]),
    ("SHIFT", ["MEMORY_READ", "ALU_SHIFT", "MEMORY_READ", "ALU_SHIFT", "PREFETCH",
               "MEMORY_WRITE", "END"]),
    ("SINGLE_ARITHM", ["OPERAND_ADDR", "MEMORY_READ", "ALU_SINGLE_ARITHM", "PREFETCH",
                       "MEMORY_WRITE", "END"]),
    ("STCR", ["ALU_STCR", "OPERAND_ADDR", "ALU_STCR", "WORD_READ", "ALU_STCR",
              "CRU_INPUT", "ALU_STCR", "PREFETCH", "MEMORY_WRITE", "END"]),
    ("STST_STWP", ["ALU_STSTWP", "ALU_NOP", "PREFETCH", "MEMORY_WRITE", "END"]),
    ("TB", ["ALU_TB", "WORD_READ", "ALU_TB", "CRU_INPUT", "ALU_TB", "PREFETCH",
            "ALU_NOP", "ALU_NOP", "END"]),
    ("X", ["OPERAND_ADDR", "MEMORY_READ", "ALU_X", "END"]),
    ("XOP", ["OPERAND_ADDR", "ALU_XOP", "MEMORY_READ", "ALU_XOP", "MEMORY_WRITE",
             "ALU_XOP", "MEMORY_WRITE", "ALU_XOP", "MEMORY_WRITE", "ALU_XOP",
             "MEMORY_WRITE", "ALU_XOP", "MEMORY_READ", "ALU_XOP", "PREFETCH",
             "ALU_NOP", "ALU_NOP", "END"]),
    ("XOR", ["OPERAND_ADDR", "MEMORY_READ", "ALU_F3", "MEMORY_READ", "ALU_F3",
             "PREFETCH", "MEMORY_WRITE", "END"]),
    ("INT", ["ALU_INT", "MEMORY_READ", "ALU_INT", "MEMORY_WRITE", "ALU_INT",
             "MEMORY_WRITE", "ALU_INT", "MEMORY_WRITE", "ALU_INT", "MEMORY_READ",
             "ALU_INT", "PREFETCH_NO_INT", "ALU_NOP", "ALU_NOP", "END"]),
]


def main():
    out = sys.argv[1] if len(sys.argv) > 1 else os.path.join(
        os.path.dirname(__file__), "..", "rtl", "tms9995", "tms9995_ucode.svh")
    lines = []
    lines.append("// Generated by tools/gen_tms9995_ucode.py -- do not edit.")
    lines.append("// TMS9995 microprograms, as in MAME tms9995.cpp (Michael Zapf).")
    lines.append("")
    lines.append("typedef enum logic [5:0] {")
    lines.append(",\n".join(f"    U_{u} = 6'd{i}" for i, u in enumerate(UOPS)))
    lines.append("} uop_t;")
    lines.append("")
    lines.append("typedef enum logic [4:0] {")
    lines.append(",\n".join(f"    P_{p} = 5'd{i}" for i, (p, _) in enumerate(PROGS)))
    lines.append("} prog_t;")
    lines.append("")
    lines.append("function automatic uop_t uop_rom(input prog_t prog, input logic [5:0] mpc);")
    lines.append("    uop_rom = U_END;")
    lines.append("    case (prog)")
    for p, ops in PROGS:
        for o in ops:
            assert o in UOPS, o
        lines.append(f"    P_{p}:")
        lines.append("        case (mpc)")
        for i, o in enumerate(ops):
            lines.append(f"        6'd{i}: uop_rom = U_{o};")
        lines.append("        default: uop_rom = U_END;")
        lines.append("        endcase")
    lines.append("    default: uop_rom = U_END;")
    lines.append("    endcase")
    lines.append("endfunction")
    lines.append("")
    with open(out, "w") as f:
        f.write("\n".join(lines))
    print(f"wrote {out}")


if __name__ == "__main__":
    main()
