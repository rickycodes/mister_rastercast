#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_dir=$(cd -- "${script_dir}/.." && pwd)
declare -A cfg=()

source "${repo_dir}/lib/rastercast/util.sh"
source "${repo_dir}/lib/rastercast/config.sh"
source "${repo_dir}/lib/rastercast/ffmpeg.sh"
source "${repo_dir}/lib/rastercast/ytdlp.sh"
source "${repo_dir}/lib/rastercast/mister.sh"

# Basic helpers

usage() {
  cat <<'EOF'
Usage: rastercast.sh <video-file-or-url>...

Environment:
  RASTERCAST_BIND_ADDR   HTTP bind address (default: 0.0.0.0)
  RASTERCAST_HOST_IP     Host/IP printed in the playback URL (auto-detected by default)
  RASTERCAST_PORT        HTTP port (default: 8090)
  RASTERCAST_FPS         Optional output video FPS override, e.g. 30000/1001
  RASTERCAST_VIDEO_BITRATE  Output video bitrate (default: 1000k)
  RASTERCAST_VIDEO_SIZE  Output video size as WIDTHxHEIGHT (default: 320x240)
  RASTERCAST_DISPLAY_ASPECT  Display aspect ratio, e.g. 4:3 (default: auto)
  RASTERCAST_VIDEO_FIT   Video fit mode: auto, contain, cover (default: auto)
  RASTERCAST_VIDEO_EFFECT  Comma-separated video effects, or none
  RASTERCAST_WATERMARK_TEXT  Text watermark drawn at bottom right
  RASTERCAST_WATERMARK_IMAGE  Image watermark file, preferably PNG/WebP/SVG
  RASTERCAST_WATERMARK_X  Watermark X expression (default: bottom-right)
  RASTERCAST_WATERMARK_Y  Watermark Y expression (default: bottom-right)
  RASTERCAST_WATERMARK_SCALE  Watermark image scale factor (default: 1)
  RASTERCAST_WATERMARK_SIZE  Text watermark font size (default: 18)
  RASTERCAST_WATERMARK_MARGIN  Text watermark edge margin (default: 8)
  RASTERCAST_WATERMARK_OPACITY  Text watermark opacity from 0.0 to 1.0 (default: 0.65)
  RASTERCAST_VIDEO_SPEED  Playback speed multiplier, from 0.5 to 2.0 (default: 1)
  RASTERCAST_VISUALIZER  Replace video with audio visualizer: none, waves, spectrum, cqt, vectorscope, freqs, spatial, histogram, bits, projectm
  RASTERCAST_PROJECTM    projectM helper path (default: ~/projects/rastercast-projectm/rastercast-projectm)
  RASTERCAST_PROJECTM_PRESETS  projectM preset directory (default: /usr/share/projectM/presets)
  RASTERCAST_PROJECTM_PRESET  Lock projectM to one preset file
  RASTERCAST_PROJECTM_FPS  projectM helper FPS (default: RASTERCAST_FPS or 30)
  RASTERCAST_PROJECTM_QUEUE_SIZE  ffmpeg queue size for projectM pipes (default: 1024)
  RASTERCAST_AUDIO_EFFECT  Audio effect: none, echo, robot, radio, deep, chipmunk
  RASTERCAST_YTDLP       Force yt-dlp for URL input: 1 or 0 (default: auto)
  RASTERCAST_YTDLP_FORMAT  yt-dlp format for URL inputs (default: progressive <=480p)
  RASTERCAST_YTDLP_COOKIES  yt-dlp cookies file for authenticated videos
  RASTERCAST_YTDLP_COOKIES_FROM_BROWSER  Browser name for yt-dlp cookies
  RASTERCAST_YTDLP_JS_RUNTIME  JavaScript runtime for yt-dlp extraction
  RASTERCAST_YTDLP_REMOTE_COMPONENTS  Remote yt-dlp components, e.g. ejs:github
  RASTERCAST_YTDLP_PLAYLIST_ITEMS  yt-dlp playlist items/range, e.g. 1:10
  RASTERCAST_QUEUE_SKIP_UNAVAILABLE  Skip unavailable queue items: 1 or 0 (default: 0)
  RASTERCAST_STARTUP_TIMEOUT  Seconds to wait for stream startup (default: 30)
  RASTERCAST_MISTER_AUTO  Automatically launch playback on MiSTer: 1 or 0 (default: 1)
  RASTERCAST_MISTER_HOST  MiSTer host/IP (default: mister)
  RASTERCAST_MISTER_USER  MiSTer SSH user (default: root)
  RASTERCAST_MISTER_SCRIPT  MiSTer script path (default: /media/fat/Scripts/rastercast.sh)
  RASTERCAST_MISTER_DEPLOY  Deploy MiSTer script when missing: auto, always, never (default: auto)
  RASTERCAST_MISTER_TTY  Allocate TTY for remote playback controls: 1 or 0 (default: 1)
  RASTERCAST_MISTER_DETACH  Start remote playback detached from SSH: 1 or 0 (default: 0)
EOF
}

# Process lifecycle

cleanup() {
  local status=$?

  if [[ -n ${cfg[pcm_ffmpeg_pid]:-} ]] && kill -0 "${cfg[pcm_ffmpeg_pid]}" 2>/dev/null; then
    kill "${cfg[pcm_ffmpeg_pid]}" 2>/dev/null || true
    wait "${cfg[pcm_ffmpeg_pid]}" 2>/dev/null || true
  fi

  if [[ -n ${cfg[projectm_pid]:-} ]] && kill -0 "${cfg[projectm_pid]}" 2>/dev/null; then
    kill "${cfg[projectm_pid]}" 2>/dev/null || true
    wait "${cfg[projectm_pid]}" 2>/dev/null || true
  fi

  if [[ -n ${cfg[ffmpeg_pid]:-} ]] && kill -0 "${cfg[ffmpeg_pid]}" 2>/dev/null; then
    kill "${cfg[ffmpeg_pid]}" 2>/dev/null || true
    wait "${cfg[ffmpeg_pid]}" 2>/dev/null || true
  fi

  if [[ -n ${cfg[server_pid]:-} ]] && kill -0 "${cfg[server_pid]}" 2>/dev/null; then
    kill "${cfg[server_pid]}" 2>/dev/null || true
    wait "${cfg[server_pid]}" 2>/dev/null || true
  fi

  close_mister_connection
  rm -rf -- "${cfg[workdir]:-}"
  exit "$status"
}

start_server() {
  python3 "${script_dir}/rastercast-server.py" "${cfg[bind_addr]}" "${cfg[port]}" "${cfg[workdir]}" >"${cfg[server_log]}" 2>&1 &
  cfg+=( [server_pid]="$!" )
  sleep 0.1

  if ! kill -0 "${cfg[server_pid]}" 2>/dev/null; then
    printf 'error: HTTP server failed to start on %s:%s\n' "${cfg[bind_addr]}" "${cfg[port]}" >&2
    show_server_log "${cfg[server_log]}"
    exit 1
  fi
}

# Main

main() {
  if [[ ${1:-} == "" || ${1:-} == "-h" || ${1:-} == "--help" ]]; then
    usage
    exit 0
  fi

  cfg=()
  cfg+=( [repo_dir]="$repo_dir" )
  load_config
  validate_config "$@"
  resolve_host_ip
  prepare_workdir
  trap cleanup EXIT INT TERM

  printf 'rastercast: exporting MPEG-TS stream into %s\n' "${cfg[workdir]}" >&2
  start_server
  start_ffmpeg "$@"
  wait_for_stream_startup
  print_stream_url
  launch_mister
  wait_for_ffmpeg

  wait "${cfg[server_pid]}"
}

main "$@"
