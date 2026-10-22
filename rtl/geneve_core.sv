//============================================================================
//  Geneve 9640 machine
//
//  TMS9995 CPU, Gate Array + PAL, TMS9901, V9938 (ESE VDP), SN76496,
//  MM58274 RTC, 32+32 KiB SRAM, 16 KiB boot EPROM (1.00 or 2.00), 128 KiB
//  VRAM, and the peripheral box with a Myarc DDCC-1 floppy controller and a
//  Nouspikel IDE card. The 512 KiB DRAM and the IDE card's 512 KiB SRAM are
//  outside (dram_* port), so the MiSTer top can put them in SDRAM.
//
//  Board behaviour follows MAME's geneve.cpp / genboard.cpp (Michael Zapf).
//  clk is the V9938 clock (21.477 MHz); the CPU CLKOUT (3 MHz = 12 MHz/4) is
//  a clock enable derived from it.
//============================================================================

module geneve_core #(
    parameter int CLK_HZ = 21477272
) (
    input  logic        clk,
    input  logic        reset,

    // ROM download: 0000-3FFF boot EPROM 1.00, 4000-5FFF DDCC-1 DSR, 6000-9FFF boot EPROM 2.00
    input  logic        rom_wr,
    input  logic [15:0] rom_addr,
    input  logic [7:0]  rom_data,
    input  logic        boot200,       // run boot EPROM 2.00
    input  logic        ide_en,        // IDE card at CRU >1000

    // DRAM (512 KiB) at 00000-7FFFF, IDE card SRAM (512 KiB) at 80000-FFFFF:
    // one request at a time, answered with dram_ack
    output logic        dram_req,
    output logic        dram_we,
    output logic [19:0] dram_addr,
    output logic [7:0]  dram_wdata,
    input  logic [7:0]  dram_rdata,
    input  logic        dram_ack,

    // Video (15 kHz)
    output logic [5:0]  vga_r,
    output logic [5:0]  vga_g,
    output logic [5:0]  vga_b,
    output logic        vga_hs_n,
    output logic        vga_vs_n,
    output logic        vga_dhclk,     // dot clock enables of the VDP
    output logic        vga_dlclk,
    output logic        vga_de,        // display window
    output logic [15:0] dbg_vdp,
    output logic [15:0] dbg_vdpw,      // VDP write requests (count) | last byte written to port 1

    // Audio
    output logic [7:0]  sound,

    // Keyboard: XT scancodes (make/break), one per strobe; the core buffers them
    input  logic        kbd_strobe,
    input  logic [7:0]  kbd_code,

    // Joysticks (1 = pressed): {up, down, right, left, fire}
    input  logic [4:0]  joy1,
    input  logic [4:0]  joy2,

    // Bus mouse (V9938 colour bus): signed deltas (-127..127, x right, y down) with a strobe;
    // buttons {left, middle, right}, 1 = pressed
    input  logic        mouse_stb,
    input  logic [7:0]  mouse_dx,
    input  logic [7:0]  mouse_dy,
    input  logic [2:0]  mouse_btn,

    // RTC
    input  logic        rtc_load,
    input  logic [55:0] rtc_bcd,

    // Floppy images for DSK1/DSK2 (DDCC-1), sector level: see wd1770.sv
    input  logic [1:0]       fdc_ready,
    input  logic [1:0]       fdc_wprot,
    input  logic [1:0][7:0]  fdc_spt,
    input  logic [1:0][7:0]  fdc_tracks,
    input  logic [1:0][1:0]  fdc_sides,
    output logic        fdc_rd,
    output logic        fdc_wr,
    output logic [15:0] fdc_lsn,
    output logic        fdc_drive,
    input  logic        fdc_ack,
    input  logic        fdc_buf_wr,
    input  logic [7:0]  fdc_buf_addr,
    input  logic [7:0]  fdc_buf_din,
    output logic [7:0]  fdc_buf_dout,

    // IDE disk image (hps_io sd_* of one drive): see ata_disk.sv
    input  logic        ide_mounted,
    input  logic        ide_readonly,
    input  logic [63:0] ide_size,
    output logic [31:0] ide_lba,
    output logic        ide_rd,
    output logic        ide_wr,
    input  logic        ide_ack,
    input  logic [8:0]  ide_buff_addr,
    input  logic [7:0]  ide_buff_dout,
    output logic [7:0]  ide_buff_din,
    input  logic        ide_buff_wr,
    output logic        ide_busy,

    // Debug: instruction trace
    output logic        dbg_inst,
    output logic [15:0] dbg_pc,
    output logic [15:0] dbg_wp,
    output logic [15:0] dbg_st,
    output logic [15:0] dbg_ir,
    output logic [15:0] dbg_op1,
    output logic [15:0] dbg_op2,
    output logic [63:0] dbg_cycles
);

`include "geneve_ga_defs.svh"

//----------------------------------------------------------------------------
// Clock enables
//----------------------------------------------------------------------------
logic [31:0] cpu_acc;
logic        ce_cpu;           // 3 MHz CLKOUT
logic [2:0]  snd_div;
logic        ce_snd;           // 3.58 MHz sound chip clock (VDP CLKOUT /6)

always_ff @(posedge clk) begin
    ce_cpu <= 1'b0;
    if (cpu_acc >= 32'(CLK_HZ - 3000000)) begin
        cpu_acc <= cpu_acc - 32'(CLK_HZ - 3000000);
        ce_cpu <= 1'b1;
    end else
        cpu_acc <= cpu_acc + 32'd3000000;
    ce_snd <= (snd_div == 3'd5);
    snd_div <= (snd_div == 3'd5) ? 3'd0 : snd_div + 3'd1;
end

//----------------------------------------------------------------------------
// CPU
//----------------------------------------------------------------------------
logic        bus_as, bus_rs, bus_we, bus_dbin, bus_iaq, bus_onchip;
logic [15:0] bus_addr;
logic [7:0]  bus_dout, bus_din;
logic        bus_ack;
logic        cru_wr, cru_rd, cru_dout, cru_din;
logic [15:0] cru_addr;
logic        clkout, cpu_ready;
logic        int1, int4;
logic        extop;
logic [2:0]  extop_code;

tms9995 cpu (
    .clk(clk), .ce(ce_cpu), .reset(reset),
    .bus_as(bus_as), .bus_rs(bus_rs), .bus_we(bus_we), .bus_dbin(bus_dbin),
    .bus_iaq(bus_iaq), .bus_onchip(bus_onchip), .bus_addr(bus_addr),
    .bus_dout(bus_dout), .bus_din(bus_din), .bus_ack(bus_ack),
    .cru_wr(cru_wr), .cru_rd(cru_rd), .cru_addr(cru_addr), .cru_dout(cru_dout), .cru_din(cru_din),
    .clkout(clkout), .ready(cpu_ready),
    .int1(int1), .int4(int4), .nmi(1'b0),
    .extop(extop), .extop_code(extop_code),
    .dbg_inst(dbg_inst), .dbg_pc(dbg_pc), .dbg_wp(dbg_wp), .dbg_st(dbg_st), .dbg_ir(dbg_ir), .dbg_op1(dbg_op1), .dbg_op2(dbg_op2),
    .dbg_cycles(dbg_cycles)
);

//----------------------------------------------------------------------------
// TMS9901
//----------------------------------------------------------------------------
logic [15:0] p_out, p_dir;
logic        intreq;
logic [3:0]  ic;
logic        rd9901;
logic        inta, intb, vdp_int, keyint;
logic [31:1] pin_in;

// MAME psi_input: interrupt and pin levels (1 = inactive / high)
always_comb begin
    logic [4:0] joy;
    joy = (p_dir[2] && !p_out[2]) ? joy2 : joy1;   // P2 = 1 selects joystick 1 (MAME joystick_select)
    pin_in = '1;
    pin_in[1]  = !inta;
    pin_in[2]  = !vdp_int;
    pin_in[3]  = !joy[0];                  // fire
    pin_in[4]  = !joy[1];                  // left
    pin_in[5]  = !joy[2];                  // right
    pin_in[6]  = !joy[3];                  // down
    pin_in[7]  = !joy[4];                  // up
    pin_in[8]  = !keyint;
    pin_in[10] = !mouse_btn[2];            // left mouse button (MAME left_mouse_button)
    pin_in[11] = 1'b1;                     // RTC interrupt (not wired in MAME)
    pin_in[12] = !intb;
end

tms9901 psi (
    .clk(clk), .reset(reset),
    .phi_rise(clkout), .phi_fall(clkout),
    .s0_update(bus_as && bus_addr[5]),
    .cru_wr(cru_wr && cru_addr[15:6] == 10'd0), .cru_bit(cru_addr[5:1]), .cru_wdata(cru_dout),
    .rd_bit(cru_addr[5:1]), .rd_data(rd9901),
    .int_line({3'b000, intb, 3'b000, keyint, 5'b00000, vdp_int, inta}),
    .pin_in(pin_in),
    .p_out(p_out), .p_dir(p_dir),
    .intreq(intreq), .ic(ic)
);

assign int1 = intreq;
assign int4 = inta;
assign intb = 1'b0;

//----------------------------------------------------------------------------
// Gate Array + PAL
//----------------------------------------------------------------------------
logic [4:0]  func;
logic [7:0]  physpage;
logic [18:0] ga_dram_addr;
logic        dec_read, geneve_mode;
logic [7:0]  ga_rdata;
logic        ga_rdata_en;
logic        sndready;
logic        kbd_load, kbd_ready, kbd_clk_out;
logic [7:0]  kbd_load_code;

geneve_ga ga (
    .clk(clk), .reset(reset),
    .as(bus_as), .addr(bus_addr), .dbin(bus_dbin),
    .rd(bus_rs), .wr(bus_as && bus_we), .wdata(bus_dout),
    .clk_rise(clkout), .clk_fall(clkout),
    .cru_wr(cru_wr), .cru_addr(cru_addr), .cru_wdata(cru_dout),
    .extready(1'b1), .sndready(sndready),
    .sysspeed(p_dir[7] ? p_out[7] : 1'b1),
    .vwaiten(p_dir[9] ? p_out[9] : 1'b0),
    .ready(cpu_ready),
    .func(func), .physpage(physpage), .dram_addr(ga_dram_addr),
    .dec_read(dec_read), .geneve_mode(geneve_mode),
    .rdata(ga_rdata), .rdata_en(ga_rdata_en),
    .kbd_load(kbd_load), .kbd_code(kbd_load_code), .kbd_ready(kbd_ready),
    .kbd_clk_out(kbd_clk_out), .kbdint(keyint)
);

//----------------------------------------------------------------------------
// Keyboard buffer (HLE of the XT keyboard serial link)
//----------------------------------------------------------------------------
logic [7:0]  kfifo [0:15];
logic [3:0]  kf_wr, kf_rd;
logic [15:0] kdelay;
logic [31:0] kpoll;
logic [1:0]  kreset_cnt;

`ifdef WD_DEBUG
logic kdbg_clk, kdbg_rdy;
always_ff @(posedge clk) begin
    kdbg_clk <= kbd_clk_out;
    kdbg_rdy <= kbd_ready;
    if (kbd_strobe) $display("KBD strobe %02x (fifo %0d/%0d) t=%0d", kbd_code, kf_rd, kf_wr, dbg_cycles);
    if (kbd_load) $display("KBD load %02x t=%0d", kbd_load_code, dbg_cycles);
    if (kdbg_clk != kbd_clk_out || kdbg_rdy != kbd_ready) $display("KBD clk %b ready %b t=%0d", kbd_clk_out, kbd_ready, dbg_cycles);
end
`endif

// MAME genkbd.cpp: the keyboard polls at 120 Hz; the clock line held low for
// 3 polls (25 ms) resets it, and after a reset it sends the BAT code AA.
always_ff @(posedge clk) begin
    kbd_load <= 1'b0;
    if (reset) begin
        kfifo[0] <= 8'haa;
        kf_wr <= 4'd1;
        kf_rd <= 4'd0;
        kdelay <= 16'd0;
        kpoll <= 32'd0;
        kreset_cnt <= 2'd0;
    end else begin
        if (kbd_strobe && (kf_wr + 4'd1) != kf_rd) begin
            kfifo[kf_wr] <= kbd_code;
            kf_wr <= kf_wr + 4'd1;
        end
        if (kpoll == 32'(CLK_HZ / 120 - 1)) begin
            kpoll <= 32'd0;
            if (!kbd_clk_out) begin
                if (kreset_cnt == 2'd2) begin
                    kfifo[0] <= 8'haa;
                    kf_rd <= 4'd0;
                    kf_wr <= 4'd1;
                    kreset_cnt <= 2'd3;
                end else if (kreset_cnt != 2'd3)
                    kreset_cnt <= kreset_cnt + 2'd1;
            end else
                kreset_cnt <= 2'd0;
        end else
            kpoll <= kpoll + 32'd1;
        // about 1 ms per scancode (an XT frame at 10 kHz), only while the line is free
        if (kf_rd != kf_wr && kbd_ready && kbd_clk_out) begin
            if (kdelay == 16'(CLK_HZ / 1000)) begin
                kdelay <= 16'd0;
                kbd_load <= 1'b1;
                kbd_load_code <= kfifo[kf_rd];
                kf_rd <= kf_rd + 4'd1;
            end else
                kdelay <= kdelay + 16'd1;
        end else
            kdelay <= 16'd0;
    end
end

//----------------------------------------------------------------------------
// Memories: SRAM (stock + expansion, 64 KiB), boot EPROMs, DDCC-1 DSR
//----------------------------------------------------------------------------
logic [7:0] sram  [0:65535];
logic [7:0] eprom [0:32767];
logic [7:0] dsr   [0:8191];
logic [7:0] fdcram [0:2047];
logic [7:0] sram_q, eprom_q, dsr_q, fdcram_q;
logic       sram_we, fdcram_we;
logic [7:0] fdc_bank_q;

// Block RAMs with registered reads. The address comes from the address set
// (bus_addr, physpage), which is stable for at least a CLKOUT cycle before the
// read phase, so the data is ready when the CPU samples it.
wire [15:0] sram_a = {func != F_SRAMX, physpage[1:0], bus_addr[12:0]};
always_ff @(posedge clk) begin
    if (sram_we) sram[sram_a] <= bus_dout;
    sram_q <= sram[sram_a];
end

// one write port (block RAM): 1.00 from 0000-3FFF, 2.00 from 6000-9FFF
wire [15:0] rom_addr2 = rom_addr - 16'h6000;
wire        eprom_we = rom_wr && (rom_addr < 16'h4000 || (rom_addr >= 16'h6000 && rom_addr < 16'ha000));
wire [14:0] eprom_wa = (rom_addr < 16'h4000) ? {1'b0, rom_addr[13:0]} : {1'b1, rom_addr2[13:0]};
always_ff @(posedge clk) begin
    if (eprom_we) eprom[eprom_wa] <= rom_data;
    eprom_q <= eprom[{boot200, physpage[0], bus_addr[12:0]}];
end

always_ff @(posedge clk) begin
    if (rom_wr && rom_addr[15:13] == 3'b010) dsr[rom_addr[12:0]] <= rom_data;
    dsr_q <= dsr[{fdc_latch[3], box_addr[11:0]}];
end

always_ff @(posedge clk) begin
    if (fdcram_we) fdcram[box_addr[10:0]] <= bus_dout;
    fdcram_q <= fdcram[box_addr[10:0]];
end

//----------------------------------------------------------------------------
// Sound
//----------------------------------------------------------------------------
logic        snd_we;
logic [8:0]  snd_busy;     // READY low for 32 sound clocks after a write (MAME: clock / (4 * 8))

assign sndready = (snd_busy == 9'd0);

SN76496 psg (
    .clk(clk), .clken(ce_snd), .reset(reset), .ce(1'b1), .we(snd_we), .data(bus_dout),
    .chmsk(4'hf), .sndout(sound), .chactv(), .lreg()
);

always_ff @(posedge clk) begin
    if (reset) snd_busy <= 9'd0;
    else if (snd_we) snd_busy <= 9'd32;
    else if (snd_busy != 9'd0 && ce_snd) snd_busy <= snd_busy - 9'd1;
end

//----------------------------------------------------------------------------
// RTC
//----------------------------------------------------------------------------
logic        rtc_wr, rtc_rd;
logic [3:0]  rtc_rdata;

mm58274 #(.CLK_HZ(CLK_HZ)) rtc (
    .clk(clk), .reset(reset),
    .addr(bus_addr[3:0]), .wr(rtc_wr), .wdata(bus_dout[3:0]), .rdata(rtc_rdata), .rd(rtc_rd),
    .time_load(rtc_load), .time_bcd(rtc_bcd)
);

//----------------------------------------------------------------------------
// V9938
//----------------------------------------------------------------------------
logic        vdp_req, vdp_ack, vdp_wrt;
logic [1:0]  vdp_port;
logic [7:0]  vdp_dbi, vdp_dbo;
logic        vdp_int_n;
logic        pram_oe_n, pram_we_n;
logic [16:0] pram_adr;
logic [15:0] pram_dbi;
logic [7:0]  pram_dbo;
logic [7:0]  vram_lo [0:65535];
logic [7:0]  vram_hi [0:65535];

assign vdp_int = !vdp_int_n;

always_ff @(posedge clk) begin
    if (vdp_req && vdp_wrt) begin
        dbg_vdpw[15:8] <= dbg_vdpw[15:8] + 8'd1;
        if (vdp_port == 2'd1) dbg_vdpw[7:0] <= vdp_dbo;
    end
end

// 9901 P1 = 1 resets the VDP (MAME VDP_reset -> v99x8 reset_line: a reset on assertion)
logic vdp_reset_pulse;
always_ff @(posedge clk)
    vdp_reset_pulse <= cru_wr && cru_addr[15:6] == 10'd0 && cru_addr[5:1] == 5'd17 && cru_dout;

// 9901 P0 = 1 drives the box RESET* line: the cards' latches clear (the DDCC-1's LS259 and WD1770)
logic box_reset_pulse;
always_ff @(posedge clk)
    box_reset_pulse <= cru_wr && cru_addr[15:6] == 10'd0 && cru_addr[5:1] == 5'd16 && cru_dout;

VDP vdp_i (
    .CLK21M(clk), .RESET(reset || vdp_reset_pulse),
    .REQ(vdp_req), .ACK(vdp_ack), .WRT(vdp_wrt), .ADR({14'd0, vdp_port}),
    .DBI(vdp_dbi), .DBO(vdp_dbo), .INT_N(vdp_int_n),
    .PRAMOE_N(pram_oe_n), .PRAMWE_N(pram_we_n), .PRAMADR(pram_adr),
    .PRAMDBI(pram_dbi), .PRAMDBO(pram_dbo),
    .VDPSPEEDMODE(1'b0), .RATIOMODE(3'b000), .CENTERYJK_R25_N(1'b0),
    .PVIDEOR(vga_r), .PVIDEOG(vga_g), .PVIDEOB(vga_b),
    .PVIDEOHS_N(vga_hs_n), .PVIDEOVS_N(vga_vs_n), .PVIDEOCS_N(),
    .PVIDEODHCLK(vga_dhclk), .PVIDEODLCLK(vga_dlclk), .BLANK_O(), .PVIDEODE(vga_de), .PDEBUG(dbg_vdp),
    .DISPRESO(1'b0), .NTSC_PAL_TYPE(1'b1), .FORCED_V_MODE(1'b0), .LEGACY_VGA(1'b0),
    .VDP_ID(5'b00000), .OFFSET_Y(7'd0),
    .MOUSE_STB(mouse_stb), .MOUSE_DX(mouse_dx), .MOUSE_DY(mouse_dy),
    .MOUSE_BTN({mouse_btn[1], mouse_btn[0]})      // S#1 bit 7 middle (switch 2), bit 6 right (switch 1)
);

always_ff @(posedge clk) begin
    if (!pram_we_n) begin
        if (pram_adr[16]) vram_hi[pram_adr[15:0]] <= pram_dbo;
        else              vram_lo[pram_adr[15:0]] <= pram_dbo;
    end
    pram_dbi <= {vram_hi[pram_adr[15:0]], vram_lo[pram_adr[15:0]]};
end

//----------------------------------------------------------------------------
// Peripheral box: Myarc DDCC-1
//----------------------------------------------------------------------------
logic [18:0] box_addr;
logic        box_sel;
logic        fdc_den;        // card selected (CRU bit 0)
logic [7:0]  fdc_latch;      // LS259
logic        wd_rd, wd_wr;
logic [7:0]  wd_dout;
logic        wd_intrq, wd_drq;

assign box_addr = {physpage[5:0], bus_addr[12:0]};
assign box_sel  = (func == F_EXT || func == F_BOX) && box_addr[18:16] == 3'b111;
assign fdc_den  = fdc_latch[0];

wire ddcc_ram = box_sel && fdc_den && (box_addr[15:11] == 5'b01010);
wire ddcc_rom = box_sel && fdc_den && (box_addr[15:12] == 4'h4);
wire ddcc_fdc = box_sel && fdc_den && ((box_addr[15:0] & 16'hff01) == 16'h5f01);
wire ddcc_cru = (cru_addr[15:8] == 8'h11);

logic [1:0] fdc_sel;
always_comb begin
    fdc_sel = 2'd0;
    if (fdc_latch[5])      fdc_sel = 2'd2;
    else if (fdc_latch[4]) fdc_sel = 2'd1;
end

// LS259: 0 card select, 1 WD reset*, 2 side, 3 EPROM bank / single density, 4-7 drive select
wd1770 #(.CLK_HZ(CLK_HZ)) wdc (
    .clk(clk), .reset(reset || !fdc_latch[1]),
    .rd(wd_rd), .wr(wd_wr), .addr(box_addr[2:1]), .din(bus_dout), .dout(wd_dout),
    .intrq(wd_intrq), .drq(wd_drq),
    .drive(fdc_sel), .side(fdc_latch[2]), .dden_n(fdc_latch[3]),
    .ready(fdc_ready), .wprot(fdc_wprot), .spt(fdc_spt), .tracks(fdc_tracks), .sides(fdc_sides),
    .img_rd(fdc_rd), .img_wr(fdc_wr), .img_lsn(fdc_lsn), .img_drive(fdc_drive), .img_ack(fdc_ack),
    .buf_wr(fdc_buf_wr), .buf_addr(fdc_buf_addr), .buf_din(fdc_buf_din), .buf_dout(fdc_buf_dout)
);

//----------------------------------------------------------------------------
// Peripheral box: Nouspikel IDE card (MAME tn_ide.cpp), Geneve mode, CRU >1000
//
// No ROM: the DSR (Fred Kaal's IDE DSR) lives in the 512 KiB SRAM, preloaded by
// the MiSTer top as IDELOAD would leave it. SRAM map DIP = SRAM, clock = bq4847.
// LS259 latch: 0 card on, 1 registers at 4000-40FF, 2 SRAM page select on write,
// 3 0 = page 0 fixed at 4000-4FFF, 4 SRAM at 6000-7FFF, 5 SRAM write protect,
// 6 IDE interrupt to INTA, 7 drive reset.
// 4020-403F: bq4847 registers; 4040-405F: CS1Fx, 4060-407F: CS3Fx, through
// 16-bit latches: the even byte (first access) is D7-D0, the odd one D15-D8.
//----------------------------------------------------------------------------
logic [7:0]  ide_q;
logic [5:0]  ide_page;
logic [15:0] ide_rlatch, ide_wlatch;
logic        ata_rd, ata_wr;
logic        ata_scs1;
logic [2:0]  ata_sreg;
logic [15:0] ata_wdata, ata_rdata;
logic        ata_intrq;
logic [55:0] ide_time;

wire ide_space = ide_en && box_sel && !box_addr[15];
wire ide_mmap  = ide_space && box_addr[14:8] == 7'h40 && ide_q[0] && ide_q[1];
wire ide_sram  = ide_space && ((box_addr[14:13] == 2'b10 && !ide_mmap && ide_q[0])
                               || (box_addr[14:13] == 2'b11 && ide_q[4]));
wire ide_rtc   = ide_mmap && box_addr[6:5] == 2'b01;
wire ide_ata   = ide_mmap && box_addr[6];
wire ide_cru   = ide_en && cru_addr[15:8] == 8'h10;
wire [5:0] ide_pg = (box_addr[13:12] == 2'b00 && !ide_q[3]) ? 6'd0 : ide_page;

assign inta = ide_q[6] && ata_intrq;

// bq4847 registers from the MiSTer RTC (not running: the time of the last load)
always_ff @(posedge clk) if (rtc_load) ide_time <= rtc_bcd;

function automatic [7:0] bq4847(input [3:0] r);
    case (r)
    4'd0:  bq4847 = ide_time[7:0];
    4'd2:  bq4847 = ide_time[15:8];
    4'd4:  bq4847 = ide_time[23:16];
    4'd6:  bq4847 = ide_time[31:24];
    4'd8:  bq4847 = ide_time[55:48];
    4'd9:  bq4847 = ide_time[39:32];
    4'd10: bq4847 = ide_time[47:40];
    4'd14: bq4847 = 8'h02;                 // 24-hour mode
    default: bq4847 = 8'h00;
    endcase
endfunction

ata_disk ata (
    .clk(clk), .reset(reset),
    .a_cs1(box_addr[5]), .a_reg(box_addr[3:1]), .rdata(ata_rdata),
    .rd(ata_rd), .wr(ata_wr), .s_cs1(ata_scs1), .s_reg(ata_sreg), .wdata(ata_wdata),
    .intrq(ata_intrq),
    .img_mounted(ide_mounted), .img_readonly(ide_readonly), .img_size(ide_size),
    .sd_lba(ide_lba), .sd_rd(ide_rd), .sd_wr(ide_wr), .sd_ack(ide_ack),
    .sd_buff_addr(ide_buff_addr), .sd_buff_dout(ide_buff_dout), .sd_buff_din(ide_buff_din), .sd_buff_wr(ide_buff_wr),
    .busy(ide_busy)
);

// DRAM-like accesses (through SDRAM): the DRAM proper and the IDE card SRAM
wire        mem_sel  = (func == F_DRAM || func == F_GROM) || ide_sram;
wire        mem_wsel = (func == F_DRAM || func == F_GROM) || (ide_sram && !ide_q[5]);
wire [19:0] mem_addr = ide_sram ? {1'b1, ide_pg, box_addr[12:0]} : {1'b0, ga_dram_addr};

//----------------------------------------------------------------------------
// Bus cycle handling
//----------------------------------------------------------------------------
typedef enum logic [2:0] { B_IDLE, B_READ, B_WRITE, B_VDP, B_DRAM, B_ACK } bstate_t;
bstate_t     bst;
logic [7:0]  rdval;
logic        pend_write, pend_rdaddr;

// DRAM (SDRAM on the MiSTer): reads start at the address phase, so the byte is
// there when the CPU's read phase comes; writes are posted (acknowledged at once).
logic        dbusy;          // a DRAM request is outstanding
logic        dbusy_rd;       // ... and it is a read
logic        pf_valid;       // read-ahead data for the current access
logic [7:0]  pf_data;
logic        rd_want;        // read-ahead wanted (DRAM was busy)
logic [19:0] rd_addr;
logic        rs_wait;        // the read phase came before the data
logic        wq;             // a write waiting for the DRAM
logic [19:0] wq_addr;
logic [7:0]  wq_data;

always_ff @(posedge clk) begin
    logic [7:0] v;
    bus_ack <= 1'b0;
    cru_din <= 1'b0;
    vdp_req <= 1'b0;
    snd_we <= 1'b0;
    rtc_wr <= 1'b0;
    rtc_rd <= 1'b0;
    wd_rd <= 1'b0;
    wd_wr <= 1'b0;
    dram_req <= 1'b0;
    sram_we <= 1'b0;
    fdcram_we <= 1'b0;
    ata_rd <= 1'b0;
    ata_wr <= 1'b0;

    if (reset) begin
        bst <= B_IDLE;
        pend_write <= 1'b0;
        pend_rdaddr <= 1'b0;
        fdc_latch <= 8'd0;
        ide_q <= 8'd0;
        ide_page <= 6'd0;
        dbusy <= 1'b0;
        dbusy_rd <= 1'b0;
        pf_valid <= 1'b0;
        rd_want <= 1'b0;
        rs_wait <= 1'b0;
        wq <= 1'b0;
    end else begin
        // The GA decodes on bus_as; the access itself happens one clk later.
        pend_write <= bus_as && bus_we && !bus_onchip;
        pend_rdaddr <= bus_as && !bus_we && !bus_onchip;

        if (pend_write) begin
            // MAME memwrite: all selected devices take the byte
            if (func == F_VIDEO && !dec_read) begin
                vdp_req <= 1'b1;
                vdp_wrt <= 1'b1;
                vdp_port <= bus_addr[2:1];
                vdp_dbo <= bus_dout;
                bst <= B_VDP;
            end else if (mem_wsel) begin
                // posted: queued, acknowledged when the DRAM takes it (below)
                wq <= 1'b1;
                wq_addr <= mem_addr;
                wq_data <= bus_dout;
                if (ide_sram && ide_q[2]) ide_page <= box_addr[6:1];
            end else begin
                if (ide_sram && ide_q[2]) ide_page <= box_addr[6:1];
                if (ide_ata) begin
                    if (!box_addr[0])
                        ide_wlatch[7:0] <= bus_dout;
                    else begin
                        // second access: the 16-bit write goes out
                        ata_wr <= 1'b1;
                        ata_scs1 <= box_addr[5];
                        ata_sreg <= box_addr[3:1];
                        ata_wdata <= {bus_dout, ide_wlatch[7:0]};
                    end
                end
                if (func == F_SOUND) snd_we <= 1'b1;
                if (func == F_CLOCK) rtc_wr <= 1'b1;
                if (func == F_SRAM || func == F_SRAMX) sram_we <= 1'b1;
                if (ddcc_ram) fdcram_we <= 1'b1;
                if (ddcc_fdc) wd_wr <= 1'b1;
                bus_ack <= 1'b1;
            end
        end

        // Reads: the decode is long stable when the read phase comes, so answer at once
        if (bus_rs) begin
            if (func == F_VIDEO && dec_read) begin
                vdp_req <= 1'b1;
                vdp_wrt <= 1'b0;
                vdp_port <= bus_addr[2:1];
                bst <= B_VDP;
            end else if (mem_sel) begin
                if (pf_valid) begin
                    bus_din <= pf_data;
                    bus_ack <= 1'b1;
                end else if (dram_ack && dbusy_rd) begin     // arrives right now
                    bus_din <= dram_rdata;
                    bus_ack <= 1'b1;
                end else
                    rs_wait <= 1'b1;
            end else begin
                v = 8'h00;
                if (ga_rdata_en) v = ga_rdata;
                if (func == F_CLOCK) begin
                    v = {geneve_mode ? 4'hf : 4'(({11'd0, bus_addr[4:0]} + 16'd1) >> 4), rtc_rdata};
                    rtc_rd <= 1'b1;
                end
                if (func == F_EPROM) v = eprom_q;
                if (func == F_SRAM || func == F_SRAMX) v = sram_q;
                if (ddcc_ram) v = fdcram_q;
                if (ddcc_rom) v = dsr_q;
                if (ddcc_fdc) begin
                    v = wd_dout;
                    wd_rd <= 1'b1;
                end
                if (ide_rtc) v = bq4847(box_addr[4:1]);
                if (ide_ata) begin
                    if (!box_addr[0]) begin
                        // first access: the 16-bit read (not in the write half: read-before-write)
                        logic [15:0] l;
                        l = box_addr[4] ? 16'h0000 : ata_rdata;
                        ide_rlatch <= l;
                        if (!box_addr[4]) begin
                            ata_rd <= 1'b1;
                            ata_scs1 <= box_addr[5];
                            ata_sreg <= box_addr[3:1];
                        end
                        v = l[7:0];
                    end else
                        v = ide_rlatch[15:8];
                end
                bus_din <= v;
                bus_ack <= 1'b1;
            end
        end

        case (bst)
        B_VDP: if (vdp_ack) begin
            bus_din <= vdp_dbi;
            bus_ack <= 1'b1;
            bst <= B_IDLE;
        end
        default: ;
        endcase

        // DRAM requests
        begin
            logic busy, want, wqv, valid;
            busy = dbusy;
            want = rd_want;
            wqv = wq;
            valid = pf_valid;
            if (pend_rdaddr) begin
                // a new access: the read-ahead belongs to it if it is a DRAM read
                valid = 1'b0;
                want = mem_sel;
                rd_addr <= mem_addr;
            end
            if (pend_write && mem_wsel) wqv = 1'b1;
            if (dram_ack) begin
                busy = 1'b0;
                if (dbusy_rd && !pend_rdaddr) begin
                    valid = 1'b1;
                    pf_data <= dram_rdata;
                    if (rs_wait) begin
                        bus_din <= dram_rdata;
                        bus_ack <= 1'b1;
                        rs_wait <= 1'b0;
                    end
                end
            end
            if (!busy) begin
                if (wq && !pend_write) begin
                    dram_req <= 1'b1;
                    dram_we <= 1'b1;
                    dram_addr <= wq_addr;
                    dram_wdata <= wq_data;
                    busy = 1'b1;
                    dbusy_rd <= 1'b0;
                    wqv = 1'b0;
                    bus_ack <= 1'b1;
                end else if (rd_want && !pend_rdaddr) begin
                    dram_req <= 1'b1;
                    dram_we <= 1'b0;
                    dram_addr <= rd_addr;
                    busy = 1'b1;
                    dbusy_rd <= 1'b1;
                    want = 1'b0;
                end
            end
            dbusy <= busy;
            rd_want <= want;
            wq <= wqv;
            pf_valid <= valid;
        end

        // CRU
        if (cru_wr) begin
            if (ddcc_cru) fdc_latch[cru_addr[3:1]] <= cru_dout;
            if (ide_cru) ide_q[cru_addr[3:1]] <= cru_dout;
            bus_ack <= 1'b1;
        end
        if (box_reset_pulse) begin
            fdc_latch <= 8'd0;
            ide_q <= 8'd0;
        end
        if (cru_rd) begin
            if (cru_addr[15:6] == 10'd0) cru_din <= rd9901;
            else if (ddcc_cru) begin
                case (cru_addr[3:1])
                3'd0: cru_din <= wd_intrq;
                3'd1: cru_din <= wd_drq;
                3'd2: cru_din <= 1'b0;        // turbo switch off
                3'd3: cru_din <= 1'b0;
                default: cru_din <= 1'b1;     // head step switches open (6 ms)
                endcase
            end else if (ide_cru) begin
                case (cru_addr[3:1])
                3'd0: cru_din <= ata_intrq;
                3'd1: cru_din <= 1'b1;        // SRAM map DIP
                3'd3: cru_din <= 1'b1;
                3'd4: cru_din <= ide_q[4];
                3'd5: cru_din <= ide_q[5];
                default: cru_din <= 1'b0;
                endcase
            end
            bus_ack <= 1'b1;
        end
    end
end

endmodule
