import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - 왼쪽 목록의 한 줄

enum MusicRailItem: Hashable {
    case search
    case likes
    case recent
    case localLibrary
    case playlist(UUID)
}

// MARK: - 화면

/// 음악 탭 전체.
///
/// Spotify·Apple Music의 골격을 그대로 쓴다 — 왼쪽에 보관함, 가운데에 내용, 아래에
/// 플레이어. 앱의 바깥 사이드바가 이미 있으므로 안쪽 목록은 좁게 두고, 플레이어 막대는
/// 이 탭의 아래에 붙어 어느 목록을 보고 있든 같은 자리에 있는다.
struct MusicView: View {
    @ObservedObject var controller: AutomationController
    @State private var rail: MusicRailItem = .search
    @State private var showsQueue = true
    @State private var newPlaylistName = ""
    @State private var isNamingPlaylist = false
    @State private var isImporting = false
    @State private var importText = ""

    private var model: MusicPlayerModel { controller.music }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                MusicRail(
                    model: model,
                    selection: $rail,
                    newPlaylist: { isNamingPlaylist = true },
                    importPlaylist: { isImporting = true }
                )
                .frame(width: 208)
                Divider()
                MusicContent(model: model, rail: $rail)
                    .frame(maxWidth: .infinity)
                if showsQueue {
                    Divider()
                    MusicQueuePanel(model: model).frame(width: 300)
                }
            }
            .frame(maxHeight: .infinity)
            Divider()
            MusicPlayerBar(model: model, showsQueue: $showsQueue)
        }
        .background { CrestWatermark() }
        .navigationTitle(AppSection.music.title)
        .sheet(isPresented: $isNamingPlaylist) {
            NamePlaylistSheet(name: $newPlaylistName) { name in
                let playlist = model.createPlaylist(named: name)
                rail = .playlist(playlist.id)
            }
        }
        .sheet(isPresented: $isImporting) {
            ImportPlaylistSheet(model: model, text: $importText)
        }
        // 눌러서 알린 말은 잠깐만 있는다. 계속 남아 있으면 다음에 무엇을 했는지와
        // 섞여 읽히기 때문이다.
        .overlay(alignment: .top) { MusicNoticeBanner(model: model) }
    }
}

// MARK: - 왼쪽 보관함

private struct MusicRail: View {
    @ObservedObject var model: MusicPlayerModel
    @Binding var selection: MusicRailItem
    let newPlaylist: () -> Void
    let importPlaylist: () -> Void
    @State private var renaming: UUID?
    @State private var renameText = ""

    var body: some View {
        List(selection: $selection) {
            Section {
                Label("검색", systemImage: "magnifyingglass").tag(MusicRailItem.search)
                Label("좋아요", systemImage: "heart").tag(MusicRailItem.likes)
                    .badge(model.library.likedIDs.count)
                Label("최근 재생", systemImage: "clock.arrow.circlepath").tag(MusicRailItem.recent)
                Label("내 음악", systemImage: "internaldrive").tag(MusicRailItem.localLibrary)
                    .badge(model.localTrackCount)
            }
            Section("플레이리스트") {
                ForEach(model.library.playlists) { playlist in
                    Label(playlist.name, systemImage: playlist.importedFrom == nil ? "music.note.list" : "square.and.arrow.down.on.square")
                        .tag(MusicRailItem.playlist(playlist.id))
                        .badge(playlist.trackIDs.count)
                        .contextMenu {
                            Button("이름 바꾸기") {
                                renameText = playlist.name
                                renaming = playlist.id
                            }
                            Button("전체 재생") {
                                model.play(model.library.tracks(playlist.trackIDs), startingAt: 0, shuffled: false)
                            }
                            Button("셔플 재생") {
                                let tracks = model.library.tracks(playlist.trackIDs)
                                model.play(tracks, startingAt: Int.random(in: 0..<max(1, tracks.count)), shuffled: true)
                            }
                            Divider()
                            Button("삭제", role: .destructive) {
                                if selection == .playlist(playlist.id) { selection = .search }
                                model.deletePlaylist(playlist.id)
                            }
                        }
                }
                if model.library.playlists.isEmpty {
                    Text("아직 없습니다")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            HStack(spacing: Spacing.s) {
                Button("새 플레이리스트", systemImage: "plus", action: newPlaylist)
                Spacer()
                Button("가져오기", systemImage: "square.and.arrow.down", action: importPlaylist)
                    .help("YouTube 플레이리스트 주소를 붙여 넣어 가져옵니다")
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .padding(Spacing.s)
            .background(.bar)
        }
        .sheet(item: Binding(
            get: { renaming.map { RenameTarget(id: $0) } },
            set: { renaming = $0?.id }
        )) { target in
            NamePlaylistSheet(name: $renameText, title: "이름 바꾸기") { name in
                model.renamePlaylist(target.id, to: name)
            }
        }
    }

    private struct RenameTarget: Identifiable { let id: UUID }
}

// MARK: - 가운데

private struct MusicContent: View {
    @ObservedObject var model: MusicPlayerModel
    @Binding var rail: MusicRailItem

    var body: some View {
        switch rail {
        case .search:
            MusicSearchScreen(model: model)
        case .likes:
            MusicCollectionScreen(
                model: model,
                title: "좋아요",
                subtitle: "하트를 누른 곡이 새로 누른 순서대로 쌓입니다.",
                symbol: "heart.fill",
                tracks: model.library.likedTracks,
                emptyMessage: "아직 좋아요를 누른 곡이 없습니다."
            )
        case .recent:
            MusicCollectionScreen(
                model: model,
                title: "최근 재생",
                subtitle: "최근에 실제로 소리가 난 곡 \(MusicLibrary.recentLimit)곡까지 남습니다.",
                symbol: "clock.arrow.circlepath",
                tracks: model.library.recentTracks,
                emptyMessage: "아직 재생한 곡이 없습니다."
            )
        case .localLibrary:
            MusicLocalScreen(model: model)
        case .playlist(let id):
            if let playlist = model.library.playlists.first(where: { $0.id == id }) {
                MusicPlaylistScreen(model: model, playlist: playlist)
            } else {
                EmptyResults(symbol: "music.note.list", message: "플레이리스트를 찾지 못했습니다.")
            }
        }
    }
}

// MARK: - 검색

private struct MusicSearchScreen: View {
    @ObservedObject var model: MusicPlayerModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: Spacing.m) {
                HStack(spacing: Spacing.s) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("곡·아티스트, 또는 YouTube 주소", text: $model.query)
                        .textFieldStyle(.plain)
                        .font(.title3)
                        .onSubmit { model.runSearch() }
                    if !model.query.isEmpty {
                        Button("지우기", systemImage: "xmark.circle.fill") { model.query = "" }
                            .labelStyle(.iconOnly)
                            .buttonStyle(.borderless)
                            .foregroundStyle(.tertiary)
                    }
                    Button("검색") { model.runSearch() }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.query.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .padding(Spacing.m)
                .glassPanel(Radius.card)

                Picker("어디서", selection: $model.scope) {
                    ForEach(MusicSearchScope.allCases) { Text($0.korean).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .onChange(of: model.scope) { _, _ in
                    if !model.searchResults.isEmpty || model.searchError != nil { model.runSearch() }
                }

                Text(model.scope.explanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(Spacing.l)

            Divider()

            if model.scope == .youtube, !model.isYouTubeConfigured {
                MusicSetupNotice(model: model)
            } else if model.isSearching {
                VStack(spacing: Spacing.s) {
                    ProgressView()
                    Text("찾는 중…").font(.callout).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = model.searchError, model.searchResults.isEmpty {
                EmptyResults(symbol: "exclamationmark.magnifyingglass", message: error)
                    .frame(maxHeight: .infinity)
            } else if model.searchResults.isEmpty {
                EmptyResults(
                    symbol: "music.note",
                    message: "듣고 싶은 곡을 찾아보세요.\nYouTube에서 찾고, 소리는 광고 없는 음원으로 냅니다."
                )
                .frame(maxHeight: .infinity)
            } else {
                MusicTrackList(model: model, tracks: model.searchResults, context: .search)
            }
        }
    }
}

/// API 키가 없을 때. 무엇을 해야 하는지를 화면이 직접 말한다 — 이 앱의 다른 화면과
/// 같은 규칙이다.
private struct MusicSetupNotice: View {
    @ObservedObject var model: MusicPlayerModel
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(spacing: Spacing.m) {
            Image(systemName: "key.horizontal")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(.tertiary)
            Text("YouTube 검색에는 Data API 키가 필요합니다")
                .font(.headline)
            Text("Google Cloud 콘솔에서 YouTube Data API v3를 켜고 API 키를 만든 뒤,\n설정 › 음악에 넣으세요. 키는 코드가 아니라 이 Mac의 파일에만 저장됩니다.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            HStack {
                Button("설정 열기") {
                    model.requestSettingsTab?()
                    openSettings()
                }
                .buttonStyle(.borderedProminent)
                Button("키 없이 무료 음원 검색") { model.scope = .free }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(Spacing.xl)
    }
}

// MARK: - 좋아요·최근 재생

private struct MusicCollectionScreen: View {
    @ObservedObject var model: MusicPlayerModel
    let title: String
    let subtitle: String
    let symbol: String
    let tracks: [Track]
    let emptyMessage: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            MusicCollectionHeader(model: model, title: title, subtitle: subtitle, symbol: symbol, tracks: tracks)
            Divider()
            if tracks.isEmpty {
                EmptyResults(symbol: symbol, message: emptyMessage).frame(maxHeight: .infinity)
            } else {
                MusicTrackList(model: model, tracks: tracks, context: .collection(title))
            }
        }
    }
}

private struct MusicCollectionHeader: View {
    @ObservedObject var model: MusicPlayerModel
    let title: String
    let subtitle: String
    let symbol: String
    let tracks: [Track]
    var extra: AnyView? = nil

    private var unresolved: Int {
        tracks.filter { $0.asset == nil }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            HStack(alignment: .top, spacing: Spacing.m) {
                Image(systemName: symbol)
                    .font(.system(size: 34, weight: .light))
                    .foregroundStyle(Color.snuBlueLabel)
                    .frame(width: 64, height: 64)
                    .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text(title).font(.title2.weight(.semibold))
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                    Text("\(tracks.count)곡" + (unresolved > 0 ? " · 음원 미확인 \(unresolved)곡" : ""))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                Spacer()
            }
            HStack(spacing: Spacing.s) {
                Button("전체 재생", systemImage: "play.fill") {
                    model.play(tracks, startingAt: 0, shuffled: false)
                }
                .buttonStyle(.borderedProminent)
                .disabled(tracks.isEmpty)
                Button("셔플", systemImage: "shuffle") {
                    model.play(tracks, startingAt: Int.random(in: 0..<max(1, tracks.count)), shuffled: true)
                }
                .disabled(tracks.isEmpty)
                Button("대기열에 추가", systemImage: "text.badge.plus") { model.enqueue(tracks) }
                    .disabled(tracks.isEmpty)
                Spacer()
                if let status = model.resolveStatus, model.resolveStatus != nil {
                    Text(status).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Button("음원 찾기", systemImage: "waveform.badge.magnifyingglass") {
                    model.resolveMissing(in: tracks)
                }
                .disabled(unresolved == 0)
                .help("광고 없이 들을 수 있는 음원을 미리 찾아 둡니다")
                if let extra { extra }
            }
            .toolbarKeepsTitle()
        }
        .padding(Spacing.l)
    }
}

// MARK: - 플레이리스트

private struct MusicPlaylistScreen: View {
    @ObservedObject var model: MusicPlayerModel
    let playlist: MusicPlaylist

    private var tracks: [Track] { model.library.tracks(playlist.trackIDs) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            MusicCollectionHeader(
                model: model,
                title: playlist.name,
                subtitle: playlist.importedFrom.map {
                    "YouTube 플레이리스트에서 가져왔습니다 · \($0.importedAt.formatted(date: .abbreviated, time: .shortened))"
                } ?? "내가 만든 플레이리스트입니다.",
                symbol: "music.note.list",
                tracks: tracks
            )
            Divider()
            if tracks.isEmpty {
                EmptyResults(symbol: "music.note.list", message: "검색해서 곡을 넣어 보세요.")
                    .frame(maxHeight: .infinity)
            } else {
                MusicTrackList(model: model, tracks: tracks, context: .playlist(playlist.id))
            }
        }
    }
}

// MARK: - 내 음악

private struct MusicLocalScreen: View {
    @ObservedObject var model: MusicPlayerModel

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.l) {
            VStack(alignment: .leading, spacing: Spacing.s) {
                Text("내 음악")
                    .font(.title2.weight(.semibold))
                Text("이 Mac에 있는 음악 파일입니다. 네트워크가 필요 없고 광고가 없는 유일한 재생 소스이며, 곡의 음원을 찾을 때 언제나 여기부터 봅니다.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: Spacing.s) {
                ForEach(model.library.resolvedLocalFolders, id: \.path) { folder in
                    HStack {
                        Image(systemName: "folder").foregroundStyle(.secondary)
                        Text(folder.path).font(.callout).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button("Finder에서 보기", systemImage: "arrow.up.forward.app") {
                            NSWorkspace.shared.activateFileViewerSelecting([folder])
                        }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                        if model.library.localFolders.contains(folder.path) {
                            Button("빼기", systemImage: "minus.circle") {
                                model.removeLocalFolder(folder.path)
                            }
                            .labelStyle(.iconOnly)
                            .buttonStyle(.borderless)
                        }
                    }
                    .padding(Spacing.s)
                    .contentCard(Radius.small)
                }
                HStack(spacing: Spacing.s) {
                    Button("폴더 추가", systemImage: "plus") { pickFolder() }
                    Button("다시 훑기", systemImage: "arrow.clockwise") { model.rescanLocalLibrary() }
                    Spacer()
                    if let status = model.scanStatus {
                        Text(status).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .toolbarKeepsTitle()
            }

            HStack(spacing: Spacing.s) {
                Image(systemName: "music.note.house").foregroundStyle(Color.snuBlueLabel)
                Text("색인에 \(model.localTrackCount)곡")
                    .font(.headline)
                Spacer()
                Button("전부 대기열에 넣기", systemImage: "text.badge.plus") { enqueueAll() }
                    .disabled(model.localTrackCount == 0)
                    .toolbarKeepsTitle()
            }
            .padding(Spacing.m)
            .glassPanel(Radius.card)

            Text("찾을 곡은 왼쪽 `검색`에서 `내 음악`을 골라 찾으세요.")
                .font(.caption)
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .padding(Spacing.l)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "이 폴더 사용"
        if panel.runModal() == .OK, let url = panel.url { model.addLocalFolder(url) }
    }

    private func enqueueAll() {
        Task {
            let tracks = await model.allLocalTracks()
            model.enqueue(tracks)
        }
    }
}

// MARK: - 곡 목록

enum MusicListContext: Equatable {
    case search
    case collection(String)
    case playlist(UUID)
    case queue
}

struct MusicTrackList: View {
    @ObservedObject var model: MusicPlayerModel
    let tracks: [Track]
    let context: MusicListContext

    var body: some View {
        List {
            ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                MusicTrackRow(
                    model: model,
                    track: track,
                    number: index + 1,
                    isCurrent: model.currentTrack?.id == track.id,
                    play: { model.play(tracks, startingAt: index) }
                )
                .listRowInsets(EdgeInsets(top: 2, leading: Spacing.s, bottom: 2, trailing: Spacing.s))
            }
            .onMove { offsets, destination in
                if case .playlist(let id) = context {
                    model.moveInPlaylist(offsets, to: destination, playlist: id)
                }
            }
            .onDelete { offsets in
                if case .playlist(let id) = context {
                    model.removeFromPlaylist(offsets, playlist: id)
                }
            }
        }
        .listStyle(.inset)
        .alternatingRowBackgrounds()
    }
}

private struct MusicTrackRow: View {
    @ObservedObject var model: MusicPlayerModel
    let track: Track
    let number: Int
    let isCurrent: Bool
    let play: () -> Void
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: Spacing.m) {
            ZStack {
                MusicArtwork(url: track.thumbnailURL, size: 40)
                if isHovering {
                    Button(action: play) {
                        Image(systemName: "play.fill")
                            .font(.body)
                            .foregroundStyle(.white)
                            .frame(width: 40, height: 40)
                            .background(.black.opacity(0.45), in: RoundedRectangle(cornerRadius: Radius.small, style: .continuous))
                    }
                    .buttonStyle(.plain)
                } else if isCurrent {
                    Image(systemName: model.status == .playing ? "speaker.wave.2.fill" : "pause.fill")
                        .font(.caption)
                        .foregroundStyle(.white)
                        .frame(width: 40, height: 40)
                        .background(.black.opacity(0.4), in: RoundedRectangle(cornerRadius: Radius.small, style: .continuous))
                }
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(track.title)
                    .font(.body)
                    .lineLimit(1)
                    .foregroundStyle(isCurrent ? Color.snuBlueLabel : Color.primary)
                HStack(spacing: Spacing.xs) {
                    Text(track.artist.isEmpty ? track.origin.displayName : track.artist)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: Spacing.s)

            MusicSourceBadge(track: track)

            Text(MusicFormat.time(track.duration))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.tertiary)
                .frame(width: 46, alignment: .trailing)

            Button(model.isLiked(track) ? "좋아요 취소" : "좋아요", systemImage: model.isLiked(track) ? "heart.fill" : "heart") {
                model.toggleLike(track)
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .foregroundStyle(model.isLiked(track) ? Color.pink : Color.secondary)

            MusicTrackMenu(model: model, track: track)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .onTapGesture(count: 2, perform: play)
        .contextMenu {
            Button("지금 재생", systemImage: "play.fill", action: play)
            MusicTrackMenuItems(model: model, track: track)
        }
    }
}

/// 이 곡이 어디서 소리가 나는지. 음악 앱이 곡마다 이런 딱지를 다는 일은 드물지만,
/// 이 앱에서는 그것이 기능의 핵심이다 — 재생되는 것이 YouTube가 아니라는 사실과
/// 어떤 곡이 아예 재생되지 않는지를 목록에서 바로 알 수 있어야 한다.
private struct MusicSourceBadge: View {
    let track: Track

    var body: some View {
        if let asset = track.asset {
            Label(asset.provider.displayName, systemImage: asset.provider.symbol)
                .font(.caption2)
                .foregroundStyle(asset.confidence >= MusicMatching.confidentThreshold ? Color.secondary : Color.orange)
                .labelStyle(.titleAndIcon)
                .help(asset.confidence >= MusicMatching.confidentThreshold
                      ? asset.provenance
                      : "비슷한 음원으로 재생합니다: \(asset.provenance)")
        } else if track.searchedWithoutResultAt != nil {
            Label("재생 불가", systemImage: "speaker.slash")
                .font(.caption2)
                .foregroundStyle(.orange)
                .help("광고 없이 들을 수 있는 음원을 찾지 못했습니다. 파일을 직접 지정할 수 있습니다.")
        } else {
            Label("미확인", systemImage: "questionmark.circle")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .help("아직 음원을 찾지 않았습니다. 재생을 누르면 그때 찾습니다.")
        }
    }
}

private struct MusicTrackMenu: View {
    @ObservedObject var model: MusicPlayerModel
    let track: Track

    var body: some View {
        Menu {
            MusicTrackMenuItems(model: model, track: track)
        } label: {
            Image(systemName: "ellipsis")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: 24)
    }
}

private struct MusicTrackMenuItems: View {
    @ObservedObject var model: MusicPlayerModel
    let track: Track

    var body: some View {
        Button("다음에 재생", systemImage: "text.line.first.and.arrowtriangle.forward") { model.playNext(track) }
        Button("대기열에 추가", systemImage: "text.badge.plus") { model.enqueue(track) }
        Divider()
        Menu("플레이리스트에 추가") {
            if model.library.playlists.isEmpty {
                Text("플레이리스트가 없습니다")
            }
            ForEach(model.library.playlists) { playlist in
                Button(playlist.name) { model.addToPlaylist([track], playlist: playlist.id) }
            }
            Divider()
            Button("새 플레이리스트로") {
                let playlist = model.createPlaylist(named: track.title, with: [track])
                model.notice = "「\(playlist.name)」을 만들었습니다."
            }
        }
        Button(model.isLiked(track) ? "좋아요 취소" : "좋아요",
               systemImage: model.isLiked(track) ? "heart.slash" : "heart") {
            model.toggleLike(track)
        }
        Divider()
        Button("음원 다시 찾기", systemImage: "arrow.clockwise") {
            model.clearAsset(of: track)
            model.resolveMissing(in: [track], force: true)
        }
        Button("파일 직접 지정…", systemImage: "folder") { pickFile() }
        if let url = track.externalURL, track.origin == .youtube {
            Divider()
            Button("YouTube에서 열기", systemImage: "arrow.up.forward.square") {
                NSWorkspace.shared.open(url)
            }
        }
    }

    private func pickFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.audio, .mp3, .mpeg4Audio, .wav, .aiff]
        panel.prompt = "이 파일로 재생"
        if panel.runModal() == .OK, let url = panel.url { model.assignFile(url, to: track) }
    }
}

// MARK: - 앨범 아트

struct MusicArtwork: View {
    let url: URL?
    let size: CGFloat

    var body: some View {
        AsyncImage(url: url) { phase in
            switch phase {
            case .success(let image):
                image.resizable().aspectRatio(contentMode: .fill)
            default:
                ZStack {
                    Rectangle().fill(.quaternary.opacity(0.6))
                    Image(systemName: "music.note").foregroundStyle(.tertiary).font(.system(size: size * 0.4))
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size > 60 ? Radius.card : Radius.small, style: .continuous))
    }
}

// MARK: - 대기열

private struct MusicQueuePanel: View {
    @ObservedObject var model: MusicPlayerModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("재생 대기열").font(.headline)
                Spacer()
                Text("\(model.library.queue.count)곡").font(.caption).foregroundStyle(.secondary)
                Button("비우기", systemImage: "trash") { model.clearQueue() }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .disabled(model.library.queue.isEmpty)
            }
            .padding(Spacing.m)
            Divider()
            if model.library.queue.isEmpty {
                EmptyResults(symbol: "list.bullet", message: "대기열이 비어 있습니다.")
                    .frame(maxHeight: .infinity)
            } else {
                List {
                    ForEach(Array(model.library.queueTracks.enumerated()), id: \.offset) { index, track in
                        HStack(spacing: Spacing.s) {
                            MusicArtwork(url: track.thumbnailURL, size: 30)
                            VStack(alignment: .leading, spacing: 0) {
                                Text(track.title).font(.callout).lineLimit(1)
                                Text(track.artist).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            if model.library.queueIndex == index {
                                Image(systemName: "speaker.wave.2.fill")
                                    .font(.caption2)
                                    .foregroundStyle(Color.snuBlueLabel)
                            }
                        }
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) { model.jumpInQueue(to: index) }
                    }
                    .onMove { model.moveInQueue(from: $0, to: $1) }
                    .onDelete { model.removeFromQueue(at: $0) }
                }
                .listStyle(.inset)
            }
        }
    }
}

// MARK: - 아래 플레이어

private struct MusicPlayerBar: View {
    @ObservedObject var model: MusicPlayerModel
    @Binding var showsQueue: Bool

    var body: some View {
        HStack(spacing: Spacing.l) {
            nowPlaying.frame(width: 240, alignment: .leading)
            transport.frame(maxWidth: .infinity)
            trailing.frame(width: 200, alignment: .trailing)
        }
        .padding(.horizontal, Spacing.l)
        .padding(.vertical, Spacing.m)
        .frame(height: 88)
        .background(.bar)
    }

    private var nowPlaying: some View {
        HStack(spacing: Spacing.s) {
            MusicArtwork(url: model.currentTrack?.thumbnailURL, size: 48)
            VStack(alignment: .leading, spacing: 1) {
                Text(model.currentTrack?.title ?? "재생 중인 곡 없음")
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                Text(statusLine)
                    .font(.caption2)
                    .foregroundStyle(statusIsProblem ? Color.orange : Color.secondary)
                    .lineLimit(1)
            }
            if let track = model.currentTrack {
                Button(model.isLiked(track) ? "좋아요 취소" : "좋아요",
                       systemImage: model.isLiked(track) ? "heart.fill" : "heart") {
                    model.toggleLike(track)
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .foregroundStyle(model.isLiked(track) ? Color.pink : Color.secondary)
            }
        }
    }

    private var statusLine: String {
        switch model.status {
        case .resolving: "광고 없는 음원을 찾는 중…"
        case .failed(let message): message
        case .idle: "왼쪽에서 곡을 고르세요"
        default: model.currentTrack?.availabilityNote ?? ""
        }
    }

    private var statusIsProblem: Bool {
        if case .failed = model.status { return true }
        if let track = model.currentTrack, track.asset == nil, track.searchedWithoutResultAt != nil { return true }
        return false
    }

    private var transport: some View {
        VStack(spacing: Spacing.xs) {
            HStack(spacing: Spacing.m) {
                Button("셔플", systemImage: "shuffle") { model.toggleShuffle() }
                    .foregroundStyle(model.library.shuffle ? Color.snuBlueLabel : Color.secondary)
                    .help(model.library.shuffle ? "셔플 켜짐" : "셔플 꺼짐")
                Button("이전", systemImage: "backward.fill") { model.previous() }
                Button(model.status == .playing ? "일시정지" : "재생",
                       systemImage: model.status == .playing ? "pause.circle.fill" : "play.circle.fill") {
                    model.togglePlayPause()
                }
                .font(.system(size: 30))
                .foregroundStyle(Color.snuBlueLabel)
                Button("다음", systemImage: "forward.fill") { model.next() }
                Button(model.library.repeatMode.korean, systemImage: model.library.repeatMode.symbol) {
                    model.cycleRepeat()
                }
                .foregroundStyle(model.library.repeatMode == .off ? Color.secondary : Color.snuBlueLabel)
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)

            HStack(spacing: Spacing.s) {
                Text(MusicFormat.time(model.position))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 42, alignment: .trailing)
                Slider(
                    value: Binding(
                        get: { min(model.position, model.duration ?? model.position) },
                        set: { model.seek(to: $0) }
                    ),
                    in: 0...max(1, model.duration ?? 1),
                    onEditingChanged: { model.isScrubbing = $0 }
                )
                .disabled(model.duration == nil)
                .controlSize(.small)
                Text(MusicFormat.time(model.duration))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 42, alignment: .leading)
            }
            .frame(maxWidth: 520)
        }
    }

    private var trailing: some View {
        HStack(spacing: Spacing.s) {
            if case .resolving = model.status { ProgressView().controlSize(.small) }
            Button("대기열", systemImage: "list.bullet") { showsQueue.toggle() }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .foregroundStyle(showsQueue ? Color.snuBlueLabel : Color.secondary)
            Image(systemName: model.library.volume < 0.01 ? "speaker.slash" : "speaker.wave.2")
                .foregroundStyle(.secondary)
                .font(.caption)
            Slider(
                value: Binding(get: { model.library.volume }, set: { model.setVolume($0) }),
                in: 0...1
            )
            .controlSize(.small)
            .frame(width: 90)
        }
    }
}

// MARK: - 잠깐 뜨는 말

private struct MusicNoticeBanner: View {
    @ObservedObject var model: MusicPlayerModel

    var body: some View {
        if let notice = model.notice {
            Text(notice)
                .font(.callout)
                .padding(.horizontal, Spacing.l)
                .padding(.vertical, Spacing.s)
                .glassPanel(Radius.panel)
                .padding(.top, Spacing.m)
                .transition(.appBanner)
                .task(id: notice) {
                    try? await Task.sleep(for: .seconds(3))
                    withAnimation(.appContent) { model.notice = nil }
                }
        }
    }
}

// MARK: - 시트

private struct NamePlaylistSheet: View {
    @Binding var name: String
    var title = "새 플레이리스트"
    let confirm: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.l) {
            Text(title).font(.headline)
            TextField("이름", text: $name)
                .textFieldStyle(.roundedBorder)
                .frame(width: 300)
                .onSubmit(save)
            HStack {
                Spacer()
                Button("취소") { dismiss() }
                Button("확인", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(Spacing.xl)
    }

    private func save() {
        confirm(name)
        name = ""
        dismiss()
    }
}

private struct ImportPlaylistSheet: View {
    @ObservedObject var model: MusicPlayerModel
    @Binding var text: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            Text("YouTube 플레이리스트 가져오기").font(.headline)
            Text("플레이리스트 주소나 id를 넣으세요. 곡 목록과 제목만 가져오고, 재생은 광고 없는 음원으로 합니다.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField("https://www.youtube.com/playlist?list=…", text: $text)
                .textFieldStyle(.roundedBorder)
                .frame(width: 420)
                .onSubmit { model.importPlaylist(text) }
            if let status = model.importStatus {
                Label(status, systemImage: model.isImporting ? "hourglass" : "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack {
                if model.isImporting { ProgressView().controlSize(.small) }
                Spacer()
                Button("닫기") { dismiss() }
                Button("가져오기") { model.importPlaylist(text) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty || model.isImporting)
            }
        }
        .padding(Spacing.xl)
    }
}

// MARK: - 개요 타일

struct MusicOverviewTile: View {
    @ObservedObject var model: MusicPlayerModel
    let open: () -> Void

    var body: some View {
        StatusTile(
            title: AppSection.music.title,
            value: model.overviewValue,
            detail: model.overviewDetail,
            symbol: AppSection.music.symbol,
            isBusy: model.status.isActive,
            open: open
        )
    }
}
