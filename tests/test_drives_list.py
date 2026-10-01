"""Tests for bin/drives-list's rclone rc queries.

Run: python3 -m unittest discover tests
"""

import http.server
import importlib.machinery
import importlib.util
import json
import os
import sys
import threading
import unittest

# Keep the plugin's bin/ free of a __pycache__ from loading the script.
sys.dont_write_bytecode = True

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
_loader = importlib.machinery.SourceFileLoader("drives_list", os.path.join(ROOT, "bin", "drives-list"))
_spec = importlib.util.spec_from_loader("drives_list", _loader)
dl = importlib.util.module_from_spec(_spec)
_loader.exec_module(dl)


class FakeRc(http.server.BaseHTTPRequestHandler):
    body = b""
    chunked = False  # stream with no Content-Length, like a hostile endpoint
    requests = []

    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0))
        FakeRc.requests.append((self.path, json.loads(self.rfile.read(length))))
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        if not self.chunked:
            self.send_header("Content-Length", str(len(self.body)))
        self.end_headers()
        try:
            self.wfile.write(self.body)
        except (BrokenPipeError, ConnectionResetError):
            pass  # client stopped reading at the cap

    def log_message(self, *args):
        pass


class RclonePendingTest(unittest.TestCase):
    def setUp(self):
        FakeRc.requests = []
        FakeRc.chunked = False
        self.server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), FakeRc)
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
        self.url = "http://127.0.0.1:%d" % self.server.server_address[1]

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()

    def serve(self, obj_or_bytes):
        FakeRc.body = obj_or_bytes if isinstance(obj_or_bytes, bytes) else json.dumps(obj_or_bytes).encode()

    def test_sums_queued_and_in_progress(self):
        self.serve({"diskCache": {"uploadsInProgress": 2, "uploadsQueued": 3}})
        self.assertEqual(dl.rclone_pending(self.url, "gdrive"), 5)
        self.assertEqual(FakeRc.requests, [("/vfs/stats", {"fs": "gdrive:"})])

    def test_no_disk_cache_is_zero(self):
        self.serve({})
        self.assertEqual(dl.rclone_pending(self.url, "gdrive"), 0)

    def test_response_at_limit_is_accepted(self):
        prefix = b'{"diskCache": {"uploadsQueued": 1}, "pad": "'
        suffix = b'"}'
        pad = dl.RCLONE_RC_MAX_BYTES - len(prefix) - len(suffix)
        self.serve(prefix + b"x" * pad + suffix)
        self.assertEqual(len(FakeRc.body), dl.RCLONE_RC_MAX_BYTES)
        self.assertEqual(dl.rclone_pending(self.url, "gdrive"), 1)

    def test_response_over_limit_is_rejected(self):
        self.serve(b'{"pad": "' + b"x" * dl.RCLONE_RC_MAX_BYTES + b'"}')
        self.assertEqual(dl.rclone_pending(self.url, "gdrive"), -1)

    def test_oversized_stream_without_length_is_rejected(self):
        # 64 MiB with no Content-Length: must stop at the cap, not buffer it all.
        FakeRc.chunked = True
        self.serve(b'{"pad": "' + b"x" * (64 * 1024 * 1024) + b'"}')
        self.assertEqual(dl.rclone_pending(self.url, "gdrive"), -1)

    def test_invalid_json_is_unknown(self):
        self.serve(b"not json")
        self.assertEqual(dl.rclone_pending(self.url, "gdrive"), -1)

    def test_unreachable_endpoint_is_unknown(self):
        self.tearDown()
        self.assertEqual(dl.rclone_pending(self.url, "gdrive"), -1)
        self.setUp()


if __name__ == "__main__":
    unittest.main()
