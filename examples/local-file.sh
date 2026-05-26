#!/usr/bin/env bash
set -euo pipefail

if (( $# == 0 )); then
  printf 'usage: %s <video-file> [more-files...]\n' "${BASH_SOURCE[0]}" >&2
  exit 1
fi

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_dir=$(cd -- "${script_dir}/.." && pwd)

env \
  RASTERCAST_VIDEO_BITRATE=2500k \
  RASTERCAST_VIDEO_SIZE=640x480 \
  RASTERCAST_DISPLAY_ASPECT=4:3 \
  RASTERCAST_MISTER_DEPLOY=always \
  RASTERCAST_MISTER_DETACH=1 \
  "$repo_dir/bin/rastercast.sh" "$@"
