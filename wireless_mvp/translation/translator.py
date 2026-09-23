from __future__ import annotations

from functools import lru_cache
import json
import os
from pathlib import Path
import shutil
import subprocess
from typing import Any
from urllib import error as urllib_error
from urllib import request as urllib_request

try:
    from google.cloud import translate
except ImportError:  # Some installations expose only translate_v3.
    try:
        from google.cloud import translate_v3 as translate
    except ImportError:
        translate = None

try:
    from google.api_core.client_options import ClientOptions
except ImportError:  # Defensive fallback if auth extras are missing.
    ClientOptions = None

# DEFAULT_PROJECT_ID = "handheld-ocr-translator-503820"
DEFAULT_PROJECT_ID = "handheld-ocr-translator"
DEFAULT_LOCATION = "global"


def _resolve_quota_project_id(project_id: str) -> str:
    return (os.environ.get("GOOGLE_CLOUD_QUOTA_PROJECT") or project_id).strip() or project_id


@lru_cache(maxsize=1)
def _translation_client() -> Any:
    """Create and cache a Translation API client that uses ADC credentials."""
    if translate is None:
        raise ImportError("google-cloud-translate is not installed")
    quota_project_id = _resolve_quota_project_id(DEFAULT_PROJECT_ID)
    if ClientOptions is None:
        return translate.TranslationServiceClient()
    return translate.TranslationServiceClient(
        client_options=ClientOptions(quota_project_id=quota_project_id)
    )


def _translate_with_gcloud_access_token(
    contents: list[str],
    target_lang: str,
    project_id: str,
    source_lang: str | None,
) -> list[str]:
    """Fallback path: call Translation REST API using a gcloud user token."""
    gcloud_cmd = _find_gcloud_executable()
    token_result = subprocess.run(
        [gcloud_cmd, "auth", "print-access-token"],
        check=True,
        capture_output=True,
        text=True,
    )
    access_token = token_result.stdout.strip()
    if not access_token:
        raise RuntimeError("gcloud returned an empty access token")

    endpoint = (
        f"https://translation.googleapis.com/v3/projects/{project_id}"
        f"/locations/{DEFAULT_LOCATION}:translateText"
    )
    payload: dict[str, Any] = {
        "contents": contents,
        "mimeType": "text/plain",
        "targetLanguageCode": target_lang,
    }
    if source_lang:
        payload["sourceLanguageCode"] = source_lang

    req = urllib_request.Request(
        endpoint,
        data=json.dumps(payload).encode("utf-8"),
        headers={
            "Authorization": f"Bearer {access_token}",
            "Content-Type": "application/json; charset=utf-8",
            "x-goog-user-project": project_id,
        },
        method="POST",
    )
    try:
        with urllib_request.urlopen(req, timeout=30) as response:
            body = json.loads(response.read().decode("utf-8"))
    except urllib_error.HTTPError as exc:
        details = ""
        try:
            details = exc.read().decode("utf-8", errors="ignore")
        except Exception:
            details = str(exc)
        raise RuntimeError(f"Translation API HTTP {exc.code}: {details}") from exc

    translations = body.get("translations", [])
    return [item.get("translatedText", "") for item in translations]


def _find_gcloud_executable() -> str:
    """Resolve gcloud executable path, including common Windows install paths."""
    candidates = [
        shutil.which("gcloud"),
        shutil.which("gcloud.cmd"),
        str(Path(os.environ.get("LOCALAPPDATA", "")) / "Google" / "Cloud SDK" / "google-cloud-sdk" / "bin" / "gcloud.cmd"),
        str(Path(os.environ.get("ProgramFiles", r"C:\Program Files")) / "Google" / "Cloud SDK" / "google-cloud-sdk" / "bin" / "gcloud.cmd"),
    ]

    for candidate in candidates:
        if candidate and Path(candidate).exists():
            return candidate

    raise RuntimeError(
        "Could not find gcloud executable. Add gcloud to PATH or install Google Cloud SDK."
    )


def translate_texts(
    texts: list[str],
    target_lang: str = "es",
    project_id: str = DEFAULT_PROJECT_ID,
    source_lang: str | None = None,
) -> list[str]:
    """Translate a list of strings with Google Cloud Translation API v3."""
    if not texts:
        return []

    non_empty_indices = [i for i, text in enumerate(texts) if text and text.strip()]
    if not non_empty_indices:
        return texts.copy()

    try:
        client = _translation_client()
        parent = f"projects/{project_id}/locations/{DEFAULT_LOCATION}"
        req: dict[str, object] = {
            "parent": parent,
            "contents": [texts[i] for i in non_empty_indices],
            "mime_type": "text/plain",
            "target_language_code": target_lang,
        }
        if source_lang:
            req["source_language_code"] = source_lang
        response = client.translate_text(request=req)
        translated_values = [result.translated_text for result in response.translations]
    except Exception:
        translated_values = _translate_with_gcloud_access_token(
            contents=[texts[i] for i in non_empty_indices],
            target_lang=target_lang,
            project_id=project_id,
            source_lang=source_lang,
        )
        

    translated = texts.copy()
    for index, translated_text in zip(non_empty_indices, translated_values):
        translated[index] = translated_text
    return translated


def translate_text(
    text: str,
    target_lang: str = "es",
    project_id: str = DEFAULT_PROJECT_ID,
    source_lang: str | None = None,
) -> str:
    """Translate one string to a target language using Google Cloud Translation."""
    return translate_texts(
        [text],
        target_lang=target_lang,
        project_id=project_id,
        source_lang=source_lang,
    )[0]
