#!/bin/bash
# shellcheck disable=SC2034
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: rastercast.sh <stream-url>

Expected MiSTer environment:
  video_mode=320,240,60
  vga_scaler=1
  fb_terminal=1
  composite_sync=1

Environment:
  RASTERCAST_MPLAYER_VO  Optional mplayer video output, e.g. fbdev or fbdev2
  RASTERCAST_CACHE_KB    MPlayer cache size in KiB (default: 8192)
  RASTERCAST_CACHE_MIN   Percent cache fill before playback starts (default: 10)
  RASTERCAST_MPLAYER_AUTOSYNC  Optional mplayer -autosync value, e.g. 30
  RASTERCAST_MPLAYER_FRAMEDROP  Enable mplayer -framedrop: 1 or 0 (default: 0)
EOF
}

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    printf 'error: required command not found: %s\n' "$1" >&2
    exit 1
  fi
}

if [[ ${1:-} == "" || ${1:-} == "-h" || ${1:-} == "--help" ]]; then
  usage
  exit 0
fi

stream_url=$1

if [[ ! "$stream_url" =~ ^https?:// ]]; then
  printf 'error: expected http(s) stream URL, got: %s\n' "$stream_url" >&2
  exit 1
fi

sam_source=/media/fat/Scripts/MiSTer_SAM_on.sh
if [[ -f "$sam_source" ]]; then
  # shellcheck source=/media/fat/Scripts/MiSTer_SAM_on.sh disable=SC1091
  source "$sam_source" --source-only
fi

# These are read by SAM helper functions when they are available.
sv_inimod="yes"
samvideo_output="CRT"
samvideo_source="youtube"
samvideo_crtmode320="video_mode=320,-16,32,32,240,1,3,13,5670"
VIDEO_RES="320x240"

if [[ -z "${mrsampath:-}" ]]; then
  mrsampath=/media/fat/Scripts
fi

if [[ ! -f "${mrsampath}/mplayer" ]]; then
  if [[ -f "${mrsampath}/mplayer.zip" ]]; then
    require_command unzip
    unzip -ojq "${mrsampath}/mplayer.zip" -d "${mrsampath}"
  elif declare -F get_samvideo >/dev/null 2>&1; then
    get_samvideo
  else
    printf 'error: mplayer not found\n' >&2
    exit 1
  fi
fi

if declare -F misterini_mod >/dev/null 2>&1; then
  misterini_mod
fi

if [[ -w /dev/tty1 ]]; then
  printf '\033[2J' > /dev/tty1 2>/dev/null || true
  printf '0\n' > /sys/class/graphics/fbcon/cursor_blink 2>/dev/null || true
  printf '\033[?17;0;0c' > /dev/tty1 2>/dev/null || true
fi

if [[ -w /dev/MiSTer_cmd ]]; then
  printf '%s\n' 'load_core /media/fat/menu.rbf' > /dev/MiSTer_cmd
fi

display_wait=${samvideo_displaywait:-5}
sleep "$display_wait"

if declare -F mbc >/dev/null 2>&1; then
  mbc raw_seq :43 || true
elif [[ -x "${mrsampath}/mbc" ]]; then
  "${mrsampath}/mbc" raw_seq :43 || true
fi

cache_kb=${RASTERCAST_CACHE_KB:-8192}
cache_min=${RASTERCAST_CACHE_MIN:-10}
mplayer_autosync=${RASTERCAST_MPLAYER_AUTOSYNC:-}
mplayer_framedrop=${RASTERCAST_MPLAYER_FRAMEDROP:-0}

mplayer_args=(-fs -cache "$cache_kb" -cache-min "$cache_min")
if [[ -n "${RASTERCAST_MPLAYER_VO:-}" ]]; then
  mplayer_args=(-vo "$RASTERCAST_MPLAYER_VO" "${mplayer_args[@]}")
fi
if [[ -n "$mplayer_autosync" ]]; then
  mplayer_args=(-autosync "$mplayer_autosync" "${mplayer_args[@]}")
fi
case "$mplayer_framedrop" in
  1 | yes | true)
    mplayer_args=(-framedrop "${mplayer_args[@]}")
    ;;
  0 | no | false)
    ;;
  *)
    printf 'error: RASTERCAST_MPLAYER_FRAMEDROP must be 1 or 0\n' >&2
    exit 1
    ;;
esac
mplayer_args+=("$stream_url")

nice -n -20 env LD_LIBRARY_PATH="${mrsampath}" "${mrsampath}/mplayer" "${mplayer_args[@]}"
