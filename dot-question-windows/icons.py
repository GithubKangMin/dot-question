"""Original app-only tray artwork; no Windows Wi-Fi or battery state is read.

The persistent Q badge identifies these as this application's answer indicators.
The numeric answer stays visible in number, Wi-Fi, and battery styles. Character
art is drawn locally with QPainter, never downloaded or installed into Windows.
"""

from __future__ import annotations

from PySide6.QtCore import QPointF, QRectF, Qt
from PySide6.QtGui import QColor, QFont, QIcon, QPainter, QPainterPath, QPen, QPixmap, QPolygonF


def _polygon(painter: QPainter, points: list[tuple[float, float]], color: str) -> None:
    painter.setPen(Qt.PenStyle.NoPen)
    painter.setBrush(QColor(color))
    painter.drawPolygon(QPolygonF([QPointF(x, y) for x, y in points]))


def _cat(painter: QPainter, frame: int) -> None:
    ink, pink = QColor("#e6ebf4"), QColor("#ed91b5")
    tail = QPainterPath(QPointF(21, 50))
    tail.cubicTo(31, 55, 32 + (frame % 3), 43, 28 + (frame % 3), 38)
    painter.setPen(QPen(ink, 3.3, Qt.PenStyle.SolidLine, Qt.PenCapStyle.RoundCap))
    painter.setBrush(Qt.BrushStyle.NoBrush)
    painter.drawPath(tail)
    painter.setPen(Qt.PenStyle.NoPen)
    painter.setBrush(ink)
    painter.drawEllipse(QRectF(5, 39, 20, 18))
    _polygon(painter, [(4, 41), (4, 26), (12, 31), (19, 31), (26, 26), (26, 42)], ink.name())
    painter.setBrush(ink)
    painter.drawEllipse(QRectF(4, 31, 22, 17))
    _polygon(painter, [(6, 30), (7, 36), (11, 33)], pink.name())
    _polygon(painter, [(23, 30), (23, 36), (19, 33)], pink.name())
    painter.setBrush(QColor("#172337"))
    if frame % 8 == 7:
        painter.drawRoundedRect(QRectF(8, 38, 4, 1.4), 0.7, 0.7)
        painter.drawRoundedRect(QRectF(19, 38, 4, 1.4), 0.7, 0.7)
    else:
        painter.drawEllipse(QRectF(9, 36, 3, 4))
        painter.drawEllipse(QRectF(19, 36, 3, 4))
    _polygon(painter, [(13, 41), (18, 41), (15.5, 44)], "#ed91b5")


def _electric_character(painter: QPainter, frame: int) -> None:
    # Original geometric, electric-mouse fan-art; no official image assets.
    shift = 1.5 if frame % 2 else 0
    yellow = "#ffcf3b"
    _polygon(painter, [(5, 38), (2, 21 + shift), (9, 24), (14, 38)], yellow)
    _polygon(painter, [(18, 38), (22, 20 - shift), (28, 23), (25, 41)], yellow)
    _polygon(painter, [(2, 21 + shift), (9, 24), (9, 30), (4, 28)], "#1a2030")
    _polygon(painter, [(22, 20 - shift), (28, 23), (26, 30), (21, 28)], "#1a2030")
    painter.setBrush(QColor(yellow))
    painter.setPen(Qt.PenStyle.NoPen)
    painter.drawEllipse(QRectF(4, 33, 23, 23))
    painter.setBrush(QColor("#1a2030"))
    painter.drawEllipse(QRectF(9, 39, 3, 4))
    painter.drawEllipse(QRectF(20, 39, 3, 4))
    painter.setBrush(QColor("#ef5a5a"))
    painter.drawEllipse(QRectF(5, 44, 6, 5))
    painter.drawEllipse(QRectF(21, 44, 6, 5))
    _polygon(painter, [(14, 45), (18, 45), (16, 48)], "#1a2030")
    if frame % 2:
        _polygon(painter, [(29, 36), (33, 30), (32, 37), (35, 37), (29, 45), (31, 38)], yellow)


def answer_icon(order: int | None, style: str, character: str = "off", frame: int = 0, *, error: bool = False) -> QIcon:
    """Draw a high-DPI tray icon. Orders 0–10 map to numbers or 10–100%.

    Wi-Fi uses 1–5 bars, with a number fallback for answers 6–10.
    None and invalid orders display ?. Supported styles: number, wifi, battery.
    Characters: off, cat, pikachu. frame animates a tail/blink/electric spark;
    callers own their animation timer and can stop it whenever no work is active.
    """
    if isinstance(order, bool) or not isinstance(order, int) or not 0 <= order <= 10:
        order = None
    style = str(style).lower()
    if style not in ("number", "wifi", "battery"):
        style = "number"
    if style == "wifi" and order is not None and order > 5:
        style = "number"
    character = str(character).lower()
    if character not in ("cat", "pikachu"):
        character = "off"
    if error: order, style, character = None, "number", "off"
    frame = int(frame)
    icon = QIcon()
    for size in (16, 20, 24, 32, 40, 48, 64, 128):
        pixmap = QPixmap(size, size)
        pixmap.fill(Qt.GlobalColor.transparent)
        painter = QPainter(pixmap)
        painter.setRenderHint(QPainter.RenderHint.Antialiasing)
        painter.setRenderHint(QPainter.RenderHint.TextAntialiasing)
        painter.scale(size / 64.0, size / 64.0)
        painter.setPen(Qt.PenStyle.NoPen)
        painter.setBrush(QColor("#172337"))
        painter.drawRoundedRect(QRectF(1, 1, 62, 62), 12, 12)

        # Q identity remains present in every style, including character variants.
        painter.setBrush(QColor("#75eed9"))
        painter.drawEllipse(QRectF(4, 4, 20, 20))
        painter.setPen(QColor("#172337"))
        font = QFont("Segoe UI")
        font.setPixelSize(16)
        font.setWeight(QFont.Weight.Black)
        painter.setFont(font)
        painter.drawText(QRectF(4, 3, 20, 20), Qt.AlignmentFlag.AlignCenter, "Q")

        has_character = character != "off"
        if character == "cat":
            _cat(painter, frame)
        elif character == "pikachu":
            _electric_character(painter, frame)

        # Keep the answer explicit, even when bars / percentage encode it too.
        left = 31 if has_character else 19
        number_rect = QRectF(left, 10 if style == "number" else 2, 61 - left, 50 if style == "number" else 34)
        font.setPixelSize(42 if style == "number" and not has_character else 36 if style == "number" else 28)
        if order == 10:
            font.setPixelSize(30 if not has_character else 24)
        painter.setFont(font)
        painter.setPen(QColor("#ffffff"))
        painter.drawText(number_rect, Qt.AlignmentFlag.AlignCenter, "!" if error else str(order) if order is not None else "?")

        if style == "wifi":
            bar_left = 32 if has_character else 15
            step = (59 - bar_left) / 5
            for index in range(5):
                height = 5 + index * 3.5
                painter.setPen(Qt.PenStyle.NoPen)
                painter.setBrush(QColor("#75eed9" if order is not None and index < order else "#425069"))
                painter.drawRoundedRect(QRectF(bar_left + index * step, 56 - height, max(2.5, step - 2), height), 1, 1)
        elif style == "battery":
            left = 32 if has_character else 14
            width = 57 - left
            painter.setPen(QPen(QColor("#dae7f6"), 2))
            painter.setBrush(Qt.BrushStyle.NoBrush)
            painter.drawRoundedRect(QRectF(left, 39, width, 17), 3, 3)
            painter.setPen(Qt.PenStyle.NoPen)
            painter.setBrush(QColor("#dae7f6"))
            painter.drawRoundedRect(QRectF(58, 44, 3, 7), 1, 1)
            if order is not None:
                painter.setBrush(QColor("#75eed9"))
                painter.drawRoundedRect(QRectF(left + 3, 42, (width - 6) * order / 10, 11), 1, 1)

        painter.end()
        icon.addPixmap(pixmap)
    return icon
