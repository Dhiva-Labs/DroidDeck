#!/usr/bin/env bash
# Smoke run of an installed DroidDeck, shared by every Linux format CI builds
# besides the .deb: the .rpm on Fedora and openSUSE, the Arch package, the
# AppImage and the Flatpak.
#
# usage: smoke.sh <command that starts DroidDeck...>
#
# Run it on a virtual display whose framebuffer Xvfb mirrors into a file:
#
#   xvfb-run -a -s "-screen 0 1280x800x24 -fbdir $SMOKE_FB" \
#     dbus-run-session -- bash smoke.sh droiddeck
#
# Starts DroidDeck and passes once all of these hold:
#
#   - The screen shows a painted Flutter UI. A Flutter UI paints hundreds of
#     distinct colours; a runner whose Dart snapshot did not start shows a
#     handful. Read from Xvfb's framebuffer file because the Flatpak builder
#     image has no ImageMagick or xdotool.
#   - The app found adb: it logs "[DroidDeck] adb: <path> v<version>" after
#     running `<path> version`, or "adb: NOT FOUND".
#   - Its device tracker is connected: the app ran `adb start-server` and its
#     own socket to the adb server on 127.0.0.1:5037 accepted
#     host:track-devices-l. No phone is attached, so the device list is empty.
#
# Environment: SMOKE_FB (the -fbdir directory), HOME (a fresh directory),
# SMOKE_SECONDS (default 120).
set -euo pipefail
: "${SMOKE_FB:?set SMOKE_FB to the directory given to Xvfb -fbdir}"
[ $# -ge 1 ] || { echo "usage: $0 <command...>" >&2; exit 2; }
secs="${SMOKE_SECONDS:-120}"
min_colours=200
log="$HOME/droiddeck-smoke.log"

# Distinct pixel values on the screen, from the XWD file Xvfb keeps up to
# date (big-endian header, then the colour map, then the pixels).
colours() {
  python3 - "$SMOKE_FB/Xvfb_screen0" <<'EOF'
import struct, sys
data = open(sys.argv[1], 'rb').read()
h = struct.unpack('>25I', data[:100])
header_size, width, height, bpp, bpl, ncolours = h[0], h[4], h[5], h[11], h[12], h[19]
start = header_size + ncolours * 12
step = bpp // 8
seen = set()
for y in range(height):
    row = data[start + y * bpl:start + y * bpl + width * step]
    if step == 4:
        seen.update(memoryview(row).cast('I'))
    else:
        seen.update(row[i:i + step] for i in range(0, len(row), step))
print(len(seen))
EOF
}

found() { grep -E '^\[DroidDeck\] adb: /[^ ]+ v' "$log" > /dev/null; }
tracking() { grep -F '[DroidDeck] tracker: connected (host:track-devices-l)' "$log" > /dev/null; }

"$@" > "$log" 2>&1 &
pid=$!
painted=0
n=0
for i in $(seq 1 "$secs"); do
  kill -0 "$pid" 2> /dev/null || { echo "DroidDeck exited early"; cat "$log"; exit 1; }
  if [ "$painted" = 0 ]; then
    n="$(colours)"
    echo "screenshot ${i}: $n distinct colours"
    if [ "$n" -ge "$min_colours" ]; then painted=1; fi
  fi
  if [ "$painted" = 1 ] && found && tracking; then
    echo "DroidDeck found adb and is tracking devices after ${i}s"
    break
  fi
  sleep 1
done
kill -0 "$pid" 2> /dev/null || { echo "DroidDeck died"; cat "$log"; exit 1; }
kill "$pid"
cat "$log"
ok=1
if [ "$painted" = 0 ]; then
  echo "the window never painted a Flutter UI ($n colours, need $min_colours)"
  ok=0
fi
if ! found; then
  echo "DroidDeck did not find a working adb"
  ok=0
fi
if ! tracking; then
  echo "DroidDeck's device tracker never connected to the adb server"
  ok=0
fi
if grep -E 'error while loading shared libraries|cannot open shared object|undefined symbol' "$log"; then
  ok=0
fi
[ "$ok" = 1 ]
echo "Flutter UI painted ($n distinct colours), adb found, device tracker connected"
