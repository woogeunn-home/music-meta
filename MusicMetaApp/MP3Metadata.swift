import Foundation

enum MP3Metadata {
    static func readGuess(from url: URL) -> TrackGuess {
        var title: String?
        var artist: String?
        var album: String?

        if let data = try? Data(contentsOf: url),
           let tag = ID3Tag(data: data) {
            title = tag.textFrame("TIT2")
            artist = tag.textFrame("TPE1")
            album = tag.textFrame("TALB")
        }

        if title == nil {
            let stem = url.deletingPathExtension().lastPathComponent
            if let range = stem.range(of: " - ") {
                artist = artist ?? String(stem[..<range.lowerBound])
                title = cleanTitle(String(stem[range.upperBound...]))
            } else {
                title = cleanTitle(stem)
            }
        }

        return TrackGuess(title: title, artist: artist, album: album)
    }

    private static func cleanTitle(_ value: String) -> String {
        value
            .replacingOccurrences(of: #"^\s*\d{1,3}\s*[-._)]?\s*"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func write(track: TrackMetadata, artwork: Data?, to url: URL) throws {
        let original = try Data(contentsOf: url)
        let audio = stripLeadingID3(from: original)
        let tag = ID3Builder()
            .text("TIT2", track.title)
            .text("TPE1", track.artist)
            .text("TALB", track.album)
            .text("TPE2", track.albumArtist)
            .text("TCON", track.genre)
            .text("TDRC", track.year)
            .text("TRCK", track.trackNumber.map(String.init))
            .text("TPOS", track.discNumber.map(String.init))
            .text("TSRC", track.isrc)
            .artwork(artwork)
            .build()

        var output = Data()
        output.append(tag)
        output.append(audio)
        try output.write(to: url, options: .atomic)
    }

    private static func stripLeadingID3(from data: Data) -> Data {
        guard data.count >= 10,
              data[0] == 0x49,
              data[1] == 0x44,
              data[2] == 0x33 else {
            return data
        }

        let size = synchsafeToInt(data[6..<10])
        let total = min(data.count, size + 10)
        return data.dropFirst(total)
    }

    private static func synchsafeToInt(_ bytes: Data.SubSequence) -> Int {
        bytes.reduce(0) { ($0 << 7) | Int($1 & 0x7F) }
    }
}

private struct ID3Tag {
    let frames: [String: Data]

    init?(data: Data) {
        guard data.count >= 10,
              data[0] == 0x49,
              data[1] == 0x44,
              data[2] == 0x33 else {
            return nil
        }

        let size = data[6..<10].reduce(0) { ($0 << 7) | Int($1 & 0x7F) }
        let end = min(data.count, size + 10)
        var offset = 10
        var parsed: [String: Data] = [:]

        while offset + 10 <= end {
            let idData = data[offset..<offset + 4]
            guard let id = String(data: idData, encoding: .ascii),
                  id.range(of: #"^[A-Z0-9]{4}$"#, options: .regularExpression) != nil else {
                break
            }

            let frameSize = Int(data[offset + 4]) << 24
                | Int(data[offset + 5]) << 16
                | Int(data[offset + 6]) << 8
                | Int(data[offset + 7])
            let frameStart = offset + 10
            let frameEnd = frameStart + frameSize
            guard frameSize > 0, frameEnd <= end else { break }
            parsed[id] = data[frameStart..<frameEnd]
            offset = frameEnd
        }

        frames = parsed
    }

    func textFrame(_ id: String) -> String? {
        guard let frame = frames[id], frame.count > 1 else { return nil }
        let encoding = frame.first ?? 0
        let payload = frame.dropFirst()

        switch encoding {
        case 0:
            return String(data: payload, encoding: .isoLatin1)
        case 1:
            return String(data: payload, encoding: .utf16)
        case 3:
            return String(data: payload, encoding: .utf8)
        default:
            return String(data: payload, encoding: .utf8)
        }
    }
}

private struct ID3Builder {
    private var frames = Data()

    func text(_ id: String, _ value: String?) -> ID3Builder {
        guard let value,
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return self
        }

        var next = self
        var payload = Data([0x03])
        payload.append(Data(value.utf8))
        next.frames.append(frame(id: id, payload: payload))
        return next
    }

    func artwork(_ value: Data?) -> ID3Builder {
        guard let value, !value.isEmpty else { return self }

        var next = self
        var payload = Data([0x03])
        payload.append(Data("image/jpeg".utf8))
        payload.append(0x00)
        payload.append(0x03)
        payload.append(0x00)
        payload.append(value)
        next.frames.append(frame(id: "APIC", payload: payload))
        return next
    }

    func build() -> Data {
        var tag = Data()
        tag.append(Data("ID3".utf8))
        tag.append(contentsOf: [0x03, 0x00, 0x00])
        tag.append(synchsafe(frames.count))
        tag.append(frames)
        return tag
    }

    private func frame(id: String, payload: Data) -> Data {
        var data = Data()
        data.append(Data(id.utf8))
        data.append(bigEndian(payload.count))
        data.append(contentsOf: [0x00, 0x00])
        data.append(payload)
        return data
    }

    private func bigEndian(_ value: Int) -> Data {
        Data([
            UInt8((value >> 24) & 0xFF),
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8(value & 0xFF)
        ])
    }

    private func synchsafe(_ value: Int) -> Data {
        Data([
            UInt8((value >> 21) & 0x7F),
            UInt8((value >> 14) & 0x7F),
            UInt8((value >> 7) & 0x7F),
            UInt8(value & 0x7F)
        ])
    }
}
