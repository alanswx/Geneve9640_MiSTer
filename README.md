# Myarc Geneve 9640 for MiSTer

A MiSTer core for the Myarc Geneve 9640 (1987): a TMS9995 computer on a card for the TI-99/4A
peripheral expansion box, with a V9938 video processor, 512 KiB of RAM and a TI-99/4A compatibility mode.
It runs MDOS (the Geneve's own OS) and, through MDOS's GPL interpreter, TI-99/4A software.

The machine follows MAME's `geneve` and `genmod` drivers (Michael Zapf): CPU microprograms, gate array,
memory mapper, wait states and peripheral cards are ported from them and checked against them.

## Hardware

- TMS9995 at 3 MHz (cycle-exact port of MAME's microprograms), Gate Array and PAL, TMS9901, MM58274 clock
  (set from the MiSTer RTC and running on its own), SN76496 sound, 64 KiB 0-wait SRAM, 512 KiB DRAM.
- V9938 (the ESE VDP, configured as V9938) with 128 KiB video RAM, or 192 KiB (expansion RAM).
- Keyboard (PS/2 → XT), joysticks 1 and 2, bus mouse (V9938 colour bus).
- Boot EPROM 1.00 (boots from floppy) or 2.00 (boots from the IDE disk).
- Genmod (Memory option): the Genmod board with a 2 MiB Memex card, its own boot EPROMs, TURBO (no wait
  states for the Memex) and the TI mode switch on.
- Peripheral box:
  - Myarc DDCC-1 floppy controller, two drives (V9T9 `.dsk` images up to 80 tracks: read, write, format);
  - Nouspikel IDE card with one hard disk, its 512 KiB SRAM holding Fred Kaal's IDE DSR, and its bq4847
    clock;
  - TI Speech Synthesizer on its PEB adapter (TMS5200 + TMS6100, from the TI-99/4A MiSTer core).

## Files

`games/Geneve/boot.rom` holds the boot EPROMs and DSRs. Build it with `tools/mkbootrom.py`:

```
tools/mkbootrom.py boot.rom genbt100.bin ddcc1.u3 genbt200.bin idesram.bin ti99_speech.zip gnmbt100.bin gnmbt200.bin
```

| Part | Source |
|---|---|
| `genbt100.bin`, `genbt200.bin` | MAME `geneve.zip` (boot EPROMs 1.00 and 2.00) |
| `ddcc1.u3` | MAME `ti99_ddcc1.zip` (Myarc DDCC-1 DSR) |
| `idesram.bin` | `tools/mkidesram.py IDEDSR14.dsk idesram.bin` (Fred Kaal's IDE DSR v14, see SOURCES.md) |
| `ti99_speech.zip` | MAME speech ROM set (the tool bit-reverses it for the TMS6100 model) |
| `gnmbt100.bin`, `gnmbt200.bin` | MAME `genmod.zip` (Genmod boot EPROMs 1.00 and 2.00) |

Trailing parts can be left out (`-` skips one): a 24 KiB `boot.rom` (`genbt100.bin` + `ddcc1.u3`) runs
MDOS from floppy without the IDE card, speech or Genmod.

`releases/Geneve_HD.zip` holds `Geneve_HD.hdv`, a 32 MB hard disk that boots MDOS 7.45 (see below).

## OSD

The OSD follows the MiSTer computer-core OSD standard: media act at once; every other setting waits for
**Apply and reset** (or any reset), and "Changes pending" shows meanwhile.

| Page | Row | Values |
|---|---|---|
| top | Pri. DSK1, DSK2 | floppy images (`.dsk`) |
| top | IDE disk | hard disk image (`.hdv`, `.raw`, `.img`: 512-byte sectors, LBA order) |
| top | Load ROM | another `boot.rom` for this session |
| top | Memory | 512K / Genmod 2M |
| Machine | Video RAM | 128K / 192K |
| Machine | IDE card | Auto / Off / On (Auto: on when an IDE disk is mounted) |
| Machine | Speech synth. | On / Off |
| Video | Aspect ratio | Original / Full Screen / custom |
| Advanced | Boot ROM | Auto / 1.00 / 2.00 (Auto: 2.00 for the IDE disk, see below) |

On Auto the machine boots whichever of DSK1 and the IDE disk was mounted last (an MGL mounts after the
remembered disks, so its boot disk wins). Disks mounted just after a
reset (by an MGL or the remembered slots) that change this choice reset the machine again, and so does
mounting or removing the IDE disk later; a floppy changed later counts at the next reset. So an MGL with a
boot floppy boots it, and one with only the hard disk boots MDOS from the hard disk.

## Hard disk

Mount `Geneve_HD.hdv` (from `releases/Geneve_HD.zip`) as IDE disk. Boot ROM 2.00 loads `LOAD-IDE` from the
disk, which loads MDOS; MDOS sees the disk as `SCS6.` and the AUTOEXEC assigns it to `C:`. On it:

| Command | |
|---|---|
| `GYRUSS` | Gyruss (Geneve port of Rasmus Moustgaard's ColecoVision version; joystick, P pause, ESC exits) |
| `&TI` | TI-99/4A mode: restarts with TIMODE2 and starts MYGPL (Enter, any key, 1 = TI BASIC; `GPL B:NAME` in an AUTOEXEC starts a cartridge image) |
| `EXEC file` | runs an Editor/Assembler option 5 program (EXEC 2.8) |
| `HELP` | the list |

`tools/mkhdcollection.sh` builds a 128 MB disk with hloberg's MAME Geneve collection (MAIN, GAMES, DEVELOP
as directories, mapped to E: F: G: as in his setup; needs Memory = Genmod 2M) for personal use.

Its files come from the 9640News MDOS 7.46 distribution (MDOS 7.45, GPL 7.40, EXEC 2.8), BeeryMiller/LOAD-SYS
(`LOAD-IDE`) and geneve9640/gyruss; `tools/mkhdrelease.sh` rebuilds it. `tools/mkideimage.sh` makes other
images (TIImageTool's classes; see HANDOFF.md).

## Software notes

- Programs started with an EXEC-style loader (Pinball 99's `PINLOAD`, Flying Shark's `SHARKLOAD`) look for
  their ROM image in the current directory: change to the program's drive first (`B:` then `PINLOAD PINBALL`).
- Flying Shark needs the Memex: Memory = Genmod 2M.
- MDOS 7.45 reads 80-track floppy images on DSK2 (720 KiB files such as Flying Shark's).

## Simulation

`verilator/` runs the same RTL in Verilator (`make`), with options for disks, the IDE card, Genmod,
keyboard input, mouse, joystick, screenshots, instruction traces (MAME format) and WAV output:

```
cd verilator && make
./obj_dir_headless/Vtop --dsk1 MDOS650.dsk --frames 1500 --type '1200:DIR\n' --screenshot 1500
./obj_dir_headless/Vtop --rom2 roms/genbt200.bin --ide Geneve_HD.hdv --ide-sram idesram.bin --frames 1000 --screenshot 1000
```

See `HANDOFF.md` for the state of the work, the layout of the code and what was learned on the way, and
`SOURCES.md` for where the documentation, software and ROMs came from.

## Credits

MAME's Geneve emulation (Michael Zapf), the ESE VDP (Kazuhiro Tsujikawa, ESE Artists' factory, OCM-PLD),
SN76496 from the MiSTer cores, the TMS5200 speech from the TI-99/4A MiSTer core, Fred Kaal's IDE DSR,
Thierry Nouspikel's IDE card documentation, Beery Miller and 9640News for MDOS, GPL, EXEC and the boot
EPROM 2.00, Rasmus Moustgaard and geneve9640 for Gyruss, TIImageTool (Michael Zapf).
