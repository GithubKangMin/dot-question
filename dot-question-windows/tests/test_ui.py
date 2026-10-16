"""Optional offscreen Qt smoke tests; no screenshot/network/OCR calls."""
import os
import tempfile
import threading
import time
import unittest
from unittest.mock import patch
os.environ.setdefault('QT_QPA_PLATFORM', 'offscreen')
try:
    from PySide6.QtWidgets import QApplication
    import app as gui
    QT_AVAILABLE = True
except ImportError:
    QT_AVAILABLE = False


@unittest.skipUnless(QT_AVAILABLE, 'PySide6 not installed; core tests remain runnable')
class UISmokeTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.app = QApplication.instance() or QApplication([])

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.env = patch.dict(os.environ, {'LOCALAPPDATA': self.tmp.name})
        self.env.start()
        self.window = gui.Window()

    def tearDown(self):
        self.window.hk.close()
        self.window.tray.hide()
        self.window.animation.stop()
        self.window.deleteLater()
        self.app.processEvents()
        self.env.stop()
        self.tmp.cleanup()

    def test_privacy_defaults(self):
        self.assertFalse(self.window.autocopy.isChecked())
        self.assertTrue(self.window.show_answer.isChecked())
        self.assertFalse(self.window.quick_mode.isChecked())
        self.assertEqual(self.window.character.currentText(), 'off')
        self.assertEqual(self.window.key.text(), '')
        self.assertEqual(self.window.mode.currentIndex(), 0)

    def test_edit_resets_signal(self):
        self.window.current_order = 2
        self.window.question.setPlainText('새 질문')
        self.assertIsNone(self.window.current_order)
        self.assertFalse(self.window.animation.isActive())

    def test_mode_switch_no_network(self):
        self.window.mode.setCurrentIndex(1)
        self.assertTrue(self.window.key.isEnabled())
        self.assertFalse(self.window.endpoint.isEnabled())
        self.assertIn('OpenAI', self.window.send.text())

    def test_cancel_pending_capture(self):
        self.window.capture_pending = True
        self.window.cancel()
        self.assertFalse(self.window.capture_pending)
        self.assertTrue(self.window.cancelled)

    def test_output_setting_stops_motion(self):
        self.window.current_order = 2
        self.window.remaining_frames = 4
        self.window.animation.start()
        self.window.output_changed()
        self.assertFalse(self.window.animation.isActive())
        self.assertEqual(self.window.remaining_frames, 0)

    def wait_for_idle(self):
        deadline = time.monotonic() + 3
        while self.window.busy and time.monotonic() < deadline:
            self.app.processEvents()
            time.sleep(0.005)
        self.assertFalse(self.window.busy)

    def test_local_request_chain_mocked(self):
        from core import Answer
        result = Answer('2', '두 번째', '설명', None, (), 2)
        self.window.question.setPlainText('고르세요\n1. 첫째\n2. 둘째')
        with patch.object(gui, 'OllamaClient') as client:
            client.return_value.answer.return_value = result
            self.window.submit()
            self.wait_for_idle()
            client.return_value.answer.assert_called_once()
        self.assertIn('두 번째', self.window.answer.toPlainText())
        self.assertEqual(self.window.current_order, 2)

    def test_cancel_ignores_late_result(self):
        release = threading.Event()
        called = []
        self.window.run(lambda: release.wait(1), called.append)
        self.window.cancel()
        release.set()
        self.wait_for_idle()
        self.assertEqual(called, [])

    def test_api_consent_cancel_never_constructs_client(self):
        self.window.mode.setCurrentIndex(1)
        self.window.key.setText('test-key-not-a-real-credential')
        self.window.question.setPlainText('테스트 질문')
        with patch.object(self.window, 'consent', return_value=False) as consent, patch.object(gui, 'OpenAIClient') as client:
            self.window.submit()
            self.wait_for_idle()
            consent.assert_called_once()
            client.assert_not_called()
        self.assertIn('전송하지', self.window.status.text())

    def test_preferences_round_trip_without_content(self):
        self.window.quick_mode.setChecked(True)
        self.window.style.setCurrentText('wifi')
        self.window.character.setCurrentText('cat')
        self.window.reduce_motion.setChecked(True)
        self.window.key.setText('must-not-persist')
        self.window.question.setPlainText('private question')
        other = gui.Window()
        try:
            self.assertTrue(other.quick_mode.isChecked())
            self.assertTrue(other.show_answer.isChecked())
            self.assertEqual(other.style.currentText(), 'wifi')
            self.assertEqual(other.character.currentText(), 'cat')
            self.assertTrue(other.reduce_motion.isChecked())
            self.assertEqual(other.key.text(), '')
            self.assertEqual(other.question.toPlainText(), '')
            self.assertIsNone(other.current_order)
        finally:
            other.hk.close(); other.tray.hide(); other.deleteLater()

    def test_quick_capture_ocr_answer_without_reveal(self):
        from core import Answer
        from PySide6.QtGui import QImage
        self.window.quick_mode.setChecked(True)
        self.window.cursor.setChecked(False)  # Quick path always uses cursor.
        self.window.answer.setPlainText('stale result')
        self.window.current_order = 1
        image = QImage(20, 20, QImage.Format.Format_RGB32)
        with patch.object(gui.QTimer, 'singleShot'), patch.object(gui, 'capture_cursor', return_value=image) as capture, patch.object(gui, 'ocr_image', return_value='고르세요\n1. 첫째\n2. 둘째'), patch.object(gui, 'OllamaClient') as client, patch.object(gui, 'OpenAIClient') as api, patch.object(self.window, 'reveal') as reveal, patch.object(gui.QMessageBox, 'warning') as popup:
            client.return_value.answer.return_value = Answer('2', '둘째', '설명', None, (), 2)
            self.window.capture(from_hotkey=True)
            self.assertEqual(self.window.answer.toPlainText(), '')
            self.assertIsNone(self.window.current_order)
            self.window.take_capture()
            self.wait_for_idle()
            capture.assert_called_once_with(900, 600)
            client.return_value.answer.assert_called_once()
            api.assert_not_called(); reveal.assert_not_called(); popup.assert_not_called()
        self.assertEqual(self.window.current_order, 2)
        self.assertFalse(self.window.isVisible())

    def test_quick_api_is_rejected_before_capture_and_dispatch(self):
        self.window.quick_mode.setChecked(True)
        self.window.mode.setCurrentIndex(1)
        with patch.object(gui, 'capture_cursor') as capture, patch.object(gui, 'OpenAIClient') as api, patch.object(self.window, 'consent') as consent, patch.object(self.window, 'reveal') as reveal, patch.object(gui.QMessageBox, 'warning') as popup, patch.object(self.window.tray, 'showMessage') as notice:
            self.window.capture(from_hotkey=True)
            self.assertFalse(self.window.capture_pending)
            self.window.quick_active = True
            self.window.start_request('question', [], True, False, automatic=True)
            capture.assert_not_called(); api.assert_not_called(); consent.assert_not_called()
            reveal.assert_not_called(); popup.assert_not_called()
            self.assertEqual(notice.call_count, 2)

    def test_quick_empty_ocr_and_model_errors_do_not_popup(self):
        with patch.object(gui.QMessageBox, 'warning') as popup, patch.object(self.window.tray, 'showMessage') as notice, patch.object(gui, 'OllamaClient') as client, patch.object(self.window, 'reveal') as reveal:
            self.window.quick_active = True
            self.window.ocr_done('  ')
            client.assert_not_called()
            self.window.quick_active = True
            client.return_value.answer.side_effect = ValueError('model unavailable')
            self.window.ocr_done('고르세요\n1. 첫째\n2. 둘째')
            self.wait_for_idle()
            self.assertEqual(notice.call_count, 2)
            popup.assert_not_called(); reveal.assert_not_called()
        self.assertIsNone(self.window.current_order)

    def test_quick_cancel_during_ocr_never_sends(self):
        release = threading.Event()
        self.window.quick_active = True
        with patch.object(gui, 'OllamaClient') as client, patch.object(self.window, 'reveal') as reveal:
            self.window.run(lambda: (release.wait(1), 'question')[1], self.window.ocr_done)
            self.window.cancel(); release.set(); self.wait_for_idle()
            client.assert_not_called(); reveal.assert_not_called()
        self.assertFalse(self.window.quick_active)
        self.assertIsNone(self.window.current_order)

    def test_manual_ocr_still_requires_send(self):
        with patch.object(gui, 'OllamaClient') as local, patch.object(gui, 'OpenAIClient') as api:
            self.window.ocr_done('question')
            local.assert_not_called(); api.assert_not_called()
        self.assertIn('검토', self.window.status.text())

    def test_quick_capture_failure_stays_hidden_and_clears_answer(self):
        self.window.quick_mode.setChecked(True)
        self.window.answer.setPlainText('stale')
        self.window.current_order = 2
        with patch.object(gui.QTimer, 'singleShot'), patch.object(gui, 'capture_cursor', side_effect=RuntimeError('capture failed')), patch.object(gui.QMessageBox, 'warning') as popup, patch.object(self.window.tray, 'showMessage') as notice, patch.object(self.window, 'reveal') as reveal:
            self.window.capture(from_hotkey=True); self.window.take_capture()
            popup.assert_not_called(); reveal.assert_not_called(); notice.assert_called_once()
        self.assertEqual(self.window.answer.toPlainText(), '')
        self.assertIsNone(self.window.current_order)
        self.assertFalse(self.window.quick_active)

    def test_cancel_clears_previous_answer_and_animation(self):
        self.window.answer.setPlainText('stale')
        self.window.current_order = 3
        self.window.remaining_frames = 6
        self.window.animation.start()
        self.window.cancel()
        self.assertEqual(self.window.answer.toPlainText(), '')
        self.assertIsNone(self.window.current_order)
        self.assertEqual(self.window.remaining_frames, 0)
        self.assertFalse(self.window.animation.isActive())

    def test_character_stays_visible_with_answer_and_reduce_motion(self):
        self.window.character.setCurrentText('cat')
        self.window.reduce_motion.setChecked(True)
        self.window.current_order = 2
        with patch.object(gui, 'answer_icon', wraps=gui.answer_icon) as icon:
            self.window.render_icon()
            icon.assert_called_with(2, 'number', 'cat', 0)

    def test_enabling_quick_restores_answer_display(self):
        self.window.show_answer.setChecked(False)
        self.window.quick_mode.setChecked(True)
        self.assertTrue(self.window.show_answer.isChecked())

    def test_saved_quick_startup_hidden_only_with_available_tray(self):
        self.window.quick_mode.setChecked(True)
        with patch.object(gui.QSystemTrayIcon, 'isSystemTrayAvailable', return_value=True), patch.object(self.window, 'show') as show:
            self.window.show_on_startup(); show.assert_not_called()
        with patch.object(gui.QSystemTrayIcon, 'isSystemTrayAvailable', return_value=False), patch.object(self.window, 'show') as show:
            self.window.show_on_startup(); show.assert_called_once()
        self.window.quick_mode.setChecked(False)
        with patch.object(gui.QSystemTrayIcon, 'isSystemTrayAvailable', return_value=True), patch.object(self.window, 'show') as show:
            self.window.show_on_startup(); show.assert_called_once()

    def test_quick_uncertain_or_no_choice_preserves_review_text_and_error(self):
        from core import Answer
        for result in (Answer('1', 'review me', 'reason', 'uncertain', (), 1), Answer(None, 'review me', 'reason', None, (), None)):
            self.window.quick_active = True
            with patch.object(gui.QMessageBox, 'warning') as popup, patch.object(self.window.tray, 'showMessage') as notice, patch.object(gui, 'answer_icon', wraps=gui.answer_icon) as icon:
                self.window.answer_done(result, [])
                popup.assert_not_called(); notice.assert_called_once()
                icon.assert_called_with(None, 'number', error=True)
                self.window.output_changed()
                icon.assert_called_with(None, 'number', error=True)
            self.assertIn('review me', self.window.answer.toPlainText())
            self.assertIsNone(self.window.current_order)
            self.assertIn('오류', self.window.tray_status.text())
            self.assertIn('오류', self.window.tray.toolTip())
            self.window.clear_signal()
            self.assertIsNone(self.window.last_error)
            self.assertNotIn('오류', self.window.tray_status.text())

    def test_manual_capture_with_quick_enabled_still_waits_for_send(self):
        from PySide6.QtGui import QImage
        self.window.quick_mode.setChecked(True)
        self.window.cursor.setChecked(True)
        image = QImage(20, 20, QImage.Format.Format_RGB32)
        with patch.object(gui.QTimer, 'singleShot'), patch.object(gui, 'capture_cursor', return_value=image), patch.object(gui, 'ocr_image', return_value='question'), patch.object(gui, 'OllamaClient') as local, patch.object(self.window, 'reveal') as reveal:
            self.window.capture()
            self.window.take_capture(); self.wait_for_idle()
            reveal.assert_called_once(); local.assert_not_called()
        self.assertFalse(self.window.quick_active)
        self.assertIn('검토', self.window.status.text())

    def test_citations_show_pdf_page(self):
        from core import Answer, Source
        source = Source('s1', 'd1', '자료.pdf', '근거 발췌', 1.0, 8)
        self.window.answer_done(Answer(None, '결론', '풀이', None, (source,), None), [source])
        self.assertIn('8쪽', self.window.answer.toPlainText())
        self.assertIn('근거 발췌', self.window.answer.toPlainText())


if __name__ == '__main__':
    unittest.main()
