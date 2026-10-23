#!/bin/sh
# Build a 128 MB IDE disk with hloberg's MAME Geneve collection (MAIN, GAMES, DEVELOP: HFDC hard disks
# HDS1-3, drives E: F: G: in his setup) as directories MAIN, GAMES, DEVELOP of one IDE disk, on top of
# the release disk (tools/mkhdrelease.sh: MDOS 7.45, GPL, EXEC, Gyruss). For personal use: the
# collection contains commercial TI software.
#
#   tools/mkhdcollection.sh MDOS746DIS GYRUSS_TIFILES LOAD-SYS IDEDSR14.dsk HLOBERG_SOFTWARE OUT_DIR
#
# HLOBERG_SOFTWARE: the folder with MAIN.CHD, GAMES.CHD, DEVELOP.CHD. Needs TIMT / TIMT_LIB (as for
# tools/mkideimage.sh) with tools/timt/CopyTree.java compiled into TIMT.
#
# The AUTOEXEC maps E: F: G: to C:\MAIN, C:\GAMES, C:\DEVELOP (ASSIGN takes a directory), so his batch
# files keep their drive paths; only HDS1-3 device names are rewritten (tools/repath.py --devices-only).
# Then his own AUTOEXEC lines follow: TIMODE, RAM disk, PATH and his menu (ARCADE, SKILL, INFOCOM, ...).
# Like his setup it needs the Genmod (OSD Memory = Genmod 2M): TIMODE and the RAM disk leave too
# little of 512K for MYGPL.
set -e
ROOT=$(cd "$(dirname "$0")/.." && pwd)
M=$1; GYR=$2; LS=$3; DSR=$4; HL=$5; OUT=$6
CT="java -cp $TIMT:$TIMT_LIB/* de.mizapf.timt.CopyTree"
SIZE=128 "$ROOT/tools/mkhdrelease.sh" "$M" "$GYR" "$LS" "$DSR" "$OUT" > /dev/null
T=$(mktemp -d)
for v in MAIN GAMES DEVELOP; do
    cp "$HL/$v.CHD" "$T/$v.chd"
    $CT export "$T/$v.chd" "$T/$v"
done
python3 -I "$ROOT/tools/repath.py" --devices-only "$T" E=HDS1=MAIN F=HDS2=GAMES G=HDS3=DEVELOP > "$OUT/repath.log"
mkdir -p "$T/root"
# his AUTOEXEC, after the drive mapping, with C:\ (Gyruss, EXEC, MYGPL) added to his PATH
HIS=$(python3 -I -c "
import sys; sys.path.insert(0, sys.argv[2]); import repath
print('|'.join(l.rstrip(';') + ';C:' + chr(92) if l.startswith('PATH') else l for l in repath.records(open(sys.argv[1], 'rb').read())))" "$T/MAIN/AUTOEXEC" "$ROOT/tools")
txt() { python3 -I "$ROOT/tools/tidsk.py" --tifiles-text "$1" "$2" "$T/root/$1"; }
txt AUTOEXEC "ASSIGN C=SCS6:|ASSIGN E=C:\\MAIN|ASSIGN F=C:\\GAMES|ASSIGN G=C:\\DEVELOP|$HIS|ECHO Also: GYRUSS (Gyruss), TI (TI-99/4A mode, MYGPL)"
txt TI 'MYGPL'
for v in MAIN GAMES DEVELOP; do
    $CT "$T/$v" "$OUT/Geneve_HD.hdv#1" $v
done
$CT "$T/root" "$OUT/Geneve_HD.hdv#1"
mv "$OUT/Geneve_HD.hdv" "$OUT/Geneve_Collection.hdv"
rm -f "$OUT/Geneve_HD.zip"
rm -rf "$T"
