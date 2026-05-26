#!/usr/bin/env bash
set -euo pipefail

repo_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)

playlist=playlists/90s-dance.strict.youtube.txt
playlist_fps=30000/1001  # swap to 60 if the display chain prefers a true 60 Hz cadence
keep_workdir=1
mister_detach=0
mapfile -t playlist_urls < <(
  awk 'NF && $1 !~ /^#/' "$playlist" | shuf
)

printf 'launch: shuffled %s playlist item(s)\n' "${#playlist_urls[@]}" >&2
if (( ${#playlist_urls[@]} == 0 )); then
  printf 'error: playlist is empty: %s\n' "$playlist" >&2
  exit 1
fi
printf 'launch: playing %s playlist item(s)\n' "${#playlist_urls[@]}" >&2

env \
  RASTERCAST_MISTER_DEPLOY=always \
  RASTERCAST_KEEP_WORKDIR="$keep_workdir" \
  RASTERCAST_MISTER_DETACH="$mister_detach" \
  RASTERCAST_CACHE_KB=32768 \
  RASTERCAST_CACHE_MIN=30 \
  RASTERCAST_FPS="$playlist_fps" \
  RASTERCAST_MPLAYER_TSKEEPBROKEN=1 \
  RASTERCAST_YTDLP_COOKIES_FROM_BROWSER=brave \
  RASTERCAST_YTDLP_JS_RUNTIME=node \
  RASTERCAST_QUEUE_SKIP_UNAVAILABLE=1 \
  "$repo_dir/bin/rastercast.sh" "${playlist_urls[@]}"
