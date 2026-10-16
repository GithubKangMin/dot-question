"""dot question Windows UI. No autostart, telemetry, or stored API credentials."""
import json
import os
import sys
import threading
from pathlib import Path
from PySide6.QtCore import QObject, Signal, QTimer, Qt, QSettings
from PySide6.QtGui import QAction
from PySide6.QtWidgets import (QApplication, QMainWindow, QWidget, QVBoxLayout,
    QHBoxLayout, QFormLayout, QLabel, QLineEdit, QPushButton, QPlainTextEdit,
    QComboBox, QCheckBox, QSpinBox, QFileDialog, QMessageBox, QListWidget,
    QSystemTrayIcon, QMenu, QDialog, QDialogButtonBox, QSplitter, QScrollArea)
from core import DocumentStore, retrieve, parse_options, build_messages, OllamaClient, OpenAIClient
from win_capture import Hotkeys, CaptureOverlay, capture_cursor, ocr_image
from icons import answer_icon


class Completed(QObject):
    result = Signal(int, object, object)


class Window(QMainWindow):
    def __init__(self):
        super().__init__()
        self.setWindowTitle('dot question · Windows')
        available = QApplication.primaryScreen().availableGeometry()
        self.resize(min(900, available.width()), min(850, available.height()))
        self.busy = False
        self.cancelled = False
        self.serial = 0
        self.current_order = None
        self.frame = 0
        self.remaining_frames = 0
        self.overlay = None
        self.capture_pending = False
        self.quick_active = False
        self.last_error = None
        settings_dir = Path(os.environ.get("LOCALAPPDATA", str(Path.home() / ".local" / "share"))) / "DotQuestion"
        self.settings = QSettings(str(settings_dir / "preferences.ini"), QSettings.Format.IniFormat)
        self.closing = False
        self.done = Completed()
        self.done.result.connect(self.completed)
        self.callback = None
        root = QWidget()
        scroll = QScrollArea(); scroll.setWidgetResizable(True); scroll.setWidget(root)
        self.setCentralWidget(scroll)
        layout = QVBoxLayout(root)
        layout.addWidget(QLabel('기본: OCR → 질문 검토 → 직접 전송. 로컬 빠른 모드를 켜면 자동 처리합니다. AI 답변은 틀릴 수 있습니다.'))
        form = QFormLayout()
        self.mode = QComboBox(); self.mode.addItems(['로컬 · Ollama', 'API · OpenAI (유료)'])
        self.local_model = QLineEdit('qwen3:4b-instruct')
        self.api_model = QLineEdit('gpt-4.1-mini')
        self.endpoint = QLineEdit('http://127.0.0.1:11434')
        self.key = QLineEdit(); self.key.setEchoMode(QLineEdit.EchoMode.Password)
        self.key.setPlaceholderText('세션 메모리에만 유지. 저장하지 않습니다.')
        clear_key = QPushButton('키 지우기'); clear_key.clicked.connect(self.key.clear)
        key_row = QHBoxLayout(); key_row.addWidget(self.key); key_row.addWidget(clear_key)
        form.addRow('모드', self.mode); form.addRow('로컬 주소', self.endpoint)
        form.addRow('로컬 모델', self.local_model); form.addRow('API 모델', self.api_model)
        form.addRow('OpenAI API 키', key_row)
        layout.addLayout(form)
        capture_row = QHBoxLayout()
        capture_button = QPushButton('영역 / 커서 캡처'); capture_button.clicked.connect(self.capture)
        self.cursor = QCheckBox('커서 중심')
        self.width_box = QSpinBox(); self.width_box.setRange(100, 4000); self.width_box.setValue(900)
        self.height_box = QSpinBox(); self.height_box.setRange(100, 4000); self.height_box.setValue(600)
        for w in [capture_button, self.cursor, QLabel('너비'), self.width_box, QLabel('높이'), self.height_box]: capture_row.addWidget(w)
        layout.addLayout(capture_row)
        self.quick_mode = QCheckBox('로컬 빠른 모드 · 단축키 → 커서 OCR → Ollama → 트레이 (자동 전송)')
        self.quick_mode.setChecked(self.settings.value('quick_mode', False, type=bool))
        layout.addWidget(self.quick_mode)
        shortcuts = QHBoxLayout()
        self.hotkey = QComboBox(); self.hotkey.addItems(['R', 'Space', 'Enter'])
        self.armed = QCheckBox('단축키 후 Enter 준비 · 10초')
        shortcuts.addWidget(QLabel('Ctrl+Alt+Shift +')); shortcuts.addWidget(self.hotkey); shortcuts.addWidget(self.armed)
        apply = QPushButton('단축키 적용'); apply.clicked.connect(self.apply_hotkey); shortcuts.addWidget(apply)
        layout.addLayout(shortcuts)
        layout.addWidget(QLabel('준비 중 Enter는 다른 앱에 입력되지 않을 수 있습니다. Esc로 해제합니다.'))
        self.question = QPlainTextEdit(); self.question.setPlaceholderText('문제를 붙여넣거나 캡처하세요. 보기마다 줄바꿈하세요.')
        self.question.setMinimumHeight(130); self.question.textChanged.connect(self.clear_signal)
        self.answer = QPlainTextEdit(); self.answer.setReadOnly(True); self.answer.setMinimumHeight(130)
        split = QSplitter(Qt.Orientation.Vertical); split.addWidget(self.question); split.addWidget(self.answer)
        layout.addWidget(split, 1)
        docs_row = QHBoxLayout()
        self.grounded = QCheckBox('자료 근거 모드 (검색 없으면 전송 안 함)'); docs_row.addWidget(self.grounded)
        import_button = QPushButton('PDF / TXT / MD 가져오기'); import_button.clicked.connect(self.import_document); docs_row.addWidget(import_button)
        delete_button = QPushButton('선택 자료 삭제'); delete_button.clicked.connect(self.delete_document); docs_row.addWidget(delete_button)
        layout.addLayout(docs_row)
        self.documents = QListWidget(); self.documents.setMaximumHeight(90); layout.addWidget(self.documents)
        outputs = QHBoxLayout()
        self.autocopy = QCheckBox('검증 답변 자동 복사')
        self.show_answer = QCheckBox('트레이에 선택 번호')
        self.show_answer.setChecked(self.settings.value('show_answer', True, type=bool))
        self.style = QComboBox(); self.style.addItems(['number', 'wifi', 'battery'])
        self.character = QComboBox(); self.character.addItems(['off', 'cat', 'pikachu'])
        self.style.setCurrentText(self.settings.value('style', 'number'))
        self.character.setCurrentText(self.settings.value('character', 'off'))
        self.reduce_motion = QCheckBox('움직임 줄이기')
        self.reduce_motion.setChecked(self.settings.value('reduce_motion', False, type=bool))
        for w in [self.autocopy, self.show_answer, self.style, self.character, self.reduce_motion]: outputs.addWidget(w)
        layout.addLayout(outputs)
        layout.addWidget(QLabel('Wi-Fi/배터리 그림은 앱의 답 표시이며 실제 상태가 아닙니다. 화면 공유에 보일 수 있습니다.'))
        actions = QHBoxLayout()
        self.send = QPushButton('로컬 AI로 전송'); self.send.clicked.connect(self.submit)
        cancel = QPushButton('취소'); cancel.clicked.connect(self.cancel)
        copy = QPushButton('답변 복사'); copy.clicked.connect(lambda: QApplication.clipboard().setText(self.answer.toPlainText()))
        clear = QPushButton('내용 지우기'); clear.clicked.connect(self.clear)
        for w in [self.send, cancel, copy, clear]: actions.addWidget(w)
        layout.addLayout(actions)
        self.status = QLabel('준비'); self.status.setWordWrap(True); layout.addWidget(self.status)
        self.tray = QSystemTrayIcon(answer_icon(None, 'number'), self)
        self.tray.setToolTip('dot question · 앱 답 표시 (실제 Wi-Fi/배터리 상태 아님)')
        menu = QMenu(self)
        self.tray_status = QAction('준비 · Q?', self); self.tray_status.setEnabled(False)
        menu.addAction(self.tray_status); menu.addSeparator()
        for title, action in [('창 열기', self.reveal), ('캡처', self.capture), ('취소', self.cancel), ('종료', self.quit)]:
            item = QAction(title, self); item.triggered.connect(action); menu.addAction(item)
        self.tray.setContextMenu(menu); self.tray.activated.connect(lambda reason: self.reveal() if reason in (QSystemTrayIcon.ActivationReason.Trigger, QSystemTrayIcon.ActivationReason.DoubleClick) else None); self.tray.show()
        self.animation = QTimer(self); self.animation.setInterval(500); self.animation.timeout.connect(self.animate)
        for widget in [self.show_answer, self.reduce_motion]: widget.toggled.connect(self.output_changed)
        self.style.currentTextChanged.connect(self.output_changed); self.character.currentTextChanged.connect(self.output_changed)
        self.quick_mode.toggled.connect(self.quick_mode_changed)
        self.mode.currentIndexChanged.connect(self.mode_changed)
        self.hk = Hotkeys(self); self.hk.triggered.connect(lambda: self.capture(from_hotkey=True)); self.hk.armed_changed.connect(self.arm_changed)
        self.hk.error.connect(lambda message: self.status.setText('단축키 오류: ' + message))
        path = Path(os.environ.get('LOCALAPPDATA', str(Path.home() / '.local' / 'share'))) / 'DotQuestion' / 'documents.json'
        self.store = DocumentStore(path)
        self.storage_error = None
        try:
            self.store.load(); self.refresh_docs()
        except Exception as error:
            self.storage_error = str(error); self.status.setText('자료 저장소 오류: ' + str(error))
        self.mode_changed()
        QTimer.singleShot(0, self.apply_hotkey)

    def show_on_startup(self):
        if not (self.quick_mode.isChecked() and QSystemTrayIcon.isSystemTrayAvailable()):
            self.show()

    def quick_mode_changed(self, enabled):
        if enabled: self.show_answer.setChecked(True)
        self.save_preferences()

    def save_preferences(self, *_):
        # Only non-content preferences are persisted, never questions/keys/results.
        for name in ('quick_mode', 'show_answer', 'reduce_motion'):
            self.settings.setValue(name, getattr(self, name).isChecked())
        for name in ('style', 'character'):
            self.settings.setValue(name, getattr(self, name).currentText())
        self.settings.sync()

    def mode_changed(self):
        api = self.mode.currentIndex() == 1
        self.endpoint.setEnabled(not api); self.local_model.setEnabled(not api)
        self.key.setEnabled(api); self.api_model.setEnabled(api)
        self.send.setText('OpenAI API로 전송 (유료)' if api else '로컬 AI로 전송')
        self.clear_signal()

    def reveal(self):
        self.showNormal(); self.raise_(); self.activateWindow()

    def error(self, error, preserve_answer=False):
        answer = self.answer.toPlainText() if preserve_answer else ''
        self.clear_signal()
        if preserve_answer: self.answer.setPlainText(answer)
        self.last_error = str(error)
        self.status.setText(str(error))
        self.tray_status.setText('오류 · ' + str(error))
        self.tray.setToolTip('dot question · 오류: ' + str(error))
        self.render_icon()
        if self.quick_active:
            self.tray.showMessage('dot question · 빠른 모드', str(error), QSystemTrayIcon.MessageIcon.Warning)
            self.quick_active = False
        else:
            QMessageBox.warning(self, 'dot question', str(error))

    def apply_hotkey(self):
        try:
            self.hk.configure(self.hotkey.currentText(), self.armed.isChecked())
            self.status.setText('단축키 적용됨')
        except Exception as error: self.status.setText('단축키: ' + str(error) + ' · 캡처 버튼을 사용하세요.')

    def arm_changed(self, armed):
        if armed:
            self.clear_signal(); self.status.setText('10초 내 Enter로 캡처 / Esc로 취소')
        else: self.status.setText('준비 해제')

    def run(self, fn, callback):
        if self.busy: return
        self.busy = True; self.cancelled = False; self.serial += 1
        serial = self.serial; self.callback = callback
        self.question.setEnabled(False); self.send.setEnabled(False); self.mode.setEnabled(False)
        def work():
            try: result, error = fn(), None
            except Exception as exc: result, error = None, exc
            try: self.done.result.emit(serial, result, error)
            except RuntimeError: pass  # Application may have exited.
        threading.Thread(target=work, daemon=True).start()

    def completed(self, serial, value, error):
        if serial != self.serial or self.closing: return
        self.busy = False; self.question.setEnabled(True); self.send.setEnabled(True); self.mode.setEnabled(True)
        callback = self.callback; self.callback = None
        if self.cancelled:
            self.quick_active = False
            self.refresh_docs(); self.status.setText('취소됨. 이미 시작된 요청/자료 저장은 되돌리지 않습니다.'); return
        if error: self.error(error); return
        callback(value)

    def cancel(self):
        self.hk.disarm(); self.cancelled = True; self.capture_pending = False; self.clear_signal()
        if self.overlay:
            self.overlay.close(); self.overlay = None
            if not self.quick_active: self.reveal()
        self.quick_active = False
        self.status.setText('결과 표시 취소됨. 작업 종료까지 기다립니다. 이미 전송된 API 요청은 과금될 수 있습니다.' if self.busy else '취소됨')

    def clear(self):
        if self.busy: self.cancel(); return
        self.question.clear(); self.answer.clear(); self.clear_signal()

    def capture(self, checked=False, *, from_hotkey=False):
        self.hk.disarm()
        if self.busy or self.overlay or self.capture_pending: return
        self.quick_active = from_hotkey and self.quick_mode.isChecked()
        self.clear_signal()
        if self.quick_active and self.mode.currentIndex() != 0:
            self.error('빠른 모드는 로컬 Ollama 전용입니다. 로컬 모드를 선택하세요. API는 전송하지 않았습니다.')
            return
        self.capture_pending = True
        self.hide()
        QTimer.singleShot(250, self.take_capture)

    def take_capture(self):
        if self.closing or not self.capture_pending: return
        self.capture_pending = False
        try:
            if self.quick_active or self.cursor.isChecked():
                self.captured(capture_cursor(self.width_box.value(), self.height_box.value()))
            else:
                self.overlay = CaptureOverlay()
                self.overlay.finished.connect(self.captured); self.overlay.show()
        except Exception as error:
            if not self.quick_active: self.reveal()
            self.error(error)

    def captured(self, image):
        self.overlay = None
        if not self.quick_active: self.reveal()
        if image is None or image.isNull():
            self.quick_active = False; self.status.setText('캡처 취소'); return
        self.status.setText('오프라인 OCR 중…')
        self.run(lambda: ocr_image(image), self.ocr_done)

    def ocr_done(self, text):
        self.question.setPlainText(text)
        if self.quick_active:
            if not text.strip(): self.error('텍스트를 찾지 못했습니다. 캡처 범위를 확인하세요.'); return
            self.submit(automatic=True)
        else:
            self.status.setText('OCR 완료. 질문을 검토하고 전송하세요.' if text.strip() else '텍스트를 찾지 못했습니다. 직접 붙여넣을 수 있습니다.')

    def refresh_docs(self):
        self.documents.clear()
        for doc in self.store.documents:
            self.documents.addItem(doc.name)
            self.documents.item(self.documents.count()-1).setData(Qt.ItemDataRole.UserRole, doc.id)

    def import_document(self):
        if self.busy: return
        if self.storage_error: self.error(self.storage_error); return
        file, _ = QFileDialog.getOpenFileName(self, '로컬 자료 가져오기', '', '자료 (*.pdf *.txt *.md)')
        if not file: return
        self.status.setText('자료 읽기/색인 중…')
        self.run(lambda: self.store.import_file(file), lambda _: (self.refresh_docs(), self.status.setText('로컬 자료 저장 완료')))

    def delete_document(self):
        if self.busy: return
        item = self.documents.currentItem()
        if not item: return
        if QMessageBox.question(self, '가져온 텍스트 삭제', '가져온 자료의 텍스트를 삭제할까요? 원본 파일은 유지됩니다.') != QMessageBox.StandardButton.Yes: return
        try: self.store.remove(item.data(Qt.ItemDataRole.UserRole)); self.refresh_docs()
        except Exception as error: self.error(error)

    def consent(self, question, sources):
        dialog = QDialog(self); dialog.setWindowTitle('OpenAI 전송 · 매 요청 확인'); dialog.resize(760, 630)
        layout = QVBoxLayout(dialog)
        label = QLabel('목적지: https://api.openai.com/v1/chat/completions\n질문과 아래 자료 발췌를 OpenAI에 전송합니다. 캡처 이미지는 보내지 않습니다.\nChatGPT 구독과 별도 과금이며 금액 한도를 보증하지 않습니다. 취소는 환불이 아닙니다.\nAPI 키는 인증에 사용하며 파일로 저장하지 않습니다. store:false도 모든 로그 삭제를 보증하지 않습니다.')
        label.setWordWrap(True); layout.addWidget(label)
        preview = QPlainTextEdit(); preview.setReadOnly(True)
        preview.setPlainText(json.dumps({'model': self.api_model.text().strip(), 'messages': build_messages(question, sources, requires_sources=self.grounded.isChecked()), 'stream': False, 'store': False, 'max_completion_tokens': 2048, 'response_format': {'type':'json_object'}}, ensure_ascii=False, indent=2))
        layout.addWidget(preview)
        links = QLabel('<a href="https://platform.openai.com/docs/guides/your-data">OpenAI 데이터 정책</a> · <a href="https://openai.com/api/pricing/">요금</a>')
        links.setOpenExternalLinks(True); layout.addWidget(links)
        buttons = QDialogButtonBox(QDialogButtonBox.StandardButton.Ok | QDialogButtonBox.StandardButton.Cancel)
        buttons.button(QDialogButtonBox.StandardButton.Ok).setText('위 내용 전송 / 과금 동의')
        buttons.accepted.connect(dialog.accept); buttons.rejected.connect(dialog.reject); layout.addWidget(buttons)
        return dialog.exec() == QDialog.DialogCode.Accepted

    def submit(self, automatic=False):
        if self.busy: return
        self.quick_active = bool(automatic)
        if automatic and self.mode.currentIndex() != 0:
            self.error("빠른 모드는 로컬 Ollama 전용입니다. API는 전송하지 않았습니다."); return
        self.hk.disarm(); self.clear_signal()
        question = self.question.toPlainText().strip()
        if not question: self.error('질문을 입력하세요.'); return
        api = self.mode.currentIndex() == 1
        required = self.grounded.isChecked()
        documents = self.store.documents
        def prepare():
            sources = retrieve(question, documents, limit=6 if api else 3,
                               max_characters=7200 if api else 2400) if required else []
            build_messages(question, sources, requires_sources=required)
            return sources
        self.status.setText('질문/자료 검색 중…')
        self.run(prepare, lambda sources: self.start_request(question, sources, api, required, automatic))

    def start_request(self, question, sources, api, required, automatic=False):
        try:
            if automatic and (api or self.mode.currentIndex() != 0):
                raise ValueError('빠른 모드는 로컬 Ollama 전용입니다. API는 전송하지 않았습니다.')
            if api:
                if not self.key.text().strip(): raise ValueError('API 키를 보안 입력칸에 입력하세요.')
                if not self.consent(question, sources):
                    self.status.setText('전송하지 않았습니다.'); return
                client = OpenAIClient(model=self.api_model.text().strip())
                session_key = self.key.text().strip()
                fn = lambda: client.answer(session_key, question, sources, requires_sources=required)
            else:
                client = OllamaClient(self.endpoint.text().strip())
                model = self.local_model.text().strip()
                fn = lambda: client.answer(model, question, sources, requires_sources=required)
            self.status.setText('응답 대기 중…'); self.answer.clear()
            self.run(fn, lambda result: self.answer_done(result, sources))
        except Exception as error: self.error(error)

    def answer_done(self, result, sources):
        lines = []
        if result.choice: lines.append('선택: ' + result.choice)
        lines.append(result.answer)
        lines.append(result.explanation)
        if result.uncertainty: lines.append('불확실: ' + str(result.uncertainty))
        for source in result.citations:
            lines.append(f'[{source.id}] {source.citation_label}\n{source.text}')
        text = '\n\n'.join(lines); self.answer.setPlainText(text)
        self.status.setText('응답 형식/보기/출처 ID 검증 완료. 사실성은 직접 확인하세요.')
        if self.autocopy.isChecked(): QApplication.clipboard().setText(text)
        self.current_order = result.choice_index if not result.uncertainty else None
        if self.quick_active and not self.current_order:
            self.error('확실한 선택 번호를 얻지 못했습니다. 창을 열어 답변을 검토하세요.', preserve_answer=True)
            return
        self.quick_active = False
        self.tray_status.setText('답 · ' + str(self.current_order) if self.current_order else '답변 검토 필요')
        self.tray.setToolTip('dot question · 답: ' + str(self.current_order) if self.current_order else 'dot question · 답변 검토 필요')
        self.output_changed()
        if self.current_order and self.character.currentText() != 'off' and not self.reduce_motion.isChecked():
            self.remaining_frames = self.current_order * 2; self.render_icon(); self.animation.start()

    def clear_signal(self):
        if not hasattr(self, 'tray'): return
        self.answer.clear()
        self.last_error = None
        self.tray_status.setText('준비 · Q?')
        self.tray.setToolTip('dot question · 앱 답 표시 (실제 Wi-Fi/배터리 상태 아님)')
        self.animation.stop(); self.current_order = None; self.frame = 0; self.remaining_frames = 0
        self.tray.setIcon(answer_icon(None, 'number'))

    def output_changed(self, *_):
        self.save_preferences()
        self.animation.stop(); self.frame = 0; self.remaining_frames = 0
        self.render_icon()

    def render_icon(self):
        if self.last_error:
            self.tray.setIcon(answer_icon(None, 'number', error=True)); return
        order = self.current_order
        char = self.character.currentText()
        if not self.show_answer.isChecked() and char == 'off': order = None
        if order is None: char = 'off'
        self.tray.setIcon(answer_icon(order, self.style.currentText(), char, self.frame))

    def animate(self):
        self.frame = 1 - self.frame; self.remaining_frames -= 1
        if self.remaining_frames <= 0: self.animation.stop(); self.frame = 0; self.remaining_frames = 0
        self.render_icon()

    def closeEvent(self, event):
        self.cancel(); self.clear_signal()
        if QSystemTrayIcon.isSystemTrayAvailable(): event.ignore(); self.hide()
        else: self.quit(); event.accept()

    def quit(self):
        self.closing = True; self.cancelled = True; self.serial += 1
        self.hk.close(); self.animation.stop(); self.key.clear(); self.tray.hide()
        if self.overlay: self.overlay.close()
        QApplication.instance().quit()


def main():
    app = QApplication(sys.argv)
    app.setApplicationName('DotQuestion'); app.setQuitOnLastWindowClosed(False)
    window = Window(); app.aboutToQuit.connect(window.hk.close); window.show_on_startup()
    return app.exec()


if __name__ == '__main__':
    sys.exit(main())
