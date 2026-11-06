#!/bin/bash
# live.sh KIND SECONDS MEDIA_DIR — a real-time live HLS feed for the QoE suite; the caller stops it.
#   hls       -> MEDIA_DIR/live/index.m3u8, 4 s segments, a 24 s sliding window, with program dates
#   hls-long  -> the same with a 2-minute window
# (The live TS channel needs no feed: server.py encodes one per connection at /live.ts.)
set -euo pipefail
KIND=$1; SECS=$2; M=$3
cd "$M"
ENC=h264_videotoolbox
ffmpeg -hide_banner -encoders 2>/dev/null | grep -q h264_videotoolbox || ENC=libx264
SRC=(-re -f lavfi -i "testsrc2=size=1280x720:rate=25,noise=alls=10:allf=t" -re -f lavfi -i "sine=frequency=440:sample_rate=48000")
OUT=(-c:v $ENC -b:v 3M -g 50 -force_key_frames "expr:gte(t,n_forced*2)" -c:a aac -b:a 128k -t "$SECS")
case $KIND in
  hls|hls-long)
    SIZE=$([ "$KIND" = hls ] && echo 6 || echo 30)
    rm -rf live && mkdir -p live
    # temp_file: the playlist is written aside and renamed, so a reader never gets half of one.
    exec ffmpeg -hide_banner -loglevel error "${SRC[@]}" "${OUT[@]}" -f hls -hls_time 4 -hls_list_size "$SIZE" \
      -hls_flags delete_segments+program_date_time+temp_file -hls_segment_filename live/seg%05d.ts live/index.m3u8 ;;
  *) echo "unknown kind $KIND" >&2; exit 2 ;;
esac
