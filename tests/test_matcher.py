from music_meta.matcher import best_match
from music_meta.models import TrackGuess, TrackMetadata


def track(title: str, artist: str) -> TrackMetadata:
    return TrackMetadata(
        id="1",
        source="test",
        title=title,
        artist=artist,
        album=None,
        album_artist=artist,
        track_number=None,
        disc_number=None,
        genre=None,
        release_date=None,
        isrc=None,
        artwork_url=None,
    )


def test_best_match_prefers_title_and_artist_similarity() -> None:
    guess = TrackGuess(title="Ditto", artist="NewJeans")
    candidates = [track("OMG", "NewJeans"), track("Ditto", "NewJeans")]

    assert best_match(guess, candidates).title == "Ditto"
