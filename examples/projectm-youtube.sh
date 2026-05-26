#!/usr/bin/env bash
set -euo pipefail

if (( $# == 0 )); then
  printf 'usage: %s <youtube-url>\n' "${BASH_SOURCE[0]}" >&2
  exit 1
fi

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_dir=$(cd -- "${script_dir}/.." && pwd)

env \
  RASTERCAST_MISTER_DEPLOY=always \
  RASTERCAST_MISTER_DETACH=1 \
  RASTERCAST_FPS=30 \
  RASTERCAST_VISUALIZER=projectm \
  RASTERCAST_PROJECTM_PRESETS=/usr/share/projectM/presets \
  RASTERCAST_YTDLP_COOKIES_FROM_BROWSER=brave \
  RASTERCAST_YTDLP_JS_RUNTIME=node \
  "$repo_dir/bin/rastercast.sh" "$@"
