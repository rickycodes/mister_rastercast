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

### Local Video

Serve a local video from the PC and launch playback on MiSTer:

```bash
bin/rastercast.sh /path/to/video.mkv
```

### Local Queue

Queue multiple videos for back-to-back playback:

```bash
bin/rastercast.sh /path/to/one.mkv /path/to/two.mkv /path/to/three.mkv
```

### Shell Expansion

Queue a directory of episodes with shell expansion:

```bash
bin/rastercast.sh /path/to/season/*.mkv
```

### Shell Array

If paths contain spaces, use a shell array:

```bash
episodes=(/path/to/season/*.mkv)
bin/rastercast.sh "${episodes[@]}"
```

### YouTube Video

Stream a YouTube URL through `yt-dlp`:

```bash
bin/rastercast.sh "https://www.youtube.com/watch?v=VIDEO_ID"
```

### YouTube Queue

Queue multiple YouTube URLs:

```bash
bin/rastercast.sh "https://www.youtube.com/watch?v=VIDEO_ID_1" "https://www.youtube.com/watch?v=VIDEO_ID_2"
```

### YouTube Playlist

Expand a YouTube playlist URL:

```bash
bin/rastercast.sh "https://www.youtube.com/playlist?list=PLAYLIST_ID"
RASTERCAST_YTDLP_PLAYLIST_ITEMS=1:5 bin/rastercast.sh "https://www.youtube.com/playlist?list=PLAYLIST_ID"
```

### Direct Media URL

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

## Options

PC streaming:

- `RASTERCAST_BIND_ADDR` sets the HTTP bind address, default `0.0.0.0`.
- `RASTERCAST_HOST_IP` sets the host/IP printed in the playback URL; auto-detected by default.
- `RASTERCAST_PORT` sets the HTTP port, default `8090`.
- `RASTERCAST_STARTUP_TIMEOUT` sets how long to wait for initial stream data, default `30`.

Video output:

- `RASTERCAST_VIDEO_BITRATE` sets the video bitrate, default `1000k`.
- `RASTERCAST_VIDEO_SIZE` sets the PC transcode size as `WIDTHxHEIGHT`, default `320x240`.
- `RASTERCAST_DISPLAY_ASPECT` sets the intended display shape, for example `4:3`; default `auto`.
- `RASTERCAST_FPS` optionally forces output FPS, for example `30000/1001`.
- `RASTERCAST_VIDEO_FIT` sets sizing: `auto`, `contain`, or `cover`; default `auto`.
- `RASTERCAST_VIDEO_EFFECT` sets comma-separated effect presets: `none`, `acid`, `trails`, `edges`, `ghost`, `matrix`, `rgbshift`, `negative`, `warp`, `wobble`, `feedback`, or `scanwarp`; default `none`.
- `RASTERCAST_VIDEO_SPEED` sets playback speed from `0.5` to `2.0`, default `1`.
- `RASTERCAST_AUDIO_EFFECT` sets an audio effect preset: `none`, `echo`, `robot`, `radio`, `deep`, or `chipmunk`; default `none`.

YouTube and other `yt-dlp` inputs:

- `RASTERCAST_YTDLP` controls URL handling: `auto`, `1`, or `0`; default `auto`.
- `RASTERCAST_YTDLP_FORMAT` sets the requested format, default `best[height<=480]/best`.
- `RASTERCAST_YTDLP_COOKIES_FROM_BROWSER` passes browser cookies, for example `brave`, `firefox`, or `chrome`.
- `RASTERCAST_YTDLP_COOKIES` passes an exported cookies file.
- `RASTERCAST_YTDLP_JS_RUNTIME` enables a JavaScript runtime for extraction, for example `node`.
- `RASTERCAST_YTDLP_REMOTE_COMPONENTS` allows remote yt-dlp components, for example `ejs:github`.
- `RASTERCAST_YTDLP_PLAYLIST_ITEMS` limits YouTube playlist expansion, for example `1:10`.
- `RASTERCAST_QUEUE_SKIP_UNAVAILABLE` skips private/deleted queue items when set to `1`, default `0`.

MiSTer auto-launch:

- `RASTERCAST_MISTER_AUTO` enables automatic SSH launch: `1` or `0`; default `1`.
- `RASTERCAST_MISTER_HOST` sets the MiSTer host/IP, default `mister`.
- `RASTERCAST_MISTER_USER` sets the SSH user, default `root`.
- `RASTERCAST_MISTER_SCRIPT` sets the remote script path, default `/media/fat/Scripts/rastercast.sh`.
- `RASTERCAST_MISTER_DEPLOY` controls script deployment: `auto`, `always`, or `never`; default `auto`.
- `RASTERCAST_MISTER_TTY` controls whether playback gets an interactive TTY: `1` or `0`; default `1`.

MiSTer playback:

- `RASTERCAST_MPLAYER_VO` optionally sets the `mplayer` video output, for example `fbdev` or `fbdev2`.
- `RASTERCAST_CACHE_KB` sets the `mplayer` cache size in KiB, default `8192`.
- `RASTERCAST_CACHE_MIN` sets the percent cache fill before playback starts, default `10`.

Optional tuning:

```bash
RASTERCAST_VIDEO_BITRATE=1000k bin/rastercast.sh /path/to/video.mkv
RASTERCAST_VIDEO_SIZE=640x480 RASTERCAST_VIDEO_BITRATE=2500k bin/rastercast.sh /path/to/video.mkv
RASTERCAST_VIDEO_SIZE=512x240 RASTERCAST_DISPLAY_ASPECT=4:3 bin/rastercast.sh /path/to/video.mkv
RASTERCAST_FPS=30000/1001 bin/rastercast.sh /path/to/video.mkv
RASTERCAST_VIDEO_FIT=cover bin/rastercast.sh "https://www.youtube.com/watch?v=VIDEO_ID"
RASTERCAST_VIDEO_FIT=contain bin/rastercast.sh "https://www.youtube.com/watch?v=VIDEO_ID"
RASTERCAST_VIDEO_EFFECT=acid bin/rastercast.sh "https://www.youtube.com/watch?v=VIDEO_ID"
RASTERCAST_VIDEO_EFFECT=trails bin/rastercast.sh "https://www.youtube.com/watch?v=VIDEO_ID"
RASTERCAST_VIDEO_EFFECT=matrix bin/rastercast.sh "https://www.youtube.com/watch?v=VIDEO_ID"
RASTERCAST_VIDEO_EFFECT=wobble bin/rastercast.sh "https://www.youtube.com/watch?v=VIDEO_ID"
RASTERCAST_VIDEO_EFFECT=scanwarp bin/rastercast.sh "https://www.youtube.com/watch?v=VIDEO_ID"
RASTERCAST_VIDEO_EFFECT=matrix,scanwarp,trails bin/rastercast.sh "https://www.youtube.com/watch?v=VIDEO_ID"
RASTERCAST_VIDEO_SPEED=0.75 bin/rastercast.sh "https://www.youtube.com/watch?v=VIDEO_ID"
RASTERCAST_AUDIO_EFFECT=echo bin/rastercast.sh "https://www.youtube.com/watch?v=VIDEO_ID"
RASTERCAST_AUDIO_EFFECT=radio bin/rastercast.sh "https://www.youtube.com/watch?v=VIDEO_ID"
RASTERCAST_YTDLP=1 bin/rastercast.sh "https://example.com/video-page"
RASTERCAST_YTDLP_FORMAT='best[height<=480]/best' bin/rastercast.sh "https://www.youtube.com/watch?v=VIDEO_ID"
RASTERCAST_YTDLP_COOKIES_FROM_BROWSER=firefox bin/rastercast.sh "https://www.youtube.com/watch?v=VIDEO_ID"
RASTERCAST_YTDLP_COOKIES=/path/to/cookies.txt bin/rastercast.sh "https://www.youtube.com/watch?v=VIDEO_ID"
RASTERCAST_YTDLP_JS_RUNTIME=node bin/rastercast.sh "https://www.youtube.com/watch?v=VIDEO_ID"
RASTERCAST_YTDLP_REMOTE_COMPONENTS=ejs:github bin/rastercast.sh "https://www.youtube.com/watch?v=VIDEO_ID"
bin/rastercast.sh "https://www.youtube.com/playlist?list=PLAYLIST_ID"
RASTERCAST_YTDLP_PLAYLIST_ITEMS=1:5 bin/rastercast.sh "https://www.youtube.com/playlist?list=PLAYLIST_ID"
RASTERCAST_QUEUE_SKIP_UNAVAILABLE=1 bin/rastercast.sh "https://www.youtube.com/playlist?list=PLAYLIST_ID"
```

`RASTERCAST_VIDEO_FIT=auto` is the default. It uses letterboxing for local files and direct media URLs, but center-crops `yt-dlp` inputs to fill the 320x240 CRT frame.
`RASTERCAST_VIDEO_SIZE` changes the PC-side stream size. MiSTer video mode and BVM support still need to match the resolution you choose. `RASTERCAST_DISPLAY_ASPECT=4:3` can correct geometry when a wide 240p mode like `512x240` is displayed as a 4:3 raster.
`RASTERCAST_VIDEO_EFFECT` defaults to `none`; available effects are `acid`, `trails`, `edges`, `ghost`, `matrix`, `rgbshift`, `negative`, `warp`, `wobble`, `feedback`, and `scanwarp`. Multiple effects can be layered with commas; order matters.
`RASTERCAST_VIDEO_SPEED` changes video and audio speed together. `RASTERCAST_AUDIO_EFFECT` can add `echo`, `robot`, `radio`, `deep`, or `chipmunk` processing.

Age-restricted YouTube videos require authenticated cookies. Use `RASTERCAST_YTDLP_COOKIES_FROM_BROWSER` with a browser profile that is signed in to YouTube, or export cookies and pass the file with `RASTERCAST_YTDLP_COOKIES`.
If YouTube signature solving fails, set `RASTERCAST_YTDLP_JS_RUNTIME=node`; newer `yt-dlp` builds may also need `RASTERCAST_YTDLP_REMOTE_COMPONENTS=ejs:github`.
Queued YouTube playback resolves media URLs before starting ffmpeg and expects one muxed media URL per video. If yt-dlp returns separate video and audio URLs, use a muxed format such as `RASTERCAST_YTDLP_FORMAT='best[height<=480][vcodec!=none][acodec!=none]/best[vcodec!=none][acodec!=none]'`. Use `RASTERCAST_QUEUE_SKIP_UNAVAILABLE=1` to skip private or deleted queue entries.

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
