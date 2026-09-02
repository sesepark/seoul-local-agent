import Foundation

// MARK: - 소스와 곡

/// Where a track came from. The app's own model deliberately knows only this
/// much about YouTube: a tag and an opaque identifier. Everything that is
/// actually YouTube-shaped — the Data API, the embed player, quota, ISO 8601
/// durations — lives behind `MusicSource`, so adding a second source later is a
/// new file rather than a rewrite of the library, the queue and every screen.
enum MusicSourceKind: String, Codable, Sendable, CaseIterable {
    case youtube

    var displayName: String {
        switch self {
        case .youtube: "YouTube"
        }
    }
}

/// How a track is actually played. The player model switches on this rather
/// than on the source kind, so a future local-file source is a new case here and
/// a new surface, and the queue logic above it does not change at all.
enum PlaybackTarget: Equatable, Sendable {
    /// The official embedded player, addressed by video id.
    case youtubeVideo(String)
}

/// One playable item, in the app's own vocabulary.
///
/// `id` is `"<source>:<sourceID>"` — stable across launches and across
/// playlists, which is what lets likes, 최근 재생, 대기열 and every playlist
/// share a single copy of the metadata instead of drifting apart.
struct Track: Codable, Identifiable, Hashable, Sendable {
    var id: String
    var source: MusicSourceKind
    var sourceID: String
    var title: String
    var artist: String
    /// Missing rather than zero when the source did not say. A live stream has
    /// no duration at all, and drawing `0:00` for it would be a lie.
    var duration: TimeInterval?
    var thumbnailURL: URL?
    /// When this Mac first learned about the track. Used for ordering nothing —
    /// likes and 최근 재생 keep their own order — but it makes the stored file
    /// readable when something has to be debugged by eye.
    var addedAt: Date

    init(
        source: MusicSourceKind,
        sourceID: String,
        title: String,
        artist: String,
        duration: TimeInterval? = nil,
        thumbnailURL: URL? = nil,
        addedAt: Date = Date()
    ) {
        self.id = "\(source.rawValue):\(sourceID)"
        self.source = source
        self.sourceID = sourceID
        self.title = title
        self.artist = artist
        self.duration = duration
        self.thumbnailURL = thumbnailURL
        self.addedAt = addedAt
    }

    var playbackTarget: PlaybackTarget {
        switch source {
        case .youtube: .youtubeVideo(sourceID)
        }
    }

    /// The page a human would open to see this track outside the app. Kept on
    /// the track rather than in the UI so the menu item does not have to know
    /// which source it is looking at.
    var externalURL: URL? {
        switch source {
        case .youtube: URL(string: "https://www.youtube.com/watch?v=\(sourceID)")
        }
    }
}

// MARK: - 플레이리스트

struct MusicPlaylist: Codable, Identifiable, Hashable, Sendable {
    var id: UUID
    var name: String
    /// Track ids, not tracks. The catalog holds one copy of each track, so
    /// renaming or re-fetching a track updates every list that contains it.
    var trackIDs: [String]
    var createdAt: Date
    var updatedAt: Date
    /// The source playlist this was imported from, if any — kept so 다시
    /// 가져오기 can update the same list instead of making a second copy.
    var importedFrom: ImportOrigin?

    struct ImportOrigin: Codable, Hashable, Sendable {
        var source: MusicSourceKind
        var id: String
        var importedAt: Date
    }

    init(name: String, trackIDs: [String] = [], importedFrom: ImportOrigin? = nil) {
        self.id = UUID()
        self.name = name
        self.trackIDs = trackIDs
        self.createdAt = Date()
        self.updatedAt = Date()
        self.importedFrom = importedFrom
    }
}

// MARK: - 반복

enum RepeatMode: String, Codable, Sendable, CaseIterable {
    case off, all, one

    var next: RepeatMode {
        switch self {
        case .off: .all
        case .all: .one
        case .one: .off
        }
    }

    var symbol: String {
        switch self {
        case .off, .all: "repeat"
        case .one: "repeat.1"
        }
    }

    var korean: String {
        switch self {
        case .off: "반복 없음"
        case .all: "전체 반복"
        case .one: "한 곡 반복"
        }
    }
}

// MARK: - 보관함

/// Everything the app remembers about music, in one value.
///
/// One file rather than several: likes, playlists, 최근 재생 and the queue all
/// reference the same catalog, and writing them separately means a crash
/// between two writes can leave a playlist pointing at a track that no longer
/// has a title. A single atomic write cannot land half-applied.
struct MusicLibrary: Codable, Sendable, Equatable {
    /// Every track anything else refers to, keyed by `Track.id`.
    var catalog: [String: Track] = [:]
    var playlists: [MusicPlaylist] = []
    /// Newest first, so the screen reads top-down without sorting.
    var likedIDs: [String] = []
    var recentIDs: [String] = []
    var queue: [String] = []
    var queueIndex: Int?
    var shuffle = false
    var repeatMode: RepeatMode = .off
    var volume: Double = 0.8
    /// Where the current track was when the app last closed, so reopening
    /// offers to continue rather than starting the song over.
    var resumePosition: TimeInterval = 0
    /// Search results are not remembered, but the last query is: reopening the
    /// tab on an empty screen loses the thing you were about to click.
    var lastQuery: String = ""

    static let recentLimit = 100

    // MARK: 조회

    func track(_ id: String) -> Track? { catalog[id] }

    func tracks(_ ids: [String]) -> [Track] { ids.compactMap { catalog[$0] } }

    func isLiked(_ id: String) -> Bool { likedIDs.contains(id) }

    var likedTracks: [Track] { tracks(likedIDs) }
    var recentTracks: [Track] { tracks(recentIDs) }
    var queueTracks: [Track] { tracks(queue) }

    var currentTrackID: String? {
        guard let index = queueIndex, queue.indices.contains(index) else { return nil }
        return queue[index]
    }

    // MARK: 변경

    /// Puts a track in the catalog, keeping the earliest `addedAt` so a track
    /// re-seen in a search does not look newly added.
    mutating func remember(_ track: Track) {
        if let existing = catalog[track.id] {
            var merged = track
            merged.addedAt = min(existing.addedAt, track.addedAt)
            catalog[track.id] = merged
        } else {
            catalog[track.id] = track
        }
    }

    mutating func remember(_ tracks: [Track]) { tracks.forEach { remember($0) } }

    mutating func toggleLike(_ track: Track) {
        remember(track)
        if let index = likedIDs.firstIndex(of: track.id) {
            likedIDs.remove(at: index)
        } else {
            likedIDs.insert(track.id, at: 0)
        }
    }

    mutating func notePlayed(_ track: Track) {
        remember(track)
        recentIDs.removeAll { $0 == track.id }
        recentIDs.insert(track.id, at: 0)
        if recentIDs.count > Self.recentLimit { recentIDs.removeLast(recentIDs.count - Self.recentLimit) }
    }

    mutating func addTracks(_ tracks: [Track], toPlaylist playlistID: UUID) {
        guard let index = playlists.firstIndex(where: { $0.id == playlistID }) else { return }
        remember(tracks)
        // 같은 곡을 두 번 넣지 않는다. 플레이리스트에 중복이 생기면 셔플이 그 곡만
        // 두 배로 자주 고르고, 지울 때도 어느 쪽을 지운 것인지 알 수 없다.
        let existing = Set(playlists[index].trackIDs)
        playlists[index].trackIDs.append(contentsOf: tracks.map(\.id).filter { !existing.contains($0) })
        playlists[index].updatedAt = Date()
    }

    mutating func removeTracks(at offsets: IndexSet, fromPlaylist playlistID: UUID) {
        guard let index = playlists.firstIndex(where: { $0.id == playlistID }) else { return }
        playlists[index].trackIDs.remove(atOffsets: offsets)
        playlists[index].updatedAt = Date()
    }

    mutating func moveTracks(from offsets: IndexSet, to destination: Int, inPlaylist playlistID: UUID) {
        guard let index = playlists.firstIndex(where: { $0.id == playlistID }) else { return }
        playlists[index].trackIDs.move(fromOffsets: offsets, toOffset: destination)
        playlists[index].updatedAt = Date()
    }

    /// Drops catalog entries nothing points at any more.
    ///
    /// Without this the file grows forever: every search result that was played
    /// once and every track removed from a playlist would stay, and after a few
    /// months the app would be reading a megabyte of dead metadata at launch.
    mutating func pruneCatalog() {
        var reachable = Set(likedIDs)
        reachable.formUnion(recentIDs)
        reachable.formUnion(queue)
        for playlist in playlists { reachable.formUnion(playlist.trackIDs) }
        catalog = catalog.filter { reachable.contains($0.key) }
    }
}

// MARK: - 저장

/// The library on disk, written the way every other personal file in this app is
/// written: owner-only, staged through a temporary file so a crash cannot leave
/// a half-written playlist behind.
struct MusicLibraryStore: Sendable {
    private let url: URL

    init(directory: URL? = nil) {
        let root = directory ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appending(path: "Library/Application Support/SeoulLocalAgent", directoryHint: .isDirectory)
        url = root.appending(path: "music-library.json")
    }

    var debugURL: URL { url }

    func load() -> MusicLibrary {
        guard let data = try? Data(contentsOf: url) else { return MusicLibrary() }
        do {
            return try JSONDecoder.musicDecoder.decode(MusicLibrary.self, from: data)
        } catch {
            // 형식이 바뀌어 읽지 못하는 경우에도 빈 보관함으로 계속 간다. 음악은
            // 앱의 다른 기능을 막을 이유가 없고, 원본 파일은 지우지 않으므로
            // 나중에 손으로 되살릴 수 있다.
            return MusicLibrary()
        }
    }

    func save(_ library: MusicLibrary) throws {
        var pruned = library
        pruned.pruneCatalog()
        try LocalFileStorage.write(try JSONEncoder.musicEncoder.encode(pruned), to: url)
    }
}

extension JSONEncoder {
    static var musicEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

extension JSONDecoder {
    static var musicDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

// MARK: - 시간 표기

enum MusicFormat {
    /// `3:07` and `1:02:11`. A missing duration is `--:--` rather than `0:00`,
    /// because a live stream genuinely has no length and saying zero is wrong.
    static func time(_ seconds: TimeInterval?) -> String {
        guard let seconds, seconds.isFinite, seconds >= 0 else { return "--:--" }
        let total = Int(seconds.rounded())
        let (hours, minutes, secs) = (total / 3600, (total % 3600) / 60, total % 60)
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, secs)
            : String(format: "%d:%02d", minutes, secs)
    }
}
