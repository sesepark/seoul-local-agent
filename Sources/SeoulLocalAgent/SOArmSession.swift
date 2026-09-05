import Foundation
import AppKit
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
    /// 마지막 진단 결과. 버리지 않고 들고 있는 이유는, 어느 팔이 토크를 쥐고 있는지가
    /// 화면이 `토크 해제` 버튼을 보여 줄지 말지를 정하기 때문이다.
    @Published private(set) var doctor: SOArmDoctor?

    // 수집 조건. 시트를 닫아도 남아 있어야 해서 화면이 아니라 여기에 둔다.
    @Published var recordTask = ""
    /// 한 에피소드가 저절로 끊기는 상한. 사람이 `지금 저장`·`다시 찍기`를 누르면 그 전에 끝난다.
    @Published var recordSeconds = 30
    /// 같은 과제의 데이터셋이 이미 있으면 거기에 회를 이어 붙일 것인가. 기본은 참이다.
    ///
    /// 학습은 데이터셋 하나만 받는다. 같은 과제를 세션마다 새 폴더에 찍으면 화면에서는 한
    /// 묶음으로 보여도 학습에는 그중 하나만 들어간다. 과제 하나가 데이터셋 하나여야 그 묶음이
    /// 곧 학습 단위가 된다.
    @Published var resumeExisting = true
    /// 수집 중 카메라 스냅숏. LeRobot이 카메라를 쥐고 있어 MJPEG 프리뷰는 열리지 않으므로
    /// 기록 루프가 남기는 JPEG를 몇 Hz로 받아 온다. 서버가 `preview`를 할 수 있을 때만.
    @Published private(set) var recordingSnapshots: [SOArmCameraRole: NSImage] = [:]
    /// 이 앱이 켜져 있는 동안 마지막으로 끝난 수집. 끝난 뒤 요약 카드가 이것을 그린다 —
    /// 전에는 끝나는 순간 처음 화면으로 돌아가 몇 회를 찍었는지도 알 수 없었다.
    @Published private(set) var lastRun: SOArmRecordingRuntime?
    /// 지금 서버로 가고 있는 수집 조작의 수. 버튼을 잠그지 않는다 — ⌘⏎ 직후의 ⇧⌘R이
    /// 조용히 버려지던 자리다. 순서대로 보내고, 도는 동안이라는 표시만 한다.
    @Published private(set) var pendingControls = 0
    /// 고른 회의 관절 궤적.
    @Published private(set) var trajectory: SOArmTrajectory?
    @Published private(set) var isLoadingTrajectory = false
    /// 학습에 쓸 정책. 숫자(스텝·배치)는 서버가 정한다.
    @Published var trainingPolicy: SOArmTrainingPolicy = .act
    @Published private(set) var startingTraining: String?
    @Published private(set) var stoppingTraining: String?
    @Published private(set) var deletingDataset: String?
    @Published private(set) var deletingEpisode: Int?
    /// 재생 전에 서버가 재 준 관절별 거리와 정렬 시간.
    @Published private(set) var replayPreview: SOArmReplayPreview?
    @Published private(set) var isLoadingReplayPreview = false
    private var snapshotTask: Task<Void, Never>?
    private var sparkPollTask: Task<Void, Never>?
    private var controlChain: Task<Void, Never>?

    let sceneCamera = MJPEGStream()
    let wristCamera = MJPEGStream()
    /// 영상을 얼마나 받을지. 원격 텔레옵 화면과 같은 값이다.
    let cameraPolicy = SOArmCameraPolicy.shared
    private var cameraPolicyWatch: AnyCancellable?

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
    @Published var selectedEpisode: Int? {
        didSet {
            guard selectedEpisode != oldValue else { return }
            loadTrajectory()
        }
    }
    @Published var selectedCamera: String?
    /// 데이터셋 이름 → 그 세션의 과제 문장.
    ///
    /// 목록 API(`/api/datasets`)는 과제를 싣지 않고 상세에만 들어 있어서, 목록을 읽은 뒤
    /// 모르는 것만 한 번씩 더 물어 채운다. 세션 이름은 타임스탬프라 무엇을 찍은 것인지
    /// 말해 주지 않는다 — 화면이 과제로 묶으려면 이 표가 있어야 한다.
    @Published private(set) var datasetTasks: [String: String] = [:]

    // 학습 서버(Spark)
    @Published private(set) var sparkStatus: SOArmSparkStatus?
    /// 학습 서버에 이미 올라가 있는 데이터셋 이름. 목록의 각 줄이 보낸 것인지 아닌지를
    /// 여기로 판단한다.
    @Published private(set) var sparkDatasets: [SOArmSparkDataset] = []
    @Published private(set) var sparkRuns: [SOArmSparkRun] = []
    /// 지금 보내고 있는 데이터셋 이름. 전송은 몇 분이 걸릴 수 있어 어느 줄이 도는 중인지
    /// 화면이 알아야 한다.
    @Published private(set) var pushingDataset: String?
    /// 회수 중인 체크포인트. `run/step` 한 줄로 둔다.
    @Published private(set) var pullingCheckpoint: String?
    @Published private(set) var isLoadingSpark = false

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
        // 영상 받기를 끄면 이 화면의 프리뷰도 함께 내려간다. 한 화면에서 껐는데 다른
        // 화면이 계속 받고 있으면 그것은 끈 것이 아니다.
        cameraPolicyWatch = cameraPolicy.$mode
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] mode in self?.cameraPolicyChanged(to: mode) }
    }

    /// 데이터 정책이 바뀌었다. 끄면 프리뷰를 내리고, 켜면 고른 값을 서버에 건다.
    ///
    /// 켤 때 프리뷰를 자동으로 다시 열지는 **않는다.** 이 화면의 프리뷰는 원래 눌러야
    /// 열리는 것이고, 데이터 설정을 만졌다는 이유로 카메라를 점유하기 시작하면 그것은
    /// 고른 적 없는 일이 벌어지는 것이다.
    private func cameraPolicyChanged(to mode: SOArmCameraDataMode) {
        // 수집 중 스냅숏도 받는 양을 따른다. 간격이 바뀌므로 도는 것을 세우고 다시 판단한다.
        snapshotTask?.cancel()
        snapshotTask = nil
        updateSnapshotPolling()
        guard let profile = mode.profile else {
            stopPreviews()
            return
        }
        for role in SOArmCameraRole.allCases {
            setCameraProfile(profile, for: role)
        }
    }

    var client: SOArmClient { SOArmClient(baseURL: server.baseURL, motionToken: server.motionToken) }
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
        updateSnapshotPolling()
        sparkPollTask?.cancel()
        sparkPollTask = nil
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
        updateSnapshotPolling()
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
            let wasRecording = status?.recording.running ?? false
            status = value
            lastUpdated = Date()
            connection = .connected
            // 수집이 방금 끝났다. 끝난 회차의 상태를 요약 카드용으로 붙잡아 두고, 목록을 다시
            // 읽어 새 데이터셋(또는 회가 늘어난 데이터셋)이 곧바로 보이게 한다.
            if wasRecording, !value.recording.running, let runtime = value.recordingRuntime, runtime.isFinished {
                lastRun = runtime
                loadDatasets()
            }
            updateSnapshotPolling()
        } catch {
            status = nil
            connection = .failed(Self.message(for: error))
            updateSnapshotPolling()
        }
    }

    /// 요약 카드를 닫는다.
    func dismissLastRun() { lastRun = nil }

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
                try? await Task.sleep(for: .seconds(self.pollInterval))
            }
        }
    }

    /// 다음 상태를 얼마 만에 다시 물을 것인가.
    ///
    /// **수집 중에는 빠르게 묻는다.** 회가 시작한 시각은 서버만 알고 있고, 앱은 그것을 다음
    /// 폴링에서야 배운다. 2초에 한 번 물으면 회가 시작하고 최대 2초가 지나서야 시계가 나타나
    /// 처음 1~2초를 건너뛴 것처럼 보인다 — 그동안 화면에는 지난 단계의 회전자만 돈다.
    /// 상태 응답은 작고 서버가 10ms 안에 답하므로, 찍는 동안에는 0.4초가 낫다.
    private var pollInterval: TimeInterval {
        guard isScreenVisible, !isConsoleFullScreen else { return 5.0 }
        if status?.recording.running == true { return 0.4 }
        return 2.0
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
        guard !isBusy else { return }
        isBusy = true
        errorMessage = nil
        let client = client
        Task {
            do {
                doctor = try await client.doctor()
            } catch {
                errorMessage = Self.message(for: error)
            }
            isBusy = false
            await refresh()
        }
    }

    /// 토크가 걸린 채로 남아 있는 팔들.
    ///
    /// 진단을 돌리기 전에는 알 수 없다. 서버 상태(`/api/status`)에는 모터 레지스터가 없고,
    /// 그것을 읽으려면 serial을 여는 진단이 필요하다.
    var armsHoldingTorque: [String] {
        (doctor?.arms ?? []).filter { $0.healthy && !$0.torqueDisabled }.map(\.role)
    }

    /// 한 팔의 토크를 푼다. 푼 뒤 진단을 다시 돌려 실제로 꺼졌는지 확인한다 —
    /// 껐다고 말하는 것과 꺼진 것을 보는 것은 다르다.
    func releaseTorque(arm: String) {
        perform { client in try await client.releaseTorque(arm: arm) }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(600))
            runDoctor()
        }
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
        let resume = resumeTarget?.name
        lastRun = nil
        // 서버도 시작 직전에 카메라 worker를 내리지만, 우리 스트림을 먼저 놓아야 재연결이
        // 서버의 정리와 경쟁하지 않는다.
        stopPreviews()
        perform { client in
            try await client.startRecording(
                confirmation: SOArmClient.recordConfirmation,
                task: task, episodes: SOArmClient.openEndedEpisodes, episodeSeconds: seconds,
                resumeDataset: resume
            )
        }
    }

    /// 지금 과제 문장과 글자까지 같은 과제로 찍힌 데이터셋 가운데 가장 최근 것.
    ///
    /// 서버가 이어 찍기를 할 수 있고 사람이 그것을 켜 두었을 때만 값이 있다. 과제가 여럿
    /// 섞인 데이터셋은 후보가 아니다 — 거기에 이어 붙이면 어느 과제의 회인지 흐려진다.
    var resumableDataset: SOArmDatasetSummary? {
        guard status?.can(.resume) == true else { return nil }
        let task = recordTask.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !task.isEmpty else { return nil }
        return SOArmDatasetSummary.newest(in: datasets.filter { taskOf($0) == task && isResumeCompatible($0) })
    }

    /// 같은 과제인데 이어 붙일 수 없는 데이터셋. 화면이 왜 새로 만드는지 말할 때 쓴다.
    var incompatibleSameTaskDataset: SOArmDatasetSummary? {
        guard status?.can(.resume) == true else { return nil }
        let task = recordTask.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !task.isEmpty else { return nil }
        return SOArmDatasetSummary.newest(in: datasets.filter { taskOf($0) == task && !isResumeCompatible($0) })
    }

    /// 서버가 센서 열을 함께 저장하는데 데이터셋에 그 열이 없으면 LeRobot의 호환 검사가 막는다.
    /// 서버도 400으로 거절하지만, 거절을 받고 나서 아는 것보다 화면이 미리 새 데이터셋으로
    /// 가는 편이 낫다.
    func isResumeCompatible(_ dataset: SOArmDatasetSummary) -> Bool {
        guard status?.can(.sensorExtras) == true else { return true }
        return !dataset.extras.isEmpty
    }

    /// 실제로 이어 붙일 곳. 사람이 `새 데이터셋`을 골랐으면 없다.
    var resumeTarget: SOArmDatasetSummary? { resumeExisting ? resumableDataset : nil }

    /// 데이터셋 하나의 과제. 목록이 실어 준 것이 먼저고, 없으면 상세에서 읽어 둔 것.
    func taskOf(_ dataset: SOArmDatasetSummary) -> String? {
        if let task = dataset.singleTask { return task }
        guard let task = datasetTasks[dataset.name], task != Self.mixedTasks else { return nil }
        return task
    }

    /// `끝내기`가 실제로 보내는 것.
    ///
    /// 찍는 중이면 그 회를 **버리고** 끝낸다(`abort`) — 찍다 만 시연은 정책에게 과제 중간에
    /// 멈추는 것을 가르친다. 회 사이(reset·saving)에는 앞 회가 이미 완성이라 `esc`로 저장하고
    /// 끝낸다. 서버가 `abort`를 모르면 `esc`밖에 없고, 그때는 화면이 그렇게 말한다.
    var stopControl: SOArmRecordControl {
        if status?.recordingRuntime?.isRecordingEpisode == true, status?.can(.abort) == true { return .abort }
        return .stop
    }

    /// 사람이 고른 재생 속도. 기본은 절반이다 — 처음 보는 재생은 느린 편이 낫다.
    /// 서버도 같은 기본값을 갖고 있고, 이 값은 화면에서 고른 것을 기억해 둘 뿐이다.
    @Published var replaySpeed: Double = 0.5

    /// 찍은 에피소드를 팔에 다시 흘린다. **팔이 실제로 움직인다.**
    func startReplay(dataset: String, episode: Int) {
        let speed = replaySpeed
        perform { client in
            try await client.startReplay(
                confirmation: SOArmClient.replayConfirmation,
                dataset: dataset, episode: episode, speed: speed
            )
        }
    }

    /// 재생을 그 자리에서 멈춘다. 토크는 걸어 둔 채다 — 멈추는 것과 힘을 놓는 것은
    /// 다른 일이고, 팔이 든 것을 떨어뜨리면 안 된다.
    func stopReplay() {
        perform { client in try await client.stopReplay() }
    }

    /// 수집 조작 하나를 보낸다. **버튼을 잠그지 않는다.**
    ///
    /// 전에는 다른 요청과 같은 `isBusy`를 썼고, 요청 뒤 상태를 한 번 다시 읽는 동안 버튼이
    /// 잠겼다. 그 반 초 사이에 누른 ⇧⌘R은 아무 말 없이 버려졌다. 시연을 끝낸 손은 빠르게
    /// 두 번 누른다. 그래서 순서대로 줄을 세워 보내고, 화면에는 가고 있다는 표시만 한다.
    func send(_ control: SOArmRecordControl) {
        let client = client
        let previous = controlChain
        pendingControls += 1
        controlChain = Task { [weak self] in
            await previous?.value
            var failure: String?
            do {
                try await client.control(control)
            } catch {
                failure = Self.message(for: error)
            }
            guard let self else { return }
            self.pendingControls = max(0, self.pendingControls - 1)
            if let failure { self.errorMessage = failure }
            await self.refresh()
        }
    }

    /// 지금 회를 끝내는 단추. 찍는 중이면 버리고, 회 사이면 저장하고 끝낸다(`stopControl`).
    func stopRecording() { send(stopControl) }

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
    /// 수집 화면이 열렸다. 데이터셋 목록까지 읽는 이유는 하나뿐이다 — 과제 문장
    /// 드롭다운이 그 목록에서 나온다. 목록 자체는 이 화면에 그리지 않는다.
    func recordScreenAppeared() {
        screenAppeared()
        Task {
            await connect()
            loadDatasets()
        }
    }

    func datasetsScreenAppeared() {
        screenAppeared()
        Task {
            await connect()
            loadDatasets()
            loadSpark()
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
                // 목록이 과제를 실어 줬으면 그대로 받아 둔다. 상세를 하나씩 묻는 것은 그것이
                // 없는 옛 서버에서만 한다.
                for dataset in list where !dataset.tasks.isEmpty {
                    datasetTasks[dataset.name] = dataset.tasks.count == 1 ? dataset.tasks[0] : Self.mixedTasks
                }
                loadTasks(for: list)
                // 앞선 실패가 남아 있으면 목록이 멀쩡히 떠 있는데 붉은 줄이 함께 보인다.
                errorMessage = nil
                // 고른 것이 사라졌거나 아직 없으면 **가장 최근** 것을 편다. 목록만 있고 아무것도
                // 열려 있지 않은 화면은 한 번 더 클릭을 요구할 뿐이고, 가장 오래된 것이 열리는
                // 화면은 방금 찍은 것을 보러 온 사람에게 매번 다시 고르게 한다.
                if selectedDataset == nil || !list.contains(where: { $0.name == selectedDataset }) {
                    selectedDataset = SOArmDatasetSummary.newest(in: list)?.name
                }
            } catch {
                errorMessage = Self.message(for: error)
            }
            isLoadingDatasets = false
        }
    }

    /// 과제가 여럿 섞인 데이터셋의 표식.
    static let mixedTasks = "여러 과제"

    /// 과제 문장을 모르는 데이터셋만 골라 한 번씩 더 물어 온다.
    ///
    /// 한 번 안 것은 다시 묻지 않는다. 데이터셋은 다시 찍히지 않는 한 과제가 바뀌지
    /// 않으므로, 새로고침마다 전부 다시 물으면 터널 너머로 같은 답을 반복해 받게 된다.
    private func loadTasks(for list: [SOArmDatasetSummary]) {
        let missing = list.filter { $0.tasks.isEmpty && datasetTasks[$0.name] == nil }.map(\.name)
        guard !missing.isEmpty else { return }
        let client = client
        Task {
            for name in missing {
                guard let detail = try? await client.dataset(name) else { continue }
                // 한 세션은 과제 하나로 찍는다(`single_task`). 그래도 첫 회의 것을
                // 집는 대신 실제로 나온 문장을 세어, 나중에 여러 과제가 한 데이터셋에
                // 들어오더라도 화면이 틀리지 않게 한다.
                let tasks = detail.episodes.compactMap { $0.task.isEmpty ? nil : $0.task }
                if let first = tasks.first {
                    datasetTasks[name] = Set(tasks).count == 1 ? first : Self.mixedTasks
                }
            }
        }
    }

    /// 지금까지 쓴 과제 문장들. `데이터 수집` 화면의 드롭다운이 이것을 보여 준다.
    ///
    /// 과제 문장은 데이터셋을 묶는 열쇠인데 매번 손으로 치면 `빨간 블록 집기`와
    /// `빨간 블록을 집는다`가 서로 다른 묶음이 된다. 고를 수 있게 해 두는 것이
    /// 문자열을 같게 유지하는 유일한 길이다.
    var knownTasks: [String] {
        Array(Set(datasetTasks.values)).filter { $0 != Self.mixedTasks }.sorted()
    }

    /// 고른 회의 관절 궤적을 읽는다. 서버가 없는 회(404)나 옛 서버(경로 없음)면 조용히 비운다.
    private func loadTrajectory() {
        trajectory = nil
        isLoadingTrajectory = false
        guard let dataset = selectedDataset, let episode = selectedEpisode else { return }
        isLoadingTrajectory = true
        let client = client
        Task {
            let value = try? await client.trajectory(dataset, episode: episode)
            guard selectedDataset == dataset, selectedEpisode == episode else { return }
            trajectory = value
            isLoadingTrajectory = false
        }
    }

    // MARK: 지우기

    /// 데이터셋 하나를 지운다. 서버는 `data/.trash`로 옮기므로 되돌릴 수 있다.
    func deleteDataset(_ name: String) {
        guard deletingDataset == nil else { return }
        deletingDataset = name
        let client = client
        Task {
            do {
                try await client.deleteDataset(name)
                errorMessage = nil
                datasetTasks[name] = nil
                if selectedDataset == name { selectedDataset = nil }
            } catch {
                errorMessage = Self.message(for: error)
            }
            deletingDataset = nil
            loadDatasets()
        }
    }

    /// 고른 데이터셋에서 한 회를 지운다. 영상을 다시 굽는 일이라 데이터셋이 크면 몇 분이 걸린다.
    func deleteEpisode(_ index: Int) {
        guard deletingEpisode == nil, let name = selectedDataset else { return }
        deletingEpisode = index
        let client = client
        Task {
            do {
                try await client.deleteEpisode(name, index: index)
                errorMessage = nil
                // 회 번호가 당겨지므로 상세를 다시 읽는다. 과제 표도 다시 채운다.
                datasetTasks[name] = nil
                if selectedDataset == name { loadDataset(name) }
            } catch {
                errorMessage = Self.message(for: error)
            }
            deletingEpisode = nil
            loadDatasets()
        }
    }

    // MARK: 학습

    /// 학습을 시작한다. 콘솔 서버가 학습 서버의 tmux에 띄우고 곧 돌아온다.
    func startTraining(_ dataset: String) {
        guard startingTraining == nil else { return }
        startingTraining = dataset
        let client = client
        let policy = trainingPolicy
        Task {
            do {
                _ = try await client.startTraining(dataset: dataset, policy: policy)
                errorMessage = nil
            } catch {
                errorMessage = Self.message(for: error)
            }
            startingTraining = nil
            loadSpark()
        }
    }

    func stopTraining(_ run: String) {
        guard stoppingTraining == nil else { return }
        stoppingTraining = run
        let client = client
        Task {
            do {
                try await client.stopTraining(run: run)
                errorMessage = nil
            } catch {
                errorMessage = Self.message(for: error)
            }
            stoppingTraining = nil
            loadSpark()
        }
    }

    var isAnyTraining: Bool { sparkRuns.contains { $0.isTraining } }

    /// 학습이 돌고 있으면 몇 초마다 진행을 다시 읽는다. 화면이 열려 있을 때만.
    private func scheduleSparkPolling() {
        sparkPollTask?.cancel()
        sparkPollTask = nil
        guard isScreenVisible, isAnyTraining else { return }
        sparkPollTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled, let self, self.isScreenVisible else { return }
            self.loadSpark()
        }
    }

    // MARK: 재생 미리보기

    /// 재생 확인 시트가 열릴 때, 팔이 지금 자리에서 첫 자세까지 얼마나 가야 하는지 서버에 묻는다.
    func loadReplayPreview() {
        replayPreview = nil
        guard status?.can(.replayPreview) == true, let dataset = selectedDataset, let episode = selectedEpisode else { return }
        isLoadingReplayPreview = true
        let client = client
        Task {
            let value = try? await client.replayPreview(dataset: dataset, episode: episode)
            guard selectedDataset == dataset, selectedEpisode == episode else { return }
            replayPreview = value
            isLoadingReplayPreview = false
        }
    }

    // MARK: 수집 중 스냅숏

    /// 수집이 돌고, 서버가 스냅숏을 내주고, 화면이 보이고, 영상 받기를 끄지 않았을 때만 돈다.
    ///
    /// 받는 양은 `영상 받기`를 따른다. 스냅숏도 바이트다 — `절약`이면 초당 한 장, `보통`이면
    /// 세 장, `최고`면 다섯 장. `끔`이면 받지 않는다.
    private func updateSnapshotPolling() {
        let wants = isScreenVisible
            && (status?.recording.running ?? false)
            && (status?.can(.preview) ?? false)
            && !cameraPolicy.isOff
        if wants {
            guard snapshotTask == nil else { return }
            let interval: Duration = switch cameraPolicy.mode {
            case .saver: .milliseconds(1000)
            case .medium: .milliseconds(330)
            default: .milliseconds(200)
            }
            snapshotTask = Task { [weak self] in
                let configuration = URLSessionConfiguration.ephemeral
                configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
                configuration.timeoutIntervalForRequest = 2
                configuration.waitsForConnectivity = false
                let session = URLSession(configuration: configuration)
                defer { session.finishTasksAndInvalidate() }
                while !Task.isCancelled {
                    guard let self else { return }
                    let client = self.client
                    // 두 카메라를 모은 뒤 **한 번에** 넣는다. 역할마다 넣으면 그때마다 화면
                    // 전체가 다시 그려지고, 초당 열 번 다시 그려지는 화면에서는 0.25초짜리
                    // 타이머가 발화할 틈이 없다 — 실제로 그것이 회 시계를 얼렸다.
                    var frames: [SOArmCameraRole: NSImage] = [:]
                    for role in SOArmCameraRole.allCases {
                        var request = URLRequest(url: client.recordingPreviewURL(role))
                        request.cachePolicy = .reloadIgnoringLocalCacheData
                        request.timeoutInterval = 2
                        guard let (data, response) = try? await session.data(for: request),
                              (response as? HTTPURLResponse)?.statusCode == 200,
                              let image = NSImage(data: data) else { continue }
                        frames[role] = image
                    }
                    if !frames.isEmpty { self.recordingSnapshots = frames }
                    try? await Task.sleep(for: interval)
                }
            }
        } else if snapshotTask != nil || !recordingSnapshots.isEmpty {
            snapshotTask?.cancel()
            snapshotTask = nil
            recordingSnapshots = [:]
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

    // MARK: 학습 서버(Spark)

    /// 학습 서버의 형편과 그쪽에 있는 것들을 한 번에 읽는다.
    ///
    /// 실패해도 `errorMessage`를 세우지 않는다. 학습 서버가 꺼져 있는 것은 수집 데이터
    /// 화면이 하려는 일(녹화한 것을 보는 것)을 막지 않으므로, 붉은 줄로 화면을 덮는 대신
    /// 학습 서버 칸에만 그 사실을 적는다.
    func loadSpark() {
        guard !isLoadingSpark else { return }
        isLoadingSpark = true
        let client = client
        Task {
            let status = (try? await client.sparkStatus()) ?? SOArmSparkStatus()
            sparkStatus = status
            if status.isReachable {
                sparkDatasets = (try? await client.sparkDatasets()) ?? []
                sparkRuns = (try? await client.sparkRuns()) ?? []
            } else {
                sparkDatasets = []
                sparkRuns = []
            }
            isLoadingSpark = false
            scheduleSparkPolling()
        }
    }

    /// 이 데이터셋이 학습 서버에 이미 있는가.
    func isOnSpark(_ name: String) -> Bool {
        sparkDatasets.contains { $0.name == name }
    }

    /// 데이터셋 하나를 학습 서버로 보낸다.
    ///
    /// 진행률은 없다. 서버가 rsync를 끝내고 한 번에 답하므로 보여 줄 숫자가 없고, 지어낸
    /// 막대는 멈춘 전송을 정상으로 보이게 한다. 대신 도는 동안 그 줄을 잠가 두 번 눌리는
    /// 것을 막는다.
    func pushToSpark(_ name: String) {
        guard pushingDataset == nil else { return }
        pushingDataset = name
        let client = client
        Task {
            do {
                try await client.pushToSpark(name)
                errorMessage = nil
            } catch {
                errorMessage = Self.message(for: error)
            }
            pushingDataset = nil
            // 보낸 뒤 목록을 다시 읽어야 그 줄이 `전송됨`으로 바뀐다.
            loadSpark()
        }
    }

    /// 학습된 체크포인트를 콘솔 서버로 회수한다. 이 Mac이 아니라 팔이 붙어 있는 서버로
    /// 내려온다 — 추론은 거기서 돈다.
    func pullCheckpoint(run: String, step: String) {
        guard pullingCheckpoint == nil else { return }
        pullingCheckpoint = "\(run)/\(step)"
        let client = client
        Task {
            do {
                try await client.pullCheckpoint(run: run, step: step)
                errorMessage = nil
            } catch {
                errorMessage = Self.message(for: error)
            }
            pullingCheckpoint = nil
        }
    }

    // MARK: 카메라

    func startPreview(_ role: SOArmCameraRole) {
        // 꺼 둔 상태에서는 열지 않는다. 화면이 버튼을 이미 막고 있지만, 프리뷰를 여는
        // 길이 하나가 아니므로(수집이 끝난 뒤 자동으로 다시 켜는 자리가 있다) 여는
        // 자리에서 한 번 더 본다.
        guard !cameraPolicy.isOff else { return }
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
        let addresses = server.candidateHosts.joined(separator: ", ")
        print("• 대상 \(server.user)@[\(addresses)] · 콘솔 \(server.baseURL.absoluteString) → 서버 \(server.remotePort)")

        do {
            try await SOArmTunnel.shared.ensureConnected(server: server)
            if let host = SOArmTunnel.shared.connectedHost {
                print("✅ SSH 터널을 열었습니다 · \(host)")
            } else {
                print("✅ 콘솔이 이미 이 포트에서 응답합니다 (터널을 새로 열지 않았습니다)")
            }
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
