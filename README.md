# Myarc Geneve 9640 for MiSTer

A MiSTer core for the Myarc Geneve 9640 (1987): a TMS9995 computer on a card for the TI-99/4A
peripheral expansion box, with a V9938 video processor, 512 KiB of RAM and a TI-99/4A compatibility mode.
It runs MDOS (the Geneve's own OS) and, through MDOS's GPL interpreter, TI-99/4A software.

The machine follows MAME's `geneve` driver (Michael Zapf): CPU microprograms, gate array, memory mapper,
wait states and peripheral cards are ported from it and checked against it.

## What is in it

- TMS9995 at 3 MHz (cycle-exact port of MAME's microprograms), Gate Array and PAL, TMS9901, MM58274 clock
  (set from the MiSTer RTC), SN76496 sound, 64 KiB 0-wait SRAM, 512 KiB DRAM (SDRAM).
- V9938 (the ESE VDP, configured as V9938) with 128 KiB video RAM, or 192 KiB (expansion RAM) from the OSD.
- Keyboard (PS/2 → XT), joystick 1 and 2, bus mouse (V9938 colour bus; left button on the 9901).
- Peripheral box:
  - Myarc DDCC-1 floppy controller with two drives (V9T9 `.dsk` images, read, write and format);
  - Nouspikel IDE card with one hard disk (plain sector image), its 512 KiB SRAM holding Fred Kaal's IDE DSR.
- Boot EPROM 1.00 or 2.00 (2.00 boots from the IDE disk).

## Files

`games/Geneve/boot.rom`, built with `tools/mkbootrom.py` from the MAME ROM sets and the IDE DSR:

```
tools/mkbootrom.py boot.rom genbt100.bin ddcc1.u3 genbt200.bin idesram.bin
```

| Part | Source |
|---|---|
| `genbt100.bin`, `genbt200.bin` | MAME `geneve.zip` (boot EPROMs 1.00 and 2.00) |
| `ddcc1.u3` | MAME `ddcc1.zip` (Myarc DDCC-1 DSR) |
| `idesram.bin` | `tools/mkidesram.py IDEDSR14.dsk idesram.bin` (Fred Kaal's IDE DSR v14, see SOURCES.md) |

A 24 KiB `boot.rom` (`genbt100.bin` + `ddcc1.u3` only) also works if boot ROM 2.00 and the IDE card are not
used. Floppy images: `.dsk` (V9T9 sector dumps, 90K to 720K). MDOS boots from `SYSTEM/SYS` on DSK1
(boot ROM 1.00) or `SYSTEM-SYS` (2.00).

## OSD

| Option | |
|---|---|
| DSK1, DSK2 | floppy images |
| IDE disk | hard disk image (`.hdv`, `.raw`, `.img`: 512-byte sectors, LBA order) |
| Boot ROM | 1.00 / 2.00 |
| IDE card (CRU 1000) | Off / On |
| Video RAM | 128K / 192K |
| Aspect ratio, Reset | |

Change Boot ROM, IDE card or Video RAM, then Reset.

## Booting MDOS from the IDE disk

`tools/mkideimage.sh` builds a hard disk image with MDOS (`SYSTEM-SYS` and the `LOAD-IDE` released with
boot ROM 2.00) using TIImageTool's classes. Mount it as IDE disk, set Boot ROM 2.00 and IDE card On, Reset:
the boot ROM loads `IDE1.LOAD-IDE`, which loads MDOS. Under MDOS the disk is `SCS6.` (MDOS maps the first
IDE drive there; see `SCSMAP` in the MDOS 7.4x notes).

## Simulation

`verilator/` runs the same RTL in Verilator (`make`), with options for disks, the IDE card, keyboard
input, mouse, joystick, screenshots, instruction traces (MAME format) and WAV output:

```
cd verilator && make
./obj_dir_headless/Vtop --dsk1 MDOS650.dsk --frames 1500 --type '1200:DIR\n' --screenshot 1500
./obj_dir_headless/Vtop --rom2 roms/genbt200.bin --ide disk.raw --ide-sram idesram.bin --frames 900 --screenshot 900
```

See `HANDOFF.md` for the state of the work, the layout of the code and what was learned on the way, and
`SOURCES.md` for where the documentation, software and ROMs came from.

## Credits

MAME's Geneve emulation (Michael Zapf), the ESE VDP (Kazuhiro Tsujikawa, ESE Artists' factory, OCM-PLD),
SN76496 from the MiSTer cores, Fred Kaal's IDE DSR, Thierry Nouspikel's IDE card documentation,
Beery Miller and 9640News for MDOS and the boot EPROM 2.00, TIImageTool (Michael Zapf).
