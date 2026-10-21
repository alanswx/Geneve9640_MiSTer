//============================================================================
//  Geneve 9640 Gate Array and wait state PAL
//
//  Behaviour as in MAME's genboard.cpp (Michael Zapf): logical address
//  decoding (native and GPL mode), the 8 map registers, the GROM emulation
//  and cartridge banking in DRAM, the XT keyboard shift register, the wait
//  state flags, and the PAL16R4 that drives READY (its simplified equations).
//
//  Events from the CPU (one clk each):
//    as        address set: decode, wait state flags, GROM address increment
//    rd        read data phase: side effects of reads (GROM address register)
//    wr        write (with as): mapper, GROM address, cartridge bank
//    clk_rise  rising CLKOUT: PAL clocks its flip-flops with the GA READY
//    clk_fall  falling CLKOUT: GA wait state flags, end of the video write pulse
//============================================================================

module geneve_ga (
    input  logic        clk,
    input  logic        reset,

    input  logic        as,
    input  logic [15:0] addr,
    input  logic        dbin,
    input  logic        rd,
    input  logic        wr,
    input  logic [7:0]  wdata,
    input  logic        clk_rise,
    input  logic        clk_fall,

    input  logic        cru_wr,
    input  logic [15:0] cru_addr,
    input  logic        cru_wdata,

    input  logic        extready,      // READY from the box
    input  logic        sndready,      // READY from the sound chip
    input  logic        sysspeed,      // 9901 P7 (PAL pin 5)
    input  logic        vwaiten,       // 9901 P9 (PAL pin 19)
    output logic        ready,         // READY to the CPU

    // decoded access (valid after as)
    output logic [4:0]  func,
    output logic [7:0]  physpage,
    output logic [18:0] dram_addr,
    output logic        dec_read,
    output logic        geneve_mode,
    output logic [7:0]  rdata,         // value of GA-internal registers (mapper, keyboard, GROM address)
    output logic        rdata_en,

    // keyboard (HLE interface): load a received scancode into the shift register
    input  logic        kbd_load,
    input  logic [7:0]  kbd_code,
    output logic        kbd_ready,     // shift register empty and enabled
    output logic        kbd_clk_out,   // CRU 1EF0 level (keyboard clock line)
    output logic        kbdint
);

`include "geneve_ga_defs.svh"

logic [7:0]  map [0:7];
logic        direct_mode;
logic        have_waitstate, have_extra_waitstate, enable_extra_waitstates;
logic [15:0] grom_address;
logic        load_lsb;
logic        cartridge_banked, cartridge_secondpage, cartridge6_writable, cartridge7_writable;
logic [8:0]  keyboard_shift_reg;
logic        shift_reg_enabled;
logic [15:0] dec_offset;
logic [4:0]  func_v;
logic [7:0]  physpage_v;
logic        dec_read_v, geneve_mode_v, kbd_clk_out_v;

// PAL state
logic pin3, pin4, pin5, pin9, pin19;
logic q14, q15, q16, q17;


//----------------------------------------------------------------------------
// Logical decoding (s_logmap)
//----------------------------------------------------------------------------
function automatic logic [4:0] decode_logical(input logic [15:0] a, input logic read,
                                              input logic gmode);
    logic [4:0] f;
    f = F_UNDEF;
    if (gmode) begin
        if      ((a & ~16'h000e) == 16'hf100) f = F_VIDEO;
        else if ((a & ~16'h0007) == 16'hf110) f = F_MAPPER;
        else if ((a & ~16'h0007) == 16'hf118) f = F_KEY;
        else if ((a & ~16'h000e) == 16'hf120) f = F_SOUND;
        else if ((a & ~16'h000f) == 16'hf130) f = F_CLOCK;
    end else begin
        if      ((a & ~16'h03fe) == (read ? 16'h8800 : 16'h8c00)) f = F_VIDEO;
        else if ((a & ~16'h0007) == 16'h8000) f = F_MAPPER;
        else if ((a & ~16'h0007) == 16'h8008) f = F_KEY;
        else if ((a & ~16'h01ff) == 16'h8400) f = F_SOUND;
        else if ((a & ~16'h01ff) == 16'h8600) f = F_EXT;
        else if ((a & ~16'h000f) == 16'h8010) f = F_CLOCK;
        else if ((a & ~16'h03fe) == (read ? 16'h9000 : 16'h9400)) f = F_EXT;
        else if ((a & ~16'h03fc) == (read ? 16'h9800 : 16'h9c00)) f = F_GROM;
        else if ((a & ~16'h03fc) == (read ? 16'h9802 : 16'h9c02)) f = F_GROMAD;
        else if ((a & ~16'h1fff) == 16'h6000) f = F_CARTROM;
    end
    return f;
endfunction

function automatic logic [4:0] decode_phys(input logic [7:0] p);
    if (p[7:6] == 2'b00)      return F_DRAM;
    else if (p[7:6] == 2'b01) return F_EXP;
    else if (p[7:5] == 3'b110) return F_SRAMU;
    else if (p[7:3] == 5'b11100) return F_SRAMU;
    else if (p[7:2] == 6'b111010) return F_SRAMX;
    else if (p[7:2] == 6'b111011) return F_SRAM;
    else if (p[7:4] == 4'hf)  return F_EPROM;
    else                      return F_BOX;
endfunction

//----------------------------------------------------------------------------
// PAL equations (MAME's simplified set)
//----------------------------------------------------------------------------
function automatic logic pal_ready(input logic p3, p4, p5, p9, p19, input logic a14, a15, a16, a17);
    logic p49;
    p49 = p9 && p4;
    return !((!p3 && !p49) || (p49 && (!a14 || !a17)) || (p5 && p4 && (!a15 || !a16)));
endfunction

// READY as the CPU samples it: after the rising CLKOUT edge, before the falling one
logic ready_q;


//----------------------------------------------------------------------------
// GA-internal register reads (combinational, valid during rd)
//----------------------------------------------------------------------------
logic [7:0] rdata_c;
logic       rdata_en_c;
always_comb begin
    rdata_c = 8'h00;
    rdata_en_c = 1'b0;
    case (func_v)
    F_MAPPER: begin rdata_c = map[dec_offset[2:0]]; rdata_en_c = 1'b1; end
    F_KEY:    begin rdata_c = keyboard_shift_reg[8:1]; rdata_en_c = 1'b1; end
    F_GROMAD: begin rdata_c = grom_address[15:8]; rdata_en_c = 1'b1; end
    default: ;
    endcase
end

/* verilator lint_off BLKSEQ */
// Registered outputs. rdata is taken before this clk's updates (a read sees the
// register value before its side effects, as MAME's readz).
always_ff @(posedge clk) begin
    rdata <= rdata_c;
    rdata_en <= rdata_en_c;
end

always_ff @(posedge clk) begin
    func <= func_v;
    physpage <= physpage_v;
    dec_read <= dec_read_v;
    geneve_mode <= geneve_mode_v;
    kbd_clk_out <= kbd_clk_out_v;
    dram_addr <= (func_v == F_GROM) ? {3'b111, dec_offset} : {physpage_v[5:0], dec_offset[12:0]};
    kbdint <= keyboard_shift_reg[0];
    kbd_ready <= shift_reg_enabled && (keyboard_shift_reg == 9'd0);
    ready <= ready_q;
end

always_ff @(posedge clk) begin
    logic [4:0] f;
    logic [7:0] pg;
    logic [2:0] logpage;
    logic [7:0] lsb;
    logic       p49, d14, d15, d16, d17;

    if (reset) begin
        for (int i = 0; i < 8; i++) map[i] = 8'h00;
        direct_mode = 1'b1;
        geneve_mode_v = 1'b0;
        have_waitstate = 1'b0;
        have_extra_waitstate = 1'b0;
        enable_extra_waitstates = 1'b0;
        grom_address = 16'd0;
        load_lsb = 1'b0;
        cartridge_banked = 1'b0;
        cartridge_secondpage = 1'b0;
        cartridge6_writable = 1'b0;
        cartridge7_writable = 1'b0;
        keyboard_shift_reg = 9'd0;
        shift_reg_enabled = 1'b0;
        kbd_clk_out_v = 1'b0;
        func_v = F_UNDEF;
        physpage_v = 8'h00;
        dec_offset = 16'd0;
        dec_read_v = 1'b1;
        // PAL power-on state (MAME constructor values)
        pin3 = 1'b1; pin4 = 1'b1; pin5 = 1'b1; pin9 = 1'b1; pin19 = 1'b0;
        q14 = 1'b0; q15 = 1'b0; q16 = 1'b0; q17 = 1'b0;
        ready_q = 1'b1;
    end else begin
        // 9901 outputs into the PAL (only once written; MAME keeps the
        // constructor values until then, the board passes them on change)
        pin5 = sysspeed;
        pin19 = vwaiten;

        // Rising CLKOUT: GA READY into the PAL, then the PAL flip-flops
        if (clk_rise) begin
            pin3 = !(have_waitstate || have_extra_waitstate || !extready || !sndready);
            p49 = pin9 && pin4;
            d17 = (p49 && !q17 && (!q14 || !q15 || !q16)) ||
                  (((p49 && pin3) || (pin3 && !pin19)) && q16 && q15 && q14) ||
                  (!pin19 && !q17 && (!q14 || !q15 || !q16));
            d16 = (p49 && q17 && !q16) || (p49 && !q17 && q16) || (p49 && q16 && q15 && q14) || !pin19;
            d15 = (p49 && q15 && (q14 || !q16 || !q17)) || (p49 && q17 && q16 && !q15) || !pin19;
            d14 = (p49 && q14) || (p49 && q17 && q16 && q15) || !pin19;
            q14 = d14; q15 = d15; q16 = d16; q17 = d17;
            ready_q = pal_ready(pin3, pin4, pin5, pin9, pin19, q14, q15, q16, q17);
        end

        // Falling CLKOUT
        if (clk_fall) begin
            if (!have_extra_waitstate) have_waitstate = 1'b0;
            else have_extra_waitstate = 1'b0;
            if (func_v == F_VIDEO && !dec_read_v) pin9 = 1'b1;   // video write pulse ends
        end

        // CRU: mirror of the 9995 flags
        if (cru_wr && (cru_addr & 16'hffe0) == 16'h1ee0) begin
            case (cru_addr[4:1])
            4'd8:  kbd_clk_out_v = cru_wdata;
            4'd9: begin
                shift_reg_enabled = cru_wdata;
                if (!cru_wdata) keyboard_shift_reg = 9'd0;
            end
            4'd10: geneve_mode_v = cru_wdata;
            4'd11: direct_mode = cru_wdata;
            4'd12: cartridge_banked = !cru_wdata;
            4'd13: cartridge6_writable = cru_wdata;
            4'd14: cartridge7_writable = cru_wdata;
            4'd15: enable_extra_waitstates = !cru_wdata;
            default: ;
            endcase
        end

        // Keyboard (HLE): a complete XT frame has been shifted in
        if (kbd_load && shift_reg_enabled)
            keyboard_shift_reg = {kbd_code, 1'b1};

        // Address set
        if (as) begin
            f = decode_logical(addr, dbin, geneve_mode_v);
            // cartridge writes
            if (f == F_CARTROM && !dbin) begin
                if (cartridge_banked) f = F_CARTBANK;
                else if ((!addr[12] && !cartridge6_writable) || (addr[12] && !cartridge7_writable))
                    f = F_CARTPROT;
            end
            // page
            logpage = addr[15:13];
            if (direct_mode) pg = 8'hf8;
            else if (f == F_CARTROM) pg = (cartridge_banked && cartridge_secondpage) ? 8'h37 : 8'h36;
            else if (f == F_GROM) pg = {5'b00111, grom_address[15:13]};
            else if (f == F_EXT) pg = {5'b10111, logpage};
            else pg = map[logpage];
            dec_offset = addr;
            // physical decoding
            if (f == F_UNDEF || f == F_CARTROM || f == F_GROM) begin
                if (f == F_GROM) begin
                    if (map[6] != 8'h03) f = F_UNDEF;
                    else begin
                        dec_offset = grom_address;
                        grom_address = ((grom_address + 16'd1) & 16'h1fff) | (grom_address & 16'he000);
                        load_lsb = 1'b0;
                    end
                end else
                    f = decode_phys(pg);
            end
            func_v = f;
            physpage_v = pg;
            dec_read_v = dbin;
            have_extra_waitstate = enable_extra_waitstates;
            have_waitstate = (f != F_SRAM && f != F_SRAMX) || have_extra_waitstate;
            // PAL video select inputs
            pin9 = !(f == F_VIDEO && !dbin);
            pin4 = !(f == F_VIDEO && dbin);
        end

        // Read side effects
        if (rd && func_v == F_GROMAD) begin
            lsb = grom_address[7:0];
            grom_address = {lsb, lsb};
            load_lsb = 1'b0;
        end

        // Writes
        if (wr) begin
            case (func_v)
            F_MAPPER: map[dec_offset[2:0]] = wdata;
            F_GROMAD: begin
                grom_address = {grom_address[7:0], wdata};
                if (load_lsb) begin
                    grom_address = ((grom_address + 16'd1) & 16'h1fff) | (grom_address & 16'he000);
                    load_lsb = 1'b0;
                end else load_lsb = 1'b1;
            end
            F_CARTBANK: cartridge_secondpage = dec_offset[1];
            default: ;
            endcase
        end
    end
end
/* verilator lint_on BLKSEQ */

endmodule
