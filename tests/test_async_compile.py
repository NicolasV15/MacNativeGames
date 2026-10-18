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
    def test_pending_ready_failure_and_preferences(self):
        with tempfile.TemporaryDirectory(prefix='mng-async-') as directory:
            output = Path(directory)
            binary = output / 'probe'
            subprocess.run(['xcrun', 'clang', '-std=gnu11', '-fobjc-arc', '-Wall', '-Wextra', '-Werror',
                            '-I' + str(NVN), str(ROOT / 'tests/async_compile_probe.m'),
                            str(NVN / 'nvn_async_compile.m'), '-framework', 'Foundation',
                            '-o', str(binary)], check=True, capture_output=True, text=True)
            run = subprocess.run([str(binary), str(output)], check=True, capture_output=True,
                                 text=True, timeout=20, env=os.environ | {'TOTK_ASYNC_SHADERS': '0'})
            self.assertIn('pass: nonblocking polls', run.stdout)
