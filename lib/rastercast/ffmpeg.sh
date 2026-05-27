#!/usr/bin/env bash

valid_video_effects="none, acid, trails, edges, ghost, matrix, rgbshift, negative, warp, wobble, feedback, scanwarp, avs-feedback, avs-grid, avs-crt, avs-neon"

video_effect_filter() {
  case "$1" in
    none) printf '%s\n' "" ;;
    acid) printf '%s\n' "hue=h=2*PI*t:s=2,eq=contrast=1.2:saturation=1.8" ;;
    trails) printf '%s\n' "tmix=frames=5:weights='1 1 1 1 1'" ;;
    edges) printf '%s\n' "edgedetect=low=0.1:high=0.4" ;;
    ghost) printf '%s\n' "lagfun=decay=0.9" ;;
    matrix) printf '%s\n' "eq=contrast=1.25:saturation=0.65:brightness=-0.03,colorchannelmixer=rr=0.55:rg=0.30:rb=0.05:gr=0.20:gg=0.90:gb=0.20:br=0.02:bg=0.20:bb=0.18" ;;
    rgbshift) printf '%s\n' "rgbashift=rh=4:bh=-4" ;;
    negative) printf '%s\n' "negate" ;;
    warp) printf '%s\n' "lenscorrection=k1=-0.25:k2=0.08:i=bilinear" ;;
    wobble) printf '%s\n' "rotate=0.04*sin(2*PI*t):fillcolor=black@0" ;;
    feedback) printf '%s\n' "tmix=frames=7:weights='1 1 1 1 1 1 1',eq=contrast=1.35:saturation=1.3" ;;
    scanwarp) printf '%s\n' "rgbashift=rh=4:bh=-4,noise=alls=12:allf=t+u" ;;
    avs-feedback) printf '%s\n' "tmix=frames=9:weights='1 1 1 1 1 1 1 1 1',eq=contrast=1.45:saturation=1.45:brightness=-0.04,rgbashift=rh=3:bh=-3" ;;
    avs-grid) printf '%s\n' "scale=iw/2:ih/2:flags=neighbor,tile=2x2,eq=contrast=1.3:saturation=1.35" ;;
    avs-crt) printf '%s\n' "noise=alls=10:allf=t+u,eq=contrast=1.25:saturation=1.25,rgbashift=rh=2:bh=-2" ;;
    avs-neon) printf '%s\n' "edgedetect=low=0.04:high=0.18,eq=contrast=1.7:saturation=1.6,lagfun=decay=0.92" ;;
    *) return 1 ;;
  esac
}

validate_video_effects() {
  local effect
  local -a video_effects=()

  IFS=',' read -r -a video_effects <<< "${cfg[video_effect]}"
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

build_video_filter() {
  local fit=${cfg[video_fit]}
  local filter
  local effect
  local effect_filter
  local -a video_effects=()
  local input_uses_ytdlp=${cfg[input_uses_ytdlp]:-0}
  local resolved_fit=$fit

  if [[ "$fit" == "auto" ]]; then
    if [[ "$input_uses_ytdlp" == "1" ]]; then
      fit=cover
    else
      fit=contain
    fi
  fi
  resolved_fit=$fit
  printf 'rastercast: video fit mode resolved to %s (input_uses_ytdlp=%s)\n' "$resolved_fit" "$input_uses_ytdlp" >&2

  case "$fit" in
    contain)
      filter="scale=${cfg[fit_width]}:${cfg[fit_height]}:force_original_aspect_ratio=decrease:force_divisible_by=2,setsar=1,pad=${cfg[video_width]}:${cfg[video_height]}:(ow-iw)/2:(oh-ih)/2:black"
      ;;
    cover)
      filter="scale=${cfg[fit_width]}:${cfg[fit_height]}:force_original_aspect_ratio=increase:force_divisible_by=2,setsar=1,crop=${cfg[fit_width]}:${cfg[fit_height]},pad=${cfg[video_width]}:${cfg[video_height]}:(ow-iw)/2:(oh-ih)/2:black"
      ;;
  esac

  IFS=',' read -r -a video_effects <<< "${cfg[video_effect]}"
  if [[ ${#video_effects[@]} -eq 0 ]]; then
    video_effects=(none)
  fi

  for effect in "${video_effects[@]}"; do
    effect_filter=$(video_effect_filter "$effect")
    if [[ -n "$effect_filter" ]]; then
      filter="${filter},${effect_filter}"
    fi
  done

  if [[ -n ${cfg[watermark_text]} ]]; then
    local escaped_text x_expr y_expr
    escaped_text=$(drawtext_escape "${cfg[watermark_text]}")
    x_expr=${cfg[watermark_x]:-w-tw-${cfg[watermark_margin]}}
    y_expr=${cfg[watermark_y]:-h-th-${cfg[watermark_margin]}}
    filter="${filter},drawtext=text='${escaped_text}':x=${x_expr}:y=${y_expr}:fontsize=${cfg[watermark_size]}:fontcolor=white@${cfg[watermark_opacity]}:box=1:boxcolor=black@0.28:boxborderw=3"
  fi

  if [[ -n ${cfg[output_fps]} ]]; then
    filter="${filter},fps=${cfg[output_fps]}"
  fi

  if [[ ${cfg[video_speed]} != "1" && ${cfg[video_speed]} != "1.0" ]]; then
    filter="${filter},setpts=PTS/${cfg[video_speed]}"
  fi

  printf '%s\n' "$filter"
}

build_audio_filter() {
  local filter=""

  if [[ ${cfg[video_speed]} != "1" && ${cfg[video_speed]} != "1.0" ]]; then
    filter="atempo=${cfg[video_speed]}"
  fi

  case "${cfg[audio_effect]}" in
    none) ;;
    echo) filter="${filter:+${filter},}aecho=0.8:0.88:60:0.35" ;;
    robot) filter="${filter:+${filter},}afftfilt=real='hypot(re,im)*sin(0)':imag='hypot(re,im)*cos(0)',aresample=44100" ;;
    radio) filter="${filter:+${filter},}highpass=f=300,lowpass=f=3000,acompressor=threshold=-18dB:ratio=4:attack=5:release=80" ;;
    deep) filter="${filter:+${filter},}asetrate=44100*0.85,aresample=44100,atempo=1.17647" ;;
    chipmunk) filter="${filter:+${filter},}asetrate=44100*1.25,aresample=44100,atempo=0.8" ;;
  esac

  printf '%s\n' "$filter"
}

visualizer_filter() {
  case "${cfg[visualizer]}" in
    waves) printf 'showwaves=s=%sx%s:mode=cline:colors=00ff66|00ccff:scale=sqrt' "${cfg[fit_width]}" "${cfg[fit_height]}" ;;
    spectrum) printf 'showspectrum=s=%sx%s:mode=combined:color=intensity:scale=cbrt:slide=scroll' "${cfg[fit_width]}" "${cfg[fit_height]}" ;;
    cqt) printf 'showcqt=s=%sx%s:count=1' "${cfg[fit_width]}" "${cfg[fit_height]}" ;;
    vectorscope) printf 'avectorscope=s=%sx%s:mode=lissajous:zoom=1.3,format=yuv420p' "${cfg[fit_width]}" "${cfg[fit_height]}" ;;
    freqs) printf 'showfreqs=s=%sx%s:mode=bar:ascale=cbrt:fscale=log:colors=00ff66|00ccff' "${cfg[fit_width]}" "${cfg[fit_height]}" ;;
    spatial) printf 'showspatial=s=%sx%s:win_size=4096:overlap=0.75' "${cfg[fit_width]}" "${cfg[fit_height]}" ;;
    histogram) printf 'ahistogram=s=%sx%s:scale=cbrt:ascale=log:slide=scroll' "${cfg[fit_width]}" "${cfg[fit_height]}" ;;
    bits) printf 'abitscope=s=%sx%s:colors=00ff66|00ccff|ff00cc' "${cfg[fit_width]}" "${cfg[fit_height]}" ;;
  esac
}

build_ffmpeg_common_args() {
  ffmpeg_common_args=(
    -hide_banner
    -loglevel error
    -nostdin
    -re
    -fflags
    +genpts+discardcorrupt
    -err_detect
    ignore_err
  )
}

build_concat_input_args() {
  concat_input_args=( )
  if is_enabled "${cfg[loop]}"; then
    concat_input_args+=( -stream_loop -1 )
  fi
  if [[ -n ${cfg[offset]} ]]; then
    concat_input_args+=( -ss "${cfg[offset]}" )
  fi
  concat_input_args+=( -f concat -safe 0 -protocol_whitelist "file,http,https,tcp,tls,crypto,httpproxy" -i "${cfg[concat_list]}" )
}

build_projectm_video_input_args() {
  projectm_video_input_args=( -f rawvideo -thread_queue_size "${cfg[projectm_queue_size]}" -pix_fmt rgb24 -video_size "${cfg[video_size]}" -framerate "${cfg[projectm_fps]}" -i "${cfg[projectm_video_pipe]}" )
}

build_projectm_pcm_input_args() {
  projectm_pcm_input_args=( -thread_queue_size "${cfg[projectm_queue_size]}" )
  if is_enabled "${cfg[loop]}"; then
    projectm_pcm_input_args+=( -stream_loop -1 )
  fi
  if [[ -n ${cfg[offset]} ]]; then
    projectm_pcm_input_args+=( -ss "${cfg[offset]}" )
  fi
  projectm_pcm_input_args+=( -f concat -safe 0 -protocol_whitelist "file,http,https,tcp,tls,crypto,httpproxy" -i "${cfg[concat_list]}" )
}

build_watermark_input_args() {
  watermark_input_args=()

  if [[ -n ${cfg[watermark_image]} ]]; then
    watermark_input_args=( -i "${cfg[watermark_image]}" )
  fi
}

build_watermark_overlay_chain() {
  local base_label=$1
  local overlay_input=$2
  local x_expr=${cfg[watermark_x]:-W-w-${cfg[watermark_margin]}}
  local y_expr=${cfg[watermark_y]:-H-h-${cfg[watermark_margin]}}

  printf '[%s]scale=iw*%s:ih*%s:flags=lanczos,format=rgba,colorchannelmixer=aa=%s[wm];[%s][wm]overlay=x=%s:y=%s:repeatlast=1:shortest=0[v]' "$overlay_input" "${cfg[watermark_scale]}" "${cfg[watermark_scale]}" "${cfg[watermark_opacity]}" "$base_label" "$x_expr" "$y_expr"
}

build_ffmpeg_output_args() {
  local video_filter=$1
  local audio_filter=$2
  local viz_filter
  local overlay_chain
  local overlay_input

  ffmpeg_output_args=(
    -c:v libx264
    -preset ultrafast
    -tune zerolatency
    -profile:v baseline
    -level 3.0
    -b:v "${cfg[video_bitrate]}"
    -maxrate "${cfg[video_bitrate]}"
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
  )

  if [[ ${cfg[visualizer]} == "projectm" ]]; then
    if [[ -n ${cfg[watermark_image]} ]]; then
      overlay_input='2:v'
      overlay_chain=$(build_watermark_overlay_chain base "$overlay_input")
      ffmpeg_output_args+=( -filter_complex "[0:v]${video_filter}[base];${overlay_chain}" -map "[v]" -map 1:a? )
    else
      ffmpeg_output_args+=( -map 0:v:0 -map 1:a? -vf "$video_filter" )
    fi
  elif [[ ${cfg[visualizer]} == "none" ]]; then
    if [[ -n ${cfg[watermark_image]} ]]; then
      overlay_input='1:v'
      overlay_chain=$(build_watermark_overlay_chain base "$overlay_input")
      ffmpeg_output_args+=( -filter_complex "[0:v]${video_filter}[base];${overlay_chain}" -map "[v]" -map 0:a? )
    else
      ffmpeg_output_args+=( -map 0:v:0 -map 0:a? -vf "$video_filter" )
    fi
  else
    viz_filter="$(visualizer_filter),setsar=1,pad=${cfg[video_width]}:${cfg[video_height]}:(ow-iw)/2:(oh-ih)/2:black"
    if [[ -n ${cfg[watermark_image]} ]]; then
      overlay_input='1:v'
      overlay_chain=$(build_watermark_overlay_chain base "$overlay_input")
      ffmpeg_output_args+=( -filter_complex "[0:a]${viz_filter}[base];${overlay_chain}" -map "[v]" -map 0:a:0 )
    else
      ffmpeg_output_args+=( -filter_complex "[0:a]${viz_filter}[v]" -map "[v]" -map 0:a:0 )
    fi
  fi

  if [[ -n "$audio_filter" ]]; then
    ffmpeg_output_args+=( -af "$audio_filter" )
  fi

  ffmpeg_output_args+=( -f mpegts "${cfg[stream_path]}" )
}

start_projectm_pipeline() {
  mkfifo "${cfg[projectm_pcm_pipe]}" "${cfg[projectm_video_pipe]}"

  RASTERCAST_PROJECTM_WIDTH="${cfg[video_width]}" \
    RASTERCAST_PROJECTM_HEIGHT="${cfg[video_height]}" \
    RASTERCAST_PROJECTM_FPS="${cfg[projectm_fps]}" \
    RASTERCAST_PROJECTM_PRESETS="${cfg[projectm_presets]}" \
    RASTERCAST_PROJECTM_PRESET="${cfg[projectm_preset]}" \
    "${cfg[projectm_bin]}" --raw-video <"${cfg[projectm_pcm_pipe]}" >"${cfg[projectm_video_pipe]}" 2>>"${cfg[ffmpeg_log]}" &
  cfg+=( [projectm_pid]="$!" )

  ffmpeg "${ffmpeg_common_args[@]}" \
    "${projectm_video_input_args[@]}" \
    "${concat_input_args[@]}" \
    "${watermark_input_args[@]}" \
    "${ffmpeg_output_args[@]}" >"${cfg[ffmpeg_log]}" 2>&1 &
  cfg+=( [ffmpeg_pid]="$!" )

  ffmpeg -y "${ffmpeg_common_args[@]}" \
    "${projectm_pcm_input_args[@]}" \
    -map 0:a:0 \
    -vn \
    -ac 2 \
    -ar 44100 \
    -f f32le \
    "${cfg[projectm_pcm_pipe]}" >>"${cfg[ffmpeg_log]}" 2>&1 &
  cfg+=( [pcm_ffmpeg_pid]="$!" )
}

start_ffmpeg() {
  build_ytdlp_args
  write_concat_list "$@"
  build_watermark_input_args

  video_filter=$(build_video_filter)
  audio_filter=$(build_audio_filter)

  build_ffmpeg_common_args
  build_concat_input_args
  build_projectm_video_input_args
  build_projectm_pcm_input_args
  build_ffmpeg_output_args "$video_filter" "$audio_filter"

  if [[ ${cfg[visualizer]} == "projectm" ]]; then
    start_projectm_pipeline
  else
    ffmpeg "${ffmpeg_common_args[@]}" \
      "${concat_input_args[@]}" \
      "${watermark_input_args[@]}" \
      "${ffmpeg_output_args[@]}" >"${cfg[ffmpeg_log]}" 2>&1 &
    cfg+=( [ffmpeg_pid]="$!" )
  fi
}

stream_is_ready() {
  [[ -s ${cfg[stream_path]} ]]
}

wait_for_stream_startup() {
  local startup_timeout=${cfg[startup_timeout]}
  local deadline=$((SECONDS + startup_timeout))

  while (( SECONDS < deadline )); do
    if stream_is_ready; then
      return
    fi

    if ! kill -0 "${cfg[ffmpeg_pid]}" 2>/dev/null; then
      if wait "${cfg[ffmpeg_pid]}"; then
        return
      fi
      printf 'error: ffmpeg failed while exporting the MPEG-TS stream\n' >&2
      show_ffmpeg_log "${cfg[ffmpeg_log]}"
      exit 1
    fi
    sleep 0.1
  done

  if ! stream_is_ready; then
    printf 'error: ffmpeg did not produce a playable MPEG-TS stream within %ss\n' "$startup_timeout" >&2
    show_ffmpeg_log "${cfg[ffmpeg_log]}"
    exit 1
  fi
}

print_stream_url() {
  printf 'rastercast: serving %s\n' "${cfg[stream_url]}" >&2
  printf 'rastercast: open this URL on the MiSTer with mplayer\n' >&2
  printf '%s\n' "${cfg[stream_url]}"
}

wait_for_ffmpeg() {
  if [[ -n ${cfg[ffmpeg_pid]} ]]; then
    if ! wait "${cfg[ffmpeg_pid]}"; then
      cfg+=( [ffmpeg_pid]="" )
      cfg+=( [stream_error]=1 )
      printf 'error: ffmpeg failed while exporting the MPEG-TS stream\n' >&2
      show_ffmpeg_log "${cfg[ffmpeg_log]}"
      exit 1
    fi
    cfg+=( [ffmpeg_pid]="" )
  fi

  cfg+=( [stream_done]=1 )
}
