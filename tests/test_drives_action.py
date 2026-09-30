"""Tests for bin/drives-action's process termination.

Run: python3 -m unittest discover tests
"""

import importlib.machinery
import importlib.util
import os
import subprocess
import sys
import time
import unittest
from unittest import mock

# Keep the plugin's bin/ free of a __pycache__ from loading the script.
sys.dont_write_bytecode = True

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
_loader = importlib.machinery.SourceFileLoader("drives_action", os.path.join(ROOT, "bin", "drives-action"))
_spec = importlib.util.spec_from_loader("drives_action", _loader)
da = importlib.util.module_from_spec(_spec)
_loader.exec_module(da)


def spawn(*cmd):
    p = subprocess.Popen(cmd)
    # Wait for exec so the start time and signal disposition are the final ones.
    time.sleep(0.2)
    return p


def entry(p, start=None):
    return {"pid": p.pid, "name": "test", "start": da.start_time(p.pid) if start is None else start}


class StartTimeTest(unittest.TestCase):
    def stat(self, comm):
        # pid (comm) state, then fields 4..21, then starttime (22) = 4242.
        fields = ["S"] + ["0"] * 18 + ["4242", "0"]
        return "123 (%s) %s\n" % (comm, " ".join(fields))

    def test_reads_field_22(self):
        with mock.patch("builtins.open", mock.mock_open(read_data=self.stat("sleep"))):
            self.assertEqual(da.start_time(123), 4242)

    def test_comm_with_spaces_and_parens(self):
        with mock.patch("builtins.open", mock.mock_open(read_data=self.stat("a) b (c) 1 2"))):
            self.assertEqual(da.start_time(123), 4242)

    def test_live_process_is_stable(self):
        self.assertIsNotNone(da.start_time(os.getpid()))
        self.assertEqual(da.start_time(os.getpid()), da.start_time(os.getpid()))

    def test_missing_process(self):
        self.assertIsNone(da.start_time(2 ** 22 + 1))  # above pid_max limit


class TerminateTest(unittest.TestCase):
    def setUp(self):
        self.children = []

    def tearDown(self):
        for p in self.children:
            if p.poll() is None:
                p.kill()
            p.wait()

    def child(self, *cmd):
        p = spawn(*cmd)
        self.children.append(p)
        return p

    def test_sigterm_exits_without_waiting_full_timeout(self):
        p = self.child("sleep", "60")
        t = time.monotonic()
        da.terminate([entry(p)])
        self.assertLess(time.monotonic() - t, 1.5)
        self.assertEqual(p.wait(timeout=2), -15)

    def test_sigkill_after_timeout_when_term_ignored(self):
        p = self.child("bash", "-c", "trap '' TERM; while :; do sleep 0.1; done")
        t = time.monotonic()
        da.terminate([entry(p)])
        self.assertGreaterEqual(time.monotonic() - t, 1.9)
        self.assertEqual(p.wait(timeout=2), -9)

    def test_mismatched_start_time_is_not_signalled(self):
        # Same PID, different start time: what a reused PID looks like.
        p = self.child("sleep", "60")
        da.terminate([entry(p, start=da.start_time(p.pid) - 1)])
        time.sleep(0.1)
        self.assertIsNone(p.poll())

    def test_unknown_start_time_is_not_signalled(self):
        p = self.child("sleep", "60")
        e = entry(p)
        e["start"] = None
        da.terminate([e])
        time.sleep(0.1)
        self.assertIsNone(p.poll())

    def test_signals_go_through_pidfd_not_pid(self):
        # A pidfd keeps referring to the dead process even if its PID is
        # reused mid-wait, so no signal may be sent by bare PID.
        p = self.child("sleep", "60")
        with mock.patch.object(da.os, "kill") as kill:
            da.terminate([entry(p)])
        kill.assert_not_called()
        self.assertEqual(p.wait(timeout=2), -15)

    def test_gone_pid_is_skipped(self):
        p = self.child("true")
        p.wait()
        da.terminate([{"pid": p.pid, "name": "gone", "start": 1}])  # must not raise

    def test_mixed_batch(self):
        ok = self.child("sleep", "60")
        stubborn = self.child("bash", "-c", "trap '' TERM; while :; do sleep 0.1; done")
        stale = self.child("sleep", "60")
        da.terminate([entry(ok), entry(stubborn), entry(stale, start=da.start_time(stale.pid) + 1)])
        self.assertEqual(ok.wait(timeout=2), -15)
        self.assertEqual(stubborn.wait(timeout=2), -9)
        self.assertIsNone(stale.poll())

    def test_busy_procs_records_start_time(self):
        d = os.path.join(os.environ.get("TMPDIR", "/tmp"), "drives-action-test-%d" % os.getpid())
        os.makedirs(d, exist_ok=True)
        try:
            p = subprocess.Popen(["sleep", "60"], cwd=d)
            self.children.append(p)
            time.sleep(0.2)
            found = [e for e in da.busy_procs(d) if e["pid"] == p.pid]
            self.assertEqual(len(found), 1)
            self.assertEqual(found[0]["start"], da.start_time(p.pid))
        finally:
            os.rmdir(d)


if __name__ == "__main__":
    unittest.main()
