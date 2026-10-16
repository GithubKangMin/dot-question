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


    def test_cancel_during_api_consent_never_dispatches(self):
        self.window.mode.setCurrentIndex(1)
        self.window.key.setText('synthetic-key')
        self.window.question.setPlainText('synthetic question')
        def cancel_inside_dialog(*_):
            self.assertTrue(self.window.busy)
            self.assertFalse(self.window.question.isEnabled())
            self.window.cancel()
            return True  # A queued OK must not override Cancel/Close.
        with patch.object(self.window, 'consent', side_effect=cancel_inside_dialog), patch.object(gui, 'OpenAIClient') as client:
            self.window.submit(); self.wait_for_idle()
            client.assert_not_called()
        self.assertIn('전송하지', self.window.status.text())

    def test_capture_cancel_restores_manual_window_and_rejects_old_timer(self):
        with patch.object(gui.QTimer, 'singleShot'), patch.object(self.window, 'reveal') as reveal, patch.object(gui, 'capture_cursor') as capture:
            self.window.cursor.setChecked(True)
            self.window.capture()
            generation = self.window.capture_generation
            self.window.cancel()
            reveal.assert_called_once()
            self.window.capture()
            self.window.take_capture(generation)
            capture.assert_not_called()
            self.assertTrue(self.window.capture_pending)
            self.window.cancel()

    def test_clear_during_ocr_cannot_repopulate_question_or_send(self):
        release = threading.Event()
        self.window.question.setPlainText('old question')
        self.window.quick_active = True
        with patch.object(gui, 'OllamaClient') as client:
            self.window.run(lambda: (release.wait(1), 'late OCR')[1], self.window.ocr_done)
            self.window.clear(); release.set(); self.wait_for_idle()
            client.assert_not_called()
        self.assertEqual(self.window.question.toPlainText(), '')
        self.assertEqual(self.window.answer.toPlainText(), '')

    def test_clear_cancels_pending_capture(self):
        with patch.object(gui.QTimer, 'singleShot'), patch.object(gui, 'capture_cursor') as capture:
            self.window.question.setPlainText('old question')
            self.window.capture()
            self.window.clear()
            self.window.take_capture()
            capture.assert_not_called()
        self.assertFalse(self.window.capture_pending)
        self.assertEqual(self.window.question.toPlainText(), '')

    def test_stale_worker_completion_cannot_replace_new_answer(self):
        self.window.answer.setPlainText('current answer')
        self.window.current_order = 2
        self.window.completed(self.window.serial - 1, None, RuntimeError('old'))
        self.assertEqual(self.window.answer.toPlainText(), 'current answer')
        self.assertEqual(self.window.current_order, 2)

    def test_synthetic_grounded_capture_to_validated_answer_and_clipboard(self):
        import json
        import core
        from pathlib import Path
        from PySide6.QtGui import QImage
        document = Path(self.tmp.name) / 'synthetic-study.txt'
        document.write_text('Synthetic mitosis produces two genetically identical daughter cells.', encoding='utf-8')
        self.window.store.import_file(document)
        self.window.grounded.setChecked(True)
        self.window.quick_mode.setChecked(True)
        self.window.autocopy.setChecked(True)
        question = 'What does mitosis produce?\nA. Four different cells\nB. Two identical cells'
        image = QImage(20, 20, QImage.Format.Format_RGB32)
        calls = []
        def fake_http(url, payload=None, **kwargs):
            calls.append((url, payload))
            if url.endswith('/api/tags'):
                return {'models': [{'name': 'qwen3:4b-instruct', 'size': 100, 'digest': 'synthetic', 'details': {'format': 'gguf'}}]}
            request = json.loads(payload['messages'][1]['content'])
            self.assertEqual(request['question'], question)
            self.assertEqual(request['allowed_choice_labels'], ['A', 'B'])
            self.assertEqual(len(request['sources']), 1)
            source_id = request['sources'][0]['id']
            response = {'selected_choice': 'B', 'answer': 'Two identical daughter cells', 'explanation': 'The supplied study text states the result of mitosis.', 'citations': [source_id], 'uncertainty': None}
            return {'done': True, 'message': {'content': json.dumps(response)}}
        with patch.object(gui.QTimer, 'singleShot'), patch.object(gui, 'capture_cursor', return_value=image), patch.object(gui, 'ocr_image', return_value=question), patch.object(core, '_request_json', side_effect=fake_http), patch.object(gui.QMessageBox, 'warning') as warning:
            self.window.capture(from_hotkey=True)
            self.window.take_capture(); self.wait_for_idle()
            warning.assert_not_called()
        self.assertEqual(len(calls), 2)
        self.assertEqual(self.window.current_order, 2)
        self.assertIn('synthetic-study.txt', self.window.answer.toPlainText())
        self.assertEqual(self.app.clipboard().text(), self.window.answer.toPlainText())

    def test_grounded_no_hit_never_contacts_model(self):
        import core
        self.window.grounded.setChecked(True)
        self.window.question.setPlainText('nonmatching synthetic question')
        self.app.clipboard().setText('keep clipboard')
        self.window.autocopy.setChecked(True)
        with patch.object(core, '_request_json') as http, patch.object(gui.QMessageBox, 'warning') as warning:
            self.window.submit(); self.wait_for_idle()
            http.assert_not_called(); warning.assert_called_once()
        self.assertEqual(self.app.clipboard().text(), 'keep clipboard')
        self.assertIsNone(self.window.current_order)

    def test_invalid_citation_fails_without_signal_or_autocopy(self):
        import core
        import json
        self.window.question.setPlainText('Choose\nA. First\nB. Second')
        self.window.autocopy.setChecked(True)
        self.app.clipboard().setText('keep clipboard')
        raw = {'selected_choice': 'A', 'answer': 'First', 'explanation': 'Synthetic explanation', 'citations': ['invented-source'], 'uncertainty': None}
        with patch.object(core.OllamaClient, 'list_models', return_value=['qwen3:4b-instruct']), patch.object(core, '_request_json', return_value={'done': True, 'message': {'content': json.dumps(raw)}}), patch.object(gui.QMessageBox, 'warning') as warning:
            self.window.submit(); self.wait_for_idle(); warning.assert_called_once()
        self.assertEqual(self.window.answer.toPlainText(), '')
        self.assertEqual(self.app.clipboard().text(), 'keep clipboard')
        self.assertIsNone(self.window.current_order)

    def test_uncertain_answer_keeps_clipboard_and_has_no_signal(self):
        from core import validate_answer, parse_options
        self.window.autocopy.setChecked(True)
        self.app.clipboard().setText('keep clipboard')
        result = validate_answer({'selected_choice': 'A', 'answer': 'Maybe first', 'explanation': 'OCR is ambiguous.', 'citations': [], 'uncertainty': 'Review OCR'}, parse_options('Choose\nA. First\nB. Second'), [])
        self.window.answer_done(result, [])
        self.assertIn('Review OCR', self.window.answer.toPlainText())
        self.assertIsNone(self.window.current_order)
        self.assertEqual(self.app.clipboard().text(), 'keep clipboard')



    def test_import_picker_preserves_context_without_auto_send(self):
        import json
        from pathlib import Path
        from test_question_import import fixture
        data = fixture('short_answer')
        data['groups'][0]['questions'].append(dict(id='q2', type='long_answer', text='Another?', choices=[]))
        file = Path(self.tmp.name) / 'questions.json'; file.write_text(json.dumps(data))
        self.window.quick_mode.setChecked(True)
        with patch.object(gui.QFileDialog, 'getOpenFileName', return_value=(str(file), '')), patch.object(self.window, 'submit') as send:
            self.window.import_questions()
            send.assert_not_called()
        self.assertTrue(self.window.question.isReadOnly())
        self.assertIn('Shared passage', self.window.question.toPlainText())
        self.window.question_picker.setCurrentIndex(2)
        self.assertIn('Shared passage', self.window.question.toPlainText())
        self.assertIn('Another?', self.window.question.toPlainText())
        self.window.ocr_done('OCR fallback')
        self.assertIsNone(self.window.imported_question)
        self.assertFalse(self.window.question.isReadOnly())

    def test_subjective_answer_only_copy_and_uncertainty_preservation(self):
        from core import Answer
        self.window.autocopy.setChecked(True)
        result = Answer(None, 'Only answer', 'Separate reasoning', None, (), None, 'long_answer')
        self.window.answer_done(result, [])
        self.assertEqual(self.app.clipboard().text(), 'Only answer')
        self.assertIn('Separate reasoning', self.window.answer.toPlainText())
        self.app.clipboard().setText('keep')
        result = Answer(None, 'Guess', 'Reason', 'Unsure', (), None, 'short_answer')
        self.window.answer_done(result, []); self.window.copy_answer()
        self.assertEqual(self.app.clipboard().text(), 'keep')
        self.window.clear_signal(); self.window.copy_answer()
        self.assertEqual(self.app.clipboard().text(), 'keep')

    def test_false_zero_is_valid_tray_answer(self):
        from core import Answer
        from icons import answer_icon
        self.window.style.setCurrentText('wifi')
        self.window.show_answer.setChecked(True)
        with patch.object(gui, 'answer_icon', wraps=answer_icon) as render:
            self.window.answer_done(Answer('false', 'False', 'Reason', None, (), 0, 'true_false'), [])
            render.assert_called_with(0, 'wifi', 'off', 0)
            self.assertIsNotNone(render.call_args.args[0])
            self.assertEqual(self.window.current_order, 0)
            self.assertIsNotNone(self.window.current_order)
            self.assertEqual(self.window.tray_status.text(), '답 · 0')
            self.assertIsNone(self.window.last_error)
            self.window.clear_signal()
            self.window.render_icon()
            self.assertIsNone(self.window.current_order)
            render.assert_called_with(None, 'wifi', 'off', 0)
        # Geometry survives headless Windows fonts: zero bars versus five bars.
        # The semantic zero-versus-unknown distinction is verified above at the
        # actual Window -> renderer boundary, without depending on glyph pixels.
        self.assertNotEqual(answer_icon(0, 'wifi').pixmap(64).toImage(), answer_icon(5, 'wifi').pixmap(64).toImage())

    def test_true_false_character_has_no_blink(self):
        from core import Answer
        self.window.character.setCurrentText('cat')
        self.window.style.setCurrentText('wifi')
        self.window.reduce_motion.setChecked(False)
        for choice, signal in [('true', 5), ('false', 0)]:
            self.window.answer_done(Answer(choice, choice, 'Reason', None, (), signal, 'true_false'), [])
            self.assertEqual(self.window.current_order, signal)
            self.assertFalse(self.window.animation.isActive())
            self.assertEqual(self.window.remaining_frames, 0)
            self.assertIsNone(self.window.last_error)

if __name__ == '__main__':
    unittest.main()
