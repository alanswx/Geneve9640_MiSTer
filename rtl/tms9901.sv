//============================================================================
//  TMS9901 Programmable System Interface
//
//  Behaviour as in MAME's tms9901.cpp (Raphael Nabet, Michael Zapf): 15
//  interrupt inputs with mask and priority, the 14-bit clock (decremented
//  every 64 phi cycles), 16 I/O pins (P0-P15; P7-P15 share pins with INT15-
//  INT7). As in MAME on the Geneve, INTREQ/IC follow the interrupt state only
//  on the falling phi edge (MAME check_int).
//============================================================================

module tms9901 (
    input  logic        clk,
    input  logic        reset,         // RST1*

    input  logic        phi_rise,      // rising phi (CPU CLKOUT)
    input  logic        phi_fall,      // falling phi
    input  logic        s0_update,     // address bit S0 seen on the bus (MAME update_clock)

    input  logic        cru_wr,
    input  logic [4:0]  cru_bit,
    input  logic        cru_wdata,
    input  logic [4:0]  rd_bit,        // combinational CRU read
    output logic        rd_data,

    input  logic [15:1] int_line,      // INTn* asserted (pushed interrupt lines)
    input  logic [31:1] pin_in,        // pin levels as read through the CRU (1 = high)

    output logic [15:0] p_out,         // latched P0-P15 output values
    output logic [15:0] p_dir,         // 1 = output
    output logic        intreq,        // INTREQ* asserted (to the CPU INT1)
    output logic [3:0]  ic             // interrupt code
);

logic        clock_mode;
logic [13:0] clock_register, decrementer_value, clock_read_register;
logic [15:0] int_mask;
logic        timer_int_pending;
logic [5:0]  clockdiv;
logic        int_pending;
logic [3:0]  int_level;

// The timer reaching 0 on this phi edge (seen by the falling edge in the same clk)
wire timer_fire = phi_rise && clockdiv == 6'd63 && decrementer_value == 14'd1 && clock_register != 14'd0;

// Interrupt prioritisation (combinational, MAME prioritize_interrupts)
logic        found;
logic [3:0]  level;
always_comb begin
    logic [15:0] masked;
    masked = {int_line, 1'b0};
    if (clock_register != 14'd0) begin
        masked[3] = timer_int_pending || timer_fire;
    end
    masked = masked & int_mask;
    found = 1'b0;
    level = 4'd15;
    for (int n = 1; n <= 15; n++) begin
        if (!found && masked[n] && ((n < 7) || !p_dir[22 - n])) begin
            found = 1'b1;
            level = 4'(n);
        end
    end
end

// CRU read
always_comb begin
    rd_data = 1'b0;
    if (rd_bit == 5'd0)
        rd_data = clock_mode;
    else if (rd_bit > 5'd15) begin
        if (p_dir[rd_bit - 5'd16]) rd_data = p_out[rd_bit - 5'd16];
        else rd_data = (rd_bit <= 5'd22) ? pin_in[rd_bit] : pin_in[5'd38 - rd_bit];
    end else if (clock_mode) begin
        if (rd_bit == 5'd15) rd_data = !found;
        else rd_data = clock_read_register[rd_bit - 5'd1];
    end else begin
        if (rd_bit > 5'd6 && p_dir[5'd22 - rd_bit]) rd_data = p_out[5'd22 - rd_bit];
        else rd_data = pin_in[rd_bit];
    end
end

always_ff @(posedge clk) begin
    if (reset) begin
        timer_int_pending <= 1'b0;
        p_dir <= 16'd0;
        p_out <= 16'd0;
        int_mask <= 16'd0;
        clock_mode <= 1'b0;
        decrementer_value <= 14'd0;
        clock_register <= 14'd0;
        clock_read_register <= 14'd0;
        clockdiv <= 6'd0;
        int_pending <= 1'b0;
        int_level <= 4'd15;
        intreq <= 1'b0;
        ic <= 4'd15;
    end else begin
        if (cru_wr) begin
            if (cru_bit >= 5'd16) begin
                p_dir[cru_bit - 5'd16] <= 1'b1;
                p_out[cru_bit - 5'd16] <= cru_wdata;
            end else if (cru_bit == 5'd0)
                clock_mode <= cru_wdata;
            else if (cru_bit == 5'd15) begin
                if (clock_mode) begin
                    if (!cru_wdata) begin      // soft reset
                        p_dir <= 16'd0;
                        p_out <= 16'd0;
                        int_mask <= 16'd0;
                    end
                end else
                    int_mask[15] <= cru_wdata;
            end else begin
                if (clock_mode) begin
                    clock_register[cru_bit - 5'd1] <= cru_wdata;
                    decrementer_value <= (clock_register & ~(14'd1 << (cru_bit - 5'd1)))
                                       | (14'(cru_wdata) << (cru_bit - 5'd1));
                end else begin
                    int_mask[cru_bit] <= cru_wdata;
                    if (cru_bit == 5'd3) timer_int_pending <= 1'b0;
                end
            end
        end

        if (s0_update) clock_read_register <= decrementer_value;

        if (phi_rise) begin
            clockdiv <= clockdiv + 6'd1;
            if (clockdiv == 6'd63) begin
                // timer_clock_in(ASSERT)
                if (decrementer_value == 14'd1) begin
                    if (clock_register != 14'd0) timer_int_pending <= 1'b1;
                    decrementer_value <= clock_register;
                    if (!clock_mode) clock_read_register <= clock_register;
                end else begin
                    decrementer_value <= decrementer_value - 14'd1;
                    if (!clock_mode) clock_read_register <= decrementer_value - 14'd1;
                end
            end
        end

        if (phi_fall) begin
            // check_int: the interrupt outputs follow the prioritised state
            int_pending <= found;
            int_level <= level;
            intreq <= found;
            ic <= level;
        end
    end
end

endmodule
