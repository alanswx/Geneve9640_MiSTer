// Headless Geneve 9640 simulation: run the core, write an instruction trace that lines up with MAME's
// debugger trace, capture PNG screenshots, and serve V9T9 floppy images to the DDCC-1.
//
//   ./obj_dir_headless/Vtop --rom genbt100.bin --dsr ddcc1.u3 --dsk1 os650.dsk --frames 300 --screenshot 300
//   ./obj_dir_headless/Vtop ... --trace out/trace.log --trace-to-cycle 200000
//
// Trace lines: "cycles WP ST PC: disassembly", as MAME's trace with {tracelog "%d %04X %04X ",totalcycles,wp,st}.

#include <cstdio>
#include <cstdlib>
#include <cstdint>
#include <cstring>
#include <string>
#include <vector>
#include <set>
#include <sys/stat.h>

#include "Vtop.h"
#include "tms9995_dasm.h"
#include "verilated.h"

#define STB_IMAGE_WRITE_IMPLEMENTATION
#include "stb_image_write.h"

static const double CLK_HZ = 21477272.0;

struct Options {
    std::string rom = "roms/genbt100.bin";
    std::string dsr = "roms/ddcc1.u3";
    std::string rom2;                      // --rom2 FILE: boot EPROM 2.00, run instead of --rom
    std::string ide, ide_sram;             // --ide IMAGE, --ide-sram FILE: IDE card with disk and SRAM
    bool        ide_log = false;
    bool        vram192 = false;               // --vram192: 64 KiB V9938 expansion RAM
    std::string speech;                    // --speech ROM: speech synthesizer with this 32 KiB ROM
    std::string speech_wav;                // --speech-wav FILE: the speech output alone
    std::string dsk[2];
    bool        dsk_readonly = false;
    uint32_t    frames = 60;
    uint64_t    max_cycles = 0;            // stop after this many CPU cycles (0 = by frames)
    std::set<uint32_t> screenshots;
    uint32_t    dump_every = 0;
    std::string out_dir = "out";
    std::string trace_file;
    uint64_t    trace_from = 0, trace_to = UINT64_MAX;
    bool        quiet = false;
    bool        fdc_log = false;
    bool        pixstats = false;
    uint32_t    mount_at = 0;
    std::string wav_file;                  // --wav FILE: sound output, 48 kHz 16-bit mono              // --mount-at FRAME: images appear in the SD slots at FRAME (make sd)
    std::string vdp_log;                   // --vdp-log FILE: CPU writes to VDP ports 1-3
    struct Key { uint32_t frame; std::vector<uint8_t> codes; };
    std::vector<Key> keys;                 // --xt FRAME:HEX,HEX,...
    struct Mouse { uint32_t frame; int dx, dy, btn; };
    std::vector<Mouse> mouse;              // --mouse FRAME:DX,DY,BUTTONS
    struct Joy { uint32_t frame; int bits; };
    std::vector<Joy> joy;                  // --joy FRAME:BITS (joystick 1)
};

static void usage()
{
    fprintf(stderr,
"usage: Vtop [options]\n"
"  --rom FILE             boot EPROM, 16 KiB (default roms/genbt100.bin)\n"
"  --dsr FILE             DDCC-1 DSR, 8 KiB (default roms/ddcc1.u3)\n"
"  --dsk1 FILE / --dsk2 FILE  V9T9 sector images in DSK1 / DSK2; --dsk-readonly: never write them back\n"
"  --rom2 FILE            boot EPROM 2.00 (16 KiB), run instead of --rom\n"
"  --ide IMAGE            IDE card at CRU >1000 with this disk (512-byte sector dump; written back)\n"
"  --ide-sram FILE        IDE card SRAM contents (Kaal's IDE DSR, tools/mkidesram.py); --ide-log\n"
"  --vram192              192 KiB video RAM (V9938 expansion RAM)\n"
"  --speech ROM           speech synthesizer with this 32 KiB ROM (cd2325a.vsm + cd2326a.vsm)\n"
"  --speech-wav FILE      WAV of the speech synthesizer output alone\n"
"  --frames N             stop after N video frames (default 60)\n"
"  --cycles N             stop after N CPU cycles\n"
"  --screenshot N         PNG of frame N (repeatable); --dump-every K: every Kth frame\n"
"  --out DIR              output directory (default out)\n"
"  --trace FILE           instruction trace: cycles WP ST PC: IR\n"
"  --trace-from C / --trace-to C   CPU cycle window for the trace\n"
"  --xt FRAME:HEX[,HEX..] XT scancodes into the keyboard at FRAME\n"
"  --type FRAME:TEXT      type TEXT (US layout, \\n = Enter) from FRAME\n"
"  --mouse FRAME:DX,DY,B  bus mouse: move by DX,DY (right/down, -127..127) at FRAME; B = buttons\n"
"                         (4 left, 2 middle, 1 right), held until the next --mouse\n"
"  --joy FRAME:BITS       joystick 1 from FRAME: 16 up, 8 down, 4 right, 2 left, 1 fire\n"
"  --quiet\n");
}

static void mkdir_p(const std::string &path)
{
    for (size_t i = 1; i <= path.size(); i++)
        if (i == path.size() || path[i] == '/') mkdir(path.substr(0, i).c_str(), 0777);
}

static bool load_file(const std::string &name, std::vector<uint8_t> &data)
{
    FILE *f = fopen(name.c_str(), "rb");
    if (!f) return false;
    fseek(f, 0, SEEK_END);
    long n = ftell(f);
    fseek(f, 0, SEEK_SET);
    data.resize(n);
    size_t got = fread(data.data(), 1, n, f);
    fclose(f);
    return got == (size_t)n;
}


// ASCII -> XT set 1 make codes (US layout); bit 8 = needs shift
static int xt_code(char c)
{
    static const char *row1 = "1234567890-=";
    static const char *row1s = "!@#$%^&*()_+";
    static const char *q = "qwertyuiop[]", *a = "asdfghjkl;'", *z = "zxcvbnm,./";
    static const char *qs = "QWERTYUIOP{}", *as = "ASDFGHJKL:\"", *zs = "ZXCVBNM<>?";
    const char *p;
    if (c == '\n') return 0x1c;
    if (c == ' ') return 0x39;
    if (c == '\\') return 0x2b;
    if (c == '|') return 0x12b;
    if ((p = strchr(row1, c))) return 0x02 + (p - row1);
    if ((p = strchr(row1s, c))) return 0x102 + (p - row1s);
    if ((p = strchr(q, c))) return 0x10 + (p - q);
    if ((p = strchr(qs, c))) return 0x110 + (p - qs);
    if ((p = strchr(a, c))) return 0x1e + (p - a);
    if ((p = strchr(as, c))) return 0x11e + (p - as);
    if ((p = strchr(z, c))) return 0x2c + (p - z);
    if ((p = strchr(zs, c))) return 0x12c + (p - zs);
    return -1;
}

static std::vector<uint8_t> xt_type(const std::string &text)
{
    std::vector<uint8_t> v;
    for (size_t i = 0; i < text.size(); i++) {
        char c = text[i];
        if (c == '\\' && i + 1 < text.size() && text[i + 1] == 'n') { c = '\n'; i++; }
        int k = xt_code(c);
        if (k < 0) continue;
        if (k & 0x100) v.push_back(0x2a);
        v.push_back(k & 0xff);
        v.push_back((k & 0xff) | 0x80);
        if (k & 0x100) v.push_back(0xaa);
    }
    return v;
}

struct Disk {
    std::string name;
    std::vector<uint8_t> data;
    bool present = false, dirty = false;
    int spt = 0, tracks = 0, sides = 0;

    bool open(const std::string &fn) {
        name = fn;
        if (!load_file(fn, data)) return false;
        present = true;
        // geometry from the volume information block (sector 0)
        if (data.size() >= 256) {
            int total = (data[0x0a] << 8) | data[0x0b];
            spt = data[0x0c];
            tracks = data[0x11];
            sides = data[0x12];
            if (spt && tracks && sides && total == spt * tracks * sides && (size_t)total * 256 <= data.size())
                return true;
        }
        // from the size
        size_t s = data.size();
        if (s == 92160)        { spt = 9;  tracks = 40; sides = 1; }
        else if (s == 184320)  { spt = 9;  tracks = 40; sides = 2; }
        else if (s == 368640)  { spt = 18; tracks = 40; sides = 2; }
        else if (s == 737280)  { spt = 18; tracks = 80; sides = 2; }
        else if (s == 1474560) { spt = 36; tracks = 80; sides = 2; }
        else { spt = 18; tracks = (int)(s / (256 * 18 * 2)); sides = 2; }
        return true;
    }
};

class Sim {
public:
    explicit Sim(const Options &o) : opt(o) { top = new Vtop; }
    ~Sim() { top->final(); delete top; }
    int run();

private:
    const Options &opt;
    Vtop *top;
    Disk disk[2];
    uint64_t clocks = 0;
    uint32_t frame = 0;

    // video capture
    static constexpr int VW = 1400, VH = 320;
    std::vector<uint8_t> fb = std::vector<uint8_t>(VW * VH * 3);
    int px = 0, line = 0, maxpx = 0;
    unsigned long long lit = 0;
    bool prev_hs = true, prev_vs = true;

    // floppy transfer
    int fdc_state = 0, fdc_pos = 0, fdc_drv = 0;
    uint32_t fdc_lsn = 0;

    void tick();
    void video();
    void floppy();
    void sdcard();
    void idedisk();
    Disk ide;
    int ide_state = 0, ide_pos = 0;
    bool ide_write = false, ide_mounted = false;
    uint32_t ide_blk = 0;
    int sd_state = 0, sd_drv = 0, sd_pos = 0;
    bool sd_write = false, sd_mount_pending = true;
    unsigned sd_mounted = 0;
    uint32_t sd_blk = 0;
    void save_png(const std::string &fn);
};

void Sim::tick()
{
    top->clk = 0;
    top->eval();
    top->clk = 1;
    top->eval();
    clocks++;
}

void Sim::save_png(const std::string &fn)
{
    // active area: the lines and columns seen in this frame
    int w = maxpx > 0 ? std::min(maxpx, (int)VW) : (int)VW;
    int h = std::min(line, (int)VH);
    if (h <= 0) return;
    stbi_write_png(fn.c_str(), w, h, 3, fb.data(), VW * 3);
}

void Sim::video()
{
    bool hs = top->vga_hs_n, vs = top->vga_vs_n;
    if (prev_hs && !hs) {
        if (px > maxpx) maxpx = px;
        if (px) line++;          // count only lines with a display window
        px = 0;
    }
    if (prev_vs && !vs) {
        if (opt.pixstats) fprintf(stderr, "frame %u: %d lines, %d px/line, %llu lit samples\n", frame, line, maxpx, lit);
        lit = 0;
        frame++;
        if (opt.screenshots.count(frame) || (opt.dump_every && frame % opt.dump_every == 0)) {
            char fn[512];
            snprintf(fn, sizeof fn, "%s/frame_%05u.png", opt.out_dir.c_str(), frame);
            save_png(fn);
            if (!opt.quiet) fprintf(stderr, "wrote %s (%dx%d)\n", fn, maxpx, line);
        }
        line = 0;
        px = 0;
        maxpx = 0;
    }
    prev_hs = hs;
    prev_vs = vs;
    if (top->vga_dhclk && top->vga_de) {
        if (px < VW && line < VH) {
            uint8_t *p = &fb[(line * VW + px) * 3];
            p[0] = (top->vga_r << 2) | (top->vga_r >> 4);
            p[1] = (top->vga_g << 2) | (top->vga_g >> 4);
            p[2] = (top->vga_b << 2) | (top->vga_b >> 4);
        }
        if (top->vga_r | top->vga_g | top->vga_b) lit++;
        px++;
    }
}

// hps_io's SD block protocol (512-byte blocks) for rtl/geneve_disk.sv ('make sd')
void Sim::sdcard()
{
    top->img_mounted = 0;
    top->sd_buff_wr = 0;
    if (sd_mount_pending && frame >= opt.mount_at) {
        for (int d = 0; d < 2; d++)
            if (disk[d].present && !(sd_mounted & (1 << d))) {
                top->img_mounted = 1 << d;
                top->img_size = disk[d].data.size();
                sd_mounted |= 1 << d;
                return;
            }
        sd_mount_pending = false;
    }
    switch (sd_state) {
    case 0:
        for (int d = 0; d < 2; d++)
            if ((top->sd_rd | top->sd_wr) & (1 << d)) {
                sd_drv = d;
                sd_write = (top->sd_wr >> d) & 1;
                sd_blk = d ? top->sd_lba1 : top->sd_lba0;
                sd_pos = 0;
                sd_state = 1;
                top->sd_ack = 1 << d;
                if (opt.fdc_log) fprintf(stderr, "sd %s DSK%d block %u (frame %u)\n", sd_write ? "write" : "read", d + 1, sd_blk, frame);
                break;
            }
        break;
    case 1: {
        Disk &dk = disk[sd_drv];
        size_t off = (size_t)sd_blk * 512 + sd_pos;
        top->sd_buff_addr = sd_pos;
        if (!sd_write) {
            top->sd_buff_dout = off < dk.data.size() ? dk.data[off] : 0;
            top->sd_buff_wr = 1;
        } else if (sd_pos > 0) {
            // din follows addr one clk later (registered block RAM)
            size_t o = (size_t)sd_blk * 512 + sd_pos - 1;
            uint8_t v = sd_drv ? top->sd_buff_din1 : top->sd_buff_din0;
            if (o < dk.data.size()) dk.data[o] = v;
            dk.dirty = true;
        }
        if (++sd_pos == (sd_write ? 513 : 512)) sd_state = 2;
        break;
    }
    case 2:
        top->sd_ack = 0;
        sd_state = 0;
        break;
    }
}

// hps_io's SD block protocol for the IDE drive (rtl/ata_disk.sv)
void Sim::idedisk()
{
    top->ide_mounted = 0;
    top->ide_buff_wr = 0;
    if (!ide.present) return;
    if (!ide_mounted) {
        top->ide_mounted = 1;
        top->ide_size = ide.data.size();
        ide_mounted = true;
        return;
    }
    switch (ide_state) {
    case 0:
        if (top->ide_rd || top->ide_wr) {
            ide_write = top->ide_wr;
            ide_blk = top->ide_lba;
            ide_pos = 0;
            ide_state = 1;
            top->ide_ack = 1;
            if (opt.ide_log) fprintf(stderr, "ide %s lba %u (frame %u)\n", ide_write ? "write" : "read", ide_blk, frame);
        }
        break;
    case 1: {
        size_t off = (size_t)ide_blk * 512 + ide_pos;
        top->ide_buff_addr = ide_pos;
        if (!ide_write) {
            top->ide_buff_dout = off < ide.data.size() ? ide.data[off] : 0;
            top->ide_buff_wr = 1;
        } else if (ide_pos > 0) {
            size_t o = (size_t)ide_blk * 512 + ide_pos - 1;
            if (o < ide.data.size()) ide.data[o] = top->ide_buff_din;
            ide.dirty = true;
        }
        if (++ide_pos == (ide_write ? 513 : 512)) ide_state = 2;
        break;
    }
    case 2:
        top->ide_ack = 0;
        ide_state = 0;
        break;
    }
}

void Sim::floppy()
{
    top->fdc_ack = 0;
    top->fdc_buf_wr = 0;
    switch (fdc_state) {
    case 0:
        if (top->fdc_rd || top->fdc_wr) {
            fdc_drv = top->fdc_drive;
            fdc_lsn = top->fdc_lsn;
            fdc_pos = 0;
            fdc_state = top->fdc_rd ? 1 : 2;
            if (opt.fdc_log) fprintf(stderr, "fdc %s DSK%d lsn %u (frame %u)\n", top->fdc_rd ? "read" : "write",
                                     fdc_drv + 1, fdc_lsn, frame);
        }
        break;
    case 1: {   // image -> buffer
        Disk &d = disk[fdc_drv];
        size_t off = (size_t)fdc_lsn * 256 + fdc_pos;
        top->fdc_buf_wr = 1;
        top->fdc_buf_addr = fdc_pos;
        top->fdc_buf_din = off < d.data.size() ? d.data[off] : 0xe5;
        if (++fdc_pos == 256) fdc_state = 3;
        break;
    }
    case 2: {   // buffer -> image (buf_dout follows buf_addr combinationally)
        Disk &d = disk[fdc_drv];
        top->fdc_buf_addr = fdc_pos;
        top->eval();
        size_t off = (size_t)fdc_lsn * 256 + fdc_pos;
        if (off < d.data.size()) d.data[off] = top->fdc_buf_dout;
        d.dirty = true;
        if (++fdc_pos == 256) fdc_state = 3;
        break;
    }
    case 3:
        top->fdc_ack = 1;
        fdc_state = 0;
        break;
    }
}

int Sim::run()
{
    mkdir_p(opt.out_dir);
    std::vector<uint8_t> rom, dsr;
    if (!load_file(opt.rom, rom) || rom.size() != 16384) { fprintf(stderr, "cannot load boot ROM %s\n", opt.rom.c_str()); return 1; }
    if (!load_file(opt.dsr, dsr) || dsr.size() != 8192) { fprintf(stderr, "cannot load DSR %s\n", opt.dsr.c_str()); return 1; }
    std::vector<uint8_t> rom2, isram;
    if (!opt.rom2.empty() && (!load_file(opt.rom2, rom2) || rom2.size() != 16384)) { fprintf(stderr, "cannot load boot ROM %s\n", opt.rom2.c_str()); return 1; }
    if (!opt.ide_sram.empty() && !load_file(opt.ide_sram, isram)) { fprintf(stderr, "cannot load %s\n", opt.ide_sram.c_str()); return 1; }
    if (!opt.ide.empty()) {
        ide.name = opt.ide;
        if (!load_file(opt.ide, ide.data)) { fprintf(stderr, "cannot open %s\n", opt.ide.c_str()); return 1; }
        ide.present = true;
    }
    for (int i = 0; i < 2; i++)
        if (!opt.dsk[i].empty()) {
            if (!disk[i].open(opt.dsk[i])) { fprintf(stderr, "cannot open %s\n", opt.dsk[i].c_str()); return 1; }
            if (!opt.quiet) fprintf(stderr, "DSK%d: %s, %d tracks, %d sides, %d sectors/track\n", i + 1,
                                    opt.dsk[i].c_str(), disk[i].tracks, disk[i].sides, disk[i].spt);
        }

    FILE *trace = opt.trace_file.empty() ? nullptr : fopen(opt.trace_file.c_str(), "w");
    std::vector<int16_t> wav, swav;
    double wav_acc = 0;
    FILE *vdplog = opt.vdp_log.empty() ? nullptr : fopen(opt.vdp_log.c_str(), "w");

    top->reset = 1;
    top->fdc_ready = (disk[0].present ? 1 : 0) | (disk[1].present ? 2 : 0);
    top->fdc_wprot = 0;
    top->fdc_spt0 = disk[0].spt; top->fdc_spt1 = disk[1].spt;
    top->fdc_tracks0 = disk[0].tracks; top->fdc_tracks1 = disk[1].tracks;
    top->fdc_sides0 = disk[0].sides; top->fdc_sides1 = disk[1].sides;
    top->joy1 = 0; top->joy2 = 0;
    top->mouse_stb = 0; top->mouse_btn = 0;
    // 2026-10-21 15:00:00, Wednesday
    top->rtc_bcd = 0x03261021150000ULL;
    top->rtc_bcd = (0x03ULL << 48) | (0x26ULL << 40) | (0x10ULL << 32) | (0x21ULL << 24) | (0x15ULL << 16);

    // ROM download while in reset: 0000 boot ROM, 4000 DSR, 6000 boot ROM 2.00, 10000 IDE SRAM
    top->boot200 = !rom2.empty();
    top->ide_en = !opt.ide.empty() || !isram.empty();
    top->vram192 = opt.vram192;
    std::vector<uint8_t> sprom;
    if (!opt.speech.empty() && (!load_file(opt.speech, sprom) || sprom.size() != 32768)) { fprintf(stderr, "cannot load speech ROM %s\n", opt.speech.c_str()); return 1; }
    top->speech_en = !sprom.empty();
    for (size_t i = 0; i < sprom.size(); i++) {
        top->rom_wr = 1;
        top->rom_addr = 0x90000 + i;
        top->rom_data = sprom[i];
        tick();
    }
    for (int i = 0; i < 16384 + 8192; i++) {
        top->rom_wr = 1;
        top->rom_addr = i;
        top->rom_data = i < 16384 ? rom[i] : dsr[i - 16384];
        tick();
    }
    for (size_t i = 0; i < rom2.size(); i++) {
        top->rom_wr = 1;
        top->rom_addr = 0x6000 + i;
        top->rom_data = rom2[i];
        tick();
    }
    for (size_t i = 0; i < isram.size() && i < 0x80000; i++) {
        top->rom_wr = 1;
        top->rom_addr = 0x10000 + i;
        top->rom_data = isram[i];
        tick();
    }
    top->rom_wr = 0;
    // the IDE image is mounted while the core is in reset (as an MGL does before an OSD reset)
    idedisk();
    tick();
    idedisk();
    for (int i = 0; i < 16; i++) tick();
    top->reset = 0;
    // the RTC takes the time after reset (as hps_io's RTC update on the MiSTer)
    top->rtc_load = 1;
    tick();
    top->rtc_load = 0;

    struct { uint64_t c; uint16_t wp, st, pc, ir; } prev{};
    bool have_prev = false;
    size_t key_i = 0;
    size_t mouse_i = 0;
    size_t joy_i = 0;
    std::vector<uint8_t> keyq;
    uint64_t next_key = 0;
    uint32_t last_report = 0;

    while (true) {
        tick();
        video();
#ifdef USE_SD
        sdcard();
#else
        floppy();
#endif
        idedisk();

        if (!opt.wav_file.empty() || !opt.speech_wav.empty()) {
            wav_acc += 48000.0;
            if (wav_acc >= CLK_HZ) {
                wav_acc -= CLK_HZ;
                swav.push_back((int16_t)((int)(int8_t)top->speech * 256));
                wav.push_back((int16_t)((int)top->sound * 64 + (int)(int8_t)top->speech * 64 - 8192));
            }
        }

        if (top->dbg_inst && trace) {
            // the operand words of an instruction arrive with the next one: print the previous line now
            if (have_prev && prev.c >= opt.trace_from && prev.c <= opt.trace_to)
                fprintf(trace, "%llu %04X %04X %04X: %s\n", (unsigned long long)prev.c, prev.wp, prev.st, prev.pc,
                        tms9995_dasm::disasm(prev.pc, prev.ir, top->dbg_op1, top->dbg_op2).c_str());
            prev = {top->dbg_cycles, top->dbg_wp, top->dbg_st, top->dbg_pc, top->dbg_ir};
            have_prev = true;
        }

        if (top->dbg_wr && vdplog && ((top->dbg_waddr & 0xfff0) == 0xf100 || (top->dbg_waddr & 0xfc00) == 0x8c00)
            && ((top->dbg_waddr & 0x6) != 0 || (top->dbg_waddr & 0xfff0) == 0xf100))
            fprintf(vdplog, "%u %llu %04X %02X\n", frame, (unsigned long long)top->dbg_cycles, top->dbg_waddr, top->dbg_wdata);

        // joystick
        while (joy_i < opt.joy.size() && opt.joy[joy_i].frame <= frame)
            top->joy1 = opt.joy[joy_i++].bits & 0x1f;

        // mouse
        top->mouse_stb = 0;
        while (mouse_i < opt.mouse.size() && opt.mouse[mouse_i].frame <= frame) {
            const auto &m = opt.mouse[mouse_i++];
            top->mouse_stb = 1;
            top->mouse_dx = (uint8_t)m.dx;
            top->mouse_dy = (uint8_t)m.dy;
            top->mouse_btn = ((m.btn & 4) ? 4 : 0) | ((m.btn & 2) ? 2 : 0) | ((m.btn & 1) ? 1 : 0);
            break;
        }

        // keyboard
        top->kbd_strobe = 0;
        while (key_i < opt.keys.size() && opt.keys[key_i].frame <= frame) {
            for (uint8_t k : opt.keys[key_i].codes) keyq.push_back(k);
            key_i++;
        }
        if (!keyq.empty() && clocks >= next_key) {
            top->kbd_strobe = 1;
            top->kbd_code = keyq.front();
            keyq.erase(keyq.begin());
            next_key = clocks + (uint64_t)(CLK_HZ / 100);  // 10 ms apart
        }

        if (!opt.quiet && frame != last_report && frame % 50 == 0) {
            last_report = frame;
            fprintf(stderr, "frame %u, cpu cycles %llu, pc %04X\n", frame, (unsigned long long)top->dbg_cycles, top->dbg_pc);
        }
        if (opt.max_cycles ? top->dbg_cycles >= opt.max_cycles : frame >= opt.frames) break;
        if (Verilated::gotFinish()) break;
    }
    if (trace) fclose(trace);
    auto write_wav = [](const std::string &fn, const std::vector<int16_t> &wav) {
        FILE *f = fopen(fn.c_str(), "wb");
        if (f) {
            uint32_t n = wav.size() * 2;
            auto w32 = [&](uint32_t v) { fwrite(&v, 4, 1, f); };
            auto w16 = [&](uint16_t v) { fwrite(&v, 2, 1, f); };
            fwrite("RIFF", 1, 4, f); w32(36 + n); fwrite("WAVEfmt ", 1, 8, f);
            w32(16); w16(1); w16(1); w32(48000); w32(96000); w16(2); w16(16);
            fwrite("data", 1, 4, f); w32(n);
            fwrite(wav.data(), 2, wav.size(), f);
            fclose(f);
        }
    };
    if (!opt.wav_file.empty()) write_wav(opt.wav_file, wav);
    if (!opt.speech_wav.empty()) write_wav(opt.speech_wav, swav);

    if (ide.dirty) {
        FILE *f = fopen(ide.name.c_str(), "wb");
        if (f) { fwrite(ide.data.data(), 1, ide.data.size(), f); fclose(f); }
    }
    for (int i = 0; i < 2; i++)
        if (disk[i].dirty && !opt.dsk_readonly) {
            FILE *f = fopen(disk[i].name.c_str(), "wb");
            if (f) { fwrite(disk[i].data.data(), 1, disk[i].data.size(), f); fclose(f); }
        }
    if (!opt.quiet) fprintf(stderr, "done: %u frames, %llu clocks, %llu cpu cycles\n", frame,
                            (unsigned long long)clocks, (unsigned long long)top->dbg_cycles);
    return 0;
}

int main(int argc, char **argv)
{
    Verilated::commandArgs(argc, argv);
    Options o;
    for (int i = 1; i < argc; i++) {
        std::string a = argv[i];
        auto next = [&]() -> std::string {
            if (i + 1 >= argc) { fprintf(stderr, "%s needs an argument\n", a.c_str()); exit(2); }
            return argv[++i];
        };
        if (a == "--help" || a == "-h") { usage(); return 0; }
        else if (a == "--rom") o.rom = next();
        else if (a == "--dsr") o.dsr = next();
        else if (a == "--rom2") o.rom2 = next();
        else if (a == "--ide") o.ide = next();
        else if (a == "--ide-sram") o.ide_sram = next();
        else if (a == "--ide-log") o.ide_log = true;
        else if (a == "--vram192") o.vram192 = true;
        else if (a == "--speech") o.speech = next();
        else if (a == "--speech-wav") o.speech_wav = next();
        else if (a == "--dsk1") o.dsk[0] = next();
        else if (a == "--dsk2") o.dsk[1] = next();
        else if (a == "--dsk-readonly") o.dsk_readonly = true;
        else if (a == "--frames") o.frames = std::stoul(next());
        else if (a == "--cycles") o.max_cycles = std::stoull(next());
        else if (a == "--screenshot") o.screenshots.insert(std::stoul(next()));
        else if (a == "--dump-every") o.dump_every = std::stoul(next());
        else if (a == "--out") o.out_dir = next();
        else if (a == "--trace") o.trace_file = next();
        else if (a == "--trace-from") o.trace_from = std::stoull(next());
        else if (a == "--trace-to") o.trace_to = std::stoull(next());
        else if (a == "--quiet") o.quiet = true;
        else if (a == "--fdc-log") o.fdc_log = true;
        else if (a == "--pixstats") o.pixstats = true;
        else if (a == "--mount-at") o.mount_at = std::stoul(next());
        else if (a == "--wav") o.wav_file = next();
        else if (a == "--vdp-log") o.vdp_log = next();
        else if (a == "--type") {
            std::string t = next();
            size_t c = t.find(':');
            if (c == std::string::npos) { fprintf(stderr, "--type wants FRAME:TEXT\n"); return 2; }
            Options::Key k;
            k.frame = std::stoul(t.substr(0, c));
            k.codes = xt_type(t.substr(c + 1));
            o.keys.push_back(k);
        }
        else if (a == "--joy") {
            Options::Joy j{};
            if (sscanf(next().c_str(), "%u:%d", &j.frame, &j.bits) != 2) { fprintf(stderr, "--joy wants FRAME:BITS\n"); return 2; }
            o.joy.push_back(j);
        }
        else if (a == "--mouse") {
            std::string v = next();
            Options::Mouse m{};
            if (sscanf(v.c_str(), "%u:%d,%d,%d", &m.frame, &m.dx, &m.dy, &m.btn) < 3) { fprintf(stderr, "--mouse wants FRAME:DX,DY[,B]\n"); return 2; }
            o.mouse.push_back(m);
        }
        else if (a == "--xt") {
            std::string s = next();
            size_t c = s.find(':');
            if (c == std::string::npos) { fprintf(stderr, "--xt wants FRAME:HEX,...\n"); return 2; }
            Options::Key k;
            k.frame = std::stoul(s.substr(0, c));
            std::string rest = s.substr(c + 1);
            size_t p = 0;
            while (p < rest.size()) {
                size_t q = rest.find(',', p);
                if (q == std::string::npos) q = rest.size();
                k.codes.push_back((uint8_t)std::stoul(rest.substr(p, q - p), nullptr, 16));
                p = q + 1;
            }
            o.keys.push_back(k);
        }
        else if (a[0] == '+') {}
        else { fprintf(stderr, "unknown option %s\n", a.c_str()); usage(); return 2; }
    }
    Sim sim(o);
    return sim.run();
}
