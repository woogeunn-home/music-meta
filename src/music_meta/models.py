from __future__ import annotations

from dataclasses import dataclass


@dataclass(frozen=True)
class TrackGuess:
    title: str | None = None
    artist: str | None = None
    album: str | None = None

    @property
    def query(self) -> str:
        parts = [self.artist, self.title, self.album]
        return " ".join(part for part in parts if part).strip()


@dataclass(frozen=True)
class TrackMetadata:
    id: str
    source: str
    title: str
    artist: str
    album: str | None
    album_artist: str | None
    track_number: int | None
    disc_number: int | None
    genre: str | None
    release_date: str | None
    isrc: str | None
    artwork_url: str | None

    @property
    def year(self) -> str | None:
        if not self.release_date:
            return None
        return self.release_date[:4]
