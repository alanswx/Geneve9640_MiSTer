#!/bin/sh
# Build an IDE hard disk image that boots MDOS with boot ROM 2.00, plus the IDE card SRAM with
# Fred Kaal's IDE DSR (what IDELOAD would leave in the card).
#
#   tools/mkideimage.sh OUT.(chd|raw) SIZE_MB SYSTEM-SYS LOAD-IDE IDEDSR14.dsk SRAM_OUT.bin
#
# TIMT = directory of compiled TIImageTool classes (see HANDOFF.md), TIMT_LIB = its jars.
# LOAD-IDE must be the one released with genbt200.bin (BeeryMiller/LOAD-SYS, loads at >A000).
# Check in MAME: SRAM_OUT.bin -> nvram/geneve_2/peb_slot8_ide_sram512, then
#   mame geneve -bios 2.00 -peb:slot8 ide -peb:slot8:ide:ata:0 hdd -hard1 OUT.chd
# with the card's MODE DIP switch set to Geneve (cfg: port :peb:slot8:ide:MODE value 1).
set -e
ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUT=$1; SIZE=$2; SYS=$3; LOADIDE=$4; DSRDSK=$5; SRAM=$6
CP="$TIMT:$TIMT_LIB/*"
T=$(mktemp -d)
cp "$SYS" "$T/SYSTEM-SYS"
# pad TIFILES payloads to whole sectors (some copies on GitHub are truncated)
python3 -I -c "
import sys
for f in sys.argv[1:]:
    d = open(f, 'rb').read(); d += bytes((-(len(d) - 128)) % 256); open(f, 'wb').write(d)" "$T/SYSTEM-SYS"
cp "$LOADIDE" "$T/LOAD-IDE"
python3 -I -c "
import sys
d = open(sys.argv[1], 'rb').read(); d += bytes((-(len(d) - 128)) % 256); open(sys.argv[1], 'wb').write(d)" "$T/LOAD-IDE"
case "$OUT" in /*) ABS=$OUT ;; *) ABS=$PWD/$OUT ;; esac
java -cp "$CP" de.mizapf.timt.ui.MakeIDE "$ABS" "$SIZE" GENEVEHD
(cd "$T" && java -cp "$CP" de.mizapf.timt.CommandShell import "$ABS#1")
java -cp "$CP" de.mizapf.timt.CommandShell dir "$ABS#1"
python3 -I "$ROOT/tools/mkidesram.py" "$DSRDSK" "$SRAM"
rm -rf "$T"
