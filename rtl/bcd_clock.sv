//============================================================================
//  Running BCD clock
//
//  The MiSTer sends the time once (hps_io RTC); a clock chip has to keep it
//  moving itself. Loaded with {wday, year, month, day, hour, min, sec} in BCD
//  (hps_io order: wday 1-7, year 00-99 = 2000-2099), it counts seconds and
//  carries into minutes, hours, days (month lengths, leap years), months,
//  years and the weekday.
//============================================================================

module bcd_clock #(
    parameter int CLK_HZ = 21477272
) (
    input  logic        clk,
    input  logic        load,
    input  logic [55:0] din,
    output logic [55:0] q
);

function automatic logic [7:0] bcd_inc(input logic [7:0] v);
    return (v[3:0] == 4'd9) ? {v[7:4] + 4'd1, 4'd0} : {v[7:4], v[3:0] + 4'd1};
endfunction

// last day of the month (BCD month and year)
function automatic logic [7:0] month_end(input logic [7:0] m, input logic [7:0] y);
    logic leap;
    // a BCD year is a multiple of 4 when (tens even and units 0/4/8) or (tens odd and units 2/6)
    leap = y[4] ? (y[3:0] == 4'd2 || y[3:0] == 4'd6) : (y[3:0] == 4'd0 || y[3:0] == 4'd4 || y[3:0] == 4'd8);
    case (m)
    8'h02:                      return leap ? 8'h29 : 8'h28;
    8'h04, 8'h06, 8'h09, 8'h11: return 8'h30;
    default:                    return 8'h31;
    endcase
endfunction

logic [$clog2(CLK_HZ)-1:0] div;

always_ff @(posedge clk) begin
    logic [7:0] sec, min, hour, day, mon, year, wday;
    {wday, year, mon, day, hour, min, sec} = q;
    if (load) begin
        q <= din;
        div <= '0;
    end else if (div == CLK_HZ - 1) begin
        div <= '0;
        sec = bcd_inc(sec);
        if (sec == 8'h60) begin
            sec = 8'h00;
            min = bcd_inc(min);
            if (min == 8'h60) begin
                min = 8'h00;
                hour = bcd_inc(hour);
                if (hour == 8'h24) begin
                    hour = 8'h00;
                    wday = (wday == 8'h07) ? 8'h01 : wday + 8'h01;
                    if (day == month_end(mon, year)) begin
                        day = 8'h01;
                        mon = (mon == 8'h09) ? 8'h10 : (mon == 8'h12) ? 8'h01 : bcd_inc(mon);
                        if (mon == 8'h01) year = (year == 8'h99) ? 8'h00 : bcd_inc(year);
                    end else
                        day = bcd_inc(day);
                end
            end
        end
        q <= {wday, year, mon, day, hour, min, sec};
    end else
        div <= div + 1'd1;
end

endmodule
