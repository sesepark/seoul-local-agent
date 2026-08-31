import Foundation
#if canImport(Testing)
import Testing
@testable import SeoulLocalAgent

/// 앱의 조작 경로를 **살아 있는 콘솔에 대고** 끝까지 걸어 본다.
///
/// 다른 시험들은 고정된 JSON을 읽고 계약이 맞는지만 본다. 여기서는 화면의 버튼이 부르는
/// 것과 똑같은 함수들을 순서대로 불러, 확인 문구 → 토크 → 리스 → 30Hz 명령 → 팔이 따라옴
/// → 접촉으로 걸림 → 확인하고 계속 → 반납까지가 실제로 이어지는지 본다.
///
/// **팔은 움직이지 않는다.** 상대는 흉내 백엔드로 도는 콘솔이다. 실물 팔로워를 여는 것은
/// 사람이 현장에 있을 때만 하는 일이고, 그 절차는 `docs/원격_텔레옵_안전.md`에 있다.
///
/// 콘솔이 없으면 조용히 건너뛴다. 서버 없이도 `scripts/run-tests.sh`가 초록이어야 한다.
///
/// ```bash
/// # 서버에서 흉내 콘솔을 띄우고
/// SOARM_VL_BACKEND=simulated SOARM_VL_SIM_OBSTACLE=elbow_flex:12 \
///   SOARM_MOTION_TOKEN=sim-token SOARM_ENABLE_MOTION=1 \
///   .venv/bin/uvicorn soarm_console.app:app --app-dir src --port 8090
/// # 이 Mac에서
/// ssh -N -L 8091:127.0.0.1:8090 deploy@<서버>
/// SOARM_TEST_CONSOLE_PORT=8091 SOARM_TEST_MOTION_TOKEN=sim-token ./scripts/run-tests.sh
/// ```
@Suite("SO-ARM 101 가상 리더 · 살아 있는 콘솔", .serialized)
struct SOArmTeleopIntegrationTests {

    private static var port: Int? {
        guard let raw = ProcessInfo.processInfo.environment["SOARM_TEST_CONSOLE_PORT"],
              let value = Int(raw) else { return nil }
        return value
    }

    private static var token: String {
        ProcessInfo.processInfo.environment["SOARM_TEST_MOTION_TOKEN"] ?? ""
    }

    /// 이 포트에서 콘솔이 실제로 대답하는가. 대답하지 않으면 시험을 건너뛴다.
    private static func reachable(_ port: Int) async -> Bool {
        await SOArmTunnel.probe(URL(string: "http://127.0.0.1:\(port)")!)
    }

    /// 화면이 들고 있는 것과 같은 모델. 서버 설정만 임시 폴더에 따로 둔다 — 이 시험이
    /// 사용자의 실제 설정 파일을 건드리면 안 된다.
    @MainActor
    private static func makeModel(port: Int) throws -> (SOArmTeleopModel, URL) {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "soarm-live-\(UUID().uuidString)", directoryHint: .isDirectory)
        let store = SOArmServerStore(directory: directory)
        var server = SOArmServer()
        server.host = "127.0.0.1"
        server.user = "test"
        server.localPort = port
        server.remotePort = port
        server.motionToken = token
        try store.save(server)
        let console = SOArmConsoleModel(store: store)
        return (SOArmTeleopModel(console: console), directory)
    }

    @MainActor
    private static func wait(
        _ seconds: Double = 6, until predicate: @MainActor () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if predicate() { return true }
            try? await Task.sleep(for: .milliseconds(40))
        }
        return predicate()
    }

    /// 앞 시험이 쥔 권한이 풀릴 때까지 기다린다. 리스는 5초에 만료되므로 그보다 길게 본다.
    /// 빼앗는 길은 없고, 시험이라고 예외를 두지도 않는다.
    @MainActor
    private static func waitForFreeLease(_ model: SOArmTeleopModel) async -> Bool {
        await wait(9) { model.connection == .streaming && model.telemetry.lease == nil }
    }

    /// 사람이 3D를 끄는 것과 같은 모양으로 민다. 현재 자세에서 조금씩 — 리스를 막 잡은
    /// 직후에 멀리 있는 목표를 보내면 자세 미동기로 거절되는 것이 맞다.
    @MainActor
    private static func push(_ model: SOArmTeleopModel, _ joint: String, by step: Double, ticks: Int) async {
        for _ in 0..<ticks {
            let present = model.telemetry.present[joint] ?? 0
            model.setTarget(joint, present + step)
            try? await Task.sleep(for: .milliseconds(40))
            if model.state.needsAcknowledgement { return }
        }
    }

    @MainActor
    @Test("확인 문구부터 반납까지, 화면이 부르는 그대로")
    func theWholeFlowAgainstALiveConsole() async throws {
        guard let port = Self.port, await Self.reachable(port) else { return }
        let (model, directory) = try Self.makeModel(port: port)
        defer { try? FileManager.default.removeItem(at: directory) }

        // 1. 화면에 들어간다. 스트림이 붙고 관절 계약이 내려온다.
        model.screenAppeared()
        #expect(await Self.wait(10) { model.connection == .streaming })
        #expect(await Self.waitForFreeLease(model))
        #expect(await Self.wait { model.status.spec.count == 6 })
        #expect(model.problems.isEmpty)
        // 아직 아무 권한도 없다. 3D를 만져도 팔은 움직이지 않는다.
        #expect(model.canCommand == false)
        #expect(model.holdsAuthority == false)

        // 2. 확인 문구가 틀리면 열리지 않는다. 서버가 400으로 거절하고 리스는 생기지 않는다.
        //    토크가 이미 걸려 있어도 마찬가지여야 한다 — 처음에는 토크를 거는 자리에만
        //    게이트를 두었고, 이 시험이 그 구멍을 잡았다.
        let torqueBefore = model.telemetry.torqueEnabled
        model.takeAuthority(confirmation: "move soarm101")
        #expect(await Self.wait { model.errorMessage != nil })
        #expect(model.holdsAuthority == false)
        // 틀린 문구로는 토크가 켜지지 않는다. 이미 켜져 있었다면 그건 앞 시험이 켜 둔
        // 것이고(토크는 스스로 꺼지지 않는다), 그 상태를 바꾸지 않았다는 것이 요점이다.
        #expect(model.telemetry.torqueEnabled == torqueBefore)
        model.errorMessage = nil

        // 3. 정확히 옮겨 적으면 토크가 걸리고 조작 권한을 받는다.
        model.takeAuthority(confirmation: SOArmVirtualLeaderClient.armConfirmation)
        #expect(await Self.wait(10) { model.holdsAuthority })
        #expect(await Self.wait { model.telemetry.torqueEnabled })
        #expect(await Self.wait { model.canCommand })
        // 권한을 받는 순간의 목표는 정의상 지금 자세다. 그러지 않으면 첫 명령에 팔이 튄다.
        let atGrant = model.telemetry.present
        for (name, present) in atGrant {
            #expect(abs((model.target[name] ?? .nan) - present) < 0.001)
        }

        // 4. 3D를 끄는 것과 같은 모양으로 민다. 팔이 따라온다.
        let before = model.telemetry.present["shoulder_pan"] ?? 0
        await Self.push(model, "shoulder_pan", by: 1.5, ticks: 25)
        let after = model.telemetry.present["shoulder_pan"] ?? 0
        #expect(after > before + 2, "밀었는데 팔이 따라오지 않았습니다 (\(before) → \(after))")
        #expect(model.state == .active)

        // 5. 손을 뗀다. 목표가 지금 자리로 붙고 팔은 선다(데드맨).
        model.endCommanding()
        #expect(model.isCommanding == false)
        let stopped = model.telemetry.present["shoulder_pan"] ?? 0
        #expect(await Self.wait(2) {
            abs((model.telemetry.present["shoulder_pan"] ?? 0) - stopped) < 1.0
        })

        // 6. 막힌 관절로 민다. 흉내 백엔드가 elbow_flex를 막아 두었다.
        await Self.push(model, "elbow_flex", by: 2.0, ticks: 120)
        #expect(await Self.wait(6) { model.state.needsAcknowledgement })
        let fault = try #require(model.telemetry.fault)
        #expect(fault.joint == "elbow_flex")
        #expect(["OVERLOAD", "OVERCURRENT", "FOLLOWING_ERROR"].contains(fault.code))
        // 화면이 왜 멈췄는지 말할 수 있어야 한다.
        #expect(fault.message.isEmpty == false)
        // 걸린 자리보다 물러나 있다.
        #expect((model.telemetry.present["elbow_flex"] ?? 99) < 12)
        // 멈춘 동안에는 토크를 그대로 두어야 한다. 끄면 팔이 떨어진다.
        #expect(model.telemetry.torqueEnabled)
        // 그리고 새 목표를 받지 않는다.
        #expect(model.canCommand == false)

        // 7. 확인하고 계속. 이전 동작을 이어서 하지 않고 지금 자세에서 다시 시작한다.
        model.resume()
        #expect(await Self.wait(6) { model.state == .ready || model.state == .active })
        #expect(await Self.wait { model.telemetry.fault == nil })

        // 8. 누구나 부를 수 있는 정지. 토크는 유지되고 리스도 그대로다.
        model.holdNow()
        #expect(await Self.wait(6) { model.state == .hold })
        #expect(model.telemetry.torqueEnabled)
        #expect(model.telemetry.lease?.holder == "맥북")
        model.resume()
        #expect(await Self.wait(6) { model.state != .hold })

        // 9. 반납. 팔은 자세를 유지한 채 남는다.
        await model.releaseAuthority()
        #expect(model.holdsAuthority == false)
        #expect(await Self.wait(6) { model.telemetry.lease == nil })
        #expect(model.telemetry.torqueEnabled)

        // 10. 화면을 떠난다. 스트림을 놓고, 서버 쪽 루프는 그대로 둔다.
        model.screenDisappeared()
        #expect(await Self.wait { model.connection != .streaming })
    }

    @MainActor
    @Test("조작 권한은 한 기기만 갖는다")
    func onlyOneDeviceCanHoldTheLease() async throws {
        guard let port = Self.port, await Self.reachable(port) else { return }
        let (model, directory) = try Self.makeModel(port: port)
        defer { try? FileManager.default.removeItem(at: directory) }
        model.screenAppeared()
        defer { model.screenDisappeared() }
        #expect(await Self.wait(10) { model.connection == .streaming })
        #expect(await Self.waitForFreeLease(model))

        model.takeAuthority(confirmation: SOArmVirtualLeaderClient.armConfirmation)
        #expect(await Self.wait(10) { model.holdsAuthority })

        // 폰이 같은 권한을 달라고 한다. 앱이 쥐고 있는 동안에는 받지 못한다.
        let phone = SOArmVirtualLeaderClient(
            baseURL: URL(string: "http://127.0.0.1:\(port)")!, motionToken: Self.token
        )
        await #expect(throws: SOArmError.self) {
            _ = try await phone.takeLease(holder: "아이폰", session: "phone-1", confirmation: SOArmVirtualLeaderClient.armConfirmation)
        }
        // 반납하면 받는다. 빼앗기는 없다.
        await model.releaseAuthority()
        let taken = try await phone.takeLease(
            holder: "아이폰", session: "phone-1", confirmation: SOArmVirtualLeaderClient.armConfirmation
        )
        #expect(taken.holder == "아이폰")
        // 그동안 앱은 관찰만 한다 — 카메라와 3D는 계속 보인다.
        #expect(await Self.wait(6) { model.telemetry.lease?.holder == "아이폰" })
        #expect(model.canCommand == false)
        #expect(model.connection == .streaming)
        try await phone.releaseLease(taken.lease_identifier)
    }

    @MainActor
    @Test("연결이 끊기면 팔은 서고, 이어서 하지 않는다")
    func losingTheStreamHoldsTheArm() async throws {
        guard let port = Self.port, await Self.reachable(port) else { return }
        let (model, directory) = try Self.makeModel(port: port)
        defer { try? FileManager.default.removeItem(at: directory) }
        model.screenAppeared()
        #expect(await Self.wait(10) { model.connection == .streaming })
        #expect(await Self.waitForFreeLease(model))
        model.takeAuthority(confirmation: SOArmVirtualLeaderClient.armConfirmation)
        #expect(await Self.wait(10) { model.holdsAuthority })
        // 앞 시험이 남긴 정지가 있으면 사람이 확인하는 자리를 대신 눌러 준다. 권한을 새로
        // 받는 것만으로는 풀리지 않는 것이 맞다(그 규칙 자체는 서버 시험이 지킨다).
        if model.state.needsAcknowledgement {
            model.resume()
            #expect(await Self.wait(6) { !model.state.needsAcknowledgement })
        }
        await Self.push(model, "wrist_roll", by: 1.0, ticks: 10)
        // 끊기 전에 실제로 조작 중이어야 한다. 이미 서 있는 팔이 서 있는 것을 확인하면
        // 아무것도 확인한 것이 아니다.
        #expect(model.state == .active)

        // 화면을 떠나는 것이 곧 대화가 끊기는 것이다. 조작 권한은 돌려주고, 그 뒤로는
        // 명령이 가지 않으므로 서버의 워치독이 팔을 세운다.
        model.screenDisappeared()
        let watchdog = SOArmVirtualLeaderClient(
            baseURL: URL(string: "http://127.0.0.1:\(port)")!, motionToken: Self.token
        )
        var state = SOArmSafetyState.active
        var torque = false
        let deadline = Date().addingTimeInterval(6)
        while Date() < deadline {
            let status = try await watchdog.status()
            state = status.telemetry.state
            torque = status.telemetry.torqueEnabled
            if state == .hold { break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        #expect(state == .hold)
        #expect(torque, "연결이 끊겼다고 토크를 끄면 팔이 떨어진다")
    }
}

private extension SOArmLease {
    /// 시험에서만 쓰는 이름. `id`는 `Identifiable`과 겹쳐 읽기 어렵다.
    var lease_identifier: String { id }
}
#endif
