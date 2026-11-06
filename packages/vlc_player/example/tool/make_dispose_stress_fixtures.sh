#!/bin/bash
# Makes dispose_stress_test.dart's fixtures, each only if it isn't there yet: delete one to make it again. A white box
# moving over a solid colour for 4 s, so the files are tiny while every picture is whole: stress_2160p60.mp4 at
# 3840x2160 and 60 fps, the largest picture and the most copies a second the Darwin renderer's output makes for a
# common film; stress_1080p30.mp4 at 1920x1080 and 30 fps, the other size a change of source moves between.
set -euo pipefail
out=$(cd "$(dirname "$0")/.." && pwd)/assets/format_fixtures
[ -f "$out/stress_2160p60.mp4" ] || ffmpeg -hide_banner -loglevel error -y \
  -f lavfi -i "color=c=0x305070:s=3840x2160:r=60:d=4,drawbox=x='mod(t*600,3600)':y=900:w=240:h=240:color=white:t=fill" \
  -c:v libx264 -preset veryfast -profile:v high -level 5.2 -pix_fmt yuv420p -g 60 -crf 30 -movflags +faststart \
  "$out/stress_2160p60.mp4"
[ -f "$out/stress_1080p30.mp4" ] || ffmpeg -hide_banner -loglevel error -y \
  -f lavfi -i "color=c=0x705030:s=1920x1080:r=30:d=4,drawbox=x='mod(t*300,1800)':y=420:w=120:h=120:color=white:t=fill" \
  -c:v libx264 -preset veryfast -profile:v high -level 4.0 -pix_fmt yuv420p -g 30 -crf 30 -movflags +faststart \
  "$out/stress_1080p30.mp4"
