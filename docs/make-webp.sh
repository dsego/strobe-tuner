#!/usr/bin/env sh
# Turn a screen recording into a looping animated WebP for the README, like docs/demo.webp. GitHub shows an
# attached video inside a bordered card, an image plays and loops without one.
#
# The recording is cropped to the window (the black area a window recording leaves around it is detected and cut
# off), scaled down, given transparent rounded corners and encoded without sound. Needs ffmpeg and img2webp,
# `brew install ffmpeg webp`.
#
#   docs/make-webp.sh <recording> [output]    output defaults to docs/demo.webp
#
#   WIDTH=<pixels>     output width, defaults to 600, twice the 300 the README shows it at
#   FPS=<rate>         frame rate, defaults to 25
#   QUALITY=<0-100>    lossy quality, defaults to 70, lower for a smaller file
#   RADIUS=<pixels>    corner radius in output pixels, defaults to 20, 0 for square corners
#   CROP=<w:h:x:y>     crop in recording pixels, defaults to "auto", "none" to keep the whole frame
#   METHOD=<0-6>       compression method, defaults to 4, 6 is a little smaller and several times slower

set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)
WIDTH=${WIDTH:-600}
FPS=${FPS:-25}
QUALITY=${QUALITY:-70}
RADIUS=${RADIUS:-20}
CROP=${CROP:-auto}
METHOD=${METHOD:-4}

if [ $# -lt 1 ] || [ ! -f "$1" ]; then
    echo "Usage: $0 <recording> [output]"
    exit 1
fi
RECORDING=$1
OUTPUT=${2:-$ROOT/docs/demo.webp}

# cropdetect keeps widening its box as it goes, the last one covers everything that was ever not black
if [ "$CROP" = auto ]; then
    echo "Detecting the window area"
    CROP=$(ffmpeg -hide_banner -i "$RECORDING" -an -vf "fps=2,cropdetect=limit=16:round=2" -f null - 2>&1 \
        | grep -o "crop=[0-9:]*" | tail -1 | cut -d= -f2)
    if [ -z "$CROP" ]; then
        echo "No crop detected, pass CROP=w:h:x:y or CROP=none"
        exit 1
    fi
    echo "Crop $CROP"
fi

FILTERS="fps=$FPS,scale=$WIDTH:-2:flags=lanczos"
if [ "$CROP" != none ]; then
    FILTERS="crop=$CROP,$FILTERS"
fi
# Alpha falls from 1 to 0 over the pixel at the corner's edge, the distance is measured from the corner's centre
if [ "$RADIUS" -gt 0 ]; then
    CORNER="hypot(X-clip(X,$RADIUS,W-1-$RADIUS),Y-clip(Y,$RADIUS,H-1-$RADIUS))"
    FILTERS="$FILTERS,format=rgba,geq=r='r(X,Y)':g='g(X,Y)':b='b(X,Y)':a='255*clip($RADIUS.5-$CORNER,0,1)'"
fi

# The frames are left in the temporary folder, the system clears it
FRAMES=$(mktemp -d "${TMPDIR:-/tmp}/make-webp.XXXXXX")
echo "Extracting frames to $FRAMES"
ffmpeg -v error -y -i "$RECORDING" -an -vf "$FILTERS" "$FRAMES/f%05d.png"

echo "Encoding $(ls "$FRAMES" | wc -l | tr -d ' ') frames"
img2webp -loop 0 -lossy -q "$QUALITY" -m "$METHOD" -d $((1000 / FPS)) "$FRAMES"/f*.png -o "$OUTPUT" > /dev/null

echo "$OUTPUT, $(($(wc -c < "$OUTPUT") / 1024)) KB"
