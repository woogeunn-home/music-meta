import Foundation

struct TrackGuess: Sendable {
    var title: String?
    var artist: String?
    var album: String?

    var query: String {
        [artist, title, album]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}

struct TrackMetadata: Identifiable, Hashable, Sendable {
    var id: String
    var source: String
    var title: String
    var artist: String
    var album: String?
    var albumArtist: String?
    var trackNumber: Int?
    var discNumber: Int?
    var genre: String?
    var releaseDate: String?
    var isrc: String?
    var artworkURL: URL?

    var year: String? {
        guard let releaseDate, !releaseDate.isEmpty else { return nil }
        return String(releaseDate.prefix(4))
    }
}

struct AlbumMetadata: Identifiable, Hashable, Sendable {
    var id: String
    var source: String
    var title: String
    var artist: String
    var genre: String?
    var releaseDate: String?
    var artworkURL: URL?
    var tracks: [TrackMetadata]

    var year: String? {
        guard let releaseDate, !releaseDate.isEmpty else { return nil }
        return String(releaseDate.prefix(4))
    }
}

struct PreviewItem: Identifiable, Sendable {
    let id = UUID()
    var fileURL: URL
    var query: String
    var candidates: [TrackMetadata]
    var selected: TrackMetadata?
    var score: Double
    var status: PreviewStatus

    var fileName: String {
        fileURL.lastPathComponent
    }
}

struct AlbumGroup: Identifiable, Sendable {
    let id = UUID()
    var folderURL: URL
    var albumTitle: String
    var albumSearchTerm: String
    var itemIDs: [PreviewItem.ID]
    var albumCandidates: [AlbumMetadata] = []
    var selectedAlbum: AlbumMetadata?

    var folderName: String {
        folderURL.lastPathComponent
    }
}

enum PreviewStatus: String {
    case pending = "대기"
    case matched = "매칭"
    case noMatch = "매칭 없음"
    case failed = "실패"
    case saved = "저장됨"
}

enum AppError: Error, LocalizedError {
    case noMP3Files
    case invalidPattern

    var errorDescription: String? {
        switch self {
        case .noMP3Files:
            "MP3 파일을 찾지 못했어요."
        case .invalidPattern:
            "파일명 패턴을 확인해 주세요."
        }
    }
}
