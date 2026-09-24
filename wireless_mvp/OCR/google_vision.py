from __future__ import annotations

import base64
from functools import lru_cache
import json
from pathlib import Path
import shutil
import subprocess
from typing import Any, NamedTuple
from urllib import error as urllib_error
from urllib import request as urllib_request

import cv2
import numpy as np

try:
    from google.cloud import vision
except ImportError as exc:
    raise ImportError("google-cloud-vision is required. Install it with: pip install google-cloud-vision") from exc

try:
    from google.api_core.client_options import ClientOptions
except ImportError:
    ClientOptions = None

from translation.translator import DEFAULT_PROJECT_ID


class TextRegion(NamedTuple):
    polygon: list[list[float]]
    text: str
    confidence: float


@lru_cache(maxsize=1)
def build_vision_engine() -> Any:
    """Create and cache a Vision client using ADC and the translation project."""
    if ClientOptions is None:
        try:
            return vision.ImageAnnotatorClient()
        except Exception:
            return None
    try:
        return vision.ImageAnnotatorClient(
            client_options=ClientOptions(quota_project_id=DEFAULT_PROJECT_ID)
        )
    except Exception:
        return None


def warm_up_engine() -> bool:
    """Build the cached Vision client now so the channel/auth cost isn't paid by the first request."""
    return build_vision_engine() is not None


def _polygon(vertices: Any) -> list[list[float]]:
    return [[float(vertex.x), float(vertex.y)] for vertex in vertices]


def _regions_from_response(response: Any) -> list[TextRegion]:
    if response.error.message:
        raise RuntimeError(f"Google Cloud Vision OCR failed: {response.error.message}")

    regions: list[TextRegion] = []
    for page in response.full_text_annotation.pages:
        for block in page.blocks:
            for paragraph in block.paragraphs:
                for word in paragraph.words:
                    text = "".join(symbol.text for symbol in word.symbols).strip()
                    if text:
                        regions.append(TextRegion(
                            polygon=_polygon(word.bounding_box.vertices),
                            text=text,
                            confidence=float(word.confidence),
                        ))

    return regions


def _find_gcloud_executable() -> str:
    candidates = [
        shutil.which("gcloud"),
        shutil.which("gcloud.cmd"),
        str(Path.home() / "AppData" / "Local" / "Google" / "Cloud SDK" / "google-cloud-sdk" / "bin" / "gcloud.cmd"),
        str(Path(r"C:\Program Files") / "Google" / "Cloud SDK" / "google-cloud-sdk" / "bin" / "gcloud.cmd"),
    ]
    for candidate in candidates:
        if candidate and Path(candidate).exists():
            return candidate
    raise RuntimeError("Could not find gcloud executable. Add gcloud to PATH or install Google Cloud SDK.")


def _run_vision_with_gcloud_token(content: bytes, language: str) -> list[TextRegion]:
    token_result = subprocess.run(
        [_find_gcloud_executable(), "auth", "print-access-token"],
        check=True,
        capture_output=True,
        text=True,
    )
    access_token = token_result.stdout.strip()
    if not access_token:
        raise RuntimeError("gcloud returned an empty access token")

    payload: dict[str, Any] = {
        "requests": [{
            "image": {"content": base64.b64encode(content).decode("ascii")},
            "features": [{"type": "DOCUMENT_TEXT_DETECTION"}],
        }],
    }
    if language:
        payload["requests"][0]["imageContext"] = {"languageHints": [language]}

    req = urllib_request.Request(
        "https://vision.googleapis.com/v1/images:annotate",
        data=json.dumps(payload).encode("utf-8"),
        headers={
            "Authorization": f"Bearer {access_token}",
            "Content-Type": "application/json; charset=utf-8",
            "x-goog-user-project": DEFAULT_PROJECT_ID,
        },
        method="POST",
    )
    try:
        with urllib_request.urlopen(req, timeout=30) as response:
            body = json.loads(response.read().decode("utf-8"))
    except urllib_error.HTTPError as exc:
        details = exc.read().decode("utf-8", errors="ignore")
        raise RuntimeError(f"Google Cloud Vision API HTTP {exc.code}: {details}") from exc

    result = body.get("responses", [{}])[0]
    error = result.get("error", {})
    if error.get("message"):
        raise RuntimeError(f"Google Cloud Vision OCR failed: {error['message']}")
    regions: list[TextRegion] = []
    for page in result.get("fullTextAnnotation", {}).get("pages", []):
        for block in page.get("blocks", []):
            for paragraph in block.get("paragraphs", []):
                for word in paragraph.get("words", []):
                    text = "".join(symbol.get("text", "") for symbol in word.get("symbols", [])).strip()
                    if text:
                        vertices = word.get("boundingBox", {}).get("vertices", [])
                        regions.append(TextRegion(
                            polygon=[[float(vertex.get("x", 0)), float(vertex.get("y", 0))] for vertex in vertices],
                            text=text,
                            confidence=float(word.get("confidence", 0.0)),
                        ))
    return regions


def _run_vision_ocr(engine: Any, content: bytes, language: str) -> list[TextRegion]:
    if engine is None:
        return _run_vision_with_gcloud_token(content, language)
    image = vision.Image(content=content)
    context = vision.ImageContext(language_hints=[language]) if language else None
    try:
        # Bound the call instead of relying on the client's much longer default deadline,
        # so a stalled request fails fast into the REST fallback below.
        response = engine.document_text_detection(image=image, image_context=context, timeout=15)
        return _regions_from_response(response)
    except Exception:
        return _run_vision_with_gcloud_token(content, language)


def run_google_vision_ocr(engine: Any, image_path: Path, language: str = "en") -> list[TextRegion]:
    return _run_vision_ocr(engine, image_path.read_bytes(), language)


def run_google_vision_ocr_array(
    engine: Any, image: np.ndarray, language: str = "en"
) -> list[TextRegion]:
    ok, encoded = cv2.imencode(".jpg", image)
    if not ok:
        raise ValueError("Could not encode the camera frame for Google Cloud Vision")
    return _run_vision_ocr(engine, encoded.tobytes(), language)