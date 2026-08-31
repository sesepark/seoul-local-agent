import Foundation
import Combine

/// SO-ARM 101 화면이 들고 있는 상태 전부.
///
/// 서버가 진실의 원본이다. 이 타입은 무엇을 시작하고 멈추라고 지시한 다음, 서버가 말해 주는
/// 상태를 그대로 되비춘다. 앱 쪽에서 "지금 텔레옵 중"이라고 낙관적으로 먼저 표시하지 않는
/// 이유는, 그 낙관이 틀렸을 때 화면이 움직이는 팔에 대해 거짓말을 하기 때문이다.
@MainActor
final class SOArmConsoleModel: ObservableObject {
    enum Connection: Equatable {
        case idle
        case connecting
        case connected
        case failed(String)

        var isConnected: Bool { self == .connected }
    }

    @Published private(set) var connection: Connection = .idle
    @Published private(set) var status: SOArmStatus?
    @Published private(set) var lastUpdated: Date?
    /// 서버를 부르는 동안 참. 버튼 두 번 눌림과 겹친 요청을 막는다.
    @Published private(set) var isBusy = false
    @Published var errorMessage: String?
    @Published var server: SOArmServer {
        didSet {
            guard server != oldValue else { return }
            scheduleSave()
        }
    }
    /// 기존 웹 콘솔을 창 전체에 띄우고 있는가.
    @Published var isConsoleFullScreen = false
    /// `환경 진단`을 눌러 나온 점검표를 보여 주고 있는가. 서버는 마지막 진단 결과를 계속
    /// 들고 있으므로, 눌렀을 때만 펼치고 닫을 수 있게 한다.
    @Published var showsDiagnosis = false

    // 수집 조건. 시트를 닫아도 남아 있어야 해서 화면이 아니라 여기에 둔다.
    @Published var recordTask = ""
    /// 한 에피소드가 저절로 끊기는 상한. 사람이 `성공 저장`·`다시 찍기`를 누르면 그 전에 끝난다.
    @Published var recordSeconds = 30

    let sceneCamera = MJPEGStream()
    let wristCamera = MJPEGStream()

    // 수집 데이터 화면
    @Published private(set) var datasets: [SOArmDatasetSummary] = []
    @Published private(set) var datasetDetail: SOArmDatasetDetail?
    @Published private(set) var isLoadingDatasets = false
    @Published var selectedDataset: String? {
        didSet {
            guard selectedDataset != oldValue else { return }
            datasetDetail = nil
            selectedEpisode = nil
            if let selectedDataset { loadDataset(selectedDataset) }
        }
    }
    @Published var selectedEpisode: Int?
    @Published var selectedCamera: String?

    private let store: SOArmServerStore
    /// 화면을 눌러 보지 않고도 카메라가 붙은 모습과 웹 콘솔을 확인할 수 있게 하는 실행 인자.
    /// `--section`·`--settings`와 같은 자리의 점검용 스위치다. 이 화면은 서버가 없으면
    /// 아무것도 그리지 않으므로, 손으로 눌러야만 볼 수 있는 상태가 남으면 확인할 방법이 없다.
    private static let opensPreviewOnLaunch = CommandLine.arguments.contains("--soarm-preview")
    private static let opensConsoleOnLaunch = CommandLine.arguments.contains("--soarm-console")
    private static let runsDoctorOnLaunch = CommandLine.arguments.contains("--soarm-diagnose")
    private var appliedLaunchOptions = false
    private var pollTask: Task<Void, Never>?
    private var saveTask: Task<Void, Never>?
    private var teardownTask: Task<Void, Never>?
    /// 진행 중인 연결 하나를 여럿이 함께 기다린다. 화면 두 개가 동시에 열리면 `connect()`도
    /// 두 번 불리는데, 그때 ssh를 두 번 띄우지 않고 같은 결과를 나눠 갖는다.
    private var connectTask: Task<Void, Never>?
    /// 이 연결을 필요로 하는 화면의 수. `SO-ARM 101`과 `수집 데이터`가 같은 터널을 쓰므로,
    /// 한 화면을 떠났다고 끊으면 다른 화면이 열려 있는데도 연결이 사라진다.
    private var visibleScreens = 0
    private var isScreenVisible: Bool { visibleScreens > 0 }

    /// `applicationWillTerminate`에서 닿기 위한 참조.
    ///
    /// `MattingDaemon.shared`·`MediaDaemon.shared`가 같은 자리에서 불리는 것과 같은 이유다.
    /// 종료 처리는 뷰 트리 밖에 있어서 `AutomationController`를 통해 내려올 길이 없다.
    /// 약한 참조라 이 모델의 주인은 여전히 컨트롤러 하나뿐이다.
    private(set) static weak var current: SOArmConsoleModel?

    init(store: SOArmServerStore = SOArmServerStore()) {
        self.store = store
        server = store.load()
        Self.current = self
    }

    var client: SOArmClient { SOArmClient(baseURL: server.baseURL) }
    var consoleURL: URL { server.baseURL }
    var mode: SOArmMode { status?.mode ?? .idle }
    var isModeRunning: Bool { mode != .idle }
    var settingsFileURL: URL { store.debugURL }

    /// 툴바의 작은 배지 한 줄. 정상일 때 화면 본문에는 상태를 그리지 않는다.
    var badge: (text: String, isAlarming: Bool) {
        switch connection {
        case .idle: ("연결 안 됨", false)
        case .connecting: ("연결 중", false)
        case .failed: ("연결 실패", true)
        case .connected:
            switch mode {
            // 툴바에 들어가는 말은 짧아야 자리를 지킨다. 무엇이 모자란지는 본문의 경고 줄이
            // 이미 한 줄씩 말하고 있으므로 여기서는 상태 이름만 쓴다.
            case .idle: (status?.teleopReady == true ? "준비됨" : "조건 미충족", status?.teleopReady != true)
            case .teleoperation: ("텔레옵", false)
            case .recording: ("수집 중", false)
            }
        }
    }

    /// 배지에 마우스를 올렸을 때. 마지막으로 서버에 닿은 시각이 여기 있으면 화면이 멈춘 것인지
    /// 서버가 멈춘 것인지 구별할 수 있다.
    var badgeHelp: String {
        guard let lastUpdated else { return "아직 서버에 닿지 않았습니다" }
        return "마지막 확인 \(lastUpdated.formatted(date: .omitted, time: .standard))"
    }

    /// 무엇이 막고 있는지. 막힌 것이 없으면 비어 있고, 화면은 그때 아무것도 그리지 않는다.
    var problems: [String] {
        if case .failed(let message) = connection { return [message] }
        guard let status else { return [] }
        var seen = Set<String>()
        return (status.teleopPreflight + status.recordPreflight).compactMap { line in
            let korean = SOArmPreflightText.korean(line)
            return seen.insert(korean).inserted ? korean : nil
        }
    }

    // MARK: 화면 수명

    func screenAppeared() {
        // 잠깐 다른 화면에 다녀온 것이라면 예약된 정리를 취소하고 쓰던 터널을 그대로 쓴다.
        teardownTask?.cancel()
        teardownTask = nil
        visibleScreens += 1
        Task { await connect() }
    }

    /// 화면을 떠난다고 무조건 끊지는 않는다. 팔이 움직이는 중이라면 개요 타일과 비상 중지가
    /// 계속 사실을 말해야 하므로 연결을 유지하고 폴링만 늦춘다.
    ///
    /// 아무것도 돌지 않을 때도 곧바로 끊지는 않는다. 사이드바를 한 칸 잘못 눌렀다가 돌아오는
    /// 일이 흔한데, 그때마다 ssh를 죽였다 다시 세우면 화면이 몇 초씩 비기 때문이다. 대신
    /// 30초 뒤에도 여전히 떠나 있으면 그때 끊는다 — 하루 종일 백그라운드에 ssh가 살아 있는
    /// 것은 이 앱이 피하려는 상태다.
    func screenDisappeared() {
        visibleScreens = max(0, visibleScreens - 1)
        guard !isScreenVisible else {
            restartPolling()
            return
        }
        stopPreviews()
        restartPolling()
        teardownTask?.cancel()
        teardownTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(30))
            guard !Task.isCancelled, let self, !self.isScreenVisible, !self.isModeRunning else { return }
            self.disconnect()
        }
    }

    // MARK: 연결

    func connect() async {
        if let connectTask {
            await connectTask.value
            return
        }
        let task = Task { await performConnect() }
        connectTask = task
        await task.value
        connectTask = nil
    }

    private func performConnect() async {
        guard !connection.isConnected else {
            restartPolling()
            return
        }
        guard server.isConfigured else {
            connection = .failed(SOArmError.notConfigured.localizedDescription)
            return
        }
        connection = .connecting
        do {
            try await SOArmTunnel.shared.ensureConnected(server: server)
            await refresh()
            applyLaunchOptions()
            restartPolling()
        } catch {
            connection = .failed(Self.message(for: error))
        }
    }

    func disconnect() {
        pollTask?.cancel()
        pollTask = nil
        stopPreviews()
        connection = .idle
        status = nil
        lastUpdated = nil
        // 종료를 기다리느라 화면이 멈추지 않게 메인 밖에서. 보통은 stdin을 닫는 즉시 끝난다.
        // 표를 들려 보내는 이유: 이 정리가 실제로 도는 시점에 이미 새 터널이 열려 있다면
        // 그것은 다른 터널이고, 건드리면 방금 연 연결을 끊는 꼴이 된다.
        let token = SOArmTunnel.shared.token
        Task.detached { SOArmTunnel.shared.shutdownNow(token: token) }
    }

    func refresh() async {
        guard server.isConfigured else {
            connection = .failed(SOArmError.notConfigured.localizedDescription)
            return
        }
        do {
            let value = try await client.status()
            status = value
            lastUpdated = Date()
            connection = .connected
        } catch {
            status = nil
            connection = .failed(Self.message(for: error))
        }
    }

    private func applyLaunchOptions() {
        guard !appliedLaunchOptions, connection.isConnected else { return }
        appliedLaunchOptions = true
        if Self.opensPreviewOnLaunch {
            SOArmCameraRole.allCases.forEach { startPreview($0) }
        }
        if Self.runsDoctorOnLaunch {
            runDoctor()
        }
        if Self.opensConsoleOnLaunch {
            enterConsoleFullScreen()
        }
    }

    private var shouldPoll: Bool {
        guard server.isConfigured else { return false }
        // 웹 콘솔이 떠 있는 동안에는 그쪽이 자기 폴링을 한다. 같은 것을 두 번 묻지 않는다.
        if isScreenVisible && !isConsoleFullScreen { return true }
        return isModeRunning
    }

    func restartPolling() {
        pollTask?.cancel()
        guard shouldPoll else {
            pollTask = nil
            return
        }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.shouldPoll else { return }
                await self.refresh()
                let seconds = self.isScreenVisible && !self.isConsoleFullScreen ? 2.0 : 5.0
                try? await Task.sleep(for: .seconds(seconds))
            }
        }
    }

    func enterConsoleFullScreen() {
        isConsoleFullScreen = true
        stopPreviews()
        restartPolling()
    }

    func leaveConsoleFullScreen() {
        isConsoleFullScreen = false
        restartPolling()
        Task { await refresh() }
    }

    // MARK: 동작

    /// 읽기 전용 진단. 모드가 도는 동안에는 서버가 거절하므로 버튼에만 붙어 있다.
    func runDoctor() {
        showsDiagnosis = true
        perform { client in _ = try await client.doctor() }
    }

    /// 진단을 아직 돌리지 않았어도 서버 상태만으로 알 수 있는 것들이 있다. 그 줄들은 그대로
    /// 답하고, 모터에 물어봐야 아는 줄은 `아직 물어보지 않았습니다`라고 말한다.
    var diagnosisChecks: [SOArmCheck] {
        SOArmDiagnosis.checks(server: server, status: status)
    }

    /// 확인 문구는 앱이 보낸다.
    ///
    /// 서버는 여전히 `START SOARM101`을 정확히 요구하고, 그 검사는 서버에 그대로 남아 있다.
    /// 달라진 것은 사람이 그 문구를 손으로 옮겨 적지 않는다는 것뿐이다 — 화면의 게이트는
    /// 시작 조건 표시와 현장 확인 안내, 그리고 시작 버튼을 한 번 누르는 것이다.
    func startTeleoperation() {
        // 두 팔의 관절을 넘기는 동안 카메라 프리뷰까지 물고 있을 이유가 없다.
        stopPreviews()
        perform { client in try await client.startTeleoperation(confirmation: SOArmClient.teleopConfirmation) }
    }

    func stopTeleoperation() {
        perform { client in try await client.stopTeleoperation() }
    }

    func startRecording() {
        let task = recordTask.trimmingCharacters(in: .whitespacesAndNewlines)
        let seconds = recordSeconds
        // 서버도 시작 직전에 카메라 worker를 내리지만, 우리 스트림을 먼저 놓아야 재연결이
        // 서버의 정리와 경쟁하지 않는다.
        stopPreviews()
        perform { client in
            try await client.startRecording(
                confirmation: SOArmClient.recordConfirmation,
                task: task, episodes: SOArmClient.openEndedEpisodes, episodeSeconds: seconds
            )
        }
    }

    func send(_ control: SOArmRecordControl) {
        perform { client in try await client.control(control) }
    }

    /// 도는 모드를 전부 내린다. 소프트웨어 중지이며 물리 E-stop이 아니다.
    func stopActiveMode() {
        perform { client in try await client.stopActiveMode() }
    }

    private func perform(_ body: @escaping @Sendable (SOArmClient) async throws -> Void) {
        guard !isBusy else { return }
        isBusy = true
        errorMessage = nil
        let client = client
        Task {
            do {
                try await body(client)
            } catch {
                errorMessage = Self.message(for: error)
            }
            isBusy = false
            await refresh()
        }
    }

    // MARK: 수집 데이터

    /// 수집 데이터 화면이 열렸다. 터널이 서기 전에 목록을 부르면 반드시 실패하므로 기다린다.
    func datasetsScreenAppeared() {
        screenAppeared()
        Task {
            await connect()
            loadDatasets()
        }
    }

    func loadDatasets() {
        guard !isLoadingDatasets else { return }
        isLoadingDatasets = true
        let client = client
        Task {
            do {
                let list = try await client.datasets()
                datasets = list
                // 앞선 실패가 남아 있으면 목록이 멀쩡히 떠 있는데 붉은 줄이 함께 보인다.
                errorMessage = nil
                // 고른 것이 사라졌거나 아직 없으면 첫 줄을 편다. 목록만 있고 아무것도 열려
                // 있지 않은 화면은 한 번 더 클릭을 요구할 뿐이다.
                if selectedDataset == nil || !list.contains(where: { $0.name == selectedDataset }) {
                    selectedDataset = list.first?.name
                }
            } catch {
                errorMessage = Self.message(for: error)
            }
            isLoadingDatasets = false
        }
    }

    private func loadDataset(_ name: String) {
        let client = client
        Task {
            do {
                let detail = try await client.dataset(name)
                guard selectedDataset == name else { return }
                datasetDetail = detail
                selectedEpisode = detail.episodes.first?.index
                if selectedCamera == nil || !detail.summary.cameras.contains(selectedCamera ?? "") {
                    selectedCamera = detail.summary.cameras.first
                }
            } catch {
                errorMessage = Self.message(for: error)
            }
        }
    }

    var currentEpisode: SOArmEpisode? {
        guard let selectedEpisode else { return nil }
        return datasetDetail?.episodes.first { $0.index == selectedEpisode }
    }

    /// 지금 고른 에피소드·카메라의 재생 주소. 구간은 주소에 들어 있고 서버가 잘라서 준다.
    var currentPlaybackURL: URL? {
        guard let camera = selectedCamera,
              let video = currentEpisode?.videos[camera],
              !video.path.isEmpty else { return nil }
        return client.videoURL(video.path)
    }

    // MARK: 카메라

    func startPreview(_ role: SOArmCameraRole) {
        stream(role).start(client.cameraURL(role.rawValue))
    }

    /// 서버가 이 역할에 대해 말하고 있는 것. 아직 상태를 못 읽었으면 빈 값이다.
    func camera(_ role: SOArmCameraRole) -> SOArmCamera {
        guard let status else { return SOArmCamera() }
        return role == .scene ? status.sceneCamera : status.wristCamera
    }

    /// 프리뷰 화질·프레임을 바꾼다.
    ///
    /// 화면 값을 먼저 바꿔 놓지 않는다. 서버가 못 하는 조합은 거절하고, 받아 준 값도
    /// 드라이버가 그대로 열어 준다는 보장이 없다 — 다음 상태 갱신에 실제로 열린 값이
    /// 실려 오므로, 화면은 그때 따라간다. 수집 중에는 서버가 409로 막고 그 말이 그대로 뜬다.
    func setCameraProfile(_ profile: SOArmCameraProfile, for role: SOArmCameraRole) {
        let name = role.rawValue
        perform { client in try await client.setCameraProfile(name, profile) }
    }

    func stopPreview(_ role: SOArmCameraRole) {
        stream(role).stop()
        // 클라이언트가 사라지면 서버가 알아서 놓지만, 명시적으로 한 번 더 말해 준다.
        let client = client
        let name = role.rawValue
        Task { try? await client.stopCamera(name) }
    }

    /// 앱이 끝날 때 서버가 우리 때문에 쥐고 있는 것을 돌려준다.
    ///
    /// 프리뷰는 이 앱이 가져간 자원이므로 이 앱이 놓아야 한다. 그냥 종료하면 터널이 끊기고
    /// 서버는 half-open 소켓이 시간 초과될 때까지 카메라 worker를 계속 물고 있는데, 그 사이에
    /// 수집을 시작하면 `record.sh`의 `fuser` 검사가 카메라가 이미 쓰이는 중이라며 거절한다.
    ///
    /// 텔레옵과 수집은 **건드리지 않는다.** 하드웨어의 주인은 서버이고 이 앱은 원격 조작면일
    /// 뿐이라, 창을 닫았다는 이유로 움직이는 팔을 멈추는 것은 이 앱이 내릴 결정이 아니다.
    /// 웹 콘솔의 탭을 닫았을 때와 같아야 한다.
    ///
    /// `applicationWillTerminate`에서 불리므로 동기다. 각 요청에 짧은 상한을 두어 종료가
    /// 네트워크 때문에 늘어지지 않게 한다.
    func releaseHeldCamerasNow() {
        let running = SOArmCameraRole.allCases.filter { stream($0).isRunning }
        guard !running.isEmpty else { return }
        running.forEach { stream($0).stop() }
        let base = server.baseURL
        for role in running {
            var request = URLRequest(url: base.appending(path: "api/cameras/\(role.rawValue)/stop"))
            request.httpMethod = "POST"
            request.timeoutInterval = 1.5
            let done = DispatchSemaphore(value: 0)
            URLSession.shared.dataTask(with: request) { _, _, _ in done.signal() }.resume()
            _ = done.wait(timeout: .now() + 2)
        }
    }

    func stopPreviews() {
        for role in SOArmCameraRole.allCases where stream(role).isRunning {
            stopPreview(role)
        }
    }

    func stream(_ role: SOArmCameraRole) -> MJPEGStream {
        role == .scene ? sceneCamera : wristCamera
    }

    // MARK: 설정 저장

    private func scheduleSave() {
        saveTask?.cancel()
        let store = store
        let server = server
        saveTask = Task {
            // 타이핑 한 글자마다 파일을 쓰지 않는다.
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            try? store.save(server)
        }
    }

    func saveServerNow() {
        saveTask?.cancel()
        try? store.save(server)
    }

    static func message(for error: Error) -> String {
        (error as? SOArmError)?.errorDescription ?? error.localizedDescription
    }
}

enum SOArmCameraRole: String, CaseIterable, Identifiable, Sendable {
    case scene, wrist

    var id: String { rawValue }
    var title: String { self == .scene ? "작업공간" : "손목" }
    var subtitle: String { self == .scene ? "SCENE" : "WRIST" }
}

/// `--soarm-check` — 터미널에서 로봇 콘솔까지 실제로 한 번 닿아 본다.
///
/// `--connection-check`와 같은 이유로 있다. 창을 띄우지 않고 답을 보고 싶을 때, 그리고 앱이
/// 열리지 않을 때 어디까지 갔는지 알고 싶을 때다. 고정 문자열을 찍지 않고 매번 실제로
/// 터널을 세우고, 상태를 읽고, 카메라 프레임을 한 장 받아 본 뒤, 남은 프로세스가 없는지까지
/// 확인한다.
@MainActor
enum SOArmConnectionCheck {
    static func run() async -> Bool {
        let server = SOArmServerStore().load()
        guard server.isConfigured else {
            print("❌ 서버가 설정되어 있지 않습니다. 설정 › 로봇에서 주소와 계정을 넣으세요.")
            print("   설정 파일: \(SOArmServerStore().debugURL.path)")
            return false
        }
        print("• 대상 \(server.sshTarget) · 콘솔 \(server.baseURL.absoluteString) → 서버 \(server.remotePort)")

        do {
            try await SOArmTunnel.shared.ensureConnected(server: server)
            print(SOArmTunnel.shared.isRunning ? "✅ SSH 터널을 열었습니다" : "✅ 콘솔이 이미 이 포트에서 응답합니다 (터널을 새로 열지 않았습니다)")
        } catch {
            print("❌ \(SOArmConsoleModel.message(for: error))")
            return false
        }
        defer { SOArmTunnel.shared.shutdownNow() }

        let client = SOArmClient(baseURL: server.baseURL)
        let status: SOArmStatus
        do {
            status = try await client.status()
        } catch {
            print("❌ \(SOArmConsoleModel.message(for: error))")
            return false
        }
        print("✅ 상태를 읽었습니다 · LeRobot \(status.lerobotVersion ?? "?") · 현재 \(status.mode.badge)")
        print("   motion gate \(status.motionEnabled ? "열림" : "닫힘") · 캘리브레이션 리더 \(status.leaderCalibrated ? "있음" : "없음") / 팔로워 \(status.followerCalibrated ? "있음" : "없음")")
        if status.teleopPreflight.isEmpty {
            print("✅ 텔레옵 시작 조건을 모두 통과했습니다")
        } else {
            status.teleopPreflight.forEach { print("⚠️  \(SOArmPreflightText.korean($0))") }
        }
        if !status.recordPreflight.isEmpty {
            status.recordPreflight
                .filter { !status.teleopPreflight.contains($0) }
                .forEach { print("⚠️  수집: \(SOArmPreflightText.korean($0))") }
        }

        var ok = true
        for role in SOArmCameraRole.allCases {
            let stream = MJPEGStream()
            stream.start(client.cameraURL(role.rawValue))
            var size: NSSize?
            for _ in 0..<40 {
                if let image = stream.image { size = image.size; break }
                if let failure = stream.failure {
                    print("⚠️  \(role.title) 카메라: \(failure)")
                    break
                }
                try? await Task.sleep(for: .milliseconds(250))
            }
            if let size {
                print("✅ \(role.title) 카메라 프레임 \(Int(size.width))×\(Int(size.height))")
            } else if stream.failure == nil {
                print("⚠️  \(role.title) 카메라에서 10초 안에 프레임이 오지 않았습니다")
                ok = false
            }
            stream.stop()
            try? await client.stopCamera(role.rawValue)
        }

        SOArmTunnel.shared.shutdownNow()
        let tunnels = tunnelProcesses()
        let leftovers = tunnels.filter { $0.isOrphan }
        if leftovers.isEmpty {
            print("✅ 남은 ssh 터널 없음")
            let held = tunnels.filter { !$0.isOrphan }
            if !held.isEmpty {
                let pids = held.map { String($0.parent) }.joined(separator: ", ")
                print("   (실행 중인 앱 \(pids)이(가) 쥔 터널 \(held.count)개는 그 앱과 함께 닫힙니다)")
            }
        } else {
            print("❌ 터널이 남았습니다: \(leftovers.map(\.command).joined(separator: ", "))")
            ok = false
        }
        return ok
    }

    /// 마커를 달고 있는 ssh 프로세스가 이 기기에 남아 있는가.
    ///
    /// 마커만 세면 안 된다. 이 점검이 도는 동안 GUI 앱이 떠 있으면 그 앱이 쥔 터널까지
    /// 남은 것으로 세어 매번 ❌가 나오는데, 그 터널에는 살아 있는 주인이 있다. 확인하려던
    /// 것은 주인을 잃은 터널이므로, 이 프로세스가 띄운 것과 부모가 사라진 것(`launchd`가
    /// 거둬 간 것)만 남은 것으로 본다.
    static func leftoverTunnels() -> [String] {
        tunnelProcesses().filter { $0.isOrphan }.map(\.command)
    }

    struct TunnelProcess: Sendable {
        let pid: Int32
        let parent: Int32
        let command: String

        /// 이 점검이 띄운 터널은 `shutdownNow()` 뒤에 없어야 하고, 부모가 `launchd`로
        /// 바뀐 터널은 띄운 앱이 이미 죽었다는 뜻이다. 둘 다 주인이 없다.
        var isOrphan: Bool { parent == 1 || parent == ProcessInfo.processInfo.processIdentifier }
    }

    static func tunnelProcesses() -> [TunnelProcess] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-Ao", "pid=,ppid=,command="]
        let pipe = Pipe()
        process.standardOutput = pipe
        guard (try? process.run()) != nil else { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
            .split(separator: "\n")
            .filter { $0.contains(SOArmTunnel.marker) && !$0.contains("ps -Ao") }
            .compactMap { TunnelProcess($0) }
    }
}

extension SOArmConnectionCheck.TunnelProcess {
    /// `ps -Ao pid=,ppid=,command=` 한 줄. 앞의 두 칸이 숫자가 아니면 우리가 아는 줄이 아니다.
    init?(_ line: Substring) {
        let fields = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard fields.count == 3, let pid = Int32(fields[0]), let parent = Int32(fields[1]) else { return nil }
        self.init(pid: pid, parent: parent, command: fields[2].trimmingCharacters(in: .whitespaces))
    }
}
