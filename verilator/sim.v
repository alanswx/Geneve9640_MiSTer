`timescale 1ns/1ns
//
// Simulation top for the Geneve 9640 core: rtl/geneve_core.sv with the 512 KiB DRAM as an array and the
// ports visible to the C++ harness (sim_headless.cpp), which loads the ROMs and serves the floppy images.
//
module top(
   input         clk /*verilator public_flat*/,
   input         reset /*verilator public_flat*/,

   // ROM download: 00000-09FFF core ROMs (see geneve_core), 10000-8FFFF IDE card SRAM (into the DRAM model)
   input         rom_wr,
   input  [19:0] rom_addr,
   input   [7:0] rom_data,
   input         boot200,
   input         ide_en,
   input         vram192,

   // IDE disk image: hps_io sd_* of one drive
   input         ide_mounted,
   input  [63:0] ide_size,
   output [31:0] ide_lba,
   output        ide_rd,
   output        ide_wr,
   input         ide_ack,
   input   [8:0] ide_buff_addr,
   input   [7:0] ide_buff_dout,
   output  [7:0] ide_buff_din,
   input         ide_buff_wr,

   output  [5:0] vga_r /*verilator public_flat*/,
   output  [5:0] vga_g /*verilator public_flat*/,
   output  [5:0] vga_b /*verilator public_flat*/,
   output        vga_hs_n /*verilator public_flat*/,
   output        vga_vs_n /*verilator public_flat*/,
   output        vga_dhclk /*verilator public_flat*/,
   output        vga_dlclk /*verilator public_flat*/,
   output        vga_de /*verilator public_flat*/,
   output  [7:0] sound,

   input         kbd_strobe,
   input   [7:0] kbd_code,
   input   [4:0] joy1,
   input   [4:0] joy2,
   input         mouse_stb,
   input   [7:0] mouse_dx,
   input   [7:0] mouse_dy,
   input   [2:0] mouse_btn,
   input         rtc_load,
   input  [55:0] rtc_bcd,

   // hps_io sd_* side (used with +define+USE_SD: rtl/geneve_disk.sv between core and harness)
   input   [1:0] img_mounted,
   input  [63:0] img_size,
   output [31:0] sd_lba0,
   output [31:0] sd_lba1,
   output  [1:0] sd_rd,
   output  [1:0] sd_wr,
   input   [1:0] sd_ack,
   input   [8:0] sd_buff_addr,
   input   [7:0] sd_buff_dout,
   output  [7:0] sd_buff_din0,
   output  [7:0] sd_buff_din1,
   input         sd_buff_wr,

   input   [1:0] fdc_ready,
   input   [1:0] fdc_wprot,
   input   [7:0] fdc_spt0,
   input   [7:0] fdc_spt1,
   input   [7:0] fdc_tracks0,
   input   [7:0] fdc_tracks1,
   input   [1:0] fdc_sides0,
   input   [1:0] fdc_sides1,
   output        fdc_rd,
   output        fdc_wr,
   output [15:0] fdc_lsn,
   output        fdc_drive,
   input         fdc_ack,
   input         fdc_buf_wr,
   input   [7:0] fdc_buf_addr,
   input   [7:0] fdc_buf_din,
   output  [7:0] fdc_buf_dout,

   output        dbg_inst /*verilator public_flat*/,
   output [15:0] dbg_pc /*verilator public_flat*/,
   output [15:0] dbg_wp /*verilator public_flat*/,
   output [15:0] dbg_st /*verilator public_flat*/,
   output [15:0] dbg_ir /*verilator public_flat*/,
   output [15:0] dbg_op1,
   output [15:0] dbg_op2,
   output [63:0] dbg_cycles /*verilator public_flat*/,
   output        dbg_wr,
   output [15:0] dbg_waddr,
   output  [7:0] dbg_wdata
);

assign dbg_wr = core.bus_as && core.bus_we;
assign dbg_waddr = core.bus_addr;
assign dbg_wdata = core.bus_dout;

wire        dram_req, dram_we;
wire [19:0] dram_addr;
wire  [7:0] dram_wdata;
reg   [7:0] dram_rdata;
reg         dram_ack;
reg   [7:0] dram [0:1048575];      // DRAM, then the IDE card SRAM

`ifdef DRAM_DEBUG
always @(posedge clk) if ((core.bus_as || core.bus_rs || core.bus_ack) && core.dbg_cycles > 4268600 && core.dbg_cycles < 4268700)
   $display("t=%0d c=%0d as=%b rs=%b we=%b ack=%b addr=%04x dout=%02x onchip=%b func=%0d pend_w=%b", $time, core.dbg_cycles, core.bus_as, core.bus_rs, core.bus_we, core.bus_ack, core.bus_addr, core.bus_dout, core.bus_onchip, core.func, core.pend_write);
always @(posedge clk) if (dram_req && dram_addr < 19'h4) $display("DRAM %s %05x %02x (rd %02x) t=%0d", dram_we ? "W" : "R", dram_addr, dram_wdata, dram[dram_addr], core.dbg_cycles);
`endif
// DRAM with a fixed latency (DRAM_LAT clks), as the SDRAM behind the clock-domain handshake
`ifndef DRAM_LAT
`define DRAM_LAT 8
`endif
reg [4:0] dram_cnt = 0;
reg [19:0] dram_a_r;
reg dram_we_r;
reg [7:0] dram_wd_r;
wire [19:0] sram_load_a = rom_addr - 20'h10000 + 20'h80000;
always @(posedge clk) begin
   if (rom_wr && rom_addr >= 20'h10000) dram[sram_load_a] <= rom_data;
   dram_ack <= 1'b0;
   if (dram_req) begin
      dram_cnt <= `DRAM_LAT;
      dram_a_r <= dram_addr;
      dram_we_r <= dram_we;
      dram_wd_r <= dram_wdata;
   end else if (dram_cnt == 5'd1) begin
      if (dram_we_r) dram[dram_a_r] <= dram_wd_r;
      dram_rdata <= dram[dram_a_r];
      dram_ack <= 1'b1;
      dram_cnt <= 0;
   end else if (dram_cnt != 0)
      dram_cnt <= dram_cnt - 1'b1;
end

`ifdef MOUSE_DEBUG
reg [23:0] mwin = 0;
always @(posedge clk) begin
   if (mouse_stb) begin
      mwin <= 24'd2000000;
      $display("MOUSE stb dx=%0d dy=%0d btn=%b c=%0d", $signed(mouse_dx), $signed(mouse_dy), mouse_btn, core.dbg_cycles);
   end else if (mwin != 0) mwin <= mwin - 1'b1;
   if (mwin != 0 && core.vdp_ack && core.vdp_port == 2'd1 && !core.vdp_wrt)
      $display("  S read %02x", core.vdp_dbi);
   if (mwin != 0 && core.cru_rd && core.cru_addr == 16'h0038)
      $display("  CRU 9901 bit 28 read: pin=%b dir12=%b", core.pin_in[10], core.p_dir[12]);
end
`endif

`ifdef VRAM_DEBUG
reg vx_rd_d;
always @(posedge clk) begin
   vx_rd_d <= core.pram_exp && !core.pram_oe_n;
   if (core.pram_exp && !core.pram_we_n) $display("VRAMX write %05x <- %02x (enabled %b)", core.pram_adr, core.pram_dbo, core.vram192);
   if (vx_rd_d) $display("VRAMX read -> %04x", core.pram_dbi);
end
`endif

`ifdef USE_SD
wire        c_fdc_rd, c_fdc_wr, c_fdc_drive, c_fdc_ack, c_buf_wr;
wire [15:0] c_fdc_lsn;
wire  [7:0] c_buf_addr, c_buf_din, c_buf_dout;
wire  [1:0] c_ready, c_wprot;
wire  [1:0][7:0] c_spt, c_tracks;
wire  [1:0][1:0] c_sides;
wire [31:0] sd_lba[2];
wire  [7:0] sd_buff_din[2];
assign sd_lba0 = sd_lba[0];
assign sd_lba1 = sd_lba[1];
assign sd_buff_din0 = sd_buff_din[0];
assign sd_buff_din1 = sd_buff_din[1];
assign fdc_rd = 1'b0;
assign fdc_wr = 1'b0;

geneve_disk disk (
   .clk(clk), .reset(reset),
   .img_mounted(img_mounted), .img_readonly(1'b0), .img_size(img_size),
   .sd_lba(sd_lba), .sd_rd(sd_rd), .sd_wr(sd_wr), .sd_ack(sd_ack),
   .sd_buff_addr(sd_buff_addr), .sd_buff_dout(sd_buff_dout), .sd_buff_din(sd_buff_din), .sd_buff_wr(sd_buff_wr),
   .ready(c_ready), .wprot(c_wprot), .spt(c_spt), .tracks(c_tracks), .sides(c_sides),
   .img_rd(c_fdc_rd), .img_wr(c_fdc_wr), .img_lsn(c_fdc_lsn), .img_drive(c_fdc_drive), .img_ack(c_fdc_ack),
   .buf_wr(c_buf_wr), .buf_addr(c_buf_addr), .buf_din(c_buf_din), .buf_dout(c_buf_dout),
   .busy()
);
`define FDC_PORTS .fdc_ready(c_ready), .fdc_wprot(c_wprot), .fdc_spt(c_spt), .fdc_tracks(c_tracks), .fdc_sides(c_sides), \
   .fdc_rd(c_fdc_rd), .fdc_wr(c_fdc_wr), .fdc_lsn(c_fdc_lsn), .fdc_drive(c_fdc_drive), .fdc_ack(c_fdc_ack), \
   .fdc_buf_wr(c_buf_wr), .fdc_buf_addr(c_buf_addr), .fdc_buf_din(c_buf_din), .fdc_buf_dout(c_buf_dout),
`else
assign sd_lba0 = 0; assign sd_lba1 = 0; assign sd_rd = 0; assign sd_wr = 0;
assign sd_buff_din0 = 0; assign sd_buff_din1 = 0;
`define FDC_PORTS .fdc_ready(fdc_ready), .fdc_wprot(fdc_wprot), \
   .fdc_spt({fdc_spt1, fdc_spt0}), .fdc_tracks({fdc_tracks1, fdc_tracks0}), .fdc_sides({fdc_sides1, fdc_sides0}), \
   .fdc_rd(fdc_rd), .fdc_wr(fdc_wr), .fdc_lsn(fdc_lsn), .fdc_drive(fdc_drive), .fdc_ack(fdc_ack), \
   .fdc_buf_wr(fdc_buf_wr), .fdc_buf_addr(fdc_buf_addr), .fdc_buf_din(fdc_buf_din), .fdc_buf_dout(fdc_buf_dout),
`endif

geneve_core core (
   .clk(clk), .reset(reset),
   .rom_wr(rom_wr && rom_addr < 20'h0a000), .rom_addr(rom_addr[15:0]), .rom_data(rom_data),
   .boot200(boot200), .ide_en(ide_en), .vram192(vram192),
   .dram_req(dram_req), .dram_we(dram_we), .dram_addr(dram_addr), .dram_wdata(dram_wdata),
   .dram_rdata(dram_rdata), .dram_ack(dram_ack),
   .vga_r(vga_r), .vga_g(vga_g), .vga_b(vga_b), .vga_hs_n(vga_hs_n), .vga_vs_n(vga_vs_n),
   .vga_dhclk(vga_dhclk), .vga_dlclk(vga_dlclk), .vga_de(vga_de), .dbg_vdp(), .dbg_vdpw(),
   .sound(sound),
   .kbd_strobe(kbd_strobe), .kbd_code(kbd_code),
   .joy1(joy1), .joy2(joy2),
   .mouse_stb(mouse_stb), .mouse_dx(mouse_dx), .mouse_dy(mouse_dy), .mouse_btn(mouse_btn),
   .rtc_load(rtc_load), .rtc_bcd(rtc_bcd),
   `FDC_PORTS
   .ide_mounted(ide_mounted), .ide_readonly(1'b0), .ide_size(ide_size), .ide_lba(ide_lba), .ide_rd(ide_rd), .ide_wr(ide_wr),
   .ide_ack(ide_ack), .ide_buff_addr(ide_buff_addr), .ide_buff_dout(ide_buff_dout), .ide_buff_din(ide_buff_din),
   .ide_buff_wr(ide_buff_wr), .ide_busy(),
   .dbg_inst(dbg_inst), .dbg_pc(dbg_pc), .dbg_wp(dbg_wp), .dbg_st(dbg_st), .dbg_ir(dbg_ir), .dbg_op1(dbg_op1), .dbg_op2(dbg_op2), .dbg_cycles(dbg_cycles)
);

endmodule
