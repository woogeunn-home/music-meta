import Foundation

enum FilenameRules {
    static func fileName(for track: TrackMetadata, pattern: String) -> String {
        var result = pattern
        let values: [String: String] = [
            "artist": clean(track.artist),
            "album_artist": clean(track.albumArtist ?? track.artist),
            "album": clean(track.album ?? "Unknown Album"),
            "title": clean(track.title),
            "track": track.trackNumber.map { String(format: "%02d", $0) } ?? "",
            "disc": track.discNumber.map(String.init) ?? "",
            "year": track.year ?? ""
        ]

        for (key, value) in values {
            result = result.replacingOccurrences(of: "{\(key)}", with: value)
        }

        return clean(result)
    }

    static func targetURL(for source: URL, track: TrackMetadata, pattern: String) -> URL {
        let stem = fileName(for: track, pattern: pattern)
        let proposed = source.deletingLastPathComponent()
            .appendingPathComponent(stem)
            .appendingPathExtension(source.pathExtension.lowercased())
        return uniqueURL(proposed, original: source)
    }

    static func clean(_ value: String) -> String {
        let invalid = CharacterSet(charactersIn: "\\/:*?\"<>|")
        let parts = value.components(separatedBy: invalid).joined(separator: "-")
        let collapsed = parts
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: " ."))
        return collapsed.isEmpty ? "Unknown" : collapsed
    }

    private static func uniqueURL(_ proposed: URL, original: URL) -> URL {
        if proposed == original || !FileManager.default.fileExists(atPath: proposed.path) {
            return proposed
        }

        let folder = proposed.deletingLastPathComponent()
        let stem = proposed.deletingPathExtension().lastPathComponent
        let ext = proposed.pathExtension

        var index = 2
        while true {
            let candidate = folder
                .appendingPathComponent("\(stem) (\(index))")
                .appendingPathExtension(ext)
            if !FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
            index += 1
        }
    }
}
