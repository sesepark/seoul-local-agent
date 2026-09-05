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
    /// 집에서 쓰는 주소. LAN의 고정 IP이거나 호스트 이름이다.
    var host = ""
    /// 집 밖에서 쓰는 주소. 비워 두어도 된다.
    ///
    /// 같은 서버로 가는 **두 번째 길**이다. 맥이 집 네트워크를 벗어나면 LAN 주소는 닿지
    /// 않는데, 그 서버는 Tailscale로 같은 tailnet에 있으므로 tailnet 주소로는 여전히
    /// 닿는다. 두 칸을 두고 먼저 열리는 쪽을 쓰면, 어디에 있든 같은 화면이 그대로 뜬다.
    ///
    /// 주소를 하나로 합치지 않은 이유: tailnet 주소만 남기면 Tailscale이 꺼져 있을 때
    /// **집에서도** 닿지 못한다. 집 안에서 쓰는 길과 밖에서 쓰는 길은 서로의 대비책이다.
    var alternateHost = ""
    var user = ""
    var sshPort = 22
    /// 이 Mac에서 열 포트. 이미 다른 터널이 8088을 쓰고 있으면 여기서 바꾼다.
    var localPort = 8088
    /// 서버에서 콘솔이 듣고 있는 포트. `config/soarm.env`의 `SOARM_WEB_PORT`와 같아야 한다.
    var remotePort = 8088
    /// 팔을 움직이는 요청에 붙이는 토큰. 서버 `config/soarm.env`의 `SOARM_MOTION_TOKEN`과
    /// 같아야 한다.
    ///
    /// 관찰과 조작의 권한을 가르는 자리다. 터널 너머로 상태와 카메라를 보는 데는 아무것도
    /// 필요 없지만, 팔로워를 움직이는 요청에는 이 토큰이 있어야 한다. 폰이 같은 tailnet에서
    /// 붙게 되면서 생긴 구분이고, 토큰을 갈아 끼우면 조작 권한만 끊긴다.
    var motionToken = ""

    var isConfigured: Bool {
        !candidateHosts.isEmpty && !user.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// 시도해 볼 주소들. 적어 둔 순서대로이고, 빈 칸과 중복은 빠진다.
    var candidateHosts: [String] {
        var seen = Set<String>()
        return [host, alternateHost]
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    func sshTarget(host: String) -> String {
        "\(user.trimmingCharacters(in: .whitespaces))@\(host)"
    }

    /// 항상 loopback. 서버를 `0.0.0.0`으로 열어 LAN에 노출하는 경로는 만들지 않는다.
    var baseURL: URL {
        URL(string: "http://127.0.0.1:\(Self.validPort(localPort))") ?? URL(string: "http://127.0.0.1:8088")!
    }

    /// 화면에 적을 이름. 지금 붙어 있는 주소가 있으면 그것을, 없으면 첫 번째 후보를 쓴다.
    var sshTarget: String {
        sshTarget(host: SOArmTunnel.shared.connectedHost ?? candidateHosts.first ?? "")
    }

    static func validPort(_ value: Int) -> Int { min(max(value, 1), 65535) }

    /// 없는 키는 기본값으로 둔다.
    ///
    /// Swift가 합성해 주는 디코더는 **기본값이 있어도** 키가 없으면 실패한다. 그래서
    /// `motionToken`을 하나 늘렸을 때, 그 키가 없는 예전 `soarm-console.json`이 통째로
    /// 디코딩에 실패하며 서버 주소와 계정까지 함께 사라졌다. 이 앱의 설정 파일은 앱보다
    /// 오래 살아 있는 것이므로, 필드가 늘거나 줄어도 읽히는 편이 옳다.
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        host = try values.decodeIfPresent(String.self, forKey: .host) ?? ""
        alternateHost = try values.decodeIfPresent(String.self, forKey: .alternateHost) ?? ""
        user = try values.decodeIfPresent(String.self, forKey: .user) ?? ""
        sshPort = try values.decodeIfPresent(Int.self, forKey: .sshPort) ?? 22
        localPort = try values.decodeIfPresent(Int.self, forKey: .localPort) ?? 8088
        remotePort = try values.decodeIfPresent(Int.self, forKey: .remotePort) ?? 8088
        motionToken = try values.decodeIfPresent(String.self, forKey: .motionToken) ?? ""
    }

    init(host: String = "", alternateHost: String = "", user: String = "", sshPort: Int = 22,
         localPort: Int = 8088, remotePort: Int = 8088, motionToken: String = "") {
        self.host = host
        self.alternateHost = alternateHost
        self.user = user
        self.sshPort = sshPort
        self.localPort = localPort
        self.remotePort = remotePort
        self.motionToken = motionToken
    }

    /// 저장된 파일이 손으로 고쳐졌을 수도 있으므로 읽을 때 한 번 걸러 낸다.
    func sanitised() -> SOArmServer {
        SOArmServer(
            host: host.trimmingCharacters(in: .whitespaces),
            alternateHost: alternateHost.trimmingCharacters(in: .whitespaces),
            user: user.trimmingCharacters(in: .whitespaces),
            sshPort: Self.validPort(sshPort),
            localPort: Self.validPort(localPort),
            remotePort: Self.validPort(remotePort),
            motionToken: motionToken.trimmingCharacters(in: .whitespacesAndNewlines)
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
            Self.korean(for: detail) ?? detail
        case .serverFailure(let detail):
            "서버가 요청을 끝내지 못했습니다: \(detail). 팔이 계속 움직이면 물리 전원을 차단하세요."
        case .badResponse(let detail):
            "서버 응답을 읽지 못했습니다: \(detail)"
        }
    }

    /// 서버가 영어로 적어 보내는 거절 가운데, **어느 버튼을 눌러야 하는지**가 답인 것들.
    ///
    /// 서버의 `detail`은 대체로 그 자체가 가장 정확한 설명이라 그대로 보여 주는 것이
    /// 맞다. 그러나 이 몇 개는 다르다. `Stop the virtual leader…`를 읽고 사용자가 실제로
    /// 한 일은 `정지`와 `권한 반납`을 누른 것이었고, 그 둘로는 관찰이 꺼지지 않는다 —
    /// 화면은 "관찰 전용"이라고 적혀 있으니 이미 멈춘 것으로 읽힌다. 문장이 버튼 이름을
    /// 말하지 않으면 사용자는 같은 버튼을 다시 누른다.
    static func korean(for detail: String) -> String? {
        if detail.hasPrefix("Stop the virtual leader before physical-leader teleoperation") {
            return "가상 리더가 아직 팔로워 USB를 쥐고 있습니다. 원격 텔레옵 화면에서 `관찰 끄기`를 누른 뒤 다시 시작하세요 — `정지`와 `권한 반납`은 관찰을 끄지 않습니다."
        }
        if detail.hasPrefix("Stop the virtual leader before recording") {
            return "가상 리더가 아직 팔로워 USB를 쥐고 있습니다. 원격 텔레옵 화면에서 `관찰 끄기`를 누른 뒤 수집을 시작하세요 — `정지`와 `권한 반납`은 관찰을 끄지 않습니다."
        }
        if detail.hasPrefix("Recording fixes every camera at") {
            return "데이터 수집이 도는 동안에는 카메라 설정을 바꿀 수 없습니다. 수집은 언제나 같은 화질로 찍습니다."
        }
        return nil
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
    var replay = SOArmReplay()
    var doctor: SOArmDoctor?
    /// 데이터 수집이 고정으로 쓰는 카메라 설정. 서버가 정하고 앱은 그대로 옮겨 적는다.
    var recordingProfile = SOArmCameraProfile.recordingDefault
    /// 가상 리더의 관찰 루프가 팔로워 USB를 쥐고 있는가.
    ///
    /// 팔로워의 주인은 하나뿐이라, 이것이 참인 동안에는 물리 리더 텔레옵도 데이터 수집도
    /// 시작할 수 없다. 서버는 이 사실을 `/api/status`에 늘 실어 보내는데 앱이 읽지 않고
    /// 있었다 — 그래서 `텔레옵 시작`이 눌리는 채로 남아 있다가, 누르면 영어 409 한 줄을
    /// 돌려주었다. 막힌 것을 **누르기 전에** 말해야 한다.
    var virtualLeaderRunning = false

    /// 팔로워를 다른 것이 쥐고 있어서 시작할 수 없다면, 그 이유와 풀 방법.
    var followerHeldElsewhere: String? {
        if replay.running {
            return "찍은 시연을 팔에 재생하는 중입니다. `수집 데이터` 화면에서 재생을 멈춘 뒤 다시 시작하세요."
        }
        guard virtualLeaderRunning else { return nil }
        return "가상 리더가 팔로워 USB를 쥐고 있습니다. 원격 텔레옵 화면에서 `관찰 끄기`를 누르세요 — `정지`와 `권한 반납`은 관찰을 끄지 않습니다."
    }

    var teleopReady: Bool { motionEnabled && teleopPreflight.isEmpty && followerHeldElsewhere == nil }
    var recordReady: Bool { motionEnabled && recordPreflight.isEmpty && followerHeldElsewhere == nil }
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
        status.virtualLeaderRunning = root.soarmDict("virtual_leader").soarmBool("running")
        status.replay = SOArmReplay(root.soarmDict("replay"))
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
    /// 수집을 시작할 때 서버가 이 카메라에 넣고 **되읽은** V4L2 값. 넣으려 한 값이 아니라
    /// 장치가 돌려준 값이라, 화면이 적는 것과 카메라가 하는 일이 어긋나지 않는다.
    var recordingControls: [String: Int] = [:]
    /// 그중 장치가 받아 주지 않은 것들. 카메라를 바꾸면 목록이 달라질 수 있다.
    var recordingControlFailures: [String] = []
    /// 이 카메라가 정말로 낼 수 있는 모드. 서버가 장치에 직접 물어서 준다.
    var modes: [SOArmCameraMode] = []

    init() {}

    init(_ json: [String: Any]) {
        active = json.soarmBool("active")
        clients = json.soarmInt("clients") ?? 0
        error = json.soarmString("error")
        if let profile = SOArmCameraProfile(json.soarmDict("requested")) { requested = profile }
        if let value = json["actual"] as? [String: Any] { actual = SOArmCameraProfile(value) }
        let controls = json.soarmDict("recording_controls")
        recordingControls = controls.soarmDict("values").compactMapValues { ($0 as? NSNumber)?.intValue }
        recordingControlFailures = (controls["failures"] as? [Any] ?? []).compactMap { $0 as? String }
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
    /// LeRobot이 "Record loop is running slower…"를 낸 횟수. 서버가 로그에서 세어 준다.
    ///
    /// 이 경고가 데이터가 조용히 나빠지는 것을 알려 주는 유일한 신호다. 데이터셋의
    /// `timestamp`는 `frame_index / fps`로 계산되므로, 루프가 느렸어도 파일은 언제나
    /// 30fps라고 적는다. 경고를 로그 안에만 두면 아무도 읽지 않는다.
    var slowLoopWarnings = 0

    init() {}

    init(_ json: [String: Any]) {
        running = json.soarmBool("running")
        pid = json.soarmInt("pid")
        logs = json.soarmStrings("logs")
        slowLoopWarnings = json.soarmInt("slow_loop_warnings") ?? 0
    }
}

struct SOArmRecordingRuntime: Sendable, Equatable {
    var phase: String?
    var datasetName: String?
    var task: String?
    var lastControl: String?
    /// 지금 회가 시작한 시각(서버의 벽시계). 서버가 알려 주지 않으면 `nil`이고, 그때
    /// 화면은 남은 시간을 세지 않는다 — 앱이 혼자 세면 회 사이 정리 시간만큼 어긋난다.
    var episodeStartedAt: Date?
    /// 한 회의 최대 길이(초). 서버가 실제로 쓴 값이지 앱이 보낸 값이 아니다.
    var episodeSeconds: Int?
    /// 지금 몇 번째 회인가. 0부터 센다.
    var episodeIndex: Int?
    /// 수집 루프가 실제로 도는 속도. 30을 목표로 도는데 못 지키면 이미지가 중복되고,
    /// 그것은 로그에만 남아 조용히 데이터가 나빠지는 유일한 경로다.
    var loopHz: Double?

    init(_ json: [String: Any]) {
        phase = json.soarmString("phase")
        datasetName = json.soarmString("dataset_name")
        task = json.soarmString("task")
        lastControl = json.soarmString("last_control")
        if let seconds = (json["episode_started_at"] as? NSNumber)?.doubleValue, seconds > 0 {
            episodeStartedAt = Date(timeIntervalSince1970: seconds)
        }
        episodeSeconds = json.soarmInt("episode_seconds")
        episodeIndex = json.soarmInt("episode_index")
        loopHz = (json["loop_hz"] as? NSNumber)?.doubleValue
    }

    var phaseTitle: String {
        switch phase {
        case "starting": "시작하는 중"
        case "recording": "수집 중"
        // 회와 회 사이. 이때는 팔을 제자리로 돌려놓는 시간이고 남은 시간을 세면 안 된다.
        case "resetting": "다음 회 준비 중"
        case "complete": "완료"
        case "error": "오류로 끝남"
        default: phase ?? "—"
        }
    }
}

/// 찍은 에피소드를 실제 팔에 다시 흘리는 재생의 상태.
///
/// 사람 손 없이 팔이 움직이는 유일한 경로라, 화면은 언제나 지금 어느 단계인지와 정지
/// 버튼을 함께 보여 준다.
struct SOArmReplay: Sendable, Equatable {
    var running = false
    var phase: String?
    var dataset: String?
    var episode: Int?
    var frame = 0
    var totalFrames = 0
    var speed = 0.5
    /// 정렬 단계가 몇 초 남았는가. 재생 단계에서는 0이다.
    var aligningSecondsLeft: Double = 0
    var error: String?
    var speeds: [Double] = [0.25, 0.5, 1.0]
    var defaultSpeed = 0.5
    var logs: [String] = []

    /// 팔이 지금 움직이고 있는가. `running`은 프로세스가 살아 있다는 뜻일 뿐이라,
    /// 끝난 뒤 상태만 남은 순간과 구별해야 한다.
    var isMoving: Bool { running && (phase == "aligning" || phase == "replaying") }

    var phaseTitle: String {
        switch phase {
        // 첫 프레임으로 뛰지 않으려고 걸어서 가는 구간이다. 이때 팔이 움직이는 것은
        // 녹화된 동작이 아니라 출발점까지 가는 길이라, 화면이 다르게 말해야 한다.
        case "aligning": "시작 자세로 가는 중"
        case "replaying": "재생 중"
        case "complete": "끝났습니다"
        case "stopped": "중간에 멈췄습니다"
        case "error": "오류로 멈췄습니다"
        default: phase ?? "—"
        }
    }

    var progress: Double {
        totalFrames > 0 ? min(1, Double(frame) / Double(totalFrames)) : 0
    }

    init() {}

    init(_ json: [String: Any]) {
        running = json.soarmBool("running")
        logs = json.soarmStrings("logs")
        speeds = (json["speeds"] as? [Any] ?? []).compactMap { ($0 as? NSNumber)?.doubleValue }
        if speeds.isEmpty { speeds = [0.25, 0.5, 1.0] }
        defaultSpeed = (json["default_speed"] as? NSNumber)?.doubleValue ?? 0.5
        let runtime = json.soarmDict("runtime")
        phase = runtime.soarmString("phase")
        dataset = runtime.soarmString("dataset")
        episode = runtime.soarmInt("episode")
        frame = runtime.soarmInt("frame") ?? 0
        totalFrames = runtime.soarmInt("total_frames") ?? 0
        speed = (runtime["speed"] as? NSNumber)?.doubleValue ?? defaultSpeed
        aligningSecondsLeft = (runtime["aligning_seconds_left"] as? NSNumber)?.doubleValue ?? 0
        error = runtime.soarmString("error")
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
    /// 팔을 움직이는 요청에만 붙는다. 관찰에는 필요 없다 — 서버가 그렇게 가른다.
    var motionToken: String = ""

    static let teleopConfirmation = "START SOARM101"
    static let recordConfirmation = "RECORD SOARM101"
    /// 가상 리더가 쓰는 것과 같은 문구다. 푸는 일이 같으므로 문구도 같아야 한다.
    static let torqueReleaseConfirmation = "RELEASE TORQUE SOARM101"

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

    static let replayConfirmation = "REPLAY SOARM101"

    /// 찍은 에피소드를 팔에 다시 흘린다. **팔이 실제로 움직인다.**
    func startReplay(confirmation: String, dataset: String, episode: Int, speed: Double) async throws {
        _ = try await send(
            "/api/replay/start", method: "POST",
            body: ["confirmation": confirmation, "dataset": dataset, "episode": episode, "speed": speed],
            timeout: 30
        )
    }

    func stopReplay() async throws {
        _ = try await send("/api/replay/stop", method: "POST", timeout: 15)
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

    /// 한 팔의 토크를 푼다. 받치지 않으면 팔이 내려앉는다.
    ///
    /// 가상 리더에도 같은 일을 하는 자리가 있지만 그것은 가상 리더가 돌고 있을 때만 쓸 수
    /// 있다. 이전 세션이 남긴 토크 때문에 텔레옵이 거절되는 자리는 그 밖이라, 서버가 따로
    /// 내놓은 길이 필요했다.
    func releaseTorque(arm: String) async throws {
        _ = try await send(
            "/api/torque/release",
            method: "POST",
            body: ["arm": arm, "confirmation": Self.torqueReleaseConfirmation],
            timeout: 60,
            motionToken: motionToken
        )
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

    // MARK: 학습 서버(Spark)

    /// 학습 서버가 살아 있는지, GPU와 디스크가 어떤 상태인지.
    ///
    /// 콘솔 서버가 대신 물어봐 준다. 이 Mac이 학습 서버에 직접 붙지 않는 이유는 팔에 대한
    /// 것과 같다 — 서버 하나가 장치와 원격 기계를 쥐고, 앱은 그 서버만 부른다.
    func sparkStatus() async throws -> SOArmSparkStatus {
        SOArmSparkStatus(try await send("/api/spark", method: "GET", timeout: 60))
    }

    /// 학습 서버에 이미 올라가 있는 데이터셋 이름들.
    func sparkDatasets() async throws -> [SOArmSparkDataset] {
        try SOArmSparkDataset.list(try await send("/api/spark/datasets", method: "GET", timeout: 60))
    }

    /// 데이터셋 하나를 학습 서버로 보낸다.
    ///
    /// 서버가 rsync가 끝날 때까지 응답을 붙들고 있으므로 타임아웃이 길다. 에피소드 몇 개는
    /// 금방이지만 수 기가바이트는 몇 분이 걸린다. 진행률을 보여 줄 수 없는 것은 서버 API가
    /// 아직 한 번에 답하기 때문이고, 그 편이 지금은 정직하다 — 없는 진행률을 지어내면
    /// 멈춘 전송과 느린 전송을 구별할 수 없다.
    func pushToSpark(_ name: String) async throws {
        _ = try await send("/api/spark/datasets/\(name)", method: "POST", timeout: 3600)
    }

    /// 학습 서버의 학습 실행과 체크포인트.
    func sparkRuns() async throws -> [SOArmSparkRun] {
        try SOArmSparkRun.list(try await send("/api/spark/runs", method: "GET", timeout: 60))
    }

    /// 체크포인트 하나를 서버로 회수한다. 이 Mac이 아니라 콘솔 서버에 내려온다 — 추론은
    /// 팔이 붙어 있는 그 서버에서 돈다.
    func pullCheckpoint(run: String, step: String) async throws {
        _ = try await send("/api/spark/runs/\(run)/\(step)", method: "POST", timeout: 1800)
    }

    // MARK: 전송

    private func send(_ path: String, method: String, body: [String: any Sendable]? = nil, timeout: TimeInterval, motionToken: String = "") async throws -> Data {
        var request = URLRequest(url: baseURL.appending(path: path.hasPrefix("/") ? String(path.dropFirst()) : path))
        request.httpMethod = method
        request.timeoutInterval = timeout
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let token = motionToken.trimmingCharacters(in: .whitespacesAndNewlines)
        if !token.isEmpty {
            request.setValue(token, forHTTPHeaderField: "x-soarm-motion-token")
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
        detail = SOArmServerText.korean(detail)
        switch status {
        case 400: return .confirmationMismatch(detail)
        case 401: return .blocked(detail)
        case 404: return .badResponse(detail)
        case 409: return .blocked(detail)
        case 500...599: return .serverFailure(detail)
        default: return .badResponse(detail)
        }
    }
}

// MARK: - 거절 문장을 한국어로

/// 서버가 `detail`로 돌려주는 영어 한 줄을 화면의 말로 옮긴다.
///
/// 이 앱은 전부 한국어인데 거절 문장만 영어로 튀어나왔다. "Torque is still enabled…"이
/// 화면 한가운데 빨간 띠로 떠 있는 것을 실제로 봤고, 그 문장은 무엇을 해야 하는지도
/// 말해 주지 않았다. 규칙은 preflight 쪽과 같다 — 아는 문장만 옮기고, 모르는 문장은
/// 원문을 남긴다. 조용히 삼키면 서버가 새 거절을 추가했을 때 이유가 사라진다.
enum SOArmServerText {
    static func korean(_ detail: String) -> String {
        let table: [(String, String)] = [
            ("Torque is still enabled",
             "토크가 아직 걸려 있습니다. 팔을 받쳐 줄 사람이 있을 때 `토크 해제`로 명시적으로 풀거나, 먼저 팔을 세우세요."),
            ("Torque is disabled",
             "토크가 꺼져 있어 팔이 목표를 따라갈 수 없습니다. 먼저 조작 권한을 받으세요."),
            ("Enable torque first",
             "토크가 꺼져 있습니다. 조작 권한을 받으면 토크가 걸리고 팔이 목표를 따라갑니다."),
            ("Torque belongs to the recording process",
             "데이터 수집이 팔을 쥐고 있습니다. 수집을 먼저 끝내세요."),
            ("Clear the fault before arming",
             "멈춘 이유를 먼저 확인해 주세요. `확인하고 계속`을 누르면 지금 자세에서 다시 시작합니다."),
            ("Confirmation phrase does not match", "확인 문구가 맞지 않습니다."),
            // 학습 서버로 보내고 받는 길에서 나는 실패들. 끊긴 전송은 받다 만 곳이 서버에
            // 남아 있으므로, 다시 눌러도 처음부터 다시 보내지 않는다는 점을 함께 말한다.
            ("The connection dropped during transfer",
             "전송 도중 연결이 끊겼습니다. 다시 누르면 받다 만 곳부터 이어받습니다."),
            ("The transfer did not finish within",
             "전송이 제한 시간 안에 끝나지 않았습니다. 다시 누르면 이어받습니다."),
            ("The training machine has no free disk space",
             "학습 서버의 디스크가 가득 찼습니다. 오래된 데이터셋이나 체크포인트를 지운 뒤 다시 시도하세요."),
            ("Cannot find the training machine on the network",
             "학습 서버 주소를 찾지 못했습니다. Tailscale이 켜져 있는지 확인하세요."),
            ("The training machine refused the login",
             "학습 서버가 로그인을 거절했습니다. 콘솔 서버의 SSH 키가 학습 서버에 등록되어 있는지 확인하세요."),
            ("The training machine's host key changed",
             "학습 서버의 호스트 키가 전과 다릅니다. 기계를 다시 설치했다면 콘솔 서버의 known_hosts에서 옛 항목을 지우세요."),
            ("The training machine refused the connection",
             "학습 서버가 연결을 거절했습니다. 켜져 있는지, sshd가 도는지 확인하세요."),
            ("The training machine did not answer",
             "학습 서버가 응답하지 않습니다. 켜져 있는지 확인하세요."),
            ("The training machine could not write the files",
             "학습 서버가 파일을 쓰지 못했습니다. 디스크 공간과 권한을 확인하세요."),
            ("Some files were not transferred",
             "일부 파일이 전송되지 않았습니다. 다시 누르면 빠진 것만 보냅니다."),
            ("Some files vanished during transfer",
             "전송 도중 원본 파일이 바뀌었습니다. 수집이 끝난 뒤 다시 보내세요."),
            ("The transfer protocol failed",
             "전송 중 프로토콜 오류가 났습니다. 다시 시도하고, 계속 실패하면 양쪽 rsync 버전을 확인하세요."),
            ("The transfer timed out",
             "전송이 시간 안에 끝나지 않았습니다. 다시 누르면 이어받습니다."),
            ("The training machine sent something that is not JSON",
             "학습 서버의 응답을 읽지 못했습니다. 서버 로그를 확인하세요."),
            ("Unknown policy type", "지원하지 않는 정책 종류입니다."),
            ("steps or batch_size out of range", "학습 스텝 수나 배치 크기가 허용 범위를 벗어났습니다."),
            ("Motion token is missing or wrong", wrongTokenLine),
            ("SOARM_ENABLE_MOTION=1 is not set",
             "서버에서 동작이 잠겨 있습니다 (config/soarm.env의 SOARM_ENABLE_MOTION=1 후 서비스 재시작)."),
            ("Virtual leader is already running", "가상 리더가 이미 돌고 있습니다."),
            ("Virtual leader is not running", "가상 리더가 돌고 있지 않습니다. `관찰 시작`을 먼저 누르세요."),
            ("Follower is not connected", "팔로워 팔이 연결되어 있지 않습니다."),
            ("Simulated follower is not connected", "모의 팔로워가 연결되어 있지 않습니다."),
            ("Follower calibration file is missing",
             "팔로워 calibration 파일이 없습니다. 서버에서 scripts/calibrate_follower.sh를 한 번 돌려야 합니다."),
            ("Follower bus did not answer",
             "팔로워 serial 버스가 응답하지 않았습니다. 전원과 케이블을 확인하고 다시 시도하세요."),
            ("Follower bus did not read back healthy",
             "팔로워 serial 버스에서 읽은 값이 정상이 아닙니다. 전원과 케이블을 확인하세요."),
            ("Could not aim the servos",
             "서보를 지금 자세로 겨누지 못했습니다. 다시 시도하고, 계속 실패하면 서버 로그를 보세요."),
            ("Could not start the virtual leader",
             "가상 리더를 시작하지 못했습니다. 잠시 뒤 다시 시도하세요."),
            ("The last known arm position is more than two minutes old",
             "마지막으로 읽은 팔의 자세가 2분보다 오래됐습니다. `관찰 시작`을 다시 누르세요."),
            ("The virtual leader has not read the arm yet",
             "아직 팔을 한 번도 읽지 못했습니다. `관찰 시작`을 먼저 누르세요."),
            ("Missing follower port", "팔로워 팔의 serial 포트를 찾지 못했습니다."),
        ]
        for (needle, korean) in table where detail.contains(needle) {
            // 서버가 이유를 덧붙여 준 경우에는 그 꼬리를 살려 둔다. 무엇이 실패했는지는
            // 대개 그 뒤에 적혀 있다.
            if let range = detail.range(of: ": "), detail.distance(from: detail.startIndex, to: range.lowerBound) < 60,
               needle.contains(":") == false, detail.hasPrefix(needle) {
                return korean + " (" + String(detail[range.upperBound...]) + ")"
            }
            return korean
        }
        return detail
    }

    private static let wrongTokenLine =
        "서버가 조작 토큰을 받아들이지 않았습니다. 설정 › 로봇의 값과 서버 config/soarm.env의 SOARM_MOTION_TOKEN이 같은지 확인하세요."
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

// MARK: - 학습 서버(Spark)

/// 학습 서버의 형편.
///
/// `reachable`이 거짓일 때 이유를 함께 들고 있는 이유는, 화면이 "못 붙었다"만 말하면
/// 사람이 할 수 있는 일이 없기 때문이다. 서버가 꺼진 것과 SSH 키가 없는 것은 다른 일이다.
struct SOArmSparkStatus: Sendable, Equatable {
    var isReachable = false
    var failure: String?
    var host = ""
    var gpuName: String?
    var temperature: Int?
    var watts: Double?
    var diskFreeBytes = 0

    init() {}

    init(_ data: Data) {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
        isReachable = (json["reachable"] as? Bool) ?? false
        failure = json.soarmString("error")
        host = json.soarmString("host") ?? ""
        diskFreeBytes = json.soarmInt("disk_free_bytes") ?? 0
        let gpu = json.soarmDict("gpu")
        gpuName = gpu.soarmString("name")
        // GB10은 통합메모리라 nvidia-smi가 GPU 전용 메모리를 모른다고 답한다. 없는 값은
        // 없는 대로 두고 화면에서 그 줄을 빼는 편이, 0을 그려 있는 척하는 것보다 낫다.
        temperature = gpu.soarmInt("temperature_c")
        watts = gpu.soarmDouble("power_w")
    }
}

/// 학습 서버에 올라가 있는 데이터셋 하나.
struct SOArmSparkDataset: Sendable, Equatable, Identifiable {
    var name = ""
    var episodes = 0
    var frames = 0

    var id: String { name }

    init(_ json: [String: Any]) {
        name = json.soarmString("name") ?? ""
        episodes = json.soarmInt("episodes") ?? 0
        frames = json.soarmInt("frames") ?? 0
    }

    static func list(_ data: Data) throws -> [SOArmSparkDataset] {
        guard let rows = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else {
            throw SOArmError.badResponse("학습 서버 데이터셋 목록이 배열이 아닙니다")
        }
        return rows.map(SOArmSparkDataset.init).filter { !$0.name.isEmpty }
    }
}

/// 학습 실행 하나와 그 체크포인트들.
struct SOArmSparkRun: Sendable, Equatable, Identifiable {
    var name = ""
    var checkpoints: [SOArmSparkCheckpoint] = []

    var id: String { name }

    init(_ json: [String: Any]) {
        name = json.soarmString("run") ?? ""
        let rows = (json["checkpoints"] as? [Any])?.compactMap { $0 as? [String: Any] } ?? []
        checkpoints = rows.map(SOArmSparkCheckpoint.init).filter { !$0.step.isEmpty }
    }

    static func list(_ data: Data) throws -> [SOArmSparkRun] {
        guard let rows = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else {
            throw SOArmError.badResponse("학습 실행 목록이 배열이 아닙니다")
        }
        return rows.map(SOArmSparkRun.init).filter { !$0.name.isEmpty }
    }
}

struct SOArmSparkCheckpoint: Sendable, Equatable, Identifiable {
    var step = ""
    var sizeBytes = 0
    var finishedAt: Date?

    var id: String { step }

    init(_ json: [String: Any]) {
        step = json.soarmString("step") ?? ""
        sizeBytes = json.soarmInt("size_bytes") ?? 0
        if let stamp = json.soarmDouble("finished_at") { finishedAt = Date(timeIntervalSince1970: stamp) }
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
