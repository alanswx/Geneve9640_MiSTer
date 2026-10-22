//============================================================================
//  ATA hard disk (PIO, LBA) on a MiSTer sd_* block device
//
//  One master drive; the slave and an empty slot read as no device (status 0).
//  The image is a plain sector dump (512-byte sectors, LBA n at offset n*512).
//  Data words are little-endian in the image, as MAME's ata_hle: word k of a
//  sector = bytes 2k (D7-D0) and 2k+1 (D15-D8).
//
//  Commands: READ SECTOR(S) 20/21, WRITE SECTOR(S) 30/31, READ BUFFER E4,
//  WRITE BUFFER E8, IDENTIFY DEVICE EC, EXECUTE DIAGNOSTIC 90; recalibrate,
//  seek, set parameters, set features, power and set multiple commands complete
//  without doing anything; others abort. That covers Fred Kaal's IDE DSR.
//
//  Host side: rdata is the register addressed by (a_cs1, a_reg), valid at any
//  time; rd/wr strobe an access to (s_cs1, s_reg). cs1 = 0 is the command block
//  (CS1Fx), 1 the control block (CS3Fx: 6 = alternate status / device control,
//  7 = drive address).
//============================================================================

module ata_disk (
    input  logic        clk,
    input  logic        reset,

    input  logic        a_cs1,
    input  logic [2:0]  a_reg,
    output logic [15:0] rdata,
    input  logic        rd,
    input  logic        wr,
    input  logic        s_cs1,
    input  logic [2:0]  s_reg,
    input  logic [15:0] wdata,
    output logic        intrq,

    // image (one hps_io drive)
    input  logic        img_mounted,
    input  logic        img_readonly,
    input  logic [63:0] img_size,
    output logic [31:0] sd_lba,
    output logic        sd_rd,
    output logic        sd_wr,
    input  logic        sd_ack,
    input  logic [8:0]  sd_buff_addr,
    input  logic [7:0]  sd_buff_dout,
    output logic [7:0]  sd_buff_din,
    input  logic        sd_buff_wr,

    output logic        busy
);

// sector buffer: even bytes (D7-D0) and odd bytes (D15-D8) of the 256 words
logic [7:0] buf_lo [0:255];
logic [7:0] buf_hi [0:255];
logic [7:0] lo_q, hi_q;
logic       sd_a0;

typedef enum logic [3:0] {
    S_IDLE, S_RDREQ, S_RDWAIT, S_DIN, S_DOUT, S_WRREQ, S_WRWAIT, S_IDENT
} state_t;

state_t      st;
// the mount survives resets (hps_io mounts once, e.g. from an MGL before the OSD reset)
logic        present = 1'b0;
logic        ro = 1'b0;
logic [31:0] total = 32'd0;       // sectors
logic [7:0]  err, seccnt, secnum, cyllo, cylhi, drhd;
logic        bsy, drq, errb, irq, nien, srst;
logic        to_disk;             // S_DOUT ends with a disk write (not WRITE BUFFER)
logic        more;                // S_DIN is followed by the next sector (not READ BUFFER)
logic [7:0]  ptr;
logic [8:0]  icnt;                // IDENTIFY fill
logic [31:0] lba;

wire sel = present && !drhd[4];
wire [7:0] status = sel ? {bsy, !bsy, 1'b0, 1'b1, drq, 2'b00, errb} : 8'h00;

assign busy = (st != S_IDLE);
assign intrq = irq && !nien;
assign sd_buff_din = sd_a0 ? hi_q : lo_q;

// host register reads
always_comb begin
    rdata = 16'h0000;
    if (sel) begin
        if (!a_cs1) begin
            case (a_reg)
            3'd0: rdata = {hi_q, lo_q};
            3'd1: rdata = {8'h00, err};
            3'd2: rdata = {8'h00, seccnt};
            3'd3: rdata = {8'h00, secnum};
            3'd4: rdata = {8'h00, cyllo};
            3'd5: rdata = {8'h00, cylhi};
            3'd6: rdata = {8'h00, drhd};
            3'd7: rdata = {8'h00, status};
            endcase
        end else begin
            if (a_reg == 3'd6) rdata = {8'h00, status};
            if (a_reg == 3'd7) rdata = {8'h00, 2'b10, ~drhd[3:0], drhd[4], !drhd[4]};
        end
    end
end

// IDENTIFY DEVICE data: 16 heads, 63 sectors/track, LBA. The cylinder count
// (total / 1008, at most 16383) is counted out after a mount, not divided.
logic [15:0] chs_cyl;
logic [31:0] chs_cap, chs_rem;
always_ff @(posedge clk) begin
    if (img_mounted) begin
        chs_cyl <= 16'd0;
        chs_cap <= 32'd0;
        chs_rem <= img_size[40:9];
    end else if (chs_rem >= 32'd1008 && chs_cyl != 16'd16383) begin
        chs_rem <= chs_rem - 32'd1008;
        chs_cyl <= chs_cyl + 16'd1;
        chs_cap <= chs_cap + 32'd1008;
    end
end

function automatic [15:0] str2(input [7:0] i);     // "MISTER GENEVE IDE DISK", space padded
    logic [8*40-1:0] s;
    s = {"MISTER GENEVE IDE DISK", {18{8'h20}}};
    str2 = s[8*40-1 - 16*i -: 16];
endfunction

function automatic [15:0] ident(input [7:0] i);
    ident = 16'h0000;
    case (i)
    8'd0:  ident = 16'h0040;
    8'd1:  ident = chs_cyl;
    8'd3:  ident = 16'd16;
    8'd6:  ident = 16'd63;
    8'd20: ident = 16'd3;
    8'd21: ident = 16'd1;
    8'd47: ident = 16'h8001;
    8'd49: ident = 16'h0200;
    8'd51: ident = 16'h0200;
    8'd53: ident = 16'h0001;
    8'd54: ident = chs_cyl;
    8'd55: ident = 16'd16;
    8'd56: ident = 16'd63;
    8'd57: ident = chs_cap[15:0];
    8'd58: ident = chs_cap[31:16];
    8'd60: ident = total[15:0];
    8'd61: ident = total[31:16];
    default:
        if (i >= 8'd10 && i <= 8'd19) ident = 16'h2020;            // serial number
        else if (i >= 8'd23 && i <= 8'd26) ident = 16'h3130;       // firmware "1010..."
        else if (i >= 8'd27 && i <= 8'd46) ident = str2(i - 8'd27);
    endcase
endfunction

// buffer ports: the SD side while a block moves, the host side (ptr) otherwise
always_ff @(posedge clk) begin
    logic [7:0] a;
    logic [15:0] iw;
    iw = ident(icnt[7:0]);
    if (sd_buff_wr && sd_ack) begin
        if (sd_buff_addr[0]) buf_hi[sd_buff_addr[8:1]] <= sd_buff_dout;
        else                 buf_lo[sd_buff_addr[8:1]] <= sd_buff_dout;
    end else if (st == S_IDENT && !icnt[8]) begin
        buf_lo[icnt[7:0]] <= iw[7:0];
        buf_hi[icnt[7:0]] <= iw[15:8];
    end else if (st == S_DOUT && wr && !s_cs1 && s_reg == 3'd0) begin
        buf_lo[ptr] <= wdata[7:0];
        buf_hi[ptr] <= wdata[15:8];
    end
    a = (st == S_WRREQ || st == S_WRWAIT) ? sd_buff_addr[8:1] : ptr;
    sd_a0 <= sd_buff_addr[0];
    lo_q <= buf_lo[a];
    hi_q <= buf_hi[a];
end

always_ff @(posedge clk) begin
    if (reset) begin
        st <= S_IDLE;
        sd_rd <= 1'b0;
        sd_wr <= 1'b0;
    end

    if (img_mounted) begin
        present <= (img_size != 64'd0);
        ro <= img_readonly;
        total <= img_size[40:9];
    end

    if (reset || srst) begin
        bsy <= 1'b0;
        drq <= 1'b0;
        errb <= 1'b0;
        irq <= 1'b0;
        err <= 8'h01;
        seccnt <= 8'h01;
        secnum <= 8'h01;
        cyllo <= 8'h00;
        cylhi <= 8'h00;
        drhd <= 8'h00;
        if (reset) begin
            nien <= 1'b0;
            srst <= 1'b0;
        end
        st <= S_IDLE;
    end else begin
        case (st)
        S_RDREQ: if (sd_ack) begin
            sd_rd <= 1'b0;
            st <= S_RDWAIT;
        end
        S_RDWAIT: if (!sd_ack) begin
            bsy <= 1'b0;
            drq <= 1'b1;
            irq <= 1'b1;
            ptr <= 8'd0;
            st <= S_DIN;
        end
        S_WRREQ: if (sd_ack) begin
            sd_wr <= 1'b0;
            st <= S_WRWAIT;
        end
        S_WRWAIT: if (!sd_ack) begin
            bsy <= 1'b0;
            irq <= 1'b1;
            if (seccnt != 8'd1) begin
                seccnt <= seccnt - 8'd1;
                lba <= lba + 32'd1;
                drq <= 1'b1;
                ptr <= 8'd0;
                st <= S_DOUT;
            end else begin
                seccnt <= 8'd0;
                st <= S_IDLE;
            end
        end
        S_IDENT: begin
            icnt <= icnt + 9'd1;
            if (icnt[8]) begin
                bsy <= 1'b0;
                drq <= 1'b1;
                irq <= 1'b1;
                ptr <= 8'd0;
                more <= 1'b0;
                st <= S_DIN;
            end
        end
        default: ;
        endcase

        // host reads with side effects: data and status
        if (rd && sel && !s_cs1) begin
            if (s_reg == 3'd7) irq <= 1'b0;
            if (s_reg == 3'd0 && st == S_DIN) begin
                ptr <= ptr + 8'd1;
                if (ptr == 8'd255) begin
                    drq <= 1'b0;
                    if (more && seccnt != 8'd1) begin
                        seccnt <= seccnt - 8'd1;
                        lba <= lba + 32'd1;
                        bsy <= 1'b1;
                        sd_lba <= lba + 32'd1;
                        sd_rd <= 1'b1;
                        st <= S_RDREQ;
                    end else begin
                        if (more) seccnt <= 8'd0;
                        st <= S_IDLE;
                    end
                end
            end
        end

        if (wr && !s_cs1 && s_reg == 3'd0 && st == S_DOUT && sel) begin
            ptr <= ptr + 8'd1;
            if (ptr == 8'd255) begin
                drq <= 1'b0;
                if (to_disk) begin
                    bsy <= 1'b1;
                    sd_lba <= lba;
                    sd_wr <= 1'b1;
                    st <= S_WRREQ;
                end else
                    st <= S_IDLE;
            end
        end

        // host register writes
        if (wr && !s_cs1) begin
            case (s_reg)
            3'd2: seccnt <= wdata[7:0];
            3'd3: secnum <= wdata[7:0];
            3'd4: cyllo <= wdata[7:0];
            3'd5: cylhi <= wdata[7:0];
            3'd6: drhd <= wdata[7:0];
            3'd7: if (sel && !bsy) begin
                logic [31:0] l;
                l = {4'd0, drhd[3:0], cylhi, cyllo, secnum};
                irq <= 1'b0;
                errb <= 1'b0;
                err <= 8'h00;
                drq <= 1'b0;
                case (wdata[7:0])
                8'h20, 8'h21: begin
                    if (l >= total) begin
                        errb <= 1'b1;
                        err <= 8'h10;              // IDNF
                        irq <= 1'b1;
                    end else begin
                        lba <= l;
                        more <= 1'b1;
                        bsy <= 1'b1;
                        sd_lba <= l;
                        sd_rd <= 1'b1;
                        st <= S_RDREQ;
                    end
                end
                8'h30, 8'h31: begin
                    if (ro || l >= total) begin
                        errb <= 1'b1;
                        err <= ro ? 8'h04 : 8'h10;
                        irq <= 1'b1;
                    end else begin
                        lba <= l;
                        to_disk <= 1'b1;
                        drq <= 1'b1;
                        ptr <= 8'd0;
                        st <= S_DOUT;
                    end
                end
                8'he4: begin
                    more <= 1'b0;
                    drq <= 1'b1;
                    ptr <= 8'd0;
                    st <= S_DIN;
                end
                8'he8: begin
                    to_disk <= 1'b0;
                    drq <= 1'b1;
                    ptr <= 8'd0;
                    st <= S_DOUT;
                end
                8'hec: begin
                    bsy <= 1'b1;
                    icnt <= 9'd0;
                    st <= S_IDENT;
                end
                8'h90: begin
                    err <= 8'h01;                  // no error
                    irq <= 1'b1;
                end
                8'h91, 8'hc6, 8'hef, 8'h70, 8'he0, 8'he1, 8'he2, 8'he3, 8'he5, 8'he6, 8'he7:
                    irq <= 1'b1;
                default:
                    if (wdata[7:4] == 4'h1)        // recalibrate
                        irq <= 1'b1;
                    else begin
                        errb <= 1'b1;
                        err <= 8'h04;              // ABRT
                        irq <= 1'b1;
                    end
                endcase
            end
            default: ;
            endcase
        end
    end

    // device control register (works during SRST too)
    if (!reset && wr && s_cs1 && s_reg == 3'd6) begin
        nien <= wdata[1];
        srst <= wdata[2];
    end
end

endmodule
