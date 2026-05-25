#!/usr/bin/env bash
set -euo pipefail

repo_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
case_dirs=()

cleanup() {
  local dir

  for dir in "${case_dirs[@]:-}"; do
    rm -rf -- "$dir"
  done
}

trap cleanup EXIT

fail() {
  printf 'smoke: %s\n' "$1" >&2
  exit 1
}

assert_contains() {
  local file=$1
  local needle=$2

  if ! grep -Fq -- "$needle" "$file"; then
    printf 'smoke: expected to find %s in %s\n' "$needle" "$file" >&2
    sed -n '1,200p' "$file" >&2 || true
    exit 1
  fi
}

assert_not_contains() {
  local file=$1
  local needle=$2

  if grep -Fq -- "$needle" "$file"; then
    printf 'smoke: did not expect to find %s in %s\n' "$needle" "$file" >&2
    sed -n '1,200p' "$file" >&2 || true
    exit 1
  fi
}

wait_for_line() {
  local file=$1
  local needle=$2
  local deadline=$((SECONDS + 15))

  while (( SECONDS < deadline )); do
    if grep -Fq -- "$needle" "$file"; then
      return 0
    fi
    sleep 0.1
  done

  printf 'smoke: timed out waiting for %s in %s\n' "$needle" "$file" >&2
  sed -n '1,200p' "$file" >&2 || true
  return 1
}

pick_port() {
  python3 - <<'PY'
import socket
sock = socket.socket()
sock.bind(("127.0.0.1", 0))
print(sock.getsockname()[1])
sock.close()
PY
}

setup_case() {
  local case_name=$1
  local case_dir

  case_dir=$(mktemp -d "${TMPDIR:-/tmp}/rastercast-smoke.${case_name}.XXXXXX")
  case_dirs+=( "$case_dir" )
  printf '%s\n' "$case_dir"
}

run_case() {
  local case_name=$1
  shift
  local case_dir
  local log_file
  local stub_dir
  local port
  local output_url
  local pid
  local exit_status=0
  local env_args=()
  local -a input_args=("$@")

  case_dir=$(setup_case "$case_name")
  log_file="${case_dir}/rastercast.log"
  stub_dir="${case_dir}/bin"
  mkdir -p "$stub_dir"
  port=$(pick_port)
  output_url="http://127.0.0.1:${port}/stream.ts"

  env_args=(
    PATH="${stub_dir}:${PATH}"
    RASTERCAST_BIND_ADDR=127.0.0.1
    RASTERCAST_HOST_IP=127.0.0.1
    RASTERCAST_PORT="${port}"
    RASTERCAST_STARTUP_TIMEOUT=5
    RASTERCAST_MISTER_AUTO=0
  )

  case "$case_name" in
    playlist)
      env_args+=( RASTERCAST_YTDLP_PLAYLIST_ITEMS=1:2 )
      ;;
    deploy)
      env_args+=( RASTERCAST_MISTER_AUTO=1 )
      env_args+=( RASTERCAST_MISTER_DEPLOY=always )
      ;;
    watermark)
      env_args+=( RASTERCAST_WATERMARK_IMAGE="${case_dir}/watermark.png" )
      : >"${case_dir}/watermark.png"
      ;;
    projectm)
      env_args+=(
        RASTERCAST_VISUALIZER=projectm
        RASTERCAST_PROJECTM="${stub_dir}/rastercast-projectm"
        RASTERCAST_PROJECTM_PRESETS="${case_dir}/presets"
        RASTERCAST_PROJECTM_PRESET="${case_dir}/preset.milk"
      )
      mkdir -p "${case_dir}/presets"
      : >"${case_dir}/preset.milk"
      ;;
  esac

  cat >>"${stub_dir}/ffmpeg" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
log_file=${RASTERCAST_SMOKE_LOG:?}
printf 'ffmpeg %s\n' "$*" >>"$log_file"
output=${@: -1}
  case "$output" in
  *.ts)
    printf 'stream\n' >"$output"
    trap 'exit 0' TERM INT
    while :; do sleep 1; done
    ;;
  *)
    : >"$output"
    exit 0
    ;;
esac
EOF
  chmod +x "${stub_dir}/ffmpeg"

cat >"${stub_dir}/yt-dlp" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
log_file=${RASTERCAST_SMOKE_LOG:?}
printf 'yt-dlp %s\n' "$*" >>"$log_file"

case " $* " in
  *" --flat-playlist --print extractor_key "*)
    if [[ ${*: -1} == *playlist* ]]; then
      printf 'YoutubeTab\n'
    else
      printf 'video\n'
    fi
    ;;
  *" --flat-playlist --print webpage_url "*)
    printf 'https://example.com/video-1\n'
    printf 'https://example.com/video-2\n'
    ;;
  *" --no-playlist --no-part --no-mtime --remux-video mkv --output "*)
    output=
    prev=
    for arg in "$@"; do
      if [[ "$prev" == "--output" ]]; then
        output=$arg
        break
      fi
      prev=$arg
    done
    if [[ -n "$output" ]]; then
      : >"$output"
      printf '%s\n' "$output"
    fi
    ;;
  *)
    printf 'https://media.example/video.mp4\n'
    ;;
esac
EOF
  chmod +x "${stub_dir}/yt-dlp"

  cat >"${stub_dir}/rastercast-projectm" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
log_file=${RASTERCAST_SMOKE_LOG:?}
printf 'projectm %s\n' "$*" >>"$log_file"
trap 'exit 0' TERM INT
while :; do sleep 1; done
EOF
  chmod +x "${stub_dir}/rastercast-projectm"

  cat >"${stub_dir}/ssh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
log_file=${RASTERCAST_SMOKE_LOG:?}
printf 'ssh %s\n' "$*" >>"$log_file"
EOF
  chmod +x "${stub_dir}/ssh"

  cat >"${stub_dir}/scp" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
log_file=${RASTERCAST_SMOKE_LOG:?}
printf 'scp %s\n' "$*" >>"$log_file"
EOF
  chmod +x "${stub_dir}/scp"

  env_args+=( RASTERCAST_SMOKE_LOG="$log_file" )

  (
    cd "$repo_dir"
    env "${env_args[@]}" bash bin/rastercast.sh "${input_args[@]}"
  ) >"$log_file" 2>&1 &
  pid=$!

  if ! wait_for_line "$log_file" "rastercast: serving ${output_url}"; then
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    fail "${case_name} did not reach stream startup"
  fi

  kill "$pid" 2>/dev/null || true
  wait "$pid" || exit_status=$?
  printf 'smoke: %s exited with %s\n' "$case_name" "$exit_status" >&2

  case "$case_name" in
    local)
      assert_contains "$log_file" "rastercast: queue has 1 item(s)"
      assert_not_contains "$log_file" "yt-dlp "
      ;;
    youtube)
      assert_contains "$log_file" "rastercast: caching URL input with yt-dlp:"
      assert_contains "$log_file" "rastercast: normalizing cached media file:"
      ;;
    playlist)
      assert_contains "$log_file" "rastercast: expanding playlist with yt-dlp:"
      assert_contains "$log_file" "rastercast: queue has 2 item(s)"
      assert_contains "$log_file" "--flat-playlist --print webpage_url"
      ;;
    projectm)
      assert_contains "$log_file" "rastercast: queue has 1 item(s)"
      ;;
    deploy)
      assert_contains "$log_file" "rastercast: deploying MiSTer script"
      assert_contains "$log_file" "scp "
      ;;
    watermark)
      assert_contains "$log_file" "watermark.png"
      ;;
  esac
}

main() {
  local local_case_dir
  local local_file

  local_case_dir=$(setup_case local-file)
  local_file="${local_case_dir}/video.mkv"
  : >"$local_file"
  run_case local "$local_file"

  run_case youtube "https://www.youtube.com/watch?v=VIDEO_ID"
  run_case playlist "https://www.youtube.com/playlist?list=PLAYLIST_ID"
  run_case deploy "$local_file"
  run_case watermark "$local_file"
  run_case projectm "$local_file"
}

main "$@"
