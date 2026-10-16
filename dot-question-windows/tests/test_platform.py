"""Headless tests with synthetic pixels and mocked Win32/Tesseract calls.

These never capture the real desktop, register native hotkeys, contact a model,
or create a screenshot file. They do not replace on-device Windows validation.
"""

import ctypes
from contextlib import contextmanager
import os
os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

import subprocess
import unittest
from unittest.mock import patch

from PySide6.QtCore import QPoint, QRect, Qt
from PySide6.QtGui import QColor, QImage
from PySide6.QtTest import QTest
from PySide6.QtWidgets import QApplication

import win_capture as capture
from icons import answer_icon


class FakeUser32:
    def __init__(self):
        self.bindings = {}
        self.fail_vk = None
        self.unregistered = []

    def RegisterHotKey(self, window, ident, modifiers, vk):
        if vk == self.fail_vk or (modifiers, vk) in self.bindings.values():
            return False
        self.bindings[ident] = (modifiers, vk)
        return True

    def UnregisterHotKey(self, window, ident):
        self.unregistered.append(ident)
        return self.bindings.pop(ident, None) is not None


@contextmanager
def mocked_hotkeys():
    # Construct without installing a real native filter, including on Windows.
    with patch.object(capture, "_IS_WINDOWS", False):
        hotkeys = capture.Hotkeys()
    user32 = FakeUser32()
    with patch.object(capture, "_IS_WINDOWS", True), \
            patch.object(capture, "_user32", user32), \
            patch.object(ctypes, "get_last_error", return_value=1409, create=True):
        try:
            yield hotkeys, user32
        finally:
            hotkeys.close()
    hotkeys.deleteLater()


class PlatformTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.app = QApplication.instance() or QApplication([])

    @staticmethod
    def pixels(width=100, height=100, color="red"):
        image = QImage(width, height, QImage.Format.Format_RGB32)
        image.fill(QColor(color))
        return image

    def test_icons_all_answer_styles_and_characters(self):
        for character in ("off", "cat", "pikachu"):
            for style in ("number", "wifi", "battery"):
                for order in (None, *range(1, 11), 99):
                    with self.subTest(character=character, style=style, order=order):
                        icon = answer_icon(order, style, character, 3)
                        for size in (16, 24, 32, 64):
                            self.assertFalse(icon.pixmap(size, size).isNull())

    def test_wifi_large_answer_falls_back_to_number(self):
        for order in range(6, 11):
            self.assertEqual(
                answer_icon(order, "wifi").pixmap(64, 64).toImage(),
                answer_icon(order, "number").pixmap(64, 64).toImage(),
            )

    def test_negative_coordinate_mixed_dpi_composition(self):
        shots = [
            capture._Snapshot(QRect(-100, 0, 100, 100), self.pixels()),
            capture._Snapshot(QRect(0, 0, 100, 100), self.pixels(200, 200, "blue")),
        ]
        result = capture._compose(shots, QRect(-50, 10, 100, 40))
        self.assertEqual((result.width(), result.height()), (200, 80))
        self.assertEqual(result.pixelColor(20, 20), QColor("red"))
        self.assertEqual(result.pixelColor(180, 20), QColor("blue"))
        self.assertTrue(capture._compose(shots, QRect(300, 300, 10, 10)).isNull())

    def test_mixed_dpi_monitor_gap_remains_white(self):
        shots = [
            capture._Snapshot(QRect(-100, 0, 100, 100), self.pixels()),
            capture._Snapshot(QRect(20, 0, 100, 100), self.pixels(200, 200, "blue")),
        ]
        result = capture._compose(shots, QRect(-10, 10, 40, 20))
        self.assertEqual(result.pixelColor(5, 10), QColor("red"))
        self.assertEqual(result.pixelColor(40, 10), QColor("white"))
        self.assertEqual(result.pixelColor(75, 10), QColor("blue"))

    def test_cursor_capture_clips_to_pointer_monitor(self):
        class Screen:
            def geometry(self):
                return QRect(-100, 0, 100, 100)
        shot = capture._Snapshot(QRect(-100, 0, 100, 100), self.pixels())
        with patch.object(capture.QApplication, "screenAt", return_value=Screen()), \
                patch.object(capture.QCursor, "pos", return_value=QPoint(-1, 50)), \
                patch.object(capture, "_take_snapshots", return_value=[shot]) as snapshots:
            result = capture.capture_cursor(40, 40)
        self.assertEqual(snapshots.call_args.args[0], QRect(-21, 30, 21, 40))
        self.assertEqual((result.width(), result.height()), (21, 40))

    def test_overlay_escape_emits_once_and_releases_images(self):
        shot = capture._Snapshot(QRect(0, 0, 100, 100), self.pixels())
        with patch.object(capture, "_take_snapshots", return_value=[shot]):
            overlay = capture.CaptureOverlay()
        results = []
        overlay.finished.connect(results.append)
        overlay.show()
        self.app.processEvents()
        QTest.keyClick(overlay, Qt.Key.Key_Escape)
        overlay.cancel()
        overlay.close()
        self.assertEqual(results, [None])
        self.assertTrue(shot.image.isNull())
        overlay.deleteLater()

    def test_overlay_selection_then_close_emits_once(self):
        with patch.object(capture, "_take_snapshots", return_value=[
            capture._Snapshot(QRect(0, 0, 100, 100), self.pixels())
        ]):
            overlay = capture.CaptureOverlay()
        results = []
        overlay.finished.connect(results.append)
        overlay._start, overlay._end = QPoint(5, 5), QPoint(50, 50)
        overlay._complete_selection()
        overlay.close()
        self.assertEqual(len(results), 1)
        self.assertIsInstance(results[0], QImage)
        self.assertEqual(results[0].width(), 46)
        overlay.deleteLater()

    def test_armed_preference_needs_shortcut_then_enter(self):
        with mocked_hotkeys() as (keys, user32):
            fired = []
            keys.triggered.connect(lambda: fired.append(True))
            keys.configure("Ctrl+Alt+Shift+R", True)
            self.assertEqual(len(user32.bindings), 1)
            self.assertFalse(keys.armed)
            keys._handle_hotkey(keys._main_id)
            self.assertTrue(keys.armed)
            self.assertEqual(len(user32.bindings), 3)
            enter = keys._enter_id
            keys._handle_hotkey(enter)
            self.assertEqual(fired, [True])
            self.assertFalse(keys.armed)
            self.assertEqual(len(user32.bindings), 1)
            self.assertFalse(keys._handle_hotkey(enter))
            self.assertEqual(fired, [True])

    def test_escape_timeout_and_close_unregister_bare_keys(self):
        with mocked_hotkeys() as (keys, user32):
            fired = []
            keys.triggered.connect(lambda: fired.append(True))
            keys.configure("Enter", True)
            keys._handle_hotkey(keys._main_id)
            keys._handle_hotkey(keys._escape_id)
            self.assertFalse(keys.armed)
            self.assertEqual(len(user32.bindings), 1)
            keys._handle_hotkey(keys._main_id)
            self.assertEqual(keys._timer.interval(), 10_000)
            keys._timer.setInterval(1)
            QTest.qWait(60)
            self.assertFalse(keys.armed)
            self.assertEqual(len(user32.bindings), 1)
            self.assertEqual(fired, [])
            keys._handle_hotkey(keys._main_id)
            keys.close()
            keys.close()
            self.assertEqual(user32.bindings, {})

    def test_conflicting_escape_undoes_enter_registration(self):
        with mocked_hotkeys() as (keys, user32):
            errors = []
            keys.error.connect(errors.append)
            keys.configure("R", True)
            user32.fail_vk = capture._VK_ESCAPE
            keys._handle_hotkey(keys._main_id)
            self.assertFalse(keys.armed)
            self.assertEqual(len(user32.bindings), 1)
            self.assertEqual(len(errors), 1)
            self.assertIn("Esc", errors[0])

    def test_conflicting_reconfigure_preserves_working_shortcut(self):
        with mocked_hotkeys() as (keys, user32):
            keys.configure("R", False)
            original = keys._main_id
            user32.fail_vk = 0x20
            with self.assertRaises(RuntimeError):
                keys.configure("Space", True)
            self.assertEqual(keys._main_id, original)
            self.assertEqual(keys.key, "R")
            self.assertEqual(len(user32.bindings), 1)
            user32.fail_vk = None
            keys.configure("Space", False)
            self.assertNotEqual(keys._main_id, original)
            self.assertEqual(len(user32.bindings), 1)

    def test_unarmed_shortcut_fires_immediately(self):
        with mocked_hotkeys() as (keys, user32):
            fired = []
            keys.triggered.connect(lambda: fired.append(True))
            keys.configure("Space", False)
            keys._handle_hotkey(keys._main_id)
            self.assertEqual(fired, [True])
            self.assertFalse(keys.armed)
            self.assertEqual(len(user32.bindings), 1)

    def test_ocr_only_sends_png_bytes_to_stdin(self):
        with patch.object(capture, "_find_tesseract", return_value="tesseract"), \
                patch.object(capture.subprocess, "run", return_value=subprocess.CompletedProcess([], 0, b"test question", b"")) as run:
            self.assertEqual(capture.ocr_image(self.pixels()), "test question")
        args, kwargs = run.call_args
        self.assertEqual(args[0][1:3], ["stdin", "stdout"])
        self.assertTrue(kwargs["input"].startswith(b"\x89PNG"))
        self.assertEqual(kwargs["timeout"], 60)

    def test_ocr_missing_language_is_not_silently_ignored(self):
        with patch.object(capture, "_find_tesseract", return_value="tesseract"), \
                patch.object(capture.subprocess, "run", return_value=subprocess.CompletedProcess([], 0, b"English only", b"Failed loading language 'kor'")):
            with self.assertRaisesRegex(RuntimeError, "traineddata"):
                capture.ocr_image(self.pixels())

    def test_ocr_timeout_and_missing_executable_actionable(self):
        with patch.object(capture, "_find_tesseract", return_value="tesseract"), \
                patch.object(capture.subprocess, "run", side_effect=subprocess.TimeoutExpired("tesseract", 60)):
            with self.assertRaisesRegex(RuntimeError, "60"):
                capture.ocr_image(self.pixels())
        with patch.dict(os.environ, {"TESSERACT_CMD": "missing-tesseract.exe"}), \
                patch.object(capture.shutil, "which", return_value=None):
            with self.assertRaisesRegex(RuntimeError, "TESSERACT_CMD"):
                capture.ocr_image(self.pixels())


if __name__ == "__main__":
    unittest.main()
