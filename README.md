# Geneve 9640 MiSTer — research workspace

- docs/       — datasheets (TMS9995, V9938, SN76489, MM58274, TMS9901), Wikipedia, Ninerpedia (via Wayback), GenREF/GenPROG manuals (docs/genref, docs/manuals), Myarc card manuals, forum threads, dressupgeekout guides (docs/web). See docs/README.md.
- software/   — whtech /Geneve mirror, MDOS 7.45 + 7.46 distributions, BeeryMiller GitHub repos (MDOS 7.46 source, Boot-Eprom, GPL, ABasic...), boot ROM versions, hloberg Full Geneve package (bootable CHDs), MAME ROM sets (software/roms/mame). See software/README.md.
- emulators/  — MAME geneve/genmod source subset (from local tree 395cc09e), -list* output, other emulators surveyed, mame_smoketest/. See emulators/README.md.
- fpga_refs/  — TI-99/4A MiSTer core, EP994A TMS9900, ESE V9938 (MSX), jt89, f18a, etc. See fpga_refs/README.md.

## Reference MAME boot (verified 2026-10-21, MAME 0.283 local binary)
    mame geneve -bios 1.00 -rompath software/roms/mame -peb:slot8 hfdc \
      -peb:slot8:hfdc:h1 generic -hard1 MAIN.CHD -peb:slot8:hfdc:h2 generic -hard2 GAMES.CHD
(MAIN/GAMES.CHD from software/hloberg_full_geneve/unzipped/Software — use copies, MAME writes to them.)
Boots MDOS to E:\> on both geneve and genmod. -bios 2.00 needs LOAD-MFM on the disk (see dressupgeekout guide).
Headless snapshots: emulators/mame_smoketest/snap.lua with -video none -nothrottle -autoboot_script.
