#!/usr/bin/env python3
import http.server
import os
import socketserver
import sys
import time
from urllib.parse import unquote, urlparse


class ThreadingHTTPServer(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True


class RastercastHandler(http.server.BaseHTTPRequestHandler):
    workdir = None

    def end_headers(self):
        send_header = self.send_header

        send_header("Cache-Control", "no-store")
        send_header("Pragma", "no-cache")
        send_header("Expires", "0")
        super().end_headers()

    def do_GET(self):
        request_path = self.path
        stream_ts = self.stream_ts

        path = unquote(urlparse(request_path).path)
        if path == "/stream.ts":
            stream_ts()
            return
        self.send_error(404, "not found")

    def stream_ts(self):
        workdir = self.workdir
        wfile = self.wfile

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

        send_response = self.send_response
        send_header = self.send_header
        end_headers = self.end_headers

        send_response(200)
        send_header("Content-Type", "video/mp2t")
        send_header("Cache-Control", "no-store")
        send_header("Accept-Ranges", "none")
        send_header("Connection", "close")
        end_headers()

        try:
            with open(stream_path, "rb", buffering=0) as stream:
                while True:
                    chunk = stream.read(64 * 1024)
                    if chunk:
                        wfile.write(chunk)
                        wfile.flush()
                        continue
                    if os.path.exists(done_path) or os.path.exists(error_path):
                        break
                    time.sleep(0.1)
        except (BrokenPipeError, ConnectionResetError):
            return


def main():
    bind_addr = sys.argv[1]
    port = int(sys.argv[2])
    RastercastHandler.workdir = sys.argv[3]

    server = ThreadingHTTPServer((bind_addr, port), RastercastHandler)
    server.serve_forever()


if __name__ == "__main__":
    main()
