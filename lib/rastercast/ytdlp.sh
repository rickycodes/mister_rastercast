#!/usr/bin/env bash
# shellcheck disable=SC2154

build_ytdlp_args() {
  ytdlp_args=(-f "$ytdlp_format")
  if [[ -n "$ytdlp_cookies" ]]; then
    ytdlp_args+=(--cookies "$ytdlp_cookies")
  fi
  if [[ -n "$ytdlp_cookies_from_browser" ]]; then
    ytdlp_args+=(--cookies-from-browser "$ytdlp_cookies_from_browser")
  fi
  if [[ -n "$ytdlp_js_runtime" ]]; then
    ytdlp_args+=(--js-runtimes "$ytdlp_js_runtime")
  fi
  if [[ -n "$ytdlp_remote_components" ]]; then
    ytdlp_args+=(--remote-components "$ytdlp_remote_components")
  fi
}

is_ytdlp_playlist() {
  local item=$1
  local extractor_key

  if ! should_use_ytdlp "$item"; then
    return 1
  fi

  extractor_key=$(yt-dlp "${ytdlp_args[@]}" --flat-playlist --print extractor_key --playlist-items 1 "$item" 2>>"${ffmpeg_log}" | sed -n '1p')
  [[ "$extractor_key" == "YoutubeTab" ]]
}

expand_playlist_input() {
  local item=$1

  if ! should_use_ytdlp "$item"; then
    printf '%s\n' "$item"
    return
  fi

  if ! is_ytdlp_playlist "$item"; then
    printf '%s\n' "$item"
    return
  fi

  printf 'rastercast: expanding playlist with yt-dlp: %s\n' "$item" >&2
  local playlist_args=(--flat-playlist --print webpage_url)
  if [[ -n "$ytdlp_playlist_items" ]]; then
    playlist_args+=(--playlist-items "$ytdlp_playlist_items")
  fi
  yt-dlp "${ytdlp_args[@]}" "${playlist_args[@]}" "$item" 2>>"${ffmpeg_log}"
}

resolve_queue_item() {
  local item=$1
  local urls
  local url_count

  if ! should_use_ytdlp "$item"; then
    if ! is_http_url "$item"; then
      item=$(cd -- "$(dirname -- "$item")" && printf '%s/%s\n' "$PWD" "$(basename -- "$item")")
    fi
    printf '%s\n' "$item"
    return
  fi

  printf 'rastercast: resolving URL input with yt-dlp: %s\n' "$item" >&2
  if ! yt-dlp "${ytdlp_args[@]}" --simulate "$item" >>"${ffmpeg_log}" 2>&1; then
    printf 'warning: yt-dlp failed while resolving queue item: %s\n' "$item" >&2
    return 1
  fi

  if ! urls=$(yt-dlp "${ytdlp_args[@]}" --get-url "$item" 2>>"${ffmpeg_log}"); then
    printf 'warning: yt-dlp failed while getting media URL: %s\n' "$item" >&2
    return 1
  fi

  url_count=$(printf '%s\n' "$urls" | sed '/^$/d' | wc -l)
  if [[ "$url_count" != "1" ]]; then
    printf 'warning: yt-dlp returned %s media URLs for queue item: %s\n' "$url_count" "$item" >&2
    printf 'error: use a muxed progressive format, e.g. RASTERCAST_YTDLP_FORMAT='\''best[height<=480][protocol^=http][vcodec!=none][acodec!=none]/best[protocol^=http][vcodec!=none][acodec!=none]'\''\n' >&2
    return 1
  fi

  if [[ "$urls" == *".m3u8"* || "$urls" == *"/manifest/hls_playlist/"* ]]; then
    printf 'warning: yt-dlp returned an HLS URL for queue item: %s\n' "$item" >&2
    printf 'error: queued YouTube playback needs a progressive muxed URL; try RASTERCAST_YTDLP_FORMAT='\''best[height<=480][protocol^=http][vcodec!=none][acodec!=none]/best[protocol^=http][vcodec!=none][acodec!=none]'\''\n' >&2
    return 1
  fi

  printf '%s\n' "$urls"
}

write_concat_list() {
  local expanded_items=()
  local item
  local resolved
  local resolved_count=0

  concat_list="${workdir}/queue.ffconcat"
  : > "$concat_list"

  build_ytdlp_args
  for item in "${inputs[@]}"; do
    while IFS= read -r expanded; do
      [[ -n "$expanded" ]] && expanded_items+=("$expanded")
    done < <(expand_playlist_input "$item")
  done

  if [[ ${#expanded_items[@]} -eq 0 ]]; then
    printf 'error: queue is empty\n' >&2
    exit 1
  fi

  printf 'rastercast: queue has %s item(s)\n' "${#expanded_items[@]}" >&2
  local index=0
  for item in "${expanded_items[@]}"; do
    index=$((index + 1))
    printf 'rastercast: preparing queue item %s/%s\n' "$index" "${#expanded_items[@]}" >&2
    if ! resolved=$(resolve_queue_item "$item"); then
      if is_enabled "$queue_skip_unavailable"; then
        printf 'rastercast: skipping unavailable queue item %s/%s\n' "$index" "${#expanded_items[@]}" >&2
        continue
      fi
      touch "$stream_error"
      printf 'error: failed to prepare queue item %s/%s\n' "$index" "${#expanded_items[@]}" >&2
      show_ffmpeg_log
      exit 1
    fi
    concat_escape "$resolved" >> "$concat_list"
    resolved_count=$((resolved_count + 1))
  done

  if (( resolved_count == 0 )); then
    touch "$stream_error"
    printf 'error: no playable queue items resolved\n' >&2
    show_ffmpeg_log
    exit 1
  fi
}
