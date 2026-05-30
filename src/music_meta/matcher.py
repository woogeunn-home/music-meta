from __future__ import annotations

from difflib import SequenceMatcher

from .models import TrackGuess, TrackMetadata


def best_match(guess: TrackGuess, candidates: list[TrackMetadata]) -> TrackMetadata | None:
    if not candidates:
        return None
    return max(candidates, key=lambda track: score_match(guess, track))


def score_match(guess: TrackGuess, track: TrackMetadata) -> float:
    title_score = _ratio(guess.title, track.title) * 0.55
    artist_score = _ratio(guess.artist, track.artist) * 0.35
    album_score = _ratio(guess.album, track.album) * 0.10
    return title_score + artist_score + album_score


def _ratio(left: str | None, right: str | None) -> float:
    if not left or not right:
        return 0.0
    return SequenceMatcher(None, left.casefold(), right.casefold()).ratio()
