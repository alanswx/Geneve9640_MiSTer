//============================================================================
//  Floppy images for the WD1770 (wd1770.sv) over the MiSTer sd_* interface
//
//  Two image slots (DSK1, DSK2), V9T9 sector dumps. TI sectors are 256 bytes,
//  SD blocks 512: a sector read loads its block and copies the half into the
//  controller's buffer; a sector write loads the block, replaces the half and
//  writes the block back. On mount, block 0 gives the geometry from the volume
//  information block (sectors/track at 0Ch, tracks at 11h, sides at 12h), with
//  the image size as the fallback.
//============================================================================

module geneve_disk (
    input  logic        clk,
    input  logic        reset,

    // hps_io (VDNUM = 2)
    input  logic [1:0]  img_mounted,
    input  logic        img_readonly,
    input  logic [63:0] img_size,
    output logic [31:0] sd_lba [2],
    output logic [1:0]  sd_rd,
    output logic [1:0]  sd_wr,
    input  logic [1:0]  sd_ack,
    input  logic [8:0]  sd_buff_addr,
    input  logic [7:0]  sd_buff_dout,
    output logic [7:0]  sd_buff_din [2],
    input  logic        sd_buff_wr,

    // to the core (wd1770 image side)
    output logic [1:0]       ready,
    output logic [1:0]       wprot,
    output logic [1:0][7:0]  spt,
    output logic [1:0][7:0]  tracks,
    output logic [1:0][1:0]  sides,
    input  logic        img_rd,
    input  logic        img_wr,
    input  logic [15:0] img_lsn,
    input  logic        img_drive,
    output logic        img_ack,
    output logic        buf_wr,
    output logic [7:0]  buf_addr,
    output logic [7:0]  buf_din,
    input  logic [7:0]  buf_dout,

    output logic        busy
);

logic [7:0] blk [0:511];
logic [7:0] blk_q;

typedef enum logic [3:0] {
    D_IDLE, D_RDREQ, D_RDWAIT, D_COPYOUT, D_COPYIN, D_WRREQ, D_WRWAIT, D_ACK, D_VIB
} dstate_t;

dstate_t     st;
logic        drv, is_write, mounting;
logic [15:0] lsn;
logic [8:0]  cnt;
logic        ack_seen;
logic [31:0] size [2];
logic [7:0]  vib [0:19];
logic [1:0]  mount_pend;           // a mount waiting for its geometry read

assign busy = (st != D_IDLE);
assign sd_buff_din[0] = blk_q;
assign sd_buff_din[1] = blk_q;

// block buffer: written by the SD side, read for the SD side and the copies
always_ff @(posedge clk) begin
    if (sd_buff_wr && (sd_ack != 2'b00)) blk[sd_buff_addr] <= sd_buff_dout;
    if (st == D_COPYIN && cnt[8] == 1'b0) blk[{lsn[0], cnt[7:0]}] <= buf_dout;
    blk_q <= blk[(st == D_WRWAIT || st == D_WRREQ) ? sd_buff_addr : {(st == D_VIB) ? 1'b0 : lsn[0], cnt[7:0]}];
end

always_ff @(posedge clk) begin
    img_ack <= 1'b0;
    buf_wr <= 1'b0;
    if (reset) begin
        st <= D_IDLE;
        sd_rd <= 2'b00;
        sd_wr <= 2'b00;
        ready <= 2'b00;
        mounting <= 1'b0;
        mount_pend <= 2'b00;
    end else begin
        // a new image: note the size, then read its first block for the geometry
        for (int d = 0; d < 2; d++)
            if (img_mounted[d]) begin
                ready[d] <= 1'b0;
                size[d] <= img_size[31:0];
                wprot[d] <= img_readonly;
                mount_pend[d] <= (img_size != 64'd0);
            end

        case (st)
        D_IDLE: begin
            if (mount_pend[0] && !img_mounted[0]) begin
                mount_pend[0] <= 1'b0;
                drv <= 1'b0; lsn <= 16'd0; mounting <= 1'b1; st <= D_RDREQ;
            end else if (mount_pend[1] && !img_mounted[1]) begin
                mount_pend[1] <= 1'b0;
                drv <= 1'b1; lsn <= 16'd0; mounting <= 1'b1; st <= D_RDREQ;
            end else if (img_rd || img_wr) begin
                drv <= img_drive;
                lsn <= img_lsn;
                is_write <= img_wr;
                mounting <= 1'b0;
                st <= D_RDREQ;
            end
        end
        D_RDREQ: begin
            sd_lba[drv] <= {17'd0, lsn[15:1]};
            sd_rd[drv] <= 1'b1;
            ack_seen <= 1'b0;
            st <= D_RDWAIT;
        end
        D_RDWAIT: begin
            if (sd_ack[drv]) begin
                sd_rd[drv] <= 1'b0;
                ack_seen <= 1'b1;
            end else if (ack_seen) begin
                cnt <= 9'd0;
                buf_addr <= 8'd0;
                st <= mounting ? D_VIB : (is_write ? D_COPYIN : D_COPYOUT);
            end
        end
        // block half -> controller buffer (blk_q follows cnt one clk later)
        D_COPYOUT: begin
            cnt <= cnt + 9'd1;
            if (cnt != 9'd0) begin
                buf_wr <= 1'b1;
                buf_addr <= cnt[7:0] - 8'd1;
                buf_din <= blk_q;
            end
            if (cnt == 9'd256) st <= D_ACK;
        end
        // controller buffer -> block half
        D_COPYIN: begin
            buf_addr <= cnt[7:0] + 8'd1;
            cnt <= cnt + 9'd1;
            if (cnt == 9'd255) st <= D_WRREQ;
        end
        D_WRREQ: begin
            sd_wr[drv] <= 1'b1;
            ack_seen <= 1'b0;
            st <= D_WRWAIT;
        end
        D_WRWAIT: begin
            if (sd_ack[drv]) begin
                sd_wr[drv] <= 1'b0;
                ack_seen <= 1'b1;
            end else if (ack_seen)
                st <= D_ACK;
        end
        D_ACK: begin
            img_ack <= 1'b1;
            st <= D_IDLE;
        end
        // geometry from the VIB (bytes 0..19 of block 0)
        D_VIB: begin
            cnt <= cnt + 9'd1;
            if (cnt != 9'd0) vib[cnt[4:0] - 5'd1] <= blk_q;
            if (cnt == 9'd21) begin
                logic [15:0] total;
                logic [7:0]  s, t;
                logic [1:0]  sd;
                total = {vib[10], vib[11]};
                s = vib[12];
                t = vib[17];
                sd = vib[18][1:0];
                if (!(s != 0 && t != 0 && sd != 0 && 32'(total) == 32'(s) * 32'(t) * 32'(sd))) begin
                    // by size
                    case (size[drv])
                    32'd92160:   begin s = 8'd9;  t = 8'd40; sd = 2'd1; end
                    32'd184320:  begin s = 8'd9;  t = 8'd40; sd = 2'd2; end
                    32'd737280:  begin s = 8'd18; t = 8'd80; sd = 2'd2; end
                    default:     begin s = 8'd18; t = 8'd40; sd = 2'd2; end
                    endcase
                end
                spt[drv] <= s;
                tracks[drv] <= t;
                sides[drv] <= sd;
                ready[drv] <= 1'b1;
                mounting <= 1'b0;
                st <= D_IDLE;
            end
        end
        default: st <= D_IDLE;
        endcase
    end
end

endmodule
