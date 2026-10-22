#============================================================================
#  Geneve 9640 Verilator simulation
#
#    make            # headless sim -> ./obj_dir_headless/Vtop
#    make clean
#
#  The machine (rtl/*.sv) goes to Verilator as is. The V9938 is the ESE VDP
#  (VHDL, rtl/vdp), turned into a Verilog netlist by "ghdl synth".
#
#  Requires: ghdl (5.x, synth built in), verilator (5.x), python3.
#============================================================================

V      = verilator
GHDL   = ghdl
RTL    = ../rtl
GEN    = gen
WORK   = ghdl_work

GHDL_FLAGS = --std=93 -fsynopsys -fexplicit -frelaxed -Wno-hide -Wno-shared -Wno-binding --workdir=$(WORK)

VDP_SRC = $(addprefix $(RTL)/vdp/, vdp_package.vhd vdp_ram.vhd vdp_linebuf.vhd vdp_doublebuf.vhd vdp_vga.vhd \
	vdp_ntsc_pal.vhd vdp_hvcounter.vhd vdp_interrupt.vhd vdp_ssg.vhd vdp_colordec.vhd vdp_text12.vhd \
	vdp_graphic123m.vhd vdp_graphic4567.vhd vdp_spinforam.vhd vdp_sprite.vhd vdp_register.vhd \
	vdp_command.vhd vdp_wait_control.vhd vdp.vhd)
GEN_V = $(GEN)/vdp.v

V_SRC = sim.v $(RTL)/geneve_core.sv $(RTL)/tms9995/tms9995.sv $(RTL)/geneve_ga.sv $(RTL)/tms9901.sv \
	$(RTL)/mm58274.sv $(RTL)/wd1770.sv $(RTL)/sn76496/sn76496.v $(GEN_V)

V_OPT = -O3 -I$(RTL) -I$(RTL)/tms9995 --x-assign fast --x-initial fast --noassert \
	-Wno-fatal -Wno-PINMISSING -Wno-WIDTH -Wno-UNOPTFLAT -Wno-CASEINCOMPLETE \
	-Wno-UNSIGNED -Wno-CMPCONST -Wno-DECLFILENAME -Wno-MULTIDRIVEN -Wno-LATCH \
	-Wno-TIMESCALEMOD -Wno-COMBDLY -Wno-INITIALDLY -Wno-BLKANDNBLK -Wno-CASEX -Wno-BLKSEQ

V_OPT += $(EXTRA)

CXXFLAGS = -O3 -std=c++17
HL_DIR   = obj_dir_headless
HL_EXE   = ./$(HL_DIR)/Vtop

all: headless

headless: $(HL_EXE)

$(RTL)/tms9995/tms9995_ucode.svh: ../tools/gen_tms9995_ucode.py
	python3 ../tools/gen_tms9995_ucode.py $@

$(WORK)/.analysed: $(VDP_SRC) Makefile
	@mkdir -p $(WORK)
	$(GHDL) -a $(GHDL_FLAGS) $(VDP_SRC)
	@touch $@

$(GEN)/vdp.v: $(WORK)/.analysed fix_port_aliases.py
	@mkdir -p $(GEN)
	$(GHDL) synth $(GHDL_FLAGS) --out=verilog vdp > $@.tmp
	$(GHDL) synth $(GHDL_FLAGS) --out=vhdl vdp > $(GEN)/vdp_netlist.vhd
	python3 fix_port_aliases.py $@.tmp $(GEN)/vdp_netlist.vhd
	@# The VRAM data output is tri-stated in the VHDL; the netlist drives 0 instead.
	perl -pi -e "s/(\\d+)'b[Zz]+\\b/\$${1}'b0/g" $@.tmp
	@mv $@.tmp $@

netlist: $(GEN_V)

$(HL_EXE): $(V_SRC) $(RTL)/tms9995/tms9995_ucode.svh $(RTL)/geneve_ga_defs.svh sim_headless.cpp Makefile
	$V -cc $(V_OPT) --exe --build -j 0 --Mdir $(HL_DIR) --top-module top \
		-CFLAGS "$(CXXFLAGS)" $(V_SRC) sim_headless.cpp -o Vtop

# The floppy images through rtl/geneve_disk.sv and an hps_io SD model, as on the MiSTer
SD_DIR = obj_dir_sd
sd: ./$(SD_DIR)/Vtop

./$(SD_DIR)/Vtop: $(V_SRC) $(RTL)/geneve_disk.sv $(RTL)/tms9995/tms9995_ucode.svh $(RTL)/geneve_ga_defs.svh sim_headless.cpp Makefile
	$V -cc $(V_OPT) +define+USE_SD --exe --build -j 0 --Mdir $(SD_DIR) --top-module top \
		-CFLAGS "$(CXXFLAGS) -DUSE_SD" $(V_SRC) $(RTL)/geneve_disk.sv sim_headless.cpp -o Vtop

clean:
	rm -rf $(HL_DIR) $(SD_DIR) $(GEN) $(WORK) out

.PHONY: all headless sd netlist clean
