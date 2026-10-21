//=======================================================================================================
//
// dbg_uart.sv - debug channel: prints a 64-bit snapshot as 16 hex digits and CR LF on the core's UART TX,
// every PERIOD clocks. On a MiSTer the core UART reaches the HPS as /dev/ttyS1:
//   stty -F /dev/ttyS1 115200 raw -echo; cat /dev/ttyS1
//
// Copyright (C) 2026 Alan Steremberg. GPL-3.0-or-later (see LICENSE).
//=======================================================================================================

module dbg_uart #(parameter integer CLK_HZ = 85909091, parameter integer BAUD = 115200,
                  parameter integer PERIOD = 8590909)                           // 0.1 s
(
	input         clk,
	input  [63:0] value,
	output reg    tx = 1'b1
);

localparam integer DIV = CLK_HZ / BAUD;

reg [31:0] tick_cnt = 0;
reg [15:0] baud_cnt = 0;
reg [63:0] snap;
reg  [4:0] chr;          // 0-15 hex digits, 16 CR, 17 LF, 18 idle
reg  [3:0] bitn;         // 0 start, 1-8 data, 9 stop
reg  [7:0] cur;
reg        busy = 1'b0;

function [7:0] hexc(input [3:0] n);
	hexc = (n < 4'd10) ? 8'h30 + n : 8'h37 + n;
endfunction

wire [7:0] next_char = (chr < 5'd16) ? hexc(snap[63 - chr*4 -: 4]) : (chr == 5'd16) ? 8'h0D : 8'h0A;

always @(posedge clk) begin
	tick_cnt <= tick_cnt + 1;
	if (!busy && tick_cnt >= PERIOD) begin
		tick_cnt <= 0;
		snap <= value;
		chr <= 5'd0; bitn <= 4'd0; baud_cnt <= 0; busy <= 1'b1;
	end
	else if (busy) begin
		if (baud_cnt != DIV - 1) baud_cnt <= baud_cnt + 1'd1;
		else begin
			baud_cnt <= 0;
			if (bitn == 4'd9) begin
				bitn <= 4'd0;
				if (chr == 5'd17) busy <= 1'b0;
				chr <= chr + 1'd1;
			end
			else bitn <= bitn + 1'd1;
		end
		// output follows bitn
		if (bitn == 4'd0) begin tx <= 1'b0; cur <= next_char; end
		else if (bitn == 4'd9) tx <= 1'b1;
		else tx <= cur[bitn - 1];
	end
	else tx <= 1'b1;
end

endmodule
