import SwiftUI
import UniformTypeIdentifiers
import AppKit

struct ContentView: View {
    @StateObject private var model = AppViewModel()
    @State private var isDropTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            contentArea
            statusBar
        }
        .frame(minWidth: 1200, minHeight: 700)
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [10, 6]))
                    .padding(8)
                    .allowsHitTesting(false)
            }
        }
        .onDrop(of: [UTType.fileURL], isTargeted: $isDropTargeted, perform: model.handleDrop)
        .onChange(of: model.selectedItemID) {
            Task { await model.loadArtworkForSelectedItem() }
        }
        .alert("알림", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("확인", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
        .sheet(isPresented: $model.showingCandidatePicker) {
            CandidatePicker(model: model)
        }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            Text("MusicMeta")
                .font(.headline)

            Text("MP3 파일이나 폴더를 창 어디에나 드롭")
                .font(.caption)
                .foregroundStyle(.secondary)

            Divider()
                .frame(height: 22)

            Button("재검색") {
                model.beginResearch()
            }
            .disabled(model.selectedItemID == nil || model.isWorking)

            Button("저장") {
                Task { await model.save() }
            }
            .keyboardShortcut("s", modifiers: [.command])
            .disabled(model.items.isEmpty || model.isWorking)

            Divider()
                .frame(height: 22)

            Toggle("Advanced: 파일명 변경", isOn: $model.renameEnabled)
                .toggleStyle(.checkbox)

            TextField("파일명 패턴", text: $model.filenamePattern)
                .textFieldStyle(.roundedBorder)
                .frame(width: 280)
                .disabled(!model.renameEnabled)

            Spacer()

            if model.isWorking {
                ProgressView()
                    .scaleEffect(0.8)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var contentArea: some View {
        HSplitView {
            AlbumSidebar(model: model)
                .frame(minWidth: 240, idealWidth: 300, maxWidth: 460)
                .clipped()

            table
                .frame(minWidth: 420, idealWidth: 720, maxWidth: .infinity)
                .clipped()

            DetailPanel(model: model)
                .frame(minWidth: 300, idealWidth: 380, maxWidth: 620)
                .clipped()
        }
    }

    private var table: some View {
        Table(model.itemsForSelectedAlbumGroup(), selection: $model.selectedItemID) {
            TableColumn("파일") { item in
                HStack(spacing: 6) {
                    Image(systemName: "music.note")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(item.fileName)
                        .lineLimit(1)
                }
            }
            .width(min: 210, ideal: 260)

            TableColumn("적용될 메타데이터") { item in
                if let selected = item.selected {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(selected.artist) - \(selected.title)")
                            .lineLimit(1)
                        Text(selected.album ?? "Unknown Album")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                } else {
                    Text(item.status.rawValue)
                        .foregroundStyle(.secondary)
                }
            }
            .width(min: 220, ideal: 320)

            TableColumn("출처") { item in
                Text(item.selected?.source ?? "")
            }
            .width(80)

            TableColumn("점수") { item in
                Text(item.selected == nil ? "" : "\(Int(item.score * 100))%")
            }
            .width(58)

            TableColumn("새 파일명") { item in
                Text(model.proposedFileName(for: item))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .width(min: 150, ideal: 210)

            TableColumn("상태") { item in
                Text(item.status.rawValue)
            }
            .width(70)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
    }

    private var statusBar: some View {
        HStack {
            Text(model.status)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.thinMaterial)
    }
}

private struct AlbumSidebar: View {
    @ObservedObject var model: AppViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("앨범")
                    .font(.headline)
                Spacer()
                if model.isWorking {
                    ProgressView()
                        .scaleEffect(0.7)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if model.albumGroups.isEmpty {
                        Text("폴더를 드롭하면 앨범 단위로 후보를 관리할 수 있어요.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .padding(14)
                    } else {
                        ForEach(model.albumGroups) { group in
                            AlbumSidebarRow(
                                group: group,
                                isSelected: model.selectedAlbumGroup?.id == group.id,
                                albumSearchTerm: model.albumSearchTermBinding(for: group),
                                onSelect: { model.selectAlbumGroup(group) },
                                onSearch: { Task { await model.searchAlbumsForSelectedGroup() } },
                                onApply: { model.apply(album: $0, to: group.id) }
                            )
                        }
                    }
                }
                .padding(10)
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .clipped()
    }
}

private struct AlbumSidebarRow: View {
    let group: AlbumGroup
    let isSelected: Bool
    @Binding var albumSearchTerm: String
    let onSelect: () -> Void
    let onSearch: () -> Void
    let onApply: (AlbumMetadata) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                onSelect()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "folder")
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(group.folderName)
                            .font(.callout.weight(.semibold))
                            .lineLimit(1)
                        Text("\(group.itemIDs.count)곡")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isSelected {
                VStack(alignment: .leading, spacing: 8) {
                    TextField("앨범 검색 키워드", text: $albumSearchTerm)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: .infinity)

                    Text("앨범명, 아티스트, 연도 조합 가능")
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    Button("앨범 후보 재검색") {
                        onSearch()
                    }
                    .controlSize(.small)

                    if group.albumCandidates.isEmpty {
                        Text("앨범 후보가 아직 없습니다.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(group.albumCandidates) { album in
                            AlbumCandidateCard(
                                album: album,
                                isSelected: group.selectedAlbum?.id == album.id && group.selectedAlbum?.source == album.source,
                                onApply: { onApply(album) }
                            )
                        }
                    }
                }
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isSelected ? Color.accentColor.opacity(0.12) : Color(nsColor: .windowBackgroundColor))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(isSelected ? Color.accentColor.opacity(0.5) : Color(nsColor: .separatorColor), lineWidth: 1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .clipped()
    }
}

private struct AlbumCandidateCard: View {
    let album: AlbumMetadata
    let isSelected: Bool
    let onApply: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(album.title)
                        .font(.caption.weight(.semibold))
                        .lineLimit(2)
                    Text(album.artist)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 6)
                if isSelected {
                    Text("적용됨")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.blue)
                } else {
                    Button("적용") {
                        onApply()
                    }
                    .controlSize(.mini)
                }
            }

            HStack(spacing: 8) {
                Text(album.source)
                Text(album.year ?? "-")
                Text("\(album.tracks.count)곡")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? Color.accentColor.opacity(0.10) : Color(nsColor: .controlBackgroundColor))
        )
    }
}

private struct CandidatePicker: View {
    @ObservedObject var model: AppViewModel

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                TextField("검색어", text: $model.searchQuery)
                    .textFieldStyle(.roundedBorder)
                Button("검색") {
                    Task { await model.researchSelectedItem() }
                }
                .disabled(model.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.isWorking)
            }

            List(model.searchCandidates, id: \.self) { candidate in
                Button {
                    model.choose(candidate: candidate)
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("\(candidate.artist) - \(candidate.title)")
                                .foregroundStyle(.primary)
                            Text(candidate.album ?? "Unknown Album")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(candidate.source)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            HStack {
                Spacer()
                Button("닫기") {
                    model.showingCandidatePicker = false
                }
                .keyboardShortcut(.cancelAction)
            }
        }
        .padding(16)
        .frame(width: 760, height: 430)
    }
}

private struct TreeHeader: View {
    var body: some View {
        HStack(spacing: 0) {
            Text("파일")
                .frame(width: 260, alignment: .leading)
            Text("적용될 메타데이터")
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("출처")
                .frame(width: 100, alignment: .leading)
            Text("점수")
                .frame(width: 70, alignment: .leading)
            Text("새 파일명")
                .frame(width: 210, alignment: .leading)
            Text("상태")
                .frame(width: 80, alignment: .leading)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color(nsColor: .controlBackgroundColor))
    }
}

private struct AlbumGroupRow: View {
    let group: AlbumGroup
    @Binding var albumTitle: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "folder")
                .foregroundStyle(.secondary)
            Text(group.folderName)
                .font(.callout.weight(.semibold))
                .lineLimit(1)
                .frame(width: 200, alignment: .leading)

            Text("앨범")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("앨범명", text: $albumTitle)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 360)

            Spacer()

            Text("\(group.itemIDs.count)곡")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color(nsColor: .underPageBackgroundColor))
    }
}

private struct TrackTreeRow: View {
    let item: PreviewItem
    let isSelected: Bool
    let proposedFileName: String
    let onSelect: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "music.note")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(item.fileName)
                    .lineLimit(1)
            }
            .frame(width: 260, alignment: .leading)

            metadataView
                .frame(maxWidth: .infinity, alignment: .leading)

            Text(item.selected?.source ?? "")
                .frame(width: 100, alignment: .leading)

            Text(item.selected == nil ? "" : "\(Int(item.score * 100))%")
                .frame(width: 70, alignment: .leading)

            Text(proposedFileName)
                .lineLimit(1)
                .foregroundStyle(.secondary)
                .frame(width: 210, alignment: .leading)

            Text(item.status.rawValue)
                .frame(width: 80, alignment: .leading)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 7)
        .background(isSelected ? Color.accentColor.opacity(0.25) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture {
            onSelect()
        }
    }

    @ViewBuilder
    private var metadataView: some View {
        if let selected = item.selected {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(selected.artist) - \(selected.title)")
                    .lineLimit(1)
                Text(selected.album ?? "Unknown Album")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        } else {
            Text(item.status.rawValue)
                .foregroundStyle(.secondary)
        }
    }
}

private struct DetailPanel: View {
    @ObservedObject var model: AppViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let item = model.selectedItem {
                    artworkView

                    if let track = item.selected {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(track.title)
                                .font(.title3.weight(.semibold))
                                .lineLimit(2)
                            Text(track.artist)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }

                        DetailSection(title: "메타데이터") {
                            DetailRow(label: "앨범", value: track.album)
                            DetailRow(label: "앨범 아티스트", value: track.albumArtist)
                            DetailRow(label: "연도", value: track.year)
                            DetailRow(label: "장르", value: track.genre)
                            DetailRow(label: "트랙", value: track.trackNumber.map(String.init))
                            DetailRow(label: "디스크", value: track.discNumber.map(String.init))
                            DetailRow(label: "ISRC", value: track.isrc)
                            DetailRow(label: "출처", value: track.source)
                        }
                    } else {
                        emptyDetail(title: "매칭 결과 없음", message: "재검색으로 검색어를 수정하고 후보를 선택하세요.")
                    }
                } else {
                    emptyDetail(title: "선택된 파일 없음", message: "가운데 목록에서 파일을 선택하면 세부 메타데이터가 표시됩니다.")
                }
            }
            .padding(16)
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    @ViewBuilder
    private var artworkView: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(nsColor: .windowBackgroundColor))
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                }

            if let data = model.detailArtworkData, let image = NSImage(data: data) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } else if model.isLoadingArtwork {
                ProgressView()
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "music.note")
                        .font(.system(size: 34))
                        .foregroundStyle(.secondary)
                    Text("커버 없음")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .aspectRatio(1, contentMode: .fit)
    }

    private func emptyDetail(title: String, message: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
            Text(message)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 20)
    }

    private func comparisonCandidates(for item: PreviewItem) -> [(String, [TrackMetadata])] {
        let grouped = Dictionary(grouping: item.candidates, by: \.source)
        return ["iTunes", "MusicBrainz"]
            .compactMap { source in
                guard let candidates = grouped[source], !candidates.isEmpty else { return nil }
                return (source, Array(candidates.prefix(3)))
            }
    }
}

private struct CandidateComparison: View {
    let candidates: [(String, [TrackMetadata])]
    let selected: TrackMetadata
    let onChoose: (TrackMetadata) -> Void

    var body: some View {
        if !candidates.isEmpty {
            DetailSection(title: "후보 비교") {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(candidates, id: \.0) { source, tracks in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(source)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)

                            ForEach(tracks, id: \.self) { track in
                                CandidateCard(
                                    track: track,
                                    isSelected: track == selected,
                                    onChoose: { onChoose(track) }
                                )
                            }
                        }
                    }
                }
            }
        }
    }
}

private struct CandidateCard: View {
    let track: TrackMetadata
    let isSelected: Bool
    let onChoose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(track.title)
                        .font(.callout.weight(.semibold))
                        .lineLimit(2)
                    Text(track.artist)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                if isSelected {
                    Text("적용됨")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.blue)
                } else {
                    Button("적용") {
                        onChoose()
                    }
                    .controlSize(.small)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                CompactMetadata(label: "앨범", value: track.album)
                CompactMetadata(label: "앨범 아티스트", value: track.albumArtist)
                CompactMetadata(label: "연도", value: track.year)
                CompactMetadata(label: "장르", value: track.genre)
                CompactMetadata(label: "트랙", value: track.trackNumber.map(String.init))
                CompactMetadata(label: "디스크", value: track.discNumber.map(String.init))
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isSelected ? Color.accentColor.opacity(0.12) : Color(nsColor: .windowBackgroundColor))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(isSelected ? Color.accentColor.opacity(0.55) : Color(nsColor: .separatorColor), lineWidth: 1)
        }
    }
}

private struct CompactMetadata: View {
    let label: String
    let value: String?

    var body: some View {
        if let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(label)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(width: 64, alignment: .leading)
                Text(value)
                    .font(.caption)
                    .lineLimit(2)
            }
        }
    }
}

private struct DetailSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
            VStack(alignment: .leading, spacing: 7) {
                content
            }
        }
    }
}

private struct DetailRow: View {
    let label: String
    let value: String?
    var placeholder = "-"

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(displayValue)
                .font(.callout)
                .textSelection(.enabled)
                .lineLimit(label == "경로" ? 4 : 2)
        }
    }

    private var displayValue: String {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return placeholder
        }
        return value
    }
}
