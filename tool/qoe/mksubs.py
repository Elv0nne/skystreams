# Writes a timed SRT and a segmented WebVTT rendition (one cue every 4 s) for the test media.
import os, sys

def ts(t, sep):
    h, r = divmod(t, 3600); m, s = divmod(r, 60)
    return f"{int(h):02d}:{int(m):02d}:{int(s):02d}{sep}{int(round((s - int(s)) * 1000)):03d}"

def cues(lang, duration):
    for n, start in enumerate(range(0, duration, 4)):
        yield n + 1, start, start + 3, f"{lang.upper()} cue {n + 1} at {start // 60:02d}:{start % 60:02d}"

def main(out_dir, lang, duration=600, seg=6):
    duration = int(duration)
    with open(os.path.join(out_dir, f"subs_{lang}.srt"), "w") as f:
        for n, a, b, text in cues(lang, duration):
            f.write(f"{n}\n{ts(a, ',')} --> {ts(b, ',')}\n{text}\n\n")
    vtt_dir = os.path.join(out_dir, "hls", f"sub_{lang}")
    os.makedirs(vtt_dir, exist_ok=True)
    playlist = ["#EXTM3U", "#EXT-X-VERSION:3", f"#EXT-X-TARGETDURATION:{seg}", "#EXT-X-MEDIA-SEQUENCE:0", "#EXT-X-PLAYLIST-TYPE:VOD"]
    all_cues = list(cues(lang, duration))
    for i, start in enumerate(range(0, duration, seg)):
        name = f"seg{i:03d}.vtt"
        with open(os.path.join(vtt_dir, name), "w") as f:
            f.write("WEBVTT\nX-TIMESTAMP-MAP=MPEGTS:126000,LOCAL:00:00:00.000\n\n")
            for n, a, b, text in all_cues:
                if a < start + seg and b > start:
                    f.write(f"{n}\n{ts(a, '.')} --> {ts(b, '.')}\n{text}\n\n")
        playlist += [f"#EXTINF:{seg:.6f},", name]
    playlist.append("#EXT-X-ENDLIST")
    with open(os.path.join(vtt_dir, "index.m3u8"), "w") as f:
        f.write("\n".join(playlist) + "\n")

if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
