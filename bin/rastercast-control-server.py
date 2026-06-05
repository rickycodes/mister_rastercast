#!/usr/bin/env python3
import http.server
import json
import os
import subprocess
import threading
import time
import sys
from urllib.parse import unquote, urlparse


class ThreadingHTTPServer(http.server.ThreadingHTTPServer):
    daemon_threads = True


class PlaybackState:
    def __init__(self):
        self.lock = threading.Lock()
        self.active = None
        self.active_pid = None
        self.active_url = None
        self.active_title = None
        self.active_source = None
        self.active_kind = None
        self.active_started_at = None
        self.active_state = "idle"
        self.active_ready = False
        self.active_log_tail = []
        self.last_request = None
        self.last_error = None
        self.last_log_path = None
        self.last_log_tail = []


STATE = PlaybackState()


class RastercastControlHandler(http.server.BaseHTTPRequestHandler):
    repo_dir = None
    dj_mode = False

    def end_headers(self):
        self.send_header("Cache-Control", "no-store")
        self.send_header("Pragma", "no-cache")
        self.send_header("Expires", "0")
        super().end_headers()

    def do_GET(self):
        try:
            path = unquote(urlparse(self.path).path)
            if path == "/health":
                self.write_json(200, {"ok": True})
                return
            if path == "/status":
                self.write_json(200, self.status_payload())
                return
            self.send_error(404, "not found")
        except Exception as err:
            self.send_error(500, f"internal error: {err}")

    def do_POST(self):
        try:
            path = unquote(urlparse(self.path).path)
            if path == "/play":
                self.handle_play()
                return
            if path == "/stop":
                self.handle_stop()
                return
            self.send_error(404, "not found")
        except Exception as err:
            self.send_error(500, f"internal error: {err}")

    def handle_play(self):
        length = int(self.headers.get("Content-Length", "0"))
        raw = self.rfile.read(length) if length > 0 else b"{}"
        try:
            payload = json.loads(raw.decode("utf-8"))
        except json.JSONDecodeError as err:
            self.send_error(400, f"invalid json: {err}")
            return

        url = str(payload.get("url", "")).strip()
        if not url.startswith(("http://", "https://")):
            self.send_error(400, "url must be an http(s) URL")
            return

        title = str(payload.get("title", "")).strip()
        source = str(payload.get("source", "")).strip()
        kind = str(payload.get("kind", "")).strip()

        with STATE.lock:
            STATE.last_request = {
                "url": url,
                "title": title,
                "source": source,
                "kind": kind,
                "received_at": time.time(),
            }
            STATE.last_error = None
            STATE.active_state = "starting"
            STATE.active_ready = False
            if STATE.active and STATE.active.poll() is None:
                try:
                    STATE.active.terminate()
                except Exception:
                    pass

            script_path = os.path.join(self.repo_dir, "bin", "rastercast.sh")
            log_path = os.path.join("/tmp", "rastercast-control.log")
            log_file = open(log_path, "a", buffering=1, encoding="utf-8")
            child_env = os.environ.copy()
            if self.dj_mode:
                child_env["RASTERCAST_MISTER_DETACH"] = "1"
                child_env["RASTERCAST_POST_PLAYBACK"] = "none"
            else:
                child_env["RASTERCAST_POST_PLAYBACK"] = "menu"
            proc = subprocess.Popen(
                [script_path, url],
                cwd=self.repo_dir,
                env=child_env,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                text=True,
            )
            threading.Thread(
                target=self.drain_process_output,
                args=(proc, log_file, log_path),
                daemon=True,
            ).start()
            STATE.active = proc
            STATE.active_pid = proc.pid
            STATE.active_url = url
            STATE.active_title = title
            STATE.active_source = source
            STATE.active_kind = kind
            STATE.active_started_at = time.time()
            STATE.last_log_path = log_path
            STATE.last_log_tail = []
            STATE.active_log_tail = []

        self.write_json(202, {"ok": True, "pid": proc.pid, "url": url})

    def handle_stop(self):
        with STATE.lock:
            proc = STATE.active
            STATE.active = None
        if proc and proc.poll() is None:
            try:
                proc.terminate()
            except Exception:
                pass
        self.write_json(200, {"ok": True})

    def write_json(self, status, payload):
        payload = sanitize_json(payload)
        body = json.dumps(payload, separators=(",", ":"), ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def status_payload(self):
        with STATE.lock:
            return {
                "active": STATE.active is not None and STATE.active.poll() is None,
                "active_pid": STATE.active_pid,
                "active_url": STATE.active_url,
                "active_title": STATE.active_title,
                "active_source": STATE.active_source,
                "active_kind": STATE.active_kind,
                "active_started_at": STATE.active_started_at,
                "active_state": STATE.active_state,
                "active_ready": STATE.active_ready,
                "active_log_tail": STATE.active_log_tail,
                "last_request": STATE.last_request,
                "last_error": STATE.last_error,
                "last_log_tail": STATE.last_log_tail,
                "last_log_path": STATE.last_log_path,
            }

    def drain_process_output(self, proc, log_file, log_path):
        try:
            # rastercast.sh writes the useful status lines to stderr, so tee them to a file.
            # We use stdout merged into stderr above to keep a single live stream.
            if proc.stdout is None:
                return
            for line in proc.stdout:
                log_file.write(line)
                log_file.flush()
                sys.stderr.write(line)
                sys.stderr.flush()
                with STATE.lock:
                    STATE.active_log_tail = tail_lines(log_path, 40)
                    if "rastercast: serving " in line:
                        STATE.active_state = "streaming"
                        STATE.active_ready = True
        except Exception as err:
            with STATE.lock:
                STATE.last_error = str(err)
                STATE.active_state = "error"
        finally:
            try:
                log_file.close()
            except Exception:
                pass
            with STATE.lock:
                if STATE.last_log_path == log_path and proc.poll() is not None:
                    STATE.active = None
                    STATE.active_pid = None
                    STATE.active_url = None
                    STATE.active_title = None
                    STATE.active_source = None
                    STATE.active_kind = None
                    STATE.active_started_at = None
                    STATE.active_state = "idle"
                    STATE.active_ready = False
                    STATE.last_log_tail = tail_lines(log_path, 40)


def tail_lines(path, count):
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as handle:
            lines = handle.readlines()
        return [line.rstrip("\n") for line in lines[-count:]]
    except OSError:
        return []


def sanitize_json(value):
    if value is None or isinstance(value, (bool, int, float, str)):
        return value
    if isinstance(value, (list, tuple)):
        return [sanitize_json(item) for item in value]
    if isinstance(value, dict):
        return {str(key): sanitize_json(item) for key, item in value.items()}
    if isinstance(value, (set, frozenset)):
        return [sanitize_json(item) for item in value]
    return str(value)


def main():
    if len(sys.argv) != 4:
        print(f"usage: {sys.argv[0]} BIND_ADDR PORT REPO_DIR", file=sys.stderr)
        return 2

    bind_addr = sys.argv[1]
    port = int(sys.argv[2])
    repo_dir = os.path.abspath(sys.argv[3])
    RastercastControlHandler.repo_dir = repo_dir
    RastercastControlHandler.dj_mode = os.environ.get("RASTERCAST_DJ_MODE", "0") in ("1", "yes", "true")

    server = ThreadingHTTPServer((bind_addr, port), RastercastControlHandler)
    server.serve_forever()


if __name__ == "__main__":
    raise SystemExit(main())
