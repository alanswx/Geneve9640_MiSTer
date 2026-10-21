#!/bin/sh
# Copy the tracked files (working tree) to the build host: misterubuntu:~/mister/Geneve9640_MiSTer
cd "$(dirname "$0")/.." || exit 1
git ls-files | rsync -a --files-from=- . misterubuntu:mister/Geneve9640_MiSTer/
