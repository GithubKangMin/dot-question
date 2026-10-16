"""Run the complete unittest suite; missing optional dependencies must not silently pass CI."""
import os
from pathlib import Path
import sys
import unittest
from unittest.mock import patch

root = Path(__file__).resolve().parents[1] / 'dot-question-windows'
os.chdir(root)
sys.path.insert(0, str(root))
os.environ['QT_QPA_PLATFORM'] = 'offscreen'
# Explicit imports make a missing dependency a hard failure rather than UI skips.
import PySide6  # noqa: F401, E402
import pypdf  # noqa: F401, E402
import win_capture  # noqa: E402
# UI constructors schedule hotkey registration. Keep it synthetic even on Windows.
# Platform tests explicitly override this flag with their own FakeUser32 backend.
with patch.object(win_capture, '_IS_WINDOWS', False):
    suite = unittest.defaultTestLoader.discover('tests')
    result = unittest.TextTestRunner(verbosity=2).run(suite)
if result.testsRun < 95:
    print(f'Expected at least 95 tests, ran {result.testsRun}', file=sys.stderr)
    sys.exit(1)
sys.exit(0 if result.wasSuccessful() and not result.skipped else 1)
