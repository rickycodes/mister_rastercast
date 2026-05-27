#!/usr/bin/env bash

load_config() {
  local output_fps="${RASTERCAST_FPS:-}"

  cfg+=(
    [bind_addr]="${RASTERCAST_BIND_ADDR:-0.0.0.0}"
    [port]="${RASTERCAST_PORT:-8090}"
    [output_fps]="$output_fps"
    [video_bitrate]="${RASTERCAST_VIDEO_BITRATE:-700k}"
    [video_size]="${RASTERCAST_VIDEO_SIZE:-320x240}"
    [display_aspect]="${RASTERCAST_DISPLAY_ASPECT:-auto}"
    [video_fit]="${RASTERCAST_VIDEO_FIT:-auto}"
    [video_effect]="${RASTERCAST_VIDEO_EFFECT:-none}"
    [watermark_text]="${RASTERCAST_WATERMARK_TEXT:-}"
    [watermark_image]="${RASTERCAST_WATERMARK_IMAGE:-}"
    [watermark_x]="${RASTERCAST_WATERMARK_X:-}"
    [watermark_y]="${RASTERCAST_WATERMARK_Y:-}"
    [watermark_scale]="${RASTERCAST_WATERMARK_SCALE:-1}"
    [watermark_size]="${RASTERCAST_WATERMARK_SIZE:-18}"
    [watermark_margin]="${RASTERCAST_WATERMARK_MARGIN:-8}"
    [watermark_opacity]="${RASTERCAST_WATERMARK_OPACITY:-0.65}"
    [video_speed]="${RASTERCAST_VIDEO_SPEED:-1}"
    [visualizer]="${RASTERCAST_VISUALIZER:-none}"
    [projectm_bin]="${RASTERCAST_PROJECTM:-${HOME}/projects/rastercast-projectm/rastercast-projectm}"
    [projectm_presets]="${RASTERCAST_PROJECTM_PRESETS:-/usr/share/projectM/presets}"
    [projectm_preset]="${RASTERCAST_PROJECTM_PRESET:-}"
    [projectm_fps]="${RASTERCAST_PROJECTM_FPS:-${output_fps:-30}}"
    [projectm_queue_size]="${RASTERCAST_PROJECTM_QUEUE_SIZE:-1024}"
    [audio_effect]="${RASTERCAST_AUDIO_EFFECT:-none}"
    [ytdlp_mode]="${RASTERCAST_YTDLP:-auto}"
    [ytdlp_format]="${RASTERCAST_YTDLP_FORMAT:-best[height<=480][protocol^=http][vcodec!=none][acodec!=none]/best[protocol^=http][vcodec!=none][acodec!=none]}"
    [ytdlp_cookies]="${RASTERCAST_YTDLP_COOKIES:-}"
    [ytdlp_cookies_from_browser]="${RASTERCAST_YTDLP_COOKIES_FROM_BROWSER:-}"
    [ytdlp_js_runtime]="${RASTERCAST_YTDLP_JS_RUNTIME:-}"
    [ytdlp_remote_components]="${RASTERCAST_YTDLP_REMOTE_COMPONENTS:-}"
    [ytdlp_playlist_items]="${RASTERCAST_YTDLP_PLAYLIST_ITEMS:-}"
    [queue_skip_unavailable]="${RASTERCAST_QUEUE_SKIP_UNAVAILABLE:-0}"
    [loop]="${RASTERCAST_LOOP:-${RASTERCAST_STREAM_LOOP:-0}}"
    [offset]="${RASTERCAST_OFFSET:-}"
    [startup_timeout]="${RASTERCAST_STARTUP_TIMEOUT:-30}"
    [mister_auto]="${RASTERCAST_MISTER_AUTO:-1}"
    [mister_host]="${RASTERCAST_MISTER_HOST:-mister}"
    [mister_user]="${RASTERCAST_MISTER_USER:-root}"
    [mister_script]="${RASTERCAST_MISTER_SCRIPT:-/media/fat/Scripts/rastercast.sh}"
    [mister_deploy]="${RASTERCAST_MISTER_DEPLOY:-auto}"
    [mister_tty]="${RASTERCAST_MISTER_TTY:-1}"
    [mister_detach]="${RASTERCAST_MISTER_DETACH:-0}"
    [host_ip]="${RASTERCAST_HOST_IP:-}"
    [loop_logger_pid]=""
  )
}

resolve_host_ip() {
  if [[ -n ${cfg[host_ip]} ]]; then
    return
  fi

  cfg+=( [host_ip]="$(hostname -I 2>/dev/null | awk '{print $1}' || true)" )
  if [[ -z ${cfg[host_ip]} ]]; then
    cfg+=( [host_ip]=127.0.0.1 )
  fi
}

prepare_workdir() {
  local workdir

  workdir=$(mktemp -d "${TMPDIR:-/tmp}/rastercast.XXXXXX")
  cfg+=(
    [workdir]="$workdir"
    [server_pid]=""
    [ffmpeg_pid]=""
    [pcm_ffmpeg_pid]=""
    [projectm_pid]=""
    [ffmpeg_log]="${workdir}/ffmpeg.log"
    [server_log]="${workdir}/server.log"
    [mister_log]="${workdir}/mister.log"
    [stream_path]="${workdir}/stream.ts"
    [stream_done]="${workdir}/stream.done"
    [stream_error]="${workdir}/stream.error"
    [projectm_pcm_pipe]="${workdir}/projectm.pcm"
    [projectm_video_pipe]="${workdir}/projectm.rgb"
    [stream_url]="http://${cfg[host_ip]}:${cfg[port]}/stream.ts"
    [ssh_control_path]="${workdir}/ssh-control-%r@%h:%p"
    [mister_ssh_used]=""
  )

  if [[ ${RASTERCAST_DEBUG_WORKDIR:-0} == 1 ]]; then
    printf 'rastercast: workdir %s\n' "$workdir" >&2
  fi
}

validate_watermark_config() {
  if [[ -n ${cfg[watermark_text]} || -n ${cfg[watermark_image]} ]]; then
    if [[ ! ${cfg[watermark_size]} =~ ^[1-9][0-9]*$ ]]; then
      printf 'error: RASTERCAST_WATERMARK_SIZE must be a positive integer\n' >&2
      exit 1
    fi
    if [[ ! ${cfg[watermark_margin]} =~ ^[0-9]+$ ]]; then
      printf 'error: RASTERCAST_WATERMARK_MARGIN must be a non-negative integer\n' >&2
      exit 1
    fi
    if ! awk -v opacity="${cfg[watermark_opacity]}" 'BEGIN { exit !(opacity + 0 == opacity && opacity >= 0 && opacity <= 1) }'; then
      printf 'error: RASTERCAST_WATERMARK_OPACITY must be a number from 0.0 to 1.0\n' >&2
      exit 1
    fi
  fi

  if [[ -n ${cfg[watermark_x]} || -n ${cfg[watermark_y]} ]]; then
    if [[ -z ${cfg[watermark_text]} && -z ${cfg[watermark_image]} ]]; then
      printf 'error: RASTERCAST_WATERMARK_X/Y require RASTERCAST_WATERMARK_TEXT or RASTERCAST_WATERMARK_IMAGE\n' >&2
      exit 1
    fi
  fi

  if [[ -n ${cfg[watermark_image]} ]]; then
    if ! awk -v scale="${cfg[watermark_scale]}" 'BEGIN { exit !(scale + 0 == scale && scale > 0 && scale <= 1) }'; then
      printf 'error: RASTERCAST_WATERMARK_SCALE must be a number from 0.0 to 1.0\n' >&2
      exit 1
    fi

    if [[ ! -f ${cfg[watermark_image]} ]]; then
      printf 'error: RASTERCAST_WATERMARK_IMAGE file not found: %s\n' "${cfg[watermark_image]}" >&2
      exit 1
    fi

    case "${cfg[watermark_image]##*.}" in
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
  local inputs=("$@")
  local item
  local ytdlp_input_count=0

  require_command ffmpeg
  require_command python3

  case ${cfg[ytdlp_mode]} in
    auto | 1 | 0)
      ;;
    *)
      printf 'error: RASTERCAST_YTDLP must be auto, 1, or 0\n' >&2
      exit 1
      ;;
  esac

  validate_bool RASTERCAST_QUEUE_SKIP_UNAVAILABLE "${cfg[queue_skip_unavailable]}"
  validate_bool RASTERCAST_LOOP "${cfg[loop]}"
  validate_bool RASTERCAST_MISTER_DETACH "${cfg[mister_detach]}"

  if [[ -n ${cfg[offset]} && ${cfg[offset]} =~ [[:space:]] ]]; then
    printf 'error: RASTERCAST_OFFSET must not contain whitespace\n' >&2
    exit 1
  fi

  case ${cfg[video_fit]} in
    auto | contain | cover)
      ;;
    *)
      printf 'error: RASTERCAST_VIDEO_FIT must be auto, contain, or cover\n' >&2
      exit 1
      ;;
  esac

  if [[ ! ${cfg[video_size]} =~ ^[1-9][0-9]*x[1-9][0-9]*$ ]]; then
    printf 'error: RASTERCAST_VIDEO_SIZE must be WIDTHxHEIGHT, e.g. 320x240\n' >&2
    exit 1
  fi
  cfg+=( [video_width]="${cfg[video_size]%x*}" [video_height]="${cfg[video_size]#*x}" )

  if [[ ${cfg[display_aspect]} == "auto" ]]; then
    cfg+=( [display_width]="${cfg[video_width]}" [display_height]="${cfg[video_height]}" )
  elif [[ ${cfg[display_aspect]} =~ ^[1-9][0-9]*:[1-9][0-9]*$ ]]; then
    cfg+=( [display_width]="${cfg[display_aspect]%:*}" [display_height]="${cfg[display_aspect]#*:}" )
  else
    printf 'error: RASTERCAST_DISPLAY_ASPECT must be auto or WIDTH:HEIGHT, e.g. 4:3\n' >&2
    exit 1
  fi

  cfg+=( [fit_width]="$(( cfg[video_height] * cfg[display_width] / cfg[display_height] ))" [fit_height]="${cfg[video_height]}" )
  if (( cfg[fit_width] > cfg[video_width] )); then
    cfg+=( [fit_width]="${cfg[video_width]}" [fit_height]="$(( cfg[video_width] * cfg[display_height] / cfg[display_width] ))" )
  fi
  cfg+=( [fit_width]="$(( cfg[fit_width] / 2 * 2 ))" [fit_height]="$(( cfg[fit_height] / 2 * 2 ))" )

  validate_video_effects
  validate_watermark_config

  case ${cfg[visualizer]} in
    none | waves | spectrum | cqt | vectorscope | freqs | spatial | histogram | bits | projectm)
      ;;
    *)
      printf 'error: RASTERCAST_VISUALIZER must be one of: none, waves, spectrum, cqt, vectorscope, freqs, spatial, histogram, bits, projectm\n' >&2
      exit 1
      ;;
  esac

  if [[ ${cfg[visualizer]} == "projectm" ]]; then
    if [[ ! -x ${cfg[projectm_bin]} ]]; then
      printf 'error: RASTERCAST_PROJECTM helper not executable: %s\n' "${cfg[projectm_bin]}" >&2
      exit 1
    fi
    if [[ ! -d ${cfg[projectm_presets]} ]]; then
      printf 'error: RASTERCAST_PROJECTM_PRESETS directory not found: %s\n' "${cfg[projectm_presets]}" >&2
      exit 1
    fi
    if [[ -n ${cfg[projectm_preset]} && ! -f ${cfg[projectm_preset]} ]]; then
      printf 'error: RASTERCAST_PROJECTM_PRESET file not found: %s\n' "${cfg[projectm_preset]}" >&2
      exit 1
    fi
    if [[ ! ${cfg[projectm_fps]} =~ ^[1-9][0-9]*$ ]]; then
      printf 'error: RASTERCAST_PROJECTM_FPS must be a positive integer\n' >&2
      exit 1
    fi
    if [[ ! ${cfg[projectm_queue_size]} =~ ^[1-9][0-9]*$ ]]; then
      printf 'error: RASTERCAST_PROJECTM_QUEUE_SIZE must be a positive integer\n' >&2
      exit 1
    fi
  fi

  case ${cfg[audio_effect]} in
    none | echo | robot | radio | deep | chipmunk)
      ;;
    *)
      printf 'error: RASTERCAST_AUDIO_EFFECT must be one of: none, echo, robot, radio, deep, chipmunk\n' >&2
      exit 1
      ;;
  esac

  if ! awk -v speed="${cfg[video_speed]}" 'BEGIN { exit !(speed + 0 == speed && speed >= 0.5 && speed <= 2.0) }'; then
    printf 'error: RASTERCAST_VIDEO_SPEED must be a number from 0.5 to 2.0\n' >&2
    exit 1
  fi

  for item in "${inputs[@]}"; do
    if should_use_ytdlp "$item"; then
      ytdlp_input_count=$((ytdlp_input_count + 1))
      cfg+=( [input_uses_ytdlp]=1 )
      require_command yt-dlp
      if [[ -n ${cfg[ytdlp_cookies]} && ! -f ${cfg[ytdlp_cookies]} ]]; then
        printf 'error: RASTERCAST_YTDLP_COOKIES file not found: %s\n' "${cfg[ytdlp_cookies]}" >&2
        exit 1
      fi
    elif ! is_http_url "$item" && [[ ! -f "$item" ]]; then
      printf 'error: input file not found: %s\n' "$item" >&2
      exit 1
    fi
  done

  cfg+=( [input_ytdlp_count]="$ytdlp_input_count" )
}
