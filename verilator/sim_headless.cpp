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
    std::string vdp_log;                   // --vdp-log FILE: CPU writes to VDP ports 1-3
    struct Key { uint32_t frame; std::vector<uint8_t> codes; };
    std::vector<Key> keys;                 // --xt FRAME:HEX,HEX,...
};

static void usage()
{
    fprintf(stderr,
"usage: Vtop [options]\n"
"  --rom FILE             boot EPROM, 16 KiB (default roms/genbt100.bin)\n"
"  --dsr FILE             DDCC-1 DSR, 8 KiB (default roms/ddcc1.u3)\n"
"  --dsk1 FILE / --dsk2 FILE  V9T9 sector images in DSK1 / DSK2; --dsk-readonly: never write them back\n"
"  --frames N             stop after N video frames (default 60)\n"
"  --cycles N             stop after N CPU cycles\n"
"  --screenshot N         PNG of frame N (repeatable); --dump-every K: every Kth frame\n"
"  --out DIR              output directory (default out)\n"
"  --trace FILE           instruction trace: cycles WP ST PC: IR\n"
"  --trace-from C / --trace-to C   CPU cycle window for the trace\n"
"  --xt FRAME:HEX[,HEX..] XT scancodes into the keyboard at FRAME\n"
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
        px = 0;
        line++;
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
    if (top->vga_dhclk) {
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
    for (int i = 0; i < 2; i++)
        if (!opt.dsk[i].empty()) {
            if (!disk[i].open(opt.dsk[i])) { fprintf(stderr, "cannot open %s\n", opt.dsk[i].c_str()); return 1; }
            if (!opt.quiet) fprintf(stderr, "DSK%d: %s, %d tracks, %d sides, %d sectors/track\n", i + 1,
                                    opt.dsk[i].c_str(), disk[i].tracks, disk[i].sides, disk[i].spt);
        }

    FILE *trace = opt.trace_file.empty() ? nullptr : fopen(opt.trace_file.c_str(), "w");
    FILE *vdplog = opt.vdp_log.empty() ? nullptr : fopen(opt.vdp_log.c_str(), "w");

    top->reset = 1;
    top->fdc_ready = (disk[0].present ? 1 : 0) | (disk[1].present ? 2 : 0);
    top->fdc_wprot = 0;
    top->fdc_spt0 = disk[0].spt; top->fdc_spt1 = disk[1].spt;
    top->fdc_tracks0 = disk[0].tracks; top->fdc_tracks1 = disk[1].tracks;
    top->fdc_sides0 = disk[0].sides; top->fdc_sides1 = disk[1].sides;
    top->joy1 = 0; top->joy2 = 0;
    // 2026-10-21 15:00:00, Wednesday
    top->rtc_bcd = 0x03261021150000ULL;
    top->rtc_bcd = (0x03ULL << 48) | (0x26ULL << 40) | (0x10ULL << 32) | (0x21ULL << 24) | (0x15ULL << 16);

    // ROM download while in reset
    for (int i = 0; i < 16384 + 8192; i++) {
        top->rom_wr = 1;
        top->rom_addr = i;
        top->rom_data = i < 16384 ? rom[i] : dsr[i - 16384];
        tick();
    }
    top->rom_wr = 0;
    for (int i = 0; i < 16; i++) tick();
    top->reset = 0;
    // the RTC takes the time after reset (as hps_io's RTC update on the MiSTer)
    top->rtc_load = 1;
    tick();
    top->rtc_load = 0;

    struct { uint64_t c; uint16_t wp, st, pc, ir; } prev{};
    bool have_prev = false;
    size_t key_i = 0;
    std::vector<uint8_t> keyq;
    uint64_t next_key = 0;
    uint32_t last_report = 0;

    while (true) {
        tick();
        video();
        floppy();

        if (top->dbg_inst && trace) {
            // the operand words of an instruction arrive with the next one: print the previous line now
            if (have_prev && prev.c >= opt.trace_from && prev.c <= opt.trace_to)
                fprintf(trace, "%llu %04X %04X %04X: %s\n", (unsigned long long)prev.c, prev.wp, prev.st, prev.pc,
                        tms9995_dasm::disasm(prev.pc, prev.ir, top->dbg_op1, top->dbg_op2).c_str());
            prev = {top->dbg_cycles, top->dbg_wp, top->dbg_st, top->dbg_pc, top->dbg_ir};
            have_prev = true;
        }

        if (top->dbg_wr && vdplog && ((top->dbg_waddr & 0xfff0) == 0xf100 || (top->dbg_waddr & 0xfc00) == 0x8c00)
            && (top->dbg_waddr & 0x6) != 0)
            fprintf(vdplog, "%u %llu %04X %02X\n", frame, (unsigned long long)top->dbg_cycles, top->dbg_waddr, top->dbg_wdata);

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
            next_key = clocks + (uint64_t)(CLK_HZ / 50);   // 20 ms apart
        }

        if (!opt.quiet && frame != last_report && frame % 50 == 0) {
            last_report = frame;
            fprintf(stderr, "frame %u, cpu cycles %llu, pc %04X\n", frame, (unsigned long long)top->dbg_cycles, top->dbg_pc);
        }
        if (opt.max_cycles ? top->dbg_cycles >= opt.max_cycles : frame >= opt.frames) break;
        if (Verilated::gotFinish()) break;
    }
    if (trace) fclose(trace);

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
        else if (a == "--vdp-log") o.vdp_log = next();
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
