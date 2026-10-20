#!/usr/bin/env python3
# Copyright (C) 2026  Davorin Šego
# Licensed under the GPL v3, see LICENSE

# Serves the web build on http://localhost:8000 for trying it out: the page and its scripts from
# platform/web, strobie.wasm from build/web and odin.js from the Odin install, nothing is copied.
# localhost counts as a secure origin, the browser lets it have the microphone.
#
#   python3 platform/web/serve.py [port]

import http.server
import os
import subprocess
import sys

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
ODIN_ROOT = subprocess.run(["odin", "root"], capture_output=True, text=True, check=True).stdout.strip()

FILES = {
    "/odin.js": os.path.join(ODIN_ROOT, "core", "sys", "wasm", "js", "odin.js"),
    "/strobie.wasm": os.path.join(ROOT, "build", "web", "strobie.wasm"),
}


class Handler(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=os.path.join(ROOT, "platform", "web"), **kwargs)

    def translate_path(self, path):
        return FILES.get(path.split("?")[0]) or super().translate_path(path)

    # Each reload takes the latest build
    def end_headers(self):
        self.send_header("Cache-Control", "no-store")
        super().end_headers()


port = int(sys.argv[1]) if len(sys.argv) > 1 else 8000
print(f"http://localhost:{port}")
http.server.ThreadingHTTPServer(("localhost", port), Handler).serve_forever()
