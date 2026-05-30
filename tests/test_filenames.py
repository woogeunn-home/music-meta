from pathlib import Path

from music_meta.filenames import clean_filename_part, unique_path


def test_clean_filename_part_replaces_reserved_characters() -> None:
    assert clean_filename_part('A/B:C*D?"E<F>G|') == "A-B-C-D--E-F-G-"


def test_unique_path_adds_suffix(tmp_path: Path) -> None:
    original = tmp_path / "song.mp3"
    original.write_bytes(b"")

    assert unique_path(original) == tmp_path / "song (2).mp3"
