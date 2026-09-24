from __future__ import annotations

from functools import lru_cache
import math
from pathlib import Path

import cv2
import numpy as np
from PIL import Image, ImageDraw, ImageFont

# Type alias for a 4-point polygon [[x1,y1],[x2,y1],[x2,y2],[x1,y2]]
Polygon = list[list[float]]

_MAX_LINES = 4
_LINE_SPACING = 1.3  # multiplier applied to line height for vertical gap
_MIN_FONT_SIZE = 8
_MAX_FONT_SIZE = 256
_BLUR_INTENSITY_MULTIPLIER = 1.25
_TEXT_FIT_MARGIN = 0.8


# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------

def _bounding_rect(polygon: Polygon) -> tuple[int, int, int, int]:
    """Return axis-aligned (x, y, w, h) bounding rectangle for a polygon."""
    pts = np.array(polygon, dtype=np.float32)
    x, y, w, h = cv2.boundingRect(pts)
    return int(x), int(y), int(w), int(h)


def _clamp(value: int, low: int, high: int) -> int:
    return max(low, min(high, value))


def _wrap_into_n_lines(words: list[str], n: int) -> list[str]:
    """Split *words* as evenly as possible across *n* lines."""
    if n <= 1 or len(words) <= 1:
        return [" ".join(words)]
    per_line = math.ceil(len(words) / n)
    return [
        " ".join(words[i : i + per_line])
        for i in range(0, len(words), per_line)
    ]


def _bgr_to_rgb(color: tuple[int, int, int]) -> tuple[int, int, int]:
    return (color[2], color[1], color[0])


# Arial/DejaVu only cover Latin-ish scripts, so non-Latin translations need a
# font that actually has glyphs for them, or PIL silently draws tofu boxes.
_SCRIPT_FONT_CANDIDATES: dict[str, list[str]] = {
    "han": ["msyh.ttc", "C:/Windows/Fonts/msyh.ttc", "simsun.ttc", "C:/Windows/Fonts/simsun.ttc"],
    "kana": ["YuGothR.ttc", "C:/Windows/Fonts/YuGothR.ttc", "msgothic.ttc", "C:/Windows/Fonts/msgothic.ttc"],
    "hangul": ["malgun.ttf", "C:/Windows/Fonts/malgun.ttf"],
    "arabic": ["tahoma.ttf", "C:/Windows/Fonts/tahoma.ttf"],
    "devanagari": ["Nirmala.ttc", "C:/Windows/Fonts/Nirmala.ttc"],
}

_DEFAULT_FONT_CANDIDATES = [
    "arial.ttf",
    "Arial.ttf",
    "C:/Windows/Fonts/arial.ttf",
    "DejaVuSans.ttf",
]


def _detect_script(text: str) -> str:
    """Return a key into _SCRIPT_FONT_CANDIDATES for the first non-Latin script found in *text*."""
    for ch in text:
        code = ord(ch)
        if 0x4E00 <= code <= 0x9FFF or 0x3400 <= code <= 0x4DBF:  # CJK Unified Ideographs
            return "han"
        if 0x3040 <= code <= 0x30FF:  # Hiragana / Katakana
            return "kana"
        if 0xAC00 <= code <= 0xD7A3:  # Hangul syllables
            return "hangul"
        if 0x0600 <= code <= 0x06FF or 0x0750 <= code <= 0x077F:  # Arabic
            return "arabic"
        if 0x0900 <= code <= 0x097F:  # Devanagari (Hindi)
            return "devanagari"
    return "latin"


@lru_cache(maxsize=256)
def _load_font(size: int, script: str) -> ImageFont.FreeTypeFont | ImageFont.ImageFont:
    """Load a font covering *script*, falling back to Arial/DejaVu, then PIL's built-in default."""
    font_candidates = _SCRIPT_FONT_CANDIDATES.get(script, []) + _DEFAULT_FONT_CANDIDATES

    for font_path in font_candidates:
        try:
            return ImageFont.truetype(font_path, size=size)
        except OSError:
            continue

    return ImageFont.load_default()


def _measure_text_block(
    draw: ImageDraw.ImageDraw,
    lines: list[str],
    font: ImageFont.FreeTypeFont | ImageFont.ImageFont,
    line_spacing_px: int,
) -> tuple[int, int, list[tuple[int, int, int, int]]]:
    """Return (max_w, total_h, line_boxes) for a text block."""
    line_boxes: list[tuple[int, int, int, int]] = []

    for line in lines:
        line_boxes.append(draw.textbbox((0, 0), line, font=font))

    line_widths = [max(1, right - left) for left, top, right, bottom in line_boxes]
    line_heights = [max(1, bottom - top) for left, top, right, bottom in line_boxes]
    max_w = max(line_widths) if line_widths else 0
    total_h = sum(line_heights) + max(0, len(lines) - 1) * line_spacing_px
    return max_w, total_h, line_boxes


def _fit_text_to_box(
    text: str,
    box_w: int,
    box_h: int,
    script: str,
    max_lines: int = _MAX_LINES,
) -> tuple[list[str], int]:
    """
    Find the line-wrapping and font scale that best fill (box_w, box_h)
    with *text*, trying an increasing number of lines and picking whichever
    combination yields the largest font size (i.e. best fill).
    """
    words = text.split()
    if not words:
        return [], _MIN_FONT_SIZE

    avail_w = max(int(box_w * _TEXT_FIT_MARGIN), 1)
    avail_h = max(int(box_h * _TEXT_FIT_MARGIN), 1)
    draw = ImageDraw.Draw(Image.new("RGB", (1, 1)))

    best_size = _MIN_FONT_SIZE
    best_lines = [text]

    for n in range(1, min(max_lines, len(words)) + 1):
        lines = _wrap_into_n_lines(words, n)
        lo = _MIN_FONT_SIZE
        hi = _MAX_FONT_SIZE
        local_best = _MIN_FONT_SIZE

        while lo <= hi:
            mid = (lo + hi) // 2
            font = _load_font(mid, script)
            line_spacing_px = max(1, int(mid * (_LINE_SPACING - 1)))
            max_w, total_h, _ = _measure_text_block(draw, lines, font, line_spacing_px)

            if max_w <= avail_w and total_h <= avail_h:
                local_best = mid
                lo = mid + 1
            else:
                hi = mid - 1

        if local_best > best_size:
            best_size = local_best
            best_lines = lines

    return best_lines, best_size


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

def blur_region(
    image: np.ndarray,
    polygon: Polygon,
    blur_kernel: int = 45,
) -> np.ndarray:
    """
    Gaussian-blur the rectangular region that encloses *polygon* in *image*.
    The image is modified in-place and returned.
    """
    ih, iw = image.shape[:2]
    x, y, w, h = _bounding_rect(polygon)

    x1 = _clamp(x, 0, iw)
    y1 = _clamp(y, 0, ih)
    x2 = _clamp(x + w, 0, iw)
    y2 = _clamp(y + h, 0, ih)

    if x2 <= x1 or y2 <= y1:
        return image  # degenerate box – skip

    # Kernel size must be positive and odd; apply a slight multiplier to obscure text better.
    k = max(5, int(round((blur_kernel | 1) * _BLUR_INTENSITY_MULTIPLIER)) | 1)
    roi = image[y1:y2, x1:x2]
    gray_roi = cv2.cvtColor(roi, cv2.COLOR_BGR2GRAY)
    blurred_gray = cv2.GaussianBlur(gray_roi, (k, k), 0)
    image[y1:y2, x1:x2] = cv2.cvtColor(blurred_gray, cv2.COLOR_GRAY2BGR)
    return image


def overlay_text(
    image: np.ndarray,
    polygon: Polygon,
    text: str,
    text_color: tuple[int, int, int] = (0, 0, 0),
    bg_color: tuple[int, int, int] | None = (255, 255, 200),
    padding: int = 8,
) -> np.ndarray:
    """
    Render *text* inside the bounding box of *polygon*, wrapping onto
    multiple lines and scaling the font so the text fills as much of the
    box (width and height) as possible.
    Optionally draws a semi-transparent background rectangle first.
    The image is modified in-place and returned.
    """
    ih, iw = image.shape[:2]
    x, y, w, h = _bounding_rect(polygon)

    x1 = _clamp(x, 0, iw)
    y1 = _clamp(y, 0, ih)
    x2 = _clamp(x + w, 0, iw)
    y2 = _clamp(y + h, 0, ih)

    if x2 <= x1 or y2 <= y1 or not text.strip():
        return image

    box_w = x2 - x1
    box_h = y2 - y1
    avail_w = max(box_w - 2 * padding, 1)
    avail_h = max(box_h - 2 * padding, 1)

    script = _detect_script(text)
    lines, font_size = _fit_text_to_box(text, avail_w, avail_h, script)
    if not lines:
        return image

    font = _load_font(font_size, script)
    text_rgb = _bgr_to_rgb(text_color)

    # Draw with Pillow so the font matches the text's script (Arial/DejaVu can't render CJK/Arabic/Devanagari).
    pil_image = Image.fromarray(cv2.cvtColor(image, cv2.COLOR_BGR2RGB))
    draw = ImageDraw.Draw(pil_image)
    line_spacing_px = max(1, int(font_size * (_LINE_SPACING - 1)))
    _, total_text_h, line_boxes = _measure_text_block(draw, lines, font, line_spacing_px)

    if bg_color is not None:
        bg_rgb = _bgr_to_rgb(bg_color)
        overlay = Image.new("RGBA", pil_image.size, (0, 0, 0, 0))
        overlay_draw = ImageDraw.Draw(overlay)
        overlay_draw.rectangle((x1, y1, x2, y2), fill=(bg_rgb[0], bg_rgb[1], bg_rgb[2], 153))
        pil_image = Image.alpha_composite(pil_image.convert("RGBA"), overlay).convert("RGB")
        draw = ImageDraw.Draw(pil_image)

    # Vertically center the whole text block inside the box.
    content_x1 = x1 + padding
    content_y1 = y1 + padding
    content_w = max(box_w - 2 * padding, 1)
    content_h = max(box_h - 2 * padding, 1)
    cursor_y = content_y1 + max((content_h - total_text_h) // 2, 0)

    for line, (left, top, right, bottom) in zip(lines, line_boxes):
        line_w = max(1, right - left)
        line_h = max(1, bottom - top)
        text_x = content_x1 + max((content_w - line_w) // 2, 0) - left
        text_y = cursor_y - top
        draw.text((text_x, text_y), line, font=font, fill=text_rgb)
        cursor_y += line_h + line_spacing_px

    image[:, :] = cv2.cvtColor(np.array(pil_image), cv2.COLOR_RGB2BGR)

    return image


def remove_text_from_regions(
    image: np.ndarray,
    polygons: list[Polygon],
    blur_kernel: int = 45,
) -> np.ndarray:
    """Blur every detected text region. Independent of translation, so callers
    can run this alongside a translation call instead of waiting on it first."""
    for polygon in polygons:
        blur_region(image, polygon, blur_kernel=blur_kernel)
    return image


def process_image_array(
    image: np.ndarray,
    polygons: list[Polygon],
    translated_texts: list[str],
    blur_kernel: int = 45,
) -> np.ndarray:
    """
    Blur each detected text region and overlay the corresponding translated
    text directly on an in-memory BGR image (e.g. a captured camera frame).
    The image is modified in-place and returned.
    """
    remove_text_from_regions(image, polygons, blur_kernel=blur_kernel)
    for polygon, translated in zip(polygons, translated_texts):
        overlay_text(image, polygon, translated)
    return image


def process_image(
    image_path: Path,
    polygons: list[Polygon],
    translated_texts: list[str],
    output_path: Path,
    blur_kernel: int = 45,
) -> np.ndarray:
    """
    Full pipeline for a single image:
      1. Blur each detected text region.
      2. Overlay the corresponding translated text.
      3. Save the result to *output_path*.

    Returns the processed image as a NumPy array (BGR).
    """
    image = cv2.imread(str(image_path))
    if image is None:
        raise FileNotFoundError(f"Cannot load image: {image_path}")

    process_image_array(image, polygons, translated_texts, blur_kernel=blur_kernel)

    output_path.parent.mkdir(parents=True, exist_ok=True)
    cv2.imwrite(str(output_path), image)

    return image
