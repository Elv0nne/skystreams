#!/bin/bash
# Makes keep_picture_test.dart's fixtures, each only if it isn't there yet: delete one to make it again. ffmpeg's output
# differs a little between versions, and a fixture rewritten for nothing is a binary diff for nothing.
# film.mp4: 24 s at 320x180, the first 2 s solid magenta and the rest green with grain, keyframes every second, also as
# 2 s HLS segments. A capture that is mostly magenta shows the film's opening, which a reopen that keeps its picture
# must never show. film_4x3.mp4: the same at 240x180, for a reopen whose new picture has another shape.
set -euo pipefail
out=$(cd "$(dirname "$0")/.." && pwd)/assets/format_fixtures/keep_picture
mkdir -p "$out/hls"
film() {
  ffmpeg -hide_banner -loglevel error -y \
    -f lavfi -i "color=c=0xFF00FF:s=$1:r=25:d=2" \
    -f lavfi -i "color=c=0x00A000:s=$1:r=25:d=22" \
    -filter_complex "[1]noise=alls=20:allf=t[g];[0][g]concat=n=2:v=1:a=0[v]" -map "[v]" \
    -c:v libx264 -preset veryfast -profile:v baseline -pix_fmt yuv420p -g 25 -keyint_min 25 -sc_threshold 0 \
    -b:v 300k -maxrate 300k -bufsize 300k -movflags +faststart "$2"
}
[ -f "$out/film.mp4" ] || film 320x180 "$out/film.mp4"
[ -f "$out/hls/index.m3u8" ] || ffmpeg -hide_banner -loglevel error -y -i "$out/film.mp4" -c copy -f hls -hls_time 2 \
  -hls_playlist_type vod -hls_segment_filename "$out/hls/seg%02d.ts" "$out/hls/index.m3u8"
[ -f "$out/film_4x3.mp4" ] || film 240x180 "$out/film_4x3.mp4"
