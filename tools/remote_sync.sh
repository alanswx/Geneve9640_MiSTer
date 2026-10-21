#!/bin/sh
# Copy the tracked files (working tree) to the build host: misterubuntu:~/mister/<dir> (default Geneve9640_MiSTer)
cd "$(dirname "$0")/.." || exit 1
DIR=${1:-Geneve9640_MiSTer}
git ls-files | rsync -a --files-from=- . "misterubuntu:mister/$DIR/"
