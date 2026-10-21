#!/bin/sh
# MiSTerKVMS command line against mister126 (capture stream on misterubuntu):
#   tools/kvms.sh screenshot out.png | type 'DIR\n' | key F12 | record 5 out.mp4 | status
exec /Applications/MiSTerKVMS.app/Contents/MacOS/kvms --mister 10.0.2.126 --stream "mkvm://10.0.2.128/Mister%20126" "$@"
