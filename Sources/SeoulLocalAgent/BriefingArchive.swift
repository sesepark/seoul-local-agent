import AppKit
import Foundation

/// What the reader did with one briefing item: ticked it off, wrote a note on
/// it, put it on the calendar.
///
/// This used to live in Notion — the checkbox on the page *was* the completion
/// state, and the next morning's carry-forward read those checkboxes back over
/// the network to decide what was still outstanding. Keeping it here instead
/// means the app can answer "무엇이 남았나" on its own, and keys the answer to
/// `ClassifiedItem.trackingID` rather than to the rendered title, so an item
/// whose wording changes between runs is still recognised as the same thing.
struct BriefingMark: Codable, Equatable {
    var isDone = false
    var completedAt: Date?
    var note = ""
    /// `EKEvent.eventIdentifier` / `EKReminder.calendarItemIdentifier` of what
    /// this item was turned into, so a second run does not add it twice.
    var calendarEventID: String?
    var reminderID: String?
    /// When the calendar entry sits, kept here so the archive can say
    /// "9월 3일 14시" without opening EventKit for every visible row.
    var scheduledAt: Date?
    var updatedAt = Date()

    var isPlaced: Bool { calendarEventID != nil || reminderID != nil }
    /// A mark with nothing in it is not worth storing, and pruning it keeps the
    /// file proportional to what the user actually touched.
    var isBlank: Bool { !isDone && note.isEmpty && !isPlaced }

    init() {}

    /// Written by hand rather than synthesised: the synthesised decoder fails on
    /// a missing key, which would mean that adding one field in a later version
    /// silently discarded every mark the user had already made.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        isDone = try container.decodeIfPresent(Bool.self, forKey: .isDone) ?? false
        completedAt = try container.decodeIfPresent(Date.self, forKey: .completedAt)
        note = try container.decodeIfPresent(String.self, forKey: .note) ?? ""
        calendarEventID = try container.decodeIfPresent(String.self, forKey: .calendarEventID)
        reminderID = try container.decodeIfPresent(String.self, forKey: .reminderID)
        scheduledAt = try container.decodeIfPresent(Date.self, forKey: .scheduledAt)
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
    }
}

struct BriefingArchiveState: Codable {
    var marks: [String: BriefingMark] = [:]

    var completedIDs: Set<String> { Set(marks.filter(\.value.isDone).map(\.key)) }

    /// Briefings themselves are pruned at thirty days; their marks are kept
    /// longer and by count instead, because a mark is two hundred bytes and
    /// losing one silently resurrects a finished task.
    static let retainedMarks = 2_000

    static func pruned(_ marks: [String: BriefingMark], keeping limit: Int = retainedMarks) -> [String: BriefingMark] {
        let live = marks.filter { !$0.value.isBlank }
        guard live.count > limit else { return live }
        let kept = live.sorted { $0.value.updatedAt > $1.value.updatedAt }.prefix(limit)
        return Dictionary(uniqueKeysWithValues: kept.map { ($0.key, $0.value) })
    }

    init(marks: [String: BriefingMark] = [:]) { self.marks = marks }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        marks = try container.decodeIfPresent([String: BriefingMark].self, forKey: .marks) ?? [:]
    }
}

/// Separate from `state.json` on purpose. That file is a checkpoint the pipeline
/// rewrites on every run and prunes to thirty days; this one is the user's own
/// record and must not be lost when a run rewrites the checkpoint. It holds no
/// message bodies — only identifiers, a flag, and whatever note was typed.
struct BriefingArchiveStore: Sendable {
    private let url: URL

    init(directory: URL? = nil) {
        let root = directory ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appending(path: "Library/Application Support/SeoulLocalAgent", directoryHint: .isDirectory)
        url = root.appending(path: "briefing-archive.json")
    }

    var debugPath: String { url.path }

    func load() -> BriefingArchiveState {
        guard let data = try? Data(contentsOf: url),
              let state = try? JSONDecoder().decode(BriefingArchiveState.self, from: data) else { return BriefingArchiveState() }
        return state
    }

    func save(_ state: BriefingArchiveState) throws {
        var stored = state
        stored.marks = BriefingArchiveState.pruned(state.marks)
        try LocalFileStorage.write(try JSONEncoder().encode(stored), to: url)
    }
}

/// The 브리핑 보관함 screen's brain: the days the pipeline has produced, the
/// reader's marks on them, and the two things the reader can do with an item —
/// tick it off, or put it on the calendar.
///
/// Briefings themselves still live in `state.json`, which the pipeline already
/// writes, prunes to thirty days and strips message bodies from. Copying them
/// into a second file would mean two things to keep in step; this reads that
/// one and joins it to the marks by `trackingID`.
@MainActor
final class BriefingArchiveModel: ObservableObject {

    enum Bucket: String, CaseIterable, Identifiable {
        case action = "오늘 꼭 할 일"
        case reference = "확인해야 할 것"
        case other = "기타"

        var id: String { rawValue }

        var symbol: String {
            switch self {
            case .action: "checkmark.circle"
            case .reference: "eye"
            case .other: "tray"
            }
        }

        var emptyText: String {
            switch self {
            case .action: "이 날 처리할 일이 없습니다."
            case .reference: "확인할 항목이 없습니다."
            case .other: "제외된 항목이 없습니다."
            }
        }
    }

    struct Entry: Identifiable, Equatable {
        let item: ClassifiedItem
        let dateKey: String
        var mark: BriefingMark

        var id: String { item.trackingID }
        var title: String { BriefPresentation.title(for: item) }
        var summary: String { BriefPresentation.summary(for: item) }
        var deadlineText: String? { BriefPresentation.deadlineText(item.deadline) }
        var source: String { item.sourceItem.source }
        var author: String { item.sourceItem.author.trimmingCharacters(in: .whitespacesAndNewlines) }
        var link: URL { item.sourceItem.link }
        var receivedAt: Date { item.sourceItem.timestamp }

        /// Written out in Korean rather than through `Date.formatted`, which
        /// follows the Mac's region and put "Aug 13, 2026 at 7:15 PM" two lines
        /// above a 마감 the app had already rendered as "8월 14일 19시 15분".
        var receivedText: String {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "ko_KR")
            formatter.timeZone = KoreanDeadline.timeZone
            formatter.dateFormat = "M월 d일 HH:mm"
            return formatter.string(from: receivedAt)
        }

        var nextAction: String? {
            BriefPresentation.usable(item.displayNextAction, limit: 200)
                ?? item.nextAction.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        }

        /// The message as it arrived, as far as the archive keeps it: a cleaned
        /// excerpt of the first 800 characters, stored with the classification.
        ///
        /// The screen used to show only the model's own summary, which meant an
        /// email whose summary missed the point could not be checked without
        /// leaving for Gmail — the exact trip this archive exists to avoid.
        var bodyText: String {
            (item.bodyExcerpt ?? item.sourceItem.body).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        static let bodyPreviewLength = 220

        var hasLongBody: Bool { bodyText.count > Self.bodyPreviewLength }

        var bodyPreview: String {
            guard hasLongBody else { return bodyText }
            return String(bodyText.prefix(Self.bodyPreviewLength)).trimmingCharacters(in: .whitespaces) + "…"
        }

        /// The whole item as plain text, for 복사.
        ///
        /// SwiftUI can only carry a selection inside one `Text`, so no amount of
        /// dragging across a row will ever produce this; a copy command has to.
        var plainText: String {
            var lines = [title, "\(source) · \(author.isEmpty ? "발신자 미상" : author) · \(receivedText)"]
            if let deadlineText { lines.append("마감 \(deadlineText)") }
            lines.append("")
            lines.append(summary)
            if let nextAction { lines.append("요청: \(nextAction)") }
            if !bodyText.isEmpty { lines += ["", bodyText] }
            if !mark.note.isEmpty { lines += ["", "메모: \(mark.note)"] }
            lines += ["", link.absoluteString]
            return lines.joined(separator: "\n")
        }

        /// What the app already put on the calendar for this item, if anything.
        var placement: CalendarPlacement? {
            if let identifier = mark.calendarEventID {
                return CalendarPlacement(identifier: identifier, date: mark.scheduledAt ?? receivedAt, isReminder: false)
            }
            if let identifier = mark.reminderID {
                return CalendarPlacement(identifier: identifier, date: mark.scheduledAt ?? receivedAt, isReminder: true)
            }
            return nil
        }

        /// The deadline read as a date, when there is one worth trusting.
        func suggestedDate(now: Date = Date()) -> KoreanDeadline.Parsed? {
            KoreanDeadline.parse(item.deadline, now: now)
        }

        /// Past its deadline, not merely due today. Worth separating: a list
        /// headed 오늘 that silently includes a deadline from two weeks ago reads
        /// as a bug rather than as a warning.
        func isOverdue(now: Date = Date()) -> Bool {
            guard let expiry = BriefPresentation.deadlineExpiry(item.deadline) else { return false }
            return expiry <= now
        }
    }

    @Published private(set) var days: [DailyBriefing] = []
    @Published var selectedDateKey: String = ""
    @Published var search = ""
    @Published var hidesDone = false
    @Published var expanded: Set<String> = []
    @Published var status = ""
    @Published var error: String?
    @Published var isExporting = false
    /// Non-nil while the confirm-the-date sheet is up.
    @Published var scheduling: Entry?
    /// Which of the two destinations the sheet opens on, so "미리 알림으로
    /// 보내기…" does not land on a sheet set to 캘린더 일정.
    @Published var schedulingPrefersReminder = false

    private let stateStore: StateStore
    private let archiveStore: BriefingArchiveStore
    /// Read once, and applied to stored briefings as they are shown rather than
    /// when they were written. That is what lets a change to the reader's own
    /// rules re-file yesterday's items without asking the model to read the
    /// inbox again — and it is already how `BriefingQualityGate` behaved.
    private var preferences: BriefingPreferences
    /// Non-nil only in tests, which must not depend on the settings file that
    /// happens to be on the machine running them.
    private let injectedPreferences: BriefingPreferences?
    private let writer = CalendarWriter()
    private var marks: [String: BriefingMark] = [:]
    /// Bumped whenever the days or the marks change. Both caches below key on it.
    private var revision = 0
    private var visibleCache: (key: String, entries: [Entry])?
    private var dueCache: (key: String, entries: [Entry])?

    /// Both stores are injectable so a test can point them at a temporary
    /// directory. Without that, running the suite would read — and the write
    /// tests would overwrite — the real briefings in Application Support.
    init(
        stateStore: StateStore = StateStore(),
        archiveStore: BriefingArchiveStore = BriefingArchiveStore(),
        preferences: BriefingPreferences? = nil
    ) {
        self.stateStore = stateStore
        self.archiveStore = archiveStore
        self.injectedPreferences = preferences
        self.preferences = preferences ?? BriefingPreferencesStore().load()
        reload()
    }

    // MARK: - 읽기

    func reload() {
        revision &+= 1
        // Re-read on every refresh so editing 분류 기준 in 설정 re-files what is
        // already on screen, without another run of the model.
        if injectedPreferences == nil { preferences = BriefingPreferencesStore().load() }
        let state = stateStore.load()
        days = state.dailyBriefings.values.sorted { sortKey($0) > sortKey($1) }
        marks = archiveStore.load().marks
        if days.first(where: { $0.dateKey == selectedDateKey }) == nil {
            selectedDateKey = days.first?.dateKey ?? ""
        }
    }

    private func sortKey(_ briefing: DailyBriefing) -> Date {
        BriefingArchiveModel.date(fromKey: briefing.dateKey) ?? briefing.updatedAt
    }

    /// `dateKey` is "yy/MM/dd" in Seoul, which sorts correctly as a string but
    /// reads badly, so the screen shows a real date built back out of it.
    static func date(fromKey key: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = KoreanDeadline.timeZone
        formatter.dateFormat = "yy/MM/dd"
        return formatter.date(from: key)
    }

    static func dayTitle(_ key: String) -> String {
        guard let date = date(fromKey: key) else { return key }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ko_KR")
        formatter.timeZone = KoreanDeadline.timeZone
        formatter.dateFormat = "M월 d일 (E)"
        return formatter.string(from: date)
    }

    var selectedDay: DailyBriefing? { days.first { $0.dateKey == selectedDateKey } }

    var isSearching: Bool { !search.trimmingCharacters(in: .whitespaces).isEmpty }

    var selectedIndex: Int? { days.firstIndex { $0.dateKey == selectedDateKey } }

    func step(_ offset: Int) {
        guard let index = selectedIndex else { return }
        let next = index + offset
        guard days.indices.contains(next) else { return }
        selectedDateKey = days[next].dateKey
        expanded.removeAll()
    }

    var canStepBack: Bool { selectedIndex.map { $0 + 1 < days.count } ?? false }
    var canStepForward: Bool { (selectedIndex ?? 0) > 0 }

    /// Everything on show, before bucketing. Searching widens the scope to every
    /// retained day, because "그때 그 메일이 언제였더라" is the whole reason to
    /// keep more than one day around.
    ///
    /// Memoised. SwiftUI evaluates `body` far more often than the data changes,
    /// and this walks every retained day through `BriefingQualityGate` — thirty
    /// days of a hundred items each, several times per redraw, is work the screen
    /// cannot afford to repeat for a result that has not changed.
    private var visible: [Entry] {
        let key = "\(revision)|\(selectedDateKey)|\(search)"
        if let cached = visibleCache, cached.key == key { return cached.entries }
        let computed = computeVisible()
        visibleCache = (key, computed)
        return computed
    }

    private func computeVisible() -> [Entry] {
        let scope = isSearching ? days : days.filter { $0.dateKey == selectedDateKey }
        var seen = Set<String>()
        var entries: [Entry] = []
        for day in scope {
            for item in BriefingQualityGate.normalized(day.items, preferences: preferences) where seen.insert(item.trackingID).inserted {
                entries.append(Entry(item: item, dateKey: day.dateKey, mark: marks[item.trackingID] ?? BriefingMark()))
            }
        }
        guard isSearching else { return entries }
        let needle = search.trimmingCharacters(in: .whitespaces).lowercased()
        return entries.filter { entry in
            "\(entry.title) \(entry.summary) \(entry.author) \(entry.source) \(entry.mark.note)".lowercased().contains(needle)
        }
    }

    func entries(_ bucket: Bucket) -> [Entry] {
        let matching = visible.filter { entry in
            switch bucket {
            case .action: entry.item.category == .action
            case .reference: entry.item.category == .reference
            case .other: entry.item.category == .excluded
            }
        }
        let shown = hidesDone ? matching.filter { !$0.mark.isDone } : matching
        // Finished items sink; among the rest the most important comes first, and
        // ties break on when the thing arrived.
        return shown.sorted { lhs, rhs in
            if lhs.mark.isDone != rhs.mark.isDone { return !lhs.mark.isDone }
            if lhs.item.importance != rhs.item.importance { return lhs.item.importance > rhs.item.importance }
            return lhs.receivedAt > rhs.receivedAt
        }
    }

    var openActionCount: Int { entries(.action).filter { !$0.mark.isDone }.count }

    /// Everything on screen as plain text, in the order it is shown.
    ///
    /// The reader's way of taking a whole morning's briefing somewhere else —
    /// a message to a lab mate, a note in their own notebook — without the app
    /// having to know about that destination. Notion export writes the same
    /// content through a service; this writes it to the clipboard.
    func plainText() -> String {
        var lines = [Self.dayTitle(selectedDateKey) + " 브리핑"]
        if isSearching { lines.append("검색: \(search)") }
        for bucket in Bucket.allCases {
            let items = entries(bucket)
            guard !items.isEmpty else { continue }
            lines += ["", "## \(bucket.rawValue) (\(items.count))"]
            for entry in items {
                lines.append("")
                lines.append("\(entry.mark.isDone ? "[x]" : "[ ]") \(entry.plainText)")
            }
        }
        return lines.joined(separator: "\n")
    }

    /// What the 개요 screen shows: everything still open whose deadline is today
    /// or already past. Capped, because 개요 is a glance and a backlog of thirty
    /// would push every other card off the screen — the full list is one click
    /// away in the archive.
    static let dueTodayLimit = 6

    func dueToday(now: Date = Date()) -> [Entry] {
        var dayCalendar = Calendar(identifier: .gregorian)
        dayCalendar.timeZone = KoreanDeadline.timeZone
        // Keyed by the day, not the instant: 개요 asks this on every redraw, but
        // the answer only changes when the data changes or the date rolls over.
        let key = "\(revision)|\(dayCalendar.startOfDay(for: now).timeIntervalSince1970)"
        if let cached = dueCache, cached.key == key { return cached.entries }
        let computed = computeDueToday(now: now)
        dueCache = (key, computed)
        return computed
    }

    private func computeDueToday(now: Date) -> [Entry] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = KoreanDeadline.timeZone
        guard let endOfDay = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) else { return [] }
        var seen = Set<String>()
        var found: [Entry] = []
        for day in days {
            for item in day.items where item.category == .action && seen.insert(item.trackingID).inserted {
                let mark = marks[item.trackingID] ?? BriefingMark()
                guard !mark.isDone, let due = KoreanDeadline.parse(item.deadline, now: now), due.date < endOfDay else { continue }
                found.append(Entry(item: item, dateKey: day.dateKey, mark: mark))
            }
        }
        // Overdue first, then by importance: the thing that is already late is
        // the thing to look at.
        return found.sorted { lhs, rhs in
            let lateLeft = lhs.isOverdue(now: now)
            if lateLeft != rhs.isOverdue(now: now) { return lateLeft }
            return lhs.item.importance > rhs.item.importance
        }
    }

    // MARK: - 표시

    func isExpanded(_ entry: Entry) -> Bool { expanded.contains(entry.id) }

    func toggleExpanded(_ entry: Entry) {
        if expanded.contains(entry.id) { expanded.remove(entry.id) } else { expanded.insert(entry.id) }
    }

    // MARK: - 쓰기

    /// `marks` is deliberately not `@Published` — it is a dictionary the whole
    /// screen reads through `entries(_:)`, so the announcement belongs to the
    /// change, not to the storage.
    private func mutate(_ id: String, _ change: (inout BriefingMark) -> Void) {
        objectWillChange.send()
        var mark = marks[id] ?? BriefingMark()
        change(&mark)
        mark.updatedAt = Date()
        marks[id] = mark
        revision &+= 1
        persist()
    }

    private func persist() {
        do {
            try archiveStore.save(BriefingArchiveState(marks: marks))
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    func toggleDone(_ entry: Entry) {
        mutate(entry.id) { mark in
            mark.isDone.toggle()
            mark.completedAt = mark.isDone ? Date() : nil
        }
    }

    func setNote(_ note: String, for entry: Entry) {
        guard (marks[entry.id]?.note ?? "") != note else { return }
        mutate(entry.id) { $0.note = note }
    }

    func note(for entry: Entry) -> String { marks[entry.id]?.note ?? "" }

    func mark(for id: String) -> BriefingMark { marks[id] ?? BriefingMark() }

    // MARK: - 캘린더

    /// One press when the deadline is unambiguous; otherwise the sheet, because
    /// a guessed date written straight into someone's calendar is worse than
    /// one extra confirmation.
    func schedule(_ entry: Entry, asReminder: Bool = false) async {
        guard let parsed = entry.suggestedDate(), parsed.isConfident else {
            ask(entry, asReminder: asReminder)
            return
        }
        await place(entry, at: parsed.date, includesTime: parsed.includesTime, asReminder: asReminder)
    }

    func ask(_ entry: Entry, asReminder: Bool) {
        schedulingPrefersReminder = asReminder
        scheduling = entry
    }

    func place(_ entry: Entry, at date: Date, includesTime: Bool, asReminder: Bool) async {
        error = nil
        do {
            if asReminder {
                if CalendarWriter.reminderAccess() != .fullAccess { try await CalendarWriter.requestReminderAccess() }
            } else {
                if CalendarWriter.eventAccess() != .fullAccess { try await CalendarWriter.requestEventAccess() }
            }
            let notes = calendarNotes(for: entry)
            let placement = asReminder
                ? try writer.addReminder(title: entry.title, notes: notes, url: entry.link, due: date, includesTime: includesTime)
                : try writer.addEvent(title: entry.title, notes: notes, url: entry.link, at: date, includesTime: includesTime)
            mutate(entry.id) { mark in
                if asReminder { mark.reminderID = placement.identifier } else { mark.calendarEventID = placement.identifier }
                mark.scheduledAt = placement.date
            }
            let when = includesTime
                ? placement.date.formatted(date: .abbreviated, time: .shortened)
                : placement.date.formatted(date: .abbreviated, time: .omitted)
            status = "\(AgentCalendar.title) \(asReminder ? "목록" : "캘린더")에 \(when)로 추가했습니다."
            scheduling = nil
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    func unschedule(_ entry: Entry) {
        guard let placement = entry.placement else { return }
        do {
            try writer.remove(placement)
            mutate(entry.id) { mark in
                mark.calendarEventID = nil
                mark.reminderID = nil
                mark.scheduledAt = nil
            }
            status = "캘린더에서 지웠습니다."
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// A recorded entry the user has since deleted in Calendar.app should stop
    /// claiming to exist, or the archive quietly refuses to add it back.
    func reconcilePlacements() {
        var changed = false
        var placements: [String: CalendarPlacement] = [:]
        for (id, mark) in marks {
            guard mark.isPlaced else { continue }
            let placement = CalendarPlacement(
                identifier: mark.calendarEventID ?? mark.reminderID ?? "",
                date: mark.scheduledAt ?? Date(),
                isReminder: mark.calendarEventID == nil
            )
            placements[id] = placement
        }
        // One store for the whole sweep, and nothing at all when permission is
        // gone — otherwise every lookup would come back empty and this would
        // quietly forget every calendar entry the user had made.
        let gone = writer.missing(Array(placements.values))
        guard !gone.isEmpty else { return }
        objectWillChange.send()
        for (id, placement) in placements where gone.contains(placement.identifier) {
            marks[id]?.calendarEventID = nil
            marks[id]?.reminderID = nil
            marks[id]?.scheduledAt = nil
            changed = true
        }
        if changed {
            revision &+= 1
            persist()
        }
    }

    private func calendarNotes(for entry: Entry) -> String {
        var lines = [entry.summary]
        if let action = entry.nextAction { lines.append("할 일: \(action)") }
        if let deadline = entry.deadlineText { lines.append("마감: \(deadline)") }
        lines.append("출처: \(entry.source) · \(entry.author)")
        lines.append(entry.link.absoluteString)
        return lines.joined(separator: "\n")
    }

    // MARK: - 내보내기

    /// Notion is opt-in now. Nothing is sent anywhere until this is pressed, and
    /// only the day on screen goes.
    func exportToNotion() async {
        guard let briefing = selectedDay else { return }
        isExporting = true
        error = nil
        defer { isExporting = false }
        do {
            let url = try await BriefingService().exportToNotion(briefing)
            status = "Notion에 내보냈습니다."
            reload()
            NSWorkspace.shared.open(url)
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    var notionURL: URL? { selectedDay?.notionURL }
}
