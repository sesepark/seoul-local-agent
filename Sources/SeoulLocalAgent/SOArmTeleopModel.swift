import Foundation
import Combine

/// 원격 텔레옵 화면이 들고 있는 상태.
///
/// `SOArmConsoleModel`이 서버에게 *무엇을 시작하고 멈추라고* 지시하는 자리라면, 이쪽은
/// 서버와 **계속 이야기하는** 자리다. 30Hz로 관절 상태가 내려오고 같은 속도로 목표가
/// 올라간다. 그래서 폴링이 아니라 WebSocket 하나를 쓴다.
///
/// 이 타입은 팔에 대해 낙관적으로 말하지 않는다. 목표를 보냈다고 화면의 관절을 먼저
/// 옮기지 않고, 서버가 실제로 읽은 값이 내려올 때 옮긴다. 조작면이 팔보다 앞서 있으면
/// 사람은 팔이 이미 도착했다고 믿은 채 다음 동작을 시작한다.
@MainActor
final class SOArmTeleopModel: ObservableObject {
    enum Connection: Equatable {
        case idle
        case connecting
        case streaming
        case failed(String)
    }

    @Published private(set) var connection: Connection = .idle
    @Published private(set) var status = SOArmVirtualLeaderStatus()
    @Published private(set) var lease: SOArmLease?
    /// 우리가 보내고 있는 목표. 조작하지 않는 동안에는 계속 실제값을 따라간다 — 그래야
    /// 리스를 잡은 직후의 첫 명령이 현재 자세에서 시작한다.
    @Published private(set) var target: [String: Double] = [:]
    /// 지금 사람이 무언가를 끌고 있는가. 데드맨의 심장이다: 거짓이 되는 순간 목표가
    /// 실제 자세로 붙고 팔은 그 자리에 선다.
    @Published private(set) var isCommanding = false
    @Published var errorMessage: String?
    /// 서버가 방금 거절한 것. 몇 초 뒤 스스로 사라진다.
    @Published private(set) var rejection: String?
    @Published private(set) var isBusy = false

    /// 3D 뷰어(WKWebView)가 붙어 있는가. 붙기 전에 밀어 넣은 텔레메트리는 버려진다.
    @Published private(set) var isViewerReady = false
    /// 3D가 열리지 못했으면 그 이유. 검은 사각형만 남겨 두면 무엇이 잘못됐는지 알 길이
    /// 없고, 사람은 팔이 고장 난 것으로 읽는다.
    @Published private(set) var viewerError: String?
    /// 3D를 그리고 있는 그래픽 장치의 이름. 페이지가 붙을 때 한 번 알려 준다.
    @Published private(set) var viewerRenderer: String?

    let sceneCamera = MJPEGStream()
    let wristCamera = MJPEGStream()

    private let console: SOArmConsoleModel
    private var socket: URLSessionWebSocketTask?
    private var socketSession: URLSession?
    private var streamTask: Task<Void, Never>?
    private var commandTask: Task<Void, Never>?
    private var leaseTask: Task<Void, Never>?
    /// 리스를 받은 시각. 갓 받은 리스를 낡은 프레임이 지우지 못하게 하는 데 쓴다.
    private var leaseTakenAt = Date.distantPast
    private var reconnectAttempt = 0
    private var sequence = 0
    private var isVisible = false
    private var rejectionTask: Task<Void, Never>?

    /// 이 세션의 이름. 서버가 리스를 누가 쥐고 있는지 다른 기기에 보여 줄 때 쓴다.
    private let sessionID = "mac-\(UUID().uuidString.prefix(8))"

    /// 화면을 눌러 보지 않고도 이 화면의 상태를 확인할 수 있게 하는 점검용 스위치.
    /// `--soarm-preview`·`--soarm-console`과 같은 자리의 것이다. 이 화면은 서버가 관찰을
    /// 시작해야 3D가 실제 팔을 그리는데, 그 상태는 손으로 눌러야만 볼 수 있다.
    ///
    /// **조작 권한을 받는 스위치는 없다.** 확인 문구를 옮겨 적는 그 순간이 게이트의
    /// 전부이므로, 그것을 건너뛰는 길을 점검용으로도 만들지 않는다.
    private static let observesOnLaunch = CommandLine.arguments.contains("--soarm-teleop")
    private var appliedLaunchOptions = false

    /// `applicationWillTerminate`에서 닿기 위한 참조. `SOArmConsoleModel.current`와 같은 이유다.
    private(set) static weak var current: SOArmTeleopModel?

    init(console: SOArmConsoleModel) {
        self.console = console
        Self.current = self
    }

    // MARK: 파생 상태

    var server: SOArmServer { console.server }
    var client: SOArmVirtualLeaderClient {
        SOArmVirtualLeaderClient(baseURL: server.baseURL, motionToken: server.motionToken)
    }
    var telemetry: SOArmTelemetry { status.telemetry }
    var state: SOArmSafetyState { telemetry.state }
    var mirror: SOArmLimitMirror { SOArmLimitMirror(spec: status.spec, policy: status.policy) }
    var holdsAuthority: Bool { lease != nil }

    /// 토크에 대해 화면이 할 수 있는 말.
    ///
    /// 루프가 돌지 않으면 아무 말도 하지 않는 것이 아니라 **모른다고** 말한다. 팔이
    /// 힘을 주고 서 있는데 "토크 없음"이라고 적힌 화면을 보고 손을 대면 다친다.
    var torqueText: String {
        guard telemetry.torqueKnown else { return "토크 상태 모름 (관찰을 시작하면 확인합니다)" }
        return telemetry.torqueEnabled ? "토크 걸림" : "토크 없음"
    }

    /// 3D를 만져서 팔이 움직일 수 있는 상태인가.
    var canCommand: Bool { holdsAuthority && state.acceptsMotion }

    /// 뷰어가 열 주소. 3D는 서버가 서빙하는 것 하나뿐이고, 맥은 주변 UI만 네이티브로 그린다.
    var viewerURL: URL {
        server.baseURL.appending(path: "viewer/").appending(queryItems: [
            URLQueryItem(name: "host", value: "native"),
            URLQueryItem(name: "holder", value: "맥북"),
        ])
    }

    /// 툴바 배지.
    var badge: (text: String, isAlarming: Bool) {
        switch connection {
        case .idle: return ("연결 안 됨", false)
        case .connecting: return ("연결 중", false)
        case .failed: return ("연결 실패", true)
        case .streaming:
            let holder = telemetry.lease.map { $0.holder } ?? ""
            if !holder.isEmpty && !holdsAuthority { return ("\(holder) 조작 중", false) }
            return (state.korean, state.needsAcknowledgement)
        }
    }

    /// 무엇이 막고 있는가. 비어 있으면 화면은 아무것도 그리지 않는다.
    var problems: [String] {
        if case .failed(let message) = connection { return [message] }
        var lines = status.preflight.map(SOArmVirtualLeaderText.korean)
        if let specError = status.specError { lines.append(specError) }
        if server.motionToken.trimmingCharacters(in: .whitespaces).isEmpty {
            lines.append(SOArmVirtualLeaderClient.missingTokenMessage)
        }
        return lines
    }

    /// 지금 팔이 서 있는 이유. 확인이 필요한 멈춤일 때만 값이 있다.
    var stopReason: String? {
        guard state.needsAcknowledgement, let fault = telemetry.fault else { return nil }
        return fault.message
    }

    /// 다른 모드가 하드웨어를 쥐고 있는가. 같은 팔에 두 곳에서 명령이 들어가는 일은 없다.
    var blockedByOtherMode: String? {
        guard let console = console.status else { return nil }
        if console.recording.running { return "데이터 수집이 도는 동안에는 가상 리더를 켤 수 없습니다" }
        if console.teleop.running { return "물리 리더 텔레옵이 도는 동안에는 가상 리더를 켤 수 없습니다" }
        return nil
    }

    // MARK: 화면 수명

    func screenAppeared() {
        isVisible = true
        console.screenAppeared()
        Task {
            await console.connect()
            await refresh()
            connect()
            applyLaunchOptions()
        }
    }

    private func applyLaunchOptions() {
        guard !appliedLaunchOptions, Self.observesOnLaunch else { return }
        appliedLaunchOptions = true
        guard !telemetry.running, problems.isEmpty, blockedByOtherMode == nil else { return }
        startObserving()
    }

    /// 화면을 떠나면 **조작 권한을 놓는다.**
    ///
    /// 만료를 기다리지 않는 이유는, 기다리는 몇 초 동안 다른 기기가 팔을 만질 수 없기
    /// 때문이다. 그 시간은 팔이 안전해지는 시간이 아니라 아무도 손댈 수 없는 시간이다.
    /// 제어 루프는 그대로 둔다 — 팔이 토크를 물고 자세를 유지하는 것은 화면과 무관하다.
    func screenDisappeared() {
        isVisible = false
        endCommanding()
        Task { await releaseAuthority() }
        disconnectStream()
        stopCameras()
        console.screenDisappeared()
    }

    /// 앱이 끝난다. 종료를 기다리느라 늘어지지 않도록 짧은 상한을 두고 동기로 돌려준다.
    ///
    /// 리스만 돌려주고 팔은 건드리지 않는다. 창을 닫았다는 이유로 움직이던 팔을 세우거나
    /// 토크를 푸는 것은 이 앱이 내릴 결정이 아니다 — 하드웨어의 주인은 서버다.
    nonisolated func releaseAuthorityNow(leaseID: String, baseURL: URL, token: String) {
        var request = URLRequest(url: baseURL.appending(path: "api/vleader/lease/\(leaseID)"))
        request.httpMethod = "DELETE"
        request.timeoutInterval = 1.5
        request.setValue(token, forHTTPHeaderField: "X-SOARM-Motion-Token")
        let done = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { _, _, _ in done.signal() }.resume()
        _ = done.wait(timeout: .now() + 2)
    }

    func releaseHeldAuthorityNow() {
        guard let lease else { return }
        self.lease = nil
        releaseAuthorityNow(leaseID: lease.id, baseURL: server.baseURL, token: server.motionToken)
    }

    // MARK: 연결

    func refresh() async {
        do {
            let value = try await client.status()
            apply(value)
        } catch {
            connection = .failed(SOArmConsoleModel.message(for: error))
        }
    }

    private func apply(_ value: SOArmVirtualLeaderStatus) {
        status = value
        // 서버가 리스를 더 이상 우리 것으로 보지 않으면 화면도 그렇게 말해야 한다.
        if let mine = lease {
            if let theirs = value.telemetry.lease, theirs.id == mine.id {
                lease = theirs
            } else if Date().timeIntervalSince(leaseTakenAt) < Self.leaseGrace {
                // 방금 받은 리스는 낡은 프레임 한 장으로 버리지 않는다.
                //
                // 텔레메트리는 30Hz로 밀려오고, 그중 한 장은 리스를 받기 **직전**에 만들어진
                // 것일 수 있다. 그 한 장에는 우리 리스가 없고, 그것을 곧이곧대로 읽으면 앱은
                // 방금 받은 권한을 스스로 내려놓는다. 그러면 갱신도 멈추고, 서버 쪽 리스는
                // 5초 뒤 조용히 만료된다 — 팔은 토크가 걸린 채로 남고 화면은 권한이 없다고
                // 말한다. 사용자가 "권한 받기를 누르면 몇 초 있다가 풀린다"고 한 것이 이것이다.
            } else if value.telemetry.lease == nil || value.telemetry.lease?.id != mine.id {
                lease = nil
                stopLeaseKeepalive()
                endCommanding()
                // 조용히 권한만 사라지면, 3D를 계속 만지면서 팔이 왜 안 따라오는지 모른다.
                // 실제로 그 화면을 봤다 — 권한을 받고 몇 초 뒤 아무 말 없이 풀려 있었다.
                errorMessage = value.telemetry.lease == nil
                    ? "조작 권한이 풀렸습니다. 팔은 그 자리에 서 있습니다 — 다시 받으려면 조작 권한 받기를 누르세요."
                    : "다른 화면이 조작 권한을 가져갔습니다. 팔은 그쪽 명령을 따릅니다."
            }
        }
        if !isCommanding {
            syncTargetToArm()
        }
    }

    /// 목표를 팔의 지금 자세로 붙인다.
    func syncTargetToArm() {
        let present = telemetry.present
        guard !present.isEmpty else { return }
        target = present
    }

    func connect() {
        guard isVisible, socket == nil, server.isConfigured else { return }
        connection = .connecting
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.waitsForConnectivity = false
        let session = URLSession(configuration: configuration)
        let task = session.webSocketTask(with: client.streamURL)
        socketSession = session
        socket = task
        task.resume()
        streamTask = Task { [weak self] in await self?.readStream(task) }
        startCommandLoop()
    }

    private func disconnectStream() {
        streamTask?.cancel()
        streamTask = nil
        commandTask?.cancel()
        commandTask = nil
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        socketSession?.invalidateAndCancel()
        socketSession = nil
        if case .streaming = connection { connection = .idle }
    }

    private func readStream(_ task: URLSessionWebSocketTask) async {
        while !Task.isCancelled {
            do {
                let message = try await task.receive()
                guard case .string(let text) = message,
                      let data = text.data(using: .utf8),
                      let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { continue }
                handle(json)
            } catch {
                guard !Task.isCancelled else { return }
                await scheduleReconnect(SOArmClient.reason(for: error))
                return
            }
        }
    }

    private func handle(_ json: [String: Any]) {
        switch json.soarmString("type") {
        case "hello":
            reconnectAttempt = 0
            connection = .streaming
            apply(SOArmVirtualLeaderStatus(json))
            pushSpecToViewer()
            // 카메라는 스트림이 붙은 뒤에 켠다. 화면이 나타나는 순간에는 터널이 아직
            // 서지 않아 첫 요청이 반드시 실패했고, 그 실패에는 다시 시도할 길이 없었다.
            startCameras()
        case "telemetry":
            connection = .streaming
            var updated = status
            updated.telemetry = SOArmTelemetry(json)
            apply(updated)
            pushTelemetryToViewer()
        case "ack":
            rejection = nil
        case "reject":
            show(rejection: json.soarmString("message") ?? json.soarmString("code") ?? "거절되었습니다")
        case "lease":
            if let renewed = SOArmLease(json), renewed.id == lease?.id { lease = renewed }
        default:
            break
        }
    }

    private func scheduleReconnect(_ reason: String) async {
        socket = nil
        socketSession?.invalidateAndCancel()
        socketSession = nil
        commandTask?.cancel()
        commandTask = nil
        guard isVisible else {
            connection = .idle
            return
        }
        connection = .failed(reason)
        // 연결이 끊긴 동안 우리는 조작하지 않는다. 서버 쪽에서는 이미 워치독이 팔을
        // 세웠을 것이고, 돌아온다고 이전 동작을 이어서 하지 않는다.
        endCommanding()
        reconnectAttempt += 1
        let delay = min(8.0, pow(2.0, Double(min(reconnectAttempt, 3))) * 0.4)
        try? await Task.sleep(for: .seconds(delay))
        guard isVisible else { return }
        connect()
    }

    private func show(rejection message: String) {
        rejection = message
        rejectionTask?.cancel()
        rejectionTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            self?.rejection = nil
        }
    }

    // MARK: 명령

    /// 목표를 30Hz로 계속 올려 보낸다.
    ///
    /// 손을 떼도 스트림은 멈추지 않는다. 멈추는 것은 목표이지 대화가 아니다 — 스트림이
    /// 끊기면 서버의 워치독이 이것을 사고로 읽고 HOLD로 떨어뜨리는데, 손가락을 뗄 때마다
    /// 그러면 조작이 되지 않는다. 실제로 대화가 끊기는 것은 화면을 떠나거나 앱이 끝날
    /// 때이고, 그때는 HOLD가 정확히 옳은 답이다.
    private func startCommandLoop() {
        commandTask?.cancel()
        let period = Duration.milliseconds(1000 / max(1, status.policy.hz))
        commandTask = Task { [weak self] in
            var beats = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: period)
                guard let self, !Task.isCancelled else { return }
                self.sendCommand()
                beats += 1
                // 카메라가 끊기면 다시 붙는다. 조작하면서 보는 화면이라 한 번 끊긴 채로
                // 남으면 그때부터는 손만 보고 조작하게 된다.
                if beats % 90 == 0 { self.restartFailedCameras() }
                // 하트비트는 명령과 따로 보낸다. PROTOCOL.md가 둘을 분리하라고 적어 둔
                // 이유가 여기서 그대로 드러난다 — HOLD에 걸려 있는 동안에는 명령을 보내지
                // 않으므로, 명령으로만 리스를 갱신하면 멈춰 서 있는 사이에 권한이 만료된다.
                if beats % 24 == 0 { self.sendHeartbeat() }
            }
        }
    }

    private func sendCommand() {
        guard canCommand, let lease, let socket, !target.isEmpty else { return }
        sequence += 1
        let joints = target.mapValues { (($0 * 1000).rounded() / 1000) }
        let payload: [String: any Sendable] = [
            "type": "command",
            "lease_id": lease.id,
            "session_id": sessionID,
            "sequence": sequence,
            "observation": telemetry.observation,
            "valid_for_ms": 300,
            "joints": joints,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let text = String(data: data, encoding: .utf8) else { return }
        send(text, on: socket)
    }

    /// 리스를 지키는 것은 **명령 루프와 따로** 돈다.
    ///
    /// 전에는 30Hz 명령 루프가 24프레임마다 하트비트를 겸했다. 그 루프는 소켓이 끊기면
    /// 함께 죽는데, 받는 쪽(텔레메트리)은 다시 붙어도 보내는 쪽이 살아나지 않는 순간이
    /// 있었다. 화면은 멀쩡히 값이 바뀌는데 서버로는 아무것도 가지 않았고, 5초 뒤 권한만
    /// 조용히 만료됐다. 그래서 리스를 쥐고 있는 동안에는 이 태스크가 HTTP로 직접 갱신한다 —
    /// 소켓의 안부와 무관하게.
    /// 갓 받은 리스를 지키는 유예. 서버의 TTL(5초)보다 짧고, 프레임 한 장이 밀리는
    /// 시간보다는 넉넉하다.
    private static let leaseGrace: TimeInterval = 2

    private func startLeaseKeepalive() {
        leaseTask?.cancel()
        let period = Duration.milliseconds(max(500, status.policy.leaseTTLMs / 3))
        leaseTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: period)
                guard let self, !Task.isCancelled else { return }
                guard let held = self.lease else { continue }
                // 한 번 실패했다고 그만두지 않는다. 터널이 잠깐 끊겼다 붙는 일이 있고,
                // 그때 갱신을 접으면 팔은 토크가 걸린 채로 권한만 잃는다. 정말로 잃었다면
                // 그 사실은 위의 `apply`가 말해 준다.
                try? await self.client.heartbeat(held.id)
            }
        }
    }

    private func stopLeaseKeepalive() {
        leaseTask?.cancel()
        leaseTask = nil
    }

    /// 소켓으로 한 줄 내보낸다.
    ///
    /// 실패를 삼키지 않는다. `send`의 오류를 버리는 동안, 받는 쪽만 살아 있고 보내는 쪽은
    /// 죽은 소켓이 멀쩡한 척 남아 있었다 — 화면에는 텔레메트리가 흐르는데 서버로는 명령도
    /// 하트비트도 한 줄 나가지 않았다. 실패하면 다시 붙는 편이 낫다.
    private func send(_ text: String, on socket: URLSessionWebSocketTask) {
        socket.send(.string(text)) { [weak self] error in
            guard error != nil else { return }
            Task { @MainActor [weak self] in
                guard let self, self.socket === socket else { return }
                await self.scheduleReconnect("스트림으로 명령을 보내지 못했습니다")
            }
        }
    }

    private func sendHeartbeat() {
        guard let lease, let socket else { return }
        let payload: [String: any Sendable] = ["type": "heartbeat", "lease_id": lease.id]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let text = String(data: data, encoding: .utf8) else { return }
        send(text, on: socket)
    }

    // MARK: 조작

    /// 관절 하나를 옮긴다. 슬라이더와 3D 드래그가 같은 자리로 들어온다.
    func setTarget(_ name: String, _ value: Double) {
        guard let joint = status.spec.first(where: { $0.name == name }) else { return }
        isCommanding = true
        target[name] = clampToSyncWindow(joint, joint.clamp(value))
    }

    /// 리스를 막 잡았을 때는 첫 목표가 팔의 현재 자세 근처여야 한다.
    ///
    /// 서버가 그렇게 요구하는데(`POSE_NOT_SYNCED`), 클라이언트가 그것을 모르면 슬라이더를
    /// 멀리 던진 순간 명령이 조용히 거절되고 팔은 꿈쩍도 하지 않는다. 실물에서 그 화면을
    /// 봤다 — 47%로 보냈는데 1.9%에 선 채로 거절만 쌓였다. 거절당할 값을 보내는 대신
    /// 갈 수 있는 데까지 보내고, 자세가 맞으면 나머지는 다음 명령이 이어 간다.
    private func clampToSyncWindow(_ joint: SOArmJointSpec, _ value: Double) -> Double {
        guard lease?.needsSync == true, let present = telemetry.present[joint.name] else { return value }
        let tolerance = (joint.isPercent ? status.policy.syncTolerancePercent : status.policy.syncToleranceDegrees) * 0.8
        return min(present + tolerance, max(present - tolerance, value))
    }

    /// 여러 관절을 한 번에. 3D 뷰어가 올려 보내는 목표가 여기로 들어온다.
    func setTargets(_ values: [String: Double], commanding: Bool) {
        for (name, value) in values {
            guard let joint = status.spec.first(where: { $0.name == name }) else { continue }
            target[name] = clampToSyncWindow(joint, joint.clamp(value))
        }
        isCommanding = commanding
        if !commanding { syncTargetToArm() }
    }

    /// 데드맨. 손을 떼면 목표가 팔의 지금 자리로 붙고 팔은 그 자리에 선다.
    func endCommanding() {
        isCommanding = false
        syncTargetToArm()
        pushEnabledToViewer()
    }

    // MARK: 권한

    /// 확인 문구를 손으로 옮겨 적은 뒤 조작 권한을 받는다.
    ///
    /// 문구는 앱이 대신 채우지 않는다. 옮겨 적는 그 순간이 게이트의 전부이고, 미리
    /// 채워 두면 게이트가 아니라 버튼 하나가 된다.
    func takeAuthority(confirmation: String) {
        perform { client, model in
            // 한 번의 확인으로 어디서든 다시 시작할 수 있어야 한다. 관찰이 꺼져 있든,
            // 걸려서 멈춰 있든, 토크를 풀어 두었든 마찬가지다. 전에는 이 셋이 각각 다른
            // 버튼을 요구했고 순서를 틀리면 서버가 조용히 거절했다 — 토크를 풀고 권한을
            // 반납한 뒤 다시 받으려 하면 아무 일도 일어나지 않았다.
            //
            // 매 단계 뒤에 상태를 다시 읽는다. 방금 바뀐 것을 두고 예전 스냅숏으로
            // 다음 판단을 하면 하나씩 건너뛰게 된다.
            // 손에 든 상태부터 새로 읽는다. 화면이 들고 있던 스냅숏이 낡아 있으면 — 스트림이
            // 잠깐 끊겼다 붙은 뒤가 그렇다 — "토크는 이미 걸려 있다"고 잘못 판단해 토크를
            // 걸지 않고 리스를 요청하고, 서버는 영어 한 줄로 거절한다. 사용자가 만난 화면이
            // 그것이었다: 토크를 풀고 반납한 뒤 다시 받으려 하면 아무 일도 일어나지 않았다.
            await model.refresh()
            if !model.telemetry.running {
                try await client.start()
                await model.refresh()
            }
            if model.state.needsAcknowledgement {
                try await client.resume()
                await model.refresh()
            }
            if !model.telemetry.torqueEnabled {
                try await client.arm(confirmation: confirmation)
                await model.refresh()
            }
            let lease = try await client.takeLease(
                holder: "맥북", session: model.sessionID, confirmation: confirmation
            )
            model.lease = lease
            model.leaseTakenAt = Date()
            model.startLeaseKeepalive()
            model.syncTargetToArm()
            model.pushEnabledToViewer()
        }
    }

    func releaseAuthority() async {
        guard let held = lease else { return }
        lease = nil
        stopLeaseKeepalive()
        pushEnabledToViewer()
        try? await client.releaseLease(held.id)
        await refresh()
    }

    /// 지금 자세에서 세운다. 리스가 없어도, 토큰이 없어도 된다.
    func holdNow() {
        endCommanding()
        perform { client, _ in try await client.hold() }
    }

    /// 멈춘 이유를 확인했다. 이전 동작을 이어서 하지 않고 현재 자세에서 다시 시작한다.
    func resume() {
        perform { client, model in
            try await client.resume()
            model.syncTargetToArm()
        }
    }

    /// 팔로워 serial을 잡고 관찰을 시작한다. 토크는 걸지 않는다.
    func startObserving() {
        perform { client, _ in try await client.start() }
    }

    /// 루프를 내린다. 토크가 걸려 있으면 서버가 거절하고 그 이유가 화면에 뜬다.
    func stopVirtualLeader() {
        perform { client, model in
            await model.releaseAuthority()
            try await client.stop()
        }
    }

    /// 토크를 푼다. **팔이 떨어질 수 있다.** 확인 문구를 손으로 옮겨 적어야 한다.
    func releaseTorque(confirmation: String) {
        perform { client, model in
            await model.releaseAuthority()
            try await client.releaseTorque(confirmation: confirmation)
        }
    }

    /// 클로저는 메인 액터에 묶여 있다. 서버를 부르는 `await` 자리에서 메인을 놓아 주므로
    /// 화면이 멈추지 않고, 그러면서도 상태를 고치는 줄들이 액터를 넘나들지 않는다.
    private func perform(_ body: @escaping @MainActor (SOArmVirtualLeaderClient, SOArmTeleopModel) async throws -> Void) {
        guard !isBusy else { return }
        isBusy = true
        errorMessage = nil
        let client = client
        Task {
            do {
                try await body(client, self)
            } catch {
                errorMessage = SOArmConsoleModel.message(for: error)
            }
            isBusy = false
            await refresh()
        }
    }

    // MARK: 카메라

    /// 이 화면에서는 카메라가 켜져 있는 것이 기본이다.
    ///
    /// `SO-ARM 101` 화면과 다른 점이다. 그쪽은 상태를 보는 화면이라 `프리뷰`를 눌러야
    /// 카메라를 점유하지만, 여기서는 카메라를 보면서 조작하는 것이 이 화면의 전부다.
    /// 화면을 떠나면 곧바로 놓는다.
    func startCameras() {
        guard isVisible else { return }
        let client = console.client
        sceneCamera.start(client.cameraURL(SOArmCameraRole.scene.rawValue))
        wristCamera.start(client.cameraURL(SOArmCameraRole.wrist.rawValue))
    }

    /// 끊긴 카메라만 다시 연다. 잘 나오고 있는 쪽은 건드리지 않는다 — 다시 열면 서버의
    /// worker를 놓았다 잡는 동안 화면이 한 번 검게 된다.
    private func restartFailedCameras() {
        guard isVisible else { return }
        let client = console.client
        for role in SOArmCameraRole.allCases {
            let stream = stream(role)
            guard !stream.isRunning else { continue }
            stream.start(client.cameraURL(role.rawValue))
        }
    }

    func stopCameras() {
        sceneCamera.stop()
        wristCamera.stop()
        let client = console.client
        Task {
            for role in SOArmCameraRole.allCases { try? await client.stopCamera(role.rawValue) }
        }
    }

    func stream(_ role: SOArmCameraRole) -> MJPEGStream {
        role == .scene ? sceneCamera : wristCamera
    }

    // MARK: 3D 뷰어와의 다리
    //
    // 3D는 서버가 서빙하는 웹 구현 하나뿐이고 폰도 같은 것을 쓴다. 맥에서는 그 페이지가
    // 자기 WebSocket을 열지 않는다(`?host=native`) — 리스와 전송은 이 모델이 쥐고,
    // 페이지는 그리기와 집기만 한다. 두 곳에서 같은 리스로 명령을 보내면 순번이 엉킨다.

    /// WKWebView에 자바스크립트를 넣어 줄 통로. 화면이 붙일 때 채운다.
    var evaluate: ((String) -> Void)?

    func viewerBecameReady() {
        isViewerReady = true
        viewerError = nil
        pushSpecToViewer()
        pushTelemetryToViewer()
        pushEnabledToViewer()
    }

    func viewerWentAway() {
        isViewerReady = false
        endCommanding()
    }

    /// 3D가 어떤 그래픽 장치로 그려지고 있는지. 화면이 비어 보일 때 그것이 *열리지 않은*
    /// 것인지 *그려지고 있는데 보이지 않는* 것인지 구별하는 유일한 단서다.
    func noteViewerRenderer(_ name: String?) {
        viewerRenderer = name
    }

    /// 3D 쪽에서 난 사고. 페이지가 스스로 말해 준다.
    func viewerFailed(_ message: String) {
        isViewerReady = false
        viewerError = message
    }

    private func pushSpecToViewer() {
        guard isViewerReady, let json = Self.json(specPayload()) else { return }
        evaluate?("window.soarmViewer && window.soarmViewer.spec(\(json))")
    }

    private func pushTelemetryToViewer() {
        guard isViewerReady, let json = Self.json(telemetryPayload()) else { return }
        evaluate?("window.soarmViewer && window.soarmViewer.telemetry(\(json))")
    }

    private func pushEnabledToViewer() {
        guard isViewerReady else { return }
        evaluate?("window.soarmViewer && window.soarmViewer.setEnabled(\(canCommand))")
    }

    /// 네이티브 슬라이더가 움직였다는 것을 3D에도 알린다. 두 화면이 같은 자세를 그려야 한다.
    func pushTargetToViewer(_ name: String, _ value: Double) {
        guard isViewerReady else { return }
        evaluate?("window.soarmViewer && window.soarmViewer.setTarget('\(name)', \(value))")
    }

    func pushEndTargetToViewer() {
        guard isViewerReady else { return }
        evaluate?("window.soarmViewer && window.soarmViewer.endTarget()")
    }

    private func specPayload() -> [String: Any] {
        [
            "spec": status.spec.map { joint in
                [
                    "name": joint.name,
                    "label": joint.label,
                    "unit": joint.unit,
                    "min": joint.minimum,
                    "max": joint.maximum,
                    "urdf_joint": joint.urdfJoint,
                    "urdf_sign": 1.0,
                    "radians_per_unit": joint.isPercent ? 0.0174533 : 0.01745329,
                ]
            },
            "policy": ["load_trip": status.policy.loadTrip, "heartbeat_ms": status.policy.heartbeatMs],
        ]
    }

    private func telemetryPayload() -> [String: Any] {
        [
            "state": telemetry.state.rawValue,
            "state_korean": telemetry.state.korean,
            "torque_enabled": telemetry.torqueEnabled,
            "observation": telemetry.observation,
            "joints": telemetry.joints.map { reading in
                [
                    "name": reading.name,
                    "present": reading.present,
                    "goal": reading.goal,
                    "load": reading.load,
                    "rate_limited": reading.rateLimited,
                ]
            },
            "fault": telemetry.fault.map { ["code": $0.code, "joint": $0.joint ?? "", "message": $0.message] } as Any,
            "lease": telemetry.lease.map { ["lease_id": $0.id, "holder": $0.holder] } as Any,
        ]
    }

    private static func json(_ value: [String: Any]) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: value) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
