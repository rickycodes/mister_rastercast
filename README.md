# rastercast

What if [mister_plex](https://github.com/mrchrisster/mister_plex) without the plex?

Rastercast is a lightweight video streaming path for MiSTerFPGA CRT setups.

It replaces the old Plex/XML workflow with a direct file-to-stream flow:

- the PC transcodes a local video file with `ffmpeg`
- the PC serves the stream over plain HTTP
- the MiSTer opens that stream with `mplayer`

This keeps the control path simple and avoids Plex, XML URLs, and SAM/Attract Mode dependencies.

## Current shape

- `bin/rastercast.sh` runs on the PC
- `mister/rastercast.sh` runs on the MiSTer

The default implementation uses a continuous MPEG-TS stream with H.264 video and MP2 audio. This avoids the MiSTer `mplayer` HLS playlist reload path, which has proven unreliable.

Event-style HLS is available with `RASTERCAST_TRANSPORT=hls`, and prebuilt VOD HLS is available with `RASTERCAST_TRANSPORT=hls-vod`.

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
- SSH access if you want the PC launcher to start playback remotely

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

To test live HLS instead:

```bash
RASTERCAST_TRANSPORT=hls bin/rastercast.sh /path/to/video.mkv
```

## Notes

- This repository is the first scaffold for the ffmpeg + mplayer approach.
- The exact playback command line may need tuning for audio device selection and CRT timing.
- The framebuffer centering issue from the current setup is still expected to need calibration work.
