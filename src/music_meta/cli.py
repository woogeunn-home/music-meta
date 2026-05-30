from __future__ import annotations

import argparse
import os
from pathlib import Path

from .filenames import filename_for, unique_path
from .matcher import best_match, score_match
from .mp3_tags import read_guess, write_tags
from .providers import default_provider_chain


def main() -> None:
    _load_dotenv(Path.cwd() / ".env")

    parser = argparse.ArgumentParser(description="Fill MP3 metadata from public metadata sources.")
    parser.add_argument("path", type=Path, help="MP3 file or folder to process")
    parser.add_argument("--country", default=os.getenv("MUSIC_META_COUNTRY", "KR"))
    parser.add_argument("--recursive", action="store_true", help="Scan folders recursively")
    parser.add_argument("--dry-run", action="store_true", help="Preview changes without writing files")
    parser.add_argument("--yes", action="store_true", help="Apply changes without prompting")
    parser.add_argument("--cover-art", action="store_true", help="Save album artwork into MP3 tags")
    parser.add_argument("--limit", type=int, default=5, help="Metadata search result limit")
    parser.add_argument(
        "--pattern",
        default="{artist} - {title}",
        help='Rename pattern without extension, e.g. "{track} {title}"',
    )
    args = parser.parse_args()

    files = list(_iter_mp3s(args.path, recursive=args.recursive))
    if not files:
        raise SystemExit("No MP3 files found.")

    os.environ["MUSIC_META_COUNTRY"] = args.country
    client = default_provider_chain()

    planned: list[tuple[Path, object, Path, float]] = []
    for path in files:
        guess = read_guess(path)
        candidates = client.search_song(guess.query, limit=args.limit)
        match = best_match(guess, candidates)
        if not match:
            print(f"SKIP  {path.name}: no metadata match for '{guess.query}'")
            continue

        score = score_match(guess, match)
        new_name = filename_for(match, args.pattern) + path.suffix.lower()
        target = unique_path(path.with_name(new_name))
        planned.append((path, match, target, score))
        print(f"MATCH {path.name}")
        print(f"  -> {match.artist} - {match.title} ({match.album or 'Unknown Album'}) [{match.source}, {score:.0%}]")
        if target != path:
            print(f"  rename: {target.name}")

    if args.dry_run:
        print("\nDry run complete. No files changed.")
        return

    if not args.yes and not _confirm(f"\nApply changes to {len(planned)} file(s)? [y/N] "):
        print("Canceled.")
        return

    for path, track, target, _score in planned:
        artwork = None
        if args.cover_art and getattr(track, "artwork_url", None):
            artwork = client.download_artwork(track)
        write_tags(path, track, artwork=artwork)
        if target != path:
            path.rename(target)
        print(f"DONE  {target.name}")


def _iter_mp3s(path: Path, recursive: bool) -> list[Path]:
    if path.is_file() and path.suffix.casefold() == ".mp3":
        return [path]
    pattern = "**/*.mp3" if recursive else "*.mp3"
    return sorted(path.glob(pattern))


def _confirm(prompt: str) -> bool:
    return input(prompt).strip().casefold() in {"y", "yes"}


def _load_dotenv(path: Path) -> None:
    if not path.exists():
        return
    for raw_line in path.read_text(encoding="utf-8").splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        key = key.strip()
        value = value.strip().strip('"').strip("'")
        os.environ.setdefault(key, value)


if __name__ == "__main__":
    main()
