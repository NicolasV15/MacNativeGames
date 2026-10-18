"""Deterministic takeover races in the actual verifier cleanup; no game runs."""
import importlib.util
from pathlib import Path
import subprocess
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import Mock, patch

SCRIPT = Path(__file__).resolve().parents[1] / 'games/totk/scripts/verify_async_shaders.py'
spec = importlib.util.spec_from_file_location('async_verifier', SCRIPT)
verifier = importlib.util.module_from_spec(spec)
spec.loader.exec_module(verifier)


class VerifierCleanupTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='mng-verifier-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.live = self.root/'live.log'
        self.live.write_text('first presented frame\n')
        self.commands = self.root/'input.txt'
        self.commands.write_text('')
        self.slot = SimpleNamespace(preempted=False)
        self.monitor = verifier.SessionMonitor(self.live, None, self.slot)
        self.monitor.refresh()  # last successful poll before the cleanup race
        self.report = dict(status='pass')
        self.game = Mock()
        self.game.poll.return_value = None
        def exited(**kwargs):
            self.game.poll.return_value = 0
            return 0
        self.game.wait.side_effect = exited

    def finish(self, during_snapshot=lambda: None):
        write = Path.write_text
        fired = False
        def inject(path, text, *args, **kwargs):
            nonlocal fired
            result = write(path, text, *args, **kwargs)
            if path == self.root/'game.log' and not fired:
                fired = True
                during_snapshot()
            return result
        with patch.object(Path, 'write_text', inject):
            verifier.finish_trial(self.root, self.commands, self.game, self.monitor, self.report)

    def assert_left_open(self, status):
        self.assertEqual(self.report['status'], status)
        self.assertEqual(self.commands.read_text(), '')
        self.game.wait.assert_not_called()

    def test_user_input_after_last_poll_interrupts_instead_of_closing(self):
        self.finish(lambda: self.live.write_text('[input] user input (keyboard)\n'))
        self.assert_left_open('interrupted')
        self.assertIn('[input] user input', (self.root/'game.log').read_text())

    def test_preemption_during_evidence_write_interrupts(self):
        self.finish(lambda: setattr(self.slot, 'preempted', True))
        self.assert_left_open('interrupted')

    def test_missing_log_during_cleanup_fails_without_closing(self):
        self.finish(self.live.unlink)
        self.assert_left_open('failed')
        self.assertIn('close_error', self.report)

    def test_previous_session_log_does_not_authorize_close(self):
        self.monitor.prior_inode = self.live.stat().st_ino
        self.finish()
        self.assert_left_open('failed')

    def test_already_taken_session_stays_open(self):
        self.monitor.taken = True
        self.finish()
        self.assert_left_open('interrupted')

    def test_unattended_session_closes_normally(self):
        self.finish()
        self.assertEqual(self.commands.read_text(), 'close\n')
        self.game.wait.assert_called_once_with(timeout=30)
        self.assertEqual(self.report['status'], 'pass')
        self.assertEqual(self.report['exit_code'], 0)

    def test_close_timeout_is_not_a_pass(self):
        self.game.wait.side_effect = subprocess.TimeoutExpired('game', 30)
        self.finish()
        self.assertEqual(self.report['status'], 'failed')
        self.assertIn('close_error', self.report)

    def test_missing_startup_log_is_tolerated_while_polling(self):
        self.live.unlink()
        self.monitor.check(self.game)
        self.assertFalse(self.monitor.taken)
