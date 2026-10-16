"""Capture actual Qt widgets with synthetic fixtures; never capture the user's desktop."""
import json
import os
from pathlib import Path
import sys
import tempfile
import time
from unittest.mock import patch

root = Path(__file__).resolve().parents[1] / 'dot-question-windows'
sys.path.insert(0, str(root))
os.environ['QT_QPA_PLATFORM'] = 'offscreen'
from PySide6.QtWidgets import QApplication, QLabel, QVBoxLayout, QWidget
import app as gui
import win_capture
from core import validate_answer, parse_options

output = Path(sys.argv[1]).resolve()
output.mkdir(parents=True, exist_ok=True)
application = QApplication.instance() or QApplication([])
with tempfile.TemporaryDirectory() as temporary, patch.dict(os.environ, {'LOCALAPPDATA': temporary}), patch.object(win_capture, '_IS_WINDOWS', False):
    window = gui.Window()
    window.resize(1100, 1200)
    fixture = Path(temporary) / 'CI-synthetic-study.txt'
    fixture.write_text('광합성은 빛 에너지를 이용해 이산화탄소와 물로 포도당과 산소를 만듭니다.', encoding='utf-8')
    window.store.import_file(fixture)
    window.refresh_docs()
    question = '[CI 합성 질문] 광합성에 필요한 에너지는?\n1. 소리\n2. 빛\n3. 바람'
    window.question.setPlainText(question)
    window.grounded.setChecked(True)
    sources = window.store.retrieve(question)
    assert sources, 'Fixture must be retrieved'
    response = validate_answer({'selected_choice': '2', 'answer': '빛 에너지', 'explanation': '합성 자료에서 광합성은 빛 에너지를 이용한다고 설명합니다. (CI 고정 응답, 실제 AI 호출 아님)', 'citations': [s.id for s in sources], 'uncertainty': None}, parse_options(question), sources)
    with patch.object(gui, 'OllamaClient') as client:
        client.return_value.answer.return_value = response
        window.submit()
        deadline = time.monotonic() + 10
        while window.busy and time.monotonic() < deadline:
            application.processEvents()
            time.sleep(0.01)
        assert not window.busy and window.current_order == 2
        client.return_value.answer.assert_called_once()
    window.status.setText('CI 합성 자료 · 고정 응답 검증 완료 · 네트워크/API 호출 없음')
    window.show()
    application.processEvents()
    assert window.grab().save(str(output / 'windows-app-view.png'))
    # Real tray icon pixels and menu widgets; explicitly not a Windows desktop capture.
    preview = QWidget()
    layout = QVBoxLayout(preview)
    layout.addWidget(QLabel('CI: application tray icon + menu widgets (not the OS taskbar)'))
    icon = QLabel(); icon.setPixmap(window.tray.icon().pixmap(64, 64)); layout.addWidget(icon)
    preview.show(); application.processEvents()
    assert preview.grab().save(str(output / 'windows-tray-icon-app-view.png'))
    menu = window.tray.contextMenu()
    menu.show(); application.processEvents()
    assert menu.grab().save(str(output / 'windows-tray-menu-app-view.png'))
    (output / 'capture-context.txt').write_text('Real PySide6 QWidget.grab renders on Windows with offscreen platform. Synthetic imported source, question and validated mock response via the app request/completion path. Tray icon/menu are app-rendered views, not proof of OS taskbar placement. No live model, API, OCR, clipboard or global shortcut operation.\n', encoding='utf-8')
    menu.hide(); preview.hide(); window.hk.close(); window.tray.hide(); window.animation.stop(); window.hide()
print('SCREENSHOTS: actual Qt app widgets saved to', output)
