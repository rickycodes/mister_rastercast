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
EOF
}

if [[ ${1:-} == "" || ${1:-} == "-h" || ${1:-} == "--help" ]]; then
  usage
  exit 0
fi

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
