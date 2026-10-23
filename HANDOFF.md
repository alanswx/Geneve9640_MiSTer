# Geneve 9640 MiSTer core — handoff

## State (2026-10-21)

- **Simulation**: `verilator/` boots the boot ROM 1.00 and MDOS 6.50 / 6.70 from V9T9 floppy images (Myarc DDCC-1)
  to `A:\>`, keyboard works (`DIR` lists the disk). Screens match MAME.
- **CPU**: `rtl/tms9995/tms9995.sv`, a port of MAME's tms9995.cpp microprograms; boot ROM traces match MAME's
  PC/WP/ST for 426k instructions with the same cycle counts (differences only around sound-chip READY timing).
  V9938 command timing differs from MAME (ESE VDP), so long traces diverge at CE polling loops.
- **MiSTer**: `Geneve.sv` builds with Quartus 17 (57 % ALMs, 38 % BRAM, timing met). On mister126 it boots
  MDOS 6.50 from `MDOS650.dsk` to `A:\>` with the MiSTer RTC time; PS/2 keyboard works (`DIR`).
  Debug UART: 16 hex digits every 0.1 s on /dev/ttyS1 (PC | VDP command debug | VDP writes | ROM | flags).
- CPU speed: full 3 MHz (DRAM read-ahead at the address phase, posted writes); no lost CLKOUT ticks in the sim.
- Tested (sim, and board where noted): MDOS 6.50/6.70/7.45 from floppy; two disks from one MGL (board);
  MIXPIC G7 picture (board); HIMIX3, BATWIND, BOXER, SFXER same as MAME; GPL 7.40 TI mode: module menu,
  Scott Adams' Adventure cartridge, TI BASIC; CALL SOUND(2000,440,0) = 440 Hz for 2.0 s (sim and board).
- Tetris (9640 News, GAMES.CHD EXECGAMES.TETRIS): title picture same as MAME after two ESE VDP fixes:
  an R#14 write keeps the auto-incremented A13-A0 (it reloaded the whole last-set address), and a second
  control byte with bits 7-6 = 11 is ignored (MAME/openMSX; it was a register write). Tetris sends 04 CE
  before every picture byte. Regression: tools/regress.sh VTOP OUT (screenshot md5s, compare two builds).
- Native games found in hloberg's GAMES.CHD (MAME HFDC image; TIImageTool CommandShell export works on it):
  EXECGAMES.{TETRIS,PINB,SHARK,SCRABBLE,SP}. hloberg runs them from batch files in GAMES.CHD ARCADEB
  (`CD F:\EXECGAMES.SHARK` then `SHARKLOAD SHARK`): the EXEC-style loaders (PINLOAD, SHARKLOAD) open their
  ROM image (PINROM256, SHARK512) in the *current directory*, and say "I/O Error, ... aborted" otherwise
  (that was the earlier "Pinball fails" result, in MAME too). Start them with AUTOEXEC `B:|PINLOAD PINBALL`.
  Tetris plays on mister126 ("Geneve Tetris" MGL: TetrisBoot.dsk with AUTOEXEC B:TETRIS + Games1.dsk).
  Pinball 99 (PINROM256, 256K) runs on the stock Geneve from an 80-track floppy (sim, MAME, mister126:
  "Geneve Pinball" MGL = PinBoot.dsk + Pinball.dsk).
  Flying Shark (SHARK512, 512K) needs a Memex: on a stock Geneve MDOS says "Insufficient memory" (MAME, even
  with its 384K SRAM option); it runs on the Genmod (OSD Genmod On; sim, MAME genmod, and mister126:
  "Geneve Flying Shark (Genmod)" MGL = SharkBoot.dsk + FlyingShark.dsk, set Genmod On, Reset).
  SCRA/SPAD13A are E/A option 5 images (MDOS says Bad command; hloberg loads them in the E/A cartridge via GPL).
  MYART 1.4 (MAIN.CHD) stops at "Loading Please Wait" in MAME and in the sim alike (run from its directory?).
- TI cartridges (GPL 7.40, GAMES.CHD CODGPL, 48 images; AUTOEXEC `TIMODE2|GPL B:NAME`, then F7 = ExeMod in
  GPL's menu, a key, 2): 33 reach their title or game (Alpiner, Burgertime, Stud Poker, Chisholm Trail,
  Fathom, Frogger, Ms. Pac-Man, M*A*S*H, Milton Bradley games, Microsurgeon, Miner 2049er, Moon Mine,
  Moonsweeper, Munchman, Othello, Parsec, A-Maze-Ing, Popeye, Return to Pirate's Isle, TI Invaders, Tunnels of
  Doom, Tombstone City, Video Chess, Wingwar, Blasto, Car Wars, Hunt the Wumpus, Kaboom, The Attack, Yahtzee...).
  14 stay in GPL's menu with module "MENU" (4A Flyer, Donkey Kong, Hopper, Jungle Hunt, Pac-Man, Pole Position,
  Sneggit, Anteater, Henpecked, Munchman II, Princess and Frog, Rotor Raider, Schnozola, Topper), Demon Attack
  shows garbage, JMANJR "Can't load": the same in MAME (checked Anteater, Donkey Kong, Topper, Demon Attack);
  hloberg starts them with MYGPL /1. Adventure asks for its data base (as expected without one).
- Genmod (OSD "Genmod (Memex 2M)"; sim --genmod with --rom roms/gnmbt100.bin [--rom2 roms/gnmbt200.bin]):
  MAME's genmod with the TI mode switch on (as hloberg's setup) and TURBO on. Genmod boot EPROMs from MAME
  genmod.zip at boot.rom 98000/9C000 (tools/mkbootrom.py parts 7, 8). The Memex (2 MiB, SDRAM 200000-3FFFFF)
  answers physical pages 40-E7 (F_EXP/F_BOX/F_SRAMU) except the BA mirrors and 10xxx010 (MAME memex.cpp default
  switches); DRAM, SRAM, EPROM stay on board, the box's speech and IDE card answer first. TURBO: those accesses
  have no wait states (MAME also drops them for some on-board devices; not done here).
- MDOS 7.45 reads 80-track DSDD images (2880 sectors) on DSK2 (Flying Shark, Pinball disks); MDOS 6.50 used
  40 tracks unless configured (GENCFG).
- Bus mouse (V9938 colour bus, MiSTer PS/2 mouse): 9640 News V1#3 MOUSE80 follows the mouse, right button
  writes, left exits (sim and board). Sim: --mouse FRAME:DX,DY,BUTTONS.
- OSD Video RAM 192K: V9938 expansion RAM via R#45 MXC/MXS/MXD (checked in the sim with a small test
  program; no known software uses it).
- Floppy FORMAT (MDOS 6.50 FORMAT B:) gives a valid V9T9 image (write track sets the geometry); sim and board.
- Joystick 1: TI BASIC CALL JOYST gives 4,4 for up+right, 0,-4 for down (sim: --joy FRAME:BITS).
- Speech (PEB speech adapter, TMS5200 model): a test program speaking "HELLO" (LOAD ADDRESS >351A, SPEAK)
  gives 0.52 s of speech in the sim (--speech roms/speech.bin --speech-wav) and 0.45 s on the board.
  Checked by ear on mister126 (user, 2026-10-22): sounds right. MAME's speech adapter stayed silent for the
  same program (native mode).
  The ROM must be bit-reversed (tools/mkbootrom.py does it).
- IDE hard disk: the core has the Nouspikel IDE card (CRU >1000, Geneve mode, rtl/geneve_core.sv + rtl/ata_disk.sv);
  its 512K SRAM is in SDRAM (dram_addr bit 19) and preloaded from boot.rom. OSD: Boot ROM 1.00/2.00, IDE card
  Off/On, S2 = IDE disk (.hdv/.raw/.img, plain 512-byte sector dump). Sim: `--rom2 roms/genbt200.bin --ide X.raw
  --ide-sram idesram.bin` boots MDOS 7.45 from IDE; MDOS sees the disk as SCS6. (SCSMAP 6A), DIR/COPY work.
  Board (mister126, 2026-10-21): boot ROM 2.00 + IDE card -> LOAD-IDE v3.05 -> MDOS 7.45 from MDOS745_IDE.hdv,
  COPY to SCS6. lands in the .hdv on the SD card. Set the OSD options, then Reset (the mount survives resets).
- IDE background (MAME verified): boot ROM 2.00 (genbt200.bin) boots MDOS 7.45 from an IDE
  disk with no floppy. Needs: Nouspikel IDE card in Geneve mode at CRU >1000; Fred Kaal's IDE DSR v14
  (IDEDSR14.dsk; NOT Nouspikel's IDEAL, which has no IDE1 device) in the card's 512K SRAM; on the disk
  IDE1.LOAD-IDE (the one from BeeryMiller/LOAD-SYS released with genbt200.bin, loads at >A000; the
  MDOS745DIS copy loads at >2000 and crashes) and IDE1.SYSTEM-SYS. tools/mkideimage.sh builds both the
  disk (.chd for MAME, .raw for the core) and the SRAM image. Kaal's DSR v18 + sources, DU2K, DM2K:
  https://hexbus.com/ti99geek/ (mirror of ti99-geek.nl).

## Layout

| Path | What |
|---|---|
| `rtl/geneve_core.sv` | the machine: CPU, gate array, 9901, VDP, SN76496, RTC, SRAM/EPROM, DDCC-1, bus handshake |
| `rtl/tms9995/` | CPU; `tms9995_ucode.svh` generated by `tools/gen_tms9995_ucode.py` |
| `rtl/geneve_ga.sv` | Gate Array + PAL16R4 (MAME genboard.cpp) |
| `rtl/tms9901.sv`, `rtl/mm58274.sv`, `rtl/wd1770.sv` | PSI, RTC, floppy controller (sector level) |
| `rtl/vdp/` | ESE VDP (OCM-PLD), VDP_ID 0 = V9938; local changes: reset palette, PVIDEODE, a WHEN OTHERS |
| `rtl/geneve_disk.sv`, `rtl/ps2_xt.sv`, `rtl/dbg_uart.sv`, `rtl/sdram.sv`, `rtl/pll*` | MiSTer glue |
| `verilator/` | headless sim: `make`, `./obj_dir_headless/Vtop --dsk1 X.dsk --frames 1500 --screenshot 1500` |
| `tools/tracecmp.py` | compare a sim trace (`--trace`) with a MAME debugger trace |
| `tools/remote_sync.sh`, `tools/kvms.sh` | copy tracked files to misterubuntu; MiSTerKVMS CLI for mister126 |
| `tools/tidsk.py` | V9T9 floppy images: list, extract, new image, add TIFILES / DIS/VAR 80 files |
| `tools/compare_run.sh` | the same MDOS session (AUTOEXEC) in MAME and the sim, screenshots side by side |
| `tools/mkbootrom.py` | boot.rom for the MiSTer (both boot ROMs, DDCC-1 DSR, IDE SRAM) |
| `tools/mkideimage.sh`, `tools/mkidesram.py` | IDE disk image (MDOS boot) and IDE card SRAM image with Kaal's DSR |
| `tools/timt/MakeIDE.java` | IDE image creation with TIImageTool's classes (compile TIImageTool from emulators/tiimagetool with the RXTX jar + a gnu.io.DriverManager stub) |

`docs/`, `software/`, `emulators/`, `fpga_refs/` are local research material (gitignored); where it came from: SOURCES.md (keep it updated).

## Board files

Core `_Computer/Geneve_20261022.rbf` (Genmod), boot.rom 640 KiB with the Genmod EPROMs (old one kept as boot_20261021.rom).

`/media/fat/games/Geneve/boot.rom` from tools/mkbootrom.py: genbt100.bin + ddcc1.u3 + genbt200.bin (MAME sets)
+ IDE SRAM at 10000 (tools/mkidesram.py on IDEDSR14.dsk), 576 KiB; the old 24 KiB file still works without IDE/2.00.
`MDOS745_IDE.hdv` (tools/mkideimage.sh) + `_Geneve/Geneve MDOS745 IDE.mgl` (needs OSD Boot ROM 2.00, IDE card On);
disks `MDOS650.dsk`, `MDOS670b_720k.dsk`; MGL `/media/fat/_Geneve/Geneve MDOS650.mgl`.

## Gotchas found

- CPU/GA use blocking assignments inside `always_ff` (as MAME's code); their ports must be NB-registered
  copies or Verilator lets other blocks see values one clk early.
- The V9938 loads a default palette on reset; the ESE VDP did not (MSX BIOS wrote it).
- 9901 P1 = 1 is a one-shot VDP reset. The XT keyboard must send AA after power-on / clock-low reset.
- Quartus 17 rejects out-of-range constant indexes in unrolled loops even when guarded.
- NB port copies must be inside the same always_ff as the blocking code (a separate block reads stale flops
  on the FPGA while Verilator shows fresh values).
- MGL file paths are relative to games/Geneve/. The box reset (9901 P0) must clear the DDCC-1 latch, or a
  retry after a failed boot finds the DSR in the wrong EPROM bank.
- `make sd` runs the floppy through rtl/geneve_disk.sv and an hps_io SD model (`--mount-at F` mounts late).

## Next

1. Optional: 384K SRAM (MAME "Ultimate" SRAM at pages C0-E7; MDOS does not use it), boot ROM 0.98, RS232.
2. IDE on the board (mister126); MDOS 7.46; bq4847 clock registers are static (time of the last RTC load).
3. Mouse (V9938 colour bus), joystick check, sound check, OSD options (boot ROM version, VRAM 192K).
