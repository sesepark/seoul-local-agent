import Foundation
import Combine

/// 가상 리더 — 물리 리더 팔 없이 팔로워를 조작하는 경로의 Mac 쪽.
///
/// 여기에도 LeRobot도 serial 접근도 없다. `SOArmClient`와 같은 규칙이다: 팔을 여는 코드는
/// 전부 서버(`soarm101-console`)에 있고, 이 파일은 그 서버가 내놓은 WebSocket과 REST를
/// 부르기만 한다. 달라진 것은 **방향**이다 — 상태를 읽어 오기만 하던 자리에, 검증받을
/// 목표 관절값을 올려 보내는 길이 하나 생겼다.
///
/// 안전 판정은 전부 서버가 한다. 이 파일에 들어 있는 관절 한계와 문턱값은 서버가 내려준
/// 사본이고, 화면이 "지금 최대 속도로 따라가는 중"이나 "여기가 한계"라고 말하기 위한
/// 것이다. 이 사본을 근거로 무엇을 허용하지 않는다 — 허용과 거절은 서버만 한다.

// MARK: - 관절 계약

/// 관절 하나의 계약. 서버가 팔로워 calibration에서 계산해 내려준다.
///
/// 한계값을 앱에 적어 두지 않는 이유는, calibration을 다시 잡으면 그 값이 바뀌는데 앱이
/// 그것을 알 방법이 없기 때문이다. 화면이 실제와 다른 한계를 그리는 순간, 사람은 팔이
/// 갈 수 있는 곳과 못 가는 곳을 화면에서 배울 수 없게 된다.
struct SOArmJointSpec: Sendable, Equatable, Identifiable {
    var name: String
    var label: String
    /// `deg` 또는 `percent`. 집게만 퍼센트다 — LeRobot의 `SOFollower`가 집게에만
    /// `RANGE_0_100`을 쓰기 때문이고, 이 앱은 그 단위를 그대로 옮긴다.
    var unit: String
    var minimum: Double
    var maximum: Double
    var urdfJoint: String

    var id: String { name }
    var isPercent: Bool { unit == "percent" }

    /// 값 하나를 사람이 읽을 문자열로.
    func text(_ value: Double) -> String {
        isPercent ? String(format: "%.0f%%", value) : String(format: "%.1f°", value)
    }

    func clamp(_ value: Double) -> Double { min(maximum, max(minimum, value)) }

    init?(_ json: [String: Any]) {
        guard let name = json.soarmString("name"),
              let minimum = json.soarmDouble("min"),
              let maximum = json.soarmDouble("max") else { return nil }
        self.name = name
        self.label = json.soarmString("label") ?? name
        self.unit = json.soarmString("unit") ?? "deg"
        self.minimum = minimum
        self.maximum = maximum
        self.urdfJoint = json.soarmString("urdf_joint") ?? name
    }
}

/// 안전 사다리의 문턱값 사본. 화면이 부하 막대의 만점을 어디에 둘지, 얼마나 조용하면
/// 워치독이 걸리는지를 사람에게 말해 주는 데 쓴다.
struct SOArmSafetyPolicy: Sendable, Equatable {
    var hz = 30
    var stepDegrees = 2.0
    var stepPercent = 3.0
    var commandTimeoutMs = 300
    var leaseTTLMs = 5000
    var heartbeatMs = 1000
    var syncToleranceDegrees = 6.0
    var syncTolerancePercent = 10.0
    var loadTrip = 400.0
    var currentTrip = 108.0
    var followingErrorDegrees = 12.0
    var temperatureWarnC = 55.0
    var temperatureTripC = 65.0
    var retreatDegrees = 4.0

    init() {}

    init(_ json: [String: Any]) {
        hz = json.soarmInt("hz") ?? hz
        stepDegrees = json.soarmDouble("step_deg") ?? stepDegrees
        stepPercent = json.soarmDouble("step_percent") ?? stepPercent
        commandTimeoutMs = json.soarmInt("command_timeout_ms") ?? commandTimeoutMs
        leaseTTLMs = json.soarmInt("lease_ttl_ms") ?? leaseTTLMs
        heartbeatMs = json.soarmInt("heartbeat_ms") ?? heartbeatMs
        syncToleranceDegrees = json.soarmDouble("sync_tolerance_deg") ?? syncToleranceDegrees
        syncTolerancePercent = json.soarmDouble("sync_tolerance_percent") ?? syncTolerancePercent
        loadTrip = json.soarmDouble("load_trip") ?? loadTrip
        currentTrip = json.soarmDouble("current_trip") ?? currentTrip
        followingErrorDegrees = json.soarmDouble("following_error_deg") ?? followingErrorDegrees
        temperatureWarnC = json.soarmDouble("temperature_warn_c") ?? temperatureWarnC
        temperatureTripC = json.soarmDouble("temperature_trip_c") ?? temperatureTripC
        retreatDegrees = json.soarmDouble("retreat_deg") ?? retreatDegrees
    }

    func step(for spec: SOArmJointSpec) -> Double { spec.isPercent ? stepPercent : stepDegrees }
}

// MARK: - 상태

/// SAFETY.md의 상태 모델. 이름은 서버가 보내는 문자열 그대로다.
enum SOArmSafetyState: String, Sendable, Equatable {
    case stopped = "STOPPED"
    case safe = "SAFE"
    case ready = "READY"
    case active = "ACTIVE"
    case retreating = "RETREATING"
    case hold = "HOLD"
    case fault = "FAULT"

    /// 이 상태에서 새 목표를 받아 주는가. 화면이 조작 UI를 열지 말지 정하는 데 쓴다.
    var acceptsMotion: Bool { self == .ready || self == .active }
    /// 사람이 원인을 확인해야 풀리는가.
    var needsAcknowledgement: Bool { self == .hold || self == .fault }

    var korean: String {
        switch self {
        case .stopped: "꺼짐"
        case .safe: "관찰 전용"
        case .ready: "대기"
        case .active: "조작 중"
        case .retreating: "물러나는 중"
        case .hold: "자세 유지"
        case .fault: "고장"
        }
    }
}

/// 왜 멈췄는가. 서버가 사람이 읽을 문장까지 함께 보내므로 앱이 다시 쓰지 않는다.
struct SOArmFault: Sendable, Equatable {
    var code: String
    var joint: String?
    var message: String

    init?(_ json: [String: Any]?) {
        guard let json, let code = json.soarmString("code") else { return nil }
        self.code = code
        self.joint = json.soarmString("joint")
        self.message = json.soarmString("message") ?? code
    }
}

struct SOArmLease: Sendable, Equatable {
    var id: String
    var holder: String
    /// 참이면 다음 명령은 팔의 현재 자세 근처에서 시작해야 한다.
    var needsSync: Bool
    var expiresInMs: Int

    init?(_ json: [String: Any]?) {
        guard let json, let id = json.soarmString("lease_id") else { return nil }
        self.id = id
        self.holder = json.soarmString("holder") ?? "알 수 없음"
        self.needsSync = json.soarmBool("needs_sync")
        self.expiresInMs = json.soarmInt("expires_in_ms") ?? 0
    }
}

/// 관절 하나의 지금 값.
struct SOArmJointReading: Sendable, Equatable, Identifiable {
    var name: String
    var present: Double
    var goal: Double
    var load: Double
    var current: Double
    var temperature: Double
    var rateLimited: Bool

    var id: String { name }

    init?(_ json: [String: Any]) {
        guard let name = json.soarmString("name") else { return nil }
        self.name = name
        self.present = json.soarmDouble("present") ?? 0
        self.goal = json.soarmDouble("goal") ?? 0
        self.load = json.soarmDouble("load") ?? 0
        self.current = json.soarmDouble("current") ?? 0
        self.temperature = json.soarmDouble("temperature") ?? 0
        self.rateLimited = json.soarmBool("rate_limited")
    }
}

/// 서버가 30Hz로 밀어 주는 한 장.
struct SOArmTelemetry: Sendable, Equatable {
    var running = false
    var relay = false
    var state = SOArmSafetyState.stopped
    var torqueEnabled = false
    /// 토크 상태를 **알고 있는가**.
    ///
    /// 제어 루프가 돌지 않으면 알 수 없다. 그때 `false`를 그대로 보여 주면 화면은 힘을
    /// 주고 서 있는 팔을 두고 "토크 없음"이라고 말한다. 서버에서 실제로 그 화면을 봤다 —
    /// 모터 여섯 개가 전부 켜져 있는데도. 모르는 것은 모른다고 해야 한다.
    var torqueKnown = false
    var observation = 0
    var loopMilliseconds = 0.0
    var joints: [SOArmJointReading] = []
    var fault: SOArmFault?
    var lease: SOArmLease?
    var error: String?
    var commandAgeMs: Int?
    var warnings: [String] = []

    /// 관절 이름 → 실제 값.
    var present: [String: Double] {
        Dictionary(uniqueKeysWithValues: joints.map { ($0.name, $0.present) })
    }

    init() {}

    init(_ json: [String: Any]) {
        running = json.soarmBool("running")
        relay = json.soarmBool("relay")
        state = SOArmSafetyState(rawValue: json.soarmString("state") ?? "") ?? .stopped
        torqueEnabled = json.soarmBool("torque_enabled")
        torqueKnown = json.soarmBool("torque_known")
        observation = json.soarmInt("observation") ?? 0
        loopMilliseconds = json.soarmDouble("loop_ms") ?? 0
        joints = (json["joints"] as? [[String: Any]] ?? []).compactMap(SOArmJointReading.init)
        fault = SOArmFault(json["fault"] as? [String: Any])
        lease = SOArmLease(json["lease"] as? [String: Any])
        error = json.soarmString("error")
        commandAgeMs = json.soarmInt("command_age_ms")
        warnings = (json["warnings"] as? [[String: Any]] ?? []).compactMap { $0.soarmString("message") }
    }
}

/// `/api/vleader` 한 번의 답. 텔레메트리에 계약과 정책, 그리고 무엇이 막고 있는지가 붙는다.
struct SOArmVirtualLeaderStatus: Sendable, Equatable {
    var available = false
    var specError: String?
    var preflight: [String] = []
    var spec: [SOArmJointSpec] = []
    var policy = SOArmSafetyPolicy()
    var telemetry = SOArmTelemetry()

    init() {}

    init(_ json: [String: Any]) {
        available = json.soarmBool("available")
        specError = json.soarmString("spec_error")
        preflight = json.soarmStrings("preflight")
        spec = (json["spec"] as? [[String: Any]] ?? []).compactMap(SOArmJointSpec.init)
        policy = SOArmSafetyPolicy(json.soarmDict("policy"))
        telemetry = SOArmTelemetry(json)
    }

    static func parse(_ data: Data) throws -> SOArmVirtualLeaderStatus {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw SOArmError.badResponse("가상 리더 상태가 JSON이 아닙니다")
        }
        return SOArmVirtualLeaderStatus(json)
    }
}

/// 서버가 preflight로 돌려주는 영어 한 줄을, 무엇을 해야 하는지로 옮긴다.
/// `SOArmPreflightText`와 같은 규칙이다 — 아는 것만 옮기고 모르는 문장은 원문을 남긴다.
enum SOArmVirtualLeaderText {
    static func korean(_ line: String) -> String {
        if line.contains("SOARM_MOTION_TOKEN") {
            return "서버에 조작 토큰이 설정되어 있지 않습니다 (config/soarm.env의 SOARM_MOTION_TOKEN 후 서비스 재시작)"
        }
        if line.contains("follower port") || line.contains("Missing follower") {
            return "팔로워 팔의 serial 포트를 찾지 못했습니다"
        }
        return SOArmPreflightText.korean(line)
    }
}

// MARK: - REST

/// 가상 리더의 REST 부분. 스트림과 달리 여기서는 상태를 **바꾼다**.
///
/// 조작에 해당하는 요청에는 토큰이 붙는다. 관찰(상태 읽기, 강제 정지)에는 붙지 않는다 —
/// 멈추는 것은 권한을 빼앗는 것이 아니라서 누구나 할 수 있어야 한다.
struct SOArmVirtualLeaderClient: Sendable {
    var baseURL: URL
    var motionToken: String

    static let armConfirmation = "MOVE SOARM101"
    static let releaseConfirmation = "RELEASE TORQUE SOARM101"

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 10
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }()

    func status() async throws -> SOArmVirtualLeaderStatus {
        try SOArmVirtualLeaderStatus.parse(try await send("api/vleader", method: "GET", token: false, timeout: 8))
    }

    /// 팔로워 serial을 잡고 관찰을 시작한다. 토크는 걸지 않으므로 아무것도 움직이지 않는다.
    func start() async throws {
        _ = try await send("api/vleader/start", method: "POST", token: false, timeout: 60)
    }

    func stop(force: Bool = false) async throws {
        _ = try await send("api/vleader/stop\(force ? "?force=true" : "")", method: "POST", token: force, timeout: 30)
    }

    /// 토크를 건다. 여기서부터 팔이 명령을 따를 수 있다.
    func arm(confirmation: String) async throws {
        _ = try await send("api/vleader/arm", method: "POST", body: ["confirmation": confirmation], token: true, timeout: 30)
    }

    /// 토크를 푼다. **팔이 떨어질 수 있다.**
    func releaseTorque(confirmation: String) async throws {
        _ = try await send("api/vleader/torque/release", method: "POST", body: ["confirmation": confirmation], token: true, timeout: 30)
    }

    /// 조작 권한을 받는다. **여기에도 확인 문구가 붙는다.**
    ///
    /// 토크를 거는 자리에만 두었더니, 이미 켜져 있을 때 그 게이트를 지나쳤다. 먼저 켜 둔
    /// 사람이 있는 팔에 아무나 문구 없이 붙을 수 있었고, 시험이 그것을 잡았다. 팔이
    /// 움직일 수 있게 되는 순간은 토크가 걸리는 순간이 아니라 권한을 받는 순간이다.
    func takeLease(holder: String, session: String, confirmation: String) async throws -> SOArmLease {
        let data = try await send(
            "api/vleader/lease", method: "POST",
            body: ["confirmation": confirmation, "holder": holder, "session_id": session],
            token: true, timeout: 15
        )
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let lease = SOArmLease(json) else {
            throw SOArmError.badResponse("리스 응답을 읽지 못했습니다")
        }
        return lease
    }

    func releaseLease(_ id: String) async throws {
        _ = try await send("api/vleader/lease/\(id)", method: "DELETE", token: true, timeout: 10)
    }

    /// 리스를 살려 둔다.
    ///
    /// 스트림에도 같은 이름의 프레임이 있고, 잘 돌 때는 그쪽이 한다. 이것은 그쪽이 조용히
    /// 죽었을 때를 위한 것이다 — 소켓 전송은 실패해도 아무 말을 하지 않으므로, 권한이
    /// 사라지고 나서야 알게 된다. 실제로 그 일이 있었다: 권한을 받고 5초 뒤, 아무것도
    /// 하지 않았는데 권한만 풀려 있었다.
    func heartbeat(_ id: String) async throws {
        _ = try await send("api/vleader/lease/\(id)/heartbeat", method: "POST", token: true, timeout: 5)
    }

    /// 리스가 없어도, 토큰이 없어도 부를 수 있다. 멈추는 것은 빼앗는 것이 아니다.
    func hold() async throws {
        _ = try await send("api/vleader/hold", method: "POST", token: false, timeout: 15)
    }

    /// 멈춘 이유를 사람이 확인했다.
    func resume() async throws {
        _ = try await send("api/vleader/resume", method: "POST", token: true, timeout: 15)
    }

    // MARK: 전송

    private func send(
        _ path: String, method: String, body: [String: any Sendable]? = nil,
        token: Bool, timeout: TimeInterval
    ) async throws -> Data {
        var request = URLRequest(url: baseURL.appending(path: path))
        request.httpMethod = method
        request.timeoutInterval = timeout
        request.cachePolicy = .reloadIgnoringLocalCacheData
        if token {
            let trimmed = motionToken.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { throw SOArmError.blocked(Self.missingTokenMessage) }
            request.setValue(trimmed, forHTTPHeaderField: "X-SOARM-Motion-Token")
        }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await Self.session.data(for: request)
        } catch {
            throw SOArmError.unreachable(SOArmClient.reason(for: error))
        }
        guard let http = response as? HTTPURLResponse else {
            throw SOArmError.badResponse("HTTP 응답이 아닙니다")
        }
        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 401 { throw SOArmError.blocked(Self.wrongTokenMessage) }
            throw SOArmClient.error(status: http.statusCode, body: data)
        }
        return data
    }

    static let missingTokenMessage = "조작 토큰이 비어 있습니다. 설정 › 로봇의 `조작 토큰`에 서버 config/soarm.env의 SOARM_MOTION_TOKEN 값을 넣으세요."
    static let wrongTokenMessage = "서버가 조작 토큰을 받아들이지 않았습니다. 설정 › 로봇의 값과 서버 config/soarm.env의 SOARM_MOTION_TOKEN이 같은지 확인하세요."

    /// WebSocket 주소. 터널 너머의 같은 포트다.
    var streamURL: URL {
        var components = URLComponents(url: baseURL.appending(path: "api/vleader/stream"), resolvingAgainstBaseURL: false)
        components?.scheme = baseURL.scheme == "https" ? "wss" : "ws"
        return components?.url ?? baseURL
    }
}

// MARK: - 클라이언트 쪽 사본

/// 서버가 할 검사를 화면이 미리 보여 주기 위한 사본.
///
/// **여기서 아무것도 막지 않는다.** 목표를 잘라서 보내지도 않는다 — 잘라 보내면 서버가
/// 무엇을 거절했는지 알 수 없게 되고, 화면은 팔이 도달했다고 말하는데 팔은 다른 곳에 선다.
/// 하는 일은 하나다: 지금 이 값이 서버에서 어떤 대접을 받을지 미리 말해 주는 것.
struct SOArmLimitMirror: Sendable {
    var spec: [SOArmJointSpec]
    var policy: SOArmSafetyPolicy

    enum Verdict: Equatable {
        case fine
        /// 절대 한계 밖. 서버가 `OUTSIDE_ABSOLUTE_LIMIT`로 거절한다.
        case outsideLimit
        /// 한 번에 갈 수 있는 것보다 멀다. 거절되지는 않고 서버가 잘라서 따라간다.
        case rateLimited
        /// 리스를 막 잡았는데 현재 자세에서 너무 멀다. 서버가 `POSE_NOT_SYNCED`로 거절한다.
        case notSynced
    }

    func verdict(for name: String, target: Double, present: Double?, needsSync: Bool) -> Verdict {
        guard let joint = spec.first(where: { $0.name == name }) else { return .fine }
        if target < joint.minimum - 1e-6 || target > joint.maximum + 1e-6 { return .outsideLimit }
        guard let present else { return .fine }
        if needsSync {
            let tolerance = joint.isPercent ? policy.syncTolerancePercent : policy.syncToleranceDegrees
            if abs(target - present) > tolerance { return .notSynced }
        }
        if abs(target - present) > policy.step(for: joint) { return .rateLimited }
        return .fine
    }

    /// 부하 막대가 몇 퍼센트 차 있어야 하는가. 만점은 서버의 정지 문턱이다.
    func loadFraction(_ reading: SOArmJointReading) -> Double {
        guard policy.loadTrip > 0 else { return 0 }
        return min(1, abs(reading.load) / policy.loadTrip)
    }

    func isHot(_ reading: SOArmJointReading) -> Bool {
        reading.temperature >= policy.temperatureWarnC
    }
}
