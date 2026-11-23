"""Exercise real, isolated Codex clients against a loopback-only model fixture."""

import contextlib
import http.server
import json
from pathlib import Path
import queue
import signal
import subprocess
import tempfile
import threading
import time
import unittest
from unittest import mock

import quota_guard as guard


class TestGuard(unittest.TestCase):
    def test_desktop_cli_and_manual_restart(self):
        requests, finish = queue.Queue(), threading.Event()

        class Model(http.server.BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass

            def do_POST(self):
                self.rfile.read(int(self.headers.get("Content-Length", 0)))
                if not self.path.endswith("/responses"):
                    self.send_error(404)
                    return
                self.send_response(200)
                self.send_header("Content-Type", "text/event-stream")
                self.end_headers()
                self.wfile.write(b": waiting\n\n")
                self.wfile.flush()
                requests.put(self.path)
                finish.wait(45)

        with tempfile.TemporaryDirectory() as temp, contextlib.ExitStack() as cleanup:
            server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Model)
            threading.Thread(target=server.serve_forever, daemon=True).start()
            cleanup.callback(server.server_close)
            cleanup.callback(server.shutdown)
            cleanup.callback(finish.set)
            fixture_home = Path(temp) / "codex"
            fixture_home.mkdir()
            env = {"PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": str(Path.home()),
                   "CODEX_HOME": str(fixture_home), "TMPDIR": temp, "NO_PROXY": "127.0.0.1"}
            args = [str(guard.codex_binaries()[0]), "-c", 'model_provider="fixture"',
                    "-c", 'model_providers.fixture.name="Quota test"',
                    "-c", 'model="gpt-5.3-codex"', "-c", 'model_providers.fixture.wire_api="responses"',
                    "-c", f'model_providers.fixture.base_url="http://127.0.0.1:{server.server_port}/v1"']

            def start(desktop=False):
                mode = (["app-server", "--stdio"] if desktop else
                        ["exec", "--ephemeral", "--skip-git-repo-check", "--sandbox", "read-only", "Fixture"])
                proc = subprocess.Popen(args + mode, cwd=temp, env=env,
                                        stdin=subprocess.PIPE if desktop else subprocess.DEVNULL,
                                        stdout=subprocess.PIPE if desktop else subprocess.DEVNULL,
                                        stderr=subprocess.DEVNULL)
                def close():
                    if proc.poll() is None:
                        proc.kill()
                    proc.wait()
                    for pipe in (proc.stdin, proc.stdout):
                        if pipe:
                            pipe.close()
                cleanup.callback(close)
                return proc

            desktop = start(desktop=True)
            def request(number, method, params):
                frame = {"id": number, "method": method, "params": params}
                desktop.stdin.write(json.dumps(frame).encode() + b"\n")
                desktop.stdin.flush()
                for line in desktop.stdout:
                    reply = json.loads(line)
                    if reply.get("id") == number:
                        self.assertNotIn("error", reply)
                        return reply["result"]
                self.fail("fixture server disconnected")

            previous = signal.signal(signal.SIGALRM, guard.timed_out)
            cleanup.callback(signal.signal, signal.SIGALRM, previous)
            cleanup.callback(signal.alarm, 0)
            signal.alarm(45)
            request(1, "initialize", {"clientInfo": {"name": "quota_fixture", "version": "1"}})
            desktop.stdin.write(b'{"method":"initialized"}\n')
            desktop.stdin.flush()
            thread = request(2, "thread/start", {"cwd": temp, "ephemeral": True,
                             "sandbox": "read-only", "approvalPolicy": "never"})["thread"]
            turn = request(3, "turn/start", {"threadId": thread["id"],
                           "input": [{"type": "text", "text": "Fixture"}]})["turn"]
            self.assertEqual(turn["status"], "inProgress")
            cli = start()
            for _ in range(2):
                requests.get(timeout=15)
            allowed = {desktop.pid, cli.pid}

            def snapshot():
                targets = [t for t in guard.snapshot_targets(None) if t["pid"] in allowed]
                self.assertEqual({t["pid"] for t in targets}, allowed)
                return targets

            def stop(targets):
                self.assertTrue(all(t["pid"] in allowed for t in targets))
                return guard.stop_targets(targets)

            now = int(time.time())
            receipt = Path(temp) / "receipt.json"
            def save(state):
                guard.atomic_write(receipt, json.dumps(state).encode())
            def sample(remaining, reset):
                window = {"windowDurationMins": 10080, "usedPercent": 100 - remaining, "resetsAt": reset}
                return {"accountId": "fixture", "rateLimitsByLimitId": {"codex": {"secondary": window}}}
            def no_rescan():
                self.fail("The guard rescanned processes after its one interruption")

            state = {}
            guard.observe(state, sample(8, now + 700), now, snapshot, stop, save)
            self.assertEqual(state["phase"], "armed")
            self.assertTrue(desktop.poll() is None and cli.poll() is None)
            guard.observe(state, sample(7, now + 700), now + 1, snapshot, stop, save)
            self.assertEqual(state["phase"], "triggered")
            for proc in (desktop, cli):
                self.assertIsNotNone(proc.wait(timeout=3))
            manual = start()
            requests.get(timeout=12)
            restored = json.loads(receipt.read_text())
            guard.observe(restored, sample(6, now + 701), now + 2, no_rescan, stop, save)
            self.assertIsNone(manual.poll())
            guard.observe(restored, sample(99, now + 605500), now + 800, no_rescan, stop, save)
            self.assertEqual(restored["phase"], "armed")

    def test_threshold_changes_accounts_and_resets(self):
        now = 2_000_000_000
        end = now + 86400
        state = {}
        def observe(remaining, threshold, reset=end, account="one", when=now):
            result = {"accountId": account, "rateLimits": {"limitId": "codex", "primary": {
                "usedPercent": 100 - remaining, "resetsAt": reset, "windowDurationMins": 10080}}}
            guard.observe(state, result, when, snapshot, lambda targets: [], lambda value: None, threshold)
        snapshot = mock.Mock(return_value=[])
        observe(12, 12)
        snapshot.assert_not_called()
        observe(11, 12)
        self.assertEqual(state["phase"], "triggered")
        observe(4, 20, end + 1)
        self.assertEqual(snapshot.call_count, 1)
        observe(4, 20, account="two")
        self.assertEqual(snapshot.call_count, 2)
        observe(99, 12, now + 7 * 86400 + 100, when=now + 101)
        self.assertEqual(state["phase"], "armed")

    def test_disabling_during_fetch_never_interrupts(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            with mock.patch.multiple(guard, ROOT=root, STATE=root / "state.json", SETTINGS=root / "settings.json"), \
                 mock.patch.object(guard, "AppSampler") as sampler, \
                 mock.patch.object(guard, "snapshot_targets") as snapshot:
                policy = {"enabled": True, "threshold": 8, "interval": 30}
                guard.write_settings(policy)
                def finish_read():
                    guard.write_settings({**policy, "enabled": False})
                    return {"checkedAt": time.time(), "result": {"accountId": "one", "rateLimits": {
                        "primary": {"windowDurationMins": 10080, "usedPercent": 99,
                                    "resetsAt": int(time.time()) + 86400}}}}
                sampler.return_value.read.side_effect = finish_read
                guard.run_watch(root / "fixture")
                snapshot.assert_not_called()
                sampler.return_value.close.assert_called_once()
                self.assertFalse(guard.STATE.exists())

    def test_unavailable_quota_and_non_chat_helpers(self):
        for data in ({}, {"accountId": "fixture", "rateLimitsByLimitId": {"other": {}}}):
            with self.assertRaises(ValueError):
                guard.weekly_quota(data, time.time())
        for args in (["codex", "exec-server", "--remote", "example"],
                     ["codex", "app-server", "generate-json-schema"],
                     ["codex", "app-server", "--startup-client-info", json.dumps({"name": "quota_clock"})],
                     ["codex", "login"], ["codex", "--remote", "unix://"]):
            self.assertFalse(guard.chat_process(args))
        self.assertTrue(guard.chat_process(["codex", "-c", "a=b", "app-server", "--mcp-launch-cwd",
                                            "tool", "/project", "/launch"]))


if __name__ == "__main__":
    unittest.main()
