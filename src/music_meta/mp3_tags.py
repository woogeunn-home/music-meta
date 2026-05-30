from __future__ import annotations

from pathlib import Path

from mutagen.easyid3 import EasyID3
from mutagen.id3 import APIC, ID3, ID3NoHeaderError
from mutagen.mp3 import MP3

from .models import TrackGuess, TrackMetadata


def read_guess(path: Path) -> TrackGuess:
    title = artist = album = None
    try:
        audio = EasyID3(path)
        title = _first(audio.get("title"))
        artist = _first(audio.get("artist"))
        album = _first(audio.get("album"))
    except Exception:
        pass

    if not title:
        title = path.stem
        if " - " in title:
            maybe_artist, maybe_title = title.split(" - ", 1)
            artist = artist or maybe_artist.strip()
            title = maybe_title.strip()

    return TrackGuess(title=title, artist=artist, album=album)


def write_tags(path: Path, track: TrackMetadata, artwork: bytes | None = None) -> None:
    try:
        audio = EasyID3(path)
    except ID3NoHeaderError:
        audio = MP3(path, ID3=EasyID3)
        audio.add_tags()
        audio.save(path)
        audio = EasyID3(path)

    audio["title"] = track.title
    audio["artist"] = track.artist
    if track.album:
        audio["album"] = track.album
    if track.album_artist:
        audio["albumartist"] = track.album_artist
    if track.genre:
        audio["genre"] = track.genre
    if track.year:
        audio["date"] = track.year
    if track.track_number:
        audio["tracknumber"] = str(track.track_number)
    if track.disc_number:
        audio["discnumber"] = str(track.disc_number)
    if track.isrc:
        audio["isrc"] = track.isrc
    audio.save(path)

    if artwork:
        _write_artwork(path, artwork)


def _write_artwork(path: Path, artwork: bytes) -> None:
    try:
        tags = ID3(path)
    except ID3NoHeaderError:
        tags = ID3()

    tags.delall("APIC")
    tags.add(
        APIC(
            encoding=3,
            mime="image/jpeg",
            type=3,
            desc="Cover",
            data=artwork,
        )
    )
    tags.save(path)


def _first(values: list[str] | None) -> str | None:
    if not values:
        return None
    return values[0]
