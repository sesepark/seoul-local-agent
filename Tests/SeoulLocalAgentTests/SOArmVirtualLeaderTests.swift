import Foundation
#if canImport(Testing)
import Testing
@testable import SeoulLocalAgent

@Suite("SO-ARM 101 가상 리더")
struct SOArmVirtualLeaderTests {

    /// 서버 `/api/vleader`가 실제로 내놓는 모양. 흉내 백엔드로 도는 콘솔에서 그대로
    /// 받아 온 것이고, 손으로 줄인 곳은 관절 여섯 개 중 셋을 남긴 것뿐이다.
    private static let statusJSON = """
    {
      "available": true,
      "spec_error": null,
      "preflight": [],
      "spec": [
        {"name": "shoulder_pan", "label": "어깨 회전", "unit": "deg",
         "min": -118.1978, "max": 118.1978, "urdf_joint": "shoulder_pan",
         "urdf_sign": 1.0, "radians_per_unit": 0.01745329},
        {"name": "elbow_flex", "label": "팔꿈치", "unit": "deg",
         "min": -96.8791, "max": 96.8791, "urdf_joint": "elbow_flex",
         "urdf_sign": 1.0, "radians_per_unit": 0.01745329},
        {"name": "gripper", "label": "집게", "unit": "percent",
         "min": 0.0, "max": 100.0, "urdf_joint": "gripper",
         "urdf_sign": 1.0, "radians_per_unit": 0.0174533}
      ],
      "policy": {"hz": 30, "step_deg": 2.0, "step_percent": 3.0,
                 "command_timeout_ms": 300, "command_valid_ms": 500,
                 "lease_ttl_ms": 5000, "heartbeat_ms": 1000,
                 "sync_tolerance_deg": 6.0, "sync_tolerance_percent": 10.0,
                 "load_trip": 400, "load_trip_ms": 300, "current_trip": 108,
                 "current_trip_ms": 300, "following_error_deg": 12.0,
                 "following_error_ms": 400, "temperature_warn_c": 55,
                 "temperature_trip_c": 65, "retreat_deg": 4.0},
      "arm_confirmation_length": 13,
      "viewer_url": "/viewer/",
      "running": true,
      "relay": false,
      "state": "HOLD",
      "state_korean": "자세 유지",
      "torque_enabled": true,
      "torque_known": true,
      "observation": 27512,
      "loop_ms": 4.43,
      "joints": [
        {"name": "shoulder_pan", "present": -44.922, "goal": -44.922, "load": 77.2,
         "current": 21.9, "temperature": 32.0, "rate_limited": false},
        {"name": "elbow_flex", "present": 8.0, "goal": 51.8, "load": 520.0,
         "current": 140.0, "temperature": 58.0, "rate_limited": true},
        {"name": "gripper", "present": 41.0, "goal": 41.0, "load": 12.0,
         "current": 4.0, "temperature": 46.0, "rate_limited": false}
      ],
      "fault": {"code": "OVERLOAD", "joint": "elbow_flex",
                "message": "팔꿈치의 부하가 300ms 넘게 520(문턱 400)입니다", "at": 1788195000.0},
      "warnings": [{"joint": "elbow_flex", "code": "OVER_TEMPERATURE", "message": "팔꿈치 58°C"}],
      "lease": {"lease_id": "426136b635229aff", "holder": "맥북", "session_id": "mac-1",
                "scope": "follower_motion", "needs_sync": true, "expires_in_ms": 4800},
      "error": null,
      "command_age_ms": 1400
    }
    """

    private static func status() throws -> SOArmVirtualLeaderStatus {
        try SOArmVirtualLeaderStatus.parse(Data(statusJSON.utf8))
    }

    // MARK: 관절 계약

    @Test("절대 한계는 서버가 내려준 값이고 앱이 계산하지 않는다")
    func limitsComeFromTheServer() throws {
        let status = try Self.status()
        let pan = try #require(status.spec.first { $0.name == "shoulder_pan" })
        // calibration의 range(758…3447)를 서버가 도 단위로 옮긴 값. 앱은 이 숫자를
        // 어디서도 다시 계산하지 않는다 — calibration을 다시 잡으면 저절로 따라와야 한다.
        #expect(abs(pan.minimum + 118.1978) < 0.001)
        #expect(abs(pan.maximum - 118.1978) < 0.001)
        #expect(pan.isPercent == false)

        let gripper = try #require(status.spec.first { $0.name == "gripper" })
        #expect(gripper.isPercent)
        #expect(gripper.minimum == 0 && gripper.maximum == 100)
    }

    @Test("단위가 다르면 표시도 다르다")
    func unitsAreShownAsThemselves() throws {
        let status = try Self.status()
        let elbow = try #require(status.spec.first { $0.name == "elbow_flex" })
        let gripper = try #require(status.spec.first { $0.name == "gripper" })
        #expect(elbow.text(12.34) == "12.3°")
        #expect(gripper.text(41.4) == "41%")
    }

    @Test("한계 밖의 값은 슬라이더에서도 잘린다")
    func clampingStaysInsideTheContract() throws {
        let elbow = try #require(try Self.status().spec.first { $0.name == "elbow_flex" })
        #expect(elbow.clamp(500) == elbow.maximum)
        #expect(elbow.clamp(-500) == elbow.minimum)
        #expect(elbow.clamp(10) == 10)
    }

    // MARK: 상태

    @Test("텔레메트리 한 장이 화면이 필요한 것을 전부 담고 있다")
    func telemetryCarriesTheWholePicture() throws {
        let status = try Self.status()
        #expect(status.telemetry.state == .hold)
        #expect(status.telemetry.torqueEnabled)
        #expect(status.telemetry.running)
        #expect(status.telemetry.relay == false)
        #expect(status.telemetry.joints.count == 3)
        #expect(status.telemetry.fault?.code == "OVERLOAD")
        #expect(status.telemetry.fault?.joint == "elbow_flex")
        #expect(status.telemetry.lease?.holder == "맥북")
        #expect(status.telemetry.lease?.needsSync == true)
        #expect(status.telemetry.warnings == ["팔꿈치 58°C"])
        #expect(status.telemetry.commandAgeMs == 1400)
    }

    @Test("모르는 상태 이름이 와도 화면이 비지 않는다")
    func anUnknownStateFallsBackInsteadOfFailing() throws {
        // 서버가 상태를 하나 더 만들었을 때, 앱이 그 자리에서 디코딩 실패로 통째로
        // 비는 것보다 "꺼짐"으로 보수적으로 읽고 조작을 열지 않는 편이 낫다.
        let json = Self.statusJSON.replacingOccurrences(of: "\"state\": \"HOLD\"", with: "\"state\": \"QUIESCING\"")
        let status = try SOArmVirtualLeaderStatus.parse(Data(json.utf8))
        #expect(status.telemetry.state == .stopped)
        #expect(status.telemetry.state.acceptsMotion == false)
    }

    @Test("토크를 모를 때는 모른다고 말한다")
    func anUnknownTorqueStateIsNotReportedAsOff() throws {
        // 루프가 돌지 않으면 토크가 걸려 있는지 알 수 없다. 서버에서 실제로 모터 여섯 개가
        // 전부 켜져 있는데 화면이 "토크 없음"이라고 적어 둔 것을 봤다.
        let known = try Self.status()
        #expect(known.telemetry.torqueKnown)
        #expect(known.telemetry.torqueEnabled)

        let json = Self.statusJSON.replacingOccurrences(of: "\"torque_known\": true", with: "\"torque_known\": false")
        let unknown = try SOArmVirtualLeaderStatus.parse(Data(json.utf8))
        #expect(unknown.telemetry.torqueKnown == false)
    }

    @Test("조작을 받아 주는 상태와 사람이 확인해야 하는 상태를 구별한다")
    func statesKnowWhatTheyAllow() {
        #expect(SOArmSafetyState.ready.acceptsMotion)
        #expect(SOArmSafetyState.active.acceptsMotion)
        #expect(SOArmSafetyState.safe.acceptsMotion == false)
        #expect(SOArmSafetyState.hold.acceptsMotion == false)
        #expect(SOArmSafetyState.retreating.acceptsMotion == false)
        #expect(SOArmSafetyState.hold.needsAcknowledgement)
        #expect(SOArmSafetyState.fault.needsAcknowledgement)
        #expect(SOArmSafetyState.active.needsAcknowledgement == false)
    }

    // MARK: 클라이언트 쪽 사본

    @Test("한계 사본은 서버가 무엇을 거절할지 미리 말해 준다")
    func theMirrorPredictsTheServersAnswer() throws {
        let status = try Self.status()
        let mirror = SOArmLimitMirror(spec: status.spec, policy: status.policy)
        // 절대 한계 밖 → 서버는 OUTSIDE_ABSOLUTE_LIMIT으로 거절한다.
        #expect(mirror.verdict(for: "elbow_flex", target: 400, present: 0, needsSync: false) == .outsideLimit)
        // 리스를 막 잡았는데 현재 자세에서 멀다 → POSE_NOT_SYNCED.
        #expect(mirror.verdict(for: "elbow_flex", target: 40, present: 0, needsSync: true) == .notSynced)
        // 같은 값이라도 자세가 이미 맞았으면 거절이 아니라 "잘라서 따라간다"이다.
        #expect(mirror.verdict(for: "elbow_flex", target: 40, present: 0, needsSync: false) == .rateLimited)
        #expect(mirror.verdict(for: "elbow_flex", target: 1, present: 0, needsSync: false) == .fine)
        // 집게는 단위가 달라 허용 폭도 다르다. 자세 동기화는 퍼센트 10까지 봐 주지만
        // 틱당 변화량은 퍼센트 3이라, 그 사이의 값은 거절이 아니라 잘라서 따라가는 쪽이다.
        #expect(mirror.verdict(for: "gripper", target: 43, present: 41, needsSync: true) == .fine)
        #expect(mirror.verdict(for: "gripper", target: 50, present: 41, needsSync: true) == .rateLimited)
        #expect(mirror.verdict(for: "gripper", target: 60, present: 41, needsSync: true) == .notSynced)
    }

    @Test("부하 막대의 만점은 서버의 정지 문턱이다")
    func theLoadBarIsScaledToTheTripThreshold() throws {
        let status = try Self.status()
        let mirror = SOArmLimitMirror(spec: status.spec, policy: status.policy)
        let elbow = try #require(status.telemetry.joints.first { $0.name == "elbow_flex" })
        let pan = try #require(status.telemetry.joints.first { $0.name == "shoulder_pan" })
        // 520은 문턱 400을 넘었으므로 가득 찬다. 넘겨도 1을 넘지 않는다.
        #expect(mirror.loadFraction(elbow) == 1.0)
        #expect(abs(mirror.loadFraction(pan) - 77.2 / 400) < 0.001)
        #expect(mirror.isHot(elbow))          // 58°C ≥ 경고 55°C
        #expect(mirror.isHot(pan) == false)   // 32°C
    }

    // MARK: 전송

    @Test("스트림 주소는 터널 너머의 같은 포트를 가리킨다")
    func theStreamGoesThroughTheSameTunnel() {
        let client = SOArmVirtualLeaderClient(
            baseURL: URL(string: "http://127.0.0.1:8088")!, motionToken: "x"
        )
        #expect(client.streamURL.absoluteString == "ws://127.0.0.1:8088/api/vleader/stream")
    }

    @Test("토큰이 비어 있으면 조작 요청을 아예 보내지 않는다")
    func motionWithoutATokenNeverLeavesTheApp() async {
        // 서버까지 갔다가 401을 받아 오는 것보다, 무엇이 빠졌는지 그 자리에서 말하는 편이
        // 낫다. 이 경로는 네트워크에 닿지 않으므로 서버 없이도 확인할 수 있다.
        let client = SOArmVirtualLeaderClient(
            baseURL: URL(string: "http://127.0.0.1:1")!, motionToken: "   "
        )
        await #expect(throws: SOArmError.self) {
            try await client.arm(confirmation: SOArmVirtualLeaderClient.armConfirmation)
        }
    }

    @Test("확인 문구는 서버가 요구하는 것과 글자 하나까지 같다")
    func theConfirmationPhrasesMatchTheServer() throws {
        // 서버가 문구 자체를 내려주지 않는다(내려주면 화면이 대신 채울 수 있다). 대신
        // 길이를 준다. 여기서 맞춰 두지 않으면 아무리 정확히 옮겨 적어도 400이 온다.
        let status = try Self.status()
        #expect(SOArmVirtualLeaderClient.armConfirmation == "MOVE SOARM101")
        #expect(SOArmVirtualLeaderClient.releaseConfirmation == "RELEASE TORQUE SOARM101")
        #expect(SOArmVirtualLeaderClient.armConfirmation.count == 13)
        #expect(status.telemetry.state == .hold)  // 이 픽스처가 실제 서버 응답임을 함께 붙잡아 둔다
    }

    // MARK: 설정

    @Test("조작 토큰은 서버 설정과 함께 이 기기에만 저장된다")
    func theMotionTokenIsStoredWithTheServerSettings() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "soarm-token-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SOArmServerStore(directory: directory)
        var server = SOArmServer()
        server.host = "192.168.0.20"
        server.user = "deploy"
        server.motionToken = "  secret-token  "
        try store.save(server)

        let loaded = store.load()
        #expect(loaded.motionToken == "secret-token")  // 앞뒤 공백은 저장할 때 걸러진다
        // 개인 정보와 같은 규칙으로 소유자만 읽을 수 있어야 한다.
        let attributes = try FileManager.default.attributesOfItem(atPath: store.debugURL.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }

    // MARK: 집에 있든 밖에 있든

    @Test("주소를 둘 적어 두면 적어 둔 순서대로 시도한다")
    func twoAddressesAreTriedInOrder() {
        var server = SOArmServer()
        server.user = "deploy"
        server.host = "192.168.0.20"
        server.alternateHost = "100.123.134.28"
        #expect(server.candidateHosts == ["192.168.0.20", "100.123.134.28"])
        #expect(server.isConfigured)
        // 같은 주소를 두 번 적어도 두 번 시도하지 않는다.
        server.alternateHost = " 192.168.0.20 "
        #expect(server.sanitised().candidateHosts == ["192.168.0.20"])
        // 집 주소를 비우고 tailnet 주소만 두는 것도 된다 — 그러면 그 하나만 시도한다.
        server.host = ""
        server.alternateHost = "100.123.134.28"
        #expect(server.candidateHosts == ["100.123.134.28"])
        #expect(server.isConfigured)
    }

    @Test("주소마다 그 주소로 붙는 ssh 명령을 만든다")
    func theTunnelTargetsTheAddressItWasGiven() {
        var server = SOArmServer()
        server.user = "deploy"
        server.host = "192.168.0.20"
        server.alternateHost = "100.123.134.28"
        let home = SOArmTunnel.arguments(for: server, host: "192.168.0.20")
        let away = SOArmTunnel.arguments(for: server, host: "100.123.134.28")
        #expect(home.contains("deploy@192.168.0.20"))
        #expect(away.contains("deploy@100.123.134.28"))
        // 포워딩은 어느 쪽으로 붙든 같은 로컬 포트다. 앱의 나머지는 주소를 모른 채 돈다.
        #expect(home.contains("127.0.0.1:8088:127.0.0.1:8088"))
        #expect(away.contains("127.0.0.1:8088:127.0.0.1:8088"))
        // 주소가 여럿이면 닿지 않는 쪽에서 오래 기다리지 않는다.
        #expect(away.contains("ConnectTimeout=4"))
        var single = server
        single.alternateHost = ""
        #expect(SOArmTunnel.arguments(for: single, host: single.host).contains("ConnectTimeout=8"))
    }

    @Test("어느 쪽으로도 못 닿으면 주소별로 이유를 적는다")
    func bothAddressesFailingSaysWhichIsWhich() {
        var server = SOArmServer()
        server.user = "deploy"
        server.host = "192.168.0.20"
        server.alternateHost = "100.123.134.28"
        let text = SOArmTunnel.failureText(
            [("192.168.0.20", "No route to host"), ("100.123.134.28", "Operation timed out")],
            server: server, key: SOArmTunnelKey()
        )
        // 하나로 뭉뚱그리면 집에서 안 되는 것인지 밖에서 안 되는 것인지 읽을 수 없다.
        #expect(text.contains("192.168.0.20: No route to host"))
        #expect(text.contains("100.123.134.28: Operation timed out"))
        // 주소가 하나뿐이면 그 하나의 조언만 나온다.
        var single = server
        single.alternateHost = ""
        let one = SOArmTunnel.failureText(
            [("192.168.0.20", "ssh: connect to host 192.168.0.20 port 22: No route to host")],
            server: single, key: SOArmTunnelKey()
        )
        #expect(!one.contains("·"))
        #expect(one.contains("로컬 네트워크"))
    }

    @Test("예전 설정 파일에 토큰이 없어도 그대로 읽힌다")
    func oldSettingsFilesStillLoad() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "soarm-legacy-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let legacy = #"{"host":"192.168.0.20","user":"deploy","sshPort":22,"localPort":8088,"remotePort":8088}"#
        try Data(legacy.utf8).write(to: directory.appending(path: "soarm-console.json"))
        let loaded = SOArmServerStore(directory: directory).load()
        #expect(loaded.host == "192.168.0.20")
        #expect(loaded.motionToken.isEmpty)
        // 두 번째 주소도 나중에 늘어난 칸이다. 없다고 파일 전체가 읽히지 않으면, 집 주소와
        // 계정까지 함께 사라진다.
        #expect(loaded.alternateHost.isEmpty)
        #expect(loaded.candidateHosts == ["192.168.0.20"])
    }

    // MARK: 화면 배치

    @Test("3D 칸은 창을 따라 커지고 아래로는 무너지지 않는다")
    func theStageFollowsTheWindow() {
        // 카메라 카드와 같은 규칙이다: 세로 스크롤 안에서는 높이 제안이 무한이라
        // `aspectRatio`가 풀 것이 없으므로, 가로를 재서 높이만 계산한다.
        #expect(SOArmTeleopLayout.stageHeight(for: 0) == SOArmTeleopLayout.minimumStageHeight)
        #expect(SOArmTeleopLayout.stageHeight(for: 400) == SOArmTeleopLayout.minimumStageHeight)
        #expect(SOArmTeleopLayout.stageHeight(for: 1200) == 552)
        #expect(SOArmTeleopLayout.stageHeight(for: 1600) > SOArmTeleopLayout.stageHeight(for: 1200))
        // 위로도 한계를 둔다. 이 칸이 창을 다 먹으면 관절 슬라이더가 한 줄도 보이지 않는다.
        #expect(SOArmTeleopLayout.stageHeight(for: 4000) == 760)
    }

    @Test("카메라도 창을 따라 커진다")
    func theCamerasGrowWithTheWindowToo() {
        // 카메라 칸을 고정 폭으로 두었더니 창을 키워도 3D만 자라고 영상은 그대로였다.
        // 조작하면서 실제로 들여다보는 것은 카메라다.
        let narrow = SOArmTeleopLayout.cameraColumnWidth(for: 900)
        let wide = SOArmTeleopLayout.cameraColumnWidth(for: 1600)
        #expect(wide > narrow)
        // 아래로는 알아볼 수 있을 만큼, 위로는 3D를 밀어내지 않을 만큼.
        #expect(SOArmTeleopLayout.cameraColumnWidth(for: 600) == 240)
        #expect(SOArmTeleopLayout.cameraColumnWidth(for: 4000) == 460)
        // 폭이 아직 측정되기 전에도 납작해지지 않는다.
        #expect(SOArmTeleopLayout.cameraColumnWidth(for: 0) == 260)
    }

    @Test("게이트는 서로 다른 문구를 요구하고 위험한 쪽을 위험하다고 말한다")
    func theGatesAreNotInterchangeable() {
        #expect(SOArmTeleopGate.arm.phrase != SOArmTeleopGate.releaseTorque.phrase)
        #expect(SOArmTeleopGate.arm.isDangerous == false)
        #expect(SOArmTeleopGate.releaseTorque.isDangerous)
        // 토크 해제 안내에는 팔이 떨어진다는 말이 반드시 들어 있어야 한다.
        #expect(SOArmTeleopGate.releaseTorque.copy.contains("떨어집니다"))
    }

    // MARK: 화면 문구

    @Test("서버의 preflight 문장을 무엇을 해야 하는지로 옮긴다")
    func preflightLinesBecomeInstructions() {
        #expect(SOArmVirtualLeaderText.korean("SOARM_MOTION_TOKEN is not set on the server").contains("조작 토큰"))
        #expect(SOArmVirtualLeaderText.korean("SOARM_ENABLE_MOTION=1 is not set").contains("motion gate"))
        #expect(SOArmVirtualLeaderText.korean("Missing follower port: /dev/serial/x").contains("팔로워"))
        // 모르는 문장은 원문을 그대로 남긴다. 조용히 삼키면 서버가 새 게이트를 추가했을 때
        // 이유 없이 막힌 것처럼 보인다.
        #expect(SOArmVirtualLeaderText.korean("Something new the app has not seen")
            == "Something new the app has not seen")
    }
}
#endif
