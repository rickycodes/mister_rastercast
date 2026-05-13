# rastercast

[![ShellCheck](https://github.com/rickycodes/mister_rastercast/actions/workflows/shellcheck.yml/badge.svg?branch=main)](https://github.com/rickycodes/mister_rastercast/actions/workflows/shellcheck.yml?query=branch%3Amain)

What if [mister_plex](https://github.com/mrchrisster/mister_plex) without the plex?

rastercast is a lightweight video streaming path for MiSTerFPGA CRT setups.

It replaces the old Plex/XML workflow with a direct file-to-stream flow:

- the PC transcodes a local video file with `ffmpeg`
- the PC serves the stream over plain HTTP
- the MiSTer opens that stream with `mplayer`

This keeps the control path simple and avoids Plex, XML URLs, and SAM/Attract Mode dependencies.

## Current shape

- `bin/rastercast.sh` runs on the PC
- `mister/rastercast.sh` runs on the MiSTer

The implementation uses a continuous MPEG-TS stream with H.264 video and MP2 audio. The default video bitrate is 1000 kbps, matching the `maxVideoBitrate=1000` setting used by `mister_plex`; source FPS is preserved unless overridden.

## CRT target

The intended MiSTer framebuffer mode is:

```ini
video_mode=320,240,60
vga_scaler=1
fb_terminal=1
composite_sync=1
```

## Requirements

PC side:

- `ffmpeg`
- `python3`
- `yt-dlp` for YouTube inputs

MiSTer side:

- `mplayer` with framebuffer support

## Install on MiSTer

Copy the MiSTer launcher to the scripts folder:

```bash
scp mister/rastercast.sh root@mister:/media/fat/Scripts/rastercast.sh
ssh root@mister 'chmod +x /media/fat/Scripts/rastercast.sh'
```

The default MiSTer SSH login is usually `root` with password `1`; SSH will prompt if you have not configured keys.

## Usage

Serve a local video from the PC and launch playback on MiSTer:

```bash
bin/rastercast.sh /path/to/video.mkv
```

Or stream a YouTube URL through `yt-dlp`:

```bash
bin/rastercast.sh "https://www.youtube.com/watch?v=VIDEO_ID"
```

Direct HTTP(S) media URLs are passed to `ffmpeg` without `yt-dlp`:

```bash
bin/rastercast.sh "https://pc-host/video.mp4"
```

That command:

- creates a temporary MPEG-TS stream
- starts a local HTTP server
- prints the playback URL once the stream file has data
- deploys the MiSTer launcher if needed
- starts playback on `mister` over SSH

The first run can take a moment because ffmpeg has to produce initial stream data before playback starts.

By default, rastercast connects to `root@mister`. SSH will prompt normally if you have not configured keys.

Automatic playback uses an interactive SSH TTY so keyboard controls can reach `mplayer`. Press `space` or `p` to pause, and `q` to quit playback and stop the PC stream.

To serve only and copy the printed URL yourself:

```bash
RASTERCAST_MISTER_AUTO=0 bin/rastercast.sh /path/to/video.mkv
```

Then open that URL with the MiSTer launcher:

```bash
/media/fat/Scripts/rastercast.sh "http://pc-host:8090/stream.ts"
```

For automatic launch, rastercast checks whether `/media/fat/Scripts/rastercast.sh` exists and is executable on the MiSTer. If it is missing, rastercast deploys `mister/rastercast.sh` with `scp`, marks it executable, then starts playback.

If your MiSTer uses a different host, SSH user, script path, or deploy behavior:

```bash
RASTERCAST_MISTER_HOST=192.168.9.240 \
RASTERCAST_MISTER_USER=root \
RASTERCAST_MISTER_SCRIPT=/media/fat/Scripts/rastercast.sh \
RASTERCAST_MISTER_DEPLOY=auto \
RASTERCAST_MISTER_TTY=1 \
bin/rastercast.sh /path/to/video.mkv
```

If the PC chooses the wrong address for the printed URL, force it:

```bash
RASTERCAST_HOST_IP=192.168.9.237 bin/rastercast.sh /path/to/video.mkv
```

Optional tuning:

```bash
RASTERCAST_VIDEO_BITRATE=1000k bin/rastercast.sh /path/to/video.mkv
RASTERCAST_FPS=30000/1001 bin/rastercast.sh /path/to/video.mkv
RASTERCAST_VIDEO_FIT=cover bin/rastercast.sh "https://www.youtube.com/watch?v=VIDEO_ID"
RASTERCAST_VIDEO_FIT=contain bin/rastercast.sh "https://www.youtube.com/watch?v=VIDEO_ID"
RASTERCAST_YTDLP=1 bin/rastercast.sh "https://example.com/video-page"
RASTERCAST_YTDLP_FORMAT='best[height<=480]/best' bin/rastercast.sh "https://www.youtube.com/watch?v=VIDEO_ID"
RASTERCAST_YTDLP_COOKIES_FROM_BROWSER=firefox bin/rastercast.sh "https://www.youtube.com/watch?v=VIDEO_ID"
RASTERCAST_YTDLP_COOKIES=/path/to/cookies.txt bin/rastercast.sh "https://www.youtube.com/watch?v=VIDEO_ID"
RASTERCAST_YTDLP_JS_RUNTIME=node bin/rastercast.sh "https://www.youtube.com/watch?v=VIDEO_ID"
RASTERCAST_YTDLP_REMOTE_COMPONENTS=ejs:github bin/rastercast.sh "https://www.youtube.com/watch?v=VIDEO_ID"
```

`RASTERCAST_VIDEO_FIT=auto` is the default. It uses letterboxing for local files and direct media URLs, but center-crops `yt-dlp` inputs to fill the 320x240 CRT frame.

Age-restricted YouTube videos require authenticated cookies. Use `RASTERCAST_YTDLP_COOKIES_FROM_BROWSER` with a browser profile that is signed in to YouTube, or export cookies and pass the file with `RASTERCAST_YTDLP_COOKIES`.
If YouTube signature solving fails, set `RASTERCAST_YTDLP_JS_RUNTIME=node`; newer `yt-dlp` builds may also need `RASTERCAST_YTDLP_REMOTE_COMPONENTS=ejs:github`.

If MiSTer reports `Cache empty`, increase the player cache or reduce bitrate:

```bash
RASTERCAST_CACHE_KB=16384 RASTERCAST_CACHE_MIN=20 /media/fat/Scripts/rastercast.sh "http://pc-host:8090/stream.ts"
RASTERCAST_VIDEO_BITRATE=700k bin/rastercast.sh /path/to/video.mkv
```

## Notes

- Thanks to [mister_plex](https://github.com/mrchrisster/mister_plex) for the MiSTer playback and CRT setup guidance this project builds on.
- YouTube input relies on `yt-dlp`; keep it updated and only stream content you are authorized to access this way.
- MiSTer playback uses an 8192 KiB mplayer cache by default to avoid network starvation.
- The framebuffer centering issue from the current setup is still expected to need calibration work.
