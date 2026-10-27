"""Recovery must not signal a recycled PID. Uses disposable sleep processes, no audio."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ENGINE = Path(os.environ.get('STUDIO_PAIR_ENGINE_PATH', Path(__file__).resolve().parents[1] / 'build/Studio Pair.app/Contents/MacOS/studio-pair-engine'))


class RecoveryTests(unittest.TestCase):
    def check_recovery(self, restored=False, birth=None, valid=True):
        with tempfile.TemporaryDirectory() as directory:
            victim = subprocess.Popen(['/bin/sleep', '30'])
            try:
                journal = dict(pid=victim.pid, executable='/bin/sleep', restored=restored,
                               volume_written=False, mute_written=False)
                if birth is not None:
                    journal['process_birth'] = birth
                path = Path(directory) / 'journal.json'
                path.write_text(json.dumps(journal if valid else []))
                result = subprocess.run([str(ENGINE), 'restore', str(path)], capture_output=True, timeout=10)
                self.assertIsNone(victim.poll(), 'Recovery killed a process it did not own')
                return result.returncode, result.stderr.decode()
            finally:
                victim.terminate()
                victim.wait(timeout=3)

    def test_completed_journal_never_signals_saved_pid(self):
        self.assertEqual(self.check_recovery(restored=True)[0], 0)

    def test_recycled_pid_with_same_executable_survives(self):
        self.assertEqual(self.check_recovery(birth='0:0')[0], 0)

    def test_live_legacy_identity_requires_manual_quit(self):
        code, error = self.check_recovery()
        self.assertNotEqual(code, 0)
        self.assertIn('Legacy worker identity', error)

    def test_non_object_journal_fails_without_signalling(self):
        code, error = self.check_recovery(valid=False)
        self.assertNotEqual(code, 0)
        self.assertIn('Invalid rollback journal', error)


if __name__ == '__main__':
    unittest.main()
