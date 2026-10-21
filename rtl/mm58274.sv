//============================================================================
//  MM58274C real time clock
//
//  Register behaviour as in MAME's mm58274c.cpp (Raphael Nabet). The time is
//  loaded from the MiSTer RTC (BCD, hps_io RTC[55:0]) when time_load pulses.
//  The interrupt timer is not emulated (MAME does not wire it on the Geneve).
//============================================================================

module mm58274 #(parameter int CLK_HZ = 21477272) (
    input  logic        clk,
    input  logic        reset,

    input  logic [3:0]  addr,
    input  logic        wr,
    input  logic [3:0]  wdata,
    output logic [3:0]  rdata,
    input  logic        rd,             // read strobe (clears the status register)

    input  logic        time_load,
    input  logic [55:0] time_bcd        // {wday, year, month, day, hour, min, sec} in BCD (hps_io order reversed)
);

logic [3:0] status, control, clk_set, int_ctl, wday;
logic [3:0] years1, years2, months1, months2, days1, days2;
logic [3:0] hours1, hours2, minutes1, minutes2, seconds1, seconds2, tenths;
logic [31:0] div;

always_comb begin
    case (addr)
    4'h0: rdata = status;
    4'h1: rdata = tenths;
    4'h2: rdata = seconds2;
    4'h3: rdata = seconds1;
    4'h4: rdata = minutes2;
    4'h5: rdata = minutes1;
    4'h6: rdata = hours2;
    4'h7: rdata = hours1;
    4'h8: rdata = days2;
    4'h9: rdata = days1;
    4'ha: rdata = months2;
    4'hb: rdata = months1;
    4'hc: rdata = years2;
    4'hd: rdata = years1;
    4'he: rdata = wday;
    default: rdata = control[1] ? int_ctl : (clk_set[0] ? (clk_set & 4'b1101) : clk_set);
    endcase
end

function automatic logic [4:0] days_in_month(input logic [3:0] m1, input logic [3:0] m2,
                                             input logic [3:0] cs);
    logic [4:0] m;
    m = 5'(m1 * 10 + m2);
    case (m)
    5'd2: days_in_month = (cs[3:2] != 2'b00) ? 5'd28 : 5'd29;
    5'd4, 5'd6, 5'd9, 5'd11: days_in_month = 5'd30;
    default: days_in_month = 5'd31;
    endcase
endfunction

/* verilator lint_off BLKSEQ */
always_ff @(posedge clk) begin
    logic [4:0] h;
    if (reset) begin
        status = 4'd0;
        control = 4'd0;
        div = 32'd0;
    end else begin
        if (rd && addr == 4'h0) status = 4'd0;
        if (wr) begin
            case (addr)
            4'h0: begin
                if (wdata[2]) tenths = 4'd0;
                control = wdata;
            end
            4'h2: seconds2 = wdata;
            4'h3: seconds1 = wdata;
            4'h4: minutes2 = wdata;
            4'h5: minutes1 = wdata;
            4'h6: hours2 = wdata;
            4'h7: hours1 = wdata;
            4'h8: days2 = wdata;
            4'h9: days1 = wdata;
            4'ha: months2 = wdata;
            4'hb: months1 = wdata;
            4'hc: years2 = wdata;
            4'hd: years1 = wdata;
            4'he: wday = wdata;
            4'hf: if (control[1]) int_ctl = wdata; else clk_set = wdata;
            default: ;
            endcase
        end

        // 1/10 s tick
        if (div == 32'(CLK_HZ / 10 - 1)) begin
            div = 32'd0;
            if (!control[2]) begin
                status = status | 4'h8;
                tenths = tenths + 4'd1;
                if (tenths == 4'd10) begin
                    tenths = 4'd0;
                    seconds2 = seconds2 + 4'd1;
                    if (seconds2 == 4'd10) begin
                        seconds2 = 4'd0;
                        seconds1 = seconds1 + 4'd1;
                        if (seconds1 == 4'd6) begin
                            seconds1 = 4'd0;
                            minutes2 = minutes2 + 4'd1;
                            if (minutes2 == 4'd10) begin
                                minutes2 = 4'd0;
                                minutes1 = minutes1 + 4'd1;
                                if (minutes1 == 4'd6) begin
                                    minutes1 = 4'd0;
                                    hours2 = hours2 + 4'd1;
                                    if (hours2 == 4'd10) begin
                                        hours2 = 4'd0;
                                        hours1 = hours1 + 4'd1;
                                    end
                                    h = 5'(hours1 * 10 + hours2);
                                    if (!clk_set[0] && h == 5'd12) clk_set = clk_set ^ 4'b0010;
                                    if (!clk_set[0] && h == 5'd13) begin
                                        hours1 = 4'd0;
                                        hours2 = 4'd1;
                                    end
                                    if (clk_set[0] && h == 5'd24) begin
                                        hours1 = 4'd0;
                                        hours2 = 4'd0;
                                    end
                                    h = 5'(hours1 * 10 + hours2);
                                    if (clk_set[0] ? (h == 5'd0) : (h == 5'd12 && !clk_set[1])) begin
                                        days2 = days2 + 4'd1;
                                        if (days2 == 4'd10) begin
                                            days2 = 4'd0;
                                            days1 = days1 + 4'd1;
                                        end
                                        wday = wday + 4'd1;
                                        if (wday == 4'd8) wday = 4'd1;
                                        if (5'(days1 * 10 + days2) == days_in_month(months1, months2, clk_set) + 5'd1) begin
                                            days1 = 4'd0;
                                            days2 = 4'd1;
                                            months2 = months2 + 4'd1;
                                            if (months2 == 4'd10) begin
                                                months2 = 4'd0;
                                                months1 = months1 + 4'd1;
                                            end
                                            if (5'(months1 * 10 + months2) == 5'd13) begin
                                                months1 = 4'd0;
                                                months2 = 4'd1;
                                                clk_set = {clk_set[3:2] + 2'd1, clk_set[1:0]};
                                                years2 = years2 + 4'd1;
                                                if (years2 == 4'd10) begin
                                                    years2 = 4'd0;
                                                    years1 = years1 + 4'd1;
                                                    if (years1 == 4'd10) years1 = 4'd0;
                                                end
                                            end
                                        end
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end else
            div = div + 32'd1;

        // Load the time (24-hour mode, Sunday = day 1, as MAME's Geneve setup)
        if (time_load) begin
            seconds1 = {1'b0, time_bcd[6:4]};
            seconds2 = time_bcd[3:0];
            minutes1 = {1'b0, time_bcd[14:12]};
            minutes2 = time_bcd[11:8];
            hours1   = {2'b0, time_bcd[21:20]};
            hours2   = time_bcd[19:16];
            days1    = {2'b0, time_bcd[29:28]};
            days2    = time_bcd[27:24];
            months1  = {3'b0, time_bcd[36]};
            months2  = time_bcd[35:32];
            years1   = time_bcd[47:44];
            years2   = time_bcd[43:40];
            wday     = time_bcd[51:48] + 4'd1;     // hps_io: 0 = Sunday
            // leap counter = year & 3, 24-hour mode
            clk_set  = {2'(years1 * 10 + years2), 2'b01};
            tenths   = 4'd0;
        end
    end
end
/* verilator lint_on BLKSEQ */

endmodule
