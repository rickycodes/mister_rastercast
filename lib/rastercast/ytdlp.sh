#!/usr/bin/env bash

should_use_ytdlp() {
  local item=$1

  [[ ${cfg[ytdlp_mode]} == "1" ]] || { [[ ${cfg[ytdlp_mode]} == "auto" ]] && is_ytdlp_url "$item"; }
}

build_ytdlp_args() {
  ytdlp_args=()
  ytdlp_args+=( -f "${cfg[ytdlp_format]}" )
  if [[ -n ${cfg[ytdlp_cookies]} ]]; then
    ytdlp_args+=( --cookies "${cfg[ytdlp_cookies]}" )
  fi
  if [[ -n ${cfg[ytdlp_cookies_from_browser]} ]]; then
    ytdlp_args+=( --cookies-from-browser "${cfg[ytdlp_cookies_from_browser]}" )
  fi
  if [[ -n ${cfg[ytdlp_js_runtime]} ]]; then
    ytdlp_args+=( --js-runtimes "${cfg[ytdlp_js_runtime]}" )
  fi
  if [[ -n ${cfg[ytdlp_remote_components]} ]]; then
    ytdlp_args+=( --remote-components "${cfg[ytdlp_remote_components]}" )
  fi
}

is_ytdlp_playlist() {
  local item=$1
  local extractor_key

  if ! should_use_ytdlp "$item"; then
    return 1
  fi

  extractor_key=$(yt-dlp "${ytdlp_args[@]}" --flat-playlist --print extractor_key --playlist-items 1 "$item" 2>>"${cfg[ffmpeg_log]}" | sed -n '1p')
  [[ "$extractor_key" == "YoutubeTab" ]]
}

expand_playlist_input() {
  local item=$1
  local playlist_args=(--flat-playlist --print webpage_url)

  if ! should_use_ytdlp "$item"; then
    printf '%s\n' "$item"
    return
  fi

  if ! is_ytdlp_playlist "$item"; then
    printf '%s\n' "$item"
    return
  fi

  printf 'rastercast: expanding playlist with yt-dlp: %s\n' "$item" >&2
  if [[ -n ${cfg[ytdlp_playlist_items]} ]]; then
    playlist_args+=( --playlist-items "${cfg[ytdlp_playlist_items]}" )
  fi
  yt-dlp "${ytdlp_args[@]}" "${playlist_args[@]}" "$item" 2>>"${cfg[ffmpeg_log]}"
}

resolve_queue_item() {
  local item=$1
  local index=${2:-0}
  local output_template
  local normalized_output
  local resolved

  if ! should_use_ytdlp "$item"; then
    if ! is_http_url "$item"; then
      item=$(cd -- "$(dirname -- "$item")" && printf '%s/%s\n' "$PWD" "$(basename -- "$item")")
    fi
    printf '%s\n' "$item"
    return
  fi

  output_template="${cfg[workdir]}/queue-$(printf '%03d' "$index").mkv"
  normalized_output="${cfg[workdir]}/queue-$(printf '%03d' "$index").clean.mkv"
  printf 'rastercast: caching URL input with yt-dlp: %s\n' "$item" >&2
  if ! resolved=$(yt-dlp "${ytdlp_args[@]}" --no-playlist --no-part --no-mtime --remux-video mkv --output "$output_template" --print after_move:filepath "$item" 2>>"${cfg[ffmpeg_log]}"); then
    printf 'warning: yt-dlp failed while caching queue item: %s\n' "$item" >&2
    return 1
  fi

  resolved=$(printf '%s\n' "$resolved" | sed -n '$p')
  if [[ -z "$resolved" || ! -f "$resolved" ]]; then
    printf 'warning: yt-dlp did not produce a cached file for queue item: %s\n' "$item" >&2
    return 1
  fi

  printf 'rastercast: normalizing cached media file: %s\n' "$resolved" >&2
  if ! ffmpeg -hide_banner -loglevel error -y \
    -fflags +genpts+discardcorrupt \
    -err_detect ignore_err \
    -i "$resolved" \
    -map 0:v:0 -map 0:a:0? -map 0:s? \
    -c:v copy \
    -c:a aac -b:a 128k -ar 44100 -ac 2 \
    -c:s copy \
    "$normalized_output" 2>>"${cfg[ffmpeg_log]}"; then
    printf 'warning: ffmpeg failed while normalizing cached queue item: %s\n' "$item" >&2
    rm -f -- "$normalized_output"
    return 1
  fi

  mv -f -- "$normalized_output" "$resolved"

  printf '%s\n' "$resolved"
}

write_concat_list() {
  local inputs=("$@")
  expanded_items=()
  local item
  local expanded
  local resolved
  local resolved_count=0
  local index=0

  cfg+=( [concat_list]="${cfg[workdir]}/queue.ffconcat" )
  : > "${cfg[concat_list]}"

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
  for item in "${expanded_items[@]}"; do
    index=$((index + 1))
    printf 'rastercast: preparing queue item %s/%s\n' "$index" "${#expanded_items[@]}" >&2
    if ! resolved=$(resolve_queue_item "$item" "$index"); then
      if is_enabled "${cfg[queue_skip_unavailable]}"; then
        printf 'rastercast: skipping unavailable queue item %s/%s\n' "$index" "${#expanded_items[@]}" >&2
        continue
      fi
      cfg+=( [stream_error]=1 )
      printf 'error: failed to prepare queue item %s/%s\n' "$index" "${#expanded_items[@]}" >&2
      show_ffmpeg_log "${cfg[ffmpeg_log]}"
      exit 1
    fi
    concat_escape "$resolved" >> "${cfg[concat_list]}"
    resolved_count=$((resolved_count + 1))
  done

  if (( resolved_count == 0 )); then
    cfg+=( [stream_error]=1 )
    printf 'error: no playable queue items resolved\n' >&2
    show_ffmpeg_log "${cfg[ffmpeg_log]}"
    exit 1
  fi
}
