import Foundation
import Combine

/// 집 서버에 붙어 있는 SO-ARM101 콘솔을 원격으로 부르는 계층.
///
/// 팔과 카메라를 여는 코드는 전부 서버(`soarm101-console`)에 있고, 이 파일은 그 서버가
/// 이미 내놓은 HTTP API를 부르기만 한다. LeRobot도, serial 포트도, calibration 파일도
/// 이 앱에는 들어오지 않는다 — 장치 소유자가 하나여야 한다는 것이 서버 쪽 설계의 전제이고,
/// Mac이 두 번째 소유자가 되는 순간 그 전제가 깨진다.
///
/// 서버 API에는 인증이 없다. 그래서 신뢰 경계는 SSH 터널이고(`SOArmTunnel`), 이 클라이언트는
/// 언제나 `127.0.0.1`의 전달 포트만 부른다.

// MARK: - 서버 설정

/// 어느 서버의 콘솔에 붙을 것인가.
///
/// 집 서버의 주소와 계정은 개인 정보라 소스에 박지 않는다. `GmailAccountStore`와 같은
/// 규칙으로 이 기기 안의 파일에만 둔다.
struct SOArmServer: Codable, Equatable, Sendable {
    var host = ""
    var user = ""
    var sshPort = 22
    /// 이 Mac에서 열 포트. 이미 다른 터널이 8088을 쓰고 있으면 여기서 바꾼다.
    var localPort = 8088
    /// 서버에서 콘솔이 듣고 있는 포트. `config/soarm.env`의 `SOARM_WEB_PORT`와 같아야 한다.
    var remotePort = 8088

    var isConfigured: Bool {
        !host.trimmingCharacters(in: .whitespaces).isEmpty
            && !user.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// 항상 loopback. 서버를 `0.0.0.0`으로 열어 LAN에 노출하는 경로는 만들지 않는다.
    var baseURL: URL {
        URL(string: "http://127.0.0.1:\(Self.validPort(localPort))") ?? URL(string: "http://127.0.0.1:8088")!
    }

    var sshTarget: String {
        "\(user.trimmingCharacters(in: .whitespaces))@\(host.trimmingCharacters(in: .whitespaces))"
    }

    static func validPort(_ value: Int) -> Int { min(max(value, 1), 65535) }

    /// 저장된 파일이 손으로 고쳐졌을 수도 있으므로 읽을 때 한 번 걸러 낸다.
    func sanitised() -> SOArmServer {
        SOArmServer(
            host: host.trimmingCharacters(in: .whitespaces),
            user: user.trimmingCharacters(in: .whitespaces),
            sshPort: Self.validPort(sshPort),
            localPort: Self.validPort(localPort),
            remotePort: Self.validPort(remotePort)
        )
    }
}

struct SOArmServerStore: Sendable {
    private let url: URL

    init(directory: URL? = nil) {
        let root = directory ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appending(path: "Library/Application Support/SeoulLocalAgent", directoryHint: .isDirectory)
        url = root.appending(path: "soarm-console.json")
    }

    var debugURL: URL { url }

    func load() -> SOArmServer {
        guard let data = try? Data(contentsOf: url),
              let value = try? JSONDecoder().decode(SOArmServer.self, from: data) else { return SOArmServer() }
        return value.sanitised()
    }

    func save(_ server: SOArmServer) throws {
        try LocalFileStorage.write(try JSONEncoder().encode(server.sanitised()), to: url)
    }
}

// MARK: - 오류

/// HTTP 코드마다 뜻이 다르고, 특히 409는 네트워크 오류가 아니라 **상태** 문제다.
/// 잠깐 기다렸다 다시 부른다고 풀리지 않으므로 재시도 경로에 넣지 않는다.
enum SOArmError: LocalizedError, Equatable {
    case notConfigured
    case tunnelFailed(String)
    case unreachable(String)
    /// 400 — 확인 문구가 틀렸다.
    case confirmationMismatch(String)
    /// 409 — 게이트를 통과하지 못했거나 다른 모드가 하드웨어를 쥐고 있다.
    case blocked(String)
    /// 500 — 서버가 중지에 실패했다. 이 경우는 물리 전원 차단을 안내해야 한다.
    case serverFailure(String)
    case badResponse(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            "SO-ARM 서버 주소가 설정되어 있지 않습니다. 설정 › 로봇에서 주소와 계정을 넣어 주세요."
        case .tunnelFailed(let detail):
            "SSH 터널을 열지 못했습니다: \(detail)"
        case .unreachable(let detail):
            "서버 콘솔에 닿지 못했습니다: \(detail)"
        case .confirmationMismatch(let detail):
            detail.isEmpty ? "확인 문구가 맞지 않습니다." : detail
        case .blocked(let detail):
            detail
        case .serverFailure(let detail):
            "서버가 요청을 끝내지 못했습니다: \(detail). 팔이 계속 움직이면 물리 전원을 차단하세요."
        case .badResponse(let detail):
            "서버 응답을 읽지 못했습니다: \(detail)"
        }
    }

    /// 다시 눌러 볼 만한 실패인가. 409와 400은 아니다.
    var isRetryable: Bool {
        switch self {
        case .unreachable, .tunnelFailed: true
        case .notConfigured, .confirmationMismatch, .blocked, .serverFailure, .badResponse: false
        }
    }
}

// MARK: - 상태 모델

/// `/api/status` 응답.
///
/// `Codable`이 아니라 손으로 읽는다. 서버가 필드를 하나 더 붙이거나(`doctor`는 아예 `null`로
/// 오기도 한다) 이름을 바꿔도 화면 전체가 디코딩 실패로 비지 않게 하려는 것이다. 이 앱이
/// 서버보다 나중에 갱신될 수 있으므로, 모르는 키는 조용히 지나가는 편이 옳다.
struct SOArmStatus: Sendable, Equatable {
    var motionEnabled = false
    var cameraRolesConfirmed = false
    var maxRelativeTarget: Double?
    var leaderDeviceExists = false
    var followerDeviceExists = false
    var leaderCalibrated = false
    var followerCalibrated = false
    var lerobotVersion: String?
    var sceneCamera = SOArmCamera()
    var wristCamera = SOArmCamera()
    var teleopPreflight: [String] = []
    var recordPreflight: [String] = []
    var teleop = SOArmProcess()
    var recording = SOArmProcess()
    var recordingRuntime: SOArmRecordingRuntime?
    var doctor: SOArmDoctor?
    /// 데이터 수집이 고정으로 쓰는 카메라 설정. 서버가 정하고 앱은 그대로 옮겨 적는다.
    var recordingProfile = SOArmCameraProfile.recordingDefault

    var teleopReady: Bool { motionEnabled && teleopPreflight.isEmpty }
    var recordReady: Bool { motionEnabled && recordPreflight.isEmpty }
    var mode: SOArmMode {
        if recording.running { .recording } else if teleop.running { .teleoperation } else { .idle }
    }

    /// 지금 화면에 띄울 로그. 도는 모드의 것을 보여 주고, 아무것도 안 돌면 마지막 텔레옵 로그를 남긴다.
    var visibleLogs: [String] {
        if recording.running { return recording.logs }
        if teleop.running { return teleop.logs }
        return recording.logs.isEmpty ? teleop.logs : recording.logs
    }

    static func parse(_ data: Data) throws -> SOArmStatus {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw SOArmError.badResponse("JSON이 아닙니다")
        }
        var status = SOArmStatus()
        status.motionEnabled = root.soarmBool("motion_enabled")
        status.cameraRolesConfirmed = root.soarmBool("camera_roles_confirmed")
        status.maxRelativeTarget = root.soarmDouble("max_relative_target")

        let devices = root.soarmDict("devices")
        status.leaderDeviceExists = devices.soarmDict("leader").soarmBool("exists")
        status.followerDeviceExists = devices.soarmDict("follower").soarmBool("exists")

        let calibrations = root.soarmDict("calibrations")
        status.leaderCalibrated = calibrations.soarmDict("leader").soarmBool("exists")
        status.followerCalibrated = calibrations.soarmDict("follower").soarmBool("exists")

        status.lerobotVersion = root.soarmDict("software").soarmString("lerobot")

        let cameras = root.soarmDict("cameras")
        status.sceneCamera = SOArmCamera(cameras.soarmDict("scene"))
        status.wristCamera = SOArmCamera(cameras.soarmDict("wrist"))

        // `preflight`도 같은 값으로 들어 있지만 읽지 않는다. 하나의 이름만 본다.
        status.teleopPreflight = root.soarmStrings("teleop_preflight")
        status.recordPreflight = root.soarmStrings("record_preflight")

        status.teleop = SOArmProcess(root.soarmDict("teleoperation"))
        let recording = root.soarmDict("recording")
        status.recording = SOArmProcess(recording)
        if let runtime = recording["runtime"] as? [String: Any] {
            status.recordingRuntime = SOArmRecordingRuntime(runtime)
        }
        if let doctor = root["doctor"] as? [String: Any] {
            status.doctor = SOArmDoctor(doctor)
        }
        if let profile = SOArmCameraProfile(root.soarmDict("recording_profile")) {
            status.recordingProfile = profile
        }
        return status
    }
}

enum SOArmMode: String, Sendable, Equatable {
    case idle, teleoperation, recording

    var badge: String {
        switch self {
        case .idle: "대기"
        case .teleoperation: "텔레옵"
        case .recording: "수집 중"
        }
    }
}

struct SOArmCamera: Sendable, Equatable {
    var active = false
    var clients = 0
    var error: String?
    /// 서버에 걸어 둔 설정.
    var requested = SOArmCameraProfile.recordingDefault
    /// 실제로 나오고 있는 것. 크기는 드라이버가 열어 준 값, 프레임은 서버가 센 전달량이다.
    /// 프리뷰가 꺼져 있으면 없다.
    var actual: SOArmCameraProfile?
    /// 이 카메라가 정말로 낼 수 있는 모드. 서버가 장치에 직접 물어서 준다.
    var modes: [SOArmCameraMode] = []

    init() {}

    init(_ json: [String: Any]) {
        active = json.soarmBool("active")
        clients = json.soarmInt("clients") ?? 0
        error = json.soarmString("error")
        if let profile = SOArmCameraProfile(json.soarmDict("requested")) { requested = profile }
        if let value = json["actual"] as? [String: Any] { actual = SOArmCameraProfile(value) }
        modes = (json["modes"] as? [[String: Any]] ?? []).compactMap(SOArmCameraMode.init)
    }

    /// 고를 수 있는 해상도. 큰 것부터, 같은 크기는 한 번만.
    var resolutions: [SOArmCameraResolution] {
        var seen: Set<SOArmCameraResolution> = []
        return modes.map(\.resolution).filter { seen.insert($0).inserted }
    }

    /// 이 해상도에서 장치가 내주는 최대 프레임.
    func deviceFrameRate(for resolution: SOArmCameraResolution) -> Int {
        modes.first { $0.resolution == resolution }?.frameRates.max() ?? requested.fps
    }
}

/// 카메라 한 대의 해상도·프레임 한 벌.
struct SOArmCameraProfile: Sendable, Equatable, Hashable {
    var width: Int
    var height: Int
    var fps: Int

    /// 수집이 쓰는 값이자 앱의 기본값. 서버가 다른 값을 말해 주면 그쪽을 따른다.
    static let recordingDefault = SOArmCameraProfile(width: 640, height: 480, fps: 30)

    init(width: Int, height: Int, fps: Int) {
        self.width = width
        self.height = height
        self.fps = fps
    }

    init?(_ json: [String: Any]) {
        guard let width = json.soarmInt("width"), let height = json.soarmInt("height") else { return nil }
        self.init(width: width, height: height, fps: json.soarmInt("fps") ?? 0)
    }

    var resolution: SOArmCameraResolution { SOArmCameraResolution(width: width, height: height) }
    var resolutionText: String { resolution.text }
    /// 서버가 아직 프레임을 세지 못했으면 0으로 온다. 그때는 숫자 대신 아무 말도 하지 않는다.
    var frameRateText: String? { fps > 0 ? "\(fps)fps" : nil }
    var text: String { [resolutionText, frameRateText].compactMap { $0 }.joined(separator: " · ") }
}

struct SOArmCameraResolution: Sendable, Equatable, Hashable {
    var width: Int
    var height: Int

    var text: String { "\(width)×\(height)" }
    var pixels: Int { width * height }
    /// 카드가 이 비율로 서야 영상 양옆에 빈 띠가 생기지 않는다.
    var aspectRatio: CGFloat { height > 0 ? CGFloat(width) / CGFloat(height) : 4.0 / 3.0 }
}

/// 서버가 장치에서 읽어 온 모드 하나.
struct SOArmCameraMode: Sendable, Equatable {
    var resolution: SOArmCameraResolution
    var frameRates: [Int]

    init?(_ json: [String: Any]) {
        guard let width = json.soarmInt("width"), let height = json.soarmInt("height") else { return nil }
        resolution = SOArmCameraResolution(width: width, height: height)
        frameRates = (json["fps"] as? [Any] ?? []).compactMap { ($0 as? NSNumber)?.intValue }
    }
}

struct SOArmProcess: Sendable, Equatable {
    var running = false
    var pid: Int?
    var logs: [String] = []

    init() {}

    init(_ json: [String: Any]) {
        running = json.soarmBool("running")
        pid = json.soarmInt("pid")
        logs = json.soarmStrings("logs")
    }
}

struct SOArmRecordingRuntime: Sendable, Equatable {
    var phase: String?
    var datasetName: String?
    var task: String?
    var lastControl: String?

    init(_ json: [String: Any]) {
        phase = json.soarmString("phase")
        datasetName = json.soarmString("dataset_name")
        task = json.soarmString("task")
        lastControl = json.soarmString("last_control")
    }

    var phaseTitle: String {
        switch phase {
        case "starting": "시작하는 중"
        case "recording": "수집 중"
        case "complete": "완료"
        case "error": "오류로 끝남"
        default: phase ?? "—"
        }
    }
}

struct SOArmDoctor: Sendable, Equatable {
    var checkedAt: String?
    var healthy = false
    var safeForMotionStart = false
    var arms: [SOArmArmDiagnostic] = []

    init(_ json: [String: Any]) {
        checkedAt = json.soarmString("checked_at")
        healthy = json.soarmBool("healthy")
        safeForMotionStart = json.soarmBool("safe_for_motion_start")
        let raw = json.soarmDict("arms")
        // 순서를 고정한다. 사전 순회 순서에 화면 줄 순서를 맡기면 폴링마다 뒤바뀐다.
        arms = ["leader", "follower"].compactMap { role in
            guard let value = raw[role] as? [String: Any] else { return nil }
            return SOArmArmDiagnostic(role: role, value)
        }
    }

    /// 한 줄 요약. 진단 결과를 통째로 JSON으로 뿌리던 웹 콘솔과 달리, 앱에서는 읽을 수 있는
    /// 문장이어야 한다.
    var summary: String {
        let arms = arms.map(\.summary).joined(separator: " · ")
        let verdict = safeForMotionStart ? "동작 시작 가능" : (healthy ? "토크가 걸려 있어 시작 불가" : "정상이 아님")
        return arms.isEmpty ? verdict : "\(verdict) · \(arms)"
    }
}

struct SOArmArmDiagnostic: Sendable, Equatable {
    var role: String
    var healthy = false
    var safeForMotionStart = false
    var error: String?
    /// 서버는 0.1V 단위 raw 값을 준다.
    var volts: Double?
    /// 응답한 모터 수와 기대한 수. `models`의 값이 `null`인 ID는 대답하지 않은 것이다.
    var respondingMotors = 0
    var expectedMotors = 0
    /// 여섯 모터가 모두 토크 해제 상태인가. 하나라도 걸려 있으면 서버가 동작 시작을 막는다.
    var torqueDisabled = false
    /// 사람이 읽을 전압 범위. 한 모터만 보면 다른 모터의 이상을 놓친다.
    var voltageRange: (low: Double, high: Double)?

    init(role: String, _ json: [String: Any]) {
        self.role = role
        healthy = json.soarmBool("healthy")
        safeForMotionStart = json.soarmBool("safe_for_motion_start")
        error = json.soarmString("error")
        let models = json.soarmDict("models")
        expectedMotors = models.count
        respondingMotors = models.values.filter { !($0 is NSNull) }.count
        let torque = json.soarmDict("torque_enabled").values.compactMap { ($0 as? NSNumber)?.intValue }
        torqueDisabled = !torque.isEmpty && torque.allSatisfy { $0 == 0 }
        // 가장 낮은 모터를 쓴다. 사전의 `values`에서 아무거나 하나 집으면 순서가 정해져 있지
        // 않아 폴링마다 다른 모터의 값이 표시되고, 숫자가 이유 없이 오르내리는 것처럼 보인다.
        // 여섯 개 중 가장 낮은 값이 팔의 상태를 가장 먼저 말해 주기도 한다.
        let voltages = json.soarmDict("voltage_raw").values.compactMap { ($0 as? NSNumber)?.doubleValue }
        if let lowest = voltages.min(), let highest = voltages.max() {
            volts = lowest / 10
            voltageRange = (lowest / 10, highest / 10)
        }
    }

    /// `(low: 11.8, high: 12.2)` → `11.8~12.2V`, 같으면 `12.1V`.
    var voltageText: String {
        guard let voltageRange else { return "전압 미확인" }
        if abs(voltageRange.high - voltageRange.low) < 0.05 {
            return String(format: "%.1fV", voltageRange.low)
        }
        return String(format: "%.1f~%.1fV", voltageRange.low, voltageRange.high)
    }

    var title: String { role == "leader" ? "리더" : "팔로워" }

    // 튜플 프로퍼티가 있어 `Equatable`이 자동 합성되지 않는다.
    static func == (lhs: SOArmArmDiagnostic, rhs: SOArmArmDiagnostic) -> Bool {
        lhs.role == rhs.role && lhs.healthy == rhs.healthy
            && lhs.safeForMotionStart == rhs.safeForMotionStart && lhs.error == rhs.error
            && lhs.volts == rhs.volts && lhs.respondingMotors == rhs.respondingMotors
            && lhs.expectedMotors == rhs.expectedMotors && lhs.torqueDisabled == rhs.torqueDisabled
            && lhs.voltageRange?.low == rhs.voltageRange?.low
            && lhs.voltageRange?.high == rhs.voltageRange?.high
    }

    var summary: String {
        if let error, !error.isEmpty { return "\(title) \(error)" }
        return "\(title) \(healthy ? "정상" : "이상") \(voltageText)"
    }
}

// MARK: - 녹화 제어

/// 녹화 중 누르는 세 가지.
///
/// **화면 문구와 전송값이 다르다.** 서버의 `record_manager.control()`은 `right` · `left` ·
/// `esc` 세 값만 받고 나머지는 409로 거절한다(LeRobot의 키보드 리스너를 파일로 흉내 낸 것이라
/// 그 키 이름을 그대로 쓴다). 사람이 읽을 이름은 여기서만 붙인다.
enum SOArmRecordControl: String, CaseIterable, Sendable {
    case success = "right"
    case retry = "left"
    case stop = "esc"

    var title: String {
        switch self {
        case .success: "성공 저장"
        case .retry: "다시 찍기"
        case .stop: "수집 종료"
        }
    }

    var symbol: String {
        switch self {
        case .success: "checkmark.circle.fill"
        case .retry: "arrow.counterclockwise"
        case .stop: "stop.fill"
        }
    }

    var help: String {
        switch self {
        case .success: "이번 시연을 데이터셋에 저장하고 다음 에피소드로 넘어갑니다"
        case .retry: "이번 시연을 버리고 같은 에피소드를 다시 찍습니다"
        case .stop: "남은 에피소드를 포기하고 수집을 끝냅니다"
        }
    }
}

// MARK: - 클라이언트

struct SOArmClient: Sendable {
    var baseURL: URL

    static let teleopConfirmation = "START SOARM101"
    static let recordConfirmation = "RECORD SOARM101"

    /// 서버가 받는 에피소드 수의 상한.
    ///
    /// 시연을 몇 번 할지는 시작 전에 정하는 값이 아니다 — 될 때까지 찍다가 그만두는 것이고,
    /// 끝내는 방법은 이미 `수집 종료` 버튼으로 있다. 서버 API가 숫자를 요구하므로 상한을
    /// 보내고, 실제 종료는 사람이 정한다. `record_manager.start()`가 1…1000만 받는다.
    static let openEndedEpisodes = 1000

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 10
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }()

    func status() async throws -> SOArmStatus {
        try SOArmStatus.parse(try await send("/api/status", method: "GET", timeout: 8))
    }

    /// 읽기 전용이지만 실제로 두 serial bus를 하나씩 열어 본다. 몇 초가 걸리고, 모드가
    /// 도는 동안에는 서버가 409로 거절한다. 그래서 폴링하지 않고 버튼에만 붙인다.
    func doctor() async throws -> SOArmDoctor {
        let data = try await send("/api/doctor", method: "POST", timeout: 60)
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw SOArmError.badResponse("진단 결과가 JSON이 아닙니다")
        }
        return SOArmDoctor(json)
    }

    func startTeleoperation(confirmation: String) async throws {
        _ = try await send("/api/teleoperation/start", method: "POST", body: ["confirmation": confirmation], timeout: 60)
    }

    func stopTeleoperation() async throws {
        _ = try await send("/api/teleoperation/stop", method: "POST", timeout: 30)
    }

    func startRecording(confirmation: String, task: String, episodes: Int, episodeSeconds: Int) async throws {
        _ = try await send(
            "/api/recording/start",
            method: "POST",
            body: [
                "confirmation": confirmation,
                "task": task,
                "episodes": episodes,
                "episode_seconds": episodeSeconds,
            ],
            timeout: 60
        )
    }

    func control(_ key: SOArmRecordControl) async throws {
        _ = try await send("/api/recording/control", method: "POST", body: ["key": key.rawValue], timeout: 15)
    }

    /// 비상 중지 성격의 명시적 사용자 액션. 도는 모드가 무엇이든 전부 내린다.
    func stopActiveMode() async throws {
        _ = try await send("/api/mode/stop", method: "POST", timeout: 30)
    }

    /// 프리뷰 화질·프레임을 바꾼다. 서버가 못 하는 조합은 400으로 거절하므로 그 말을 그대로 올린다.
    func setCameraProfile(_ name: String, _ profile: SOArmCameraProfile) async throws {
        _ = try await send(
            "/api/cameras/\(name)/settings",
            method: "POST",
            body: ["width": profile.width, "height": profile.height, "fps": profile.fps],
            timeout: 15
        )
    }

    func stopCamera(_ name: String) async throws {
        _ = try await send("/api/cameras/\(name)/stop", method: "POST", timeout: 10)
    }

    func datasets() async throws -> [SOArmDatasetSummary] {
        try SOArmDatasetSummary.list(try await send("/api/datasets", method: "GET", timeout: 20))
    }

    func dataset(_ name: String) async throws -> SOArmDatasetDetail {
        try SOArmDatasetDetail.parse(try await send("/api/datasets/\(name)", method: "GET", timeout: 30))
    }

    /// 서버가 준 경로를 그대로 붙인다. 영상은 내려받지 않고 Range 요청으로 필요한 구간만 읽는다.
    func videoURL(_ path: String) -> URL {
        // 경로에 `?from=…&to=…`가 들어 있다. `appending(path:)`는 그것까지 경로로 인코딩해
        // 버리므로 주소를 직접 잇는다.
        URL(string: baseURL.absoluteString + (path.hasPrefix("/") ? path : "/" + path)) ?? baseURL
    }

    func cameraURL(_ name: String) -> URL {
        baseURL.appending(path: "api/cameras/\(name).mjpg")
    }

    // MARK: 전송

    private func send(_ path: String, method: String, body: [String: any Sendable]? = nil, timeout: TimeInterval) async throws -> Data {
        var request = URLRequest(url: baseURL.appending(path: path.hasPrefix("/") ? String(path.dropFirst()) : path))
        request.httpMethod = method
        request.timeoutInterval = timeout
        request.cachePolicy = .reloadIgnoringLocalCacheData
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await Self.session.data(for: request)
        } catch {
            throw SOArmError.unreachable(Self.reason(for: error))
        }
        guard let http = response as? HTTPURLResponse else {
            throw SOArmError.badResponse("HTTP 응답이 아닙니다")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw Self.error(status: http.statusCode, body: data)
        }
        return data
    }

    /// 왜 못 닿았는지를 한국어로.
    ///
    /// `URLError.localizedDescription`은 번들에 한국어 자원이 없으면 영어로 나온다. 화면의
    /// 나머지가 전부 한국어인데 실패 이유만 영어면, 그 한 줄이 정확히 읽혀야 할 상황에서
    /// 가장 안 읽힌다. 아는 코드만 옮기고 모르는 것은 원문을 그대로 남긴다.
    static func reason(for error: Error) -> String {
        guard let urlError = error as? URLError else { return error.localizedDescription }
        switch urlError.code {
        case .cannotConnectToHost:
            return "그 포트에서 아무도 응답하지 않습니다 (콘솔이 꺼져 있거나 터널이 닫혔습니다)"
        case .cannotFindHost:
            return "주소를 찾지 못했습니다"
        case .timedOut:
            return "제한 시간 안에 응답이 없었습니다"
        case .networkConnectionLost:
            return "연결이 도중에 끊겼습니다"
        case .notConnectedToInternet:
            return "네트워크에 연결되어 있지 않습니다"
        case .cancelled:
            return "요청이 취소되었습니다"
        default:
            return urlError.localizedDescription
        }
    }

    /// FastAPI는 실패를 `{"detail": "..."}`로 준다. 그 문장이 무엇이 막혔는지 가장 정확하게
    /// 말해 주므로, 우리 문장으로 덮어쓰지 않고 그대로 올린다.
    static func error(status: Int, body: Data) -> SOArmError {
        var detail = ""
        if let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] {
            detail = json.soarmString("detail") ?? ""
        }
        if detail.isEmpty { detail = "HTTP \(status)" }
        switch status {
        case 400: return .confirmationMismatch(detail)
        case 404: return .badResponse(detail)
        case 409: return .blocked(detail)
        case 500...599: return .serverFailure(detail)
        default: return .badResponse(detail)
        }
    }
}

// MARK: - preflight 문장을 한국어로

/// 서버가 돌려주는 preflight 문장은 영어 한 줄짜리 진단이다. 화면에는 무엇을 해야 하는지가
/// 보여야 하므로 아는 것만 옮기고, 모르는 문장은 원문을 그대로 남긴다. 조용히 삼키면
/// 서버가 새 게이트를 추가했을 때 이유 없이 막힌 것처럼 보인다.
enum SOArmPreflightText {
    static func korean(_ line: String) -> String {
        if line.contains("SOARM_ENABLE_MOTION") {
            return "서버에서 motion gate가 닫혀 있습니다 (config/soarm.env의 SOARM_ENABLE_MOTION=1 후 서비스 재시작)"
        }
        if line.contains("SOARM_CAMERA_ROLES_CONFIRMED") {
            return "Scene·Wrist 카메라 역할이 확인되지 않았습니다 (서버에서 SOARM_CAMERA_ROLES_CONFIRMED=1)"
        }
        if line.contains("lerobot-teleoperate") {
            return "서버에 lerobot-teleoperate 실행 파일이 없습니다 (uv sync가 끝났는지 확인)"
        }
        if line.contains("leader port") { return "리더 팔의 serial 포트를 찾지 못했습니다" }
        if line.contains("follower port") { return "팔로워 팔의 serial 포트를 찾지 못했습니다" }
        if line.lowercased().contains("calibration") {
            let arm = line.lowercased().contains("leader") ? "리더" : (line.lowercased().contains("follower") ? "팔로워" : "")
            return "\(arm) 캘리브레이션이 없거나 올바르지 않습니다 (서버에서 scripts/calibrate_*.sh)".trimmingCharacters(in: .whitespaces)
        }
        return line
    }
}

// MARK: - JSON 도우미

/// 이름에 `soarm`을 붙인 이유: `Dictionary`의 확장은 앱 전체에 보이므로, 여기서만 쓰는
/// 느슨한 접근자가 다른 파일의 이름과 부딪히지 않게 한다.
extension Dictionary where Key == String, Value == Any {
    func soarmDict(_ key: String) -> [String: Any] { self[key] as? [String: Any] ?? [:] }
    func soarmString(_ key: String) -> String? {
        guard let value = self[key] as? String, !value.isEmpty else { return nil }
        return value
    }
    func soarmBool(_ key: String) -> Bool {
        if let value = self[key] as? Bool { return value }
        return (self[key] as? NSNumber)?.boolValue ?? false
    }
    func soarmInt(_ key: String) -> Int? { (self[key] as? NSNumber)?.intValue }
    func soarmDouble(_ key: String) -> Double? { (self[key] as? NSNumber)?.doubleValue }
    func soarmStrings(_ key: String) -> [String] {
        (self[key] as? [Any])?.compactMap { $0 as? String } ?? []
    }
}

// MARK: - 진단 점검표

/// `환경 진단`이 내놓는 한 줄.
///
/// 앱의 `설정 › 연결 상태`와 같은 모양을 쓴다(`ConnectionCheck.State`). 같은 질문 —
/// *지금 실제로 닿는가, 무엇이 정상인가* — 에 답하는 화면이 앱 안에 두 가지 모양으로 있으면
/// 읽는 사람이 매번 다시 배워야 한다.
struct SOArmCheck: Identifiable, Sendable, Equatable {
    var state: ConnectionCheck.State
    var symbol: String
    var title: String
    var summary: String

    var id: String { title }
}

/// 서버 상태와 읽기 전용 진단을 항목별 점검표로 바꾼다.
///
/// 관절값을 늘어놓는 것과 점검표는 다른 물건이다. 숫자는 무엇이 잘못됐는지 알고 있을 때만
/// 쓸모가 있고, 진단을 누르는 순간에 알고 싶은 것은 *어디까지 정상인가*이다. 그래서 각 줄이
/// 하나의 질문에 ✅/⚠️/❌로 답하고, 숫자는 그 답의 근거로만 뒤에 붙는다.
enum SOArmDiagnosis {
    static func checks(server: SOArmServer, status: SOArmStatus?) -> [SOArmCheck] {
        guard let status else {
            return [SOArmCheck(state: .failed, symbol: "network", title: "서버 콘솔",
                               summary: "\(server.sshTarget)에 닿지 못했습니다")]
        }
        var checks: [SOArmCheck] = [
            SOArmCheck(
                state: .ok, symbol: "network", title: "서버 콘솔",
                summary: "\(server.sshTarget) · LeRobot \(status.lerobotVersion ?? "버전 미확인")"
            )
        ]

        let arms = status.doctor?.arms ?? []
        for (role, present) in [("leader", status.leaderDeviceExists), ("follower", status.followerDeviceExists)] {
            let korean = role == "leader" ? "리더 팔" : "팔로워 팔"
            if let arm = arms.first(where: { $0.role == role }) {
                if let error = arm.error, !error.isEmpty {
                    checks.append(SOArmCheck(state: .failed, symbol: "dot.radiowaves.left.and.right",
                                             title: korean, summary: error))
                } else {
                    let motors = "모터 \(arm.respondingMotors)/\(arm.expectedMotors) 응답"
                    checks.append(SOArmCheck(
                        state: arm.healthy ? .ok : .failed,
                        symbol: "dot.radiowaves.left.and.right", title: korean,
                        summary: "\(motors) · \(arm.voltageText)"
                    ))
                }
            } else {
                // 진단을 아직 돌리지 않았으면 포트가 보인다는 것까지만 말한다. 장치 파일이
                // 있다는 것과 모터가 대답한다는 것은 다른 사실이다.
                checks.append(SOArmCheck(
                    state: present ? .warning : .failed,
                    symbol: "dot.radiowaves.left.and.right", title: korean,
                    summary: present ? "포트는 보이지만 아직 모터에 물어보지 않았습니다" : "serial 포트를 찾지 못했습니다"
                ))
            }
        }

        if let doctor = status.doctor {
            let disengaged = doctor.arms.allSatisfy(\.torqueDisabled)
            checks.append(SOArmCheck(
                state: doctor.safeForMotionStart ? .ok : .warning,
                symbol: "bolt.slash", title: "토크 상태",
                summary: doctor.safeForMotionStart
                    ? "두 팔 모두 토크가 풀려 있어 동작을 시작할 수 있습니다"
                    : (disengaged ? "모터 상태가 정상 범위를 벗어났습니다" : "토크가 걸려 있어 동작을 시작할 수 없습니다")
            ))
        }

        checks.append(SOArmCheck(
            state: status.leaderCalibrated ? .ok : .failed, symbol: "ruler", title: "리더 캘리브레이션",
            summary: status.leaderCalibrated ? "저장된 캘리브레이션이 있습니다" : "서버에서 scripts/calibrate_leader.sh를 실행하세요"
        ))
        checks.append(SOArmCheck(
            state: status.followerCalibrated ? .ok : .failed, symbol: "ruler", title: "팔로워 캘리브레이션",
            summary: status.followerCalibrated ? "저장된 캘리브레이션이 있습니다" : "서버에서 scripts/calibrate_follower.sh를 실행하세요"
        ))
        checks.append(SOArmCheck(
            state: status.motionEnabled ? .ok : .warning, symbol: "lock.open", title: "Motion gate",
            summary: status.motionEnabled ? "열려 있어 텔레옵을 시작할 수 있습니다" : "닫혀 있습니다 (서버 config/soarm.env의 SOARM_ENABLE_MOTION=1)"
        ))
        checks.append(SOArmCheck(
            state: status.sceneCamera.error == nil ? .ok : .failed, symbol: "video", title: "Scene 카메라",
            summary: status.sceneCamera.error ?? (status.sceneCamera.active ? "연결됨 · 지금 프리뷰 중" : "연결됨")
        ))
        checks.append(SOArmCheck(
            state: status.wristCamera.error == nil ? .ok : .failed, symbol: "video", title: "Wrist 카메라",
            summary: status.wristCamera.error ?? (status.wristCamera.active ? "연결됨 · 지금 프리뷰 중" : "연결됨")
        ))
        checks.append(SOArmCheck(
            state: status.cameraRolesConfirmed ? .ok : .warning, symbol: "checkmark.seal", title: "카메라 역할 확인",
            summary: status.cameraRolesConfirmed
                ? "Scene·Wrist가 확인되어 데이터 수집을 할 수 있습니다"
                : "확인되지 않아 데이터 수집이 막혀 있습니다 (서버 SOARM_CAMERA_ROLES_CONFIRMED=1)"
        ))
        return checks
    }
}

// MARK: - 수집한 데이터셋

/// 목록에 한 줄로 나오는 데이터셋.
struct SOArmDatasetSummary: Sendable, Equatable, Identifiable {
    var name = ""
    var episodes = 0
    var frames = 0
    var fps = 0
    var cameras: [String] = []
    var sizeBytes = 0
    var recordedAt: Date?

    var id: String { name }

    /// 초 단위 길이. 프레임 수를 fps로 나눈 값이라 실제 녹화 길이와 같다.
    var seconds: Double { fps > 0 ? Double(frames) / Double(fps) : 0 }

    init() {}

    init(_ json: [String: Any]) {
        name = json.soarmString("name") ?? ""
        episodes = json.soarmInt("episodes") ?? 0
        frames = json.soarmInt("frames") ?? 0
        fps = json.soarmInt("fps") ?? 0
        cameras = json.soarmStrings("cameras")
        sizeBytes = json.soarmInt("size_bytes") ?? 0
        if let stamp = json.soarmDouble("recorded_at") { recordedAt = Date(timeIntervalSince1970: stamp) }
    }

    static func list(_ data: Data) throws -> [SOArmDatasetSummary] {
        guard let rows = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else {
            throw SOArmError.badResponse("데이터셋 목록이 배열이 아닙니다")
        }
        return rows.map(SOArmDatasetSummary.init).filter { !$0.name.isEmpty }
    }
}

/// 한 데이터셋의 에피소드까지.
struct SOArmDatasetDetail: Sendable, Equatable {
    var summary = SOArmDatasetSummary()
    var episodes: [SOArmEpisode] = []

    static func parse(_ data: Data) throws -> SOArmDatasetDetail {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw SOArmError.badResponse("데이터셋 정보가 JSON이 아닙니다")
        }
        var detail = SOArmDatasetDetail()
        detail.summary = SOArmDatasetSummary(json)
        let rows = (json["episodes_detail"] as? [Any])?.compactMap { $0 as? [String: Any] } ?? []
        detail.episodes = rows.map { SOArmEpisode($0, fps: detail.summary.fps) }
        return detail
    }
}

struct SOArmEpisode: Sendable, Equatable, Identifiable {
    var index = 0
    var task = ""
    var frames = 0
    var seconds: Double = 0
    /// video key → 재생 정보. v3에서는 여러 에피소드가 한 파일에 이어 붙으므로 구간이 필요하다.
    var videos: [String: SOArmEpisodeVideo] = [:]

    var id: Int { index }

    init(_ json: [String: Any], fps: Int) {
        index = json.soarmInt("index") ?? 0
        task = json.soarmString("task") ?? ""
        frames = json.soarmInt("frames") ?? 0
        seconds = fps > 0 ? Double(frames) / Double(fps) : 0
        for (key, value) in json.soarmDict("videos") {
            guard let entry = value as? [String: Any] else { continue }
            videos[key] = SOArmEpisodeVideo(entry)
        }
    }
}

struct SOArmEpisodeVideo: Sendable, Equatable {
    var path = ""
    var fromSeconds: Double = 0
    var toSeconds: Double = 0

    init(_ json: [String: Any]) {
        path = json.soarmString("url") ?? ""
        fromSeconds = json.soarmDouble("from_seconds") ?? 0
        toSeconds = json.soarmDouble("to_seconds") ?? 0
    }
}

/// `observation.images.scene` → `작업공간`. 서버가 쓰는 feature 이름은 화면에 그대로 내놓기엔
/// 길고, 그 뒤의 한 마디가 사람이 부르는 이름이다.
enum SOArmCameraName {
    static func display(_ key: String) -> String {
        let short = key.split(separator: ".").last.map(String.init) ?? key
        switch short {
        case "scene": return "작업공간"
        case "wrist": return "손목"
        default: return short
        }
    }
}
