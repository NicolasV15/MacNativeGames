"""Exercise the production compile queue with deterministic compiler gates (no GPU)."""
from pathlib import Path
import os
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
NVN = ROOT / 'games/totk/third_party/d2r_gfx/gfx/nvn'


@unittest.skipUnless(sys.platform == 'darwin', 'requires Foundation and clang')
class AsyncCompileTests(unittest.TestCase):
    def run_probe(self, source, expected, frameworks=()):
        with tempfile.TemporaryDirectory(prefix='mng-async-') as directory:
            output = Path(directory)
            binary = output / 'probe'
            subprocess.run(['xcrun', 'clang', '-std=gnu11', '-fobjc-arc', '-Wall', '-Wextra', '-Werror',
                            '-I' + str(NVN), str(ROOT / 'tests' / source),
                            str(NVN / 'nvn_async_compile.m'), '-framework', 'Foundation',
                            *frameworks, '-o', str(binary)], check=True, capture_output=True, text=True)
            run = subprocess.run([str(binary), str(output)], check=True, capture_output=True,
                                 text=True, timeout=20, env=os.environ | {'TOTK_ASYNC_SHADERS': '0'})
            self.assertIn(expected, run.stdout)

    def test_pending_ready_failure_and_preferences(self):
        self.run_probe('async_compile_probe.m', 'pass: nonblocking polls')

    def test_warm_only_results_release_and_render_requests_share_work(self):
        self.run_probe('async_compile_lifetime_probe.m', 'pass: transient warm results release')

    def test_mode_switches_do_not_duplicate_or_strand_predictions(self):
        self.run_probe('async_pipeline_probe.m', 'pass: mode switches reuse pending work', ('-framework', 'Metal'))
