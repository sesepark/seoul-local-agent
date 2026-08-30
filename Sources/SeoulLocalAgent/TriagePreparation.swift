import Foundation
import CryptoKit

/// Identifies the evidence a classification was based on, so an item that shows up
/// again unchanged can reuse the previous result instead of being sent to the model.
enum SourceFingerprint {
    static func of(_ item: SourceItem) -> String {
        of(subject: item.subject, body: item.body, timestamp: item.timestamp)
    }

    static func of(subject: String, body: String, timestamp: Date) -> String {
        let material = "\(subject)\u{1}\(body)\u{1}\(Int(timestamp.timeIntervalSince1970))"
        let digest = SHA256.hash(data: Data(material.utf8))
        return digest.compactMap { String(format: "%02x", $0) }.joined().prefix(16).description
    }
}

/// Keeps connector transport wrappers out of both the model prompt and the
/// Notion page. It does not interpret a message; it only removes known Gog
/// framing and collapses layout whitespace.
enum InboxTextSanitizer {
    static func clean(_ value: String) -> String {
        var text = value.precomposedStringWithCanonicalMapping
        text = text.replacingOccurrences(
            of: "<<<EXTERNAL_UNTRUSTED_CONTENT[^>]*>>>",
            with: "",
            options: .regularExpression
        )
        text = text.replacingOccurrences(
            of: "<<<END_EXTERNAL_UNTRUSTED_CONTENT[^>]*>>>",
            with: "",
            options: .regularExpression
        )
        text = text.replacingOccurrences(
            of: "(?im)^\\s*Source:\\s*google_api\\s*-*\\s*",
            with: "",
            options: .regularExpression
        )
        // Attachment placeholders (U+FFFC) arrive from Messages and Mail and carry
        // no meaning for the classifier.
        text = text.replacingOccurrences(of: "\u{FFFC}", with: " ")
        text = text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(1_200))
    }
}

enum InboxEvidenceGate {
    private static let transportOnly: Set<String> = ["google_api", "slack_api", "unknown", "(텍스트 없는 메시지)"]

    static func canonicalBody(body: String, snippet: String, subject: String) -> String {
        let candidates = [body, snippet, subject].map(InboxTextSanitizer.clean)
        for candidate in candidates where isUsable(candidate) { return candidate }
        return ""
    }

    static func isUsable(_ text: String) -> Bool {
        let clean = InboxTextSanitizer.clean(text)
        guard clean.count >= 4 else { return false }
        return !transportOnly.contains(clean.lowercased())
    }
}

/// Group only clearly repeated operational notifications. This deliberately
/// avoids fuzzy semantic merging: an uncertain item stays separate rather than
/// hiding a real request.
enum IncidentGrouper {
    static func group(_ items: [SourceItem]) -> [SourceItem] {
        let buckets = Dictionary(grouping: items, by: incidentKey)
        return buckets.values.compactMap { group in
            guard let first = group.sorted(by: { $0.timestamp > $1.timestamp }).first else { return nil }
            guard group.count > 1 else { return first }
            let links = group.map(\.link).prefix(4).map(\.absoluteString).joined(separator: " | ")
            let combinedBody = "동일 유형 알림 \(group.count)건으로 묶음. 최근 원문: \(first.body) 관련 링크: \(links)"
            return SourceItem(
                id: first.id,
                source: first.source,
                account: first.account,
                author: first.author,
                timestamp: first.timestamp,
                subject: first.subject,
                body: String(combinedBody.prefix(1_200)),
                link: first.link,
                // Losing this would break next-day carry-forward for grouped items.
                stableID: first.stableID
            )
        }
        .sorted(by: { $0.timestamp > $1.timestamp })
    }

    private static func incidentKey(_ item: SourceItem) -> String {
        let raw = "\(item.author) \(item.subject)".lowercased()
        let family: String?
        if raw.contains("payment") || raw.contains("billing") || raw.contains("결제") { family = "payment" }
        else if raw.contains("deployment") || raw.contains("deploy") || raw.contains("배포") { family = "deployment" }
        else if raw.contains("build failed") || raw.contains("빌드 실패") { family = "build-failed" }
        else { family = nil }
        guard let family else { return "unique:\(item.id)" }
        // Values such as a retry count, dollar amount, or date must not split
        // one otherwise identical operational incident into many entries.
        let sender = raw.replacingOccurrences(of: "[^a-z가-힣]", with: "", options: .regularExpression)
        return "\(item.source)|\(sender.prefix(48))|\(family)"
    }
}

enum BriefPresentation {
    static func title(for item: ClassifiedItem) -> String {
        if let value = usable(item.displayTitle, limit: 90) { return presentationText(value) }
        let source = item.sourceItem.source
        let subject = InboxTextSanitizer.clean(item.sourceItem.subject)
        let compact = subject.isEmpty ? "새 항목" : String(subject.prefix(52))
        return "\(source) 확인: \(compact)"
    }

    /// The exact text written into a Notion to_do, and therefore the text the
    /// next day's carry-forward reads back.
    static func todoTitle(for item: ClassifiedItem) -> String {
        let title = title(for: item)
        guard let deadline = deadlineText(item.deadline) else { return title }
        return "\(title) · 마감 \(deadline)"
    }

    struct ParsedDeadline {
        let date: Date
        let includesTime: Bool
    }

    private static let seoul = TimeZone(identifier: "Asia/Seoul") ?? .current

    static func parseDeadline(_ raw: String) -> ParsedDeadline? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        for options in [ISO8601DateFormatter.Options([.withInternetDateTime, .withFractionalSeconds]),
                        ISO8601DateFormatter.Options([.withInternetDateTime])] {
            let parser = ISO8601DateFormatter()
            parser.formatOptions = options
            if let date = parser.date(from: trimmed) { return ParsedDeadline(date: date, includesTime: true) }
        }
        let dateOnly = DateFormatter()
        dateOnly.locale = Locale(identifier: "en_US_POSIX")
        dateOnly.timeZone = seoul
        dateOnly.dateFormat = "yyyy-MM-dd"
        if let date = dateOnly.date(from: trimmed) { return ParsedDeadline(date: date, includesTime: false) }
        return nil
    }

    /// The instant after which a deadline is genuinely past. A date without a time
    /// stays valid until the end of that day in Seoul, so a same-day deadline is not
    /// dropped by a morning run.
    static func deadlineExpiry(_ raw: String) -> Date? {
        guard let parsed = parseDeadline(raw) else { return nil }
        guard !parsed.includesTime else { return parsed.date }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = seoul
        return calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: parsed.date))
    }

    /// The model answers with ISO-8601. Printing that verbatim gave readers
    /// "마감 2026-09-09T18:00:00Z"; this renders it as a Seoul wall-clock time.
    static func deadlineText(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let parsed = parseDeadline(trimmed) else {
            // Anything the model wrote in another shape is shown as-is rather than dropped.
            return String(trimmed.prefix(40))
        }
        let display = DateFormatter()
        display.locale = Locale(identifier: "ko_KR")
        display.timeZone = seoul
        display.dateFormat = parsed.includesTime ? "M월 d일 HH시 mm분" : "M월 d일"
        return display.string(from: parsed.date)
    }

    static func summary(for item: ClassifiedItem) -> String {
        if let value = usable(item.displaySummary, limit: 700) { return presentationText(value) }
        let value = InboxTextSanitizer.clean(item.summary)
        return value.isEmpty ? "원문을 확인해 주세요." : value
    }

    /// A soft quality gate: reject only transport leakage or unusable UI text.
    /// It never retries the model; the deterministic Korean-labelled fallback
    /// above keeps a briefing writable even for an imperfect model response.
    static func usable(_ value: String?, limit: Int) -> String? {
        guard let value else { return nil }
        let text = InboxTextSanitizer.clean(value)
        guard !text.isEmpty, text.count <= limit,
              !text.contains("<<<"), !text.contains("http://"), !text.contains("https://"),
              !text.contains("\n"), !text.contains("- [") else { return nil }
        return text
    }

    private static func presentationText(_ value: String) -> String {
        value
            .replacingOccurrences(of: "^(?:[-*]\\s*)?(?:\\[.?\\]\\s*)?(?:\\*{1,2})?", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\\*{1,2}$", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum BriefingQualityGate {
    static func normalized(_ items: [ClassifiedItem]) -> [ClassifiedItem] {
        items.map { item in
            var result = item
            if !InboxEvidenceGate.isUsable(item.sourceItem.body) {
                result.confidence = 0
                return result
            }
            if result.category == .action, result.pinnedByUserRule != true {
                let evidence = "\(result.sourceItem.subject) \(result.sourceItem.body) \(result.facts ?? "")".lowercased()
                let optionalOpportunity = ["모집", "포럼", "특강", "학술대회", "장학금", "사전등록", "registration", "forum"].contains { evidence.contains($0) }
                    && !["요청", "회신", "제출", "승인", "필수", "required", "must"].contains { evidence.contains($0) }
                if optionalOpportunity || (result.confidence ?? 1) < 0.55 {
                    result = ClassifiedItem(
                        sourceItem: result.sourceItem,
                        facts: result.facts,
                        category: .reference,
                        summary: result.summary,
                        reason: "직접 요청이 아닌 선택 가능한 정보이거나 행동 근거가 부족해 확인 항목으로 이동: \(result.reason)",
                        importance: min(result.importance, 3),
                        nextAction: "원문 확인",
                        deadline: result.deadline,
                        displayTitle: result.displayTitle,
                        displaySummary: result.displaySummary,
                        displayNextAction: "원문 확인",
                        confidence: min(result.confidence ?? 1, 0.5),
                        pinnedByUserRule: result.pinnedByUserRule
                    )
                }
            }
            return result
        }
    }
}

enum ClassifiedIncidentMerger {
    static func merge(_ items: [ClassifiedItem]) -> [ClassifiedItem] {
        let grouped = Dictionary(grouping: items, by: incidentKey)
        return grouped.values.compactMap { group in
            guard var representative = group.max(by: { lhs, rhs in
                if lhs.importance == rhs.importance { return lhs.sourceItem.timestamp < rhs.sourceItem.timestamp }
                return lhs.importance < rhs.importance
            }) else { return nil }
            guard group.count > 1 else { return representative }
            let facts = group.compactMap(\.facts).filter { !$0.isEmpty }
            representative.facts = String(facts.joined(separator: " ").prefix(600))
            representative.displaySummary = "관련 알림 \(group.count)건을 하나로 묶었습니다. \(BriefPresentation.summary(for: representative))"
            return representative
        }.sorted { lhs, rhs in
            if lhs.importance == rhs.importance { return lhs.sourceItem.timestamp > rhs.sourceItem.timestamp }
            return lhs.importance > rhs.importance
        }
    }

    private static func incidentKey(_ item: ClassifiedItem) -> String {
        let raw = "\(item.sourceItem.author) \(item.sourceItem.subject) \(item.facts ?? "")".lowercased()
        let family: String
        if raw.contains("payment") || raw.contains("결제") || raw.contains("invoice") { family = "billing" }
        else if raw.contains("deploy") || raw.contains("배포") || raw.contains("build failed") { family = "deployment" }
        else if raw.contains("refund") || raw.contains("환불") { family = "refund" }
        else if raw.contains("login") || raw.contains("로그인") || raw.contains("oauth") { family = "security" }
        else { return item.trackingID }
        let sender = item.sourceItem.author.lowercased().replacingOccurrences(of: "[^a-z0-9가-힣]", with: "", options: .regularExpression)
        return "\(item.sourceItem.source)|\(sender.prefix(40))|\(family)"
    }
}


/// Decides what an earlier day's briefing still owes today.
///
/// Two things survive into the next report: an action the user has not ticked off
/// in Notion and whose deadline has not passed, and a calendar entry for something
/// that has not happened yet. Everything else belongs to the day it was collected.
enum CarryForwardPolicy {
    struct Outcome {
        var carried: [ClassifiedItem] = []
        /// Unfinished, but past its stated deadline. Counted rather than carried.
        var expired: [ClassifiedItem] = []
    }

    /// `completedIDs` are the `trackingID`s the reader has ticked off in the
    /// 브리핑 보관함. Everything else that was an action yesterday is still an
    /// action today.
    ///
    /// This used to be driven by the set of *unchecked* to_do titles read back
    /// out of the Notion page, which meant two things went wrong quietly: an
    /// item whose generated title changed between runs lost its identity, and
    /// an item past the page's `briefingMaxActions` cut-off was never written
    /// as a to_do at all and so could never be carried. Keying on the tracking
    /// ID and inverting the test — carry unless explicitly finished — fixes
    /// both.
    static func evaluate(previousItems: [ClassifiedItem], completedIDs: Set<String>, now: Date) -> Outcome {
        var outcome = Outcome()
        for item in previousItems {
            if isUpcomingCalendarEntry(item, now: now) {
                outcome.carried.append(item)
                continue
            }
            guard item.category == .action, !completedIDs.contains(item.trackingID) else { continue }
            if let expiry = BriefPresentation.deadlineExpiry(item.deadline), expiry <= now {
                outcome.expired.append(item)
            } else {
                outcome.carried.append(item)
            }
        }
        return outcome
    }

    static func isUpcomingCalendarEntry(_ item: ClassifiedItem, now: Date) -> Bool {
        item.sourceItem.source == SourceName.calendar && item.sourceItem.timestamp > now
    }

    /// Items already covered by a carried-over result, with identical evidence, do
    /// not need to be classified again. This is what keeps an unchanged calendar
    /// entry from being re-summarised on every run.
    static func unchangedItems(in collected: [SourceItem], alreadyCarried carried: [ClassifiedItem]) -> Set<String> {
        var fingerprints: [String: String] = [:]
        for item in carried {
            guard let fingerprint = item.contentFingerprint else { continue }
            fingerprints[item.trackingID] = fingerprint
        }
        guard !fingerprints.isEmpty else { return [] }
        var unchanged = Set<String>()
        for item in collected {
            let key = item.stableID ?? item.id
            guard let fingerprint = fingerprints[key], fingerprint == SourceFingerprint.of(item) else { continue }
            unchanged.insert(item.id)
        }
        return unchanged
    }
}
