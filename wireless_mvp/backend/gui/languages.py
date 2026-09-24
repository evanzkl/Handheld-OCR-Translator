from __future__ import annotations

from dataclasses import dataclass


@dataclass(frozen=True)
class Language:
    display_name: str
    ocr_code: str        # Google Cloud Vision language hint
    translate_code: str  # Google Cloud Translation language code


# Curated set of languages supported by Google Cloud Vision and Translation.
LANGUAGES: list[Language] = [
    Language("English", "en", "en"),
    Language("Spanish", "es", "es"),
    Language("French", "fr", "fr"),
    Language("German", "de", "de"),
    Language("Italian", "it", "it"),
    Language("Portuguese", "pt", "pt"),
    Language("Dutch", "nl", "nl"),
    Language("Russian", "ru", "ru"),
    Language("Polish", "pl", "pl"),
    Language("Turkish", "tr", "tr"),
    Language("Vietnamese", "vi", "vi"),
    Language("Arabic", "ar", "ar"),
    Language("Hindi", "hi", "hi"),
    Language("Chinese (Simplified)", "zh-CN", "zh-CN"),
    Language("Japanese", "ja", "ja"),
    Language("Korean", "ko", "ko"),
]

LANGUAGE_NAMES: list[str] = [lang.display_name for lang in LANGUAGES]

_BY_NAME = {lang.display_name: lang for lang in LANGUAGES}


def language_by_display_name(name: str) -> Language:
    return _BY_NAME[name]
