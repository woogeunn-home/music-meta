import Foundation
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class AppViewModel: ObservableObject {
    @Published var items: [PreviewItem] = []
    @Published var albumGroups: [AlbumGroup] = []
    @Published var selectedAlbumGroupID: AlbumGroup.ID?
    @Published var selectedItemID: PreviewItem.ID?
    @Published var renameEnabled = false
    @Published var filenamePattern = "{artist} - {title}"
    @Published var isWorking = false
    @Published var status = "MP3 파일이나 폴더를 여기에 드롭하세요."
    @Published var searchQuery = ""
    @Published var searchCandidates: [TrackMetadata] = []
    @Published var showingCandidatePicker = false
    @Published var errorMessage: String?
    @Published var detailArtworkData: Data?
    @Published var isLoadingArtwork = false

    private let providers = MetadataProviderChain()
    private var artworkCache: [URL: Data] = [:]
    private let minimumTrackScore = 0.58
    private let minimumAlbumScore = 0.62

    var selectedItem: PreviewItem? {
        guard let selectedIndex else { return nil }
        return items[selectedIndex]
    }

    var selectedAlbumGroup: AlbumGroup? {
        guard let selectedAlbumGroupID else { return albumGroups.first }
        return albumGroups.first { $0.id == selectedAlbumGroupID }
    }

    func handleDrop(providers itemProviders: [NSItemProvider]) -> Bool {
        for provider in itemProviders where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { [weak self] item, _ in
                guard let self else { return }
                let url = Self.url(from: item)
                Task { @MainActor in
                    guard let url else { return }
                    await self.analyze(urls: [url])
                }
            }
        }
        return true
    }

    func analyze(urls: [URL]) async {
        let collected = collectMP3Entries(from: urls)
        let files = collected.groups.flatMap(\.files) + collected.looseFiles
        guard !files.isEmpty else {
            errorMessage = AppError.noMP3Files.localizedDescription
            return
        }

        isWorking = true
        status = "\(files.count)개 파일 분석 중..."
        albumGroups = []
        items = files.map {
            let guess = MP3Metadata.readGuess(from: $0)
            return PreviewItem(fileURL: $0, query: guess.query, candidates: [], selected: nil, score: 0, status: .pending)
        }
        albumGroups = collected.groups.map { group in
            AlbumGroup(
                folderURL: group.folderURL,
                albumTitle: group.folderURL.lastPathComponent,
                albumSearchTerm: group.folderURL.lastPathComponent,
                itemIDs: group.files.compactMap { file in items.first { $0.fileURL == file }?.id }
            )
        }
        selectedAlbumGroupID = albumGroups.first?.id

        for group in albumGroups {
            await searchAlbums(groupID: group.id, autoApplyBest: true)
        }

        for index in items.indices where items[index].selected == nil {
            await searchTrack(index: index)
        }
        applyAlbumGroupsToChildren()

        status = "\(files.count)개 파일 분석 완료"
        if selectedItemID == nil {
            selectedItemID = itemsForSelectedAlbumGroup().first?.id ?? items.first?.id
            await loadArtworkForSelectedItem()
        }
        isWorking = false
    }

    func beginResearch() {
        guard let index = selectedIndex else { return }
        searchQuery = items[index].query
        searchCandidates = items[index].candidates
        showingCandidatePicker = true
    }

    func researchSelectedItem() async {
        guard let index = selectedIndex else { return }
        isWorking = true
        status = "재검색 중: \(searchQuery)"
        let candidates = await providers.search(term: searchQuery, limit: 12)
        items[index].query = searchQuery
        items[index].candidates = highConfidenceTracks(guess: MP3Metadata.readGuess(from: items[index].fileURL), candidates: candidates)
        searchCandidates = items[index].candidates
        status = candidates.isEmpty ? "재검색 완료: 후보 없음" : "재검색 완료"
        isWorking = false
    }

    func choose(candidate: TrackMetadata) {
        guard let index = selectedIndex else { return }
        let guess = MP3Metadata.readGuess(from: items[index].fileURL)
        let selected = trackWithAlbumOverride(candidate, for: items[index].id)
        items[index].selected = selected
        items[index].score = score(guess: guess, track: selected)
        items[index].status = .matched
        showingCandidatePicker = false
        Task { await loadArtworkForSelectedItem() }
    }

    func items(in group: AlbumGroup) -> [PreviewItem] {
        group.itemIDs.compactMap { id in items.first { $0.id == id } }
    }

    func itemsForSelectedAlbumGroup() -> [PreviewItem] {
        if let group = selectedAlbumGroup {
            return items(in: group)
        }
        return looseItems()
    }

    func looseItems() -> [PreviewItem] {
        let groupedIDs = Set(albumGroups.flatMap(\.itemIDs))
        return items.filter { !groupedIDs.contains($0.id) }
    }

    func albumSearchTermBinding(for group: AlbumGroup) -> Binding<String> {
        Binding(
            get: { self.albumGroups.first { $0.id == group.id }?.albumSearchTerm ?? group.albumSearchTerm },
            set: { newValue in self.updateAlbumSearchTerm(groupID: group.id, searchTerm: newValue) }
        )
    }

    func updateAlbumSearchTerm(groupID: AlbumGroup.ID, searchTerm: String) {
        guard let groupIndex = albumGroups.firstIndex(where: { $0.id == groupID }) else { return }
        albumGroups[groupIndex].albumSearchTerm = searchTerm
    }

    func selectAlbumGroup(_ group: AlbumGroup) {
        selectedAlbumGroupID = group.id
        selectedItemID = items(in: group).first?.id
        Task { await loadArtworkForSelectedItem() }
    }

    func searchAlbumsForSelectedGroup() async {
        guard let groupID = selectedAlbumGroup?.id else { return }
        isWorking = true
        status = "앨범 후보 검색 중..."
        let count = await searchAlbums(groupID: groupID, autoApplyBest: false)
        status = count == 0 ? "앨범 후보 검색 완료: 후보 없음" : "앨범 후보 검색 완료: \(count)개"
        isWorking = false
    }

    func apply(album: AlbumMetadata, to groupID: AlbumGroup.ID) {
        guard let groupIndex = albumGroups.firstIndex(where: { $0.id == groupID }) else { return }
        albumGroups[groupIndex].selectedAlbum = album
        albumGroups[groupIndex].albumTitle = album.title

        let group = albumGroups[groupIndex]
        let groupItems = items(in: group).sorted { $0.fileURL.lastPathComponent.localizedStandardCompare($1.fileURL.lastPathComponent) == .orderedAscending }
        let albumTracks = album.tracks.sorted { ($0.discNumber ?? 1, $0.trackNumber ?? 0) < ($1.discNumber ?? 1, $1.trackNumber ?? 0) }

        for (offset, item) in groupItems.enumerated() {
            guard let itemIndex = items.firstIndex(where: { $0.id == item.id }) else { continue }
            let filenameNumber = leadingTrackNumber(from: item.fileURL)
            let matchedTrack = filenameNumber.flatMap { number in
                albumTracks.first { $0.trackNumber == number }
            } ?? (offset < albumTracks.count ? albumTracks[offset] : nil)

            guard var track = matchedTrack else { continue }
            track.source = album.source
            track.album = album.title
            track.albumArtist = album.artist
            track.genre = track.genre ?? album.genre
            track.releaseDate = track.releaseDate ?? album.releaseDate
            track.artworkURL = album.artworkURL ?? track.artworkURL

            var candidates = items[itemIndex].candidates
            if !candidates.contains(track) {
                candidates.insert(track, at: 0)
            }
            items[itemIndex].candidates = candidates
            items[itemIndex].selected = track
            items[itemIndex].score = 1
            items[itemIndex].status = .matched
        }

        if selectedAlbumGroupID == groupID, selectedItemID == nil {
            selectedItemID = items(in: group).first?.id
        }
        Task { await loadArtworkForSelectedItem() }
    }

    func loadArtworkForSelectedItem() async {
        guard let item = selectedItem, let track = item.selected else {
            detailArtworkData = nil
            isLoadingArtwork = false
            return
        }

        let selectedID = item.id
        detailArtworkData = nil
        isLoadingArtwork = true
        let artwork = await artwork(for: track, itemID: item.id)
        guard selectedItemID == selectedID else { return }
        detailArtworkData = artwork
        isLoadingArtwork = false
    }

    func save() async {
        let editable = items.indices.filter { items[$0].selected != nil }
        guard !editable.isEmpty else { return }

        isWorking = true
        status = "\(editable.count)개 파일 저장 중..."

        for index in editable {
            guard let track = items[index].selected else { continue }
            do {
                let artwork = await artwork(for: track, itemID: items[index].id)
                try MP3Metadata.write(track: track, artwork: artwork, to: items[index].fileURL)

                if renameEnabled {
                    let target = FilenameRules.targetURL(
                        for: items[index].fileURL,
                        track: track,
                        pattern: filenamePattern
                    )
                    if target != items[index].fileURL {
                        try FileManager.default.moveItem(at: items[index].fileURL, to: target)
                        items[index].fileURL = target
                    }
                }

                items[index].status = .saved
            } catch {
                items[index].status = .failed
                errorMessage = error.localizedDescription
            }
        }

        status = "저장 완료"
        isWorking = false
    }

    func proposedFileName(for item: PreviewItem) -> String {
        guard renameEnabled, let selected = item.selected else { return "" }
        return FilenameRules.targetURL(for: item.fileURL, track: selected, pattern: filenamePattern).lastPathComponent
    }

    func select(_ item: PreviewItem) {
        selectedItemID = item.id
    }

    private var selectedIndex: Int? {
        guard let selectedItemID else { return nil }
        return items.firstIndex { $0.id == selectedItemID }
    }

    private func collectMP3Entries(from urls: [URL]) -> (groups: [(folderURL: URL, files: [URL])], looseFiles: [URL]) {
        var groups: [(folderURL: URL, files: [URL])] = []
        var looseFiles: [URL] = []
        for url in urls {
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
                var files: [URL] = []
                let children = FileManager.default.enumerator(
                    at: url,
                    includingPropertiesForKeys: [.isRegularFileKey],
                    options: [.skipsHiddenFiles]
                )
                while let child = children?.nextObject() as? URL {
                    if child.pathExtension.lowercased() == "mp3" {
                        files.append(child)
                    }
                }
                if !files.isEmpty {
                    groups.append((url, files.sorted { $0.path < $1.path }))
                }
            } else if url.pathExtension.lowercased() == "mp3" {
                looseFiles.append(url)
            }
        }
        return (groups, looseFiles.sorted { $0.lastPathComponent < $1.lastPathComponent })
    }

    private func bestMatch(guess: TrackGuess, candidates: [TrackMetadata]) -> TrackMetadata? {
        highConfidenceTracks(guess: guess, candidates: candidates)
            .max { score(guess: guess, track: $0) < score(guess: guess, track: $1) }
    }

    private func searchTrack(index: Int) async {
        let guess = MP3Metadata.readGuess(from: items[index].fileURL)
        let candidates = await providers.search(term: guess.query)
        let filteredCandidates = highConfidenceTracks(guess: guess, candidates: candidates)
        let selected = bestMatch(guess: guess, candidates: candidates)
        items[index].query = guess.query
        items[index].candidates = filteredCandidates
        items[index].selected = selected
        items[index].score = selected.map { score(guess: guess, track: $0) } ?? 0
        items[index].status = selected == nil ? .noMatch : .matched
    }

    @discardableResult
    private func searchAlbums(groupID: AlbumGroup.ID, autoApplyBest: Bool) async -> Int {
        guard let groupIndex = albumGroups.firstIndex(where: { $0.id == groupID }) else { return 0 }
        let term = albumGroups[groupIndex].albumSearchTerm
        var candidates: [AlbumMetadata] = []
        for query in albumSearchQueries(from: term) {
            candidates.append(contentsOf: await providers.searchAlbums(term: query, limit: 6))
        }
        let filteredCandidates = highConfidenceAlbums(group: albumGroups[groupIndex], candidates: candidates)
        albumGroups[groupIndex].albumCandidates = filteredCandidates

        if autoApplyBest, let best = bestAlbumMatch(group: albumGroups[groupIndex], candidates: filteredCandidates) {
            apply(album: best, to: groupID)
        }
        return filteredCandidates.count
    }

    private func bestAlbumMatch(group: AlbumGroup, candidates: [AlbumMetadata]) -> AlbumMetadata? {
        candidates.max { albumScore(group: group, album: $0) < albumScore(group: group, album: $1) }
    }

    private func albumScore(group: AlbumGroup, album: AlbumMetadata) -> Double {
        let normalizedTerm = normalizedSearchText(group.albumSearchTerm)
        let albumTitle = normalizedSearchText(album.title)
        let albumArtist = normalizedSearchText(album.artist)
        let combinedAlbum = normalizedSearchText("\(album.artist) \(album.title) \(album.year ?? "")")

        let titleScore = max(
            normalizedSimilarity(group.folderName, album.title),
            normalizedSimilarity(normalizedTerm, combinedAlbum),
            normalizedTerm.contains(albumTitle) || albumTitle.contains(normalizedTerm) ? 0.96 : 0
        )
        let artistScore = albumArtist.isEmpty ? 0 : (normalizedTerm.contains(albumArtist) ? 1 : normalizedSimilarity(normalizedTerm, album.artist))
        let trackCountScore = album.tracks.isEmpty ? 0 : max(0, 1 - abs(Double(album.tracks.count - group.itemIDs.count)) / Double(max(album.tracks.count, group.itemIDs.count)))
        let sourceBoost = album.source == "iTunes" ? 0.12 : 0
        return titleScore * 0.50 + artistScore * 0.18 + trackCountScore * 0.32 + sourceBoost
    }

    private func score(guess: TrackGuess, track: TrackMetadata) -> Double {
        normalizedSimilarity(guess.title, track.title) * 0.55
            + normalizedSimilarity(guess.artist, track.artist) * 0.35
            + normalizedSimilarity(guess.album, track.album) * 0.10
    }

    private func applyAlbumGroupsToChildren() {
        for group in albumGroups {
            let itemIDs = Set(group.itemIDs)
            for index in items.indices where itemIDs.contains(items[index].id) {
                guard var track = items[index].selected else { continue }
                track.album = group.albumTitle
                if let album = group.selectedAlbum {
                    track.album = album.title
                    track.albumArtist = album.artist
                    track.genre = track.genre ?? album.genre
                    track.releaseDate = track.releaseDate ?? album.releaseDate
                    track.artworkURL = album.artworkURL ?? track.artworkURL
                }
                items[index].selected = track
            }
        }
    }

    private func trackWithAlbumOverride(_ track: TrackMetadata, for itemID: PreviewItem.ID) -> TrackMetadata {
        guard let group = albumGroups.first(where: { $0.itemIDs.contains(itemID) }) else {
            return track
        }
        var copy = track
        copy.album = group.albumTitle
        if let album = group.selectedAlbum {
            copy.album = album.title
            copy.albumArtist = album.artist
            copy.genre = copy.genre ?? album.genre
            copy.releaseDate = copy.releaseDate ?? album.releaseDate
            copy.artworkURL = album.artworkURL ?? copy.artworkURL
        }
        return copy
    }

    private func highConfidenceTracks(guess: TrackGuess, candidates: [TrackMetadata]) -> [TrackMetadata] {
        candidates
            .filter { score(guess: guess, track: $0) >= minimumTrackScore }
            .sorted { score(guess: guess, track: $0) > score(guess: guess, track: $1) }
    }

    private func highConfidenceAlbums(group: AlbumGroup, candidates: [AlbumMetadata]) -> [AlbumMetadata] {
        var seen = Set<String>()
        let deduped = candidates
            .filter { album in
                let trackCountIsPlausible = album.tracks.isEmpty == false
                    && abs(album.tracks.count - group.itemIDs.count) <= max(4, group.itemIDs.count / 2)
                return trackCountIsPlausible
            }
            .filter { album in
                let key = "\(album.source)|\(album.title.lowercased())|\(album.artist.lowercased())|\(album.year ?? "")"
                guard !seen.contains(key) else { return false }
                seen.insert(key)
                return true
            }
            .sorted { albumScore(group: group, album: $0) > albumScore(group: group, album: $1) }

        let strict = deduped.filter { albumScore(group: group, album: $0) >= minimumAlbumScore }
        if strict.isEmpty {
            return Array(deduped.prefix(5))
        }
        return Array(strict.prefix(8))
    }

    private func albumSearchQueries(from term: String) -> [String] {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        let withoutParentheses = trimmed.replacingOccurrences(of: #"\([^)]*\)"#, with: "", options: .regularExpression)
        let plain = normalizedSearchText(withoutParentheses)
        let dashParts = withoutParentheses
            .split(separator: "-", maxSplits: 1)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }

        var queries = [trimmed, withoutParentheses, plain]
        if dashParts.count == 2 {
            queries.append("\(dashParts[0]) \(dashParts[1])")
            queries.append("\(dashParts[1]) \(dashParts[0])")
        }
        return queries
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .reduce(into: []) { result, query in
                if !result.contains(query) {
                    result.append(query)
                }
            }
    }

    private func normalizedSearchText(_ value: String) -> String {
        value
            .lowercased()
            .replacingOccurrences(of: #"\([^)]*\)"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"(^|\s)\d{1,3}\s*[-._)]\s*"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"[^a-z0-9가-힣]+"#, with: " ", options: .regularExpression)
            .split(separator: " ")
            .joined(separator: " ")
    }

    private func normalizedSimilarity(_ left: String?, _ right: String?) -> Double {
        similarity(left.map(normalizedSearchText), right.map(normalizedSearchText))
    }

    private func artwork(for track: TrackMetadata, itemID: PreviewItem.ID) async -> Data? {
        let sharedArtworkURL = albumGroups
            .first { $0.itemIDs.contains(itemID) }?
            .selectedAlbum?
            .artworkURL
        let artworkURL = sharedArtworkURL ?? track.artworkURL
        guard let artworkURL else { return nil }
        if let cached = artworkCache[artworkURL] {
            return cached
        }
        var trackForArtwork = track
        trackForArtwork.artworkURL = artworkURL
        let data = await providers.artwork(for: trackForArtwork)
        if let data {
            artworkCache[artworkURL] = data
        }
        return data
    }

    private func leadingTrackNumber(from url: URL) -> Int? {
        let name = url.deletingPathExtension().lastPathComponent
        let digits = name.prefix { $0.isNumber }
        guard !digits.isEmpty else { return nil }
        return Int(digits)
    }

    private func similarity(_ left: String?, _ right: String?) -> Double {
        guard let left, let right, !left.isEmpty, !right.isEmpty else { return 0 }
        let a = Array(left.lowercased())
        let b = Array(right.lowercased())
        guard !a.isEmpty, !b.isEmpty else { return 0 }

        var previous = Array(0...b.count)
        var current = Array(repeating: 0, count: b.count + 1)

        for i in 1...a.count {
            current[0] = i
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
            }
            swap(&previous, &current)
        }

        let distance = previous[b.count]
        return 1 - Double(distance) / Double(max(a.count, b.count))
    }

    nonisolated private static func url(from item: NSSecureCoding?) -> URL? {
        if let url = item as? URL {
            return url
        }
        if let data = item as? Data {
            return URL(dataRepresentation: data, relativeTo: nil)
        }
        return nil
    }
}
