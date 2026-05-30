from __future__ import annotations

import re
import unicodedata
from pathlib import Path

from .models import TrackMetadata

INVALID_FILENAME_CHARS = re.compile(r'[\\/:*?"<>|]')
WHITESPACE = re.compile(r"\s+")


def clean_filename_part(value: str, fallback: str = "Unknown") -> str:
    normalized = unicodedata.normalize("NFC", value or fallback)
    cleaned = INVALID_FILENAME_CHARS.sub("-", normalized)
    cleaned = WHITESPACE.sub(" ", cleaned).strip(" .")
    return cleaned or fallback


def filename_for(track: TrackMetadata, pattern: str) -> str:
    values = {
        "artist": clean_filename_part(track.artist),
        "album_artist": clean_filename_part(track.album_artist or track.artist),
        "album": clean_filename_part(track.album or "Unknown Album"),
        "title": clean_filename_part(track.title),
        "track": f"{track.track_number:02d}" if track.track_number else "",
        "disc": str(track.disc_number or ""),
        "year": track.year or "",
    }
    return pattern.format(**values).strip()


def unique_path(target: Path) -> Path:
    if not target.exists():
        return target

    stem = target.stem
    suffix = target.suffix
    parent = target.parent
    index = 2
    while True:
        candidate = parent / f"{stem} ({index}){suffix}"
        if not candidate.exists():
            return candidate
        index += 1
