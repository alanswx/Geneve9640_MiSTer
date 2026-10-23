# Geneve 9640 MiSTer core — handoff

## State (2026-10-22)

Builds with Quartus 17 (63 % ALMs, 77 % RAM blocks, timing met). On mister126 it boots MDOS from floppy
and from the IDE disk; tested software is below. The sim (`verilator/`) runs the same RTL and matches MAME
screen for screen where compared (`tools/compare_run.sh`); `tools/regress.sh` compares two builds.

### Machine
- CPU: `rtl/tms9995/tms9995.sv`, MAME's tms9995.cpp microprograms; boot ROM traces match MAME's PC/WP/ST
  for 426k instructions with the same cycle counts. Full 3 MHz: DRAM read-ahead at the address phase,
  posted writes. V9938 command timing differs from MAME (ESE VDP), so long traces diverge at CE polling.
- Gate Array + PAL (`rtl/geneve_ga.sv`, MAME genboard.cpp), wait states, mapper, GROM emulation.
- V9938 = ESE VDP with local fixes: default palette on reset, PVIDEODE, an R#14 write keeps the
  auto-incremented A13-A0, a second control byte 11xxxxxx is ignored (MAME/openMSX; Geneve Tetris sends
  04 CE before every picture byte), 192K expansion RAM via R#45 (OSD Video RAM; no known software uses it).
- Clocks: MM58274 (`rtl/mm58274.sv`) and the IDE card's bq4847 (`rtl/bcd_clock.sv`) are loaded once from the
  MiSTer RTC and run on their own (the MiSTer sends the time only once).
- Genmod (OSD Memory = Genmod 2M; sim `--genmod --rom roms/gnmbt100.bin [--rom2 roms/gnmbt200.bin]`): MAME's
  genmod with the TI mode switch on (as hloberg's setup) and TURBO on. Genmod boot EPROMs at boot.rom
  98000/9C000. The Memex (2 MiB, SDRAM 200000-3FFFFF) answers physical pages 40-E7 (F_EXP/F_BOX/F_SRAMU)
  except the BA mirrors and 10xxx010 (MAME memex.cpp default switches); DRAM, SRAM, EPROM stay on board, the
  box's speech and IDE card answer first. TURBO drops the wait states of those accesses (MAME also does it
  for some on-board devices; not done here). Genmod with boot ROM 2.00 boots MDOS from the IDE disk
  (sim and board; Flying Shark from the hard disk).

### Peripherals
- Floppy: Myarc DDCC-1 (`rtl/wd1770.sv` sector level, `rtl/geneve_disk.sv`), V9T9 images, FORMAT works.
  MDOS 7.45 reads 80-track images; MDOS 6.50 uses 40 tracks unless configured (GENCFG).
- IDE: Nouspikel card at CRU >1000 in Geneve mode (`rtl/geneve_core.sv`, `rtl/ata_disk.sv`), its 512K SRAM in
  SDRAM (dram_addr 80000) preloaded from boot.rom with Fred Kaal's IDE DSR v14 (NOT Nouspikel's IDEAL, which
  has no IDE1 device). Boot ROM 2.00 loads IDE1.LOAD-IDE (the one from BeeryMiller/LOAD-SYS, loads at >A000;
  the MDOS745DIS copy loads at >2000 and crashes), which loads IDE1.SYSTEM-SYS. MDOS maps the disk to SCS6.
  (SCSMAP 6A); `ASSIGN C=SCS6:` gives it a drive letter. COPY to it lands in the image on the SD card.
- Speech: TMS5200 + TMS6100 on the PEB adapter, checked by ear on mister126 (ROM bit-reversed by mkbootrom).
- Keyboard, joysticks (TI BASIC CALL JOYST), bus mouse (9640 News MOUSE80), sound (CALL SOUND 440 Hz).

### OSD (Geneve.sv)
MiSTer computer-core OSD standard (~/Downloads/osd-standard.md): top page = media (Pri. DSK1, DSK2, IDE disk,
Load ROM), Memory, pages Machine / Video / Advanced, "Changes pending", Apply and reset. `cfg` latches `status`
at every reset; settings use `cfg`. IDE card and Boot ROM have Auto: card on when an IDE disk is mounted, boot ROM
2.00 when the IDE disk was mounted after the DSK1 floppy (remembered SC slots mount first, an MGL after). A mount that changes the Auto choice resets the machine
within 5 s after a reset (MGL and remembered SC slots mount then, in any order), an IDE disk mounted or
removed later resets it too; floppy changes later count at the next reset. Config version v,1 (status
bits 3 and 4 are no longer used).

### Software tested
| Software | Result |
|---|---|
| MDOS 6.50, 6.70, 7.45 | boot from floppy; 7.45 from IDE (`releases/Geneve_HD.zip`) |
| 9640 News: MIXPIC, HIMIX3, BATWIND, BOXER, SFXER, MOUSE80 | as MAME |
| Tetris (GAMES.CHD EXECGAMES) | plays (board) |
| Pinball 99 | plays (board; start from its own drive, see below) |
| Flying Shark | plays with Genmod (board); stock Geneve: "Insufficient memory" (also MAME, also 384K SRAM) |
| Gyruss (geneve9640/gyruss) | title (sim, board image) |
| GPL 7.40: 48 cartridge images (GAMES.CHD CODGPL) | 33 reach title/game; 15 fail the same way in MAME (below) |
| EXEC 2.8 (E/A option 5) | Scrabble, SPAD 13, Buck Rogers and Congo Bongo titles; Eric in Monsterland: "Unsupported GPL access attempted" (EXEC) |
| MyArt 1.4 (MAIN.CHD) | stops at "Loading Please Wait", as in MAME |

- EXEC-style loaders (PINLOAD, SHARKLOAD) open their ROM image in the current directory and say "I/O Error,
  ... aborted" otherwise: `B:` then `PINLOAD PINBALL` (hloberg's batch files `CD` into the game directory).
- Cartridges: AUTOEXEC `TIMODE2|GPL B:NAME`, then F7 (ExeMod) in GPL's menu. These stay in GPL's menu with
  module "MENU": 4A Flyer, Donkey Kong, Hopper, Jungle Hunt, Pac-Man, Pole Position, Sneggit, Anteater,
  Henpecked, Munchman II, Princess and Frog, Rotor Raider, Schnozola, Topper; Demon Attack shows garbage;
  Junkman Jr "Can't load". MAME does the same (checked Anteater, Donkey Kong, Topper, Demon Attack). hloberg
  starts them with `MYGPL /1`, now on the hard disk image.
- hloberg's collection on one IDE disk: tools/mkhdcollection.sh (tools/timt/CopyTree.java copies whole trees
  between images and host folders; tools/repath.py rewrites HDSn. device names). MDOS ASSIGN takes a
  directory (`ASSIGN F=C:\GAMES`, no trailing period: the alias gets a period appended, see L9/PARSEFS), so
  his E:/F:/G: batch files run unchanged. Needs Genmod (TIMODE + RAM disk leave too little of 512K; MDOS
  then says "Bad command" for MYGPL). Board: FROGGER (MYGPL /1), FLYSHARK, ZORKI (Infocom) work.
- The OSD saves settings only with System page > Save settings (Main menu.cpp); the saved config is
  Geneve_v1.CFG and applies at core start (Genmod from a saved config verified with MEM: 230 pages).
- hloberg's MAME package (MAIN/GAMES/DEVELOP.CHD) is for MAME's genmod with an HFDC; TIImageTool's
  CommandShell exports from it (`export IMG DIR.SUBDIR`). MAME's natkeyboard doesn't reach the Geneve keyboard;
  the scratchpad `keys.lua` presses its ioport fields instead.

## Layout

| Path | What |
|---|---|
| `Geneve.sv` | MiSTer top: OSD, cfg latch, SDRAM (DRAM, IDE SRAM, Memex), floppy/IDE images, RTC, video, audio |
| `rtl/geneve_core.sv` | the machine: CPU, gate array, 9901, VDP, SN76496, clocks, SRAM/EPROM, box cards, bus handshake |
| `rtl/tms9995/` | CPU; `tms9995_ucode.svh` generated by `tools/gen_tms9995_ucode.py` |
| `rtl/geneve_ga.sv` | Gate Array + PAL16R4 (MAME genboard.cpp), Genmod TURBO |
| `rtl/tms9901.sv`, `rtl/mm58274.sv`, `rtl/bcd_clock.sv`, `rtl/wd1770.sv`, `rtl/ata_disk.sv` | PSI, clocks, floppy and IDE |
| `rtl/vdp/` | ESE VDP (OCM-PLD), VDP_ID 0 = V9938, with the local changes above |
| `rtl/geneve_disk.sv`, `rtl/ps2_xt.sv`, `rtl/dbg_uart.sv`, `rtl/sdram.sv`, `rtl/pll*` | MiSTer glue |
| `verilator/` | headless sim: `make`, `./obj_dir_headless/Vtop --help`; variants with `make HL_DIR=obj_dir_X EXTRA=+define+...` |
| `releases/Geneve_HD.zip` | the shipped hard disk image (`tools/mkhdrelease.sh`) |
| `tools/mkbootrom.py` | boot.rom (boot EPROMs, DDCC-1 DSR, IDE SRAM, speech ROM, Genmod EPROMs) |
| `tools/mkideimage.sh`, `tools/mkidesram.py`, `tools/timt/MakeIDE.java` | IDE images with TIImageTool's classes (compile TIImageTool from emulators/tiimagetool with the RXTX jar + a gnu.io.DriverManager stub; TIMT / TIMT_LIB point at them) |
| `tools/tidsk.py` | V9T9 floppy images: list, extract, new, add TIFILES / DIS/VAR 80; DIS/VAR 80 as TIFILES |
| `tools/compare_run.sh`, `tools/regress.sh`, `tools/tracecmp.py` | MAME vs sim, build vs build, trace compare |
| `tools/remote_sync.sh`, `tools/kvms.sh` | copy tracked files to misterubuntu (git ls-files: add new files first); MiSTerKVMS CLI for mister126 |

`docs/`, `software/`, `emulators/`, `fpga_refs/` are local research material (gitignored); where it came
from: SOURCES.md (keep it updated).

## Board files (mister126)

- `_Computer/Geneve_20261022b.rbf` (all MGLs use it); older: `Geneve_20261022.rbf`, `Geneve_20261021.rbf`.
- `games/Geneve/boot.rom` 640 KiB, all parts (`boot_20261021.rom`: without the Genmod EPROMs).
- `_Geneve/*.mgl`: Geneve Hard Disk (Geneve_HD.hdv), Flying Shark (Genmod; set Memory = Genmod 2M), Pinball,
  Tetris, MDOS650, MDOS650 + 9640News, MDOS670b, MDOS745 IDE, Mouse demo, TI BASIC (MDOS 7.45), Adventure (GPL).

## Gotchas found

- CPU/GA use blocking assignments inside `always_ff` (as MAME's code); their ports must be NB-registered
  copies inside the same always_ff, or Verilator lets other blocks see values one clk early and the FPGA
  reads stale flops.
- The V9938 loads a default palette on reset; the ESE VDP did not (MSX BIOS wrote it).
- 9901 P1 = 1 is a one-shot VDP reset. The XT keyboard must send AA after power-on / clock-low reset.
- Quartus 17 rejects out-of-range constant indexes in unrolled loops even when guarded.
- MGL file paths are relative to games/Geneve/. The box reset (9901 P0) must clear the DDCC-1 latch, or a
  retry after a failed boot finds the DSR in the wrong EPROM bank.
- `make sd` runs the floppy through rtl/geneve_disk.sv and an hps_io SD model (`--mount-at F` mounts late).
- ROM download ranges are checked in three places (Geneve.sv rom_wr, verilator/sim.v rom_wr, geneve_core):
  a new boot.rom part needs all three.
- MAME: bios 2.00 nvram is `nvram/geneve_2/` (geneve) but `nvram/genmod_1/` (genmod); the IDE card's SRAM
  (`peb_slot8_ide_sram512`) must be restored from idesram.bin before each run.

## Next

1. Testers' reports (tester package: README in ~/Downloads/Geneve_tester_*.zip, built from the board files).
2. More software: `MYGPL /1` for the 15 cartridges, Extended BASIC 2.6 (DEVELOP.CHD XB) and its games,
   Infocom (GAMES.CHD INFOCOM), MyArt from its own directory.
3. Optional: RS232 (TI RS232 card), boot ROM 0.98 (in MAME's set), a second IDE drive.
