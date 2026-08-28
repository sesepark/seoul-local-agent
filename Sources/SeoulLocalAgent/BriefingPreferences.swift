import Foundation

struct BriefingPreferences: Codable, Equatable {
    static let defaultInstructions = """
    나는 서울대학교 전기·정보공학부 학부생이다.
    교수·조교·학사 행정의 직접 요청과 이미 약속하거나 신청한 일은 중요하게 본다.
    장학금·수강·연구·인턴·취업·강연·행사 공지는 직접 요청이 없다면 확인 항목으로 둔다.
    서비스 중단, 결제 실패, 데이터 손실, 운영 장애는 중요하게 본다.
    일반 뉴스레터와 홍보 메일은 기타로 제외한다.
    """

    var userInstructions: String = Self.defaultInstructions
    /// One case-insensitive substring per line. Matches sender, account,
    /// subject, or body. These lists are always visible and editable in UI.
    var ignoredPatterns: [String] = []
    var importantPatterns: [String] = []

    static let defaults = BriefingPreferences()
}

struct BriefingPreferencesStore: Sendable {
    private let url: URL

    init(directory: URL? = nil) {
        let root = directory ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appending(path: "Library/Application Support/SeoulLocalAgent", directoryHint: .isDirectory)
        url = root.appending(path: "briefing-preferences.json")
    }

    func load() -> BriefingPreferences {
        guard let data = try? Data(contentsOf: url),
              let value = try? JSONDecoder().decode(BriefingPreferences.self, from: data) else { return .defaults }
        return value
    }

    func save(_ preferences: BriefingPreferences) throws {
        try LocalFileStorage.write(try JSONEncoder().encode(preferences), to: url)
    }
}

enum BriefingPreferenceRules {
    static func partition(_ items: [SourceItem], preferences: BriefingPreferences) -> (included: [SourceItem], ignored: [SourceItem], importantIDs: Set<String>) {
        var included: [SourceItem] = []
        var ignored: [SourceItem] = []
        var importantIDs = Set<String>()
        for item in items {
            let haystack = "\(item.source) \(item.account) \(item.author) \(item.subject) \(item.body)".lowercased()
            let important = matches(preferences.importantPatterns, in: haystack)
            let ignore = matches(preferences.ignoredPatterns, in: haystack)
            if important {
                included.append(item)
                importantIDs.insert(item.id)
            } else if ignore {
                ignored.append(item)
            } else {
                included.append(item)
            }
        }
        return (included, ignored, importantIDs)
    }

    private static func matches(_ patterns: [String], in haystack: String) -> Bool {
        patterns.lazy.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .contains { !$0.isEmpty && haystack.contains($0) }
    }
}

extension Array where Element == String {
    static func preferenceLines(_ text: String) -> [String] {
        text.split(whereSeparator: \.isNewline).map(String.init).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}
