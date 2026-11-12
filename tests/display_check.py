"""Opt-in hardware checks: panel restoration when the owner's pipe closes or dies.

Run with --hardware and two Studio Displays attached. This temporarily disables
the built-in panel. It does not play audio or change the external displays.
"""
import argparse
import json
from pathlib import Path
import subprocess
import sys
import time
import unittest

HELPER = Path(__file__).resolve().parents[1] / "build/Studio Pair.app/Contents/MacOS/studio-pair-display"


def inventory():
    return json.loads(subprocess.check_output([str(HELPER), "--inspect"]))


def wait_for(predicate):
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline:
        if predicate():
            return
        time.sleep(0.1)
    raise AssertionError("Display state did not recover within 10 seconds")


class DisplayRecoveryTests(unittest.TestCase):
    def setUp(self):
        info = inventory()
        if info["studios"] != 2 or not info["builtin"] or not info["available"]:
            self.skipTest("Needs two Studio Displays and an active built-in panel")
        self.builtin = info["builtin"]

    def tearDown(self):
        subprocess.run([str(HELPER), "--restore", str(self.builtin)], check=True, timeout=10)

    def test_close_owner_pipe_restores_panel(self):
        guardian = subprocess.Popen([str(HELPER), "--watch", str(self.builtin)],
                                    stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
        try:
            wait_for(lambda: inventory()["builtin"] == 0)
            self.assertEqual(inventory()["studios"], 2)
            guardian.stdin.close()
            self.assertEqual(guardian.wait(timeout=10), 0)
            self.assertEqual(inventory()["builtin"], self.builtin)
        finally:
            if guardian.poll() is None:
                guardian.terminate()
                guardian.wait(timeout=10)
            guardian.stdout.close()

    def test_killed_owner_restores_panel(self):
        owner_code = """
import subprocess, sys, time
p = subprocess.Popen([sys.argv[1], '--watch', sys.argv[2]], stdin=subprocess.PIPE,
                     stdout=subprocess.DEVNULL)
print(p.pid, flush=True)
time.sleep(30)
"""
        owner = subprocess.Popen([sys.executable, "-c", owner_code, str(HELPER), str(self.builtin)],
                                 stdout=subprocess.PIPE, text=True)
        try:
            owner.stdout.readline()
            wait_for(lambda: inventory()["builtin"] == 0)
            self.assertEqual(inventory()["studios"], 2)
            owner.kill()
            owner.wait(timeout=5)
            wait_for(lambda: inventory()["builtin"] == self.builtin)
        finally:
            if owner.poll() is None:
                owner.kill()
                owner.wait(timeout=5)
            owner.stdout.close()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--hardware", action="store_true", required=True)
    parser.add_argument("--helper", type=Path, default=HELPER)
    args = parser.parse_args()
    HELPER = args.helper.resolve()
    unittest.main(argv=[sys.argv[0]])
