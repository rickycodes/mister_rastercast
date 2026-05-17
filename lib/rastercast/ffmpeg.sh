#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2154

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
    avs-feedback)
      printf '%s\n' "tmix=frames=9:weights='1 1 1 1 1 1 1 1 1',eq=contrast=1.45:saturation=1.45:brightness=-0.04,rgbashift=rh=3:bh=-3"
      ;;
    avs-grid)
      printf '%s\n' "scale=iw/2:ih/2:flags=neighbor,tile=2x2,eq=contrast=1.3:saturation=1.35"
      ;;
    avs-crt)
      printf '%s\n' "noise=alls=10:allf=t+u,eq=contrast=1.25:saturation=1.25,rgbashift=rh=2:bh=-2"
      ;;
    avs-neon)
      printf '%s\n' "edgedetect=low=0.04:high=0.18,eq=contrast=1.7:saturation=1.6,lagfun=decay=0.92"
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

drawtext_escape() {
  local value=$1
  value=${value//\\/\\\\}
  value=${value//:/\\:}
  value=${value//\'/\\\'}
  value=${value//,/\\,}
  printf '%s\n' "$value"
}

append_watermark() {
  local escaped_text
  local x_expr
  local y_expr

  if [[ -z "$watermark_text" ]]; then
    return
  fi

  escaped_text=$(drawtext_escape "$watermark_text")
  x_expr=${watermark_x:-w-tw-${watermark_margin}}
  y_expr=${watermark_y:-h-th-${watermark_margin}}
  video_filter="${video_filter},drawtext=text='${escaped_text}':x=${x_expr}:y=${y_expr}:fontsize=${watermark_size}:fontcolor=white@${watermark_opacity}:box=1:boxcolor=black@0.28:boxborderw=3"
}

build_watermark_overlay_chain() {
  local base_label=$1
  local overlay_input=$2
  local x_expr
  local y_expr

  x_expr=${watermark_x:-W-w-${watermark_margin}}
  y_expr=${watermark_y:-H-h-${watermark_margin}}
  printf '[%s]scale=iw*%s:ih*%s:flags=lanczos,format=rgba,colorchannelmixer=aa=%s[wm];[%s][wm]overlay=x=%s:y=%s:repeatlast=1:shortest=0[v]' "$overlay_input" "$watermark_scale" "$watermark_scale" "$watermark_opacity" "$base_label" "$x_expr" "$y_expr"
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
  append_watermark

  if [[ -n "$output_fps" ]]; then
    video_filter="${video_filter},fps=${output_fps}"
  fi

  if [[ "$video_speed" != "1" && "$video_speed" != "1.0" ]]; then
    video_filter="${video_filter},setpts=PTS/${video_speed}"
  fi
}

build_audio_filter() {
  audio_filter=""

  if [[ "$video_speed" != "1" && "$video_speed" != "1.0" ]]; then
    audio_filter="${audio_filter:+${audio_filter},}atempo=${video_speed}"
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
    freqs)
      printf 'showfreqs=s=%sx%s:mode=bar:ascale=cbrt:fscale=log:colors=00ff66|00ccff' "$fit_width" "$fit_height"
      ;;
    spatial)
      printf 'showspatial=s=%sx%s:win_size=4096:overlap=0.75' "$fit_width" "$fit_height"
      ;;
    histogram)
      printf 'ahistogram=s=%sx%s:scale=cbrt:ascale=log:slide=scroll' "$fit_width" "$fit_height"
      ;;
    bits)
      printf 'abitscope=s=%sx%s:colors=00ff66|00ccff|ff00cc' "$fit_width" "$fit_height"
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

  if [[ "$visualizer" == "projectm" ]]; then
    if [[ -n "$watermark_image" ]]; then
      ffmpeg_output_args=(-filter_complex "[0:v]${video_filter}[base];$(build_watermark_overlay_chain base '2:v')" -map "[v]" -map 1:a? "${ffmpeg_output_args[@]}")
    else
      ffmpeg_output_args=(-map 0:v:0 -map 1:a? -vf "$video_filter" "${ffmpeg_output_args[@]}")
    fi
  elif [[ "$visualizer" == "none" ]]; then
    if [[ -n "$watermark_image" ]]; then
      ffmpeg_output_args=(-filter_complex "[0:v]${video_filter}[base];$(build_watermark_overlay_chain base '1:v')" -map "[v]" -map 0:a? "${ffmpeg_output_args[@]}")
    else
      ffmpeg_output_args=(-map 0:v:0 -map 0:a? -vf "$video_filter" "${ffmpeg_output_args[@]}")
    fi
  else
    local effect
    local effect_filter
    local viz_filter
    viz_filter="$(visualizer_filter),setsar=1,pad=${video_width}:${video_height}:(ow-iw)/2:(oh-ih)/2:black"
    for effect in "${video_effects[@]}"; do
      effect_filter=$(video_effect_filter "$effect")
      if [[ -n "$effect_filter" ]]; then
        viz_filter="${viz_filter},${effect_filter}"
      fi
    done
    video_filter="$viz_filter"
    append_watermark
    viz_filter="$video_filter"
    if [[ -n "$output_fps" ]]; then
      viz_filter="${viz_filter},fps=${output_fps}"
    fi
    if [[ "$video_speed" != "1" && "$video_speed" != "1.0" ]]; then
      viz_filter="${viz_filter},setpts=PTS/${video_speed}"
    fi
    if [[ -n "$watermark_image" ]]; then
      ffmpeg_output_args=(-filter_complex "[0:a]${viz_filter}[base];$(build_watermark_overlay_chain base '1:v')" -map "[v]" -map 0:a:0 "${ffmpeg_output_args[@]}")
    else
      ffmpeg_output_args=(-filter_complex "[0:a]${viz_filter}[v]" -map "[v]" -map 0:a:0 "${ffmpeg_output_args[@]}")
    fi
  fi

  if [[ -n "$audio_filter" ]]; then
    ffmpeg_output_args=(-af "$audio_filter" "${ffmpeg_output_args[@]}")
  fi
}

start_projectm_pipeline() {
  mkfifo "$projectm_pcm_pipe" "$projectm_video_pipe"

  RASTERCAST_PROJECTM_WIDTH="$video_width" \
    RASTERCAST_PROJECTM_HEIGHT="$video_height" \
    RASTERCAST_PROJECTM_FPS="$projectm_fps" \
    RASTERCAST_PROJECTM_PRESETS="$projectm_presets" \
    RASTERCAST_PROJECTM_PRESET="$projectm_preset" \
    "$projectm_bin" --raw-video <"$projectm_pcm_pipe" >"$projectm_video_pipe" 2>>"${ffmpeg_log}" &
  projectm_pid=$!

  ffmpeg \
    -hide_banner \
    -loglevel error \
    -nostdin \
    -fflags +genpts \
    -f rawvideo \
    -thread_queue_size "$projectm_queue_size" \
    -pix_fmt rgb24 \
    -video_size "$video_size" \
    -framerate "$projectm_fps" \
    -i "$projectm_video_pipe" \
    -re \
    -thread_queue_size "$projectm_queue_size" \
    -f concat \
    -safe 0 \
    -protocol_whitelist file,http,https,tcp,tls,crypto,httpproxy \
    -i "$concat_list" \
    "${watermark_input_args[@]}" \
    "${ffmpeg_output_args[@]}" >"${ffmpeg_log}" 2>&1 &
  ffmpeg_pid=$!

  ffmpeg \
    -hide_banner \
    -y \
    -loglevel error \
    -nostdin \
    -re \
    -fflags +genpts \
    -thread_queue_size "$projectm_queue_size" \
    -f concat \
    -safe 0 \
    -protocol_whitelist file,http,https,tcp,tls,crypto,httpproxy \
    -i "$concat_list" \
    -map 0:a:0 \
    -vn \
    -ac 2 \
    -ar 44100 \
    -f f32le \
    "$projectm_pcm_pipe" >>"${ffmpeg_log}" 2>&1 &
  pcm_ffmpeg_pid=$!
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
  if [[ "$visualizer" == "projectm" ]]; then
    start_projectm_pipeline
  else
    ffmpeg "${ffmpeg_args[@]}" \
      -f concat \
      -safe 0 \
      -protocol_whitelist file,http,https,tcp,tls,crypto,httpproxy \
      -i "$concat_list" \
      "${watermark_input_args[@]}" \
      "${ffmpeg_output_args[@]}" >"${ffmpeg_log}" 2>&1 &
  fi
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
