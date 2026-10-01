"""Tests for bin/drives-list: rclone rc queries, bounded network usage, and
per-source error handling.

Run: python3 -m unittest discover tests
"""

import http.server
import importlib.machinery
import importlib.util
import io
import json
import os
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from unittest import mock

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
        self.assertEqual(dl.rclone_pending(self.url, "gdrive:"), 5)
        self.assertEqual(FakeRc.requests, [("/vfs/stats", {"fs": "gdrive:"})])

    def test_no_disk_cache_is_zero(self):
        self.serve({})
        self.assertEqual(dl.rclone_pending(self.url, "gdrive:"), 0)

    def test_response_at_limit_is_accepted(self):
        prefix = b'{"diskCache": {"uploadsQueued": 1}, "pad": "'
        suffix = b'"}'
        pad = dl.RCLONE_RC_MAX_BYTES - len(prefix) - len(suffix)
        self.serve(prefix + b"x" * pad + suffix)
        self.assertEqual(len(FakeRc.body), dl.RCLONE_RC_MAX_BYTES)
        self.assertEqual(dl.rclone_pending(self.url, "gdrive:"), 1)

    def test_response_over_limit_is_rejected(self):
        self.serve(b'{"pad": "' + b"x" * dl.RCLONE_RC_MAX_BYTES + b'"}')
        self.assertEqual(dl.rclone_pending(self.url, "gdrive:"), -1)

    def test_oversized_stream_without_length_is_rejected(self):
        # 64 MiB with no Content-Length: must stop at the cap, not buffer it all.
        FakeRc.chunked = True
        self.serve(b'{"pad": "' + b"x" * (64 * 1024 * 1024) + b'"}')
        self.assertEqual(dl.rclone_pending(self.url, "gdrive:"), -1)

    def test_invalid_json_is_unknown(self):
        self.serve(b"not json")
        self.assertEqual(dl.rclone_pending(self.url, "gdrive:"), -1)

    def test_unreachable_endpoint_is_unknown(self):
        self.tearDown()
        self.assertEqual(dl.rclone_pending(self.url, "gdrive:"), -1)
        self.setUp()

    def test_sends_full_fs_for_subpath_mounts(self):
        self.serve({"diskCache": {"uploadsQueued": 1}})
        dl.rclone_pending(self.url, "gdrive:docs")
        self.assertEqual(FakeRc.requests, [("/vfs/stats", {"fs": "gdrive:docs"})])


class BoundedUsageTest(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.mkdtemp()
        self.addCleanup(os.rmdir, self.dir)

    def test_matches_statvfs(self):
        st = os.statvfs(self.dir)
        size, used, ro = dl.bounded_usage([self.dir])[self.dir]
        self.assertEqual(size, st.f_blocks * st.f_frsize)
        self.assertGreater(used, 0)
        self.assertFalse(ro)

    def test_missing_path_is_zeros(self):
        missing = os.path.join(self.dir, "nope")
        self.assertEqual(dl.bounded_usage([missing]), {missing: (0, 0, False)})

    def test_hung_mounts_give_up_together_at_the_timeout(self):
        # Stand-in for statvfs on a dead NFS server: never answers.
        hang = "import time; time.sleep(30)"
        a, b = os.path.join(self.dir, "a"), os.path.join(self.dir, "b")
        with mock.patch.object(dl, "STATVFS_CHILD", hang):
            t = time.monotonic()
            out = dl.bounded_usage([a, b], timeout=0.5)
            elapsed = time.monotonic() - t
        self.assertEqual(out, {a: (0, 0, False), b: (0, 0, False)})
        self.assertLess(elapsed, 1.5)  # one shared deadline, not 0.5s per mount

    def test_hung_child_does_not_hold_stdout(self):
        # The widget reads drives-list's stdout to EOF, so a stuck child must
        # not keep it open after drives-list exits.
        script = ("import sys; sys.path.insert(0, %r); sys.dont_write_bytecode = True\n"
                  "import importlib.machinery as m, importlib.util as u\n"
                  "l = m.SourceFileLoader('dl', %r); d = u.module_from_spec(u.spec_from_loader('dl', l))\n"
                  "l.exec_module(d); d.STATVFS_CHILD = 'import time; time.sleep(30)'\n"
                  "print(d.bounded_usage(['/'], timeout=0.3))\n"
                  % (ROOT, os.path.join(ROOT, "bin", "drives-list")))
        t = time.monotonic()
        out = subprocess.run([sys.executable, "-c", script], capture_output=True, text=True, timeout=10)
        self.assertLess(time.monotonic() - t, 5)
        self.assertIn("(0, 0, False)", out.stdout)

    def test_fill_usage(self):
        d = dl.plain_entry("x", self.dir, "src", "nfs", "network", "")
        self.assertEqual((d["size"], d["pct"]), (0, 0))
        dl.fill_usage([d])
        self.assertGreater(d["size"], 0)
        self.assertEqual(d["pct"], dl.pct(d["used"], d["size"]))


class RcUrlForTest(unittest.TestCase):
    def mounts(self, *cmdlines):
        return [(c.split(), "http://rc%d" % i) for i, c in enumerate(cmdlines)]

    def test_remote_right_after_mount(self):
        self.assertEqual(dl.rc_url_for(self.mounts("gdrive: /g --rc"), "gdrive:"), "http://rc0")

    def test_flags_before_remote(self):
        m = self.mounts("--vfs-cache-mode writes --rc gdrive: /home/u/g")
        self.assertEqual(dl.rc_url_for(m, "gdrive:"), "http://rc0")

    def test_flag_value_with_colon_is_not_the_remote(self):
        m = self.mounts("--cache-dir /x:y --rc dropbox: /d")
        self.assertIsNone(dl.rc_url_for(m, "x:"))
        self.assertEqual(dl.rc_url_for(m, "dropbox:"), "http://rc0")

    def test_exact_source_wins_over_same_remote(self):
        m = self.mounts("gdrive:photos /p --rc", "gdrive:docs /d --rc-addr :5573")
        self.assertEqual(dl.rc_url_for(m, "gdrive:docs"), "http://rc1")
        self.assertEqual(dl.rc_url_for(m, "gdrive:photos"), "http://rc0")

    def test_falls_back_to_remote_name(self):
        # findmnt may spell the source differently from the command line.
        m = self.mounts("--daemon gdrive:/docs /d --rc")
        self.assertEqual(dl.rc_url_for(m, "gdrive:docs"), "http://rc0")

    def test_unknown_remote(self):
        self.assertIsNone(dl.rc_url_for(self.mounts("gdrive: /g --rc"), "onedrive:"))


class RcloneMountsTest(unittest.TestCase):
    """Real processes named `rclone` (a sh script), found via pgrep + cmdline."""

    def setUp(self):
        self.dir = tempfile.mkdtemp()
        self.fake = os.path.join(self.dir, "rclone")
        with open(self.fake, "w") as f:
            f.write("#!/bin/sh\nsleep 60\n")
        os.chmod(self.fake, 0o755)
        self.procs = []

    def tearDown(self):
        for p in self.procs:
            p.kill()
            p.wait()
        os.unlink(self.fake)
        os.rmdir(self.dir)

    def start(self, *args):
        self.procs.append(subprocess.Popen([self.fake] + list(args)))
        time.sleep(0.2)

    def ours(self):
        # Ignore any real rclone mounts on this machine.
        return [m for m in dl.rclone_mounts() if any(a.startswith("/test-") for a in m[0])]

    def test_finds_rc_mounts_with_flags_anywhere(self):
        self.start("--config", "/x.conf", "mount", "--vfs-cache-mode", "writes",
                   "gdrive:", "/test-g", "--rc-addr", ":5573")
        self.start("mount", "/no/rc", "/test-n")  # no --rc: skipped
        self.start("serve", "http", "gdrive:", "/test-s", "--rc")  # not a mount: skipped
        found = self.ours()
        self.assertEqual(len(found), 1)
        args, url = found[0]
        self.assertEqual(url, "http://localhost:5573")
        self.assertIn("gdrive:", args)
        self.assertEqual(dl.rc_url_for(found, "gdrive:"), url)

    def test_argument_with_spaces_survives(self):
        self.start("mount", "my drive:", "/test-space", "--rc")
        found = self.ours()
        self.assertEqual(dl.rc_url_for(found, "my drive:"), "http://localhost:5572")


class MainTest(unittest.TestCase):
    def run_main(self, *argv):
        out = io.StringIO()
        with mock.patch.object(sys, "argv", ["drives-list"] + list(argv)), \
                mock.patch("sys.stdout", out):
            dl.main()
        return json.loads(out.getvalue())

    def test_block_failure_keeps_network_drives(self):
        net = dl.plain_entry("share", "/mnt/share", "srv:/x", "nfs", "network", "")
        with mock.patch.object(dl, "block_drives", side_effect=ValueError("lsblk broke")), \
                mock.patch.object(dl, "network_drives", return_value=[net]), \
                mock.patch.object(dl, "rclone_drives", return_value=[]), \
                mock.patch.object(dl, "gvfs_drives", return_value=[]), \
                mock.patch.object(dl, "bounded_usage", return_value={"/mnt/share": (100, 25, False)}):
            result = self.run_main("--network")
        self.assertEqual(result["error"], "lsblk broke")
        self.assertEqual([d["key"] for d in result["drives"]], ["/mnt/share"])
        self.assertEqual(result["drives"][0]["pct"], 25)

    def test_network_failure_keeps_block_drives(self):
        with mock.patch.object(dl, "block_drives", return_value=[{"key": "/dev/sdb1"}]), \
                mock.patch.object(dl, "network_drives", side_effect=OSError("findmnt broke")), \
                mock.patch.object(dl, "gvfs_drives", return_value=[]):
            result = self.run_main("--network")
        self.assertEqual(result["error"], "findmnt broke")
        self.assertEqual([d["key"] for d in result["drives"]], ["/dev/sdb1"])

    def test_no_errors(self):
        with mock.patch.object(dl, "block_drives", return_value=[]):
            self.assertEqual(self.run_main()["error"], "")


if __name__ == "__main__":
    unittest.main()
