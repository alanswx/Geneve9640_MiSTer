#!/bin/bash
# Run a fixed set of simulation scenarios and print one md5 per screenshot, to compare two builds:
#
#   tools/regress.sh VTOP OUTDIR > a.txt;  tools/regress.sh OTHER_VTOP OUTDIR2 > b.txt;  diff a.txt b.txt
#
# Scenarios use the disks in software/ (gitignored, see SOURCES.md); a missing disk skips its scenario.
# Each scenario gets fresh copies of its disks (MDOS writes to them). Runs in parallel.
ROOT=$(cd "$(dirname "$0")/.." && pwd)
VTOP=$(cd "$(dirname "$1")" && pwd)/$(basename "$1"); OUT=$2
SW=$ROOT/software
MDOS650=$SW/mister/games/Geneve/MDOS650.dsk
NEWS21=$SW/whtech/Geneve/9640\ News\ disks\ v1-3/9640\ NEWS\ disks\ for\ Geneve/9640V2#1A.DSK
GAMES=${GAMES:-}            # optional floppy with TETRIS + TETRIT (see HANDOFF.md)
IDE=${IDE:-}                # optional IDE image with MDOS (tools/mkideimage.sh)
IDESRAM=$SW/kaal_idedsr/idesram.bin
mkdir -p "$OUT"

# scenario NAME FRAMES AUTOEXEC|- DSK2|- [extra sim args...]
scenario() {
    local name=$1 frames=$2 cmds=$3 dsk2=$4; shift 4
    local d=$OUT/$name; rm -rf "$d"; mkdir -p "$d"
    local args=()
    if [ "$cmds" != "-" ]; then
        cp "$MDOS650" "$d/boot.dsk"
        python3 -I "$ROOT/tools/tidsk.py" "$d/boot.dsk" --add-text AUTOEXEC "$cmds" > /dev/null
        args+=(--dsk1 "$d/boot.dsk")
    fi
    if [ "$dsk2" != "-" ]; then cp "$dsk2" "$d/dsk2.dsk"; args+=(--dsk2 "$d/dsk2.dsk"); fi
    local last=${frames##*,}
    for f in ${frames//,/ }; do args+=(--screenshot "$f"); done
    (cd "$ROOT/verilator" && "$VTOP" --quiet --frames "$last" --out "$d" "${args[@]}" "$@" > "$d/log" 2>&1)
}

cp "$MDOS650" "$OUT/mdos650.dsk"
scenario mdos650_dir 1500 - - --dsk1 "$OUT/mdos650.dsk" --type '1200:DIR\n' &
[ -f "$NEWS21" ] && scenario himix3 1500,2100 "B:|HIMIX3" "$NEWS21" &
[ -f "$NEWS21" ] && scenario boxer 1500 "B:|BOXER" "$NEWS21" &
[ -n "$GAMES" ] && scenario tetris 1300 "B:TETRIS" "$GAMES" &
if [ -n "$IDE" ]; then
    cp "$IDE" "$OUT/ide.raw"
    scenario ide_boot 940 - - --rom2 roms/genbt200.bin --ide "$OUT/ide.raw" --ide-sram "$IDESRAM" &
fi
wait
cd "$OUT" && for f in */frame_*.png; do echo "$f $(md5 -q "$f" 2>/dev/null || md5sum "$f" | cut -d' ' -f1)"; done
