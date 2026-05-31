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

The implementation uses a continuous MPEG-TS stream with H.264 video and MP2 audio. The default video bitrate is 700 kbps, which is a more conservative default for MiSTer playback; source FPS is preserved unless overridden.

## CRT target

The intended MiSTer framebuffer mode is:

```ini
video_mode=320,240,60
vga_scaler=1
fb_terminal=1
composite_sync=1
```

The MiSTer toggle helper in [`mister/rastercast-video-mode-toggle.sh`](/home/ricky/projects/rastercast/mister/rastercast-video-mode-toggle.sh) restores a baseline profile with `video_mode=0`, `vga_scaler=0`, `fb_terminal=0`, and `composite_sync=0` by default. Override those restore values with `RASTERCAST_DEFAULT_VIDEO_MODE`, `RASTERCAST_DEFAULT_VGA_SCALER`, `RASTERCAST_DEFAULT_FB_TERMINAL`, and `RASTERCAST_DEFAULT_COMPOSITE_SYNC` if your normal setup differs.

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

The repository includes ready-made scripts in [`examples/`](/home/ricky/projects/rastercast/examples).

- [`examples/local-file.sh`](/home/ricky/projects/rastercast/examples/local-file.sh): a single local file with higher-bitrate CRT-friendly defaults.
- [`examples/local-queue.sh`](/home/ricky/projects/rastercast/examples/local-queue.sh): a batch of local files with skip-on-missing enabled.
- [`examples/serve-only.sh`](/home/ricky/projects/rastercast/examples/serve-only.sh): start the stream without auto-launching MiSTer.
- [`examples/youtube-single.sh`](/home/ricky/projects/rastercast/examples/youtube-single.sh): one YouTube URL with the playlist-safe playback knobs.
- [`examples/youtube-playlist.sh`](/home/ricky/projects/rastercast/examples/youtube-playlist.sh): the shuffled playlist launcher.
- [`examples/debug-youtube-playlist.sh`](/home/ricky/projects/rastercast/examples/debug-youtube-playlist.sh): playlist launcher that prints the temp workdir for log inspection.
- [`examples/projectm-youtube.sh`](/home/ricky/projects/rastercast/examples/projectm-youtube.sh): YouTube playback rendered through projectM.

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

- `RASTERCAST_VIDEO_BITRATE` sets the video bitrate, default `700k`.
- `RASTERCAST_VIDEO_SIZE` sets the PC transcode size as `WIDTHxHEIGHT`, default `320x240`.
- `RASTERCAST_DISPLAY_ASPECT` sets the intended display shape, for example `4:3`; default `auto`.
- `RASTERCAST_FPS` optionally forces output FPS, for example `30000/1001`.
- `RASTERCAST_VIDEO_FIT` sets sizing: `auto`, `contain`, or `cover`; default `auto`.
- `RASTERCAST_VIDEO_EFFECT` sets comma-separated effect presets: `none`, `acid`, `trails`, `edges`, `ghost`, `matrix`, `rgbshift`, `negative`, `warp`, `wobble`, `feedback`, `scanwarp`, `avs-feedback`, `avs-grid`, `avs-crt`, or `avs-neon`; default `none`.
- `RASTERCAST_WATERMARK_TEXT` draws a text watermark in the lower right; default unset.
- `RASTERCAST_WATERMARK_IMAGE` overlays a watermark image in the lower right; PNG, WebP, or SVG recommended.
- `RASTERCAST_WATERMARK_X` sets the watermark X position as an ffmpeg expression; default is bottom-right.
- `RASTERCAST_WATERMARK_Y` sets the watermark Y position as an ffmpeg expression; default is bottom-right.
- `RASTERCAST_WATERMARK_SCALE` scales an image watermark from `0.0` to `1.0`; default `1`.
- `RASTERCAST_WATERMARK_SIZE` sets watermark font size; default `18`.
- `RASTERCAST_WATERMARK_MARGIN` sets watermark edge margin; default `8`.
- `RASTERCAST_WATERMARK_OPACITY` sets watermark opacity from `0.0` to `1.0`; default `0.65` for text and image watermarks.
- `RASTERCAST_VIDEO_SPEED` sets playback speed from `0.5` to `2.0`, default `1`.
- `RASTERCAST_VISUALIZER` replaces source video with an audio visualizer: `none`, `waves`, `spectrum`, `cqt`, `vectorscope`, `freqs`, `spatial`, `histogram`, `bits`, or `projectm`; default `none`.
- `RASTERCAST_PROJECTM` sets the ProjectM helper path when `RASTERCAST_VISUALIZER=projectm`; default `~/projects/rastercast-projectm/rastercast-projectm`.
- `RASTERCAST_PROJECTM_PRESETS` sets the ProjectM preset directory; default `/usr/share/projectM/presets`.
- `RASTERCAST_PROJECTM_PRESET` locks ProjectM to one preset file; default unset.
- `RASTERCAST_PROJECTM_FPS` sets the ProjectM helper frame rate; default is `RASTERCAST_FPS` or `30`.
- `RASTERCAST_PROJECTM_QUEUE_SIZE` sets ffmpeg queue size for ProjectM pipes; default `1024`.
- `RASTERCAST_AUDIO_EFFECT` sets an audio effect preset: `none`, `echo`, `robot`, `radio`, `deep`, or `chipmunk`; default `none`.

YouTube and other `yt-dlp` inputs:

- `RASTERCAST_YTDLP` controls URL handling: `auto`, `1`, or `0`; default `auto`.
- `RASTERCAST_YTDLP_FORMAT` sets the requested format; by default rastercast prefers progressive muxed HTTP video at 480p or lower.
- `RASTERCAST_YTDLP_COOKIES_FROM_BROWSER` passes browser cookies, for example `brave`, `firefox`, or `chrome`.
- `RASTERCAST_YTDLP_COOKIES` passes an exported cookies file.
- `RASTERCAST_YTDLP_JS_RUNTIME` enables a JavaScript runtime for extraction, for example `node`.
- `RASTERCAST_YTDLP_REMOTE_COMPONENTS` allows remote yt-dlp components, for example `ejs:github`.
- `RASTERCAST_YTDLP_PLAYLIST_ITEMS` limits YouTube playlist expansion, for example `1:10`.
- `RASTERCAST_QUEUE_SKIP_UNAVAILABLE` skips private/deleted queue items when set to `1`, default `0`.
- `RASTERCAST_LOOP` loops the queued input continuously when set to `1`, default `0`. `RASTERCAST_STREAM_LOOP` is accepted as an alias.
- `RASTERCAST_OFFSET` seeks into the queued input before playback starts, for example `90` or `00:01:30`.

MiSTer auto-launch:

- `RASTERCAST_MISTER_AUTO` enables automatic SSH launch: `1` or `0`; default `1`.
- `RASTERCAST_MISTER_HOST` sets the MiSTer host/IP, default `mister`.
- `RASTERCAST_MISTER_USER` sets the SSH user, default `root`.
- `RASTERCAST_MISTER_SCRIPT` sets the remote script path, default `/media/fat/Scripts/rastercast.sh`.
- `RASTERCAST_MISTER_DEPLOY` controls script deployment: `auto`, `always`, or `never`; default `auto`.
- `RASTERCAST_MISTER_TTY` controls whether playback gets an interactive TTY: `1` or `0`; default `1`.
- `RASTERCAST_MISTER_DETACH` starts MiSTer playback with `nohup` and lets SSH close immediately: `1` or `0`; default `0`.

MiSTer playback:

- `RASTERCAST_MPLAYER_VO` optionally sets the `mplayer` video output, for example `fbdev` or `fbdev2`.
- `RASTERCAST_CACHE_KB` sets the `mplayer` cache size in KiB, default `16384`.
- `RASTERCAST_CACHE_MIN` sets the percent cache fill before playback starts, default `20`.
- `RASTERCAST_MPLAYER_AUTOSYNC` optionally sets `mplayer -autosync`, for example `30`.
- `RASTERCAST_MPLAYER_FRAMEDROP` enables `mplayer -framedrop` when set to `1`, default `0`.

For YouTube playlist-style queues, rastercast defaults to `RASTERCAST_MPLAYER_AUTOSYNC=30` and `RASTERCAST_MPLAYER_FRAMEDROP=1` unless you set either variable yourself.

Optional tuning:

```bash
RASTERCAST_VIDEO_BITRATE=700k bin/rastercast.sh /path/to/video.mkv
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
RASTERCAST_WATERMARK_TEXT=MUCH bin/rastercast.sh "https://www.youtube.com/watch?v=VIDEO_ID"
RASTERCAST_WATERMARK_IMAGE=/path/to/logo.png bin/rastercast.sh "https://www.youtube.com/watch?v=VIDEO_ID"
RASTERCAST_WATERMARK_X=20 RASTERCAST_WATERMARK_Y=20 bin/rastercast.sh "https://www.youtube.com/watch?v=VIDEO_ID"
RASTERCAST_WATERMARK_SCALE=0.25 RASTERCAST_WATERMARK_IMAGE=/path/to/logo.png bin/rastercast.sh "https://www.youtube.com/watch?v=VIDEO_ID"
RASTERCAST_VIDEO_SPEED=0.75 bin/rastercast.sh "https://www.youtube.com/watch?v=VIDEO_ID"
RASTERCAST_VISUALIZER=spectrum bin/rastercast.sh "https://www.youtube.com/watch?v=VIDEO_ID"
RASTERCAST_VISUALIZER=vectorscope bin/rastercast.sh "https://www.youtube.com/watch?v=VIDEO_ID"
RASTERCAST_VISUALIZER=spatial bin/rastercast.sh "https://www.youtube.com/watch?v=VIDEO_ID"
RASTERCAST_VISUALIZER=bits bin/rastercast.sh "https://www.youtube.com/watch?v=VIDEO_ID"
RASTERCAST_VISUALIZER=projectm RASTERCAST_FPS=30 bin/rastercast.sh "https://www.youtube.com/watch?v=VIDEO_ID"
RASTERCAST_VISUALIZER=projectm RASTERCAST_PROJECTM_PRESETS=/usr/share/projectM/presets bin/rastercast.sh "https://www.youtube.com/watch?v=VIDEO_ID"
RASTERCAST_VISUALIZER=projectm RASTERCAST_PROJECTM_PRESET="/usr/share/projectM/presets/Geiss - Swirlie 2.milk" bin/rastercast.sh "https://www.youtube.com/watch?v=VIDEO_ID"
RASTERCAST_VISUALIZER=projectm RASTERCAST_PROJECTM_QUEUE_SIZE=2048 bin/rastercast.sh "https://www.youtube.com/watch?v=VIDEO_ID"
RASTERCAST_AUDIO_EFFECT=echo bin/rastercast.sh "https://www.youtube.com/watch?v=VIDEO_ID"
RASTERCAST_AUDIO_EFFECT=radio bin/rastercast.sh "https://www.youtube.com/watch?v=VIDEO_ID"
RASTERCAST_YTDLP=1 bin/rastercast.sh "https://example.com/video-page"
RASTERCAST_YTDLP_FORMAT='best[height<=480][protocol^=http][vcodec!=none][acodec!=none]/best[protocol^=http][vcodec!=none][acodec!=none]' bin/rastercast.sh "https://www.youtube.com/watch?v=VIDEO_ID"
RASTERCAST_YTDLP_COOKIES_FROM_BROWSER=firefox bin/rastercast.sh "https://www.youtube.com/watch?v=VIDEO_ID"
RASTERCAST_YTDLP_COOKIES=/path/to/cookies.txt bin/rastercast.sh "https://www.youtube.com/watch?v=VIDEO_ID"
RASTERCAST_YTDLP_JS_RUNTIME=node bin/rastercast.sh "https://www.youtube.com/watch?v=VIDEO_ID"
RASTERCAST_YTDLP_REMOTE_COMPONENTS=ejs:github bin/rastercast.sh "https://www.youtube.com/watch?v=VIDEO_ID"
bin/rastercast.sh "https://www.youtube.com/playlist?list=PLAYLIST_ID"
RASTERCAST_YTDLP_PLAYLIST_ITEMS=1:5 bin/rastercast.sh "https://www.youtube.com/playlist?list=PLAYLIST_ID"
RASTERCAST_QUEUE_SKIP_UNAVAILABLE=1 bin/rastercast.sh "https://www.youtube.com/playlist?list=PLAYLIST_ID"
RASTERCAST_LOOP=1 bin/rastercast.sh /path/to/video.mkv
RASTERCAST_LOOP=1 bin/rastercast.sh "https://www.youtube.com/watch?v=VIDEO_ID"
RASTERCAST_LOOP=1 bin/rastercast.sh "https://www.youtube.com/playlist?list=PLAYLIST_ID"
RASTERCAST_OFFSET=90 bin/rastercast.sh /path/to/video.mkv
RASTERCAST_OFFSET=00:01:30 bin/rastercast.sh "https://www.youtube.com/playlist?list=PLAYLIST_ID"
```

`RASTERCAST_VIDEO_FIT=auto` is the default. It uses letterboxing for local files and direct media URLs, but center-crops `yt-dlp` inputs to fill the 320x240 CRT frame.
`RASTERCAST_VIDEO_SIZE` changes the PC-side stream size. MiSTer video mode and BVM support still need to match the resolution you choose. `RASTERCAST_DISPLAY_ASPECT=4:3` can correct geometry when a wide 240p mode like `512x240` is displayed as a 4:3 raster.
`RASTERCAST_VIDEO_EFFECT` defaults to `none`; available effects are `acid`, `trails`, `edges`, `ghost`, `matrix`, `rgbshift`, `negative`, `warp`, `wobble`, `feedback`, `scanwarp`, `avs-feedback`, `avs-grid`, `avs-crt`, and `avs-neon`. Multiple effects can be layered with commas; order matters.
`RASTERCAST_VIDEO_SPEED` changes video and audio speed together. `RASTERCAST_AUDIO_EFFECT` can add `echo`, `robot`, `radio`, `deep`, or `chipmunk` processing.
`RASTERCAST_VISUALIZER` replaces the source video with generated visuals from the audio stream. The built-in ffmpeg visualizers run inside ffmpeg. `RASTERCAST_VISUALIZER=projectm` uses the external `rastercast-projectm` helper to render MilkDrop/projectM frames from raw PCM and feed them back into the stream.

Age-restricted YouTube videos require authenticated cookies. Use `RASTERCAST_YTDLP_COOKIES_FROM_BROWSER` with a browser profile that is signed in to YouTube, or export cookies and pass the file with `RASTERCAST_YTDLP_COOKIES`.
If YouTube signature solving fails, set `RASTERCAST_YTDLP_JS_RUNTIME=node`; newer `yt-dlp` builds may also need `RASTERCAST_YTDLP_REMOTE_COMPONENTS=ejs:github`.
Queued YouTube playback resolves media URLs before starting ffmpeg and expects one progressive muxed media URL per video. HLS manifests and separate video/audio URLs are rejected because they are unreliable inside ffmpeg's concat demuxer. If needed, override the default format with `RASTERCAST_YTDLP_FORMAT`. Use `RASTERCAST_QUEUE_SKIP_UNAVAILABLE=1` to skip private or deleted queue entries.
`RASTERCAST_OFFSET` applies to the queued concat input, so it works across single files, single URLs, and playlists.

If MiSTer reports `Cache empty`, increase the player cache or reduce bitrate:

```bash
RASTERCAST_CACHE_KB=16384 RASTERCAST_CACHE_MIN=20 /media/fat/Scripts/rastercast.sh "http://pc-host:8090/stream.ts"
RASTERCAST_CACHE_KB=2048 RASTERCAST_CACHE_MIN=1 RASTERCAST_MPLAYER_AUTOSYNC=30 RASTERCAST_MPLAYER_FRAMEDROP=1 bin/rastercast.sh "https://www.youtube.com/watch?v=VIDEO_ID"
RASTERCAST_VIDEO_BITRATE=700k bin/rastercast.sh /path/to/video.mkv
```

## Notes

- Thanks to [mister_plex](https://github.com/mrchrisster/mister_plex) for the MiSTer playback and CRT setup guidance this project builds on.
- YouTube input relies on `yt-dlp`; keep it updated and only stream content you are authorized to access this way.
- MiSTer playback uses a 16384 KiB mplayer cache by default to avoid network starvation.
- The framebuffer centering issue from the current setup is still expected to need calibration work.
