#!/bin/bash
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
EOF
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
  source "$sam_source" --source-only
fi

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

mplayer_args=(-fs)
if [[ -n "${RASTERCAST_MPLAYER_VO:-}" ]]; then
  mplayer_args=(-vo "$RASTERCAST_MPLAYER_VO" "${mplayer_args[@]}")
fi
mplayer_args+=("$stream_url")

nice -n -20 env LD_LIBRARY_PATH="${mrsampath}" "${mrsampath}/mplayer" "${mplayer_args[@]}"
