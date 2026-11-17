#!/usr/bin/env python3
"""End-to-end tests for the gate CLI and its daemon.

Every test gets its own HOME / XDG dirs, so it can never touch the real ledger.
"""

import json
import os
import pathlib
import socket
import subprocess
import sys
import tempfile
import time
import unittest

BIN = pathlib.Path(__file__).resolve().parents[1] / "bin" / "gate"


class GateTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="lucid-gate-test-")
        base = pathlib.Path(self.tmp.name)
        self.env = {
            **os.environ,
            "HOME": str(base / "home"),
            "XDG_STATE_HOME": str(base / "state"),
            "XDG_CONFIG_HOME": str(base / "config"),
            "XDG_RUNTIME_DIR": str(base / "run"),
        }
        for name in ("home", "state", "config", "run"):
            (base / name).mkdir(parents=True)
        os.chmod(base / "run", 0o700)
        config_dir = base / "config" / "lucid-gate"
        config_dir.mkdir(parents=True)
        (config_dir / "config.json").write_text(json.dumps({
            "default_cost": 100,
            "place_costs": {"discord": 100},
            "tasks": [
                {"id": "focus", "min": 0, "reward": 50},
                {"id": "typing", "min": 5, "reward": 20},
            ],
        }))

    def tearDown(self):
        self._call({"cmd": "shutdown"})
        self.tmp.cleanup()

    def _socket(self):
        return pathlib.Path(self.env["XDG_RUNTIME_DIR"]) / "lucid-gate.sock"

    def _call(self, payload):
        try:
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as sock:
                sock.settimeout(2)
                sock.connect(str(self._socket()))
                sock.sendall(json.dumps(payload).encode() + b"\n")
                chunks = b""
                while b"\n" not in chunks:
                    chunk = sock.recv(65536)
                    if not chunk:
                        break
                    chunks += chunk
            return json.loads(chunks.decode() or "{}")
        except OSError:
            return {}

    def gate(self, *args, check=True):
        proc = subprocess.run(
            [sys.executable, str(BIN), *map(str, args)],
            env=self.env,
            capture_output=True,
            text=True,
            timeout=30,
        )
        if check and proc.returncode != 0:
            raise AssertionError(f"gate {' '.join(map(str, args))} failed: {proc.stderr}\n{proc.stdout}")
        return proc

    def state(self):
        return json.loads(self.gate("status", "--json").stdout)

    def balance(self):
        return self.state()["state"]["balance"]

    def test_status_creates_a_ledger(self):
        state = self.state()["state"]
        self.assertEqual(state["balance"], 0)
        self.assertTrue(any(t["id"] == "focus" for t in state["tasks"]))
        self.assertTrue(self._socket().exists())

    def test_voluntary_task_earns_credits(self):
        self.gate("start", "focus")
        self.gate("complete", "focus")
        self.assertEqual(self.balance(), 50)

    def test_free_unlocks_after_daily_goal(self):
        cfg_path = pathlib.Path(self.env["XDG_CONFIG_HOME"]) / "lucid-gate" / "config.json"
        cfg = json.loads(cfg_path.read_text())
        cfg["free_after"] = 2
        cfg_path.write_text(json.dumps(cfg))

        self.gate("start", "focus")
        self.gate("complete", "focus")
        self.gate("start", "focus")
        self.gate("complete", "focus")
        balance = self.balance()
        self.assertEqual(balance, 100)

        state = self.state()["state"]
        self.assertEqual(len(state["daily"]["log"]), 2)

        # the unlock costs nothing once the daily goal is met
        self.gate("request", "--place", "discord", "--label", "free")
        state = self.state()["state"]
        gate = next(g for g in state["gates"].values() if g["state"] == "pending")
        self.gate("unlock", gate["id"])
        self.assertEqual(self.balance(), balance)
        state = self.state()["state"]
        self.assertEqual(state["gates"][gate["id"]]["by"], "free")

        # and a task finished while free pays its reward, not the gate
        self.gate("request", "--place", "discord", "--label", "reward")
        state = self.state()["state"]
        gate = next(g for g in state["gates"].values() if g["state"] == "pending")
        self.gate("start", "focus")
        self.gate("complete", "focus")
        self.assertEqual(self.balance(), balance + 50)
        state = self.state()["state"]
        self.assertEqual(state["gates"][gate["id"]]["state"], "granted")

    def test_credit_is_deduped_by_ref(self):
        self.gate("credit", "40", "--ref", "duolingo-xp-1")
        self.assertEqual(self.balance(), 40)
        # a repeated poll for the same XP step must not pay twice
        self.gate("credit", "40", "--ref", "duolingo-xp-1")
        self.assertEqual(self.balance(), 40)
        self.gate("credit", "10", "--ref", "duolingo-xp-2")
        self.assertEqual(self.balance(), 50)

    def test_spending_unlocks_without_a_task(self):
        self.gate("start", "focus")
        self.gate("complete", "focus")
        self.gate("start", "focus")
        self.gate("complete", "focus")
        gate_id = json.loads(self.gate("request", "--place", "discord", "--label", "Send", "--json").stdout)["gate"]["id"]
        self.gate("unlock", gate_id)
        self.assertEqual(self.balance(), 0)
        gate = self.state()["state"]["gates"][gate_id]
        self.assertEqual(gate["state"], "granted")
        self.assertEqual(gate["by"], "spend")

    def test_insufficient_credits_are_refused(self):
        gate_id = json.loads(self.gate("request", "--place", "discord", "--json").stdout)["gate"]["id"]
        proc = self.gate("unlock", gate_id, check=False)
        self.assertEqual(proc.returncode, 2)
        self.assertIn("more Compute", proc.stderr)
        self.assertEqual(self.state()["state"]["gates"][gate_id]["state"], "pending")

    def test_task_opens_a_waiting_gate_for_free(self):
        gate_id = json.loads(self.gate("request", "--place", "discord", "--json").stdout)["gate"]["id"]
        self.gate("start", "focus")
        self.gate("complete", "focus")
        state = self.state()["state"]
        self.assertEqual(state["gates"][gate_id]["state"], "granted")
        self.assertEqual(state["gates"][gate_id]["by"], "task")
        self.assertEqual(state["balance"], 0)

    def test_a_task_cannot_be_claimed_early(self):
        self.gate("start", "typing")
        proc = self.gate("complete", "typing", check=False)
        self.assertEqual(proc.returncode, 2)
        self.assertIn("left on", proc.stderr)

    def test_ref_deduplicates_pending_gates(self):
        first = json.loads(self.gate("request", "--place", "discord", "--ref", "abc", "--json").stdout)["gate"]["id"]
        second = json.loads(self.gate("request", "--place", "discord", "--ref", "abc", "--json").stdout)["gate"]["id"]
        self.assertEqual(first, second)

    def test_run_executes_the_command_after_the_task(self):
        marker = pathlib.Path(self.tmp.name) / "ran"
        runner = subprocess.Popen(
            [sys.executable, str(BIN), "run", "--place", "discord", "--", sys.executable, "-c",
             f"open({str(marker)!r}, 'w').write('ok')"],
            env=self.env,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        deadline = time.time() + 10
        gate_id = None
        while time.time() < deadline:
            state = self.state()["state"]
            pending = [g for g in state["gates"].values() if g["state"] == "pending"]
            if pending:
                gate_id = pending[0]["id"]
                break
            time.sleep(0.1)
        self.assertIsNotNone(gate_id, "gate run never registered a gate")
        self.gate("start", "focus")
        self.gate("complete", "focus")
        out, err = runner.communicate(timeout=10)
        self.assertEqual(runner.returncode, 0, err)
        self.assertEqual(marker.read_text(), "ok")

    def test_cancel_stops_a_waiter(self):
        runner = subprocess.Popen(
            [sys.executable, str(BIN), "request", "--place", "discord", "--wait"],
            env=self.env,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        deadline = time.time() + 10
        gate_id = None
        while time.time() < deadline:
            pending = [g for g in self.state()["state"]["gates"].values() if g["state"] == "pending"]
            if pending:
                gate_id = pending[0]["id"]
                break
            time.sleep(0.1)
        self.assertIsNotNone(gate_id)
        self.gate("cancel", gate_id)
        runner.communicate(timeout=5)
        self.assertEqual(runner.returncode, 1)


if __name__ == "__main__":
    unittest.main(verbosity=2)
