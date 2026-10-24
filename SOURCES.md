# Sources

Where the documentation, software, ROMs and reference code used for this core came from. Local copies are in
`docs/`, `software/`, `emulators/` and `fpga_refs/` (not in git). Keep this list up to date when something new is
found; note dead sites and their replacements.

## Status of key sites (2026-10-21)

| Site | Status | Use instead |
|---|---|---|
| ti99-geek.nl (Fred Kaal: IDE DSR, DU2K, DM2K) | does not respond | mirror https://hexbus.com/ti99geek/ (index page is built by JavaScript; open project pages directly, e.g. `Projects/idedsr/idedsr.html`, files under `Projects/<name>/Files/`) |
| unige.ch/medecine/nouspikel (Thierry Nouspikel's TI tech pages, IDE card, IDEAL) | HTTP 503 | Wayback Machine, e.g. https://web.archive.org/web/20250711121137/https://www.unige.ch/medecine/nouspikel/ti99/ideal.htm |
| Wayback copies of ti99-geek.nl files | listed in the index but downloads return 404 | the hexbus mirror |

## The machine, general

- https://en.wikipedia.org/wiki/Geneve_9640
- https://en.wikipedia.org/wiki/Myarc_Disk_Operating_System
- https://www.ninerpedia.org/wiki/Geneve_9640, https://ninerpedia.org/wiki/Category:MDOS
- https://ninerpedia.org/wiki/Features_of_the_TI_and_Geneve_emulation_in_MESS,
  https://ninerpedia.org/wiki/MAME_version_history, https://ninerpedia.org/wiki/MESS_version_history
- http://aug.99er.net/geneve_9640.htm
- https://jedimatt42.com/retro/geneve/
- https://retrocomputingforum.com/t/geneve-9640-the-other-tms9900-based-micro/387
- https://ti99resources.wordpress.com/emulation/
- https://4apedia.com/index.php/Micropendium
- AtariAge forums: https://forums.atariage.com/topic/319101-geneve-9640-benchmarks/,
  https://forums.atariage.com/topic/301459-geneve-9640-geneve-ii/,
  https://forums.atariage.com/topic/246124-can-a-geneve-boot-off-of-an-80-track-tifdc/,
  https://forums.atariage.com/topic/256244-mame-harddisk-switch/,
  https://forums.atariage.com/topic/289605-tipi-geneve-9640-to-raspberry-pi-interface-development/page/9/
- https://forums.bannister.org/ubbthreads.php?ubb=showflat&Main=6511&Number=67182 (MESS Geneve thread)

## Documentation and software archives

- WHT archive: https://ftp.whtech.com/ (JSON listing: `https://ftp.whtech.com/?do=list&file=<dir>`);
  `Geneve/`, `Geneve.new/` (GeneveOS, Documents, Tools, e.g. `Geneve.new/GeneveOS/GenOS_MDOS.txt`,
  `Geneve.new/Tools/qde33.dsk`), `datasheets and manuals/`, `magazines/micropendium/`, `System ROMs/MAME/`
  (`geneve.zip`, `genmod.zip`, `ti99_hfdc.zip`), `utilities/Archivers/arc303g`. Older address: https://www.whtech.com/ftp/
- https://99er.net/ftp.html
- dressupgeekout (Charlotte Koch) Geneve pages: https://dressupgeekout.com/geneve/,
  https://dressupgeekout.com/geneve/geneve-mame/ (running the Geneve in MAME),
  https://dressupgeekout.com/geneve/full-geneve-package/, https://dressupgeekout.com/geneve/useful-geneve-programs/,
  https://dressupgeekout.com/geneve/geneve-documents/, https://dressupgeekout.com/geneve/ti-writer/,
  https://dressupgeekout.com/tags/geneve/
- hloberg's MAME Geneve packages (HFDC hard disk images MAIN.CHD / GAMES.CHD):
  https://forums.atariage.com/blogs/entry/18937-new-zip-file-of-full-geneve-for-mame/,
  https://forums.atariage.com/blogs/entry/17703-messmame-geneve-9640-files-update/,
  https://forums.atariage.com/blogs/entry/17630-the-other-99s-a-set-of-mamemess-packages/,
  https://forums.atariage.com/blogs/blog/528-hlo-projects/
- Internet Archive search: https://archive.org/advancedsearch.php?q=geneve+9640
- MM58274 RTC data sheet: http://www.national.com/ds/MM/MM58274C.pdf

## MDOS, boot EPROMs, 9640 News (Beery Miller)

- https://github.com/BeeryMiller/MDOS (MDOS sources; UPDATE74x release notes: IDE needs Fred Kaal's DSR v14,
  SCSMAP)
- https://github.com/BeeryMiller/Boot-Eprom (versions 0.98, 1.00, 2.00 sources and binaries)
- https://github.com/BeeryMiller/LOAD-SYS (GENEVE200.BIN = MAME genbt200.bin, and the matching LOAD-IDE / LOAD-MFM /
  LOAD-SCS / LOAD-TIP; its LOAD-IDE is the one that works with boot ROM 2.00; the file in git is short of its last
  sector's padding)
- Other BeeryMiller repos: ABasic, Abasic-V3, FORTH, Fortran, Geneve9640, GPL, HyperCopy, Manuals, MDM5,
  MDOS730-Issues, MEMTEST, MyWord, PSYSTEM (all `https://github.com/BeeryMiller/<name>`)
- https://www.9640news.com/?p=530, https://www.9640news.com/wp-content/uploads/2026/01/MDOS746DIS.zip (MDOS 7.46)
- MDOS 7.45 release: https://forums.atariage.com/topic/365259-mdos-version-745-release/ (MDOS745DIS),
  7.43: https://forums.atariage.com/topic/360732-mdos-version-743-release/
- https://github.com/geneve9640/MDOS-Utilities, https://github.com/geneve9640/gyruss
- https://github.com/horizonramdisk/Horizon-Ramdisk-ti994a
- https://github.com/RobertLM78/ti99-and-myarc-BASIC

## Hard disk: IDE card

- Fred Kaal (mirror https://hexbus.com/ti99geek/):
  - IDE DSR: `Projects/idedsr/idedsr.html`, files `idedsr_v18.zip`, `idedsr_v18_src.zip` (full source), `tbtestprogs.zip`
  - IDE DSR v14 (what MDOS 7.4x requires): `IDEDSR14.dsk`, supplied by the user (~/Downloads)
  - DU2K (IDE/disk initializer): `Projects/du2k/du2k.html`, `du2k_v31.zip`, `du2k_v31_src.zip`
  - DM2K (disk manager): `Projects/dm2k/dm2k.html`, `dm2k_v40.zip`, `dm2k_v40_src.zip`; `DM2K_v30.dsk`, `DM2K_v3.1.dsk`
    from the user; Geneve version: https://www.hexbus.com/ti99geek/Projects/gdm2k/gdm2k.html
  - IDE card: `Projects/idecard/idecard.html`, `idecard.zip`, `idetest.zip`, `ti99_ide_lpf.zip`; `IDE_TEST.bin` from the user
  - Archived index of the old site: http://web.archive.org/cdx/search/cdx?url=ti99-geek.nl*
- Thierry Nouspikel: IDE card https://www.unige.ch/medecine/nouspikel/ti99/ide2.htm, IDEAL
  https://www.unige.ch/medecine/nouspikel/ti99/ideal.htm (via the Wayback Machine); `ideal.zip` (IDEAL 1.0a-1.3a)
  supplied by the user. IDEAL is the TI-99/4A DSR; the Geneve setup uses Kaal's DSR instead.
- MAME's card: `src/devices/bus/ti99/peb/tn_ide.cpp` (Michael Zapf)

## TIPI

- https://github.com/jedimatt42/tipi, https://jedimatt42.com/downloads.html
- https://www.arcadeshopper.com/wp/ti-99-4a-faq-tipi-ti-to-raspberry-pi-connection/

## Emulators and tools

- MAME: https://github.com/mamedev/mame, https://www.mamedev.org/ (geneve.cpp, genboard.cpp, tms9995.cpp,
  tn_ide.cpp, ...); older geneve.cpp: https://git.redump.net/hbmame/plain/src/mame/drivers/geneve.cpp
- MAME 0.260 ROM sets: https://archive.org/download/mame-0.260-roms-non-merged/MAME%200.260%20ROMs%20%28non-merged%29/MAME%200.260%20ROMs%20%28non-merged%29/
  (geneve.zip: genbt098/100/200.bin; ddcc1.zip; ti99_hfdc.zip; ...); MAME 0.289 software lists (merged) from the user
- TIImageTool (Michael Zapf): https://github.com/mizapf/tiimagetool, https://www.mizapf.de/en/ti99/timt
  (compiles with RXTX 2.1.7 from https://repo1.maven.org/maven2/org/rxtx/rxtx/2.1.7/rxtx-2.1.7.jar plus a stub)
- Classic99: https://github.com/tursilion/classic99; js99er: https://github.com/Rasmus-M/js99er-angular;
  V9T9: https://github.com/eswartz/emul; emu9995: https://github.com/kwhr0/emu9995; ti99sim; pyTIrom:
  https://github.com/GHPS/pyTIrom
- Kaal's Ti994w emulator: https://ti99-geek.nl/Projects/ti994w/Files/Ti994w54c.zip (archived)

## FPGA references

- ESE VDP (V9938/V9958): http://www.ohnaka.jp/ese-vdp/, https://github.com/kunichiko/ese-vdp,
  https://github.com/lfantoniosi/ocm-pld-dev (the copy used in rtl/vdp), https://codeberg.org/dinoboards/V9958-Super
- TI-99/4A MiSTer core: https://github.com/MiSTer-devel/TI-99_4A_MiSTer
- MSX cores: https://github.com/MiSTer-devel/MSX_MiSTer, https://github.com/MiSTer-devel/MSX1_MiSTer
- ColecoVision: https://github.com/MiSTer-devel/ColecoVision_MiSTer
- Erik Piehl's TMS9900 FPGA work: https://github.com/Speccery/EP994A, https://github.com/Speccery/fpga99,
  https://github.com/Speccery/tiny-tms9900, https://github.com/Speccery/breadboard
- F18A / TN VDP: https://github.com/lfantoniosi/f18a, https://github.com/lfantoniosi/tn_vdp
- SN76489: https://github.com/jotego/jt89
- MiSTer template: https://github.com/MiSTer-devel/Template_MiSTer
- MiSTer Main (menu.cpp: OSD settings are saved only by System page > Save settings, to config/<core>_v<n>.CFG):
  https://github.com/MiSTer-devel/Main_MiSTer
- SDRAM: http://hamsterworks.co.nz/mediawiki/index.php/Simple_SDRAM_Controller
