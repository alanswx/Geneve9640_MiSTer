#!/bin/sh
# Run the same MDOS session in MAME and in the simulation and keep screenshots of both.
#
#   tools/compare_run.sh NAME BOOT.dsk DSK2.dsk|- "CMD1|CMD2|..." FRAMES
#
# BOOT.dsk is copied, AUTOEXEC (DIS/VAR 80) with the commands is added to the copy, and both
# emulations boot it (bios 1.00, Myarc DDCC-1). FRAMES is a comma list for the simulation; the last
# one ends the run. MAME's floppy emulation has real rotation/step timing and loads MDOS about 1400
# frames later, so its screenshots are taken at FRAME + MAME_DELAY (default 1400).
# Output: $OUT/NAME/mame_FRAME.png, sim_FRAME.png  (OUT defaults to the session scratchpad compare/)
set -e
ROOT=$(cd "$(dirname "$0")/.." && pwd)
NAME=$1; BOOT=$2; DSK2=$3; CMDS=$4; FRAMES=$5
OUT=${OUT:-$ROOT/verilator/out_compare}
MAME=${MAME:-/Users/alans/dev2/FM-7_MiSTer_alanswx/refs/mame/mame}
# 80-track images need 3.5" drives in MAME: MAME_DRIVES="-peb:slot8:ddcc1:0 35dd -peb:slot8:ddcc1:1 35dd"
MAME_DRIVES=${MAME_DRIVES:-}
# EXTRA_TEXT="NAME=line|line" adds another DIS/VAR 80 file (a batch file) to the boot disk
EXTRA_TEXT=${EXTRA_TEXT:-}
D=$OUT/$NAME
mkdir -p "$D"
cp "$BOOT" "$D/boot.dsk"
python3 -I "$ROOT/tools/tidsk.py" "$D/boot.dsk" --add-text AUTOEXEC "$CMDS" > /dev/null
if [ -n "$EXTRA_TEXT" ]; then
    python3 -I "$ROOT/tools/tidsk.py" "$D/boot.dsk" --add-text "${EXTRA_TEXT%%=*}" "${EXTRA_TEXT#*=}" > /dev/null
fi
FLOP2=""; SIM2=""
if [ "$DSK2" != "-" ]; then
    cp "$DSK2" "$D/dsk2.dsk"
    cp "$DSK2" "$D/dsk2_sim.dsk"
    FLOP2="-flop2 $D/dsk2.dsk"; SIM2="--dsk2 $D/dsk2_sim.dsk"
fi
cp "$D/boot.dsk" "$D/boot_sim.dsk"
LAST=$(echo "$FRAMES" | tr ',' '\n' | sort -n | tail -1)
MAME_DELAY=${MAME_DELAY:-1400}
MFRAMES=$(echo "$FRAMES" | tr ',' '\n' | awk -v d=$MAME_DELAY '{printf "%s%d", (NR>1 ? "," : ""), $1+d}')
MLAST=$((LAST + MAME_DELAY))

# MAME (frames counted by the Lua script, 60 Hz)
rm -rf "$D/mame_snap"
cat > "$D/snap.lua" <<EOF
local f=0
local snaps = {}
for n in string.gmatch("$MFRAMES", "%d+") do snaps[tonumber(n)] = true end
emu.register_frame_done(function()
  f = f + 1
  if snaps[f] then manager.machine.video:snapshot() end
  if f >= $MLAST then manager.machine:exit() end
end)
EOF
(cd "$D" && "$MAME" geneve -bios 1.00 -rompath "$ROOT/software/roms/mame" -skip_gameinfo -nothrottle \
    -video none -sound none -snapshot_directory mame_snap -autoboot_script snap.lua \
    -peb:slot8 ddcc1 $MAME_DRIVES -flop1 boot.dsk $FLOP2 > mame.log 2>&1) &

# simulation
(cd "$ROOT/verilator" && ${SIM:-./obj_dir_headless/Vtop} --frames "$LAST" --quiet --out "$D/sim" \
    $(echo "$FRAMES" | tr ',' '\n' | sed 's/^/--screenshot /') \
    --dsk1 "$D/boot_sim.dsk" $SIM2 > "$D/sim.log" 2>&1) &
wait

i=0
for f in $(echo "$FRAMES" | tr ',' '\n' | sort -n); do
    [ -f "$D/mame_snap/geneve/$(printf %04d $i).png" ] && mv "$D/mame_snap/geneve/$(printf %04d $i).png" "$D/mame_$f.png"
    [ -f "$D/sim/frame_$(printf %05d $f).png" ] && mv "$D/sim/frame_$(printf %05d $f).png" "$D/sim_$f.png"
    i=$((i + 1))
done
ls "$D"/*.png
