//============================================================================
//  TMS9995 CPU
//
//  A port of MAME's tms9995.cpp (Michael Zapf, BSD-3-Clause) to RTL. The CPU
//  runs the same microprograms (tms9995_ucode.svh) with the same micro-
//  operations, so each instruction takes the same number of CLKOUT cycles as
//  in MAME and instruction traces can be compared cycle for cycle.
//
//  Timing model
//  ------------
//  clk is the system clock; ce marks one CLKOUT cycle (XTAL/4, 3 MHz on the
//  Geneve). A micro-operation executes in one clk and books a number of
//  CLKOUT cycles ("pulses", MAME's pulse_clock). The next micro-operation runs
//  after those pulses have been consumed by ce. Every consumed pulse produces
//  a one-clk clkout strobe; READY is sampled two clks later (after the board
//  has processed the rising CLKOUT edge), as MAME samples READY inside
//  pulse_clock. Micro-operations that need no time run back to back on clk.
//
//  Bus handshake (all strobes are one clk wide)
//  --------------------------------------------
//  bus_as   address set (MAME's setaddress), with bus_addr, bus_dbin, bus_iaq,
//           bus_onchip. For an external write, bus_we is set in the same clk
//           with bus_dout; the board answers it with bus_ack. Other address
//           strobes need no answer.
//  bus_rs   read data: the board answers with bus_ack and bus_din.
//  cru_wr   CRU bit write (cru_addr, cru_dout), answered by bus_ack.
//  cru_rd   CRU bit read (cru_addr), answered by bus_ack with cru_din.
//  The CPU waits for bus_ack; the waiting time is not counted as CLKOUT cycles.
//============================================================================

module tms9995 (
    input  logic        clk,
    input  logic        ce,          // one CLKOUT cycle
    input  logic        reset,       // RESET* asserted

    output logic        bus_as,
    output logic        bus_rs,
    output logic        bus_we,
    output logic        bus_dbin,
    output logic        bus_iaq,
    output logic        bus_onchip,
    output logic [15:0] bus_addr,
    output logic [7:0]  bus_dout,
    input  logic [7:0]  bus_din,
    input  logic        bus_ack,

    output logic        cru_wr,
    output logic        cru_rd,
    output logic [15:0] cru_addr,
    output logic        cru_dout,
    input  logic        cru_din,

    output logic        clkout,      // a CLKOUT cycle was consumed
    input  logic        ready,       // READY line

    input  logic        int1,        // INT1* asserted
    input  logic        int4,        // INT4*/EC asserted
    input  logic        nmi,         // NMI* asserted

    output logic        extop,       // external instruction (IDLE, RSET, CKON, CKOF, LREX)
    output logic [2:0]  extop_code,

    // debugging
    output logic        dbg_inst,    // an instruction starts (MAME's debugger hook)
    output logic [15:0] dbg_pc,
    output logic [15:0] dbg_wp,
    output logic [15:0] dbg_st,
    output logic [15:0] dbg_ir,
    output logic [15:0] dbg_op1,     // operand words of the previous instruction (PC+2, PC+4)
    output logic [15:0] dbg_op2,
    output logic [63:0] dbg_cycles   // CLKOUT cycles since power-on (MAME totalcycles)
);

`include "tms9995_ucode.svh"

// Outputs: the sequencer works on these variables (blocking, as MAME's code);
// the ports are registered copies, so other blocks see them one clk later.
logic        bus_as_v, bus_rs_v, bus_we_v, bus_dbin_v, bus_iaq_v, bus_onchip_v;
logic [15:0] bus_addr_v;
logic [7:0]  bus_dout_v;
logic        cru_wr_v, cru_rd_v, cru_dout_v;
logic [15:0] cru_addr_v;
logic        clkout_v, extop_v, dbg_inst_v;
logic [2:0]  extop_code_v;
logic [15:0] dbg_pc_v, dbg_wp_v, dbg_st_v, dbg_ir_v;
logic [15:0] cur_op1, cur_op2, dbg_op1_v, dbg_op2_v;

// Instructions (MAME's enum)
localparam logic [6:0]
    MID=0, A=1, AB=2, ABS=3, AI=4, ANDI=5, B=6, BL=7, BLWP=8, C=9,
    CB=10, CI=11, CKOF=12, CKON=13, CLR=14, COC=15, CZC=16, DEC=17, DECT=18, DIV=19,
    DIVS=20, IDLE=21, INC=22, INCT=23, INV=24, JEQ=25, JGT=26, JH=27, JHE=28, JL=29,
    JLE=30, JLT=31, JMP=32, JNC=33, JNE=34, JNO=35, JOC=36, JOP=37, LDCR=38, LI=39,
    LIMI=40, LREX=41, LST=42, LWP=43, LWPI=44, MOV=45, MOVB=46, MPY=47, MPYS=48, NEG=49,
    ORI=50, RSET=51, RTWP=52, S=53, SB=54, SBO=55, SBZ=56, SETO=57, SLA=58, SOC=59,
    SOCB=60, SRA=61, SRC=62, SRL=63, STCR=64, STST=65, STWP=66, SWPB=67, SZC=68, SZCB=69,
    TB=70, X=71, XOP=72, XOR=73, INTR=74;

// Status register bits
localparam logic [15:0] ST_LH = 16'h8000, ST_AGT = 16'h4000, ST_EQ = 16'h2000,
    ST_C = 16'h1000, ST_OV = 16'h0800, ST_OP = 16'h0400, ST_X = 16'h0200, ST_OE = 16'h0020;

localparam logic [5:0] PENDING_NMI = 6'd1, PENDING_MID = 6'd2, PENDING_LEVEL1 = 6'd4,
    PENDING_OVERFLOW = 6'd8, PENDING_DECR = 6'd16, PENDING_LEVEL4 = 6'd32;

// What to do when bus_ack arrives
localparam logic [2:0] K_NONE = 3'd0, K_RD_HI = 3'd1, K_RD_LO = 3'd2, K_CRU_IN = 3'd3,
    K_DIV = 3'd4;
localparam logic [1:0] C_NONE = 2'd0, C_PREFETCH = 2'd1, C_ABORT = 2'd2;

//----------------------------------------------------------------------------
// State
//----------------------------------------------------------------------------
logic [15:0] PC, WP, ST, IR, pre_IR;
logic [6:0]  command, pre_command;
prog_t       index, pre_index, caller_index;
logic        byteop, pre_byteop;
logic [5:0]  MPC, caller_MPC;
logic [3:0]  inst_state;
logic [2:0]  mem_phase;           // 1..4
logic signed [5:0] pass;

logic [15:0] address, current_value, source_value, address_add, address_saved;
logic [15:0] address_copy, value_copy;
logic [3:0]  regnumber;
logic [4:0]  count;
logic [15:0] cru_address, cru_value;
logic        cru_first_read;
logic        get_destination;
logic        check_ready, m_ready;
logic        iaq;

logic [15:0] flag;
logic        mid_flag, mid_active, idle_state;
logic [5:0]  int_pending;
logic [3:0]  intmask;
logic        int1_active, int4_active, nmi_active;
logic        int1_prev, int4_prev;
logic [15:0] decrementer_value, starting_count;
logic [1:0]  decrementer_clkdiv;
logic        from_reset;
logic        in_reset;

logic [7:0]  ram [0:255];

logic [5:0]  pend;               // CLKOUT cycles to consume before the next micro-op
logic [1:0]  rsamp;              // READY sampling pipeline after a pulse
logic        waiting;            // waiting for bus_ack
logic [2:0]  ack_kind;
logic [1:0]  cont;               // continuation after a read completes the prefetch
logic        epilogue_pending;

// divider (DIV, DIVS)
logic        div_busy, div_signed;
logic [4:0]  div_step;
logic [16:0] div_rem;
logic [15:0] div_quo, div_den;
logic        div_qneg, div_rneg;

logic [63:0] cycles;

//----------------------------------------------------------------------------
// Instruction decoding (MAME's lookup tree)
//----------------------------------------------------------------------------
typedef struct packed {
    logic       found;
    logic [6:0] cmd;
    prog_t      prog;
    logic       fmt1;
} dec_t;

function automatic dec_t decode_op(input logic [15:0] i);
    dec_t d;
    d.found = 1'b1; d.fmt1 = 1'b0; d.cmd = MID; d.prog = P_OPAD;
    casez (i)
    16'b0000_0000_1000_????: begin d.cmd = LST;  d.prog = P_LST_LWP; end
    16'b0000_0000_1001_????: begin d.cmd = LWP;  d.prog = P_LST_LWP; end
    16'b0000_0001_10??_????: begin d.cmd = DIVS; d.prog = P_DIVS; end
    16'b0000_0001_11??_????: begin d.cmd = MPYS; d.prog = P_MPY; end
    16'b0000_0010_0000_????: begin d.cmd = LI;   d.prog = P_LI; end
    16'b0000_0010_0010_????: begin d.cmd = AI;   d.prog = P_IMM_ARITHM; end
    16'b0000_0010_0100_????: begin d.cmd = ANDI; d.prog = P_IMM_ARITHM; end
    16'b0000_0010_0110_????: begin d.cmd = ORI;  d.prog = P_IMM_ARITHM; end
    16'b0000_0010_1000_????: begin d.cmd = CI;   d.prog = P_CI; end
    16'b0000_0010_1010_????: begin d.cmd = STWP; d.prog = P_STST_STWP; end
    16'b0000_0010_1100_????: begin d.cmd = STST; d.prog = P_STST_STWP; end
    16'b0000_0010_1110_????: begin d.cmd = LWPI; d.prog = P_LIMI_LWPI; end
    16'b0000_0011_0000_????: begin d.cmd = LIMI; d.prog = P_LIMI_LWPI; end
    16'h0340:                begin d.cmd = IDLE; d.prog = P_EXTERNAL; end
    16'h0360:                begin d.cmd = RSET; d.prog = P_EXTERNAL; end
    16'h0380:                begin d.cmd = RTWP; d.prog = P_RTWP; end
    16'h03a0:                begin d.cmd = CKON; d.prog = P_EXTERNAL; end
    16'h03c0:                begin d.cmd = CKOF; d.prog = P_EXTERNAL; end
    16'h03e0:                begin d.cmd = LREX; d.prog = P_EXTERNAL; end
    16'b0000_0100_00??_????: begin d.cmd = BLWP; d.prog = P_BLWP; end
    16'b0000_0100_01??_????: begin d.cmd = B;    d.prog = P_B; end
    16'b0000_0100_10??_????: begin d.cmd = X;    d.prog = P_X; end
    16'b0000_0100_11??_????: begin d.cmd = CLR;  d.prog = P_CLR_SETO; end
    16'b0000_0101_00??_????: begin d.cmd = NEG;  d.prog = P_SINGLE_ARITHM; end
    16'b0000_0101_01??_????: begin d.cmd = INV;  d.prog = P_SINGLE_ARITHM; end
    16'b0000_0101_10??_????: begin d.cmd = INC;  d.prog = P_SINGLE_ARITHM; end
    16'b0000_0101_11??_????: begin d.cmd = INCT; d.prog = P_SINGLE_ARITHM; end
    16'b0000_0110_00??_????: begin d.cmd = DEC;  d.prog = P_SINGLE_ARITHM; end
    16'b0000_0110_01??_????: begin d.cmd = DECT; d.prog = P_SINGLE_ARITHM; end
    16'b0000_0110_10??_????: begin d.cmd = BL;   d.prog = P_BL; end
    16'b0000_0110_11??_????: begin d.cmd = SWPB; d.prog = P_SINGLE_ARITHM; end
    16'b0000_0111_00??_????: begin d.cmd = SETO; d.prog = P_CLR_SETO; end
    16'b0000_0111_01??_????: begin d.cmd = ABS;  d.prog = P_SINGLE_ARITHM; end
    16'b0000_1000_????_????: begin d.cmd = SRA;  d.prog = P_SHIFT; end
    16'b0000_1001_????_????: begin d.cmd = SRL;  d.prog = P_SHIFT; end
    16'b0000_1010_????_????: begin d.cmd = SLA;  d.prog = P_SHIFT; end
    16'b0000_1011_????_????: begin d.cmd = SRC;  d.prog = P_SHIFT; end
    16'b0001_0000_????_????: begin d.cmd = JMP;  d.prog = P_JUMP; end
    16'b0001_0001_????_????: begin d.cmd = JLT;  d.prog = P_JUMP; end
    16'b0001_0010_????_????: begin d.cmd = JLE;  d.prog = P_JUMP; end
    16'b0001_0011_????_????: begin d.cmd = JEQ;  d.prog = P_JUMP; end
    16'b0001_0100_????_????: begin d.cmd = JHE;  d.prog = P_JUMP; end
    16'b0001_0101_????_????: begin d.cmd = JGT;  d.prog = P_JUMP; end
    16'b0001_0110_????_????: begin d.cmd = JNE;  d.prog = P_JUMP; end
    16'b0001_0111_????_????: begin d.cmd = JNC;  d.prog = P_JUMP; end
    16'b0001_1000_????_????: begin d.cmd = JOC;  d.prog = P_JUMP; end
    16'b0001_1001_????_????: begin d.cmd = JNO;  d.prog = P_JUMP; end
    16'b0001_1010_????_????: begin d.cmd = JL;   d.prog = P_JUMP; end
    16'b0001_1011_????_????: begin d.cmd = JH;   d.prog = P_JUMP; end
    16'b0001_1100_????_????: begin d.cmd = JOP;  d.prog = P_JUMP; end
    16'b0001_1101_????_????: begin d.cmd = SBO;  d.prog = P_SBO_SBZ; end
    16'b0001_1110_????_????: begin d.cmd = SBZ;  d.prog = P_SBO_SBZ; end
    16'b0001_1111_????_????: begin d.cmd = TB;   d.prog = P_TB; end
    16'b0010_00??_????_????: begin d.cmd = COC;  d.prog = P_COC_CZC; end
    16'b0010_01??_????_????: begin d.cmd = CZC;  d.prog = P_COC_CZC; end
    16'b0010_10??_????_????: begin d.cmd = XOR;  d.prog = P_XOR; end
    16'b0010_11??_????_????: begin d.cmd = XOP;  d.prog = P_XOP; end
    16'b0011_00??_????_????: begin d.cmd = LDCR; d.prog = P_LDCR; end
    16'b0011_01??_????_????: begin d.cmd = STCR; d.prog = P_STCR; end
    16'b0011_10??_????_????: begin d.cmd = MPY;  d.prog = P_MPY; end
    16'b0011_11??_????_????: begin d.cmd = DIV;  d.prog = P_DIV; end
    16'b0100_????_????_????: begin d.cmd = SZC;  d.prog = P_ADD_S_SXC; d.fmt1 = 1'b1; end
    16'b0101_????_????_????: begin d.cmd = SZCB; d.prog = P_ADD_S_SXC; d.fmt1 = 1'b1; end
    16'b0110_????_????_????: begin d.cmd = S;    d.prog = P_ADD_S_SXC; d.fmt1 = 1'b1; end
    16'b0111_????_????_????: begin d.cmd = SB;   d.prog = P_ADD_S_SXC; d.fmt1 = 1'b1; end
    16'b1000_????_????_????: begin d.cmd = C;    d.prog = P_C;         d.fmt1 = 1'b1; end
    16'b1001_????_????_????: begin d.cmd = CB;   d.prog = P_C;         d.fmt1 = 1'b1; end
    16'b1010_????_????_????: begin d.cmd = A;    d.prog = P_ADD_S_SXC; d.fmt1 = 1'b1; end
    16'b1011_????_????_????: begin d.cmd = AB;   d.prog = P_ADD_S_SXC; d.fmt1 = 1'b1; end
    16'b1100_????_????_????: begin d.cmd = MOV;  d.prog = P_MOV;       d.fmt1 = 1'b1; end
    16'b1101_????_????_????: begin d.cmd = MOVB; d.prog = P_MOV;       d.fmt1 = 1'b1; end
    16'b1110_????_????_????: begin d.cmd = SOC;  d.prog = P_ADD_S_SXC; d.fmt1 = 1'b1; end
    16'b1111_????_????_????: begin d.cmd = SOCB; d.prog = P_ADD_S_SXC; d.fmt1 = 1'b1; end
    default: d.found = 1'b0;
    endcase
    return d;
endfunction

function automatic logic is_onchip(input logic [15:0] a);
    return ((a[15:8] == 8'hf0) && (a < 16'hf0fc)) || (a[15:2] == 14'h3fff);
endfunction

function automatic logic parity8(input logic [7:0] v);
    return ^v;
endfunction

//----------------------------------------------------------------------------
// Helpers working on the state with blocking assignments (MAME's semantics)
//----------------------------------------------------------------------------
task automatic set_bit(input logic [15:0] bit_mask, input logic state);
    if (state) ST = ST | bit_mask;
    else       ST = ST & ~bit_mask;
endtask

task automatic compare_and_set_lae(input logic [15:0] v1, input logic [15:0] v2);
    set_bit(ST_EQ, v1 == v2);
    set_bit(ST_LH, v1 > v2);
    set_bit(ST_AGT, $signed(v1) > $signed(v2));
endtask

task automatic set_status_parity(input logic [7:0] v);
    set_bit(ST_OP, parity8(v));
endtask

task automatic pulse(input logic [5:0] n);
    pend = pend + n;
endtask

task automatic trigger_decrementer();
    if (starting_count != 16'd0) begin
        decrementer_value = decrementer_value - 16'd1;
        if (decrementer_value == 16'd0) begin
            decrementer_value = starting_count;
            if (flag[1]) flag[3] = 1'b1;
        end
    end
endtask

// Address strobe towards the board
task automatic set_address(input logic [15:0] a, input logic dbin, input logic onchip);
    bus_as_v     = 1'b1;
    bus_addr_v   = a;
    bus_dbin_v   = dbin;
    bus_iaq_v    = iaq & dbin;
    bus_onchip_v = onchip;
endtask

task automatic decode(input logic [15:0] inst);
    dec_t d;
    d = decode_op(inst);
    mid_active = 1'b0;
    if (!d.found) begin
        pre_IR = 16'h0000;
        pre_command = MID;
    end else begin
        pre_IR = inst;
        pre_command = d.cmd;
        pre_index = d.prog;
        pre_byteop = d.fmt1 && inst[12];
        pass = 6'sd1;
    end
endtask

task automatic service_interrupt();
    logic [15:0] vectorpos;
    vectorpos = 16'h0010;
    if (in_reset) begin
        vectorpos = 16'h0000;
        intmask = 4'd0;
        mem_phase = 3'd1;
        int1_active = 1'b0;
        int4_active = 1'b0;
        decrementer_clkdiv = 2'd0;
        pass = 6'sd0;
        flag = 16'h0000;
        ST = 16'h0000;
    end else if (mid_active) begin
        vectorpos = 16'h0008;
        intmask = 4'd1;
        PC = PC + 16'd2;
        mid_active = 1'b0;
    end else if ((int_pending & PENDING_NMI) != 0) begin
        vectorpos = 16'hfffc;
        int_pending = int_pending & ~PENDING_NMI;
        intmask = 4'd0;
    end else if ((int_pending & PENDING_LEVEL1) != 0) begin
        vectorpos = 16'h0004;
        int_pending = int_pending & ~PENDING_LEVEL1;
        flag[2] = 1'b0;
        intmask = 4'd0;
    end else if ((int_pending & PENDING_OVERFLOW) != 0) begin
        vectorpos = 16'h0008;
        int_pending = int_pending & ~PENDING_OVERFLOW;
        intmask = 4'd1;
    end else if ((int_pending & PENDING_DECR) != 0) begin
        vectorpos = 16'h000c;
        intmask = 4'd2;
        int_pending = int_pending & ~PENDING_DECR;
        flag[3] = 1'b0;
    end else begin
        vectorpos = 16'h0010;
        intmask = 4'd3;
        int_pending = int_pending & ~PENDING_LEVEL4;
        flag[4] = 1'b0;
    end

    address = vectorpos;
    index = P_INT;
    inst_state = 4'd0;
    byteop = 1'b0;
    command = INTR;
    pass = in_reset ? 6'sd1 : 6'sd2;
    from_reset = in_reset;
    if (in_reset) begin
        IR = 16'h0000;
        in_reset = 1'b0;
    end
    MPC = 6'd0;
    check_ready = 1'b0;
endtask

task automatic next_command();
    IR = pre_IR;
    command = pre_command;
    index = pre_index;
    byteop = pre_byteop;
    inst_state = 4'd0;
    if (command == MID) begin
        mid_flag = 1'b1;
        mid_active = 1'b1;
        service_interrupt();
    end else begin
        get_destination = 1'b0;
        address = WP + {11'd0, IR[3:0], 1'b0};
        MPC = 6'h3f;   // -1
        dbg_inst_v = 1'b1;
        dbg_op1_v = cur_op1;
        dbg_op2_v = cur_op2;
        cur_op1 = 16'd0;
        cur_op2 = 16'd0;
        dbg_pc_v = PC - 16'd2;
        dbg_wp_v = WP;
        dbg_st_v = ST;
        dbg_ir_v = IR;
    end
endtask

task automatic command_completed();
    if (int_pending != 0)
        service_interrupt();
    else if ((ST & ST_OE) != 0 && (ST & ST_OV) != 0 && ST[3:0] > 4'd2)
        service_interrupt();
    else
        next_command();
endtask

// Memory read (MAME mem_read); word = word access
task automatic mem_read(input logic word);
    logic [15:0] a;
    logic [7:0]  ia;
    if (address[15:1] == 15'h7ffd) begin   // fffa/fffb: decrementer
        current_value = decrementer_value;
        if (byteop) begin
            if (address[0]) current_value = current_value << 8;
            current_value = current_value & 16'hff00;
        end
        pulse(1);
    end else if (is_onchip(address)) begin
        if (word || !byteop) address = address & 16'hfffe;
        check_ready = 1'b0;
        ia = address[7:0] & 8'hfe;
        set_address(address & 16'hfffe, 1'b1, 1'b1);
        current_value = {ram[ia], ram[ia | 8'd1]};
        note_word(address, current_value);
        if (!word && byteop) begin
            if (address[0]) current_value = current_value << 8;
            current_value = current_value & 16'hff00;
        end
        pulse(1);
    end else begin
        check_ready = 1'b1;
        a = address;
        case (mem_phase)
        3'd1: begin
            if (word || !byteop) begin
                pass = 6'sd4;
                a = a & 16'hfffe;
            end else pass = 6'sd2;
            set_address(a, 1'b1, 1'b0);
            pulse(1);
        end
        3'd2: begin
            if (word || !byteop) a = a & 16'hfffe;
            bus_rs_v = 1'b1;
            bus_addr_v = a;
            bus_dbin_v = 1'b1;
            waiting = 1'b1;
            ack_kind = K_RD_HI;
        end
        3'd3: begin
            set_address(address | 16'd1, 1'b1, 1'b0);
            pulse(1);
        end
        default: begin
            bus_rs_v = 1'b1;
            bus_addr_v = address | 16'd1;
            bus_dbin_v = 1'b1;
            waiting = 1'b1;
            ack_kind = K_RD_LO;
        end
        endcase
        mem_phase = (mem_phase == 3'd4) ? 3'd1 : mem_phase + 3'd1;
        if (pass == 6'sd1) mem_phase = 3'd1;
    end
endtask

task automatic mem_write(input logic word);
    logic [15:0] a;
    logic [15:0] decbyte;
    if (address[15:1] == 15'h7ffd) begin
        if (byteop) begin
            decbyte = current_value & 16'hff00;
            current_value = decbyte | (decbyte >> 8);
        end
        starting_count = current_value;
        decrementer_value = current_value;
        pulse(1);
    end else if (is_onchip(address)) begin
        if (word || !byteop) address = address & 16'hfffe;
        set_address(address & 16'hfffe, 1'b0, 1'b1);
        check_ready = 1'b0;
        ram[address[7:0]] = current_value[15:8];
        if (word || !byteop) ram[address[7:0] + 8'd1] = current_value[7:0];
        pulse(1);
    end else begin
        check_ready = 1'b1;
        a = address;
        case (mem_phase)
        3'd1: begin
            if (word || !byteop) begin
                pass = 6'sd4;
                a = a & 16'hfffe;
            end else pass = 6'sd2;
            set_address(a, 1'b0, 1'b0);
            bus_we_v = 1'b1;
            bus_dout_v = current_value[15:8];
            waiting = 1'b1;
            ack_kind = K_NONE;
            pulse(1);
        end
        3'd3: begin
            set_address(address | 16'd1, 1'b0, 1'b0);
            bus_we_v = 1'b1;
            bus_dout_v = current_value[7:0];
            waiting = 1'b1;
            ack_kind = K_NONE;
            pulse(1);
        end
        default: ;
        endcase
        mem_phase = (mem_phase == 3'd4) ? 3'd1 : mem_phase + 3'd1;
        if (pass == 6'sd1) mem_phase = 3'd1;
    end
endtask

// Debugging: remember operand words read from the instruction stream
task automatic note_word(input logic [15:0] a, input logic [15:0] v);
    if (!iaq) begin
        if ((a & 16'hfffe) == dbg_pc_v + 16'd2) cur_op1 = v;
        if ((a & 16'hfffe) == dbg_pc_v + 16'd4) cur_op2 = v;
    end
endtask

// Completion of a prefetch (after the low byte has arrived)
task automatic prefetch_finish();
    decode(current_value);
    address = address_copy;
    current_value = value_copy;
    PC = PC + 16'd2;
    iaq = 1'b0;
endtask

// MAME prefetch_and_decode. Returns 1 when the prefetch completed in this call.
task automatic prefetch_and_decode(input logic [1:0] k);
    if (mem_phase == 3'd1) begin
        address_copy = address;
        value_copy = current_value;
        iaq = 1'b1;
        address = PC;
    end
    mem_read(1'b1);
    if (mem_phase == 3'd1) begin
        if (waiting) cont = k;          // finish when the low byte arrives
        else begin
            prefetch_finish();
            if (k == C_ABORT) command_completed();
        end
    end
endtask

task automatic int_prefetch_and_decode(input logic [1:0] k);
    logic [3:0] im;
    logic       done;
    im = ST[3:0];
    done = 1'b0;
    if (mem_phase == 3'd1) begin
        if (nmi_active) begin
            int_pending = int_pending | PENDING_NMI;
            idle_state = 1'b0;
            PC = PC + 16'd2;
            done = 1'b1;
        end else begin
            int_pending = 6'd0;
            if (command != XOP && command != BLWP) begin
                if ((int1_active || flag[2]) && im >= 4'd1) int_pending = int_pending | PENDING_LEVEL1;
                if (flag[3] && im >= 4'd3) int_pending = int_pending | PENDING_DECR;
                if ((int4_active || flag[4]) && im >= 4'd4) int_pending = int_pending | PENDING_LEVEL4;
            end
            if (int_pending != 0) begin
                idle_state = 1'b0;
                PC = PC + 16'd2;
                done = 1'b1;
            end else if (idle_state) begin
                pass = 6'sd2;
                pulse(1);
                done = 1'b1;
            end
        end
    end
    if (done) begin
        if (k == C_ABORT && mem_phase == 3'd1) command_completed();
    end else
        prefetch_and_decode(k);
endtask

task automatic operand_address_subprogram();
    logic [15:0] ircopy;
    ircopy = IR;
    if (get_destination) ircopy = ircopy >> 6;
    caller_index = index;
    caller_MPC = MPC;
    index = P_OPAD;
    MPC = {2'b00, ircopy[5:4], 2'b00};
    regnumber = ircopy[3:0];
    address = WP + {11'd0, regnumber, 1'b0};
    source_value = current_value;
    current_value = address;
    if (MPC == 6'd8) begin
        if (regnumber != 4'd0) MPC = 6'd16;
        else begin
            address = PC;
            PC = PC + 16'd2;
        end
    end
    get_destination = 1'b1;
    mem_phase = 3'd1;
    address_add = 16'd0;
    MPC = MPC - 6'd1;
endtask

// CRU output of one bit
task automatic cru_output_operation();
    if (cru_address == 16'h1fda) begin
        check_ready = 1'b0;
        mid_flag = cru_value[0];
    end else if ((cru_address & 16'hffe0) == 16'h1ee0) begin
        check_ready = 1'b0;
        if (cru_address != 16'h1ee4 && cru_address != 16'h1ee6 && cru_address != 16'h1ee8)
            flag[cru_address[4:1]] = cru_value[0];
    end else
        check_ready = 1'b1;
    cru_wr_v = 1'b1;
    cru_addr_v = cru_address & 16'hfffe;
    cru_dout_v = cru_value[0];
    waiting = 1'b1;
    ack_kind = K_NONE;
    cru_value = cru_value >> 1;
    cru_address = cru_address + 16'd2;
    count = count - 5'd1;
    pass = (count > 5'd0) ? 6'sd2 : 6'sd1;
    pulse(2);
endtask

task automatic cru_input_issue();
    if (cru_first_read) begin
        cru_value = 16'd0;
        cru_first_read = 1'b0;
        pass = $signed({1'b0, count});
    end
    cru_rd_v = 1'b1;
    cru_addr_v = cru_address & 16'hfffe;
    waiting = 1'b1;
    ack_kind = K_CRU_IN;
endtask

task automatic cru_input_finish(input logic bit_in);
    logic crubit;
    crubit = bit_in;
    cru_value = (cru_value >> 1) & 16'h7fff;
    if (cru_address == 16'h1fda) begin
        crubit = mid_flag;
        check_ready = 1'b0;
    end else if ((cru_address & 16'hffe0) == 16'h1ee0) begin
        crubit = flag[cru_address[4:1]];
        check_ready = 1'b0;
    end else
        check_ready = 1'b1;
    if (crubit) cru_value = cru_value | 16'h8000;
    cru_address = cru_address + 16'd2;
    if (pass == 6'sd1) cru_value = cru_value >> (5'd16 - count);
    pulse(2);
endtask

//----------------------------------------------------------------------------
// ALU operations
//----------------------------------------------------------------------------
task automatic alu_add_s_sxc();
    logic [16:0] dest_new;
    dest_new = 17'd0;
    case (command)
    A, AB: begin
        dest_new = {1'b0, current_value} + {1'b0, source_value};
        set_bit(ST_C, dest_new[16]);
        set_bit(ST_OV, ((dest_new[15:0] ^ current_value) & (dest_new[15:0] ^ source_value) & 16'h8000) != 0);
    end
    S, SB: begin
        dest_new = {1'b0, current_value} + {1'b0, ~source_value} + 17'd1;
        set_bit(ST_C, dest_new[16]);
        set_bit(ST_OV, ((current_value ^ source_value) & (current_value ^ dest_new[15:0]) & 16'h8000) != 0);
    end
    SOC, SOCB: dest_new = {1'b0, current_value | source_value};
    SZC, SZCB: dest_new = {1'b0, current_value & ~source_value};
    default: ;
    endcase
    current_value = dest_new[15:0];
    compare_and_set_lae(dest_new[15:0], 16'd0);
    if (byteop) set_status_parity(dest_new[15:8]);
endtask

task automatic alu_blwp();
    logic [5:0] n;
    n = 6'd1;
    case (inst_state)
    4'd0: begin
        value_copy = WP;
        WP = current_value & 16'hfffe;
        address_saved = address + 16'd2;
        address = WP + 16'd30;
        current_value = ST;
    end
    4'd1: begin
        current_value = PC;
        address = address - 16'd2;
    end
    4'd2: begin
        current_value = value_copy;
        address = address - 16'd2;
    end
    4'd3: address = address_saved;
    4'd4: begin
        PC = current_value & 16'hfffe;
        n = 6'd0;
    end
    default: ;
    endcase
    inst_state = inst_state + 4'd1;
    pulse(n);
endtask

task automatic alu_divide();
    logic [5:0] n;
    n = 6'd1;
    case (inst_state)
    4'd0: begin
        source_value = current_value;
        address = WP + {11'd0, IR[9:6], 1'b0};
        address_copy = address;
        pulse(1);
    end
    4'd1: begin
        if (current_value < source_value) begin
            MPC = MPC + 6'd1;
            set_bit(ST_OV, 1'b0);
        end else
            set_bit(ST_OV, 1'b1);
        value_copy = current_value;
        address = address + 16'd2;
        pulse(1);
    end
    4'd2: begin
        // quotient and remainder by the iterative divider; finished in div_finish
        div_busy = 1'b1;
        div_signed = 1'b0;
        div_step = 5'd0;
        div_rem = {1'b0, value_copy};
        div_quo = current_value;
        div_den = source_value;
        div_qneg = 1'b0;
        div_rneg = 1'b0;
        waiting = 1'b1;
        ack_kind = K_DIV;
    end
    4'd3: begin
        current_value = value_copy;
        address = address + 16'd2;
        pulse(1);
    end
    default: pulse(1);
    endcase
    inst_state = inst_state + 4'd1;
endtask

task automatic alu_divide_signed();
    logic signed [31:0] dividend, lim;
    logic signed [16:0] divisor;
    logic        overflow;
    logic [31:0] mag;
    logic [15:0] dmag;
    case (inst_state)
    4'd0: begin
        source_value = current_value;
        address = WP;
        pulse(1);
    end
    4'd1: begin
        value_copy = current_value;
        address = address + 16'd2;
        pulse(1);
    end
    4'd2: begin
        dividend = $signed({value_copy, current_value});
        divisor = $signed({source_value[15], source_value});
        if (divisor != 0) begin
            if (dividend >= 0) begin
                if (divisor > 0) lim = (32'(divisor) <<< 15) - 32'sd1;
                else             lim = (32'(-divisor) <<< 15) + 32'(-divisor) - 32'sd1;
                overflow = dividend > lim;
            end else begin
                if (divisor > 0) lim = (32'(divisor) <<< 15) + 32'(divisor) - 32'sd1;
                else             lim = (32'(-divisor) <<< 15) - 32'sd1;
                overflow = (-dividend) > lim;
            end
        end else
            overflow = 1'b1;
        set_bit(ST_OV, overflow);
        if (!overflow) MPC = MPC + 6'd1;
        pulse(1);
    end
    4'd3: begin
        dividend = $signed({value_copy, current_value});
        mag = dividend[31] ? 32'(-dividend) : 32'(dividend);
        dmag = source_value[15] ? 16'(-source_value) : source_value;
        div_busy = 1'b1;
        div_signed = 1'b1;
        div_step = 5'd0;
        div_rem = {1'b0, mag[31:16]};
        div_quo = mag[15:0];
        div_den = dmag;
        div_qneg = dividend[31] ^ source_value[15];
        div_rneg = dividend[31];
        waiting = 1'b1;
        ack_kind = K_DIV;
    end
    4'd4: begin
        current_value = value_copy;
        address = address + 16'd2;
    end
    default: ;
    endcase
    inst_state = inst_state + 4'd1;
endtask

// Divider done: quotient in div_quo, remainder in div_rem[15:0]
task automatic div_finish();
    logic [15:0] q, r, t;
    logic [5:0]  n;
    q = div_qneg ? 16'(-div_quo) : div_quo;
    r = div_rneg ? 16'(-div_rem[15:0]) : div_rem[15:0];
    current_value = q;
    value_copy = r;
    if (div_signed) address = WP;
    else address = address_copy;
    n = 6'd1;
    t = r;
    for (int i = 0; i < 16; i++)
        if (t != 16'd0) begin
            t = t >> 1;
            n = n + 6'd1;
        end
    pulse(n);
endtask

task automatic alu_external();
    if (command == IDLE) idle_state = 1'b1;
    if (command == RSET) ST = ST & 16'hfff0;
    extop_v = 1'b1;
    extop_code_v = IR[7:5];
endtask

task automatic alu_f3();
    case (inst_state)
    4'd0: begin
        source_value = current_value;
        address = WP + {11'd0, IR[9:6], 1'b0};
    end
    4'd1: begin
        if (command == COC)
            set_bit(ST_EQ, (current_value & source_value) == source_value);
        else if (command == CZC)
            set_bit(ST_EQ, (~current_value & source_value) == source_value);
        else begin
            current_value = current_value ^ source_value;
            compare_and_set_lae(current_value, 16'd0);
        end
    end
    default: ;
    endcase
    inst_state = inst_state + 4'd1;
endtask

task automatic alu_imm_arithm();
    logic [16:0] dest_new;
    dest_new = 17'd0;
    case (command)
    AI: begin
        dest_new = {1'b0, current_value} + {1'b0, source_value};
        set_bit(ST_C, dest_new[16]);
        set_bit(ST_OV, ((dest_new[15:0] ^ current_value) & (dest_new[15:0] ^ source_value) & 16'h8000) != 0);
    end
    ANDI: dest_new = {1'b0, current_value & source_value};
    ORI:  dest_new = {1'b0, current_value | source_value};
    default: ;
    endcase
    current_value = dest_new[15:0];
    compare_and_set_lae(current_value, 16'd0);
    address = address_saved;
endtask

task automatic alu_jump();
    logic cond;
    case (command)
    JMP: cond = 1'b1;
    JLT: cond = (ST & (ST_AGT | ST_EQ)) == 0;
    JLE: cond = (ST & ST_LH) == 0;
    JEQ: cond = (ST & ST_EQ) != 0;
    JHE: cond = (ST & (ST_LH | ST_EQ)) != 0;
    JGT: cond = (ST & ST_AGT) != 0;
    JNE: cond = (ST & ST_EQ) == 0;
    JNC: cond = (ST & ST_C) == 0;
    JOC: cond = (ST & ST_C) != 0;
    JNO: cond = (ST & ST_OV) == 0;
    JL:  cond = (ST & (ST_LH | ST_EQ)) == 0;
    JH:  cond = (ST & ST_LH) != 0;
    JOP: cond = (ST & ST_OP) != 0;
    default: cond = 1'b0;
    endcase
    if (cond) PC = PC + {{7{IR[7]}}, IR[7:0], 1'b0};
endtask

task automatic alu_ldcr();
    case (inst_state)
    4'd0: begin
        count = {1'b0, IR[9:6]};
        if (count == 5'd0) count = 5'd16;
        byteop = count < 5'd9;
    end
    4'd1: begin
        compare_and_set_lae(current_value, 16'd0);
        if (byteop) begin
            current_value = {8'd0, current_value[15:8]};
            set_status_parity(current_value[7:0]);
        end
        cru_value = current_value;
        address = WP + 16'd24;
    end
    4'd2: cru_address = current_value;
    default: ;
    endcase
    inst_state = inst_state + 4'd1;
    pulse(1);
endtask

task automatic alu_multiply();
    logic [31:0] result;
    logic [5:0]  n;
    n = 6'd0;
    if (command == MPY) begin
        case (inst_state)
        4'd0: begin
            source_value = current_value;
            address = WP + {11'd0, IR[9:6], 1'b0};
            n = 6'd1;
        end
        4'd1: begin
            result = source_value * current_value;
            current_value = result[31:16];
            value_copy = result[15:0];
            n = 6'd17;
        end
        4'd2: begin
            address = address + 16'd2;
            current_value = value_copy;
        end
        default: ;
        endcase
    end else begin
        case (inst_state)
        4'd0: begin
            source_value = current_value;
            address = WP;
            n = 6'd1;
        end
        4'd1: begin
            result = 32'($signed(source_value) * $signed(current_value));
            current_value = result[31:16];
            value_copy = result[15:0];
            n = 6'd16;
        end
        4'd2: begin
            address = address + 16'd2;
            current_value = value_copy;
        end
        default: ;
        endcase
    end
    inst_state = inst_state + 4'd1;
    pulse(n);
endtask

task automatic alu_rtwp();
    case (inst_state)
    4'd0: begin
        address = WP + 16'd30;
        pulse(1);
    end
    4'd1: begin
        ST = current_value;
        address = address - 16'd2;
    end
    4'd2: begin
        PC = current_value & 16'hfffe;
        address = address - 16'd2;
    end
    4'd3: WP = current_value & 16'hfffe;
    default: ;
    endcase
    inst_state = inst_state + 4'd1;
endtask

task automatic alu_sbo_sbz();
    if (inst_state == 4'd0)
        address = WP + 16'd24;
    else begin
        cru_value = (command == SBO) ? 16'd1 : 16'd0;
        cru_address = current_value + {{7{IR[7]}}, IR[7:0], 1'b0};
        count = 5'd1;
    end
    inst_state = inst_state + 4'd1;
    pulse(1);
endtask

task automatic alu_shift();
    logic        carry, overflow, check_ov;
    logic [15:0] sign, value;
    logic [4:0]  cnt;
    case (inst_state)
    4'd0: begin
        value_copy = current_value;
        address_saved = address;
        address = WP;
        current_value = {12'd0, IR[7:4]};
        if (current_value != 16'd0) MPC = MPC + 6'd1;
        pulse(2);
    end
    4'd1: begin
        cnt = {1'b0, current_value[3:0]};
        if (cnt == 5'd0) cnt = 5'd16;
        value = value_copy;
        carry = 1'b0;
        overflow = 1'b0;
        check_ov = 1'b0;
        sign = (command == SRA) ? (value & 16'h8000) : 16'd0;
        for (int i = 0; i < 16; i++) begin
            if (5'(i) < cnt) begin
                case (command)
                SRL, SRA: begin
                    carry = value[0];
                    value = (value >> 1) | sign;
                end
                SLA: begin
                    carry = value[15];
                    value = value << 1;
                    check_ov = 1'b1;
                    if (carry != value[15]) overflow = 1'b1;
                end
                default: begin   // SRC
                    carry = value[0];
                    value = {value[0], value[15:1]};
                end
                endcase
            end
        end
        pulse({1'b0, cnt});
        current_value = value;
        set_bit(ST_C, carry);
        if (check_ov) set_bit(ST_OV, overflow);
        compare_and_set_lae(current_value, 16'd0);
        address = address_saved;
    end
    default: ;
    endcase
    inst_state = inst_state + 4'd1;
endtask

task automatic alu_single_arithm();
    logic [16:0] dest_new;
    logic [15:0] src_val, sign;
    logic        check_ov, check_c, done;
    src_val = current_value;
    sign = 16'd0;
    check_ov = 1'b1;
    check_c = 1'b1;
    done = 1'b0;
    dest_new = 17'd0;
    case (command)
    ABS: begin
        set_bit(ST_OV, current_value == 16'h8000);
        set_bit(ST_C, 1'b0);
        compare_and_set_lae(current_value, 16'd0);
        if (current_value[15]) current_value = ~src_val + 16'd1;
        done = 1'b1;
    end
    DEC: begin
        dest_new = {1'b0, src_val} + 17'h0ffff;
        sign = 16'h8000;
    end
    DECT: begin
        dest_new = {1'b0, src_val} + 17'h0fffe;
        sign = 16'h8000;
    end
    INC:  dest_new = {1'b0, src_val} + 17'd1;
    INCT: dest_new = {1'b0, src_val} + 17'd2;
    INV: begin
        dest_new = {1'b0, ~src_val};
        check_ov = 1'b0;
        check_c = 1'b0;
    end
    NEG: begin
        dest_new = {1'b0, ~src_val} + 17'd1;
        check_ov = 1'b0;
        set_bit(ST_OV, src_val == 16'h8000);
    end
    SWPB: begin
        current_value = {current_value[7:0], current_value[15:8]};
        pulse(10);
        done = 1'b1;
    end
    default: ;
    endcase
    if (!done) begin
        if (check_ov) set_bit(ST_OV, ((src_val & 16'h8000) == sign) && ((dest_new[15:0] & 16'h8000) != sign));
        if (check_c) set_bit(ST_C, dest_new[16]);
        current_value = dest_new[15:0];
        compare_and_set_lae(current_value, 16'd0);
    end
endtask

task automatic alu_stcr();
    logic [5:0] n;
    n = 6'd1;
    case (inst_state)
    4'd0: begin
        count = {1'b0, IR[9:6]};
        if (count == 5'd0) count = 5'd16;
        byteop = count < 5'd9;
    end
    4'd1: begin
        address_saved = address;
        address = WP + 16'd24;
    end
    4'd2: begin
        cru_address = current_value;
        cru_first_read = 1'b1;
    end
    4'd3: begin
        current_value = cru_value;
        address = address_saved;
        compare_and_set_lae(current_value, 16'd0);
        n = 6'd13;
        if (byteop) begin
            set_status_parity(current_value[7:0]);
            current_value = current_value << 8;
        end else n = n + 6'd8;
    end
    default: ;
    endcase
    inst_state = inst_state + 4'd1;
    pulse(n);
endtask

task automatic alu_tb();
    case (inst_state)
    4'd0: begin
        address = WP + 16'd24;
        pulse(1);
    end
    4'd1: begin
        cru_address = current_value + {{7{IR[7]}}, IR[7:0], 1'b0};
        cru_first_read = 1'b1;
        count = 5'd1;
        pulse(1);
    end
    4'd2: set_bit(ST_EQ, cru_value != 16'd0);
    default: ;
    endcase
    inst_state = inst_state + 4'd1;
endtask

task automatic alu_xop();
    case (inst_state)
    4'd0: begin
        address_saved = address;
        address = 16'h0040 + {10'd0, IR[9:6], 2'b00};
        pulse(1);
    end
    4'd1: begin
        value_copy = WP;
        WP = current_value & 16'hfffe;
        address = WP + 16'h0016;
        current_value = address_saved;
        pulse(1);
    end
    4'd2: begin
        address = WP + 16'h001e;
        current_value = ST;
        pulse(1);
    end
    4'd3: begin
        address = WP + 16'h001c;
        current_value = PC;
        pulse(1);
    end
    4'd4: begin
        address = WP + 16'h001a;
        current_value = value_copy;
        pulse(1);
    end
    4'd5: begin
        address = 16'h0042 + {10'd0, IR[9:6], 2'b00};
        pulse(1);
    end
    4'd6: begin
        PC = current_value & 16'hfffe;
        set_bit(ST_X, 1'b1);
    end
    default: ;
    endcase
    inst_state = inst_state + 4'd1;
endtask

task automatic alu_int();
    logic [5:0] p;
    p = 6'd1;
    case (inst_state)
    4'd0: begin
        PC = PC - 16'd2;
        address_saved = address;
    end
    4'd1: begin
        p = 6'd2;
        source_value = WP;
        WP = current_value & 16'hfffe;
        current_value = ST;
        address = (WP + 16'd30) & 16'hfffe;
    end
    4'd2: begin
        address = (WP + 16'd28) & 16'hfffe;
        current_value = PC;
    end
    4'd3: begin
        address = (WP + 16'd26) & 16'hfffe;
        current_value = source_value;
    end
    4'd4: address = (address_saved + 16'd2) & 16'hfffe;
    4'd5: begin
        PC = current_value & 16'hfffe;
        ST = (ST & 16'hfe00) | {12'd0, intmask};
        if (((int_pending & PENDING_MID) != 0) && nmi_active) begin
            int_pending = int_pending & ~PENDING_MID;
            address = 16'hfffc;
            intmask = 4'd0;
            MPC = 6'd0;
        end else if (from_reset) begin
            from_reset = 1'b0;
            ST = ST & 16'h01ff;
            mid_flag = 1'b0;
            mid_active = 1'b0;
            flag[4:0] = 5'd0;
        end
        p = 6'd0;
    end
    default: ;
    endcase
    inst_state = inst_state + 4'd1;
    pulse(p);
endtask

// End of a micro-operation: advance the microprogram counter (MAME's main loop)
task automatic epilogue();
    pass = pass - 6'sd1;
    if (pass <= 6'sd0) begin
        pass = 6'sd1;
        MPC = MPC + 6'd1;
    end
endtask

// Execute one micro-operation
task automatic exec_uop();
    uop_t u;
    u = uop_rom(index, MPC);
    check_ready = 1'b0;
    case (u)
    U_PREFETCH:        int_prefetch_and_decode(C_PREFETCH);
    U_PREFETCH_NO_INT: prefetch_and_decode(C_PREFETCH);
    U_MEMORY_READ:     mem_read(1'b0);
    U_MEMORY_WRITE:    mem_write(1'b0);
    U_WORD_READ:       mem_read(1'b1);
    U_WORD_WRITE:      mem_write(1'b1);
    U_OPERAND_ADDR:    operand_address_subprogram();
    U_INCREG: begin
        address_saved = current_value;
        current_value = current_value + (byteop ? 16'd1 : 16'd2);
        address = WP + {11'd0, regnumber, 1'b0};
        mem_phase = 3'd1;
        pulse(1);
    end
    U_INDX: begin
        address_add = current_value;
        address = PC;
        PC = PC + 16'd2;
        mem_phase = 3'd1;
        pulse(1);
    end
    U_SET_IMM: begin
        address_saved = WP + {11'd0, IR[3:0], 1'b0};
        address = PC;
        source_value = current_value;
        PC = PC + 16'd2;
        mem_phase = 3'd1;
    end
    U_RETADDR: begin
        index = caller_index;
        MPC = caller_MPC;
        address = current_value + address_add;
    end
    U_RETADDR1: begin
        index = caller_index;
        MPC = caller_MPC;
        address = address_saved;
    end
    U_CRU_INPUT:       cru_input_issue();
    U_CRU_OUTPUT:      cru_output_operation();
    U_ABORT:           int_prefetch_and_decode(C_ABORT);
    U_END:             command_completed();
    U_ALU_NOP:         pulse(1);
    U_ALU_ADD_S_SXC:   alu_add_s_sxc();
    U_ALU_B: begin
        current_value = PC;
        PC = address & 16'hfffe;
        address = WP + 16'd22;
    end
    U_ALU_BLWP:        alu_blwp();
    U_ALU_C: begin
        if (byteop) set_status_parity(source_value[15:8]);
        compare_and_set_lae(source_value, current_value);
    end
    U_ALU_CI:          compare_and_set_lae(source_value, current_value);
    U_ALU_CLR_SETO:    current_value = (command == SETO) ? 16'hffff : 16'h0000;
    U_ALU_DIV:         alu_divide();
    U_ALU_DIVS:        alu_divide_signed();
    U_ALU_EXTERNAL:    alu_external();
    U_ALU_F3:          alu_f3();
    U_ALU_IMM_ARITHM:  alu_imm_arithm();
    U_ALU_JUMP:        alu_jump();
    U_ALU_LDCR:        alu_ldcr();
    U_ALU_LI: begin
        address = address_saved;
        compare_and_set_lae(current_value, 16'd0);
    end
    U_ALU_LIMIWP: begin
        if (command == LIMI) begin
            ST = (ST & 16'hfff0) | (current_value & 16'h000f);
            pulse(1);
        end else
            WP = current_value & 16'hfffe;
    end
    U_ALU_LSTWP: begin
        if (command == LST) begin
            ST = current_value;
            pulse(1);
        end else
            WP = current_value & 16'hfffe;
    end
    U_ALU_MOV: begin
        current_value = source_value;
        if (byteop) set_status_parity(current_value[15:8]);
        compare_and_set_lae(current_value, 16'd0);
    end
    U_ALU_MPY:         alu_multiply();
    U_ALU_RTWP:        alu_rtwp();
    U_ALU_SBO_SBZ:     alu_sbo_sbz();
    U_ALU_SHIFT:       alu_shift();
    U_ALU_SINGLE_ARITHM: alu_single_arithm();
    U_ALU_STCR:        alu_stcr();
    U_ALU_STSTWP: begin
        address = WP + {11'd0, IR[3:0], 1'b0};
        current_value = (command == STST) ? ST : WP;
    end
    U_ALU_TB:          alu_tb();
    U_ALU_X: begin
        decode(current_value);
        pulse(1);
        next_command();
    end
    U_ALU_XOP:         alu_xop();
    U_ALU_INT:         alu_int();
    default: ;
    endcase
endtask

//----------------------------------------------------------------------------
// Main sequencer
//----------------------------------------------------------------------------
/* verilator lint_off BLKSEQ */
always_ff @(posedge clk) begin
    // one-clk strobes
    bus_as_v = 1'b0;
    bus_rs_v = 1'b0;
    bus_we_v = 1'b0;
    cru_wr_v = 1'b0;
    cru_rd_v = 1'b0;
    clkout_v = 1'b0;
    extop_v  = 1'b0;
    dbg_inst_v = 1'b0;

    if (reset) begin
        in_reset = 1'b1;
        flag = 16'h0000;
        pend = 6'd0;
        rsamp = 2'd0;
        waiting = 1'b0;
        epilogue_pending = 1'b0;
        cont = C_NONE;
        div_busy = 1'b0;
        m_ready = 1'b1;
        check_ready = 1'b0;
        idle_state = 1'b0;
        mid_flag = 1'b0;
        mid_active = 1'b0;
        int_pending = 6'd0;
        nmi_active = 1'b0;
        int1_prev = 1'b0;
        int4_prev = 1'b0;
        iaq = 1'b0;
        cycles = 64'd0;
        starting_count = 16'd0;
        decrementer_value = 16'd0;
        cru_first_read = 1'b0;
        get_destination = 1'b0;
        command = INTR;
        pre_command = MID;
        pre_IR = 16'd0;
        pre_index = P_OPAD;
        pre_byteop = 1'b0;
        caller_index = P_OPAD;
        caller_MPC = 6'd0;
    end else begin
        // RESET released: the reset "interrupt" (MAME execute_run)
        if (in_reset) service_interrupt();

        // Interrupt inputs
        nmi_active = nmi;
        int1_active = int1;
        if (int1 && !int1_prev) flag[2] = 1'b1;
        if (!flag[0]) begin
            int4_active = int4;
            if (int4 && !int4_prev) flag[4] = 1'b1;
        end else if (int4 && !int4_prev)
            trigger_decrementer();
        int1_prev = int1;
        int4_prev = int4;

        // READY sampling, two clks after the pulse (the board has seen the rising CLKOUT)
        if (rsamp != 2'd0) begin
            rsamp = rsamp - 2'd1;
            if (rsamp == 2'd0) m_ready = ready;
        end

        // Consume one CLKOUT cycle
        if (ce && pend != 6'd0) begin
            pend = pend - 6'd1;
            clkout_v = 1'b1;
            cycles = cycles + 64'd1;
            rsamp = 2'd2;
            if (!flag[0] && flag[1]) begin
                decrementer_clkdiv = decrementer_clkdiv + 2'd1;
                if (decrementer_clkdiv == 2'd0) trigger_decrementer();
            end
        end

        // Iterative divider (no CLKOUT cycles)
        if (div_busy) begin
            if (div_step == 5'd16) begin
                div_busy = 1'b0;
                waiting = 1'b0;
                div_finish();
                epilogue();
            end else begin
                // restoring division step: shift in the next quotient bit
                div_rem = {div_rem[15:0], div_quo[15]};
                div_quo = {div_quo[14:0], 1'b0};
                if (div_rem >= {1'b0, div_den}) begin
                    div_rem = div_rem - {1'b0, div_den};
                    div_quo[0] = 1'b1;
                end
                div_step = div_step + 5'd1;
            end
        end else if (waiting && bus_ack) begin
            waiting = 1'b0;
            case (ack_kind)
            K_RD_HI:  current_value = {bus_din, 8'h00};
            K_RD_LO: begin
                current_value[7:0] = bus_din;
                note_word(address, current_value);
            end
            K_CRU_IN: cru_input_finish(cru_din);
            default: ;
            endcase
            if (cont != C_NONE) begin
                prefetch_finish();
                if (cont == C_ABORT) command_completed();
                cont = C_NONE;
            end
            epilogue();
        end else if (!waiting && pend == 6'd0 && rsamp == 2'd0 && !in_reset) begin
            if (check_ready && !m_ready)
                pend = 6'd1;          // wait state
            else begin
                exec_uop();
                if (!waiting) epilogue();
            end
        end
    end
end
/* verilator lint_on BLKSEQ */


always_ff @(posedge clk) begin
    bus_as <= bus_as_v;      bus_rs <= bus_rs_v;      bus_we <= bus_we_v;
    bus_dbin <= bus_dbin_v;  bus_iaq <= bus_iaq_v;    bus_onchip <= bus_onchip_v;
    bus_addr <= bus_addr_v;  bus_dout <= bus_dout_v;
    cru_wr <= cru_wr_v;      cru_rd <= cru_rd_v;      cru_addr <= cru_addr_v;  cru_dout <= cru_dout_v;
    clkout <= clkout_v;      extop <= extop_v;        extop_code <= extop_code_v;
    dbg_inst <= dbg_inst_v;  dbg_pc <= dbg_pc_v;      dbg_wp <= dbg_wp_v;      dbg_st <= dbg_st_v;
    dbg_ir <= dbg_ir_v;      dbg_op1 <= dbg_op1_v;    dbg_op2 <= dbg_op2_v;
    dbg_cycles <= cycles;
end

endmodule
