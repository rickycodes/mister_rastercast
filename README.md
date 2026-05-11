# rastercast

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

MiSTer side:

- `mplayer` with framebuffer support

## Usage

Serve a local video from the PC:

```bash
bin/rastercast.sh /path/to/video.mkv
```

That command:

- creates a temporary MPEG-TS stream
- starts a local HTTP server
- prints the playback URL once the stream file has data

The first run can take a moment because ffmpeg has to produce initial stream data before playback starts.

Then copy that URL to the MiSTer launcher, or use the launcher directly on the MiSTer:

```bash
/media/fat/Scripts/rastercast.sh "http://pc-host:8090/stream.ts"
```

If the PC chooses the wrong address for the printed URL, force it:

```bash
RASTERCAST_HOST_IP=192.168.9.237 bin/rastercast.sh /path/to/video.mkv
```

Optional tuning:

```bash
RASTERCAST_VIDEO_BITRATE=1000k bin/rastercast.sh /path/to/video.mkv
RASTERCAST_FPS=30000/1001 bin/rastercast.sh /path/to/video.mkv
```

If MiSTer reports `Cache empty`, increase the player cache or reduce bitrate:

```bash
RASTERCAST_CACHE_KB=16384 RASTERCAST_CACHE_MIN=20 /media/fat/Scripts/rastercast.sh "http://pc-host:8090/stream.ts"
RASTERCAST_VIDEO_BITRATE=700k bin/rastercast.sh /path/to/video.mkv
```

## Notes

- Thanks to [mister_plex](https://github.com/mrchrisster/mister_plex) for the MiSTer playback and CRT setup guidance this project builds on.
- MiSTer playback uses an 8192 KiB mplayer cache by default to avoid network starvation.
- The framebuffer centering issue from the current setup is still expected to need calibration work.
