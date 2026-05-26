#!/usr/bin/env bash
set -euo pipefail

if (( $# == 0 )); then
  printf 'usage: %s <video-or-url> [more-items...]\n' "${BASH_SOURCE[0]}" >&2
  exit 1
fi

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_dir=$(cd -- "${script_dir}/.." && pwd)

env \
  RASTERCAST_MISTER_AUTO=0 \
  RASTERCAST_VIDEO_BITRATE=1000k \
  "$repo_dir/bin/rastercast.sh" "$@"
