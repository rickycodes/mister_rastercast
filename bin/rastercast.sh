#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: rastercast.sh <video-file>

Environment:
  RASTERCAST_BIND_ADDR   HTTP bind address (default: 0.0.0.0)
  RASTERCAST_HOST_IP     Host/IP printed in the playback URL (auto-detected by default)
  RASTERCAST_PORT        HTTP port (default: 8090)
  RASTERCAST_TRANSPORT   ts, hls, or hls-vod (default: ts)
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
transport=${RASTERCAST_TRANSPORT:-ts}
startup_timeout=${RASTERCAST_STARTUP_TIMEOUT:-30}

if [[ "$transport" != "hls-vod" && "$transport" != "hls" && "$transport" != "ts" ]]; then
  printf 'error: RASTERCAST_TRANSPORT must be ts, hls, or hls-vod, got: %s\n' "$transport" >&2
  exit 1
fi

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

printf 'rastercast: exporting %s stream into %s\n' "$transport" "$workdir" >&2

python3 - "$bind_addr" "$port" "$workdir" >"${server_log}" 2>&1 <<'PY' &
import functools
import http.server
import os
import socketserver
import sys
import time
import threading
from urllib.parse import unquote, urlparse

bind_addr = sys.argv[1]
port = int(sys.argv[2])
workdir = sys.argv[3]
playlist_state = {}
playlist_lock = threading.Lock()

class ThreadingHTTPServer(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True

class RastercastHandler(http.server.SimpleHTTPRequestHandler):
    extensions_map = {
        **http.server.SimpleHTTPRequestHandler.extensions_map,
        ".m3u8": "application/vnd.apple.mpegurl",
        ".ts": "video/mp2t",
    }

    def end_headers(self):
        self.send_header("Cache-Control", "no-store")
        self.send_header("Pragma", "no-cache")
        self.send_header("Expires", "0")
        super().end_headers()

    def do_GET(self):
        path = unquote(urlparse(self.path).path)
        if path == "/stream.m3u8":
            self.stream_playlist()
            return
        if path == "/stream.ts":
            self.stream_transport_stream()
            return
        super().do_GET()

    def stream_playlist(self):
        playlist_path = os.path.join(workdir, "stream.m3u8")
        error_path = os.path.join(workdir, "stream.error")
        client_key = self.client_address[0]
        deadline = time.monotonic() + 30

        while True:
            if os.path.exists(error_path):
                self.send_error(500, "ffmpeg failed")
                return
            try:
                with open(playlist_path, "rb") as playlist:
                    body = playlist.read()
            except FileNotFoundError:
                body = b""

            if body:
                body = self.client_playlist(body, client_key)
                break

            if time.monotonic() >= deadline:
                self.send_error(404, "playlist not ready")
                return
            time.sleep(0.1)

        try:
            self.send_response(200)
            self.send_header("Content-Type", "application/vnd.apple.mpegurl")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError):
            return

    def client_playlist(self, source_body, client_key):
        text = source_body.decode("utf-8", errors="replace")
        if "#EXT-X-ENDLIST" in text:
            return source_body

        lines = text.splitlines()
        prefix = []
        segments = []
        index = 0

        while index < len(lines):
            line = lines[index]
            if line.startswith("#EXTINF:") and index + 1 < len(lines):
                segments.append((line, lines[index + 1]))
                index += 2
                continue
            if not line.startswith("#EXT-X-ENDLIST"):
                prefix.append(line)
            index += 1

        if not segments:
            return source_body

        with playlist_lock:
            previous_count = playlist_state.get(client_key, 0)
            if previous_count <= 0:
                reveal_count = 1
            else:
                reveal_count = min(len(segments), previous_count + 2)
            playlist_state[client_key] = reveal_count

        output = []
        for line in prefix:
            if line.startswith("#EXT-X-MEDIA-SEQUENCE:"):
                output.append("#EXT-X-MEDIA-SEQUENCE:0")
            else:
                output.append(line)
        for extinf, url in segments[:reveal_count]:
            output.append(extinf)
            output.append(url)
        output.append("")
        return "\n".join(output).encode("utf-8")

    def stream_transport_stream(self):
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

handler = functools.partial(RastercastHandler, directory=workdir)
server = ThreadingHTTPServer((bind_addr, port), handler)
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

if [[ "$transport" == "hls-vod" ]]; then
  printf 'rastercast: prebuilding complete HLS playlist before playback; this may take a while\n' >&2
  ffmpeg \
    -hide_banner \
    -loglevel error \
    -nostdin \
    -i "$input" \
    -map 0:v:0 \
    -map 0:a? \
    -vf "$video_filter" \
    -c:v libx264 \
    -preset ultrafast \
    -tune zerolatency \
    -profile:v baseline \
    -level 3.0 \
    -b:v 1000k \
    -maxrate 1000k \
    -bufsize 2000k \
    -pix_fmt yuv420p \
    -g 60 \
    -keyint_min 60 \
    -sc_threshold 0 \
    -c:a aac \
    -b:a 96k \
    -ar 44100 \
    -ac 2 \
    -f hls \
    -hls_time 2 \
    -hls_list_size 0 \
    -hls_segment_type mpegts \
    -hls_playlist_type vod \
    -hls_flags temp_file \
    -hls_base_url "http://${host_ip}:${port}/" \
    -hls_segment_filename "${workdir}/seg%05d.ts" \
    "${workdir}/stream.m3u8" >"${ffmpeg_log}" 2>&1 &
  stream_path="${workdir}/stream.m3u8"
  stream_url="http://${host_ip}:${port}/stream.m3u8"
elif [[ "$transport" == "hls" ]]; then
  ffmpeg \
    -hide_banner \
    -loglevel error \
    -nostdin \
    -re \
    -fflags +genpts \
    -i "$input" \
    -map 0:v:0 \
    -map 0:a? \
    -vf "$video_filter,fps=30000/1001" \
    -c:v libx264 \
    -preset ultrafast \
    -tune zerolatency \
    -profile:v baseline \
    -level 3.0 \
    -b:v 1000k \
    -maxrate 1000k \
    -bufsize 2000k \
    -pix_fmt yuv420p \
    -g 60 \
    -keyint_min 60 \
    -sc_threshold 0 \
    -c:a aac \
    -b:a 96k \
    -ar 44100 \
    -ac 2 \
    -f hls \
    -hls_time 2 \
    -hls_list_size 0 \
    -hls_segment_type mpegts \
    -hls_playlist_type event \
    -hls_flags temp_file \
    -hls_base_url "http://${host_ip}:${port}/" \
    -hls_segment_filename "${workdir}/seg%05d.ts" \
    "${workdir}/stream.m3u8" >"${ffmpeg_log}" 2>&1 &
  stream_path="${workdir}/stream.m3u8"
  stream_url="http://${host_ip}:${port}/stream.m3u8"
else
  ffmpeg \
    -hide_banner \
    -loglevel error \
    -nostdin \
    -re \
    -i "$input" \
    -map 0:v:0 \
    -map 0:a? \
    -vf "$video_filter" \
    -c:v libx264 \
    -preset ultrafast \
    -tune zerolatency \
    -profile:v baseline \
    -level 3.0 \
    -b:v 1000k \
    -maxrate 1000k \
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
  stream_path="${workdir}/stream.ts"
  stream_url="http://${host_ip}:${port}/stream.ts"
fi
ffmpeg_pid=$!

stream_is_ready() {
  [[ -s "$stream_path" ]] || return 1
  if [[ "$transport" == "hls-vod" ]]; then
    grep -q '^#EXT-X-ENDLIST' "$stream_path" && compgen -G "${workdir}/seg*.ts" >/dev/null
    return
  fi
  [[ "$transport" == "hls" ]] || return 0
  compgen -G "${workdir}/seg*.ts" >/dev/null
}

if [[ "$transport" == "hls-vod" ]]; then
  if ! wait "$ffmpeg_pid"; then
    ffmpeg_pid=""
    touch "$stream_error"
    printf 'error: ffmpeg failed while exporting the %s stream\n' "$transport" >&2
    show_ffmpeg_log
    exit 1
  fi
  ffmpeg_pid=""
else
  deadline=$((SECONDS + startup_timeout))
  while (( SECONDS < deadline )); do
    if stream_is_ready; then
      break
    fi
    if ! kill -0 "${ffmpeg_pid}" 2>/dev/null; then
      if wait "${ffmpeg_pid}"; then
        break
      fi
      printf 'error: ffmpeg failed while exporting the %s stream\n' "$transport" >&2
      show_ffmpeg_log
      exit 1
    fi
    sleep 0.1
  done
fi

if ! stream_is_ready; then
  printf 'error: ffmpeg did not produce a playable %s stream within %ss\n' "$transport" "${startup_timeout}" >&2
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
    printf 'error: ffmpeg failed while exporting the %s stream\n' "$transport" >&2
    show_ffmpeg_log
    exit 1
  fi
  ffmpeg_pid=""
fi
touch "$stream_done"

wait "$server_pid"
