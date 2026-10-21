`timescale 1ns/1ns
//
// Simulation top for the Geneve 9640 core: rtl/geneve_core.sv with the 512 KiB DRAM as an array and the
// ports visible to the C++ harness (sim_headless.cpp), which loads the ROMs and serves the floppy images.
//
module top(
   input         clk /*verilator public_flat*/,
   input         reset /*verilator public_flat*/,

   input         rom_wr,
   input  [14:0] rom_addr,
   input   [7:0] rom_data,

   output  [5:0] vga_r /*verilator public_flat*/,
   output  [5:0] vga_g /*verilator public_flat*/,
   output  [5:0] vga_b /*verilator public_flat*/,
   output        vga_hs_n /*verilator public_flat*/,
   output        vga_vs_n /*verilator public_flat*/,
   output        vga_dhclk /*verilator public_flat*/,
   output        vga_dlclk /*verilator public_flat*/,
   output  [7:0] sound,

   input         kbd_strobe,
   input   [7:0] kbd_code,
   input   [4:0] joy1,
   input   [4:0] joy2,
   input         rtc_load,
   input  [55:0] rtc_bcd,

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
wire [18:0] dram_addr;
wire  [7:0] dram_wdata;
reg   [7:0] dram_rdata;
reg         dram_ack;
reg   [7:0] dram [0:524287];

`ifdef DRAM_DEBUG
always @(posedge clk) if ((core.bus_as || core.bus_rs || core.bus_ack) && core.dbg_cycles > 4268600 && core.dbg_cycles < 4268700)
   $display("t=%0d c=%0d as=%b rs=%b we=%b ack=%b addr=%04x dout=%02x onchip=%b func=%0d pend_w=%b", $time, core.dbg_cycles, core.bus_as, core.bus_rs, core.bus_we, core.bus_ack, core.bus_addr, core.bus_dout, core.bus_onchip, core.func, core.pend_write);
always @(posedge clk) if (dram_req && dram_addr < 19'h4) $display("DRAM %s %05x %02x (rd %02x) t=%0d", dram_we ? "W" : "R", dram_addr, dram_wdata, dram[dram_addr], core.dbg_cycles);
`endif
always @(posedge clk) begin
   dram_ack <= 1'b0;
   if (dram_req) begin
      if (dram_we) dram[dram_addr] <= dram_wdata;
      dram_rdata <= dram[dram_addr];
      dram_ack <= 1'b1;
   end
end

geneve_core core (
   .clk(clk), .reset(reset),
   .rom_wr(rom_wr), .rom_addr(rom_addr), .rom_data(rom_data),
   .dram_req(dram_req), .dram_we(dram_we), .dram_addr(dram_addr), .dram_wdata(dram_wdata),
   .dram_rdata(dram_rdata), .dram_ack(dram_ack),
   .vga_r(vga_r), .vga_g(vga_g), .vga_b(vga_b), .vga_hs_n(vga_hs_n), .vga_vs_n(vga_vs_n),
   .vga_dhclk(vga_dhclk), .vga_dlclk(vga_dlclk),
   .sound(sound),
   .kbd_strobe(kbd_strobe), .kbd_code(kbd_code),
   .joy1(joy1), .joy2(joy2),
   .rtc_load(rtc_load), .rtc_bcd(rtc_bcd),
   .fdc_ready(fdc_ready), .fdc_wprot(fdc_wprot),
   .fdc_spt({fdc_spt1, fdc_spt0}), .fdc_tracks({fdc_tracks1, fdc_tracks0}), .fdc_sides({fdc_sides1, fdc_sides0}),
   .fdc_rd(fdc_rd), .fdc_wr(fdc_wr), .fdc_lsn(fdc_lsn), .fdc_drive(fdc_drive), .fdc_ack(fdc_ack),
   .fdc_buf_wr(fdc_buf_wr), .fdc_buf_addr(fdc_buf_addr), .fdc_buf_din(fdc_buf_din), .fdc_buf_dout(fdc_buf_dout),
   .dbg_inst(dbg_inst), .dbg_pc(dbg_pc), .dbg_wp(dbg_wp), .dbg_st(dbg_st), .dbg_ir(dbg_ir), .dbg_op1(dbg_op1), .dbg_op2(dbg_op2), .dbg_cycles(dbg_cycles)
);

endmodule
