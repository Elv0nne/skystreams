#!/bin/bash
# mkmedia.sh MEDIA_DIR — the QoE suite's media, generated so nothing binary is committed (about 10 minutes).
#   prog.mp4 / prog.mkv : 10 min, 1080p24 noisy test pattern (compresses like film), 5 Mbit/s, 10 s GOP,
#                         English (440 Hz) and Japanese (880 Hz) audio; the MKV adds English and Spanish SRT.
#   hls/master.m3u8     : 1080/720/480 ladder, 6 s segments, separate audio renditions, WebVTT subtitles.
#   big4k.mp4           : 3 min, 2160p24, 25 Mbit/s: the "4K-class" file for the buffer rule.
set -euo pipefail
M="$1"; D=600; HERE="$(cd "$(dirname "$0")" && pwd)"
# ffmpeg's HLS muxer writes into these, and doesn't make them.
mkdir -p "$M/hls/v1080" "$M/hls/v720" "$M/hls/v480" && cd "$M"
ENC=h264_videotoolbox
ffmpeg -hide_banner -encoders 2>/dev/null | grep -q h264_videotoolbox || ENC=libx264
python3 "$HERE/mksubs.py" "$M" eng
python3 "$HERE/mksubs.py" "$M" spa
SRC="testsrc2=size=1920x1080:rate=24:duration=$D"
NOISE="noise=alls=14:allf=t+u"
A1="sine=frequency=440:sample_rate=48000:duration=$D"
A2="sine=frequency=880:sample_rate=48000:duration=$D"
ffmpeg -hide_banner -loglevel error -y -f lavfi -i "$SRC" -f lavfi -i "$A1" -f lavfi -i "$A2" \
  -vf "$NOISE" -c:v $ENC -b:v 5M -maxrate 6M -bufsize 10M -g 240 -profile:v high \
  -c:a aac -b:a 128k -ac 2 -map 0:v -map 1:a -map 2:a \
  -metadata:s:a:0 language=eng -metadata:s:a:0 title=English -metadata:s:a:1 language=jpn -metadata:s:a:1 title=Japanese \
  -movflags +faststart prog.mp4
ffmpeg -hide_banner -loglevel error -y -i prog.mp4 -i subs_eng.srt -i subs_spa.srt -map 0 -map 1 -map 2 -c copy -c:s srt \
  -metadata:s:s:0 language=eng -metadata:s:s:0 title=English -metadata:s:s:1 language=spa -metadata:s:s:1 title=Spanish prog.mkv
ffmpeg -hide_banner -loglevel error -y -f lavfi -i "$SRC" \
  -filter_complex "[0:v]$NOISE,split=3[a][b][c];[b]scale=1280:720[b2];[c]scale=854:480[c2]" \
  -map "[a]" -c:v $ENC -b:v 5M -maxrate 6M -bufsize 10M -g 48 -force_key_frames "expr:gte(t,n_forced*2)" -profile:v high \
    -f hls -hls_time 6 -hls_playlist_type vod -hls_segment_filename hls/v1080/seg%03d.ts hls/v1080/index.m3u8 \
  -map "[b2]" -c:v $ENC -b:v 2800k -maxrate 3400k -bufsize 6M -g 48 -force_key_frames "expr:gte(t,n_forced*2)" -profile:v high \
    -f hls -hls_time 6 -hls_playlist_type vod -hls_segment_filename hls/v720/seg%03d.ts hls/v720/index.m3u8 \
  -map "[c2]" -c:v $ENC -b:v 1200k -maxrate 1500k -bufsize 3M -g 48 -force_key_frames "expr:gte(t,n_forced*2)" -profile:v main \
    -f hls -hls_time 6 -hls_playlist_type vod -hls_segment_filename hls/v480/seg%03d.ts hls/v480/index.m3u8
for lang in eng jpn; do
  src=$([ $lang = eng ] && echo "$A1" || echo "$A2")
  mkdir -p hls/aud_$lang
  ffmpeg -hide_banner -loglevel error -y -f lavfi -i "$src" -c:a aac -b:a 128k -ac 2 \
    -f hls -hls_time 6 -hls_playlist_type vod -hls_segment_filename hls/aud_$lang/seg%03d.ts hls/aud_$lang/index.m3u8
done
cat > hls/master.m3u8 <<'M3U'
#EXTM3U
#EXT-X-VERSION:4
#EXT-X-INDEPENDENT-SEGMENTS
#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aud",NAME="English",LANGUAGE="en",DEFAULT=YES,AUTOSELECT=YES,CHANNELS="2",URI="aud_eng/index.m3u8"
#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aud",NAME="Japanese",LANGUAGE="ja",DEFAULT=NO,AUTOSELECT=YES,CHANNELS="2",URI="aud_jpn/index.m3u8"
#EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID="subs",NAME="English",LANGUAGE="en",DEFAULT=NO,AUTOSELECT=YES,URI="sub_eng/index.m3u8"
#EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID="subs",NAME="Spanish",LANGUAGE="es",DEFAULT=NO,AUTOSELECT=YES,URI="sub_spa/index.m3u8"
#EXT-X-STREAM-INF:BANDWIDTH=6400000,AVERAGE-BANDWIDTH=5300000,RESOLUTION=1920x1080,CODECS="avc1.640028,mp4a.40.2",AUDIO="aud",SUBTITLES="subs"
v1080/index.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=3600000,AVERAGE-BANDWIDTH=3000000,RESOLUTION=1280x720,CODECS="avc1.64001f,mp4a.40.2",AUDIO="aud",SUBTITLES="subs"
v720/index.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=1700000,AVERAGE-BANDWIDTH=1350000,RESOLUTION=854x480,CODECS="avc1.4d401f,mp4a.40.2",AUDIO="aud",SUBTITLES="subs"
v480/index.m3u8
M3U
ffmpeg -hide_banner -loglevel error -y -f lavfi -i "testsrc2=size=3840x2160:rate=24:duration=180" -f lavfi -i "$A1" \
  -vf "noise=alls=10:allf=t" -c:v $ENC -b:v 25M -maxrate 30M -bufsize 50M -g 240 -profile:v high \
  -c:a aac -b:a 128k -ac 2 -t 180 -movflags +faststart big4k.mp4
echo done
