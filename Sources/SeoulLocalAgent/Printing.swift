import Foundation

// MARK: - 서버가 말해 주는 것

/// 집 서버 CUPS에 등록된 프린터 하나.
///
/// 이 앱은 프린터를 직접 알지 못한다. USB로 서버에 붙어 있는 것은 서버가 쥐고 있고, 여기
/// 있는 값은 전부 `lpstat`이 방금 말해 준 것을 옮겨 적은 것이다. 로봇 팔에서와 같은
/// 규칙이다 — 앱이 낙관적으로 먼저 상태를 그리면, 그 낙관이 틀렸을 때 화면이 종이를 물고
/// 멈춰 있는 기계에 대해 거짓말을 한다.
struct RemotePrinter: Identifiable, Equatable, Sendable {
    enum State: Equatable, Sendable {
        case idle
        case printing
        case stopped

        var title: String {
            switch self {
            case .idle: "대기 중"
            case .printing: "인쇄 중"
            case .stopped: "멈춰 있음"
            }
        }

        var symbol: String {
            switch self {
            case .idle: "printer"
            case .printing: "printer.filled.and.paper"
            case .stopped: "exclamationmark.triangle.fill"
            }
        }
    }

    let name: String
    var state: State = .idle
    /// CUPS가 덧붙인 한 줄. `media-empty-warning` 같은 기계 말이라도 그대로 싣는다 —
    /// 옮겨 적으면서 잃는 것이, 읽기 어려워서 잃는 것보다 크다.
    var reason = ""
    var isDefault = false

    var id: String { name }

    /// 큐 이름은 `Samsung_C48x`처럼 밑줄이 그대로 보인다. 사람이 읽는 자리에서만 고친다.
    var displayName: String { name.replacingOccurrences(of: "_", with: " ") }
}

/// PPD가 실제로 내주는 선택지. 화면의 픽커는 이것으로만 만든다.
///
/// 고정된 목록을 쓰지 않는 이유가 있다. 이 집 프린터는 양면 장치가 **달려 있지 않고**
/// (`Option1/Duplexer: *False`), 컬러/흑백을 고르는 항목이 PPD에 아예 없다. 앱이 "양면"
/// 스위치를 그려 놓으면 눌러도 아무 일이 일어나지 않는 스위치가 되고, 그것은 없는 것보다
/// 나쁘다. 프린터가 바뀌어도 같은 규칙으로 따라간다.
struct PrinterCapabilities: Equatable, Sendable {
    struct Option: Equatable, Sendable {
        let keyword: String
        let label: String
        var choices: [String]
        /// `*`가 붙어 있던 값. 없으면 빈 문자열.
        var current: String
    }

    var options: [Option] = []

    func option(_ keyword: String) -> Option? { options.first { $0.keyword == keyword } }

    /// 넣을 수 있는 용지. PPD 순서 그대로이되, 학생이 실제로 쓰는 것부터 앞으로 당긴다.
    var pageSizes: [String] {
        let all = option("PageSize")?.choices ?? []
        guard !all.isEmpty else { return ["A4"] }
        let preferred = ["A4", "Letter", "A5", "B5", "Legal", "A3"]
        let front = preferred.filter(all.contains)
        return front + all.filter { !front.contains($0) }
    }

    var defaultPageSize: String {
        let current = option("PageSize")?.current ?? ""
        if !current.isEmpty, current != "Default" { return current }
        return pageSizes.contains("A4") ? "A4" : (pageSizes.first ?? "A4")
    }

    /// 양면을 걸 수 있는가. 선택지가 있는 것과 **장치가 달려 있는 것**은 다르다.
    ///
    /// PPD에는 `Duplex` 항목이 언제나 들어 있지만, 그 옆의 설치 옵션(`Option1/Duplexer`)이
    /// `False`이면 그 프린터에는 양면 장치가 없다. 그 상태에서 `sides=two-sided-…`를 보내면
    /// 한 면만 찍히거나 그냥 무시된다.
    var supportsDuplex: Bool {
        guard let duplex = option("Duplex"), duplex.choices.count > 1 else { return false }
        guard let installed = installableDuplexer else { return true }
        return installed
    }

    private var installableDuplexer: Bool? {
        guard let option = options.first(where: {
            $0.label.localizedCaseInsensitiveContains("duplex")
                && Set($0.choices) == ["True", "False"]
        }) else { return nil }
        return option.current == "True"
    }

    /// PPD가 컬러/흑백을 고르게 해 주는가. 이 집 프린터는 해 주지 않는다.
    var supportsColorModel: Bool { (option("ColorModel")?.choices.count ?? 0) > 1 }
}

/// 서버 큐에 들어 있는 작업 하나.
struct PrintQueueEntry: Identifiable, Equatable, Sendable {
    let id: String
    var owner: String
    var bytes: Int
    var submitted: String
}

// MARK: - lpstat·lpoptions 읽기

/// CUPS 명령들이 내놓는 사람용 출력을 값으로 바꾼다.
///
/// 전부 순수 함수다. 서버 없이 시험할 수 있어야 하고, 여기가 틀리면 화면 전체가 조용히
/// 틀린 것을 말하게 되므로 시험이 붙는 자리는 여기다.
enum CUPSOutput {
    /// `lpstat -p -d`.
    static func printers(_ text: String) -> [RemotePrinter] {
        var found: [RemotePrinter] = []
        var defaultName = ""
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            if line.hasPrefix("printer ") {
                let rest = line.dropFirst("printer ".count)
                guard let name = rest.split(separator: " ", maxSplits: 1).first.map(String.init) else { continue }
                var printer = RemotePrinter(name: name)
                if line.contains("now printing") {
                    printer.state = .printing
                } else if line.contains("disabled since") || line.contains("is stopped") {
                    printer.state = .stopped
                } else {
                    printer.state = .idle
                }
                // `… disabled since <날짜> - 종이 없음` 의 꼬리.
                if let dash = line.range(of: " - ", options: .backwards) {
                    printer.reason = String(line[dash.upperBound...]).trimmingCharacters(in: .whitespaces)
                }
                found.append(printer)
            } else if line.hasPrefix("\t") || line.hasPrefix("    ") {
                // 앞 줄에 딸린 사유. 빈 것이면 채운다.
                let detail = line.trimmingCharacters(in: .whitespaces)
                if !detail.isEmpty, !found.isEmpty, found[found.count - 1].reason.isEmpty {
                    found[found.count - 1].reason = detail
                }
            } else if let range = line.range(of: "system default destination: ") {
                defaultName = String(line[range.upperBound...]).trimmingCharacters(in: .whitespaces)
            }
        }
        return found.map { printer in
            var printer = printer
            printer.isDefault = printer.name == defaultName
            return printer
        }
    }

    /// `lpoptions -p 이름 -l`.
    ///
    /// 한 줄이 `키워드/사람이 읽는 이름: 선택지 선택지 …`이고, 지금 값에 `*`가 붙는다.
    static func capabilities(_ text: String) -> PrinterCapabilities {
        var options: [PrinterCapabilities.Option] = []
        for rawLine in text.split(separator: "\n") {
            let line = String(rawLine)
            guard let colon = line.firstIndex(of: ":") else { continue }
            let head = String(line[line.startIndex..<colon])
            guard let slash = head.firstIndex(of: "/") else { continue }
            let keyword = String(head[head.startIndex..<slash])
            let label = String(head[head.index(after: slash)...])
            var choices: [String] = []
            var current = ""
            for token in line[line.index(after: colon)...].split(separator: " ") {
                if token.hasPrefix("*") {
                    let value = String(token.dropFirst())
                    current = value
                    choices.append(value)
                } else {
                    choices.append(String(token))
                }
            }
            guard !choices.isEmpty else { continue }
            options.append(.init(keyword: keyword, label: label, choices: choices, current: current))
        }
        return PrinterCapabilities(options: options)
    }

    /// `lpstat -o`.
    static func queue(_ text: String) -> [PrintQueueEntry] {
        text.split(separator: "\n").compactMap { rawLine in
            let fields = rawLine.split(separator: " ", omittingEmptySubsequences: true)
            guard fields.count >= 3, let bytes = Int(fields[2]) else { return nil }
            let id = String(fields[0])
            // 작업 번호는 `큐이름-번호` 꼴이다. 아닌 줄은 큐 목록이 아니다.
            guard id.contains("-"), Int(id.split(separator: "-").last ?? "") != nil else { return nil }
            return PrintQueueEntry(
                id: id,
                owner: String(fields[1]),
                bytes: bytes,
                submitted: fields.dropFirst(3).joined(separator: " ")
            )
        }
    }

    /// `lp`가 성공했을 때의 한 줄: `request id is Samsung_C48x-12 (1 file(s))`.
    static func jobID(_ text: String) -> String? {
        guard let range = text.range(of: "request id is ") else { return nil }
        let rest = text[range.upperBound...]
        let id = rest.split(separator: " ", maxSplits: 1).first.map(String.init) ?? ""
        return id.isEmpty ? nil : id
    }
}

// MARK: - 보내는 방법

/// 한 번의 인쇄에 붙는 선택들.
///
/// 값은 IPP 이름(`sides`, `media`, `number-up`)으로 적는다. PPD마다 다른 이름(`Duplex`,
/// `PageSize`)을 쓰면 프린터를 바꾼 날 조용히 무시되기 시작한다.
struct PrintOptions: Equatable, Sendable, Codable {
    enum Sides: String, CaseIterable, Identifiable, Sendable, Codable {
        case oneSided = "one-sided"
        case twoSidedLongEdge = "two-sided-long-edge"
        case twoSidedShortEdge = "two-sided-short-edge"

        var id: String { rawValue }

        var title: String {
            switch self {
            case .oneSided: "단면"
            case .twoSidedLongEdge: "양면 (긴 쪽으로 넘김)"
            case .twoSidedShortEdge: "양면 (짧은 쪽으로 넘김)"
            }
        }
    }

    var copies = 1
    /// 비어 있으면 전부. `1-4,8,11-` 꼴.
    var pageRange = ""
    var paper = "A4"
    var sides: Sides = .oneSided
    var numberUp = 1
    /// 서버에서 회색조 PDF로 바꿔 보낸다. PPD에 컬러 항목이 없는 프린터에서 흑백으로
    /// 찍을 수 있는 유일한 길이다.
    var grayscale = false
    var fitToPage = true

    /// 사람이 적은 쪽 범위가 CUPS가 받아들이는 꼴인가.
    static func isValidRange(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return true }
        // 빈 조각을 버리면 `1,,2`가 통과한다. CUPS는 그것을 받지 않는다.
        for part in trimmed.split(separator: ",", omittingEmptySubsequences: false) {
            let piece = part.trimmingCharacters(in: .whitespaces)
            guard !piece.isEmpty else { return false }
            let bounds = piece.split(separator: "-", omittingEmptySubsequences: false)
            switch bounds.count {
            case 1:
                guard let value = Int(bounds[0]), value > 0 else { return false }
            case 2:
                let low = bounds[0].isEmpty ? 1 : Int(bounds[0]) ?? 0
                let high = bounds[1].isEmpty ? Int.max : Int(bounds[1]) ?? 0
                guard low > 0, high >= low else { return false }
            default:
                return false
            }
        }
        return true
    }

    /// 이 설정으로 몇 장의 종이가 나오는가.
    ///
    /// 쪽수가 아니라 **종이 수**를 세는 이유는, 트레이에 남은 종이와 비교할 수 있는 숫자가
    /// 그것뿐이기 때문이다. 모아찍기와 양면은 둘 다 종이를 줄인다.
    func sheets(forPages pages: Int) -> Int {
        guard pages > 0 else { return 0 }
        let perSheetSide = max(1, numberUp)
        var sides = Int(ceil(Double(pages) / Double(perSheetSide)))
        if self.sides != .oneSided { sides = Int(ceil(Double(sides) / 2)) }
        return sides * max(1, copies)
    }

    func lpArguments(printer: String, title: String) -> [String] {
        var arguments = ["lp"]
        if !printer.isEmpty { arguments += ["-d", printer] }
        arguments += ["-n", String(max(1, copies))]
        arguments += ["-t", title]
        arguments += ["-o", "media=\(paper)"]
        arguments += ["-o", "sides=\(sides.rawValue)"]
        if numberUp > 1 { arguments += ["-o", "number-up=\(numberUp)"] }
        if fitToPage { arguments += ["-o", "fit-to-page"] }
        let range = pageRange.trimmingCharacters(in: .whitespaces)
        if !range.isEmpty { arguments += ["-o", "page-ranges=\(range)"] }
        if copies > 1 { arguments += ["-o", "collate=true"] }
        arguments += ["--", "-"]
        return arguments
    }
}

// MARK: - 서버로 가는 길

enum PrintError: LocalizedError, Equatable {
    case notConfigured
    case unreachable(String)
    case commandFailed(String)
    case noPrinter

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            "집 서버 주소가 설정되어 있지 않습니다. 설정 › 프린터에서 넣어 주세요."
        case .unreachable(let detail):
            detail
        case .commandFailed(let detail):
            detail
        case .noPrinter:
            "서버에 등록된 프린터가 없습니다. 서버에서 `lpstat -p`로 확인해 주세요."
        }
    }
}

/// 마지막으로 실제로 열린 주소를 앱이 도는 동안만 기억한다.
///
/// `SOArmTunnel`이 같은 것을 하고 있지만 이 길은 그 터널을 쓰지 않으므로(포워딩이 필요 없고,
/// 명령 하나를 돌리고 끝난다) 기억도 따로 둔다. 집과 밖을 오갈 때 매번 닿지 않는 주소의
/// 시간 초과를 먼저 기다릴 이유가 없다는 것이 이 기억의 전부다.
private final class PrinterHostMemory: @unchecked Sendable {
    static let shared = PrinterHostMemory()
    private let lock = NSLock()
    private var host: String?

    var remembered: String? {
        lock.lock()
        defer { lock.unlock() }
        return host
    }

    func remember(_ value: String) {
        lock.lock()
        host = value
        lock.unlock()
    }

    func forget() {
        lock.lock()
        host = nil
        lock.unlock()
    }
}

/// 집 서버에 명령 하나를 보내고 그 대답을 받아 온다.
///
/// ## 집에서도 밖에서도
///
/// 이 맥은 집에도 있고 밖에도 있다. 그래서 로봇 화면과 **똑같이** 주소를 두 개 두고
/// (`host` = 집 LAN, `alternateHost` = Tailscale) 먼저 열리는 쪽을 쓴다. 주소를 하나로
/// 합치자는 이야기는 하지 않는다 — tailnet 주소만 남기면 Tailscale이 꺼진 날 집에서도
/// 못 닿고, LAN 주소만 남기면 밖에서 아무것도 못 한다. 두 길은 서로의 대비책이다.
///
/// ## 프로세스는 반드시 죽는다
///
/// `ActiveProcessRegistry`에 등록하고, 명령줄에 표식을 심어 두고, 시간 초과에서는 신호를
/// 보낸 뒤 죽인다. 앱이 끝날 때 남아 있는 ssh가 없어야 한다.
struct PrinterLink: Sendable {
    /// 원격에서는 셸 주석이고, 로컬 `ps` 출력에는 남는다.
    static let marker = "seoul-local-agent-print"

    struct Reply: Sendable {
        var output: String
        /// 실제로 대답한 주소. 화면이 "집에서 붙었는지 밖에서 붙었는지"를 말할 수 있게 한다.
        var host: String
    }

    let server: SOArmServer
    var key = SOArmTunnelKey()

    static func arguments(server: SOArmServer, host: String, key: SOArmTunnelKey, command: String) -> [String] {
        [
            "-T",
            "-o", "BatchMode=yes",
            // 주소가 둘이면 짧게 끊는다. 밖에 있을 때 집 주소는 대답하지 않고 시간만 쓰는데,
            // 그 시간이 길면 화면이 그만큼 비어 있다.
            "-o", "ConnectTimeout=\(server.candidateHosts.count > 1 ? 4 : 8)",
            "-o", "ServerAliveInterval=15",
            "-o", "ServerAliveCountMax=3",
            // `~/.ssh`는 샌드박스 밖의 보호 폴더라 앱이 읽지 못한다. 이 앱 전용 열쇠만 쓴다.
            "-i", key.privateKey.path,
            "-o", "IdentitiesOnly=yes",
            "-o", "UserKnownHostsFile=\(key.knownHosts.path)",
            "-o", "StrictHostKeyChecking=accept-new",
            "-p", String(server.sshPort),
            server.sshTarget(host: host),
            "\(command) # \(marker)",
        ]
    }

    /// 시도할 주소 순서. 지난번에 열린 것이 맨 앞으로 온다.
    private var hosts: [String] {
        let all = server.sanitised().candidateHosts
        guard let remembered = PrinterHostMemory.shared.remembered, all.contains(remembered) else { return all }
        return [remembered] + all.filter { $0 != remembered }
    }

    /// - Parameters:
    ///   - sending: stdin으로 흘려보낼 파일. 서버에 임시 파일을 만들지 않기 위한 것이다 —
    ///     `lp`가 스풀로 복사해 가므로 남길 것이 없고, 지울 것도 없다.
    ///   - progress: 보낸 비율. 밖에서 모바일 데이터로 큰 PDF를 보낼 때 이것이 없으면
    ///     화면이 멈춘 것처럼 보인다.
    func run(
        _ command: String,
        sending file: URL? = nil,
        timeout: Double = 20,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> Reply {
        let server = server.sanitised()
        guard server.isConfigured else { throw PrintError.notConfigured }
        try key.ensureExists()

        var failures: [(host: String, reason: String)] = []
        for host in hosts {
            do {
                let output = try await execute(
                    command, host: host, server: server, file: file, timeout: timeout, progress: progress
                )
                PrinterHostMemory.shared.remember(host)
                return Reply(output: output, host: host)
            } catch let error as PrintError {
                guard case .unreachable(let reason) = error else { throw error }
                failures.append((host, reason))
            }
        }
        PrinterHostMemory.shared.forget()
        throw PrintError.unreachable(
            SOArmTunnel.failureText(failures, server: server, key: key)
        )
    }

    /// ssh 하나를 돌리고 stdout을 돌려준다.
    ///
    /// 연결이 안 된 것(`.unreachable`)과 원격 명령이 실패한 것(`.commandFailed`)을 가른다.
    /// 앞의 것만 다음 주소로 넘어갈 이유가 되고, 뒤의 것은 어느 주소로 가도 같은 답이 온다.
    /// ssh는 자기 문제일 때 255로 끝나므로 그것이 경계선이다.
    private func execute(
        _ command: String, host: String, server: SOArmServer, file: URL?,
        timeout: Double, progress: (@Sendable (Double) -> Void)?
    ) async throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = Self.arguments(server: server, host: host, key: key, command: command)
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        let input = file == nil ? nil : Pipe()
        if let input {
            process.standardInput = input
        } else {
            process.standardInput = FileHandle.nullDevice
        }

        do {
            try process.run()
        } catch {
            throw PrintError.unreachable("ssh를 실행하지 못했습니다: \(error.localizedDescription)")
        }
        ActiveProcessRegistry.shared.add(process)
        defer { ActiveProcessRegistry.shared.remove(process) }

        if let input, let file {
            Self.feed(file, into: input, progress: progress)
        }
        // 파이프는 자식이 도는 동안 비워 줘야 한다. 끝난 뒤에 읽으면 출력이 버퍼보다 클 때
        // 서로를 기다리며 멈춘다.
        let outputReader = Task.detached { output.fileHandleForReading.readDataToEndOfFile() }
        let errorReader = Task.detached { errors.fileHandleForReading.readDataToEndOfFile() }

        let deadline = Date().addingTimeInterval(timeout)
        var timedOut = false
        while process.isRunning {
            if Task.isCancelled { break }
            if Date() > deadline {
                timedOut = true
                break
            }
            try? await Task.sleep(for: .milliseconds(60))
        }
        if process.isRunning {
            process.terminate()
            for _ in 0..<20 where process.isRunning { try? await Task.sleep(for: .milliseconds(50)) }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
        let stdout = String(decoding: await outputReader.value, as: UTF8.self)
        let stderr = String(decoding: await errorReader.value, as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.contains("Permanently added") }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if Task.isCancelled { throw CancellationError() }
        if timedOut {
            throw PrintError.unreachable("\(host): \(Int(timeout))초 안에 대답하지 않았습니다")
        }
        let status = process.terminationStatus
        guard status != 0 else { return stdout }
        if status == 255 {
            throw PrintError.unreachable(stderr.isEmpty ? "연결하지 못했습니다" : stderr)
        }
        let detail = stderr.isEmpty ? stdout.trimmingCharacters(in: .whitespacesAndNewlines) : stderr
        throw PrintError.commandFailed(detail.isEmpty ? "서버에서 명령이 \(status)로 끝났습니다." : detail)
    }

    /// 파일을 stdin으로 흘려보낸다.
    ///
    /// 협력 스레드가 아니라 별도 큐인 이유: 파이프가 가득 차면 쓰기가 **막힌다.** 그 막힘이
    /// Swift 동시성의 스레드에서 일어나면 다른 작업들까지 함께 서 버린다.
    private static func feed(_ file: URL, into pipe: Pipe, progress: (@Sendable (Double) -> Void)?) {
        let handle = pipe.fileHandleForWriting
        DispatchQueue.global(qos: .utility).async {
            defer { try? handle.close() }
            guard let reader = try? FileHandle(forReadingFrom: file) else { return }
            defer { try? reader.close() }
            let attributes = try? FileManager.default.attributesOfItem(atPath: file.path)
            let total = (attributes?[.size] as? Int) ?? 0
            var sent = 0
            while true {
                guard let chunk = try? reader.read(upToCount: 256 * 1024), !chunk.isEmpty else { break }
                do {
                    try handle.write(contentsOf: chunk)
                } catch {
                    // 원격이 먼저 끝났다. 종료 상태가 이유를 말해 줄 것이므로 여기서는 조용히 그만둔다.
                    return
                }
                sent += chunk.count
                if total > 0 { progress?(min(1, Double(sent) / Double(total))) }
            }
            progress?(1)
        }
    }
}

// MARK: - 명령 만들기

/// 서버에서 돌릴 셸 한 줄을 만든다.
enum PrintCommand {
    /// 작은따옴표로 감싼다. 파일 이름에 공백·따옴표·한글이 들어와도 셸이 쪼개지 않는다.
    static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// 상태·선택지·큐를 **한 번의 왕복으로** 모두 읽어 온다.
    ///
    /// 셋으로 나누면 밖에서 쓸 때 왕복 지연이 세 배가 된다. 집 안에서는 티가 안 나지만
    /// 모바일 데이터로 붙어 있을 때는 화면이 눈에 띄게 늦게 찬다.
    static func inspect(printer: String) -> String {
        let target = printer.isEmpty ? "" : "-p \(quote(printer)) "
        return [
            "printf '@@PRINTERS@@\\n'; lpstat -p -d 2>&1",
            "printf '@@OPTIONS@@\\n'; lpoptions \(target)-l 2>&1",
            "printf '@@QUEUE@@\\n'; lpstat -o 2>&1",
            "printf '@@GS@@\\n'; command -v gs 2>/dev/null || true",
        ].joined(separator: "; ")
    }

    /// stdin으로 들어온 PDF를 큐에 넣는 한 줄.
    ///
    /// 서버에 임시 파일을 만들지 않는다. `lp`는 받은 것을 그 자리에서 스풀로 복사하므로
    /// 남는 것이 없고, 지울 것도 없고, 중간에 끊겨도 서버에 조각이 남지 않는다.
    static func send(options: PrintOptions, printer: String, title: String, grayscaleAvailable: Bool) -> String {
        let lp = options.lpArguments(printer: printer, title: title).map(quote).joined(separator: " ")
        guard options.grayscale, grayscaleAvailable else { return lp }
        // PPD에 컬러 항목이 없는 프린터에서 흑백으로 찍는 유일한 길: 문서 자체를 회색조로
        // 바꾼다. 래스터로 굽지 않으므로 글자는 글자로 남는다.
        let gs = [
            "gs", "-q", "-dNOPAUSE", "-dBATCH", "-dSAFER",
            "-sDEVICE=pdfwrite", "-sColorConversionStrategy=Gray",
            "-dProcessColorModel=/DeviceGray", "-sOutputFile=-", "-",
        ].joined(separator: " ")
        // `pipefail`이 없으면 gs가 죽어도 lp의 성공이 그대로 성공으로 보인다.
        return "set -o pipefail; \(gs) | \(lp)"
    }

    static func cancel(_ job: String) -> String { "cancel \(quote(job))" }

    /// 제목은 서버 큐와 작업 목록에 그대로 보인다. 줄바꿈과 따옴표만 걷어 내고 길이를 자른다.
    static func title(for name: String) -> String {
        let cleaned = name
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespaces)
        let prefix = String(cleaned.prefix(80))
        return prefix.isEmpty ? "SeoulLocalAgent" : prefix
    }
}

// MARK: - 창 없이 확인하기

/// `--printer-check`. 창을 열지 않고 프린터까지 가는 길을 확인한다.
///
/// `--soarm-check`와 같은 자리의 도구다. 그런데 이쪽은 **주소를 하나씩 따로** 두드린다.
/// 이 맥은 집에도 있고 밖에도 있으므로, "닿았다"는 한 줄로는 집 주소가 살아 있는지 밖에서
/// 쓸 주소가 살아 있는지 알 수 없다. 실제로 필요한 답은 그 두 줄이다.
enum PrintConnectionCheck {
    static func run() async -> Bool {
        let server = SOArmServerStore().load()
        guard server.isConfigured else {
            print("❌ 집 서버 주소가 없습니다. 설정 › 로봇에서 주소와 계정을 넣으세요.")
            print("   설정 파일: \(SOArmServerStore().debugURL.path)")
            return false
        }
        let key = SOArmTunnelKey()
        guard key.exists else {
            print("❌ 이 앱 전용 SSH 열쇠가 없습니다: \(key.privateKey.path)")
            return false
        }
        print("• 대상 \(server.user)@[\(server.candidateHosts.joined(separator: ", "))]")

        var reachable: [String] = []
        for host in server.candidateHosts {
            var single = server
            single.host = host
            single.alternateHost = ""
            let link = PrinterLink(server: single)
            do {
                let reply = try await link.run("lpstat -p -d 2>&1", timeout: 15)
                let printers = CUPSOutput.printers(reply.output)
                let label = host == server.host ? "집 주소" : "집 밖에서 쓸 주소"
                if printers.isEmpty {
                    print("⚠️  \(label) \(host): 닿았지만 등록된 프린터가 없습니다")
                } else {
                    let summary = printers
                        .map { "\($0.name) \($0.state.title)\($0.isDefault ? " (기본)" : "")" }
                        .joined(separator: ", ")
                    print("✅ \(label) \(host): \(summary)")
                }
                reachable.append(host)
            } catch {
                let label = host == server.host ? "집 주소" : "집 밖에서 쓸 주소"
                print("❌ \(label) \(host): \(error.localizedDescription.split(separator: "\n").first ?? "")")
            }
        }
        guard let working = reachable.first else {
            print("❌ 어느 주소로도 닿지 못했습니다. 집 안이라면 서버가 켜져 있는지, 밖이라면 Tailscale이 양쪽에서 도는지 보세요.")
            return false
        }
        if reachable.count < server.candidateHosts.count {
            print("⚠️  한쪽 길만 열려 있습니다. 지금 위치에서는 문제가 없지만, 다른 곳으로 옮기면 닿지 않을 수 있습니다.")
        }

        var single = server
        single.host = working
        single.alternateHost = ""
        do {
            let reply = try await PrinterLink(server: single).run(PrintCommand.inspect(printer: ""), timeout: 20)
            let capabilities = CUPSOutput.capabilities(
                reply.output.components(separatedBy: "@@OPTIONS@@").dropFirst().first?
                    .components(separatedBy: "@@QUEUE@@").first ?? ""
            )
            print("• 용지 \(capabilities.pageSizes.prefix(6).joined(separator: ", "))")
            print("• 양면 \(capabilities.supportsDuplex ? "가능" : "장치 없음") · 컬러 선택 \(capabilities.supportsColorModel ? "가능" : "없음")")
            let hasGhostscript = reply.output.components(separatedBy: "@@GS@@").last?
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            print("• 흑백 변환 \(hasGhostscript ? "가능 (서버 ghostscript)" : "불가 — 서버에 ghostscript가 없습니다")")
        } catch {
            print("⚠️  프린터 선택지를 읽지 못했습니다: \(error.localizedDescription)")
        }
        return true
    }
}
