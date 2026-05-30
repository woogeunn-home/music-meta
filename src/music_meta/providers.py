from __future__ import annotations

import os
from typing import Any, Protocol

import requests

from .models import TrackMetadata


class MetadataProvider(Protocol):
    name: str

    def search_song(self, term: str, limit: int = 5) -> list[TrackMetadata]:
        ...

    def download_artwork(self, artwork_url: str, size: int = 1200) -> bytes:
        ...


class ProviderError(RuntimeError):
    pass


class ProviderChain:
    def __init__(self, providers: list[MetadataProvider]) -> None:
        self.providers = providers

    def search_song(self, term: str, limit: int = 5) -> list[TrackMetadata]:
        results: list[TrackMetadata] = []
        for provider in self.providers:
            try:
                results.extend(provider.search_song(term, limit=limit))
            except requests.RequestException:
                continue
        return results

    def download_artwork(self, track: TrackMetadata, size: int = 1200) -> bytes | None:
        if not track.artwork_url:
            return None
        for provider in self.providers:
            if provider.name == track.source:
                try:
                    return provider.download_artwork(track.artwork_url, size=size)
                except requests.RequestException:
                    return None
        return None


class MusicBrainzProvider:
    name = "MusicBrainz"

    def __init__(self, user_agent: str | None = None) -> None:
        self.session = requests.Session()
        self.session.headers.update(
            {
                "User-Agent": user_agent
                or os.getenv("MUSIC_META_USER_AGENT")
                or "music-meta/0.1.0 (https://github.com/local/music-meta)"
            }
        )

    def search_song(self, term: str, limit: int = 5) -> list[TrackMetadata]:
        if not term:
            return []

        response = self.session.get(
            "https://musicbrainz.org/ws/2/recording/",
            params={"query": term, "fmt": "json", "limit": limit},
            timeout=20,
        )
        response.raise_for_status()
        return [_track_from_musicbrainz(item) for item in response.json().get("recordings", [])]

    def download_artwork(self, artwork_url: str, size: int = 1200) -> bytes:
        response = self.session.get(artwork_url, allow_redirects=True, timeout=20)
        response.raise_for_status()
        return response.content


class ITunesProvider:
    name = "iTunes"

    def __init__(self, country: str | None = None) -> None:
        self.country = country or os.getenv("MUSIC_META_COUNTRY", "KR")
        self.session = requests.Session()

    def search_song(self, term: str, limit: int = 5) -> list[TrackMetadata]:
        if not term:
            return []

        response = self.session.get(
            "https://itunes.apple.com/search",
            params={
                "term": term,
                "country": self.country,
                "media": "music",
                "entity": "song",
                "limit": limit,
            },
            timeout=20,
        )
        response.raise_for_status()
        return [_track_from_itunes(item) for item in response.json().get("results", [])]

    def download_artwork(self, artwork_url: str, size: int = 1200) -> bytes:
        sized_url = artwork_url.replace("100x100bb", f"{size}x{size}bb")
        response = self.session.get(sized_url, timeout=20)
        response.raise_for_status()
        return response.content


def default_provider_chain() -> ProviderChain:
    return ProviderChain([MusicBrainzProvider(), ITunesProvider()])


def _track_from_musicbrainz(item: dict[str, Any]) -> TrackMetadata:
    release = _first(item.get("releases"))
    artist = _artist_credit(item.get("artist-credit")) or "Unknown Artist"
    release_group = (release or {}).get("release-group") or {}
    release_id = (release or {}).get("id")
    first_medium = _first((release or {}).get("media"))
    first_track = _first((first_medium or {}).get("track"))
    return TrackMetadata(
        id=item.get("id") or "",
        source=MusicBrainzProvider.name,
        title=item.get("title") or "Unknown Title",
        artist=artist,
        album=(release or {}).get("title"),
        album_artist=artist,
        track_number=_parse_int((first_track or {}).get("number")),
        disc_number=_parse_int((first_medium or {}).get("position")),
        genre=None,
        release_date=(release or {}).get("date") or release_group.get("first-release-date"),
        isrc=_first(item.get("isrcs")),
        artwork_url=f"https://coverartarchive.org/release/{release_id}/front" if release_id else None,
    )


def _track_from_itunes(item: dict[str, Any]) -> TrackMetadata:
    return TrackMetadata(
        id=str(item.get("trackId") or ""),
        source=ITunesProvider.name,
        title=item.get("trackName") or "Unknown Title",
        artist=item.get("artistName") or "Unknown Artist",
        album=item.get("collectionName"),
        album_artist=item.get("artistName"),
        track_number=item.get("trackNumber"),
        disc_number=item.get("discNumber"),
        genre=item.get("primaryGenreName"),
        release_date=item.get("releaseDate"),
        isrc=None,
        artwork_url=item.get("artworkUrl100"),
    )


def _artist_credit(value: list[dict[str, Any]] | None) -> str | None:
    if not value:
        return None
    names = [credit.get("artist", {}).get("name") for credit in value]
    return ", ".join(name for name in names if name)


def _first(value: list[Any] | None) -> Any | None:
    if not isinstance(value, list) or not value:
        return None
    return value[0]


def _parse_int(value: Any) -> int | None:
    try:
        return int(value)
    except (TypeError, ValueError):
        return None
