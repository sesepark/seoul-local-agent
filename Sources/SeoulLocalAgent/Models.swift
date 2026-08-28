import Foundation

enum BriefCategory: String, Codable, CaseIterable {
    case action, reference, excluded
}

struct SourceItem: Codable, Hashable, Identifiable {
    let id: String
    let source: String
    let account: String
    let author: String
    let timestamp: Date
    let subject: String
    let body: String
    let link: URL

    /// Stable across reruns for a conversation/incident. Older state files do
    /// not contain it, so all consumers must fall back to `id`.
    var stableID: String?

    init(id: String, source: String, account: String, author: String, timestamp: Date, subject: String, body: String, link: URL, stableID: String? = nil) {
        self.id = id
        self.source = source
        self.account = account
        self.author = author
        self.timestamp = timestamp
        self.subject = subject
        self.body = body
        self.link = link
        self.stableID = stableID
    }
}

struct ClassifiedItem: Codable, Hashable, Identifiable {
    let sourceItem: SourceItem
    /// Evidence-grounded intermediate card, distinct from reader-facing prose.
    var facts: String?
    let category: BriefCategory
    let summary: String
    let reason: String
    let importance: Int
    let nextAction: String
    let deadline: String
    var displayTitle: String?
    var displaySummary: String?
    var displayNextAction: String?
    var confidence: Double?
    /// Set when the user's own "always important" pattern matched. The heuristic
    /// quality gate must not overrule an explicit user rule.
    var pinnedByUserRule: Bool? = nil
    /// Hash of the evidence this classification was based on. A carried-over item
    /// whose source still hashes the same does not need to be analysed again.
    var contentFingerprint: String? = nil
    var id: String { sourceItem.id }
    var trackingID: String { sourceItem.stableID ?? sourceItem.id }
}

struct DailyBriefing: Codable {
    let dateKey: String
    var items: [ClassifiedItem]
    var sourceCounts: [String: Int]
    var failures: [String]
    var notionURL: URL?
    var updatedAt: Date
    /// What was actually collected for this run. Older state files omit it.
    var collectionRange: String?
    /// Unfinished items from an earlier day whose deadline has already passed, so
    /// the report can say they were dropped instead of losing them silently.
    var expiredCarryOverCount: Int?
}

/// The source labels the pipeline groups and routes by.
enum SourceName {
    static let gmail = "Gmail"
    static let slack = "Slack"
    static let messages = "메시지"
    static let calendar = "캘린더"
    static let ordered = [gmail, slack, messages, calendar]
}

struct PersistentState: Codable {
    var checkpoints: [String: Date] = [:]
    var dailyBriefings: [String: DailyBriefing] = [:]
    var lastNotionURL: URL?
    var lastSuccessAt: Date?
    var lastError: String?

    /// Only recent days are ever reread (same-day merge and one-day carry-forward),
    /// so keeping every briefing forever would grow the state file without bound.
    static let retainedBriefingDays = 30

    static func pruned(_ briefings: [String: DailyBriefing], keeping limit: Int = retainedBriefingDays) -> [String: DailyBriefing] {
        guard briefings.count > limit else { return briefings }
        let kept = briefings.values.sorted { $0.updatedAt > $1.updatedAt }.prefix(limit)
        return Dictionary(uniqueKeysWithValues: kept.map { ($0.dateKey, $0) })
    }
}

extension DailyBriefing {
    /// Carry-forward and same-day merging need identity, dates, links, and the
    /// generated Korean text — never the original message body. Dropping it keeps
    /// mail, Slack, and iMessage contents out of the on-disk checkpoint.
    func withoutSourceBodies() -> DailyBriefing {
        var copy = self
        copy.items = items.map { item in
            let source = item.sourceItem
            let redacted = SourceItem(
                id: source.id, source: source.source, account: source.account, author: source.author,
                timestamp: source.timestamp, subject: source.subject, body: "", link: source.link,
                stableID: source.stableID
            )
            return ClassifiedItem(
                sourceItem: redacted, facts: item.facts, category: item.category, summary: item.summary,
                reason: item.reason, importance: item.importance, nextAction: item.nextAction,
                deadline: item.deadline, displayTitle: item.displayTitle, displaySummary: item.displaySummary,
                displayNextAction: item.displayNextAction, confidence: item.confidence,
                pinnedByUserRule: item.pinnedByUserRule, contentFingerprint: item.contentFingerprint
            )
        }
        return copy
    }
}

enum RunPhase: String {
    case idle = "대기 중"
    case collecting = "수집 중"
    case classifying = "로컬 LLM 분석 중"
    case writing = "Notion 작성 중"
    case completed = "완료"
    case failed = "실패"
    case cancelled = "취소됨"
}

enum CollectionRange: String, CaseIterable, Identifiable {
    case sinceLastSuccess = "마지막 성공 이후 (기본)"
    case day1 = "최근 24시간 재검토"
    case day3 = "최근 3일 재검토"
    case day7 = "최근 7일 재검토"
    case day14 = "최근 14일 재검토"
    case day30 = "최근 30일 재검토"

    var id: String { rawValue }
    var days: Int? {
        switch self {
        case .sinceLastSuccess: nil
        case .day1: 1
        case .day3: 3
        case .day7: 7
        case .day14: 14
        case .day30: 30
        }
    }
}

enum BriefingQualityMode: String, CaseIterable, Identifiable {
    case thorough
    case balanced

    var id: String { rawValue }
    var title: String { self == .thorough ? "정밀 · 권장" : "균형" }
    /// Measured on the local 27B model: roughly 12 seconds per item for the fact
    /// pass and a second pass for the Korean edit, so a 100-item window is tens of
    /// minutes rather than the few minutes the old text implied.
    var explanation: String {
        self == .thorough
            ? "사실 추출 6건·한국어 편집 4건 배치로 처리합니다. 항목 100건 기준 대략 30~50분 걸립니다."
            : "같은 품질 검사를 3건·2건의 짧은 배치로 처리합니다. 한 번의 요청이 짧아 실패 시 손실이 적습니다."
    }
}

enum ASRModelChoice: String, Codable, CaseIterable, Identifiable {
    case qwen06B8Bit
    case qwen06B
    case qwen17B
    case qwen17BSpeculative

    var id: String { rawValue }
    var title: String {
        switch self {
        case .qwen06B8Bit: "초고속 · 0.6B 8-bit"
        case .qwen06B: "균형 · 0.6B"
        case .qwen17B: "정밀 · 1.7B"
        case .qwen17BSpeculative: "실험 · 1.7B + 0.6B 초안"
        }
    }
    var explanation: String {
        switch self {
        case .qwen06B8Bit: return "가장 빠른 권장값. 한국어·영어 품질 손실을 작게 유지하면서 8-bit로 가볍게 실행합니다."
        case .qwen06B: return "0.6B 원본 정밀도. 초고속보다 조금 느리지만 양자화에 따른 품질 손실이 없습니다."
        case .qwen17B: return "현재의 고품질 모델. 잡음, 고유명사, 복잡한 발화에 유리하지만 가장 느립니다."
        case .qwen17BSpeculative: return "1.7B가 결과를 만들고 0.6B가 토큰을 미리 제안합니다. 화자 구분용 모델이 아니며 일부 녹음에서는 더 느릴 수 있습니다."
        }
    }

    var runnerValue: String { rawValue }
}

enum DiarizationChoice: String, Codable, CaseIterable, Identifiable {
    case disabled
    case community1
    case legacy31

    var id: String { rawValue }

    var title: String {
        switch self {
        case .disabled: "사용 안 함 · 가장 빠름"
        case .community1: "Community-1 · 권장"
        case .legacy31: "Legacy 3.1 · 호환용"
        }
    }

    var explanation: String {
        switch self {
        case .disabled: return "음성 인식만 실행합니다. 화자 이름은 붙지 않으며 처리 시간이 가장 짧습니다."
        case .community1: return "최신 공개 pyannote 파이프라인입니다. 기존 3.1보다 전반적인 정확도와 성능이 개선되었습니다."
        case .legacy31: return "이전 pyannote 3.1 결과가 필요한 경우를 위한 선택입니다. 더 빠른 모드는 아닙니다."
        }
    }

    var isEnabled: Bool { self != .disabled }
    var runnerValue: String { rawValue }
}

enum TranscriptionTimestampMode: String, Codable, CaseIterable, Identifiable {
    case none
    case timestamps

    var id: String { rawValue }
    var title: String { self == .none ? "시간 없이" : "시간 포함" }
    var includesTimestamps: Bool { self == .timestamps }
}

enum TranscriptionLanguage: String, Codable, CaseIterable, Identifiable {
    case korean = "Korean"
    case automatic
    case english = "English"

    var id: String { rawValue }
    var title: String {
        switch self {
        case .korean: "한국어"
        case .automatic: "자동 감지"
        case .english: "영어"
        }
    }

    var runnerValue: String? { self == .automatic ? nil : rawValue }
}

/// How the 문서 인식 tab reads a page. Vision ships with macOS and answers
/// instantly but only returns plain text; MinerU is a downloaded document model
/// that keeps formulas as LaTeX and tables as HTML, which is what lecture slides
/// and problem sets in the sciences actually need.
enum DocumentRecognitionMode: String, CaseIterable, Identifiable, Sendable {
    case vision
    case precise

    var id: String { rawValue }

    var title: String {
        switch self {
        case .vision: "빠름 (macOS 내장)"
        case .precise: "정밀 (수식·표)"
        }
    }

    var detail: String {
        switch self {
        case .vision: "다운로드 없이 즉시 글자만 뽑습니다. 수식과 표는 깨집니다."
        case .precise: "수식을 LaTeX로, 표를 표 그대로 살려 Markdown으로 만듭니다. 첫 실행에 모델을 내려받습니다."
        }
    }

    var producesMarkdown: Bool { self == .precise }
}

enum AppSection: String, CaseIterable, Identifiable {
    case overview, transcription, documents, cutout, briefing, settings
    var id: String { rawValue }
    var title: String {
        switch self {
        case .overview: "개요"
        case .transcription: "녹음·전사"
        case .documents: "문서 인식"
        case .cutout: "누끼 따기"
        case .briefing: "자동 브리핑"
        case .settings: "설정"
        }
    }
    var symbol: String {
        switch self {
        case .overview: "square.grid.2x2"
        case .transcription: "waveform"
        case .documents: "text.viewfinder"
        case .cutout: "person.and.background.dotted"
        case .briefing: "tray.full"
        case .settings: "gearshape"
        }
    }
}

enum AgentError: LocalizedError {
    case invalidNotionParent
    case invalidClassification
    case cancelled
    case processFailed(String)
    case missingCredential(String)

    var errorDescription: String? {
        switch self {
        case .invalidNotionParent: "Notion 쓰기 대상 allowlist 검증에 실패했습니다."
        case .invalidClassification: "로컬 모델의 분류 응답 형식이 안전 검증을 통과하지 못했습니다."
        case .cancelled: "사용자가 실행을 중지했습니다."
        case .processFailed(let message), .missingCredential(let message): message
        }
    }
}
