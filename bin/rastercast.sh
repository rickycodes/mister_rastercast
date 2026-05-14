#!/usr/bin/env bash
# shellcheck disable=SC2029
set -euo pipefail

valid_video_effects="none, acid, trails, edges, ghost, matrix, rgbshift, negative, warp, wobble, feedback, scanwarp"

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
  RASTERCAST_VIDEO_SPEED  Playback speed multiplier, from 0.5 to 2.0 (default: 1)
  RASTERCAST_VISUALIZER  Replace video with audio visualizer: none, waves, spectrum, cqt, vectorscope
  RASTERCAST_AUDIO_EFFECT  Audio effect: none, echo, robot, radio, deep, chipmunk
  RASTERCAST_YTDLP       Force yt-dlp for URL input: 1 or 0 (default: auto)
  RASTERCAST_YTDLP_FORMAT  yt-dlp format for URL inputs (default: best[height<=480]/best)
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
EOF
}

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    printf 'error: required command not found: %s\n' "$1" >&2
    exit 1
  fi
}

is_http_url() {
  [[ "$1" =~ ^https?:// ]]
}

is_ytdlp_url() {
  [[ "$1" =~ ^https?://([^/?#]+\.)?(youtube\.com|youtu\.be)([/?#]|$) ]]
}

is_enabled() {
  case "$1" in
    1 | yes | true)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

validate_bool() {
  local name=$1
  local value=$2

  case "$value" in
    1 | yes | true | 0 | no | false)
      ;;
    *)
      printf 'error: %s must be 1 or 0\n' "$name" >&2
      exit 1
      ;;
  esac
}

show_ffmpeg_log() {
  if [[ -f "${ffmpeg_log}" ]]; then
    printf '%s\n' '---- ffmpeg log ----' >&2
    sed -n '1,200p' "${ffmpeg_log}" >&2
    printf '%s\n' '--------------------' >&2
  fi
}

show_server_log() {
  if [[ -f "${server_log}" ]]; then
    printf '%s\n' '---- server log ----' >&2
    sed -n '1,80p' "${server_log}" >&2
    printf '%s\n' '--------------------' >&2
  fi
}

# Configuration

load_config() {
  script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
  repo_dir=$(cd -- "${script_dir}/.." && pwd)

  inputs=("$@")
  input_uses_ytdlp=0
  ytdlp_mode=${RASTERCAST_YTDLP:-auto}

  bind_addr=${RASTERCAST_BIND_ADDR:-0.0.0.0}
  port=${RASTERCAST_PORT:-8090}
  output_fps=${RASTERCAST_FPS:-}
  video_bitrate=${RASTERCAST_VIDEO_BITRATE:-1000k}
  video_size=${RASTERCAST_VIDEO_SIZE:-320x240}
  display_aspect=${RASTERCAST_DISPLAY_ASPECT:-auto}
  video_fit=${RASTERCAST_VIDEO_FIT:-auto}
  video_effect=${RASTERCAST_VIDEO_EFFECT:-none}
  video_speed=${RASTERCAST_VIDEO_SPEED:-1}
  visualizer=${RASTERCAST_VISUALIZER:-none}
  audio_effect=${RASTERCAST_AUDIO_EFFECT:-none}
  ytdlp_format=${RASTERCAST_YTDLP_FORMAT:-best[height<=480]/best}
  ytdlp_cookies=${RASTERCAST_YTDLP_COOKIES:-}
  ytdlp_cookies_from_browser=${RASTERCAST_YTDLP_COOKIES_FROM_BROWSER:-}
  ytdlp_js_runtime=${RASTERCAST_YTDLP_JS_RUNTIME:-}
  ytdlp_remote_components=${RASTERCAST_YTDLP_REMOTE_COMPONENTS:-}
  ytdlp_playlist_items=${RASTERCAST_YTDLP_PLAYLIST_ITEMS:-}
  queue_skip_unavailable=${RASTERCAST_QUEUE_SKIP_UNAVAILABLE:-0}
  startup_timeout=${RASTERCAST_STARTUP_TIMEOUT:-30}

  mister_auto=${RASTERCAST_MISTER_AUTO:-1}
  mister_host=${RASTERCAST_MISTER_HOST:-mister}
  mister_user=${RASTERCAST_MISTER_USER:-root}
  mister_script=${RASTERCAST_MISTER_SCRIPT:-/media/fat/Scripts/rastercast.sh}
  mister_deploy=${RASTERCAST_MISTER_DEPLOY:-auto}
  mister_tty=${RASTERCAST_MISTER_TTY:-1}

  host_ip=${RASTERCAST_HOST_IP:-}
}

resolve_host_ip() {
  if [[ -n "$host_ip" ]]; then
    return
  fi

  host_ip=$(hostname -I 2>/dev/null | awk '{print $1}' || true)
  if [[ -z "${host_ip:-}" ]]; then
    host_ip=127.0.0.1
  fi
}

prepare_workdir() {
  workdir=$(mktemp -d "${TMPDIR:-/tmp}/rastercast.XXXXXX")
  server_pid=""
  ffmpeg_pid=""
  ffmpeg_log="${workdir}/ffmpeg.log"
  server_log="${workdir}/server.log"
  stream_path="${workdir}/stream.ts"
  stream_done="${workdir}/stream.done"
  stream_error="${workdir}/stream.error"
  stream_url="http://${host_ip}:${port}/stream.ts"
  ssh_control_path="${workdir}/ssh-control-%r@%h:%p"
  ssh_opts=(-o ControlMaster=auto -o ControlPersist=60 -o "ControlPath=${ssh_control_path}")
  mister_ssh_used=""
}

validate_config() {
  require_command ffmpeg
  require_command python3

  case "$ytdlp_mode" in
    auto | 1 | 0)
      ;;
    *)
      printf 'error: RASTERCAST_YTDLP must be auto, 1, or 0\n' >&2
      exit 1
      ;;
  esac

  validate_bool RASTERCAST_QUEUE_SKIP_UNAVAILABLE "$queue_skip_unavailable"

  case "$video_fit" in
    auto | contain | cover)
      ;;
    *)
      printf 'error: RASTERCAST_VIDEO_FIT must be auto, contain, or cover\n' >&2
      exit 1
      ;;
  esac

  if [[ ! "$video_size" =~ ^[1-9][0-9]*x[1-9][0-9]*$ ]]; then
    printf 'error: RASTERCAST_VIDEO_SIZE must be WIDTHxHEIGHT, e.g. 320x240\n' >&2
    exit 1
  fi
  video_width=${video_size%x*}
  video_height=${video_size#*x}

  if [[ "$display_aspect" == "auto" ]]; then
    display_width=$video_width
    display_height=$video_height
  elif [[ "$display_aspect" =~ ^[1-9][0-9]*:[1-9][0-9]*$ ]]; then
    display_width=${display_aspect%:*}
    display_height=${display_aspect#*:}
  else
    printf 'error: RASTERCAST_DISPLAY_ASPECT must be auto or WIDTH:HEIGHT, e.g. 4:3\n' >&2
    exit 1
  fi
  fit_width=$((video_height * display_width / display_height))
  fit_height=$video_height
  if (( fit_width > video_width )); then
    fit_width=$video_width
    fit_height=$((video_width * display_height / display_width))
  fi
  fit_width=$((fit_width / 2 * 2))
  fit_height=$((fit_height / 2 * 2))

  validate_video_effects

  case "$visualizer" in
    none | waves | spectrum | cqt | vectorscope)
      ;;
    *)
      printf 'error: RASTERCAST_VISUALIZER must be one of: none, waves, spectrum, cqt, vectorscope\n' >&2
      exit 1
      ;;
  esac

  case "$audio_effect" in
    none | echo | robot | radio | deep | chipmunk)
      ;;
    *)
      printf 'error: RASTERCAST_AUDIO_EFFECT must be one of: none, echo, robot, radio, deep, chipmunk\n' >&2
      exit 1
      ;;
  esac

  if ! awk -v speed="$video_speed" 'BEGIN { exit !(speed + 0 == speed && speed >= 0.5 && speed <= 2.0) }'; then
    printf 'error: RASTERCAST_VIDEO_SPEED must be a number from 0.5 to 2.0\n' >&2
    exit 1
  fi

  local item
  for item in "${inputs[@]}"; do
    if should_use_ytdlp "$item"; then
      input_uses_ytdlp=1
      require_command yt-dlp
      if [[ -n "$ytdlp_cookies" && ! -f "$ytdlp_cookies" ]]; then
        printf 'error: RASTERCAST_YTDLP_COOKIES file not found: %s\n' "$ytdlp_cookies" >&2
        exit 1
      fi
    elif ! is_http_url "$item" && [[ ! -f "$item" ]]; then
      printf 'error: input file not found: %s\n' "$item" >&2
      exit 1
    fi
  done
}

should_use_ytdlp() {
  [[ "$ytdlp_mode" == "1" ]] || { [[ "$ytdlp_mode" == "auto" ]] && is_ytdlp_url "$1"; }
}

video_effect_filter() {
  case "$1" in
    none)
      printf '%s\n' ""
      ;;
    acid)
      printf '%s\n' "hue=h=2*PI*t:s=2,eq=contrast=1.2:saturation=1.8"
      ;;
    trails)
      printf '%s\n' "tmix=frames=5:weights='1 1 1 1 1'"
      ;;
    edges)
      printf '%s\n' "edgedetect=low=0.1:high=0.4"
      ;;
    ghost)
      printf '%s\n' "lagfun=decay=0.9"
      ;;
    matrix)
      printf '%s\n' "eq=contrast=1.25:saturation=0.65:brightness=-0.03,colorchannelmixer=rr=0.55:rg=0.30:rb=0.05:gr=0.20:gg=0.90:gb=0.20:br=0.02:bg=0.20:bb=0.18"
      ;;
    rgbshift)
      printf '%s\n' "rgbashift=rh=4:bh=-4"
      ;;
    negative)
      printf '%s\n' "negate"
      ;;
    warp)
      printf '%s\n' "lenscorrection=k1=-0.25:k2=0.08:i=bilinear"
      ;;
    wobble)
      printf '%s\n' "rotate=0.04*sin(2*PI*t):fillcolor=black@0"
      ;;
    feedback)
      printf '%s\n' "tmix=frames=7:weights='1 1 1 1 1 1 1',eq=contrast=1.35:saturation=1.3"
      ;;
    scanwarp)
      printf '%s\n' "rgbashift=rh=4:bh=-4,noise=alls=12:allf=t+u"
      ;;
    *)
      return 1
      ;;
  esac
}

validate_video_effects() {
  local effect

  IFS=',' read -r -a video_effects <<< "$video_effect"
  if [[ ${#video_effects[@]} -eq 0 ]]; then
    video_effects=(none)
  fi

  for effect in "${video_effects[@]}"; do
    if [[ -z "$effect" ]]; then
      printf 'error: RASTERCAST_VIDEO_EFFECT contains an empty effect name\n' >&2
      exit 1
    fi
    if [[ "$effect" == "none" && ${#video_effects[@]} -gt 1 ]]; then
      printf 'error: RASTERCAST_VIDEO_EFFECT=none cannot be combined with other effects\n' >&2
      exit 1
    fi
    if ! video_effect_filter "$effect" >/dev/null; then
      printf 'error: unknown RASTERCAST_VIDEO_EFFECT: %s\n' "$effect" >&2
      printf 'error: valid effects: %s\n' "$valid_video_effects" >&2
      exit 1
    fi
  done
}

append_video_effects() {
  local effect
  local effect_filter

  for effect in "${video_effects[@]}"; do
    effect_filter=$(video_effect_filter "$effect")
    if [[ -n "$effect_filter" ]]; then
      video_filter="${video_filter},${effect_filter}"
    fi
  done
}

build_video_filter() {
  local fit="$video_fit"

  if [[ "$fit" == "auto" ]]; then
    if (( input_uses_ytdlp )); then
      fit=cover
    else
      fit=contain
    fi
  fi

  case "$fit" in
    contain)
      video_filter="scale=${fit_width}:${fit_height}:force_original_aspect_ratio=decrease:force_divisible_by=2,setsar=1,pad=${video_width}:${video_height}:(ow-iw)/2:(oh-ih)/2:black"
      ;;
    cover)
      video_filter="scale=${fit_width}:${fit_height}:force_original_aspect_ratio=increase:force_divisible_by=2,setsar=1,crop=${fit_width}:${fit_height},pad=${video_width}:${video_height}:(ow-iw)/2:(oh-ih)/2:black"
      ;;
  esac

  append_video_effects

  if [[ -n "$output_fps" ]]; then
    video_filter="${video_filter},fps=${output_fps}"
  fi

  if [[ "$video_speed" != "1" && "$video_speed" != "1.0" ]]; then
    video_filter="${video_filter},setpts=PTS/${video_speed}"
  fi
}

build_audio_filter() {
  if [[ "$video_speed" != "1" && "$video_speed" != "1.0" ]]; then
    audio_filter="atempo=${video_speed}"
  else
    audio_filter=""
  fi

  case "$audio_effect" in
    none)
      ;;
    echo)
      audio_filter="${audio_filter:+${audio_filter},}aecho=0.8:0.88:60:0.35"
      ;;
    robot)
      audio_filter="${audio_filter:+${audio_filter},}afftfilt=real='hypot(re,im)*sin(0)':imag='hypot(re,im)*cos(0)',aresample=44100"
      ;;
    radio)
      audio_filter="${audio_filter:+${audio_filter},}highpass=f=300,lowpass=f=3000,acompressor=threshold=-18dB:ratio=4:attack=5:release=80"
      ;;
    deep)
      audio_filter="${audio_filter:+${audio_filter},}asetrate=44100*0.85,aresample=44100,atempo=1.17647"
      ;;
    chipmunk)
      audio_filter="${audio_filter:+${audio_filter},}asetrate=44100*1.25,aresample=44100,atempo=0.8"
      ;;
  esac
}

visualizer_filter() {
  case "$visualizer" in
    waves)
      printf 'showwaves=s=%sx%s:mode=cline:colors=00ff66|00ccff:scale=sqrt' "$fit_width" "$fit_height"
      ;;
    spectrum)
      printf 'showspectrum=s=%sx%s:mode=combined:color=intensity:scale=cbrt:slide=scroll' "$fit_width" "$fit_height"
      ;;
    cqt)
      printf 'showcqt=s=%sx%s:count=1' "$fit_width" "$fit_height"
      ;;
    vectorscope)
      printf 'avectorscope=s=%sx%s:mode=lissajous:zoom=1.3,format=yuv420p' "$fit_width" "$fit_height"
      ;;
  esac
}

build_ffmpeg_output_args() {
  ffmpeg_output_args=(
    -c:v libx264
    -preset ultrafast
    -tune zerolatency
    -profile:v baseline
    -level 3.0
    -b:v "$video_bitrate"
    -maxrate "$video_bitrate"
    -bufsize 2000k
    -pix_fmt yuv420p
    -g 60
    -keyint_min 60
    -sc_threshold 0
    -c:a mp2
    -b:a 128k
    -ar 44100
    -ac 2
    -muxpreload 0
    -muxdelay 0
    -mpegts_flags +resend_headers
    -avoid_negative_ts make_zero
    -f mpegts
    "$stream_path"
  )

  if [[ "$visualizer" == "none" ]]; then
    ffmpeg_output_args=(-map 0:v:0 -map 0:a? -vf "$video_filter" "${ffmpeg_output_args[@]}")
  else
    local viz_filter
    viz_filter="$(visualizer_filter),setsar=1,pad=${video_width}:${video_height}:(ow-iw)/2:(oh-ih)/2:black"
    if [[ -n "$output_fps" ]]; then
      viz_filter="${viz_filter},fps=${output_fps}"
    fi
    if [[ "$video_speed" != "1" && "$video_speed" != "1.0" ]]; then
      viz_filter="${viz_filter},setpts=PTS/${video_speed}"
    fi
    ffmpeg_output_args=(-filter_complex "[0:a]${viz_filter}[v]" -map "[v]" -map 0:a:0 "${ffmpeg_output_args[@]}")
  fi

  if [[ -n "$audio_filter" ]]; then
    ffmpeg_output_args=(-af "$audio_filter" "${ffmpeg_output_args[@]}")
  fi
}

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
    printf 'error: use a muxed format, e.g. RASTERCAST_YTDLP_FORMAT='\''best[height<=480][vcodec!=none][acodec!=none]/best[vcodec!=none][acodec!=none]'\''\n' >&2
    return 1
  fi

  printf '%s\n' "$urls"
}

concat_escape() {
  local value=${1//\'/\'\\\'\'}
  printf "file '%s'\n" "$value"
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

# MiSTer control

run_mister_ssh() {
  mister_ssh_used=1
  ssh "${ssh_opts[@]}" "${mister_user}@${mister_host}" "$@"
}

run_mister_playback() {
  case "$mister_tty" in
    1 | yes | true)
      mister_ssh_used=1
      ssh "${ssh_opts[@]}" -t "${mister_user}@${mister_host}" "$@"
      ;;
    0 | no | false)
      run_mister_ssh "$@"
      ;;
    *)
      printf 'error: RASTERCAST_MISTER_TTY must be 1 or 0\n' >&2
      exit 1
      ;;
  esac
}

run_mister_scp() {
  mister_ssh_used=1
  scp "${ssh_opts[@]}" "$@"
}

copy_mister_script() {
  local local_script="${repo_dir}/mister/rastercast.sh"

  if [[ ! -f "$local_script" ]]; then
    printf 'error: local MiSTer script not found: %s\n' "$local_script" >&2
    exit 1
  fi

  printf 'rastercast: deploying MiSTer script to %s@%s:%s\n' "$mister_user" "$mister_host" "$mister_script" >&2
  run_mister_scp "$local_script" "${mister_user}@${mister_host}:${mister_script}"
}

launch_mister() {
  case "$mister_auto" in
    1 | yes | true)
      ;;
    0 | no | false)
      return
      ;;
    *)
      printf 'error: RASTERCAST_MISTER_AUTO must be 1 or 0\n' >&2
      exit 1
      ;;
  esac

  if [[ "$mister_script" == *"'"* ]]; then
    printf "error: RASTERCAST_MISTER_SCRIPT cannot contain a single quote\n" >&2
    exit 1
  fi

  require_command ssh
  require_command scp

  case "$mister_deploy" in
    always)
      copy_mister_script
      ;;
    auto)
      if ! run_mister_ssh "test -x '$mister_script'"; then
        copy_mister_script
      fi
      ;;
    never)
      ;;
    *)
      printf 'error: RASTERCAST_MISTER_DEPLOY must be auto, always, or never\n' >&2
      exit 1
      ;;
  esac

  printf 'rastercast: launching MiSTer playback on %s@%s\n' "$mister_user" "$mister_host" >&2
  run_mister_playback "chmod +x '$mister_script' && exec '$mister_script' '$stream_url'"
}

# Process lifecycle

cleanup() {
  local status=$?

  if [[ -n "${ffmpeg_pid}" ]] && kill -0 "${ffmpeg_pid}" 2>/dev/null; then
    kill "${ffmpeg_pid}" 2>/dev/null || true
    wait "${ffmpeg_pid}" 2>/dev/null || true
  fi

  if [[ -n "${server_pid}" ]] && kill -0 "${server_pid}" 2>/dev/null; then
    kill "${server_pid}" 2>/dev/null || true
    wait "${server_pid}" 2>/dev/null || true
  fi

  if [[ -n "${mister_ssh_used}" ]] && command -v ssh >/dev/null 2>&1; then
    ssh "${ssh_opts[@]}" -O exit "${mister_user}@${mister_host}" >/dev/null 2>&1 || true
  fi

  rm -rf "${workdir}"
  exit "${status}"
}

start_server() {
  python3 "${script_dir}/rastercast-server.py" "$bind_addr" "$port" "$workdir" >"${server_log}" 2>&1 &
  server_pid=$!
  sleep 0.1

  if ! kill -0 "$server_pid" 2>/dev/null; then
    printf 'error: HTTP server failed to start on %s:%s\n' "$bind_addr" "$port" >&2
    show_server_log
    exit 1
  fi
}

start_ffmpeg() {
  local audio_filter
  local ffmpeg_output_args
  local video_filter

  build_video_filter
  build_audio_filter

  local ffmpeg_args=(
    -hide_banner
    -loglevel error
    -nostdin
    -re
    -fflags +genpts
  )
  build_ffmpeg_output_args

  write_concat_list
  ffmpeg "${ffmpeg_args[@]}" \
    -f concat \
    -safe 0 \
    -protocol_whitelist file,http,https,tcp,tls,crypto,httpproxy \
    -i "$concat_list" \
    "${ffmpeg_output_args[@]}" >"${ffmpeg_log}" 2>&1 &
  ffmpeg_pid=$!
}

stream_is_ready() {
  [[ -s "$stream_path" ]]
}

wait_for_stream_startup() {
  local deadline=$((SECONDS + startup_timeout))

  while (( SECONDS < deadline )); do
    if stream_is_ready; then
      return
    fi

    if ! kill -0 "${ffmpeg_pid}" 2>/dev/null; then
      if wait "${ffmpeg_pid}"; then
        return
      fi
      printf 'error: ffmpeg failed while exporting the MPEG-TS stream\n' >&2
      show_ffmpeg_log
      exit 1
    fi
    sleep 0.1
  done

  if ! stream_is_ready; then
    printf 'error: ffmpeg did not produce a playable MPEG-TS stream within %ss\n' "${startup_timeout}" >&2
    show_ffmpeg_log
    exit 1
  fi
}

print_stream_url() {
  printf 'rastercast: serving %s\n' "$stream_url" >&2
  printf 'rastercast: open this URL on the MiSTer with mplayer\n' >&2
  printf '%s\n' "$stream_url"
}

wait_for_ffmpeg() {
  if [[ -n "$ffmpeg_pid" ]]; then
    if ! wait "$ffmpeg_pid"; then
      ffmpeg_pid=""
      touch "$stream_error"
      printf 'error: ffmpeg failed while exporting the MPEG-TS stream\n' >&2
      show_ffmpeg_log
      exit 1
    fi
    ffmpeg_pid=""
  fi

  touch "$stream_done"
}

# Main

main() {
  if [[ ${1:-} == "" || ${1:-} == "-h" || ${1:-} == "--help" ]]; then
    usage
    exit 0
  fi

  load_config "$@"
  validate_config
  resolve_host_ip
  prepare_workdir
  trap cleanup EXIT INT TERM

  printf 'rastercast: exporting MPEG-TS stream into %s\n' "$workdir" >&2
  start_server
  start_ffmpeg
  wait_for_stream_startup
  print_stream_url
  launch_mister
  wait_for_ffmpeg

  wait "$server_pid"
}

main "$@"
