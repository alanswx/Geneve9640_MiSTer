//============================================================================
//  MiSTer ps2_key (set 2) to XT keyboard scancodes (set 1)
//
//  Each key event becomes its set 1 make code (break: | 80h); the extended
//  keys of the 101-key layout get an E0 prefix, as the Geneve's XT keyboard
//  (MAME genkbd.cpp) sends them. One code per strobe, at least 2 clks apart.
//============================================================================

module ps2_xt (
    input  logic        clk,
    input  logic        reset,
    input  logic [10:0] ps2_key,     // [7:0] code, [8] extended, [9] pressed, [10] toggles per event
    output logic        strobe,
    output logic [7:0]  code
);

`include "ps2_xt_table.svh"

logic       old_toggle;
logic       pend_code;
logic [7:0] pend;

always_ff @(posedge clk) begin
    logic [7:0] x;
    strobe <= 1'b0;
    if (reset) begin
        old_toggle <= ps2_key[10];
        pend_code <= 1'b0;
    end else if (pend_code) begin
        strobe <= 1'b1;
        code <= pend;
        pend_code <= 1'b0;
    end else if (ps2_key[10] != old_toggle) begin
        old_toggle <= ps2_key[10];
        x = ps2_to_xt(ps2_key[8], ps2_key[7:0]);
        if (x != 8'h00) begin
            x = ps2_key[9] ? x : (x | 8'h80);
            if (ps2_key[8]) begin
                strobe <= 1'b1;
                code <= 8'he0;
                pend <= x;
                pend_code <= 1'b1;
            end else begin
                strobe <= 1'b1;
                code <= x;
            end
        end
    end
end

endmodule
