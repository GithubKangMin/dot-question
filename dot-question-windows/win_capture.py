"""Windows hotkeys, in-memory screenshots, and offline OCR.

Call capture functions and Hotkeys on Qt's GUI thread. Run ocr_image in a worker.
Qt 6 supplies per-monitor DPI awareness: do not change process DPI awareness after
QApplication starts. Screen rectangles and pointer positions use Qt logical
coordinates. Each monitor is captured separately at its native pixel density;
selected pieces are assembled at the highest participating density. Windows can
leave gaps between mixed-DPI screen rectangles in Qt's virtual desktop. Those
gaps remain white, rather than guessing a different monitor arrangement.

No screenshot is saved to a file, clipboard, or remote service. In particular we
do not use pytesseract.image_to_string, which creates temporary image files.
Tesseract receives PNG bytes on stdin and returns text on stdout.
"""

from __future__ import annotations

import ctypes
import itertools
import math
import os
from pathlib import Path
import shutil
import subprocess
import sys
from dataclasses import dataclass
from typing import Any
import weakref

from PySide6.QtCore import (
    QAbstractNativeEventFilter, QBuffer, QByteArray, QCoreApplication,
    QIODevice, QObject, QPoint, QRect, QRectF, Qt, QThread, QTimer, Signal,
)
from PySide6.QtGui import QColor, QCursor, QFont, QImage, QPainter, QPen
from PySide6.QtWidgets import QApplication, QWidget


_IS_WINDOWS = sys.platform == "win32"
_WM_HOTKEY = 0x0312
_MOD_NOREPEAT = 0x4000
_MOD_CAPTURE = 0x0001 | 0x0002 | 0x0004 | _MOD_NOREPEAT
_VK_RETURN = 0x0D
_VK_ESCAPE = 0x1B

if _IS_WINDOWS:
    from ctypes import wintypes

    _user32 = ctypes.WinDLL("user32", use_last_error=True)
    _user32.RegisterHotKey.argtypes = (wintypes.HWND, ctypes.c_int, wintypes.UINT, wintypes.UINT)
    _user32.RegisterHotKey.restype = wintypes.BOOL
    _user32.UnregisterHotKey.argtypes = (wintypes.HWND, ctypes.c_int)
    _user32.UnregisterHotKey.restype = wintypes.BOOL
else:
    _user32 = None


def _require_gui_thread() -> QCoreApplication:
    app = QCoreApplication.instance()
    if app is None or QThread.currentThread() != app.thread():
        raise RuntimeError("화면 캡처와 단축키 설정은 앱의 GUI 스레드에서 실행해야 합니다.")
    return app


class _HotkeyFilter(QAbstractNativeEventFilter):
    def __init__(self, owner: "Hotkeys") -> None:
        super().__init__()
        self._owner = weakref.ref(owner)

    def nativeEventFilter(self, event_type: Any, message: Any) -> tuple[bool, int]:
        if not _IS_WINDOWS or bytes(event_type) not in (
            b"windows_generic_MSG", b"windows_dispatcher_MSG"
        ):
            return False, 0
        msg = wintypes.MSG.from_address(int(message))
        owner = self._owner()
        if owner is not None and msg.message == _WM_HOTKEY:
            return owner._handle_hotkey(int(msg.wParam)), 0
        return False, 0


class Hotkeys(QObject):
    """RegisterHotKey only: no hooks, accessibility access, or system changes.

    configure("R", False) installs Ctrl+Alt+Shift+R. Space and Enter also work.
    configure(key, True) opts into a confirmation step: the modified shortcut
    arms bare Enter and Esc for 10 seconds. Bare Enter fires once; Esc cancels.
    Both are released before a trigger is
    emitted, and on cancellation, timeout, reconfiguration, or close().

    Failed registration is transactional: newly registered keys are undone and
    the previous working configuration remains in place. Call disarm when the
    app cancels or completes a capture. close is connected to aboutToQuit.
    """

    triggered = Signal()
    armed_changed = Signal(bool)
    error = Signal(str)
    _sequence = itertools.count(0x5000)
    _allocated: set[int] = set()

    def __init__(self, parent: QObject | None = None) -> None:
        super().__init__(parent)
        app = _require_gui_thread()
        self._app = app
        self._bindings: dict[int, tuple[int, int]] = {}
        self._main_id: int | None = None
        self._enter_id: int | None = None
        self._escape_id: int | None = None
        self._key: str | None = None
        self._arm_preference = False
        self._armed = False
        self._closed = False
        self._timer = QTimer(self)
        self._timer.setSingleShot(True)
        self._timer.timeout.connect(self.disarm)
        self._filter = _HotkeyFilter(self)
        if _IS_WINDOWS:
            app.installNativeEventFilter(self._filter)
        app.aboutToQuit.connect(self.close)

    @property
    def armed(self) -> bool:
        return self._armed

    @property
    def key(self) -> str | None:
        return self._key

    @staticmethod
    def _normalize_key(key: str) -> tuple[str, int]:
        label = str(key).strip().lower().replace(" ", "")
        for prefix in ("ctrl+alt+shift+", "control+alt+shift+"):
            if label.startswith(prefix):
                label = label[len(prefix):]
        choices = {"r": ("R", 0x52), "space": ("Space", 0x20),
                   "enter": ("Enter", _VK_RETURN), "return": ("Enter", _VK_RETURN)}
        if label not in choices:
            raise ValueError("단축키는 Ctrl+Alt+Shift+R / Space / Enter 중에서 선택하세요.")
        return choices[label]

    def _register(self, modifiers: int, vk: int, label: str) -> int:
        for _ in range(0xB000):
            hotkey_id = 0x1000 + (next(self._sequence) % 0xB000)
            if hotkey_id not in self._allocated:
                break
        else:
            raise RuntimeError("사용 가능한 단축키 ID가 없습니다. 앱을 다시 시작하세요.")
        if not _user32.RegisterHotKey(None, hotkey_id, modifiers, vk):
            error = ctypes.get_last_error()
            raise RuntimeError(
                f"{label} 등록 실패 (Windows 오류 {error}). "
                "다른 앱이 이 키를 사용 중일 수 있습니다. 다른 단축키를 선택하거나 충돌하는 앱의 단축키를 해제하세요."
            )
        self._allocated.add(hotkey_id)
        self._bindings[hotkey_id] = (modifiers, vk)
        return hotkey_id

    def _unregister(self, hotkey_id: int | None) -> None:
        if hotkey_id is not None and hotkey_id in self._bindings:
            _user32.UnregisterHotKey(None, hotkey_id)
            self._bindings.pop(hotkey_id, None)
            self._allocated.discard(hotkey_id)

    def configure(self, key: str, armed: bool = False) -> None:
        _require_gui_thread()
        label, vk = self._normalize_key(key)
        if self._closed:
            raise RuntimeError("이미 종료된 단축키 관리자입니다.")
        if not _IS_WINDOWS:
            raise RuntimeError("전역 단축키는 Windows에서만 사용할 수 있습니다.")

        next_main = self._main_id
        if self._key != label:
            # Try the replacement before releasing the working registration.
            next_main = self._register(_MOD_CAPTURE, vk, f"Ctrl+Alt+Shift+{label}")
        if next_main != self._main_id:
            self._unregister(self._main_id)
        self._main_id, self._key = next_main, label
        self._arm_preference = bool(armed)
        self.disarm()

    def _arm(self) -> None:
        if self._armed:
            self._timer.start(10_000)
            return
        new_ids = []
        try:
            enter_id = self._register(_MOD_NOREPEAT, _VK_RETURN, "Enter")
            new_ids.append(enter_id)
            escape_id = self._register(_MOD_NOREPEAT, _VK_ESCAPE, "Esc")
            new_ids.append(escape_id)
        except Exception:
            for hotkey_id in reversed(new_ids):
                self._unregister(hotkey_id)
            raise
        self._enter_id, self._escape_id = enter_id, escape_id
        self._armed = True
        self._timer.start(10_000)
        self.armed_changed.emit(True)

    def _handle_hotkey(self, hotkey_id: int) -> bool:
        if self._closed or hotkey_id not in self._bindings:
            return False
        if hotkey_id == self._escape_id:
            self.disarm()
            return True
        if hotkey_id == self._main_id and self._arm_preference:
            try:
                self._arm()
            except RuntimeError as exc:
                self.error.emit(str(exc))
            return True
        if hotkey_id in (self._main_id, self._enter_id):
            self.disarm()
            self.triggered.emit()
            return True
        return False

    def disarm(self) -> None:
        _require_gui_thread()
        self._timer.stop()
        self._unregister(self._enter_id)
        self._unregister(self._escape_id)
        self._enter_id = self._escape_id = None
        if self._armed:
            self._armed = False
            self.armed_changed.emit(False)

    def close(self) -> None:
        _require_gui_thread()
        if self._closed:
            return
        self.disarm()
        for hotkey_id in list(self._bindings):
            self._unregister(hotkey_id)
        self._main_id = None
        self._closed = True
        if _IS_WINDOWS:
            self._app.removeNativeEventFilter(self._filter)


@dataclass
class _Snapshot:
    geometry: QRect
    image: QImage
    screen: Any = None


def _take_snapshots(region: QRect | None = None) -> list[_Snapshot]:
    _require_gui_thread()
    snapshots = []
    for screen in QApplication.screens():
        geometry = QRect(screen.geometry())
        if region is not None and not geometry.intersects(region):
            continue
        image = screen.grabWindow(0).toImage()
        if image.isNull():
            raise RuntimeError(
                f"'{screen.name()}' 화면을 캡처하지 못했습니다. "
                "보안 데스크톱이나 캡처가 제한된 화면인지 확인하세요."
            )
        # All subsequent source rectangles explicitly use raw image pixels.
        image.setDevicePixelRatio(1.0)
        snapshots.append(_Snapshot(geometry, image, screen))
    if not snapshots:
        raise RuntimeError("캡처할 화면을 찾지 못했습니다.")
    return snapshots


def _compose(snapshots: list[_Snapshot], selection: QRect) -> QImage:
    """Compose selected monitor pieces; suitable for synthetic unit tests."""
    selection = selection.normalized()
    pieces = [(shot, selection.intersected(shot.geometry)) for shot in snapshots]
    pieces = [(shot, rect) for shot, rect in pieces if not rect.isEmpty()]
    if not pieces:
        return QImage()
    bounds = QRect(pieces[0][1])
    for _, rect in pieces[1:]:
        bounds = bounds.united(rect)
    density = max(
        max(shot.image.width() / shot.geometry.width(), shot.image.height() / shot.geometry.height())
        for shot, _ in pieces
    )
    width, height = math.ceil(bounds.width() * density), math.ceil(bounds.height() * density)
    if width > 32768 or height > 32768 or width * height > 80_000_000:
        raise RuntimeError("선택 영역이 너무 큽니다. 더 작은 영역을 선택하세요.")
    result = QImage(width, height, QImage.Format.Format_RGB32)
    if result.isNull():
        raise RuntimeError("캡처 이미지에 필요한 메모리가 부족합니다.")
    result.fill(Qt.GlobalColor.white)
    painter = QPainter(result)
    painter.setRenderHint(QPainter.RenderHint.SmoothPixmapTransform)
    for shot, rect in pieces:
        sx = shot.image.width() / shot.geometry.width()
        sy = shot.image.height() / shot.geometry.height()
        source = QRectF(
            (rect.x() - shot.geometry.x()) * sx,
            (rect.y() - shot.geometry.y()) * sy,
            rect.width() * sx, rect.height() * sy,
        )
        target = QRectF(
            (rect.x() - bounds.x()) * density,
            (rect.y() - bounds.y()) * density,
            rect.width() * density, rect.height() * density,
        )
        painter.drawImage(target, shot.image, source)
    painter.end()
    return result


def capture_cursor(width: int, height: int) -> QImage:
    """Capture a rectangle centered on the pointer (size in Qt logical pixels).

    The rectangle is clipped to the monitor under the pointer, including
    negative-coordinate monitors. Use CaptureOverlay for multi-monitor regions.
    """
    _require_gui_thread()
    width, height = int(width), int(height)
    if not (1 <= width <= 16384 and 1 <= height <= 16384):
        raise ValueError("캡처 크기는 가로·세로 각각 1~16384 범위여야 합니다.")
    cursor = QCursor.pos()
    screen = QApplication.screenAt(cursor)
    if screen is None:
        raise RuntimeError("마우스 포인터가 있는 화면을 찾지 못했습니다.")
    rect = QRect(cursor.x() - width // 2, cursor.y() - height // 2, width, height)
    rect = rect.intersected(screen.geometry())
    return _compose(_take_snapshots(rect), rect)


class _OverlayPanel(QWidget):
    def __init__(self, controller: "CaptureOverlay", shot: _Snapshot) -> None:
        super().__init__(None, Qt.WindowType.FramelessWindowHint | Qt.WindowType.WindowStaysOnTopHint | Qt.WindowType.Tool)
        self._controller = controller
        self._shot = shot
        self.setAttribute(Qt.WidgetAttribute.WA_DeleteOnClose, False)
        self.setMouseTracking(True)
        self.setCursor(Qt.CursorShape.CrossCursor)
        self.setFocusPolicy(Qt.FocusPolicy.StrongFocus)
        self.setWindowTitle("Q · 영역 선택 · Esc 취소")
        self.setGeometry(shot.geometry)
        # Selecting the target QScreen before showing avoids inheriting the
        # primary monitor's density for a secondary monitor's overlay window.
        self.winId()
        if self.windowHandle() is not None and shot.screen is not None:
            self.windowHandle().setScreen(shot.screen)
        self.setGeometry(shot.geometry)

    def paintEvent(self, event: Any) -> None:
        painter = QPainter(self)
        painter.drawImage(QRectF(self.rect()), self._shot.image)
        painter.fillRect(self.rect(), QColor(10, 14, 22, 115))
        selection = self._controller.selection
        if selection is not None:
            local = selection.translated(-self._shot.geometry.x(), -self._shot.geometry.y())
            painter.save()
            painter.setClipRect(local)
            painter.drawImage(QRectF(self.rect()), self._shot.image)
            painter.restore()
            painter.setPen(QPen(QColor("#68e6d1"), 2))
            painter.drawRect(local.adjusted(0, 0, -1, -1))
        painter.setPen(Qt.GlobalColor.white)
        painter.setFont(QFont("Segoe UI", 11))
        painter.fillRect(QRect(20, 18, min(560, self.width() - 40), 42), QColor(10, 14, 22, 215))
        painter.drawText(QRect(32, 18, self.width() - 64, 42), Qt.AlignmentFlag.AlignVCenter,
                         "Q  드래그해서 영역 선택 · Esc / 마우스 오른쪽 버튼으로 취소")

    def mousePressEvent(self, event: Any) -> None:
        if event.button() == Qt.MouseButton.RightButton:
            self._controller.cancel()
        elif event.button() == Qt.MouseButton.LeftButton:
            self._controller._start = event.globalPosition().toPoint()
            self._controller._end = self._controller._start
            self._controller._redraw()

    def mouseMoveEvent(self, event: Any) -> None:
        if self._controller._start is not None:
            self._controller._end = event.globalPosition().toPoint()
            self._controller._redraw()

    def mouseReleaseEvent(self, event: Any) -> None:
        if event.button() == Qt.MouseButton.LeftButton and self._controller._start is not None:
            self._controller._end = event.globalPosition().toPoint()
            self._controller._complete_selection()

    def keyPressEvent(self, event: Any) -> None:
        if event.key() == Qt.Key.Key_Escape:
            self._controller.cancel()
        else:
            super().keyPressEvent(event)

    def closeEvent(self, event: Any) -> None:
        if not self._controller._done:
            self._controller.cancel()
        event.accept()


class CaptureOverlay(_OverlayPanel):
    """One overlay per monitor, coordinated as a single capture operation.

    Connect finished before show(). It emits exactly once with a QImage, or None
    on cancel/empty selection. The caller owns the widget and may deleteLater()
    after finished. error contains an actionable explanation on capture failure.
    All screen snapshots are released at completion.
    """

    finished = Signal(object)

    def __init__(self, parent: QWidget | None = None) -> None:
        # All monitors are frozen before even the first overlay is displayed.
        self._snapshots = _take_snapshots()
        self._start: QPoint | None = None
        self._end: QPoint | None = None
        self._done = False
        self.error = ""
        super().__init__(self, self._snapshots[0])
        self._panels: list[_OverlayPanel] = [self]
        self._panels.extend(_OverlayPanel(self, shot) for shot in self._snapshots[1:])
        # Top-level Tool windows must not be constrained to a parent's screen.
        # Retain an owner reference without changing their native parenting.
        self._owner = parent

    @property
    def selection(self) -> QRect | None:
        if self._start is None or self._end is None:
            return None
        return QRect(self._start, self._end).normalized()

    def show(self) -> None:
        if self._done:
            return
        for panel in self._panels:
            QWidget.show(panel)
            panel.raise_()
        active = next((panel for panel in self._panels if panel._shot.geometry.contains(QCursor.pos())), self)
        active.activateWindow()
        active.setFocus(Qt.FocusReason.ActiveWindowFocusReason)

    def _redraw(self) -> None:
        for panel in self._panels:
            panel.update()

    def _complete_selection(self) -> None:
        selection = self.selection
        if selection is None or selection.width() < 3 or selection.height() < 3:
            self.cancel()
            return
        try:
            image = _compose(self._snapshots, selection)
            self._finish(None if image.isNull() else image)
        except Exception as exc:
            self.error = str(exc)
            self._finish(None)

    def cancel(self) -> None:
        self._finish(None)

    def _finish(self, image: QImage | None) -> None:
        if self._done:
            return
        self._done = True
        for panel in self._panels:
            panel.hide()
            panel._shot.image = QImage()
            if panel is not self:
                panel.deleteLater()
        self._panels = [self]
        self._snapshots.clear()
        self.finished.emit(image)


def _find_tesseract() -> str:
    configured = os.environ.get("TESSERACT_CMD", "").strip().strip('"')
    if configured:
        found = shutil.which(configured)
        if found:
            return found
        raise RuntimeError("TESSERACT_CMD에 지정된 Tesseract 실행 파일을 찾지 못했습니다. 경로를 확인하세요.")
    found = shutil.which("tesseract")
    if found:
        return found
    if _IS_WINDOWS:
        for root in (os.environ.get("LOCALAPPDATA"), os.environ.get("ProgramFiles"), os.environ.get("ProgramFiles(x86)")):
            if not root:
                continue
            for suffix in ("Tesseract-OCR/tesseract.exe", "Programs/Tesseract-OCR/tesseract.exe"):
                candidate = Path(root) / suffix
                if candidate.is_file():
                    return str(candidate)
    raise RuntimeError(
        "오프라인 OCR용 Tesseract가 설치되어 있지 않거나 경로를 찾지 못했습니다. "
        "README의 OCR 설치 안내에 따라 Tesseract와 한국어(kor)·영어(eng) 데이터를 설치한 뒤 앱을 다시 시작하세요. "
        "또는 TESSERACT_CMD 환경 변수에 tesseract.exe의 전체 경로를 지정하세요. 텍스트 직접 붙여넣기는 계속 사용할 수 있습니다."
    )


def ocr_image(image: QImage) -> str:
    """Offline Tesseract, PNG stdin → text stdout. Run this in a worker thread.

    OCR_LANG defaults to kor+eng; users working exclusively in English can set
    OCR_LANG=eng. Missing language packs produce a clear installation message.
    No pytesseract temporary-file path is used and no network call is made.
    """
    if image.isNull():
        raise ValueError("OCR에 사용할 이미지가 비어 있습니다.")
    executable = _find_tesseract()
    language = os.environ.get("OCR_LANG", "kor+eng").strip() or "kor+eng"
    if any(not (part and part.replace("_", "").isalnum()) for part in language.split("+")):
        raise ValueError("OCR_LANG은 kor+eng 또는 eng처럼 언어 이름으로 지정하세요.")
    data = QByteArray()
    buffer = QBuffer(data)
    buffer.open(QIODevice.OpenModeFlag.WriteOnly)
    if not image.save(buffer, "PNG"):
        buffer.close()
        raise RuntimeError("OCR 입력 이미지를 메모리에서 변환하지 못했습니다.")
    buffer.close()
    flags = subprocess.CREATE_NO_WINDOW if _IS_WINDOWS else 0
    try:
        result = subprocess.run(
            [executable, "stdin", "stdout", "-l", language, "--psm", "6"],
            input=bytes(data), stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            timeout=60, check=False, creationflags=flags,
        )
    except subprocess.TimeoutExpired as exc:
        raise RuntimeError("OCR이 60초 안에 완료되지 않았습니다. 더 작은 영역을 선택해 다시 시도하세요.") from exc
    except OSError as exc:
        raise RuntimeError("Tesseract를 실행하지 못했습니다. 설치 경로와 실행 파일을 확인하세요.") from exc
    error = result.stderr.decode("utf-8", errors="replace")
    # Tesseract may exit successfully after falling back to only one language.
    # Surface missing Korean data instead of silently losing Korean text.
    if "Failed loading language" in error or "Error opening data file" in error:
        raise RuntimeError(
            f"OCR 언어 데이터({language})가 부족합니다. Tesseract의 tessdata 폴더에 해당 .traineddata 파일을 설치하세요. "
            "영어만 인식하려면 OCR_LANG=eng로 설정할 수 있습니다."
        )
    if result.returncode:
        raise RuntimeError(f"Tesseract OCR 실패 (종료 코드 {result.returncode}). 설치와 언어 데이터를 확인하세요.")
    text = result.stdout.decode("utf-8", errors="replace").strip()
    if not text:
        raise RuntimeError("선택한 영역에서 텍스트를 읽지 못했습니다. 글자가 더 크게 보이도록 확대하거나 직접 붙여넣으세요.")
    return text
