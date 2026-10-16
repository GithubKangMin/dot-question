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
from PySide6.QtWidgets import QApplication, QLabel, QVBoxLayout, QHBoxLayout, QWidget
from PySide6.QtGui import QFontDatabase, QFont, QRawFont
import app as gui
import win_capture
from core import validate_answer, parse_options

output = Path(sys.argv[1]).resolve()
output.mkdir(parents=True, exist_ok=True)
application = QApplication.instance() or QApplication([])
# The Windows offscreen platform does not populate its font database automatically.
# Load the runner's installed Korean font explicitly, without downloading anything.
if sys.platform == 'win32':
    font_path = Path(os.environ.get('WINDIR', 'C:/Windows')) / 'Fonts' / 'malgun.ttf'
    font_id = QFontDatabase.addApplicationFont(str(font_path))
    assert font_id >= 0, f'Could not load installed font: {font_path}'
    families = QFontDatabase.applicationFontFamilies(font_id)
    assert families, 'Korean font must be available for readable screenshots'
    application.setFont(QFont(families[0], 10))
    raw_font = QRawFont.fromFont(application.font())
    glyphs = raw_font.glyphIndexesForString('광합성질문답변설정자료고양이피카츄')
    assert raw_font.isValid() and glyphs and all(glyphs), 'Missing Korean glyphs'
    assert all(not raw_font.pathForGlyph(glyph).isEmpty() for glyph in glyphs), 'Empty Korean glyph outlines'
    print('SCREENSHOT FONT:', raw_font.familyName(), 'Korean glyph coverage verified')


def save_view(widget, filename):
    image = widget.grab().toImage()
    assert not image.isNull(), f'Null screenshot: {filename}'
    colors = []
    visible = 0
    for y in range(0, image.height(), 3):
        for x in range(0, image.width(), 3):
            color = image.pixelColor(x, y)
            visible += color.alpha() > 230
            colors.append((color.red() // 16, color.green() // 16, color.blue() // 16))
    assert colors and visible > len(colors) * .9, f'Transparent screenshot: {filename}'
    from collections import Counter
    counts = Counter(colors)
    contrast = len(colors) - counts.most_common(1)[0][1]
    assert len(counts) >= 8 and contrast > len(colors) * .005, f'Blank screenshot: {filename}'
    assert image.save(str(output / filename)), f'Cannot save {filename}'
    print(f'SCREENSHOT PIXELS: {filename} visible={visible}/{len(colors)}, nonbackground={contrast}')

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
    save_view(window, 'windows-app-view.png')
    # Real tray icon pixels and menu widgets; explicitly not a Windows desktop capture.
    preview = QWidget()
    layout = QVBoxLayout(preview)
    layout.addWidget(QLabel('앱 아이콘 렌더링 · 시스템 작업 표시줄 캡처 아님'))
    row = QHBoxLayout(); layout.addLayout(row)
    for label, style, character in [('Wi-Fi형 · 보기 2', 'wifi', 'off'),
                                     ('배터리형 · 보기 2', 'battery', 'off'),
                                     ('고양이 · 활성 프레임', 'number', 'cat'),
                                     ('피카츄 · 활성 프레임', 'number', 'pikachu')]:
        column = QVBoxLayout(); row.addLayout(column)
        pixmap = gui.answer_icon(2, style, character, 1).pixmap(64, 64)
        assert not pixmap.isNull(), f'Missing icon: {label}'
        icon = QLabel(); icon.setPixmap(pixmap); column.addWidget(icon)
        column.addWidget(QLabel(label))
    preview.show(); application.processEvents()
    save_view(preview, 'windows-tray-icon-app-view.png')
    menu = window.tray.contextMenu()
    menu.show(); application.processEvents()
    save_view(menu, 'windows-tray-menu-app-view.png')
    (output / 'capture-context.txt').write_text(f'Real PySide6 QWidget.grab renders on {sys.platform} with offscreen platform. Synthetic imported source, question and validated mock response via the app request/completion path. Tray icon preview uses production Wi-Fi, battery, cat and Pikachu renderers; icon/menu panels are app-rendered views, not proof of OS taskbar placement. Nonblank opaque pixels are asserted. The Windows-only font check requires installed Malgun with Korean glyph outlines; other platforms use their local font environment. No live model, API, OCR, clipboard or global shortcut operation.\n', encoding='utf-8')
    menu.hide(); preview.hide(); window.hk.close(); window.tray.hide(); window.animation.stop(); window.hide()
print('SCREENSHOTS: actual Qt app widgets saved to', output)
