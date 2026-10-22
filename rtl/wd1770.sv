//============================================================================
//  WD1770 floppy disk controller, sector level
//
//  Works on sector-dump images (V9T9 .dsk: 256-byte sectors, side 0 tracks
//  0..n-1 followed by side 1 tracks n-1..0). The controller keeps a head
//  position per drive and answers type I-IV commands; sector data goes
//  through a 256-byte buffer filled or drained by the image interface:
//
//    img_rd / img_wr  one-clk request for logical sector img_lsn of drive
//                     img_drive; the outside fills the buffer (buf_wr) or
//                     reads it (buf_addr / buf_dout), then pulses img_ack.
//
//  Single density (dden_n = 1) finds sectors only on 9-sector images,
//  double density only on 16/18-sector images, as on the real medium.
//  Head stepping and the sector search take a short fixed time; data bytes
//  are offered at once (DRQ) and never get lost.
//============================================================================

module wd1770 #(
    parameter int CLK_HZ  = 21477272,
    parameter int STEP_US = 200,       // per head step (real drives: 6-20 ms)
    parameter int FIND_US = 300        // to find a sector ID
) (
    input  logic        clk,
    input  logic        reset,

    input  logic        rd,             // read strobe (register addr)
    input  logic        wr,
    input  logic [1:0]  addr,           // 0 status/command, 1 track, 2 sector, 3 data
    input  logic [7:0]  din,
    output logic [7:0]  dout,
    output logic        intrq,
    output logic        drq,

    input  logic [1:0]  drive,          // 1, 2 = selected drive, 0 = none
    input  logic        side,
    input  logic        dden_n,         // 1 = single density (FM)
    input  logic [1:0]  ready,          // image present per drive
    input  logic [1:0]  wprot,          // write protected per drive
    input  logic [1:0][7:0] spt,        // sectors per track
    input  logic [1:0][7:0] tracks,     // tracks per side in the image
    input  logic [1:0][1:0] sides,      // sides in the image

    output logic        img_rd,
    output logic        img_wr,
    output logic [15:0] img_lsn,
    output logic        img_drive,      // 0 = DSK1, 1 = DSK2
    input  logic        img_ack,
    input  logic        buf_wr,
    input  logic [7:0]  buf_addr,
    input  logic [7:0]  buf_din,
    output logic [7:0]  buf_dout
);

localparam int US = CLK_HZ / 1000000;

typedef enum logic [3:0] {
    S_IDLE, S_STEP, S_FIND, S_RDIMG, S_RDDATA, S_WRDATA, S_WRIMG, S_RDADDR, S_WRTRK, S_RDTRK, S_DONE
} state_t;

state_t      st;
logic [7:0]  status, track_r, sector_r, data_r, cmd;
logic [7:0]  headpos [0:1];
logic        dirn;               // 1 = step in
logic [7:0]  sbuf [0:255];
logic [8:0]  bcnt;
logic [31:0] timer;
logic        motor_on;
logic [31:0] motor_timer;
logic        type1;
logic [31:0] index_ctr;
logic [7:0]  ida [0:5];
logic [7:0]  rdaddr_sec;
logic [12:0] trkcnt;
logic        stepped;

wire        dsel   = drive != 2'd0;
wire        dn     = (drive == 2'd2);
wire [7:0]  hp     = headpos[dn];
wire [7:0]  d_spt  = spt[dn];
wire        dens_ok = dden_n ? (d_spt == 8'd9) : (d_spt >= 8'd16);
wire        disk   = dsel && ready[dn];
wire        index  = disk && motor_on && (index_ctr < 32'(CLK_HZ / 250));   // 4 ms of 200 ms

assign buf_dout = sbuf[buf_addr];
assign img_drive = dn;

always_comb begin
    case (addr)
    2'd0: dout = type1 ? {motor_on, (disk && wprot[dn]), 1'b1, status[4:3], (hp == 8'd0), index, status[0]}
                       : {motor_on, status[6:0]};
    2'd1: dout = track_r;
    2'd2: dout = sector_r;
    default: dout = data_r;
    endcase
end

function automatic logic [15:0] lsn_of(input logic [7:0] cyl, input logic s, input logic [7:0] sec,
                                       input logic [7:0] spt_d, input logic [7:0] trk_d);
    if (!s) return 16'(cyl * spt_d + sec);
    else    return 16'((2 * trk_d - 1 - cyl) * spt_d + sec);
endfunction

// Sector present on the medium under the head?
function automatic logic sector_ok(input logic [7:0] sec);
    return disk && dens_ok && (track_r == hp) && (hp < tracks[dn]) && (sec < d_spt)
        && (!side || sides[dn] == 2'd2);
endfunction

`ifdef WD_DEBUG
always_ff @(posedge clk) begin
    if (wr && addr == 2'd0) $display("WD cmd %02x drive %0d side %0d dden_n %0d trk %0d sec %0d hp %0d ready %b spt %0d", din, drive, side, dden_n, track_r, sector_r, hp, ready, d_spt);
    if (st == S_DONE) $display("WD done status %02x", status);
end
`endif

always_ff @(posedge clk) begin
    img_rd <= 1'b0;
    img_wr <= 1'b0;

    if (reset) begin
        st <= S_IDLE;
        status <= 8'd0;
        track_r <= 8'd0;
        sector_r <= 8'd1;
        data_r <= 8'd0;
        intrq <= 1'b0;
        drq <= 1'b0;
        type1 <= 1'b1;
        motor_on <= 1'b0;
        headpos[0] <= 8'd0;
        headpos[1] <= 8'd0;
        dirn <= 1'b1;
        rdaddr_sec <= 8'd0;
        index_ctr <= 32'd0;
        stepped <= 1'b0;
        motor_timer <= 32'd0;
        timer <= 32'd0;
    end else begin
        index_ctr <= (index_ctr >= 32'(CLK_HZ / 5 - 1)) ? 32'd0 : index_ctr + 32'd1;
        if (motor_timer != 32'd0) motor_timer <= motor_timer - 32'd1;
        else if (st == S_IDLE) motor_on <= 1'b0;

        if (buf_wr) sbuf[buf_addr] <= buf_din;

        // Register access
        if (rd && addr == 2'd0) intrq <= 1'b0;
        if (rd && addr == 2'd3) drq <= 1'b0;
        if (wr) begin
            case (addr)
            2'd0: begin
                if (din[7:4] == 4'hd) begin
                    // Force interrupt
                    st <= S_IDLE;
                    status[0] <= 1'b0;
                    drq <= 1'b0;
                    if (st == S_IDLE) type1 <= 1'b1;
                    intrq <= (din[3:0] != 4'd0);
                end else if (st == S_IDLE) begin
                    cmd <= din;
                    intrq <= 1'b0;
                    status <= 8'h01;           // busy
                    motor_on <= 1'b1;
                    motor_timer <= 32'(CLK_HZ * 2);
                    timer <= 32'd0;
                    if (!din[7]) begin
                        type1 <= 1'b1;
                        st <= S_STEP;
                    end else begin
                        type1 <= 1'b0;
                        case (din[7:5])
                        3'b100: st <= S_FIND;                         // read sector
                        3'b101: st <= S_FIND;                         // write sector
                        default: case (din[7:4])
                            4'hc: st <= S_RDADDR;
                            4'he: st <= S_RDTRK;
                            default: st <= S_WRTRK;                   // f
                        endcase
                        endcase
                    end
                end
            end
            2'd1: if (st == S_IDLE) track_r <= din;
            2'd2: if (st == S_IDLE) sector_r <= din;
            default: begin
                data_r <= din;
                drq <= 1'b0;
            end
            endcase
        end

        case (st)
        // Type I: restore, seek, step, step in, step out
        S_STEP: begin
            if (timer != 32'd0) timer <= timer - 32'd1;
            else if (stepped || (cmd[7:5] == 3'b000 && (cmd[4] ? (track_r == data_r) : (hp == 8'd0)))) begin
                if (cmd[7:4] == 4'h0) track_r <= 8'd0;          // restore ends on track 0
                if (cmd[2] && !(disk && dens_ok && ((cmd[7:4] == 4'h0) ? hp == 8'd0 : track_r == hp)))
                    status[4] <= 1'b1;                           // verify: seek error
                stepped <= 1'b0;
                st <= S_DONE;
            end else begin
                logic d;
                if (cmd[7:5] == 3'b000) d = cmd[4] ? (data_r > track_r) : 1'b0;
                else if (cmd[7:5] == 3'b010) d = 1'b1;
                else if (cmd[7:5] == 3'b011) d = 1'b0;
                else d = dirn;
                dirn <= d;
                // seek always updates the track register, step only with u = 1
                if ((cmd[7:4] == 4'h1) || (cmd[7:5] != 3'b000 && cmd[4]))
                    track_r <= d ? track_r + 8'd1 : track_r - 8'd1;
                if (dsel) headpos[dn] <= d ? (hp < 8'd83 ? hp + 8'd1 : hp) : (hp != 8'd0 ? hp - 8'd1 : 8'd0);
                if (cmd[7:5] != 3'b000) stepped <= 1'b1;
                timer <= 32'(STEP_US * US);
            end
        end

        // Type II: find the sector
        S_FIND: begin
            if (timer != 32'(FIND_US * US)) timer <= timer + 32'd1;
            else if (!sector_ok(sector_r)) begin
                status[4] <= 1'b1;              // record not found
                st <= S_DONE;
            end else if (cmd[5]) begin
                if (wprot[dn]) begin
                    status[6] <= 1'b1;
                    st <= S_DONE;
                end else begin
                    bcnt <= 9'd0;
                    drq <= 1'b1;
                    status[1] <= 1'b1;
                    st <= S_WRDATA;
                end
            end else begin
                img_rd <= 1'b1;
                img_lsn <= lsn_of(hp, side, sector_r, d_spt, tracks[dn]);
                st <= S_RDIMG;
            end
        end
        S_RDIMG: if (img_ack) begin
            bcnt <= 9'd0;
            st <= S_RDDATA;
        end
        S_RDDATA: begin
            if (!drq && !(wr || rd)) begin
                if (bcnt == 9'd256) begin
                    status[1] <= 1'b0;
                    if (cmd[4] && sector_ok(sector_r + 8'd1)) begin
                        sector_r <= sector_r + 8'd1;
                        timer <= 32'd0;
                        st <= S_FIND;
                    end else begin
                        if (cmd[4]) status[4] <= 1'b1;
                        st <= S_DONE;
                    end
                end else begin
                    data_r <= sbuf[bcnt[7:0]];
                    bcnt <= bcnt + 9'd1;
                    drq <= 1'b1;
                    status[1] <= 1'b1;
                end
            end
        end
        S_WRDATA: begin
            if (!drq && !(wr || rd)) begin
                sbuf[bcnt[7:0]] <= data_r;
                if (bcnt == 9'd255) begin
                    status[1] <= 1'b0;
                    img_wr <= 1'b1;
                    img_lsn <= lsn_of(hp, side, sector_r, d_spt, tracks[dn]);
                    st <= S_WRIMG;
                end else begin
                    bcnt <= bcnt + 9'd1;
                    drq <= 1'b1;
                end
            end
        end
        S_WRIMG: if (img_ack) begin
            if (cmd[4] && sector_ok(sector_r + 8'd1)) begin
                sector_r <= sector_r + 8'd1;
                timer <= 32'd0;
                st <= S_FIND;
            end else begin
                if (cmd[4]) status[4] <= 1'b1;
                st <= S_DONE;
            end
        end

        // Type III
        S_RDADDR: begin
            if (timer != 32'(FIND_US * US)) timer <= timer + 32'd1;
            else if (!(disk && dens_ok && hp < tracks[dn])) begin
                status[4] <= 1'b1;
                st <= S_DONE;
            end else if (bcnt == 9'd0 && !drq) begin
                ida[0] <= hp;
                ida[1] <= {7'd0, side};
                ida[2] <= rdaddr_sec;
                ida[3] <= 8'd1;
                ida[4] <= 8'h00;
                ida[5] <= 8'h00;
                rdaddr_sec <= (rdaddr_sec + 8'd1 >= d_spt) ? 8'd0 : rdaddr_sec + 8'd1;
                bcnt <= 9'd1;
                timer <= 32'(FIND_US * US);
            end else if (!drq && !(wr || rd)) begin
                if (bcnt == 9'd7) begin
                    sector_r <= ida[0];
                    status[1] <= 1'b0;
                    st <= S_DONE;
                end else begin
                    data_r <= ida[bcnt[2:0] - 3'd1];
                    bcnt <= bcnt + 9'd1;
                    drq <= 1'b1;
                    status[1] <= 1'b1;
                end
            end
        end
        S_RDTRK: begin
            // not supported by the image: deliver one empty byte and finish
            status[4] <= 1'b1;
            st <= S_DONE;
        end
        S_WRTRK: begin
            // format: take the track bytes, keep the image as it is
            if (!disk || wprot[dn]) begin
                if (disk) status[6] <= 1'b1;
                st <= S_DONE;
            end else if (timer == 32'd0) begin
                trkcnt <= 13'd0;
                drq <= 1'b1;
                status[1] <= 1'b1;
                timer <= 32'd1;
            end else if (!drq && !(wr || rd)) begin
                if (trkcnt == (dden_n ? 13'd3125 : 13'd6250)) begin
                    status[1] <= 1'b0;
                    st <= S_DONE;
                end else begin
                    trkcnt <= trkcnt + 13'd1;
                    drq <= 1'b1;
                end
            end
        end

        S_DONE: begin
            status[0] <= 1'b0;
            drq <= 1'b0;
            intrq <= 1'b1;
            motor_timer <= 32'(CLK_HZ * 2);
            st <= S_IDLE;
        end
        default: ;
        endcase
    end
end

endmodule
