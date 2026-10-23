//============================================================================
//
//  Myarc Geneve 9640 for MiSTer
//
//  This program is free software; you can redistribute it and/or modify it
//  under the terms of the GNU General Public License as published by the Free
//  Software Foundation; either version 2 of the License, or (at your option)
//  any later version.
//
//  This program is distributed in the hope that it will be useful, but WITHOUT
//  ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
//  FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License for
//  more details.
//
//  You should have received a copy of the GNU General Public License along
//  with this program; if not, write to the Free Software Foundation, Inc.,
//  51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
//
//============================================================================

module emu
(
	`include "sys/emu_ports.vh"
);

///////// Default values for ports not used in this core /////////

assign ADC_BUS  = 'Z;
assign USER_OUT = '1;
assign {UART_RTS, UART_DTR} = 0;
assign {SD_SCK, SD_MOSI, SD_CS} = 'Z;
assign {DDRAM_CLK, DDRAM_BURSTCNT, DDRAM_ADDR, DDRAM_DIN, DDRAM_BE, DDRAM_RD, DDRAM_WE} = '0;

assign VGA_SL = 0;
assign VGA_F1 = 0;
assign VGA_SCALER  = 0;
assign VGA_DISABLE = 0;
assign HDMI_FREEZE = 0;
assign HDMI_BLACKOUT = 0;
assign HDMI_BOB_DEINT = 0;

assign AUDIO_S = 0;
assign AUDIO_MIX = 0;

assign LED_POWER = 0;
assign BUTTONS = 0;

//////////////////////////////////////////////////////////////////

// OSD as in the MiSTer computer-core OSD standard: media on the top page act at once, every
// other setting waits for Apply and reset (or any reset); "Changes pending" shows meanwhile.
`include "build_id.v"
localparam CONF_STR = {
	"Geneve;;",
	"-;",
	"SC0,DSK,Pri. DSK1;",
	"SC1,DSK,DSK2;",
	"SC2,HDVRAWIMG,IDE disk;",
	"F0,ROM,Load ROM;",
	"-;",
	"O[7],Memory,512K,Genmod 2M;",
	"-;",
	"P1,Machine;",
	"P2,Video;",
	"P5,Advanced;",
	"-;",
	"h0-,Changes pending;",
	"R[0],Apply and reset;",

	"P1O[5],Video RAM,128K,192K;",
	"P1O[9:8],IDE card,Auto,Off,On;",
	"P1O[6],Speech synth.,On,Off;",

	"P2O[122:121],Aspect ratio,Original,Full Screen,[ARC1],[ARC2];",

	"P5O[11:10],Boot ROM,Auto,1.00,2.00;",

	"J1,Fire;",
	"v,1;",
	"V,v",`BUILD_DATE
};

/////////////////  CLOCKS  ////////////////////////

// 85.909 MHz (SDRAM), the same phase shifted for the SDRAM_CLK pin, and
// 21.477 MHz = 6 x NTSC colour burst (the V9938 clock; the machine runs on it).
wire clk_mem, clk_sdram, clk_sys;
wire pll_locked;

pll pll
(
	.refclk(CLK_50M),
	.rst(0),
	.outclk_0(clk_mem),
	.outclk_1(clk_sdram),
	.outclk_2(clk_sys),
	.locked(pll_locked)
);

/////////////////  HPS  ///////////////////////////

wire         forced_scandoubler;
wire   [1:0] buttons;
wire [127:0] status;
reg  [127:0] cfg;          // the settings the machine runs with (below)
wire         pending;
wire  [10:0] ps2_key;
wire  [24:0] ps2_mouse;
wire  [31:0] joystick_0, joystick_1;
wire  [64:0] rtc;

wire         ioctl_download;
wire  [15:0] ioctl_index;
wire         ioctl_wr;
wire  [26:0] ioctl_addr;
wire   [7:0] ioctl_dout;

wire   [2:0] img_mounted;
wire         img_readonly;
wire  [63:0] img_size;
wire  [31:0] sd_lba[3];
wire   [2:0] sd_rd, sd_wr, sd_ack;
wire   [8:0] sd_buff_addr;
wire   [7:0] sd_buff_dout;
wire   [7:0] sd_buff_din[3];
wire         sd_buff_wr;
wire         ld_busy;

hps_io #(.CONF_STR(CONF_STR), .VDNUM(3)) hps_io
(
	.clk_sys(clk_sys),
	.HPS_BUS(HPS_BUS),
	.EXT_BUS(),
	.gamma_bus(),

	.forced_scandoubler(forced_scandoubler),
	.buttons(buttons),
	.status(status),
	.status_menumask({15'd0, pending}),

	.ps2_key(ps2_key),
	.ps2_mouse(ps2_mouse),
	.joystick_0(joystick_0),
	.joystick_1(joystick_1),
	.RTC(rtc),

	.ioctl_download(ioctl_download),
	.ioctl_index(ioctl_index),
	.ioctl_wr(ioctl_wr),
	.ioctl_addr(ioctl_addr),
	.ioctl_dout(ioctl_dout),
	.ioctl_wait(ld_busy),

	.img_mounted(img_mounted),
	.img_readonly(img_readonly),
	.img_size(img_size),
	.sd_lba(sd_lba),
	.sd_blk_cnt('{6'd0, 6'd0, 6'd0}),
	.sd_rd(sd_rd),
	.sd_wr(sd_wr),
	.sd_ack(sd_ack),
	.sd_buff_addr(sd_buff_addr),
	.sd_buff_dout(sd_buff_dout),
	.sd_buff_din(sd_buff_din),
	.sd_buff_wr(sd_buff_wr)
);

/////////////////  RESET  /////////////////////////

reg  ide_auto_reset = 0;
wire reset = RESET | status[0] | buttons[1] | ioctl_download | ~pll_locked | ide_auto_reset;

// The settings the machine runs with, taken from the OSD at every reset
always @(posedge clk_sys) if (reset) cfg <= status;

assign pending = {status[11:5], status[122:121]} != {cfg[11:5], cfg[122:121]};

// Auto (IDE card, Boot ROM): an IDE disk turns the card on, and the machine boots it with boot ROM 2.00
// unless a floppy was mounted in DSK1 after it: of the two boot disks the one mounted last wins. A core
// start mounts the remembered slots first and an MGL's disks after them, so an MGL's boot disk wins.
// A mount that changes the Auto choice resets the machine while the boot window after a reset is open
// (5 s), and an IDE disk mounted or removed later resets it too; floppies changed later only count at
// the next reset.
reg ide_present = 0, ide_last = 0;
reg ide_present_r = 0, ide_last_r = 0;
always @(posedge clk_sys) begin
	if (img_mounted[2]) begin
		ide_present <= |img_size;
		ide_last <= |img_size;
	end
	if (img_mounted[0] && |img_size) ide_last <= 0;
	if (reset) begin
		ide_present_r <= ide_present;
		ide_last_r <= ide_last;
	end
end

wire auto_ide  = cfg[9:8] == 2'd0;
wire auto_boot = cfg[11:10] == 2'd0;
wire ide_on    = auto_ide  ? ide_present_r : (cfg[9:8] == 2'd2);
wire boot_200  = auto_boot ? (ide_present_r && ide_last_r) : (cfg[11:10] == 2'd2);

wire auto_changed = (auto_ide && ide_present != ide_present_r) ||
                    (auto_boot && (ide_present && ide_last) != (ide_present_r && ide_last_r));

always @(posedge clk_sys) begin
	reg  [3:0] cnt;
	reg [27:0] window;
	if (reset) window <= 28'd107386360;          // 5 s of clk_sys
	else if (window) window <= window - 1'd1;
	if (ide_auto_reset) begin
		cnt <= cnt + 1'd1;
		if (&cnt) ide_auto_reset <= 0;
	end else if (!reset && auto_changed && (window || (auto_ide && ide_present != ide_present_r))) begin
		ide_auto_reset <= 1;
		cnt <= 0;
	end
end

wire [1:0] ar = cfg[122:121];

assign VIDEO_ARX = (!ar) ? 12'd4 : (ar - 1'd1);
assign VIDEO_ARY = (!ar) ? 12'd3 : 12'd0;

/////////////////  DRAM in SDRAM  /////////////////

// The core asks for one byte at a time on clk_sys (dram_req, one clk) and
// waits for dram_ack. The controller runs on clk_mem = 4 x clk_sys (same PLL).
// 00000-7FFFF: DRAM, 80000-FFFFF: IDE card SRAM (loaded from boot.rom 10000-8FFFF
// during the download, the core is in reset then), 200000-3FFFFF: Memex (Genmod).
wire        dram_req, dram_we;
wire [21:0] dram_addr;
wire  [7:0] dram_wdata;
reg   [7:0] dram_rdata;
reg         dram_ack;

reg         sd_req_t = 0, sd_done_t = 0;     // toggles: clk_sys -> clk_mem, clk_mem -> clk_sys
reg         sd_we_r;
reg  [21:0] sd_addr_r;
reg   [7:0] sd_wdata_r;
reg         ld_pend = 0;

wire        ld_sram = ioctl_download && ioctl_wr && ioctl_index == 16'd0 && ioctl_addr >= 27'h10000 && ioctl_addr < 27'h90000;
wire [21:0] ld_addr = {2'b00, ioctl_addr[19:0] - 20'h10000 + 20'h80000};
assign      ld_busy = ld_pend;

always @(posedge clk_sys) begin
	reg done_old;
	dram_ack <= 0;
	if (ld_sram) begin
		ld_pend <= 1;
		sd_req_t <= ~sd_req_t;
		sd_we_r <= 1;
		sd_addr_r <= ld_addr;
		sd_wdata_r <= ioctl_dout;
	end else if (dram_req) begin
		sd_req_t <= ~sd_req_t;
		sd_we_r <= dram_we;
		sd_addr_r <= dram_addr;
		sd_wdata_r <= dram_wdata;
	end
	done_old <= sd_done_t;
	if (done_old != sd_done_t) begin
		if (ld_pend)
			ld_pend <= 0;
		else begin
			dram_ack <= 1;
			dram_rdata <= sdram_dout_r;
		end
	end
end

wire [15:0] sdram_dout;
reg   [7:0] sdram_dout_r;
reg         sdram_rd, sdram_we;
wire        sdram_ready;

always @(posedge clk_mem) begin
	reg req_old;
	reg busy;
	reg [1:0] wait_cnt;
	req_old <= sd_req_t;
	if (req_old != sd_req_t) begin
		sdram_rd <= ~sd_we_r;
		sdram_we <= sd_we_r;
		busy <= 1;
		wait_cnt <= 2'd2;
	end else if (busy) begin
		if (wait_cnt != 0) wait_cnt <= wait_cnt - 1'd1;
		else if (sdram_ready) begin
			sdram_rd <= 0;
			sdram_we <= 0;
			busy <= 0;
			sdram_dout_r <= sdram_dout[7:0];
			sd_done_t <= ~sd_done_t;
		end
	end
end

sdram sdram
(
	.init(~pll_locked),
	.clk(clk_mem),
	.clk_pin(clk_sdram),
	.SDRAM_DQ(SDRAM_DQ), .SDRAM_A(SDRAM_A), .SDRAM_DQML(SDRAM_DQML), .SDRAM_DQMH(SDRAM_DQMH), .SDRAM_BA(SDRAM_BA),
	.SDRAM_nCS(SDRAM_nCS), .SDRAM_nWE(SDRAM_nWE), .SDRAM_nRAS(SDRAM_nRAS), .SDRAM_nCAS(SDRAM_nCAS),
	.SDRAM_CKE(SDRAM_CKE), .SDRAM_CLK(SDRAM_CLK),
	.wtbt(2'b00),
	.addr({3'd0, sd_addr_r}),
	.dout(sdram_dout),
	.din({8'h00, sd_wdata_r}),
	.we(sdram_we),
	.rd(sdram_rd),
	.ready(sdram_ready)
);

/////////////////  MOUSE  /////////////////////////

// PS/2 packet: [7:0] flags (0 left, 1 right, 2 middle, 4 X sign, 5 Y sign), [15:8] X, [23:16] Y (up),
// [24] toggles per packet. The bus mouse wants x right / y down, limited to -127..127.
reg        mouse_stb;
reg  [7:0] mouse_dx, mouse_dy;
always @(posedge clk_sys) begin
	reg        old_t;
	reg  [8:0] x, y;
	old_t <= ps2_mouse[24];
	mouse_stb <= 0;
	if (old_t != ps2_mouse[24]) begin
		x = {ps2_mouse[4], ps2_mouse[15:8]};
		y = -{ps2_mouse[5], ps2_mouse[23:16]};
		mouse_dx <= ($signed(x) > 127) ? 8'd127 : ($signed(x) < -127) ? 8'h81 : x[7:0];
		mouse_dy <= ($signed(y) > 127) ? 8'd127 : ($signed(y) < -127) ? 8'h81 : y[7:0];
		mouse_stb <= 1;
	end
end

/////////////////  KEYBOARD, RTC  /////////////////

wire       kbd_strobe;
wire [7:0] kbd_code;

ps2_xt ps2_xt
(
	.clk(clk_sys),
	.reset(reset),
	.ps2_key(ps2_key),
	.strobe(kbd_strobe),
	.code(kbd_code)
);

reg rtc_load;
always @(posedge clk_sys) begin
	reg old_t, old_reset;
	old_t <= rtc[64];
	old_reset <= reset;
	rtc_load <= (old_t != rtc[64]) || (old_reset && !reset);
end

/////////////////  FLOPPY IMAGES  /////////////////

wire        fdc_rd, fdc_wr, fdc_drive, fdc_ack;
wire [15:0] fdc_lsn;
wire        fdc_buf_wr;
wire  [7:0] fdc_buf_addr, fdc_buf_din, fdc_buf_dout;
wire  [1:0] fdc_ready, fdc_wprot;
wire  [1:0][7:0] fdc_spt, fdc_tracks;
wire  [1:0][1:0] fdc_sides;
wire        disk_busy, ide_busy;
wire [31:0] fd_lba[2];
wire  [7:0] fd_buff_din[2];
wire  [1:0] fd_rd, fd_wr;
wire        ide_rd, ide_wr;

assign sd_lba[0] = fd_lba[0];
assign sd_lba[1] = fd_lba[1];
assign sd_buff_din[0] = fd_buff_din[0];
assign sd_buff_din[1] = fd_buff_din[1];
assign sd_rd = {ide_rd, fd_rd};
assign sd_wr = {ide_wr, fd_wr};

geneve_disk disk
(
	.clk(clk_sys),
	.reset(~pll_locked),
	.img_mounted(img_mounted[1:0]), .img_readonly(img_readonly), .img_size(img_size),
	.sd_lba(fd_lba), .sd_rd(fd_rd), .sd_wr(fd_wr), .sd_ack(sd_ack[1:0]),
	.sd_buff_addr(sd_buff_addr), .sd_buff_dout(sd_buff_dout), .sd_buff_din(fd_buff_din), .sd_buff_wr(sd_buff_wr),
	.ready(fdc_ready), .wprot(fdc_wprot), .spt(fdc_spt), .tracks(fdc_tracks), .sides(fdc_sides),
	.img_rd(fdc_rd), .img_wr(fdc_wr), .img_lsn(fdc_lsn), .img_drive(fdc_drive), .img_ack(fdc_ack),
	.buf_wr(fdc_buf_wr), .buf_addr(fdc_buf_addr), .buf_din(fdc_buf_din), .buf_dout(fdc_buf_dout),
	.busy(disk_busy)
);

assign LED_DISK = {1'b0, disk_busy | ide_busy};

/////////////////  DEBUG UART  //////////////////

// Every 0.1 s on UART TX (/dev/ttyS1 on the HPS, 115200 baud), 16 hex digits:
// PC | VDP debug (CE, cmd WR req/ack, RD req/ack, DOTSTATE, 0, cmd state, cmd) | CPU cycles[31:16] | ROM bytes/256 | flags
wire [15:0] dbg_pc;
wire [63:0] dbg_cycles;
wire [15:0] dbg_vdp, dbg_vdpw;
reg   [7:0] dbg_dreq, dbg_dack, dbg_rom;
always @(posedge clk_sys) begin
	if (dram_req) dbg_dreq <= dbg_dreq + 1'd1;
	if (dram_ack) dbg_dack <= dbg_dack + 1'd1;
	if (ioctl_download && ioctl_wr && ioctl_index == 16'd0 && ioctl_addr[7:0] == 8'd0 && dbg_rom != 8'hff)
		dbg_rom <= dbg_rom + 1'd1;
end

dbg_uart #(.CLK_HZ(21477272), .PERIOD(2147727)) dbg_uart
(
	.clk(clk_sys),
	.value({dbg_pc, dbg_vdp, dbg_vdpw, dbg_rom,
	        reset, pll_locked, ioctl_download, disk_busy, fdc_ready, 2'b00}),
	.tx(UART_TXD)
);

/////////////////  MACHINE  ///////////////////////

wire [5:0] r, g, b;
wire       hs_n, vs_n, dhclk, de;
wire [7:0] sound;
wire signed [7:0] speech;

geneve_core core
(
	.clk(clk_sys),
	.reset(reset),

	.rom_wr(ioctl_download && ioctl_wr && ioctl_index == 16'd0 && (ioctl_addr < 27'ha000 || (ioctl_addr >= 27'h90000 && ioctl_addr < 27'ha0000))),
	.rom_addr(ioctl_addr[19:0]),
	.rom_data(ioctl_dout),
	.boot200(boot_200),
	.ide_en(ide_on),
	.vram192(cfg[5]),
	.speech_en(~cfg[6]),
	.genmod(cfg[7]),

	.dram_req(dram_req), .dram_we(dram_we), .dram_addr(dram_addr), .dram_wdata(dram_wdata),
	.dram_rdata(dram_rdata), .dram_ack(dram_ack),

	.vga_r(r), .vga_g(g), .vga_b(b), .vga_hs_n(hs_n), .vga_vs_n(vs_n),
	.vga_dhclk(dhclk), .vga_dlclk(), .vga_de(de), .dbg_vdp(dbg_vdp), .dbg_vdpw(dbg_vdpw),

	.sound(sound), .speech(speech),

	.kbd_strobe(kbd_strobe), .kbd_code(kbd_code),
	.joy1({joystick_0[3], joystick_0[2], joystick_0[0], joystick_0[1], joystick_0[4]}),
	.joy2({joystick_1[3], joystick_1[2], joystick_1[0], joystick_1[1], joystick_1[4]}),
	.mouse_stb(mouse_stb), .mouse_dx(mouse_dx), .mouse_dy(mouse_dy),
	.mouse_btn({ps2_mouse[0], ps2_mouse[2], ps2_mouse[1]}),

	.rtc_load(rtc_load), .rtc_bcd(rtc[55:0]),

	.fdc_ready(fdc_ready), .fdc_wprot(fdc_wprot), .fdc_spt(fdc_spt), .fdc_tracks(fdc_tracks), .fdc_sides(fdc_sides),
	.fdc_rd(fdc_rd), .fdc_wr(fdc_wr), .fdc_lsn(fdc_lsn), .fdc_drive(fdc_drive), .fdc_ack(fdc_ack),
	.fdc_buf_wr(fdc_buf_wr), .fdc_buf_addr(fdc_buf_addr), .fdc_buf_din(fdc_buf_din), .fdc_buf_dout(fdc_buf_dout),

	.ide_mounted(img_mounted[2]), .ide_readonly(img_readonly), .ide_size(img_size),
	.ide_lba(sd_lba[2]), .ide_rd(ide_rd), .ide_wr(ide_wr), .ide_ack(sd_ack[2]),
	.ide_buff_addr(sd_buff_addr), .ide_buff_dout(sd_buff_dout), .ide_buff_din(sd_buff_din[2]),
	.ide_buff_wr(sd_buff_wr && sd_ack[2]), .ide_busy(ide_busy),

	.dbg_inst(), .dbg_pc(dbg_pc), .dbg_wp(), .dbg_st(), .dbg_ir(), .dbg_op1(), .dbg_op2(), .dbg_cycles(dbg_cycles)
);

/////////////////  VIDEO, AUDIO  //////////////////

assign CLK_VIDEO = clk_sys;
assign CE_PIXEL  = dhclk;

reg [7:0] ro, go, bo;
reg       hso, vso, deo;
always @(posedge clk_sys) if (dhclk) begin
	ro <= {r, r[5:4]};
	go <= {g, g[5:4]};
	bo <= {b, b[5:4]};
	deo <= de;
	hso <= ~hs_n;
	if (~hso & ~hs_n) vso <= ~vs_n;
end

assign VGA_R  = ro;
assign VGA_G  = go;
assign VGA_B  = bo;
assign VGA_HS = hso;
assign VGA_VS = vso;
assign VGA_DE = deo;

// sound chip (unsigned) and speech (signed, centred), half each
assign AUDIO_L = {2'b00, sound, 6'd0} + {1'b0, ~speech[7], speech[6:0], 6'd0};
assign AUDIO_R = AUDIO_L;

reg [26:0] act_cnt;
always @(posedge clk_sys) act_cnt <= act_cnt + 1'd1;
assign LED_USER = disk_busy | act_cnt[26];

endmodule
