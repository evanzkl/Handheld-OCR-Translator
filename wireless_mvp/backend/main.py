from __future__ import annotations

import base64
import threading
import time
import uuid

import cv2
import numpy as np
from fastapi import FastAPI, File, Form, HTTPException, UploadFile
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import Response

from .gui.languages import LANGUAGES, language_by_display_name
from .gui.pipeline import TranslationPipeline
from .OCR.google_vision import warm_up_engine
from .translation.translator import warm_up_client
from .schemas import (
    JobCreateRequest,
    JobCreateResponse,
    JobStatusResponse,
    LanguageInfo,
    ProcessResult,
)

app = FastAPI(title="Handheld OCR Translator API", version="1.0.0")


@app.on_event("startup")
def _warm_up_google_clients() -> None:
    """Build the Vision/Translation gRPC clients now, not on the first request."""
    warm_up_engine()
    warm_up_client()

# Allow a local Flutter web dev server (served from a different port) to call this API.
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)

# Single shared pipeline so the Vision/Translation clients are created once and reused.
pipeline = TranslationPipeline()


@app.get("/health")
def health() -> dict[str, str]:
    return {"status": "ok"}


@app.get("/api/languages", response_model=list[LanguageInfo])
def get_languages() -> list[LanguageInfo]:
    return [
        LanguageInfo(
            display_name=lang.display_name,
            ocr_code=lang.ocr_code,
            translate_code=lang.translate_code,
        )
        for lang in LANGUAGES
    ]


def _process_image_bytes(content: bytes, source_lang: str, target_lang: str) -> tuple[bytes, float, float]:
    """Decode raw image bytes, run the shared pipeline, and return (png_bytes, accuracy, seconds).

    Shared by the laptop-diagnostic upload path (/api/process) and the ESP32
    job-upload path (/api/v1/jobs/{job_id}/upload) so the pipeline is not duplicated.
    """
    try:
        source = language_by_display_name(source_lang)
        target = language_by_display_name(target_lang)
    except KeyError as exc:
        raise HTTPException(status_code=400, detail=f"Unknown language: {exc}") from exc

    image = cv2.imdecode(np.frombuffer(content, dtype=np.uint8), cv2.IMREAD_COLOR)
    if image is None:
        print(f"[decode-failed] {len(content)} bytes, header={content[:16].hex()}")
        raise HTTPException(status_code=400, detail="Could not decode uploaded image")

    started_at = time.perf_counter()
    try:
        result_image, accuracy = pipeline.process(image, source.ocr_code, target.translate_code)
    except Exception as exc:  # noqa: BLE001 - surface pipeline failures to the caller
        raise HTTPException(status_code=502, detail=str(exc)) from exc
    processing_time = time.perf_counter() - started_at

    ok, encoded = cv2.imencode(".png", result_image)
    if not ok:
        raise HTTPException(status_code=500, detail="Could not encode processed image")

    return encoded.tobytes(), accuracy, processing_time


async def _run_pipeline(
    file: UploadFile, source_lang: str, target_lang: str
) -> tuple[bytes, float, float]:
    """Decode the upload, run the shared pipeline, and return (png_bytes, accuracy, seconds)."""
    content = await file.read()
    return _process_image_bytes(content, source_lang, target_lang)


@app.post("/api/process", response_model=ProcessResult)
async def process_image(
    file: UploadFile = File(...),
    source_lang: str = Form(...),
    target_lang: str = Form(...),
) -> ProcessResult:
    png_bytes, accuracy, processing_time = await _run_pipeline(file, source_lang, target_lang)
    return ProcessResult(
        image_base64=base64.b64encode(png_bytes).decode("ascii"),
        image_format="png",
        accuracy=accuracy,
        processing_time_seconds=processing_time,
    )


@app.post(
    "/api/process/image",
    response_class=Response,
    responses={200: {"content": {"image/png": {}}}},
)
async def process_image_raw(
    file: UploadFile = File(...),
    source_lang: str = Form(...),
    target_lang: str = Form(...),
) -> Response:
    """Same processing as /api/process, but returns the PNG directly for easy viewing in /docs."""
    png_bytes, accuracy, processing_time = await _run_pipeline(file, source_lang, target_lang)
    return Response(
        content=png_bytes,
        media_type="image/png",
        headers={
            "X-Accuracy": f"{accuracy:.4f}",
            "X-Processing-Time-Seconds": f"{processing_time:.4f}",
        },
    )


class _Job:
    """In-memory record for one ESP32 capture job (no database, per project constraints)."""

    def __init__(self, source_lang: str, target_lang: str) -> None:
        self.source_lang = source_lang
        self.target_lang = target_lang
        self.status: str = "pending"
        self.result: ProcessResult | None = None
        self.error: str | None = None


_jobs: dict[str, _Job] = {}
_jobs_lock = threading.Lock()


@app.post("/api/v1/jobs", response_model=JobCreateResponse)
def create_job(payload: JobCreateRequest) -> JobCreateResponse:
    """Flutter calls this first to create a capture job, then tells the ESP32 to capture."""
    try:
        language_by_display_name(payload.source_lang)
        language_by_display_name(payload.target_lang)
    except KeyError as exc:
        raise HTTPException(status_code=400, detail=f"Unknown language: {exc}") from exc

    job_id = uuid.uuid4().hex
    with _jobs_lock:
        _jobs[job_id] = _Job(payload.source_lang, payload.target_lang)
    return JobCreateResponse(job_id=job_id, status="pending")


@app.post("/api/v1/jobs/{job_id}/upload")
async def upload_job_image(job_id: str, file: UploadFile = File(...)) -> dict[str, str]:
    """Called directly by the ESP32 after it captures a still image (not by Flutter)."""
    with _jobs_lock:
        job = _jobs.get(job_id)
    if job is None:
        raise HTTPException(status_code=404, detail="Unknown job_id")

    content = await file.read()
    try:
        png_bytes, accuracy, processing_time = _process_image_bytes(content, job.source_lang, job.target_lang)
    except HTTPException as exc:
        with _jobs_lock:
            job.status = "error"
            job.error = str(exc.detail)
        raise

    with _jobs_lock:
        job.status = "done"
        job.result = ProcessResult(
            image_base64=base64.b64encode(png_bytes).decode("ascii"),
            image_format="png",
            accuracy=accuracy,
            processing_time_seconds=processing_time,
        )
    return {"status": "ok"}


@app.get("/api/v1/jobs/{job_id}", response_model=JobStatusResponse)
def get_job(job_id: str) -> JobStatusResponse:
    """Flutter polls this to retrieve the completed result."""
    with _jobs_lock:
        job = _jobs.get(job_id)
    if job is None:
        raise HTTPException(status_code=404, detail="Unknown job_id")
    return JobStatusResponse(job_id=job_id, status=job.status, result=job.result, error=job.error)
