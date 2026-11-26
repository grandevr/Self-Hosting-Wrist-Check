"""Tests for kuma-status.py against a fake Uptime Kuma. Run: python3 server/tests/test_writer.py"""
import http.server
import json
import os
import subprocess
import sys
import tempfile
import threading
import unittest

WRITER = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "kuma-status.py")


def beats(last_status, pings):
    return [{"status": last_status if i == len(pings) - 1 else 1, "ping": p, "msg": "",
             "time": "2026-11-26 19:%02d:00" % i} for i, p in enumerate(pings)]


PAGE = {"config": {"slug": "home", "showTags": True, "showCertificateExpiry": False}, "publicGroupList": [
    {"name": "Media", "monitorList": [{"id": 1, "name": "Jellyfin"}, {"id": 2, "name": "PKVault"},
                                      {"id": 3, "name": "Immich"}]},
    {"name": "Host", "monitorList": [{"id": 4, "name": "Disk", "tags": [{"name": "priority", "value": "high"}]},
                                     {"id": 5, "name": "Api", "tags": [{"name": "slow_ms", "value": "100"}]},
                                     {"id": 6, "name": "Retrying"}]}]}
BEATS = {"heartbeatList": {
    "1": beats(1, [3000, 3000, 3000]),  # slow three times in a row
    "2": beats(0, [10, None]),          # down
    "3": beats(1, [3000, 50, 3000]),    # slow, but not three in a row
    "4": beats(0, [5]),                 # down, priority:high
    "5": beats(1, [150, 150, 150]),     # slow by its own slow_ms tag
    "6": beats(2, [5, 5]),              # pending
}, "uptimeList": {"1_24": 0.9931}}


class Kuma(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def do_GET(self):
        body = {"/api/status-page/home": PAGE, "/api/status-page/heartbeat/home": BEATS}.get(self.path)
        if body is None:
            self.send_response(404)
            self.end_headers()
            return
        data = json.dumps(body).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(data)


class WriterTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.server = http.server.HTTPServer(("127.0.0.1", 0), Kuma)
        threading.Thread(target=cls.server.serve_forever, daemon=True).start()
        cls.url = "http://127.0.0.1:%d" % cls.server.server_port

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()
        cls.server.server_close()

    def run_writer(self, *args, **env):
        e = dict(os.environ, KUMA_URL=self.url, KUMA_SLUG="home")
        e.update(env)
        return subprocess.run([sys.executable, WRITER, *args], env=e, capture_output=True, text=True, timeout=30)

    def test_fields_the_watch_reads(self):
        with tempfile.TemporaryDirectory() as d:
            out = os.path.join(d, "status.json")
            r = self.run_writer(OUT=out)
            self.assertEqual(r.returncode, 0, r.stderr)
            with open(out, encoding="utf-8") as f:
                s = json.load(f)
        for key in ("short", "title", "count", "problems", "updated"):
            self.assertIn(key, s)
        self.assertNotIn("error", s)
        self.assertEqual(s["problems"][0], "Disk DOWN")  # priority:high first
        self.assertIn("PKVault DOWN", s["problems"])
        self.assertIn("Jellyfin SLOW", s["problems"])
        self.assertIn("Api SLOW", s["problems"])          # its own slow_ms
        self.assertNotIn("Immich SLOW", s["problems"])    # not slow three times in a row
        self.assertEqual(s["count"], len(s["problems"]))
        self.assertEqual(s["short"], "Disk DOWN")

    def test_details_have_no_msg(self):
        r = self.run_writer("--print")
        s = json.loads(r.stdout)
        self.assertEqual(s["details"]["PKVault"]["state"], "down")
        for d in s["details"].values():
            self.assertNotIn("msg", d)  # Kuma's public API never sends the messages

    def test_check_notes_page_settings(self):
        r = self.run_writer("--check")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("6 monitors", r.stdout)
        self.assertIn("Show Certificate Expiry", r.stdout)
        self.assertNotIn("Show Tags", r.stdout)

    def test_check_unknown_slug(self):
        self.assertEqual(self.run_writer("--check", KUMA_SLUG="nope").returncode, 3)

    def test_kuma_down(self):
        r = self.run_writer("--print", KUMA_URL="http://127.0.0.1:9")
        s = json.loads(r.stdout)
        self.assertEqual(s["short"], "Kuma DOWN")
        self.assertEqual(s["count"], 0)
        self.assertIn("error", s)


if __name__ == "__main__":
    unittest.main()
