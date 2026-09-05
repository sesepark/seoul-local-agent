import Foundation
import Combine

/// 학습 서버(DGX Spark)의 작업 큐를 원격으로 부르는 계층.
///
/// 팔이 붙은 콘솔 서버와 달리 이쪽은 **곧장** 간다. 큐가 사는 곳이 GPU를 가진 기계이고,
/// 그 기계만 켜져 있으면 밤새 도는 줄을 볼 수 있어야 하기 때문이다. 콘솔 서버를 한 번 더
/// 거치면 그 서버가 재시작하는 동안 학습 화면이 함께 사라진다.
///
/// 학습을 실제로 띄우고 순서를 정하는 코드는 전부 서버(`~/sparkq/sparkq.py`)에 있다. 이
/// 파일은 그 서버가 내놓은 HTTP API를 부르기만 한다 — GPU의 소유자는 하나여야 하고,
/// Mac이 두 번째 소유자가 되는 순간 큐 밖에서 학습이 시작된다.
///
/// 서버 API에는 인증이 없다. 그래서 큐는 `127.0.0.1`에만 bind되어 있고, SSH 터널이 곧
/// 신뢰 경계다(`SOArmTunnel.spark`).

// MARK: - 설정

/// 학습 서버 주소는 콘솔 서버와 같은 모양이라 `SOArmServer`를 그대로 쓴다.
///
/// 모양이 같은 것을 두 벌 만들면 한쪽만 고쳐지는 날이 온다. `motionToken`은 이 서버에
/// 해당하는 것이 없어 비워 둔다 — 팔이 없는 기계이므로 조작 권한을 가를 것도 없다.
struct SparkServerStore: Sendable {
    private let url: URL

    init(directory: URL? = nil) {
        let root = directory ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appending(path: "Library/Application Support/SeoulLocalAgent", directoryHint: .isDirectory)
        url = root.appending(path: "spark-queue.json")
    }

    func load() -> SOArmServer {
        guard let data = try? Data(contentsOf: url),
              let server = try? JSONDecoder().decode(SOArmServer.self, from: data) else {
            // 처음 켜는 사람에게 빈 칸 네 개를 내미는 것보다, 이 파이프라인이 실제로 쓰는
            // 포트를 채워 두고 주소만 받는 편이 낫다.
            return SOArmServer(sshPort: 22, localPort: 8092, remotePort: 8092)
        }
        return server.sanitised()
    }

    func save(_ server: SOArmServer) {
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        guard let data = try? JSONEncoder().encode(server.sanitised()) else { return }
        try? data.write(to: url, options: .atomic)
    }
}

// MARK: - 서버가 내놓는 것들

/// 큐에 걸 수 있는 작업 한 종류. 서버의 `kinds/*.json` 하나에 해당한다.
///
/// 종류를 앱에 박아 두지 않는 이유는 늘리기 위해서다. 새 실험을 걸 수 있게 하는 데 이 앱을
/// 고칠 필요가 없고, 서버에 JSON 하나를 더 놓으면 화면에 항목이 하나 늘어난다.
struct SparkJobKind: Decodable, Sendable, Equatable, Identifiable {
    var kind = ""
    var title = ""
    var label = ""
    var detail = ""
    var icon = ""
    var fields: [SparkJobField] = []

    var id: String { kind }

    enum CodingKeys: String, CodingKey { case kind, title, label, detail, icon, fields }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        kind = try values.decodeIfPresent(String.self, forKey: .kind) ?? ""
        title = try values.decodeIfPresent(String.self, forKey: .title) ?? ""
        label = try values.decodeIfPresent(String.self, forKey: .label) ?? kind
        detail = try values.decodeIfPresent(String.self, forKey: .detail) ?? ""
        icon = try values.decodeIfPresent(String.self, forKey: .icon) ?? "square.stack.3d.up"
        fields = try values.decodeIfPresent([SparkJobField].self, forKey: .fields) ?? []
    }

    init(kind: String = "", label: String = "", detail: String = "", icon: String = "square.stack.3d.up",
         fields: [SparkJobField] = []) {
        self.kind = kind
        self.label = label
        self.detail = detail
        self.icon = icon
        self.fields = fields
    }

    /// 서버가 정한 기본값으로 채운 요청 한 벌.
    var defaultParameters: [String: SparkParameter] {
        var out: [String: SparkParameter] = [:]
        for field in fields {
            if let value = field.defaultValue { out[field.name] = value }
        }
        return out
    }
}

/// 작업 하나를 걸 때 사람이 정하는 값 한 칸.
struct SparkJobField: Decodable, Sendable, Equatable, Identifiable {
    enum Form: String, Codable, Sendable { case name, `enum`, int }

    var name = ""
    var label = ""
    var type: Form = .name
    /// `enum`일 때 고를 수 있는 값들.
    var values: [String] = []
    /// 값 하나를 사람이 읽는 문장으로 옮긴 것. 없으면 값을 그대로 쓴다.
    var labels: [String: String] = [:]
    var help = ""
    /// `name`이면서 이 값이 `datasets`이면, 고를 목록을 서버의 데이터셋에서 가져온다.
    var source = ""
    var minimum = 1
    var maximum = 10_000_000
    var defaultValue: SparkParameter?

    var id: String { name }

    enum CodingKeys: String, CodingKey {
        case name, label, type, values, labels, help, source
        case minimum = "min", maximum = "max", defaultValue = "default"
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        name = try values.decodeIfPresent(String.self, forKey: .name) ?? ""
        label = try values.decodeIfPresent(String.self, forKey: .label) ?? name
        type = (try? values.decodeIfPresent(Form.self, forKey: .type)) ?? .name
        self.values = try values.decodeIfPresent([String].self, forKey: .values) ?? []
        labels = try values.decodeIfPresent([String: String].self, forKey: .labels) ?? [:]
        help = try values.decodeIfPresent(String.self, forKey: .help) ?? ""
        source = try values.decodeIfPresent(String.self, forKey: .source) ?? ""
        minimum = try values.decodeIfPresent(Int.self, forKey: .minimum) ?? 1
        maximum = try values.decodeIfPresent(Int.self, forKey: .maximum) ?? 10_000_000
        defaultValue = try values.decodeIfPresent(SparkParameter.self, forKey: .defaultValue)
    }

    init(name: String, label: String = "", type: Form = .name, values: [String] = [],
         labels: [String: String] = [:], help: String = "", source: String = "",
         minimum: Int = 1, maximum: Int = 10_000_000, defaultValue: SparkParameter? = nil) {
        self.name = name
        self.label = label.isEmpty ? name : label
        self.type = type
        self.values = values
        self.labels = labels
        self.help = help
        self.source = source
        self.minimum = minimum
        self.maximum = maximum
        self.defaultValue = defaultValue
    }

    func caption(for value: String) -> String { labels[value] ?? value }
}

/// 문자열이거나 정수인 값. 서버의 JSON이 두 가지를 섞어 쓰므로 그대로 받는다.
enum SparkParameter: Codable, Sendable, Equatable, Hashable {
    case text(String)
    case number(Int)

    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if let number = try? value.decode(Int.self) { self = .number(number); return }
        if let text = try? value.decode(String.self) { self = .text(text); return }
        if let flag = try? value.decode(Bool.self) { self = .text(flag ? "true" : "false"); return }
        if let real = try? value.decode(Double.self) { self = .number(Int(real)); return }
        self = .text("")
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .text(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        }
    }

    var text: String {
        switch self {
        case .text(let value): value
        case .number(let value): String(value)
        }
    }

    var number: Int? {
        switch self {
        case .text(let value): Int(value)
        case .number(let value): value
        }
    }
}

/// 진행 상황. 종류가 달라도 화면은 이 한 가지 모양만 읽는다.
struct SparkProgress: Decodable, Sendable, Equatable {
    var step: Int?
    var steps: Int?
    var loss: Double?
    var reward: Double?
    var etaSeconds: Int?
    var updatedAt: Double?
    var logTail: [String] = []

    enum CodingKeys: String, CodingKey {
        case step, steps, loss, reward
        case etaSeconds = "eta_seconds"
        case updatedAt = "updated_at"
        case logTail = "log_tail"
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        step = try values.decodeIfPresent(Int.self, forKey: .step)
        steps = try values.decodeIfPresent(Int.self, forKey: .steps)
        loss = try values.decodeIfPresent(Double.self, forKey: .loss)
        reward = try values.decodeIfPresent(Double.self, forKey: .reward)
        etaSeconds = try values.decodeIfPresent(Int.self, forKey: .etaSeconds)
        updatedAt = try values.decodeIfPresent(Double.self, forKey: .updatedAt)
        logTail = try values.decodeIfPresent([String].self, forKey: .logTail) ?? []
    }

    init() {}

    /// 0…1. 총량을 모르면 `nil`이고, 그때 화면은 막대 대신 도는 표시를 쓴다.
    var fraction: Double? {
        guard let step, let steps, steps > 0 else { return nil }
        return min(1, max(0, Double(step) / Double(steps)))
    }
}

/// 큐에 있는(또는 있었던) 작업 하나.
struct SparkJob: Decodable, Sendable, Equatable, Identifiable {
    enum State: String, Codable, Sendable {
        case queued, running, done, failed, cancelled, interrupted

        var badge: String {
            switch self {
            case .queued: "대기"
            case .running: "실행 중"
            case .done: "완료"
            case .failed: "실패"
            case .cancelled: "중지됨"
            case .interrupted: "끊김"
            }
        }

        var symbol: String {
            switch self {
            case .queued: "clock"
            case .running: "play.circle.fill"
            case .done: "checkmark.circle.fill"
            case .failed: "xmark.circle.fill"
            case .cancelled: "minus.circle.fill"
            case .interrupted: "exclamationmark.triangle.fill"
            }
        }
    }

    var id = ""
    var kind = ""
    var title = ""
    var state: State = .queued
    var command = ""
    var session = ""
    var parameters: [String: SparkParameter] = [:]
    var createdAt: Double?
    var startedAt: Double?
    var finishedAt: Double?
    var exitCode: Int?
    var error: String?
    /// 도는 작업에만 붙는다. 세션이 실제로 살아 있는가.
    var live: Bool?
    var progress: SparkProgress?

    enum CodingKeys: String, CodingKey {
        case id, kind, title, state, command, session, error, live
        case parameters = "params"
        case createdAt = "created_at"
        case startedAt = "started_at"
        case finishedAt = "finished_at"
        case exitCode = "exit_code"
        case progress = "progress_detail"
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decodeIfPresent(String.self, forKey: .id) ?? ""
        kind = try values.decodeIfPresent(String.self, forKey: .kind) ?? ""
        title = try values.decodeIfPresent(String.self, forKey: .title) ?? id
        state = (try? values.decodeIfPresent(State.self, forKey: .state)) ?? .queued
        command = try values.decodeIfPresent(String.self, forKey: .command) ?? ""
        session = try values.decodeIfPresent(String.self, forKey: .session) ?? ""
        parameters = try values.decodeIfPresent([String: SparkParameter].self, forKey: .parameters) ?? [:]
        createdAt = try values.decodeIfPresent(Double.self, forKey: .createdAt)
        startedAt = try values.decodeIfPresent(Double.self, forKey: .startedAt)
        finishedAt = try values.decodeIfPresent(Double.self, forKey: .finishedAt)
        exitCode = try values.decodeIfPresent(Int.self, forKey: .exitCode)
        error = try values.decodeIfPresent(String.self, forKey: .error)
        live = try values.decodeIfPresent(Bool.self, forKey: .live)
        progress = try values.decodeIfPresent(SparkProgress.self, forKey: .progress)
    }

    init(id: String = "", kind: String = "", title: String = "", state: State = .queued) {
        self.id = id
        self.kind = kind
        self.title = title
        self.state = state
    }

    /// 사람이 고른 값들을 한 줄로. `데이터셋 soarm101_… · 정책 act`
    func summary(using kinds: [SparkJobKind]) -> String {
        guard let spec = kinds.first(where: { $0.kind == kind }) else {
            return parameters.keys.sorted().map { "\($0) \(parameters[$0]?.text ?? "")" }.joined(separator: " · ")
        }
        return spec.fields.compactMap { field in
            guard let value = parameters[field.name] else { return nil }
            return "\(field.label) \(field.caption(for: value.text))"
        }.joined(separator: " · ")
    }
}

/// 큐 화면 한 장에 필요한 전부. 왕복을 늘리지 않으려고 서버가 한 번에 답한다.
struct SparkSnapshot: Decodable, Sendable, Equatable {
    var running: SparkJob?
    var queued: [SparkJob] = []
    var recent: [SparkJob] = []
    var paused = false
    /// 큐 밖에서 GPU를 쓰고 있는 프로세스들. 이것이 비어야 다음 작업이 시작된다.
    var foreignApps: [SparkComputeApp] = []

    enum CodingKeys: String, CodingKey {
        case running, queued, recent, paused
        case foreignApps = "gpu_apps"
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        running = try values.decodeIfPresent(SparkJob.self, forKey: .running)
        queued = try values.decodeIfPresent([SparkJob].self, forKey: .queued) ?? []
        recent = try values.decodeIfPresent([SparkJob].self, forKey: .recent) ?? []
        paused = try values.decodeIfPresent(Bool.self, forKey: .paused) ?? false
        foreignApps = try values.decodeIfPresent([SparkComputeApp].self, forKey: .foreignApps) ?? []
    }

    init() {}
}

struct SparkComputeApp: Decodable, Sendable, Equatable, Identifiable {
    var pid = ""
    var name = ""
    var memoryMiB = ""

    var id: String { pid }

    enum CodingKeys: String, CodingKey { case pid, name, memoryMiB = "memory_mib" }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        pid = try values.decodeIfPresent(String.self, forKey: .pid) ?? ""
        name = try values.decodeIfPresent(String.self, forKey: .name) ?? ""
        memoryMiB = try values.decodeIfPresent(String.self, forKey: .memoryMiB) ?? ""
    }

    /// 경로가 길어 화면을 밀어낸다. 마지막 두 조각이면 무엇인지 알아볼 수 있다.
    var shortName: String {
        let pieces = name.split(separator: "/")
        return pieces.suffix(2).joined(separator: "/")
    }
}

/// 기계 상태 한 줌.
struct SparkMachine: Decodable, Sendable, Equatable {
    var host = ""
    var gpuName = ""
    var temperatureC: Int?
    var powerW: Double?
    var memoryUsedMiB: Int?
    var memoryTotalMiB: Int?
    var gpuUtilizationPercent: Int?
    var cpuPercent: Double?
    /// 통합메모리. CPU와 GPU가 나눠 쓰므로 이 값이 곧 기계가 얼마나 찼는지다.
    var ramUsedBytes: Int64?
    var ramTotalBytes: Int64?
    var diskFreeBytes: Int64 = 0
    var diskTotalBytes: Int64 = 0
    var queued = 0
    var running = false
    var paused = false
    /// 닿지 못했을 때의 이유. 비어 있으면 닿은 것이다.
    var unreachable = ""

    enum CodingKeys: String, CodingKey {
        case host, gpu, memory, queued, running, paused
        case cpuPercent = "cpu_percent"
        case diskFreeBytes = "disk_free_bytes"
        case diskTotalBytes = "disk_total_bytes"
    }

    enum GPUKeys: String, CodingKey {
        case name
        case memoryUsedMiB = "memory_used_mib"
        case memoryTotalMiB = "memory_total_mib"
        case temperatureC = "temperature_c"
        case powerW = "power_w"
        case utilizationPercent = "utilization_percent"
    }

    enum MemoryKeys: String, CodingKey {
        case usedBytes = "used_bytes"
        case totalBytes = "total_bytes"
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        host = try values.decodeIfPresent(String.self, forKey: .host) ?? ""
        diskFreeBytes = try values.decodeIfPresent(Int64.self, forKey: .diskFreeBytes) ?? 0
        diskTotalBytes = try values.decodeIfPresent(Int64.self, forKey: .diskTotalBytes) ?? 0
        queued = try values.decodeIfPresent(Int.self, forKey: .queued) ?? 0
        running = try values.decodeIfPresent(Bool.self, forKey: .running) ?? false
        paused = try values.decodeIfPresent(Bool.self, forKey: .paused) ?? false
        if let gpu = try? values.nestedContainer(keyedBy: GPUKeys.self, forKey: .gpu) {
            gpuName = try gpu.decodeIfPresent(String.self, forKey: .name) ?? ""
            // GB10은 통합메모리라 nvidia-smi가 GPU 전용 메모리를 `[N/A]`로 답한다. 값이
            // 없는 것과 읽기에 실패한 것은 다르므로 없는 값은 그냥 비워 둔다.
            memoryUsedMiB = try gpu.decodeIfPresent(Int.self, forKey: .memoryUsedMiB)
            memoryTotalMiB = try gpu.decodeIfPresent(Int.self, forKey: .memoryTotalMiB)
            temperatureC = try gpu.decodeIfPresent(Int.self, forKey: .temperatureC)
            powerW = try gpu.decodeIfPresent(Double.self, forKey: .powerW)
            gpuUtilizationPercent = try gpu.decodeIfPresent(Int.self, forKey: .utilizationPercent)
        }
        cpuPercent = try values.decodeIfPresent(Double.self, forKey: .cpuPercent)
        if let mem = try? values.nestedContainer(keyedBy: MemoryKeys.self, forKey: .memory) {
            ramUsedBytes = try mem.decodeIfPresent(Int64.self, forKey: .usedBytes)
            ramTotalBytes = try mem.decodeIfPresent(Int64.self, forKey: .totalBytes)
        }
    }

    /// 통합메모리 사용률 0…1. 값이 없으면 nil.
    var ramFraction: Double? {
        guard let used = ramUsedBytes, let total = ramTotalBytes, total > 0 else { return nil }
        return min(1, max(0, Double(used) / Double(total)))
    }

    init() {}

    var isReachable: Bool { unreachable.isEmpty && !host.isEmpty }
}

/// 학습 서버에 이미 와 있는 데이터셋. 학습을 걸 때 고를 수 있는 것이 이것뿐이다.
struct SparkDataset: Decodable, Sendable, Equatable, Identifiable {
    var name = ""
    var episodes = 0
    var frames = 0
    var fps = 0

    var id: String { name }

    enum CodingKeys: String, CodingKey { case name, episodes, frames, fps }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        name = try values.decodeIfPresent(String.self, forKey: .name) ?? ""
        episodes = try values.decodeIfPresent(Int.self, forKey: .episodes) ?? 0
        frames = try values.decodeIfPresent(Int.self, forKey: .frames) ?? 0
        fps = try values.decodeIfPresent(Int.self, forKey: .fps) ?? 0
    }

    init(name: String, episodes: Int = 0, frames: Int = 0, fps: Int = 0) {
        self.name = name
        self.episodes = episodes
        self.frames = frames
        self.fps = fps
    }
}

// MARK: - 클라이언트

struct SparkQueueClient: Sendable {
    var server: SOArmServer

    private var session: URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }

    func status() async throws -> SparkMachine {
        try decode(SparkMachine.self, from: await send("/api/status", method: "GET", timeout: 30))
    }

    func snapshot() async throws -> SparkSnapshot {
        try decode(SparkSnapshot.self, from: await send("/api/queue", method: "GET", timeout: 30))
    }

    func kinds() async throws -> [SparkJobKind] {
        struct Wrapper: Decodable { var kinds: [SparkJobKind] }
        return try decode(Wrapper.self, from: await send("/api/kinds", method: "GET", timeout: 30)).kinds
    }

    func datasets() async throws -> [SparkDataset] {
        struct Wrapper: Decodable { var datasets: [SparkDataset] }
        return try decode(Wrapper.self, from: await send("/api/datasets", method: "GET", timeout: 30)).datasets
    }

    @discardableResult
    func enqueue(kind: String, parameters: [String: SparkParameter]) async throws -> SparkJob {
        let body: [String: any Sendable] = [
            "kind": kind,
            "params": parameters.mapValues { value -> any Sendable in
                if let number = value.number, case .number = value { return number }
                return value.text
            },
        ]
        return try decode(SparkJob.self, from: await send("/api/queue", method: "POST", body: body, timeout: 60))
    }

    /// 대기 중이면 줄에서 빼고, 도는 중이면 세운다. 서버가 어느 쪽인지 알고 있다.
    func cancel(_ id: String) async throws {
        _ = try await send("/api/queue/\(id)", method: "DELETE", timeout: 60)
    }

    func moveToTop(_ id: String) async throws {
        _ = try await send("/api/queue/\(id)/top", method: "POST", timeout: 30)
    }

    func setPaused(_ paused: Bool) async throws {
        _ = try await send("/api/queue/pause", method: "POST", body: ["paused": paused], timeout: 30)
    }

    func log(_ id: String) async throws -> [String] {
        struct Wrapper: Decodable { var lines: [String] }
        return try decode(Wrapper.self, from: await send("/api/queue/\(id)/log", method: "GET", timeout: 60)).lines
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw SOArmError.badResponse("학습 서버의 응답을 읽지 못했습니다: \(error.localizedDescription)")
        }
    }

    private func send(
        _ path: String, method: String, body: [String: any Sendable]? = nil, timeout: TimeInterval
    ) async throws -> Data {
        try await SOArmTunnel.spark.ensureConnected(server: server)
        var request = URLRequest(url: server.baseURL.appending(path: path.trimmingPrefix("/")))
        request.httpMethod = method
        request.timeoutInterval = timeout
        request.cachePolicy = .reloadIgnoringLocalCacheData
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw SOArmError.unreachable(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw SOArmError.badResponse("학습 서버가 HTTP로 답하지 않았습니다")
        }
        guard (200..<300).contains(http.statusCode) else {
            // 서버는 왜 거절했는지를 `detail` 한 줄로 말한다. 그 줄을 지우고 상태 코드만
            // 보여 주면 사람이 무엇을 고쳐야 하는지 알 수 없다.
            let detail = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["detail"] as? String
            throw SOArmError.badResponse(detail ?? "학습 서버가 \(http.statusCode)로 거절했습니다")
        }
        return data
    }
}
