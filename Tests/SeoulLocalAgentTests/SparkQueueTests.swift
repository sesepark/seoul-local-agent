import Foundation
#if canImport(Testing)
import Testing
@testable import SeoulLocalAgent

@Suite("학습 서버 작업 큐")
struct SparkQueueTests {

    // MARK: 서버가 내놓는 것을 읽는다

    /// 서버(`sparkq`)가 실제로 내놓는 모양 그대로. 손으로 다듬은 JSON으로 시험하면
    /// 서버가 바뀌었을 때 이 시험은 계속 통과하면서 화면만 비어 버린다.
    static let snapshotJSON = """
    {
      "running": {
        "id": "20260906_030000-a1b2",
        "kind": "lerobot-train",
        "title": "act 학습 · soarm101_20260905_092024",
        "state": "running",
        "params": {"dataset": "soarm101_20260905_092024", "policy": "act"},
        "values": {"dataset": "soarm101_20260905_092024", "policy": "act", "steps": 100000},
        "session": "train-soarm101_20260905_092024__act__20260906_0300",
        "created_at": 1780000000.0,
        "started_at": 1780000010.0,
        "live": true,
        "progress_detail": {
          "step": 12000, "steps": 100000, "loss": 0.0421,
          "eta_seconds": 7320, "updated_at": 1780003000.0,
          "log_tail": ["step:12K loss:0.042", "Training:  12%|"]
        }
      },
      "queued": [
        {"id": "20260906_031000-c3d4", "kind": "isaac-rl", "title": "Isaac RL · Isaac-Lift-Cube-SO101-v0",
         "state": "queued", "params": {"task": "Isaac-Lift-Cube-SO101-v0", "num_envs": 4096, "max_iterations": 2500},
         "created_at": 1780000600.0}
      ],
      "recent": [
        {"id": "20260905_220000-e5f6", "kind": "isaac-rl", "title": "Isaac RL · Isaac-Lift-Cube-SO101-v0",
         "state": "failed", "exit_code": 3, "started_at": 1779960000.0, "finished_at": 1779963600.0}
      ],
      "paused": false,
      "gpu_apps": []
    }
    """

    @Test("도는 것·기다리는 것·끝난 것을 한 번에 읽는다")
    func decodesSnapshot() throws {
        let snapshot = try JSONDecoder().decode(
            SparkSnapshot.self, from: Data(Self.snapshotJSON.utf8)
        )
        let running = try #require(snapshot.running)
        #expect(running.id == "20260906_030000-a1b2")
        #expect(running.state == .running)
        #expect(running.live == true)
        #expect(snapshot.queued.count == 1)
        #expect(snapshot.queued.first?.state == .queued)
        #expect(snapshot.recent.first?.state == .failed)
        #expect(snapshot.recent.first?.exitCode == 3)
        #expect(!snapshot.paused)
    }

    @Test("진행은 종류가 달라도 같은 모양으로 온다")
    func decodesProgress() throws {
        let snapshot = try JSONDecoder().decode(
            SparkSnapshot.self, from: Data(Self.snapshotJSON.utf8)
        )
        let progress = try #require(snapshot.running?.progress)
        #expect(progress.step == 12000)
        #expect(progress.steps == 100_000)
        #expect(progress.etaSeconds == 7320)
        #expect(progress.fraction == 0.12)
        #expect(progress.logTail.count == 2)
    }

    @Test("총량을 모르면 진행률을 지어내지 않는다")
    func progressWithoutTotal() {
        // 0%에 붙어 있는 막대는 `진행이 없다`로 읽힌다. 실제로는 아직 몇 스텝인지 로그가
        // 말하지 않은 것뿐이고, 그때는 막대 대신 도는 표시를 써야 한다.
        var progress = SparkProgress()
        progress.step = 10
        #expect(progress.fraction == nil)
        progress.steps = 0
        #expect(progress.fraction == nil)
        progress.steps = 100
        #expect(progress.fraction == 0.1)
        // 로그가 총량보다 큰 값을 말해도 막대는 넘치지 않는다.
        progress.step = 500
        #expect(progress.fraction == 1)
    }

    @Test("작업이 없는 큐도 그대로 읽힌다")
    func decodesEmptySnapshot() throws {
        let empty = """
        {"running": null, "queued": [], "recent": [], "paused": false, "gpu_apps": []}
        """
        let snapshot = try JSONDecoder().decode(SparkSnapshot.self, from: Data(empty.utf8))
        #expect(snapshot.running == nil)
        #expect(snapshot.queued.isEmpty)
        #expect(snapshot.recent.isEmpty)
    }

    @Test("큐 밖에서 GPU를 쓰는 프로세스를 그대로 전한다")
    func decodesForeignApps() throws {
        // 큐가 다음 것을 꺼내지 않는 이유가 `일시정지`인지 `남이 GPU를 쓰는 중`인지는
        // 화면에서 갈라져야 한다. 둘 다 `도는 것 없음`으로 보이면 사람은 큐가 고장 난
        // 줄 안다.
        let json = """
        {"running": null, "queued": [], "recent": [], "paused": false,
         "gpu_apps": [{"pid": "1844773", "name": "/workspace/isaaclab/_isaac_sim/kit/python/bin/python3", "memory_mib": "2988"}]}
        """
        let snapshot = try JSONDecoder().decode(SparkSnapshot.self, from: Data(json.utf8))
        let app = try #require(snapshot.foreignApps.first)
        #expect(app.pid == "1844773")
        #expect(app.shortName == "bin/python3")
    }

    @Test("통합메모리라 비어 오는 칸을 실패로 읽지 않는다")
    func decodesMachineWithMissingMemory() throws {
        // GB10은 nvidia-smi가 GPU 전용 메모리를 `[N/A]`로 답한다. 서버는 그 자리를
        // `null`로 넘기는데, 그것을 오류로 다루면 멀쩡한 기계가 `닿지 않음`이 된다.
        let json = """
        {"ok": true, "host": "spark-86e8",
         "gpu": {"name": "NVIDIA GB10", "memory_used_mib": null, "memory_total_mib": null,
                 "temperature_c": 58, "power_w": 28.39},
         "disk_free_bytes": 3706727972864, "disk_total_bytes": 4031871553536,
         "running": false, "queued": 0, "paused": false}
        """
        let machine = try JSONDecoder().decode(SparkMachine.self, from: Data(json.utf8))
        #expect(machine.isReachable)
        #expect(machine.gpuName == "NVIDIA GB10")
        #expect(machine.memoryUsedMiB == nil)
        #expect(machine.temperatureC == 58)
        #expect(machine.diskFreeBytes == 3_706_727_972_864)
    }

    @Test("사용률 셋을 읽고, 통합메모리를 기계 부하로 삼는다")
    func decodesUtilization() throws {
        let json = """
        {"ok": true, "host": "spark-86e8",
         "gpu": {"name": "NVIDIA GB10", "memory_used_mib": null, "memory_total_mib": null,
                 "temperature_c": 54, "power_w": 20.3, "utilization_percent": 57},
         "cpu_percent": 6.8,
         "memory": {"total_bytes": 130662936576, "used_bytes": 11362852864},
         "disk_free_bytes": 3706678173696, "disk_total_bytes": 4031871553536,
         "running": true, "queued": 0, "paused": false}
        """
        let m = try JSONDecoder().decode(SparkMachine.self, from: Data(json.utf8))
        #expect(m.gpuUtilizationPercent == 57)
        #expect(m.cpuPercent == 6.8)
        #expect(m.ramUsedBytes == 11_362_852_864)
        #expect(m.ramTotalBytes == 130_662_936_576)
        let fraction = try #require(m.ramFraction)
        #expect(abs(fraction - 0.087) < 0.005)
    }

    @Test("사용률이 안 와도(옛 서버) 화면은 막대를 비워 둘 뿐 깨지지 않는다")
    func toleratesMissingUtilization() throws {
        // 없는 값을 0%로 그리면 `안 쓰는 중`으로 잘못 읽힌다. nil이어야 화면이 막대를
        // 흐리게 비워 둔다.
        let json = """
        {"ok": true, "host": "spark-86e8",
         "disk_free_bytes": 1, "disk_total_bytes": 2, "running": false, "queued": 0, "paused": false}
        """
        let m = try JSONDecoder().decode(SparkMachine.self, from: Data(json.utf8))
        #expect(m.gpuUtilizationPercent == nil)
        #expect(m.cpuPercent == nil)
        #expect(m.ramFraction == nil)
        #expect(m.isReachable)
    }

    @Test("닿지 못한 기계는 닿은 것과 구별된다")
    func unreachableMachine() {
        var machine = SparkMachine()
        #expect(!machine.isReachable)
        machine.host = "spark-86e8"
        #expect(machine.isReachable)
        machine.unreachable = "연결이 거부되었습니다"
        #expect(!machine.isReachable)
    }

    // MARK: 작업 종류는 서버가 정한다

    static let kindsJSON = """
    {"kinds": [{
      "kind": "lerobot-train",
      "title": "${policy} 학습 · ${dataset}",
      "label": "데이터셋 학습",
      "detail": "수집한 시연으로 정책을 학습합니다.",
      "icon": "brain.head.profile",
      "fields": [
        {"name": "dataset", "label": "데이터셋", "type": "name", "source": "datasets"},
        {"name": "policy", "label": "정책", "type": "enum", "values": ["act", "smolvla"],
         "default": "act", "labels": {"act": "ACT · 처음부터", "smolvla": "SmolVLA · 옮겨 오기"},
         "presets": {"act": {"steps": 100000}}},
        {"name": "num_envs", "label": "동시 환경 수", "type": "int", "default": 4096, "min": 1, "max": 16384}
      ]
    }]}
    """

    @Test("걸 수 있는 작업은 앱이 아니라 서버가 정한다")
    func decodesKinds() throws {
        // 종류를 앱에 박아 두면 새 실험 하나에 앱 배포가 따라붙는다. 서버에 JSON을 하나
        // 더 놓으면 화면에 항목이 하나 느는 것이 이 구조의 요점이다.
        struct Wrapper: Decodable { var kinds: [SparkJobKind] }
        let spec = try #require(
            try JSONDecoder().decode(Wrapper.self, from: Data(Self.kindsJSON.utf8)).kinds.first
        )
        #expect(spec.kind == "lerobot-train")
        #expect(spec.label == "데이터셋 학습")
        #expect(spec.icon == "brain.head.profile")
        #expect(spec.fields.count == 3)
        #expect(spec.fields[0].source == "datasets")
        #expect(spec.fields[1].type == .enum)
        #expect(spec.fields[1].caption(for: "act") == "ACT · 처음부터")
        // 이름표가 없는 값은 값 자체를 쓴다. 빈 줄을 보여 주는 것보다 낫다.
        #expect(spec.fields[1].caption(for: "pi0") == "pi0")
        #expect(spec.fields[2].type == .int)
        #expect(spec.fields[2].maximum == 16384)
    }

    @Test("기본값은 서버가 준 것을 그대로 채운다")
    func defaultParameters() throws {
        struct Wrapper: Decodable { var kinds: [SparkJobKind] }
        let spec = try #require(
            try JSONDecoder().decode(Wrapper.self, from: Data(Self.kindsJSON.utf8)).kinds.first
        )
        let values = spec.defaultParameters
        #expect(values["policy"] == .text("act"))
        #expect(values["num_envs"] == .number(4096))
        // 기본값이 없는 칸은 비워 둔다 — 화면이 목록에서 첫 번째를 골라 채운다.
        #expect(values["dataset"] == nil)
    }

    @Test("문자열과 정수가 섞여 와도 잃지 않는다")
    func parameterRoundTrip() throws {
        let encoded = try JSONEncoder().encode([
            "policy": SparkParameter.text("act"),
            "num_envs": SparkParameter.number(4096),
        ])
        let decoded = try JSONDecoder().decode([String: SparkParameter].self, from: encoded)
        #expect(decoded["policy"] == .text("act"))
        #expect(decoded["num_envs"] == .number(4096))
        #expect(decoded["num_envs"]?.text == "4096")
        #expect(decoded["policy"]?.number == nil)
    }

    @Test("고른 값을 사람이 읽는 한 줄로 옮긴다")
    func summarisesParameters() throws {
        struct Wrapper: Decodable { var kinds: [SparkJobKind] }
        let kinds = try JSONDecoder().decode(Wrapper.self, from: Data(Self.kindsJSON.utf8)).kinds
        let snapshot = try JSONDecoder().decode(
            SparkSnapshot.self, from: Data(Self.snapshotJSON.utf8)
        )
        let running = try #require(snapshot.running)
        let summary = running.summary(using: kinds)
        // 칸 이름(`policy`)이 아니라 이름표(`정책`)로, 값도 이름표로 옮긴다.
        #expect(summary.contains("데이터셋 soarm101_20260905_092024"))
        #expect(summary.contains("정책 ACT · 처음부터"))
        // 명세를 모르는 종류라도 값은 보여 준다. 빈 줄로 두면 무엇을 거는지 알 수 없다.
        let unknown = snapshot.queued[0].summary(using: kinds)
        #expect(unknown.contains("Isaac-Lift-Cube-SO101-v0"))
    }

    // MARK: 두 서버, 두 열쇠

    @Test("학습 서버 터널은 콘솔 터널과 표식도 열쇠도 다르다")
    func sparkTunnelIsSeparate() {
        // 표식을 나눠 두지 않으면 한쪽을 정리하는 청소가 다른 쪽 터널까지 끊는다.
        #expect(SOArmTunnel.spark.marker != SOArmTunnel.shared.marker)
        #expect(ActiveProcessRegistry.runnerMarkers.contains(SOArmTunnel.sparkMarker))
        #expect(ActiveProcessRegistry.runnerMarkers.contains(SOArmTunnel.marker))
        // 열쇠도 따로다 — 한쪽 접근만 서버에서 회수할 수 있어야 한다.
        #expect(SOArmTunnel.spark.key.privateKey.lastPathComponent == "spark-tunnel-key")
        #expect(SOArmTunnel.shared.key.privateKey.lastPathComponent == "soarm-tunnel-key")
        #expect(SOArmTunnel.spark.key.knownHosts.lastPathComponent == "spark-known-hosts")
    }

    @Test("학습 서버로 가는 ssh 명령은 제 표식과 제 열쇠를 쓴다")
    func buildsSparkTunnelCommand() {
        let server = SOArmServer(
            host: "192.168.0.72", alternateHost: "100.118.183.50",
            user: "sehwan_spark", localPort: 8092, remotePort: 8092
        )
        let arguments = SOArmTunnel.arguments(
            for: server, host: server.host,
            key: SOArmTunnelKey(name: "spark"), marker: SOArmTunnel.sparkMarker
        )
        #expect(arguments.contains("127.0.0.1:8092:127.0.0.1:8092"))
        #expect(arguments.contains("sehwan_spark@192.168.0.72"))
        #expect(arguments.last?.contains(SOArmTunnel.sparkMarker) == true)
        #expect(arguments.last?.contains(SOArmTunnel.marker) == false)
        #expect(arguments.contains { $0.hasSuffix("spark-tunnel-key") })
        #expect(arguments.contains { $0.contains("spark-known-hosts") })
        // 콘솔 터널과 마찬가지로 `~/.ssh`는 건드리지 않는다.
        #expect(!arguments.contains { $0.contains("/.ssh/") })
    }

    @Test("실패 안내는 어느 설정 화면으로 가야 하는지를 말한다")
    func hintPointsAtTheRightSettings() {
        let server = SOArmServer(host: "192.168.0.72", user: "sehwan_spark")
        let spark = SOArmTunnel.hint(
            for: "sehwan_spark@192.168.0.72: Permission denied (publickey).",
            server: server, key: SOArmTunnelKey(name: "spark"), settingsPath: "설정 › 학습 서버"
        )
        #expect(spark.contains("설정 › 학습 서버"))
        #expect(spark.contains("spark-tunnel-key"))
        // 기본값은 그대로 콘솔 서버를 가리킨다 — 기존 화면의 안내가 바뀌면 안 된다.
        let console = SOArmTunnel.hint(for: "Permission denied (publickey).", server: server)
        #expect(console.contains("설정 › 로봇"))
    }

    // MARK: 설정 파일

    @Test("설정이 없으면 이 파이프라인이 실제로 쓰는 포트로 시작한다")
    func storeDefaults() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "spark-store-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = SparkServerStore(directory: directory)
        let fresh = store.load()
        // 빈 칸 네 개를 내미는 대신 포트는 채워 두고 주소만 받는다.
        #expect(fresh.localPort == 8092)
        #expect(fresh.remotePort == 8092)
        #expect(!fresh.isConfigured)

        var server = fresh
        server.host = " 192.168.0.72 "
        server.alternateHost = "100.118.183.50"
        server.user = "sehwan_spark"
        store.save(server)
        let loaded = store.load()
        // 손으로 고쳐졌을 수 있으므로 읽을 때 한 번 다듬는다.
        #expect(loaded.host == "192.168.0.72")
        #expect(loaded.isConfigured)
        #expect(loaded.candidateHosts == ["192.168.0.72", "100.118.183.50"])
    }

    @Test("두 서버의 설정은 서로 다른 파일에 산다")
    func storesDoNotCollide() throws {
        // 한 파일을 나눠 쓰면 학습 서버 주소를 넣는 순간 팔이 붙은 콘솔 서버 주소가
        // 덮인다. 실제로 그렇게 되면 화면에는 `닿지 않습니다`만 남는다.
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "spark-store-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        SparkServerStore(directory: directory).save(
            SOArmServer(host: "192.168.0.72", user: "sehwan_spark", localPort: 8092, remotePort: 8092)
        )
        try SOArmServerStore(directory: directory).save(
            SOArmServer(host: "192.168.0.20", user: "deploy", localPort: 8088, remotePort: 8088)
        )
        #expect(SparkServerStore(directory: directory).load().user == "sehwan_spark")
        #expect(SOArmServerStore(directory: directory).load().user == "deploy")
    }

    // MARK: 사이드바

    @Test("학습 서버는 로봇 묶음의 마지막 화면이다")
    func sidebarPlacement() {
        #expect(AppSection.Group.robot.members.contains(.spark))
        #expect(AppSection.Group.robot.members.last == .spark)
        #expect(AppSection.spark.title == "학습 서버")
        // 수집한 다음에 학습한다. 사이드바 순서가 곧 그 순서여야 한다.
        let robot = AppSection.Group.robot.members
        #expect(robot.firstIndex(of: .soarmData)! < robot.firstIndex(of: .spark)!)
    }
}
#endif
