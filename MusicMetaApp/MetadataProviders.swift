import Foundation

protocol MetadataProvider: Sendable {
    var name: String { get }
    func search(term: String, limit: Int) async throws -> [TrackMetadata]
    func searchAlbums(term: String, limit: Int) async throws -> [AlbumMetadata]
    func downloadArtwork(from url: URL) async throws -> Data
}

struct MetadataProviderChain: Sendable {
    let providers: [MetadataProvider] = [
        ITunesProvider(country: Locale.current.region?.identifier ?? "KR"),
        MusicBrainzProvider()
    ]

    func search(term: String, limit: Int = 8) async -> [TrackMetadata] {
        var all: [TrackMetadata] = []
        for provider in providers {
            do {
                all.append(contentsOf: try await provider.search(term: term, limit: limit))
            } catch {
                continue
            }
        }
        return all
    }

    func searchAlbums(term: String, limit: Int = 6) async -> [AlbumMetadata] {
        var all: [AlbumMetadata] = []
        for provider in providers {
            do {
                all.append(contentsOf: try await provider.searchAlbums(term: term, limit: limit))
            } catch {
                continue
            }
        }
        return all
    }

    func artwork(for track: TrackMetadata) async -> Data? {
        guard let artworkURL = track.artworkURL else { return nil }
        let provider = providers.first { $0.name == track.source } ?? providers.first
        return try? await provider?.downloadArtwork(from: artworkURL)
    }
}

struct MusicBrainzProvider: MetadataProvider {
    let name = "MusicBrainz"

    func search(term: String, limit: Int) async throws -> [TrackMetadata] {
        guard var components = URLComponents(string: "https://musicbrainz.org/ws/2/recording/") else {
            return []
        }
        components.queryItems = [
            URLQueryItem(name: "query", value: term),
            URLQueryItem(name: "fmt", value: "json"),
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "inc", value: "recordings+artist-credits+release-groups")
        ]
        guard let url = components.url else { return [] }

        var request = URLRequest(url: url)
        request.setValue("music-meta/0.1.0", forHTTPHeaderField: "User-Agent")

        let (data, _) = try await URLSession.shared.data(for: request)
        let response = try JSONDecoder().decode(MusicBrainzSearchResponse.self, from: data)
        return response.recordings.map(Self.track)
    }

    func searchAlbums(term: String, limit: Int) async throws -> [AlbumMetadata] {
        guard var components = URLComponents(string: "https://musicbrainz.org/ws/2/release/") else {
            return []
        }
        components.queryItems = [
            URLQueryItem(name: "query", value: term),
            URLQueryItem(name: "fmt", value: "json"),
            URLQueryItem(name: "limit", value: String(limit))
        ]
        guard let url = components.url else { return [] }

        var request = URLRequest(url: url)
        request.setValue("music-meta/0.1.0", forHTTPHeaderField: "User-Agent")

        let (data, _) = try await URLSession.shared.data(for: request)
        let response = try JSONDecoder().decode(MusicBrainzReleaseSearchResponse.self, from: data)
        var albums: [AlbumMetadata] = []
        for release in response.releases {
            let detailedRelease = (try? await lookupRelease(id: release.id)) ?? release
            albums.append(Self.album(from: detailedRelease))
        }
        return albums
    }

    func downloadArtwork(from url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue("music-meta/0.1.0", forHTTPHeaderField: "User-Agent")
        let (data, _) = try await URLSession.shared.data(for: request)
        return data
    }

    private static func track(from recording: MusicBrainzRecording) -> TrackMetadata {
        let release = recording.releases?.first
        let medium = release?.media?.first
        let track = medium?.tracks?.first
        let artist = recording.artistCredit?
            .compactMap { $0.artist?.name }
            .joined(separator: ", ")
        let releaseID = release?.id

        return TrackMetadata(
            id: recording.id,
            source: "MusicBrainz",
            title: recording.title,
            artist: artist?.isEmpty == false ? artist! : "Unknown Artist",
            album: release?.title,
            albumArtist: artist,
            trackNumber: Int(track?.number ?? ""),
            discNumber: medium?.position,
            genre: nil,
            releaseDate: release?.date ?? release?.releaseGroup?.firstReleaseDate,
            isrc: recording.isrcs?.first,
            artworkURL: releaseID.flatMap { URL(string: "https://coverartarchive.org/release/\($0)/front") }
        )
    }

    private func lookupRelease(id: String) async throws -> MusicBrainzRelease {
        guard let url = URL(string: "https://musicbrainz.org/ws/2/release/\(id)?fmt=json&inc=recordings+artist-credits+release-groups") else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: url)
        request.setValue("music-meta/0.1.0", forHTTPHeaderField: "User-Agent")
        let (data, _) = try await URLSession.shared.data(for: request)
        return try JSONDecoder().decode(MusicBrainzRelease.self, from: data)
    }

    private static func album(from release: MusicBrainzRelease) -> AlbumMetadata {
        let artist = release.artistCredit?
            .compactMap { $0.artist?.name }
            .joined(separator: ", ")
        let albumArtist = artist?.isEmpty == false ? artist! : "Unknown Artist"
        let tracks = (release.media ?? []).flatMap { medium in
            (medium.tracks ?? []).map { track in
                TrackMetadata(
                    id: track.recording?.id ?? "\(release.id)-\(medium.position ?? 1)-\(track.number ?? "")",
                    source: "MusicBrainz",
                    title: track.title ?? track.recording?.title ?? "Unknown Title",
                    artist: albumArtist,
                    album: release.title,
                    albumArtist: albumArtist,
                    trackNumber: Int(track.number ?? ""),
                    discNumber: medium.position,
                    genre: nil,
                    releaseDate: release.date ?? release.releaseGroup?.firstReleaseDate,
                    isrc: nil,
                    artworkURL: URL(string: "https://coverartarchive.org/release/\(release.id)/front")
                )
            }
        }
        return AlbumMetadata(
            id: release.id,
            source: "MusicBrainz",
            title: release.title ?? "Unknown Album",
            artist: albumArtist,
            genre: nil,
            releaseDate: release.date ?? release.releaseGroup?.firstReleaseDate,
            artworkURL: URL(string: "https://coverartarchive.org/release/\(release.id)/front"),
            tracks: tracks
        )
    }
}

struct ITunesProvider: MetadataProvider {
    let name = "iTunes"
    let country: String

    func search(term: String, limit: Int) async throws -> [TrackMetadata] {
        guard var components = URLComponents(string: "https://itunes.apple.com/search") else {
            return []
        }
        components.queryItems = [
            URLQueryItem(name: "term", value: term),
            URLQueryItem(name: "country", value: country),
            URLQueryItem(name: "media", value: "music"),
            URLQueryItem(name: "entity", value: "song"),
            URLQueryItem(name: "limit", value: String(limit))
        ]
        guard let url = components.url else { return [] }

        let (data, _) = try await URLSession.shared.data(from: url)
        let response = try JSONDecoder().decode(ITunesSearchResponse.self, from: data)
        return response.results.map { item in
            TrackMetadata(
                id: String(item.trackID ?? 0),
                source: name,
                title: item.trackName ?? "Unknown Title",
                artist: item.artistName ?? "Unknown Artist",
                album: item.collectionName,
                albumArtist: item.artistName,
                trackNumber: item.trackNumber,
                discNumber: item.discNumber,
                genre: item.primaryGenreName,
                releaseDate: item.releaseDate,
                isrc: nil,
                artworkURL: item.artworkURL100.flatMap(Self.largeArtworkURL)
            )
        }
    }

    func searchAlbums(term: String, limit: Int) async throws -> [AlbumMetadata] {
        guard var components = URLComponents(string: "https://itunes.apple.com/search") else {
            return []
        }
        components.queryItems = [
            URLQueryItem(name: "term", value: term),
            URLQueryItem(name: "country", value: country),
            URLQueryItem(name: "media", value: "music"),
            URLQueryItem(name: "entity", value: "album"),
            URLQueryItem(name: "limit", value: String(limit))
        ]
        guard let url = components.url else { return [] }

        let (data, _) = try await URLSession.shared.data(from: url)
        let response = try JSONDecoder().decode(ITunesSearchResponse.self, from: data)
        var albums: [AlbumMetadata] = []
        for item in response.results {
            guard let collectionID = item.collectionID else { continue }
            albums.append(try await lookupAlbum(collectionID: collectionID, seed: item))
        }
        return albums
    }

    func downloadArtwork(from url: URL) async throws -> Data {
        let (data, _) = try await URLSession.shared.data(from: url)
        return data
    }

    private static func largeArtworkURL(_ value: String) -> URL? {
        URL(string: value.replacingOccurrences(of: "100x100bb", with: "1200x1200bb"))
    }

    private func lookupAlbum(collectionID: Int, seed: ITunesTrack) async throws -> AlbumMetadata {
        guard var components = URLComponents(string: "https://itunes.apple.com/lookup") else {
            throw URLError(.badURL)
        }
        components.queryItems = [
            URLQueryItem(name: "id", value: String(collectionID)),
            URLQueryItem(name: "country", value: country),
            URLQueryItem(name: "entity", value: "song")
        ]
        guard let url = components.url else { throw URLError(.badURL) }

        let (data, _) = try await URLSession.shared.data(from: url)
        let response = try JSONDecoder().decode(ITunesSearchResponse.self, from: data)
        let tracks = response.results.filter { $0.wrapperType == "track" }.map { item in
            TrackMetadata(
                id: String(item.trackID ?? 0),
                source: name,
                title: item.trackName ?? "Unknown Title",
                artist: item.artistName ?? seed.artistName ?? "Unknown Artist",
                album: item.collectionName ?? seed.collectionName,
                albumArtist: seed.artistName,
                trackNumber: item.trackNumber,
                discNumber: item.discNumber,
                genre: item.primaryGenreName ?? seed.primaryGenreName,
                releaseDate: item.releaseDate ?? seed.releaseDate,
                isrc: nil,
                artworkURL: item.artworkURL100.flatMap(Self.largeArtworkURL) ?? seed.artworkURL100.flatMap(Self.largeArtworkURL)
            )
        }
        return AlbumMetadata(
            id: String(collectionID),
            source: name,
            title: seed.collectionName ?? "Unknown Album",
            artist: seed.artistName ?? "Unknown Artist",
            genre: seed.primaryGenreName,
            releaseDate: seed.releaseDate,
            artworkURL: seed.artworkURL100.flatMap(Self.largeArtworkURL),
            tracks: tracks
        )
    }
}

private struct MusicBrainzReleaseSearchResponse: Decodable {
    let releases: [MusicBrainzRelease]
}

private struct MusicBrainzSearchResponse: Decodable {
    let recordings: [MusicBrainzRecording]
}

private struct MusicBrainzRecording: Decodable {
    let id: String
    let title: String
    let releases: [MusicBrainzRelease]?
    let isrcs: [String]?
    let artistCredit: [MusicBrainzArtistCredit]?

    enum CodingKeys: String, CodingKey {
        case id
        case title
        case releases
        case isrcs
        case artistCredit = "artist-credit"
    }
}

private struct MusicBrainzArtistCredit: Decodable {
    let artist: MusicBrainzArtist?
}

private struct MusicBrainzArtist: Decodable {
    let name: String?
}

private struct MusicBrainzRelease: Decodable {
    let id: String
    let title: String?
    let date: String?
    let media: [MusicBrainzMedium]?
    let releaseGroup: MusicBrainzReleaseGroup?
    let artistCredit: [MusicBrainzArtistCredit]?

    enum CodingKeys: String, CodingKey {
        case id
        case title
        case date
        case media
        case releaseGroup = "release-group"
        case artistCredit = "artist-credit"
    }
}

private struct MusicBrainzReleaseGroup: Decodable {
    let firstReleaseDate: String?

    enum CodingKeys: String, CodingKey {
        case firstReleaseDate = "first-release-date"
    }
}

private struct MusicBrainzMedium: Decodable {
    let position: Int?
    let tracks: [MusicBrainzTrack]?

    enum CodingKeys: String, CodingKey {
        case position
        case tracks
        case track
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        position = try container.decodeIfPresent(Int.self, forKey: .position)
        tracks = try container.decodeIfPresent([MusicBrainzTrack].self, forKey: .tracks)
            ?? container.decodeIfPresent([MusicBrainzTrack].self, forKey: .track)
    }
}

private struct MusicBrainzTrack: Decodable {
    let number: String?
    let title: String?
    let recording: MusicBrainzTrackRecording?
}

private struct MusicBrainzTrackRecording: Decodable {
    let id: String?
    let title: String?
}

private struct ITunesSearchResponse: Decodable {
    let results: [ITunesTrack]
}

private struct ITunesTrack: Decodable {
    let wrapperType: String?
    let collectionID: Int?
    let trackID: Int?
    let trackName: String?
    let artistName: String?
    let collectionName: String?
    let trackNumber: Int?
    let discNumber: Int?
    let primaryGenreName: String?
    let releaseDate: String?
    let artworkURL100: String?

    enum CodingKeys: String, CodingKey {
        case wrapperType
        case collectionID = "collectionId"
        case trackID = "trackId"
        case trackName
        case artistName
        case collectionName
        case trackNumber
        case discNumber
        case primaryGenreName
        case releaseDate
        case artworkURL100 = "artworkUrl100"
    }
}
