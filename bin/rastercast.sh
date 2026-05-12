#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: rastercast.sh <video-file>

Environment:
  RASTERCAST_BIND_ADDR   HTTP bind address (default: 0.0.0.0)
  RASTERCAST_HOST_IP     Host/IP printed in the playback URL (auto-detected by default)
  RASTERCAST_PORT        HTTP port (default: 8090)
  RASTERCAST_FPS         Optional output video FPS override, e.g. 30000/1001
  RASTERCAST_VIDEO_BITRATE  Output video bitrate (default: 1000k)
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

if [[ ${1:-} == "" || ${1:-} == "-h" || ${1:-} == "--help" ]]; then
  usage
  exit 0
fi

require_command ffmpeg
require_command python3

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_dir=$(cd -- "${script_dir}/.." && pwd)

input=$1
if [[ ! -f "$input" ]]; then
  printf 'error: input file not found: %s\n' "$input" >&2
  exit 1
fi

bind_addr=${RASTERCAST_BIND_ADDR:-0.0.0.0}
port=${RASTERCAST_PORT:-8090}
output_fps=${RASTERCAST_FPS:-}
video_bitrate=${RASTERCAST_VIDEO_BITRATE:-1000k}
startup_timeout=${RASTERCAST_STARTUP_TIMEOUT:-30}
mister_auto=${RASTERCAST_MISTER_AUTO:-1}
mister_host=${RASTERCAST_MISTER_HOST:-mister}
mister_user=${RASTERCAST_MISTER_USER:-root}
mister_script=${RASTERCAST_MISTER_SCRIPT:-/media/fat/Scripts/rastercast.sh}
mister_deploy=${RASTERCAST_MISTER_DEPLOY:-auto}
mister_tty=${RASTERCAST_MISTER_TTY:-1}

host_ip=${RASTERCAST_HOST_IP:-}
if [[ -z "$host_ip" ]]; then
  host_ip=$(hostname -I 2>/dev/null | awk '{print $1}' || true)
  if [[ -z "${host_ip:-}" ]]; then
    host_ip=127.0.0.1
  fi
fi
workdir=$(mktemp -d "${TMPDIR:-/tmp}/rastercast.XXXXXX")
server_pid=""
ffmpeg_pid=""
ffmpeg_log="${workdir}/ffmpeg.log"
server_log="${workdir}/server.log"
stream_done="${workdir}/stream.done"
stream_error="${workdir}/stream.error"
ssh_control_path="${workdir}/ssh-control-%r@%h:%p"
ssh_opts=(-o ControlMaster=auto -o ControlPersist=60 -o "ControlPath=${ssh_control_path}")
mister_ssh_used=""

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

run_mister_ssh() {
  mister_ssh_used=1
  # shellcheck disable=SC2029
  ssh "${ssh_opts[@]}" "${mister_user}@${mister_host}" "$@"
}

run_mister_playback() {
  case "$mister_tty" in
    1 | yes | true)
      mister_ssh_used=1
      # shellcheck disable=SC2029
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
trap cleanup EXIT INT TERM

printf 'rastercast: exporting MPEG-TS stream into %s\n' "$workdir" >&2

python3 - "$bind_addr" "$port" "$workdir" >"${server_log}" 2>&1 <<'PY' &
import http.server
import os
import socketserver
import sys
import time
from urllib.parse import unquote, urlparse

bind_addr = sys.argv[1]
port = int(sys.argv[2])
workdir = sys.argv[3]

class ThreadingHTTPServer(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True

class RastercastHandler(http.server.BaseHTTPRequestHandler):
    def end_headers(self):
        self.send_header("Cache-Control", "no-store")
        self.send_header("Pragma", "no-cache")
        self.send_header("Expires", "0")
        super().end_headers()

    def do_GET(self):
        path = unquote(urlparse(self.path).path)
        if path == "/stream.ts":
            self.stream_ts()
            return
        self.send_error(404, "not found")

    def stream_ts(self):
        stream_path = os.path.join(workdir, "stream.ts")
        done_path = os.path.join(workdir, "stream.done")
        error_path = os.path.join(workdir, "stream.error")
        deadline = time.monotonic() + 30

        while not os.path.exists(stream_path):
            if os.path.exists(error_path):
                self.send_error(500, "ffmpeg failed")
                return
            if time.monotonic() >= deadline:
                self.send_error(404, "stream not ready")
                return
            time.sleep(0.1)

        self.send_response(200)
        self.send_header("Content-Type", "video/mp2t")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Accept-Ranges", "none")
        self.send_header("Connection", "close")
        self.end_headers()

        try:
            with open(stream_path, "rb", buffering=0) as stream:
                while True:
                    chunk = stream.read(64 * 1024)
                    if chunk:
                        self.wfile.write(chunk)
                        self.wfile.flush()
                        continue
                    if os.path.exists(done_path) or os.path.exists(error_path):
                        break
                    time.sleep(0.1)
        except (BrokenPipeError, ConnectionResetError):
            return

server = ThreadingHTTPServer((bind_addr, port), RastercastHandler)
server.serve_forever()
PY
server_pid=$!
sleep 0.1
if ! kill -0 "$server_pid" 2>/dev/null; then
  printf 'error: HTTP server failed to start on %s:%s\n' "$bind_addr" "$port" >&2
  show_server_log
  exit 1
fi

video_filter="scale=320:240:force_original_aspect_ratio=decrease,pad=320:240:(ow-iw)/2:(oh-ih)/2:black"
if [[ -n "$output_fps" ]]; then
  video_filter="${video_filter},fps=${output_fps}"
fi

ffmpeg \
  -hide_banner \
  -loglevel error \
  -nostdin \
  -re \
  -fflags +genpts \
  -i "$input" \
  -map 0:v:0 \
  -map 0:a? \
  -vf "$video_filter" \
  -c:v libx264 \
  -preset ultrafast \
  -tune zerolatency \
  -profile:v baseline \
  -level 3.0 \
  -b:v "$video_bitrate" \
  -maxrate "$video_bitrate" \
  -bufsize 2000k \
  -pix_fmt yuv420p \
  -g 60 \
  -keyint_min 60 \
  -sc_threshold 0 \
  -c:a mp2 \
  -b:a 128k \
  -ar 44100 \
  -ac 2 \
  -muxpreload 0 \
  -muxdelay 0 \
  -mpegts_flags +resend_headers \
  -avoid_negative_ts make_zero \
  -f mpegts \
  "${workdir}/stream.ts" >"${ffmpeg_log}" 2>&1 &
ffmpeg_pid=$!
stream_path="${workdir}/stream.ts"
stream_url="http://${host_ip}:${port}/stream.ts"

stream_is_ready() {
  [[ -s "$stream_path" ]]
}

deadline=$((SECONDS + startup_timeout))
while (( SECONDS < deadline )); do
  if stream_is_ready; then
    break
  fi
  if ! kill -0 "${ffmpeg_pid}" 2>/dev/null; then
    if wait "${ffmpeg_pid}"; then
      break
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

printf 'rastercast: serving %s\n' "$stream_url" >&2
printf 'rastercast: open this URL on the MiSTer with mplayer\n' >&2
printf '%s\n' "$stream_url"
launch_mister

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

wait "$server_pid"
