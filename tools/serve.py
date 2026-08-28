#!/usr/bin/env python3
"""Static server that refuses to let anything be cached.

The default http.server lets the browser hold on to ES modules and image
assets, so after regenerating a depth map or editing config.js you can spend a
long time measuring the *previous* build and concluding the change did nothing.
Everything here is sent no-store.

    python3 tools/serve.py [port] [directory]
"""
import functools
import http.server
import sys


class NoCacheHandler(http.server.SimpleHTTPRequestHandler):
    def end_headers(self):
        self.send_header("Cache-Control", "no-store, no-cache, must-revalidate, max-age=0")
        self.send_header("Pragma", "no-cache")
        self.send_header("Expires", "0")
        super().end_headers()

    def log_message(self, fmt, *args):        # keep the console readable
        if "404" in (fmt % args):
            super().log_message(fmt, *args)


def main():
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 4322
    directory = sys.argv[2] if len(sys.argv) > 2 else "."
    handler = functools.partial(NoCacheHandler, directory=directory)
    with http.server.ThreadingHTTPServer(("", port), handler) as httpd:
        print(f"serving {directory} on http://localhost:{port} (no-store)")
        httpd.serve_forever()


if __name__ == "__main__":
    main()
