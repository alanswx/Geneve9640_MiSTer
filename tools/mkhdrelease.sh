#!/bin/sh
# Build the hard disk image shipped in releases/Geneve_HD.zip: MDOS 7.45 that boots from the IDE disk
# (OSD IDE card and Boot ROM on Auto), GPL 7.40 (TI mode), EXEC 2.8 (E/A option 5 loader) and Gyruss,
# with an AUTOEXEC that makes the disk C: and a HELP list.
#
#   tools/mkhdrelease.sh MDOS746DIS GYRUSS_TIFILES LOAD-SYS IDEDSR14.dsk OUT_DIR
#
# MDOS746DIS: the unzipped 9640News MDOS746DIS.zip (its MDOS/SYSTEM-SYS is MDOS 7.45);
# GYRUSS_TIFILES: github.com/geneve9640/gyruss TIFILES; LOAD-SYS: github.com/BeeryMiller/LOAD-SYS.
# TIMT / TIMT_LIB as for tools/mkideimage.sh; SIZE (MB, default 32).
set -e
ROOT=$(cd "$(dirname "$0")/.." && pwd)
M=$1; GYR=$2; LS=$3; DSR=$4; OUT=$5
T=$(mktemp -d)
cp "$M"/GPL740/GPL "$M"/GPL740/GPM "$M"/GPL740/GPN "$M"/GPL740/GPO "$M"/GPL740/GPP "$T/"
cp "$M"/GPL740/MYGPL "$M"/GPL740/MYGPM "$M"/GPL740/MYGPN "$M"/GPL740/MYGPO "$M"/GPL740/MYGPP "$T/"
cp "$M"/EXEC/EXEC "$M"/EXEC/EXEC28DOC "$T/"
cp "$GYR"/GYRLOAD "$GYR"/GYRUSS1 "$GYR"/GYRUSS2 "$GYR"/GYRUSS3 "$GYR"/GYRUSS4 "$T/"
txt() { python3 -I "$ROOT/tools/tidsk.py" --tifiles-text "$1" "$2" "$T/$1"; }
txt AUTOEXEC 'ASSIGN C=SCS6:|C:|PATH C:\|PROMPT $N:\$P$G|HELP'
txt HELP 'ECHO|ECHO Geneve 9640 MiSTer hard disk (IDE1 = SCS6. = C:)|ECHO|ECHO GYRUSS     Gyruss (joystick, P pause, ESC exits)|ECHO &TI        TI-99/4A mode (TI BASIC, cartridges)|ECHO EXEC file  run an E/A option 5 program|ECHO HELP       this list|ECHO'
txt GYRUSS 'GYRLOAD SCS6.GYRUSS1'
txt TI 'TIMODE2|SCS6.MYGPL'
mkdir -p "$OUT"
"$ROOT/tools/mkideimage.sh" "$OUT/Geneve_HD.hdv" "${SIZE:-32}" "$M/MDOS/SYSTEM-SYS" "$LS/LOAD-IDE" "$DSR" "$T/idesram.bin" "$T"
rm -f "$OUT/Geneve_HD.zip"
(cd "$OUT" && zip -q -9 Geneve_HD.zip Geneve_HD.hdv)
rm -rf "$T"
