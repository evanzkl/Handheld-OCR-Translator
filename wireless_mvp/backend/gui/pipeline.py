from __future__ import annotations

from collections.abc import Iterable
from concurrent.futures import ThreadPoolExecutor

import numpy as np

from ..OCR.google_vision import build_vision_engine, run_google_vision_ocr_array
from ..translation.translator import translate_texts
from ..blur_and_overlay.processor import overlay_text, remove_text_from_regions


def _region_bounds(region) -> tuple[float, float, float, float]:
    points = np.asarray(region.polygon, dtype=float)
    return (
        float(points[:, 0].min()),
        float(points[:, 1].min()),
        float(points[:, 0].max()),
        float(points[:, 1].max()),
    )


def _merge_phrase_regions(regions: Iterable) -> list:
    """Combine nearby OCR word boxes into readable, same-line phrases."""
    ordered = sorted(regions, key=lambda region: (_region_bounds(region)[1], _region_bounds(region)[0]))
    phrases: list[dict] = []

    for region in ordered:
        x0, y0, x1, y1 = _region_bounds(region)
        height = max(1.0, y1 - y0)
        matching_phrase = None
        smallest_gap = float("inf")

        for phrase in phrases:
            px0, py0, px1, py1 = phrase["bounds"]
            phrase_height = max(1.0, py1 - py0)
            vertical_overlap = max(0.0, min(y1, py1) - max(y0, py0))
            overlap_ratio = vertical_overlap / min(height, phrase_height)
            horizontal_gap = max(0.0, max(px0, x0) - min(px1, x1))
            same_line = (
                overlap_ratio >= 0.25
                or abs((y0 + y1) / 2 - (py0 + py1) / 2) <= 0.55 * max(height, phrase_height)
            )
            close_enough = horizontal_gap <= max(40.0, 3.0 * max(height, phrase_height))

            if same_line and close_enough and horizontal_gap < smallest_gap:
                matching_phrase = phrase
                smallest_gap = horizontal_gap

        if matching_phrase is None:
            phrases.append({"regions": [region], "bounds": (x0, y0, x1, y1)})
            continue

        matching_phrase["regions"].append(region)
        matching_phrase["bounds"] = (
            min(matching_phrase["bounds"][0], x0),
            min(matching_phrase["bounds"][1], y0),
            max(matching_phrase["bounds"][2], x1),
            max(matching_phrase["bounds"][3], y1),
        )

    merged = []
    for phrase in phrases:
        phrase_regions = sorted(phrase["regions"], key=lambda region: _region_bounds(region)[0])
        x0, y0, x1, y1 = phrase["bounds"]
        merged.append(
            type(phrase_regions[0])(
                polygon=[[x0, y0], [x1, y0], [x1, y1], [x0, y1]],
                text=" ".join(region.text for region in phrase_regions),
                confidence=sum(region.confidence for region in phrase_regions) / len(phrase_regions),
            )
        )

    return sorted(merged, key=lambda region: (_region_bounds(region)[1], _region_bounds(region)[0]))


class TranslationPipeline:
    """Wraps the OCR -> translate -> blur/overlay pipeline for in-memory frames."""

    def __init__(self) -> None:
        self._engine = None

    def _get_engine(self):
        if self._engine is None:
            self._engine = build_vision_engine()
        return self._engine

    def process(
        self,
        frame_bgr: np.ndarray,
        ocr_lang: str,
        target_lang: str,
    ) -> tuple[np.ndarray, float]:
        """
        Run OCR on *frame_bgr*, translate the detected text, and render the
        blurred/translated result. Returns (result_image_bgr, avg_confidence_pct).
        """
        engine = self._get_engine()
        regions = run_google_vision_ocr_array(engine, frame_bgr, language=ocr_lang)

        if not regions:
            return frame_bgr.copy(), 0.0

        phrase_regions = _merge_phrase_regions(regions)
        polygons = [region.polygon for region in phrase_regions]
        result_image = frame_bgr.copy()

        # Translation (network call) and text removal (local blur) don't depend on
        # each other, so run them concurrently instead of one after the other.
        with ThreadPoolExecutor(max_workers=1) as executor:
            translate_future = executor.submit(
                translate_texts,
                [region.text for region in phrase_regions],
                target_lang=target_lang,
                source_lang=ocr_lang if ocr_lang != target_lang else None,
            )
            remove_text_from_regions(result_image, polygons)
            translated_texts = translate_future.result()

        for polygon, translated in zip(polygons, translated_texts):
            overlay_text(result_image, polygon, translated)

        avg_confidence = sum(region.confidence for region in regions) / len(regions) * 100
        return result_image, avg_confidence
