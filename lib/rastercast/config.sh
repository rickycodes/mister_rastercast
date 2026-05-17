#!/usr/bin/env bash
# shellcheck disable=SC2034

load_config() {
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
  watermark_text=${RASTERCAST_WATERMARK_TEXT:-}
  watermark_image=${RASTERCAST_WATERMARK_IMAGE:-}
  watermark_x=${RASTERCAST_WATERMARK_X:-}
  watermark_y=${RASTERCAST_WATERMARK_Y:-}
  watermark_scale=${RASTERCAST_WATERMARK_SCALE:-1}
  watermark_size=${RASTERCAST_WATERMARK_SIZE:-18}
  watermark_margin=${RASTERCAST_WATERMARK_MARGIN:-8}
  watermark_opacity=${RASTERCAST_WATERMARK_OPACITY:-0.65}
  video_speed=${RASTERCAST_VIDEO_SPEED:-1}
  visualizer=${RASTERCAST_VISUALIZER:-none}
  projectm_bin=${RASTERCAST_PROJECTM:-${HOME}/projects/rastercast-projectm/rastercast-projectm}
  projectm_presets=${RASTERCAST_PROJECTM_PRESETS:-/usr/share/projectM/presets}
  projectm_preset=${RASTERCAST_PROJECTM_PRESET:-}
  projectm_fps=${RASTERCAST_PROJECTM_FPS:-${output_fps:-30}}
  projectm_queue_size=${RASTERCAST_PROJECTM_QUEUE_SIZE:-1024}
  audio_effect=${RASTERCAST_AUDIO_EFFECT:-none}
  ytdlp_format=${RASTERCAST_YTDLP_FORMAT:-best[height<=480][protocol^=http][vcodec!=none][acodec!=none]/best[protocol^=http][vcodec!=none][acodec!=none]/best[height<=480][vcodec!=none][acodec!=none]/best[vcodec!=none][acodec!=none]}
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
  mister_detach=${RASTERCAST_MISTER_DETACH:-0}

  host_ip=${RASTERCAST_HOST_IP:-}
  watermark_input_args=()
  if [[ -n "$watermark_image" ]]; then
    watermark_input_args=(-i "$watermark_image")
  fi
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
  pcm_ffmpeg_pid=""
  projectm_pid=""
  ffmpeg_log="${workdir}/ffmpeg.log"
  server_log="${workdir}/server.log"
  stream_path="${workdir}/stream.ts"
  stream_done="${workdir}/stream.done"
  stream_error="${workdir}/stream.error"
  projectm_pcm_pipe="${workdir}/projectm.pcm"
  projectm_video_pipe="${workdir}/projectm.rgb"
  stream_url="http://${host_ip}:${port}/stream.ts"
  ssh_control_path="${workdir}/ssh-control-%r@%h:%p"
  ssh_opts=(
    -o ControlMaster=auto
    -o ControlPersist=60
    -o ServerAliveInterval=15
    -o ServerAliveCountMax=3
    -o "ControlPath=${ssh_control_path}"
  )
  mister_ssh_used=""
}

validate_watermark_config() {
  if [[ -n "$watermark_text" || -n "$watermark_image" ]]; then
    if [[ ! "$watermark_size" =~ ^[1-9][0-9]*$ ]]; then
      printf 'error: RASTERCAST_WATERMARK_SIZE must be a positive integer\n' >&2
      exit 1
    fi
    if [[ ! "$watermark_margin" =~ ^[0-9]+$ ]]; then
      printf 'error: RASTERCAST_WATERMARK_MARGIN must be a non-negative integer\n' >&2
      exit 1
    fi
    if ! awk -v opacity="$watermark_opacity" 'BEGIN { exit !(opacity + 0 == opacity && opacity >= 0 && opacity <= 1) }'; then
      printf 'error: RASTERCAST_WATERMARK_OPACITY must be a number from 0.0 to 1.0\n' >&2
      exit 1
    fi
  fi

  if [[ -n "$watermark_x" || -n "$watermark_y" ]]; then
    if [[ -z "$watermark_text" && -z "$watermark_image" ]]; then
      printf 'error: RASTERCAST_WATERMARK_X/Y require RASTERCAST_WATERMARK_TEXT or RASTERCAST_WATERMARK_IMAGE\n' >&2
      exit 1
    fi
  fi

  if [[ -n "$watermark_image" ]]; then
    if ! awk -v scale="$watermark_scale" 'BEGIN { exit !(scale + 0 == scale && scale > 0 && scale <= 1) }'; then
      printf 'error: RASTERCAST_WATERMARK_SCALE must be a number from 0.0 to 1.0\n' >&2
      exit 1
    fi

    if [[ ! -f "$watermark_image" ]]; then
      printf 'error: RASTERCAST_WATERMARK_IMAGE file not found: %s\n' "$watermark_image" >&2
      exit 1
    fi

    case "${watermark_image##*.}" in
      png | webp | svg | PNG | WEBP | SVG)
        ;;
      *)
        printf 'error: RASTERCAST_WATERMARK_IMAGE must be a .png, .webp, or .svg file\n' >&2
        exit 1
        ;;
    esac
  fi
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
  validate_bool RASTERCAST_MISTER_DETACH "$mister_detach"

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
  validate_watermark_config

  case "$visualizer" in
    none | waves | spectrum | cqt | vectorscope | freqs | spatial | histogram | bits | projectm)
      ;;
    *)
      printf 'error: RASTERCAST_VISUALIZER must be one of: none, waves, spectrum, cqt, vectorscope, freqs, spatial, histogram, bits, projectm\n' >&2
      exit 1
      ;;
  esac

  if [[ "$visualizer" == "projectm" ]]; then
    if [[ ! -x "$projectm_bin" ]]; then
      printf 'error: RASTERCAST_PROJECTM helper not executable: %s\n' "$projectm_bin" >&2
      exit 1
    fi
    if [[ ! -d "$projectm_presets" ]]; then
      printf 'error: RASTERCAST_PROJECTM_PRESETS directory not found: %s\n' "$projectm_presets" >&2
      exit 1
    fi
    if [[ -n "$projectm_preset" && ! -f "$projectm_preset" ]]; then
      printf 'error: RASTERCAST_PROJECTM_PRESET file not found: %s\n' "$projectm_preset" >&2
      exit 1
    fi
    if [[ ! "$projectm_fps" =~ ^[1-9][0-9]*$ ]]; then
      printf 'error: RASTERCAST_PROJECTM_FPS must be a positive integer\n' >&2
      exit 1
    fi
    if [[ ! "$projectm_queue_size" =~ ^[1-9][0-9]*$ ]]; then
      printf 'error: RASTERCAST_PROJECTM_QUEUE_SIZE must be a positive integer\n' >&2
      exit 1
    fi
  fi

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
