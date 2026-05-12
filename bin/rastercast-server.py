#!/usr/bin/env python3
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
