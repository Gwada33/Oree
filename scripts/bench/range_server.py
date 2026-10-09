#!/usr/bin/env python3
"""Local test server for the download engine.
  /big/<N>.bin      N MiB of repeating bytes, Range supported, Content-Disposition: attachment
  /norange/<N>.bin  same but ignores Range (the engine must hand it back to WebKit)
  /slow/<N>.bin     like big but throttled to ~8 MiB/s PER CONNECTION (so more connections = more speed)
  /mirrored/<N>.bin like slow, with Link: <http://127.0.0.1:8791/fast/N.bin>; rel=duplicate (run a 2nd server on 8791)
  /fast/<N>.bin     like big (the mirror target)
Usage: range_server.py [port]   (default 8790)"""
import http.server, socketserver, sys, time, re

BLOCK = (bytes(range(256)) * 4096)  # 1 MiB pattern; byte at offset i is i % 256

class H(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    def log_message(self, *a): pass
    def do_HEAD(self): self.do_GET(head=True)
    def do_GET(self, head=False):
        m = re.match(r"^/(big|norange|slow|mirrored|fast)/(\d+)\.bin", self.path)
        if not m:
            body = b"ok"
            self.send_response(200); self.send_header("Content-Length", str(len(body))); self.end_headers()
            if not head: self.wfile.write(body)
            return
        kind, size = m.group(1), int(m.group(2)) * 1024 * 1024
        start, end, status = 0, size - 1, 200
        rng = self.headers.get("Range")
        if rng and kind != "norange":
            r = re.match(r"bytes=(\d+)-(\d*)", rng)
            if r:
                start = int(r.group(1)); end = int(r.group(2)) if r.group(2) else size - 1
                end = min(end, size - 1); status = 206
        length = end - start + 1
        self.send_response(status)
        self.send_header("Content-Type", "application/octet-stream")
        self.send_header("Content-Length", str(length))
        self.send_header("Content-Disposition", f'attachment; filename="oree-{kind}-{size >> 20}mb.bin"')
        self.send_header("ETag", f'"{size}"')               # same validator for every kind: mirrors are "the same file"
        self.send_header("Last-Modified", "Wed, 01 Jan 2025 00:00:00 GMT")
        if kind == "mirrored": self.send_header("Link", f"<http://127.0.0.1:8791/fast/{size >> 20}.bin>; rel=duplicate; pri=1")
        if kind != "norange": self.send_header("Accept-Ranges", "bytes")
        if status == 206: self.send_header("Content-Range", f"bytes {start}-{end}/{size}")
        self.end_headers()
        if head: return
        sent = 0
        try:
            while sent < length:
                offset = (start + sent) % len(BLOCK)
                chunk = BLOCK[offset: offset + min(len(BLOCK) - offset, length - sent, 262144)]
                self.wfile.write(chunk); sent += len(chunk)
                if kind in ("slow", "mirrored"): time.sleep(len(chunk) / (8 * 1024 * 1024 if kind == "slow" else 4 * 1024 * 1024))
        except (BrokenPipeError, ConnectionResetError): pass

class S(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True
    request_queue_size = 128

if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8790
    S(("127.0.0.1", port), H).serve_forever()
