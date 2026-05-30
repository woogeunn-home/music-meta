from __future__ import annotations

import os
import threading
from dataclasses import dataclass
from pathlib import Path
from tkinter import BooleanVar, StringVar, Tk, Toplevel, messagebox, simpledialog, ttk

try:
    from tkinterdnd2 import DND_FILES, TkinterDnD
except ImportError:  # pragma: no cover - import guard for optional GUI dependency
    DND_FILES = None
    TkinterDnD = None

from .filenames import filename_for, unique_path
from .matcher import best_match, score_match
from .models import TrackMetadata
from .mp3_tags import read_guess, write_tags
from .providers import default_provider_chain


@dataclass
class PreviewRow:
    path: Path
    query: str
    match: TrackMetadata | None
    score: float = 0.0
    target: Path | None = None


class MusicMetaApp:
    def __init__(self, root: Tk) -> None:
        self.root = root
        self.root.title("music-meta")
        self.root.geometry("980x620")
        self.client = default_provider_chain()
        self.rows: dict[str, PreviewRow] = {}
        self.rename_enabled = BooleanVar(value=False)
        self.pattern = StringVar(value="{artist} - {title}")
        self.status = StringVar(value="MP3 파일이나 폴더를 여기에 드롭하세요.")

        self._build()

    def _build(self) -> None:
        frame = ttk.Frame(self.root, padding=16)
        frame.pack(fill="both", expand=True)

        drop = ttk.Label(
            frame,
            text="MP3 파일/폴더 드롭",
            anchor="center",
            relief="ridge",
            padding=28,
        )
        drop.pack(fill="x")
        if DND_FILES is not None:
            drop.drop_target_register(DND_FILES)
            drop.dnd_bind("<<Drop>>", self._on_drop)

        toolbar = ttk.Frame(frame)
        toolbar.pack(fill="x", pady=(12, 8))
        ttk.Button(toolbar, text="재검색", command=self._research_selected).pack(side="left")
        ttk.Button(toolbar, text="저장", command=self._save).pack(side="left", padx=(8, 0))
        ttk.Checkbutton(toolbar, text="Advanced: 파일명 변경", variable=self.rename_enabled, command=self._refresh_targets).pack(
            side="left", padx=(20, 8)
        )
        ttk.Entry(toolbar, textvariable=self.pattern, width=32).pack(side="left")
        ttk.Button(toolbar, text="패턴 적용", command=self._refresh_targets).pack(side="left", padx=(8, 0))

        columns = ("file", "match", "album", "source", "score", "rename")
        self.tree = ttk.Treeview(frame, columns=columns, show="headings", selectmode="browse")
        headings = {
            "file": "파일",
            "match": "적용될 제목/아티스트",
            "album": "앨범",
            "source": "출처",
            "score": "점수",
            "rename": "새 파일명",
        }
        widths = {"file": 180, "match": 260, "album": 190, "source": 90, "score": 60, "rename": 190}
        for column in columns:
            self.tree.heading(column, text=headings[column])
            self.tree.column(column, width=widths[column], anchor="w")
        self.tree.pack(fill="both", expand=True)

        ttk.Label(frame, textvariable=self.status).pack(fill="x", pady=(8, 0))

    def _on_drop(self, event: object) -> None:
        raw_paths = self.root.tk.splitlist(getattr(event, "data", ""))
        paths = [Path(raw_path) for raw_path in raw_paths]
        files = _collect_mp3s(paths)
        if not files:
            messagebox.showinfo("music-meta", "MP3 파일을 찾지 못했어요.")
            return
        self._analyze(files)

    def _analyze(self, files: list[Path]) -> None:
        self.status.set(f"{len(files)}개 파일 분석 중...")
        self.tree.delete(*self.tree.get_children())
        self.rows.clear()
        threading.Thread(target=self._analyze_worker, args=(files,), daemon=True).start()

    def _analyze_worker(self, files: list[Path]) -> None:
        for path in files:
            guess = read_guess(path)
            candidates = self.client.search_song(guess.query, limit=8)
            match = best_match(guess, candidates)
            score = score_match(guess, match) if match else 0.0
            row = PreviewRow(path=path, query=guess.query, match=match, score=score)
            row.target = self._target_for(row)
            self.root.after(0, self._insert_row, row)
        self.root.after(0, self.status.set, f"{len(files)}개 파일 분석 완료")

    def _insert_row(self, row: PreviewRow) -> None:
        item_id = str(row.path)
        self.rows[item_id] = row
        self.tree.insert("", "end", iid=item_id, values=self._values(row))

    def _values(self, row: PreviewRow) -> tuple[str, str, str, str, str, str]:
        match = row.match
        if not match:
            return (row.path.name, "매칭 없음", "", "", "", "")
        return (
            row.path.name,
            f"{match.artist} - {match.title}",
            match.album or "",
            match.source,
            f"{row.score:.0%}",
            row.target.name if row.target and row.target != row.path else "",
        )

    def _research_selected(self) -> None:
        selected = self.tree.selection()
        if not selected:
            return
        item_id = selected[0]
        row = self.rows[item_id]
        query = simpledialog.askstring("재검색", "검색어를 수정하세요.", initialvalue=row.query)
        if not query:
            return
        self.status.set(f"재검색 중: {query}")
        threading.Thread(target=self._research_worker, args=(item_id, query), daemon=True).start()

    def _research_worker(self, item_id: str, query: str) -> None:
        candidates = self.client.search_song(query, limit=10)
        self.root.after(0, self._choose_candidate, item_id, query, candidates)

    def _choose_candidate(self, item_id: str, query: str, candidates: list[TrackMetadata]) -> None:
        if not candidates:
            messagebox.showinfo("music-meta", "후보를 찾지 못했어요.")
            self.status.set("재검색 완료: 후보 없음")
            return

        dialog = CandidateDialog(self.root, candidates)
        self.root.wait_window(dialog.window)
        if dialog.selected is None:
            self.status.set("재검색 취소")
            return

        row = self.rows[item_id]
        row.query = query
        row.match = dialog.selected
        row.score = score_match(read_guess(row.path), dialog.selected)
        row.target = self._target_for(row)
        self.tree.item(item_id, values=self._values(row))
        self.status.set("재검색 결과 반영 완료")

    def _refresh_targets(self) -> None:
        for item_id, row in self.rows.items():
            row.target = self._target_for(row)
            self.tree.item(item_id, values=self._values(row))

    def _target_for(self, row: PreviewRow) -> Path:
        if not self.rename_enabled.get() or not row.match:
            return row.path
        return unique_path(row.path.with_name(filename_for(row.match, self.pattern.get()) + row.path.suffix.lower()))

    def _save(self) -> None:
        rows = [row for row in self.rows.values() if row.match]
        if not rows:
            messagebox.showinfo("music-meta", "저장할 매칭 결과가 없어요.")
            return
        if not messagebox.askyesno("저장", f"{len(rows)}개 파일의 메타데이터를 덮어쓸까요?"):
            return

        self.status.set("저장 중...")
        threading.Thread(target=self._save_worker, args=(rows,), daemon=True).start()

    def _save_worker(self, rows: list[PreviewRow]) -> None:
        saved = 0
        for row in rows:
            artwork = self.client.download_artwork(row.match)
            write_tags(row.path, row.match, artwork=artwork)
            if row.target and row.target != row.path:
                row.path.rename(row.target)
                row.path = row.target
            saved += 1
        self.root.after(0, self.status.set, f"{saved}개 파일 저장 완료")


class CandidateDialog:
    def __init__(self, root: Tk, candidates: list[TrackMetadata]) -> None:
        self.selected = None
        self.candidates = candidates
        self.window = Toplevel(root)
        self.window.title("후보 선택")
        self.window.geometry("760x320")

        columns = ("track", "album", "source")
        self.tree = ttk.Treeview(self.window, columns=columns, show="headings")
        for column, title, width in [("track", "곡", 320), ("album", "앨범", 300), ("source", "출처", 100)]:
            self.tree.heading(column, text=title)
            self.tree.column(column, width=width)
        self.tree.pack(fill="both", expand=True, padx=12, pady=12)

        for index, track in enumerate(candidates):
            self.tree.insert("", "end", iid=str(index), values=(f"{track.artist} - {track.title}", track.album or "", track.source))

        buttons = ttk.Frame(self.window)
        buttons.pack(fill="x", padx=12, pady=(0, 12))
        ttk.Button(buttons, text="선택", command=self._select).pack(side="right")
        ttk.Button(buttons, text="취소", command=self.window.destroy).pack(side="right", padx=(0, 8))

    def _select(self) -> None:
        selected = self.tree.selection()
        if selected:
            self.selected = self.candidates[int(selected[0])]
        self.window.destroy()


def _collect_mp3s(paths: list[Path]) -> list[Path]:
    files: list[Path] = []
    for path in paths:
        if path.is_file() and path.suffix.casefold() == ".mp3":
            files.append(path)
        elif path.is_dir():
            files.extend(sorted(path.rglob("*.mp3")))
    return files


def main() -> None:
    _load_dotenv(Path.cwd() / ".env")
    if TkinterDnD is None:
        raise SystemExit('GUI dependency missing. Install with: pip install -e ".[gui]"')
    root = TkinterDnD.Tk()
    MusicMetaApp(root)
    root.mainloop()


def _load_dotenv(path: Path) -> None:
    if not path.exists():
        return
    for raw_line in path.read_text(encoding="utf-8").splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        os.environ.setdefault(key.strip(), value.strip().strip('"').strip("'"))
