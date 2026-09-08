#!/usr/bin/env python3
"""Local manual integration fixture. No third-party packages or internet needed."""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse

PAGE = """<!doctype html><meta charset="utf-8"><title>Kiosk test experience</title>
<style>
body{font:18px system-ui;background:#202723;color:#f1f2e8;margin:0;padding:70px;line-height:1.5}
h1{font-size:52px;letter-spacing:-2px}p{max-width:650px;color:#c7cec3}
a,button{display:inline-block;font:inherit;color:#202723;background:#d6fa72;padding:12px 18px;border:0;border-radius:8px;margin:5px;text-decoration:none;cursor:pointer}
input{font:inherit;padding:12px;border-radius:8px;border:0;margin:10px}
</style>
<p>METERVARA / KIOSK TEST</p><h1>Website ready.</h1>
<p>This local page exercises navigation and browser recovery. Use the operator shortcut to close preview: Control + Option + Command + K.</p>
<a href="/next">Allowed page</a><a href="http://localhost:8765/escape">Blocked host</a>
<a href="/next" target="_blank">New window link</a>
<a href="/download" download>Download</a><a href="mailto:kiosk@example.com">External app link</a>
<a href="/unavailable">Server error</a>
<button onclick="while(true){}">Freeze browser</button>
<button onclick="alert('This should be suppressed')">Alert dialog</button>
<p><label>Visitor input <input placeholder="Type here"></label></p>
"""

class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        path = urlparse(self.path).path
        if path == "/unavailable":
            self.send_response(503)
            self.end_headers()
            self.wfile.write(b"Service unavailable")
        elif path == "/download":
            self.send_response(200)
            self.send_header("Content-Type", "application/octet-stream")
            self.send_header("Content-Disposition", "attachment; filename=test.txt")
            self.end_headers()
            self.wfile.write(b"Downloads should be blocked")
        else:
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.end_headers()
            self.wfile.write((PAGE.replace("Website ready.", "Second page." if path == "/next" else "Website ready.")).encode())

if __name__ == "__main__":
    print("Kiosk test website: http://127.0.0.1:8765", flush=True)
    ThreadingHTTPServer(("127.0.0.1", 8765), Handler).serve_forever()
