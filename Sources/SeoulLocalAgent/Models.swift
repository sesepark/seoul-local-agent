import SwiftUI
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
    /// Who the item was addressed to, when that changes what counts as relevant.
    /// A notice from another college's board is written for that college, so only
    /// something this user could personally apply to is worth reporting.
    var audience: String?

    init(id: String, source: String, account: String, author: String, timestamp: Date, subject: String, body: String, link: URL, stableID: String? = nil, audience: String? = nil) {
        self.id = id
        self.source = source
        self.account = account
        self.author = author
        self.timestamp = timestamp
        self.subject = subject
        self.body = body
        self.link = link
        self.stableID = stableID
        self.audience = audience
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
    static let web = "웹 공지"
    static let ordered = [gmail, slack, messages, calendar, web]
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
                stableID: source.stableID, audience: source.audience
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
    /// Measured on the local MoE model after the classification and the Korean
    /// report text were merged into one call: 3.6 to 6.0 seconds per item for 정밀
    /// depending on what else the machine is doing, so a 100-item window is minutes
    /// rather than the tens of minutes the dense 27B model and its second pass needed.
    var explanation: String {
        self == .thorough
            ? "한 요청에 6건씩 묶어 분류와 한국어 브리핑 문장을 한 번에 만듭니다. 항목 100건 기준 대략 10분 걸립니다."
            : "같은 품질 검사를 3건씩의 짧은 배치로 처리합니다. 한 번의 요청이 짧아 실패 시 손실이 적습니다."
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

/// The sidebar. Settings deliberately is *not* a case: macOS puts settings in a
/// ⌘, window, and keeping it here as a peer made the list read as a flat pile of
/// unrelated things.
///
/// Declaration order *is* sidebar order, which is also what `⌘1`…`⌘0` follow, so
/// a case moved here moves on screen and under the user's fingers together.
enum AppSection: String, CaseIterable, Identifiable {
    case overview
    case documents, scan, pdf
    case transcription, audioCleanup, cutout, upscale
    case compression, convert
    case briefing, archive

    var id: String { rawValue }

    /// The name in the sidebar *and* in the window title bar. Screens used to
    /// re-state a slightly different title inside their own content — the
    /// sidebar said 녹음·전사 while the screen said 녹음 전사 — so there is now
    /// exactly one string per screen.
    var title: String {
        switch self {
        case .overview: "개요"
        case .documents: "문서 인식"
        case .scan: "스캔 보정"
        case .pdf: "PDF 편집"
        case .transcription: "녹음·전사"
        case .audioCleanup: "소리 다듬기"
        case .cutout: "누끼 따기"
        case .upscale: "화질 올리기"
        case .compression: "용량 줄이기"
        case .convert: "형식 변환"
        case .briefing: "자동 브리핑"
        case .archive: "브리핑 보관함"
        }
    }

    var subtitle: String {
        switch self {
        case .overview: "이 Mac에서 도는 것들의 현재 상태입니다. 아래에서 바로 이어서 할 수 있습니다."
        case .documents: "강의 슬라이드 사진, 스캔한 유인물 PDF, 화면의 일부를 텍스트로 바꿉니다. 어느 쪽을 고르든 이미지가 이 Mac을 벗어나지 않습니다."
        case .scan: "비스듬히 찍은 유인물 사진을 반듯하게 펴고 그늘을 지워 스캔한 것처럼 만듭니다. 여러 장을 한 PDF로 묶을 수 있습니다."
        case .pdf: "PDF를 합치고 나누고 쪽을 정리합니다. 암호를 걸거나 풀고, 서명 이미지와 워터마크를 얹습니다."
        case .transcription: "앱에서 바로 녹음하거나 파일을 드롭해 한국어 전사를 만듭니다. 여러 전사와 AI 자동요약은 대기열에 추가한 순서대로 하나씩 처리됩니다."
        case .audioCleanup: "강의·회의 녹음에서 에어컨 소리와 웅성거림을 걷어내고 음량을 고르게 맞춥니다. 영상을 넣으면 소리만 꺼내 다듬습니다."
        case .cutout: "사진을 드롭하면 배경을 지운 투명 PNG를 만듭니다. 모델은 이 Mac에서만 실행되고 사진은 기기를 벗어나지 않습니다."
        case .upscale: "작거나 흐린 사진을 크고 또렷하게 만듭니다. 뒷자리에서 찍은 슬라이드나 저해상도 스캔에 씁니다."
        case .compression: "사진·PDF·영상의 용량을 이 Mac에서 줄입니다. 파일은 기기를 벗어나지 않고 원본도 그대로 남습니다."
        case .convert: "사진·오디오·영상·문서를 다른 형식으로 바꿉니다. 필요한 것은 전부 이 Mac 안에서 처리합니다."
        case .briefing: "메일·메시지·웹 공지를 모아 이 Mac의 모델로 정리합니다. 수집부터 저장까지의 상태를 여기서 봅니다."
        case .archive: "정리된 결과가 날짜별로 쌓입니다. 끝낸 일을 체크하고, 남은 일은 Mac 캘린더나 미리 알림으로 바로 넘깁니다."
        }
    }

    /// A few words for the launcher grid on 개요, where the full subtitle would
    /// not fit and nine tools is more than anyone remembers by name alone.
    var hint: String {
        switch self {
        case .overview: "지금 상태와 이어서 할 일"
        case .documents: "사진·PDF에서 글자 뽑기"
        case .scan: "찍은 유인물을 반듯한 스캔으로"
        case .pdf: "합치기·나누기·서명·암호"
        case .transcription: "녹음하고 한국어로 받아쓰기"
        case .audioCleanup: "잡음 빼고 음량 고르게"
        case .cutout: "배경 지운 투명 PNG"
        case .upscale: "작고 흐린 사진을 크게"
        case .compression: "사진·PDF·영상 용량 줄이기"
        case .convert: "다른 형식으로 바꾸기"
        case .briefing: "메일·공지 모아 정리하기"
        case .archive: "정리된 할 일과 캘린더 연동"
        }
    }

    var symbol: String {
        switch self {
        case .overview: "square.grid.2x2"
        case .documents: "text.viewfinder"
        case .scan: "doc.viewfinder"
        case .pdf: "doc.on.doc"
        case .transcription: "waveform"
        case .audioCleanup: "waveform.path.badge.minus"
        case .cutout: "person.and.background.dotted"
        // Deliberately the mirror image of 용량 줄이기: the two tools do opposite
        // things and the sidebar should say so before the label is read.
        case .upscale: "arrow.up.left.and.arrow.down.right"
        case .compression: "arrow.down.right.and.arrow.up.left"
        case .convert: "arrow.triangle.2.circlepath"
        case .briefing: "tray.full"
        case .archive: "checklist"
        }
    }

    /// ⌘1…⌘9 then ⌘0, in sidebar order. The screens past the number row take a
    /// letter instead — the same answer Apple's own apps reach when a sidebar
    /// outgrows ten rows. 자동 브리핑 and its 보관함 are one subject with two
    /// screens, so they share ⌘B and ⇧⌘B rather than taking unrelated letters.
    var shortcut: KeyEquivalent {
        switch self {
        case .overview: "1"
        case .documents: "2"
        case .scan: "3"
        case .pdf: "4"
        case .transcription: "5"
        case .audioCleanup: "6"
        case .cutout: "7"
        case .upscale: "8"
        case .compression: "9"
        case .convert: "0"
        case .briefing, .archive: "b"
        }
    }

    var shortcutModifiers: EventModifiers {
        self == .archive ? [.command, .shift] : .command
    }

    /// Which heading the row sits under. A flat list of eleven would read as a
    /// pile of unrelated things; grouped by what the user is holding — a
    /// document, a recording or a photo, a file to convert — it reads as a menu.
    enum Group: String, CaseIterable, Identifiable {
        case start = "시작"
        case documents = "문서"
        case media = "미디어"
        case files = "변환"
        case automation = "자동화"

        var id: String { rawValue }

        var members: [AppSection] {
            switch self {
            case .start: [.overview]
            case .documents: [.documents, .scan, .pdf]
            case .media: [.transcription, .audioCleanup, .cutout, .upscale]
            case .files: [.compression, .convert]
            case .automation: [.briefing, .archive]
            }
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
