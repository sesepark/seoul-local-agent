import Foundation
#if canImport(Testing)
import Testing
@testable import SeoulLocalAgent

@Suite("SO-ARM 101 콘솔")
struct SOArmConsoleTests {

    // MARK: 영상 데이터 정책

    @Test("`끔`은 설정이 아니라 연결을 닫는 것이다")
    func offIsNotAProfile() {
        // 프로필이 없다는 것이 요점이다. 값을 하나 골라 두면 어딘가에서 그것을 걸고
        // 스트림을 여는 길이 생기고, 그러면 껐다고 적힌 화면이 데이터를 쓴다.
        #expect(SOArmCameraDataMode.off.profile == nil)
        #expect(SOArmCameraDataMode.off.hourlyBytesPerCamera == nil)
        for mode in SOArmCameraDataMode.allCases where mode != .off {
            #expect(mode.profile != nil)
        }
    }

    @Test("아끼는 쪽일수록 실제로 덜 받는다")
    func loweringTheModeLowersTheBytes() {
        let saver = try? #require(SOArmCameraDataMode.saver.hourlyBytesPerCamera)
        let medium = try? #require(SOArmCameraDataMode.medium.hourlyBytesPerCamera)
        let full = try? #require(SOArmCameraDataMode.full.hourlyBytesPerCamera)
        #expect((saver ?? 0) < (medium ?? 0))
        #expect((medium ?? 0) < (full ?? 0))
        // 절약은 밖에서 쓰라고 만든 값이다. 시간당 100MB를 넘으면 그 목적을 잃는다.
        #expect((saver ?? .max) < 100_000_000)
    }

    @Test("고르는 값은 서버가 실제로 낼 수 있는 모드다")
    func everyModeIsOneTheCameraCanOpen() {
        // 서버는 장치가 가진 목록에 없는 해상도를 400으로 거절한다. 두 카메라 모두
        // 320×240과 640×480을 내주므로 그 둘만 쓴다. 프레임은 장치 최대(30) 이하이면
        // 서버가 받아서 스스로 솎아 낸다.
        let allowed: Set<SOArmCameraResolution> = [
            SOArmCameraResolution(width: 320, height: 240),
            SOArmCameraResolution(width: 640, height: 480),
        ]
        for mode in SOArmCameraDataMode.allCases {
            guard let profile = mode.profile else { continue }
            #expect(allowed.contains(profile.resolution))
            #expect(profile.fps >= 1 && profile.fps <= 30)
        }
    }

    // MARK: 상태 읽기

    /// 서버 `app.py`의 `/api/status`가 실제로 내놓는 모양.
    private static let statusJSON = """
    {
      "motion_enabled": true,
      "camera_roles_confirmed": true,
      "max_relative_target": 2.0,
      "devices": {
        "leader": {"path": "/dev/serial/by-id/usb-leader", "exists": true, "resolved": "/dev/ttyACM0"},
        "follower": {"path": "/dev/serial/by-id/usb-follower", "exists": true, "resolved": "/dev/ttyACM1"},
        "scene_camera": {"path": "/dev/v4l/by-path/scene", "exists": true, "resolved": "/dev/video0"},
        "wrist_camera": {"path": "/dev/v4l/by-path/wrist", "exists": false, "resolved": null}
      },
      "calibrations": {
        "leader": {"path": "/home/deploy/.cache/leader.json", "exists": true},
        "follower": {"path": "/home/deploy/.cache/follower.json", "exists": false}
      },
      "software": {"lerobot": "0.6.1"},
      "cameras": {
        "scene": {"active": true, "clients": 1, "error": null,
                  "requested": {"width": 1280, "height": 720, "fps": 15},
                  "actual": {"width": 1280, "height": 720, "fps": 9},
                  "modes": [{"width": 1920, "height": 1080, "fps": [30]},
                            {"width": 1280, "height": 720, "fps": [30]},
                            {"width": 640, "height": 480, "fps": [30]}]},
        "wrist": {"active": false, "clients": 0, "error": "Cannot open camera",
                  "requested": {"width": 640, "height": 480, "fps": 30},
                  "actual": null,
                  "modes": [{"width": 640, "height": 480, "fps": [30]}]}
      },
      "recording_profile": {"width": 640, "height": 480, "fps": 30},
      "preflight": ["Missing follower port: /dev/serial/by-id/usb-follower"],
      "teleop_preflight": ["Missing follower port: /dev/serial/by-id/usb-follower"],
      "record_preflight": ["SOARM_CAMERA_ROLES_CONFIRMED=1 is not set"],
      "teleoperation": {"running": false, "pid": null, "return_code": 0, "logs": ["teleop stopped"]},
      "recording": {
        "running": true, "pid": 4242, "return_code": null,
        "runtime": {"phase": "recording", "dataset_name": "soarm101_20260830_101500", "task": "블록 집어 트레이에 놓기", "last_control": "right"},
        "logs": ["episode 3/10"]
      },
      "doctor": {
        "checked_at": "2026-08-30T10:00:00+00:00",
        "healthy": true,
        "safe_for_motion_start": false,
        "arms": {
          "leader": {"role": "leader", "healthy": true, "safe_for_motion_start": false,
                     "models": {"1": 777, "2": 777, "3": 777, "4": 777, "5": 777, "6": 777},
                     "torque_enabled": {"shoulder_pan": 1, "gripper": 0},
                     "voltage_raw": {"shoulder_pan": 118, "gripper": 122}, "error": null},
          "follower": {"role": "follower", "healthy": false, "safe_for_motion_start": false,
                       "models": {"1": 777, "2": 777, "3": 777, "4": null, "5": 777, "6": 777},
                       "torque_enabled": {}, "voltage_raw": {}, "error": "Missing motor IDs: [4]"}
        }
      }
    }
    """

    @Test("서버 상태를 화면이 쓰는 값으로 읽는다")
    func parsesStatus() throws {
        let status = try SOArmStatus.parse(Data(Self.statusJSON.utf8))
        #expect(status.motionEnabled)
        #expect(status.cameraRolesConfirmed)
        #expect(status.maxRelativeTarget == 2)
        #expect(status.leaderCalibrated)
        #expect(!status.followerCalibrated)
        #expect(status.lerobotVersion == "0.6.1")
        #expect(status.sceneCamera.active)
        #expect(status.sceneCamera.clients == 1)
        #expect(status.wristCamera.error == "Cannot open camera")
        #expect(status.sceneCamera.requested == SOArmCameraProfile(width: 1280, height: 720, fps: 15))
        #expect(status.sceneCamera.actual?.fps == 9)
        #expect(status.wristCamera.actual == nil)
        #expect(status.recordingProfile == SOArmCameraProfile(width: 640, height: 480, fps: 30))
        #expect(status.teleopPreflight.count == 1)
        #expect(status.recordPreflight == ["SOARM_CAMERA_ROLES_CONFIRMED=1 is not set"])
        #expect(status.recording.running)
        #expect(status.recording.pid == 4242)
        #expect(status.recordingRuntime?.datasetName == "soarm101_20260830_101500")
        #expect(status.recordingRuntime?.phaseTitle == "수집 중")
        #expect(status.doctor?.arms.map(\.role) == ["leader", "follower"])
        #expect(status.doctor?.arms.first?.volts == 11.8)
        #expect(status.doctor?.arms.first?.voltageText == "11.8~12.2V")
        #expect(status.doctor?.arms.first?.respondingMotors == 6)
        #expect(status.doctor?.arms.last?.respondingMotors == 5)
        #expect(status.doctor?.safeForMotionStart == false)
    }

    @Test("진단 전압은 폴링마다 흔들리지 않는다")
    func reportsTheLowestMotorVoltage() throws {
        // 사전에서 아무 값이나 집으면 순서가 정해져 있지 않아 같은 진단 결과가 폴링마다 다른
        // 숫자로 보인다. 가장 낮은 모터로 고정한다.
        let json = """
        {"doctor": {"healthy": true, "safe_for_motion_start": true, "arms": {
          "leader": {"healthy": true, "voltage_raw": {"a": 122, "b": 118, "c": 121, "d": 125, "e": 119, "f": 123}},
          "follower": {"healthy": true, "voltage_raw": {"a": 121, "b": 121}}
        }}}
        """
        let doctor = try SOArmStatus.parse(Data(json.utf8)).doctor
        #expect(doctor?.arms.first?.volts == 11.8)
        #expect(doctor?.arms.last?.volts == 12.1)
        // 순서도 고정이다. 리더가 먼저 나온다.
        #expect(doctor?.arms.map(\.role) == ["leader", "follower"])
    }

    @Test("진단은 관절값이 아니라 항목별 답을 준다")
    func buildsADiagnosisChecklist() throws {
        let server = SOArmServer(host: "192.168.0.20", user: "deploy")
        let status = try SOArmStatus.parse(Data(Self.statusJSON.utf8))
        let checks = SOArmDiagnosis.checks(server: server, status: status)
        func check(_ title: String) -> SOArmCheck? { checks.first { $0.title == title } }

        #expect(check("서버 콘솔")?.state == .ok)
        #expect(check("서버 콘솔")?.summary.contains("LeRobot 0.6.1") == true)
        // 픽스처의 리더는 정상, 팔로워는 모터 하나가 대답하지 않는다.
        #expect(check("리더 팔")?.state == .ok)
        #expect(check("리더 팔")?.summary.contains("모터 6/6 응답") == true)
        #expect(check("팔로워 팔")?.state == .failed)
        #expect(check("팔로워 팔")?.summary.contains("Missing motor IDs") == true)
        // 토크가 걸려 있어 동작을 시작할 수 없다.
        #expect(check("토크 상태")?.state == .warning)
        #expect(check("리더 캘리브레이션")?.state == .ok)
        #expect(check("팔로워 캘리브레이션")?.state == .failed)
        #expect(check("Motion gate")?.state == .ok)
        #expect(check("Wrist 카메라")?.state == .failed)
        #expect(check("카메라 역할 확인")?.state == .ok)
    }

    @Test("진단 전이면 모터에 물어보지 않았다고 말한다")
    func doesNotClaimMotorsAnswered() throws {
        let json = """
        {"motion_enabled": true, "doctor": null,
         "devices": {"leader": {"exists": true}, "follower": {"exists": false}},
         "teleoperation": {"running": false, "logs": []}, "recording": {"running": false, "logs": []}}
        """
        let status = try SOArmStatus.parse(Data(json.utf8))
        let checks = SOArmDiagnosis.checks(server: SOArmServer(host: "b", user: "d"), status: status)
        let leader = checks.first { $0.title == "리더 팔" }
        // 장치 파일이 있다는 것과 모터가 대답한다는 것은 다른 사실이다.
        #expect(leader?.state == .warning)
        #expect(leader?.summary.contains("아직 모터에 물어보지 않았습니다") == true)
        #expect(checks.first { $0.title == "팔로워 팔" }?.state == .failed)
        // 진단을 돌리지 않았으면 토크 줄은 아예 없다. 모르는 것을 초록으로 칠하지 않는다.
        #expect(!checks.contains { $0.title == "토크 상태" })
    }

    @Test("서버에 닿지 못하면 점검표도 그것만 말한다")
    func saysOnlyWhatItKnowsWhenOffline() {
        let checks = SOArmDiagnosis.checks(server: SOArmServer(host: "b", user: "d"), status: nil)
        #expect(checks.count == 1)
        #expect(checks.first?.state == .failed)
    }

    @Test("전압은 한 모터가 아니라 범위로 말한다")
    func showsTheVoltageRange() throws {
        let json = """
        {"doctor": {"arms": {"leader": {"healthy": true, "models": {"1": 777, "2": 777},
         "torque_enabled": {"a": 0, "b": 0}, "voltage_raw": {"a": 118, "b": 124}}}}}
        """
        let arm = try #require(try SOArmStatus.parse(Data(json.utf8)).doctor?.arms.first)
        #expect(arm.voltageText == "11.8~12.4V")
        #expect(arm.respondingMotors == 2)
        #expect(arm.torqueDisabled)
    }

    @Test("에피소드 수는 사람이 정하지 않는다")
    func recordsUntilStopped() {
        // 서버 API가 숫자를 요구하므로 상한을 보내고, 끝내는 것은 `수집 종료` 버튼이다.
        #expect(SOArmClient.openEndedEpisodes == 1000)
    }

    @Test("도는 모드가 곧 화면의 모드다")
    func derivesMode() throws {
        let status = try SOArmStatus.parse(Data(Self.statusJSON.utf8))
        // 녹화가 돌고 있으면 텔레옵 여부와 무관하게 수집 중이다.
        #expect(status.mode == .recording)
        #expect(status.visibleLogs == ["episode 3/10"])
        // preflight가 남아 있는 한 두 시작 모두 막힌다.
        #expect(!status.teleopReady)
        #expect(!status.recordReady)
    }

    @Test("게이트가 전부 열리면 시작 가능으로 읽는다")
    func readsReadyState() throws {
        let json = """
        {"motion_enabled": true, "teleop_preflight": [], "record_preflight": [],
         "teleoperation": {"running": false, "logs": []}, "recording": {"running": false, "logs": []}}
        """
        let status = try SOArmStatus.parse(Data(json.utf8))
        #expect(status.teleopReady)
        #expect(status.recordReady)
        #expect(status.mode == .idle)
    }

    /// 서버가 필드를 빼거나 더해도 화면이 통째로 비어서는 안 된다. `doctor`는 진단을 한 번도
    /// 돌리지 않은 서버에서 실제로 `null`로 온다.
    @Test("모르는 키와 빠진 키를 견딘다")
    func toleratesSparseJSON() throws {
        let json = """
        {"motion_enabled": false, "doctor": null, "some_future_field": {"a": 1},
         "teleoperation": {"running": true, "pid": 7, "logs": ["a", "b"]}}
        """
        let status = try SOArmStatus.parse(Data(json.utf8))
        #expect(status.doctor == nil)
        #expect(status.mode == .teleoperation)
        #expect(status.teleop.logs == ["a", "b"])
        #expect(status.teleopPreflight.isEmpty)
        #expect(!status.motionEnabled)
        #expect(status.recordingRuntime == nil)
    }

    @Test("JSON이 아니면 읽기를 포기한다")
    func rejectsNonJSON() {
        #expect(throws: SOArmError.self) { try SOArmStatus.parse(Data("<html>".utf8)) }
    }

    // MARK: 녹화 제어

    /// 서버 `record_manager.control()`은 `right` · `left` · `esc`만 받고 나머지는 409로
    /// 거절한다. 화면 문구를 그대로 보내면 수집 중 버튼 셋이 전부 실패한다.
    @Test("제어 버튼은 서버가 아는 키를 보낸다")
    func sendsKeysTheServerAccepts() {
        #expect(SOArmRecordControl.success.rawValue == "right")
        #expect(SOArmRecordControl.retry.rawValue == "left")
        #expect(SOArmRecordControl.stop.rawValue == "esc")
        #expect(Set(SOArmRecordControl.allCases.map(\.rawValue)) == ["right", "left", "esc"])
        #expect(SOArmRecordControl.success.title == "성공 저장")
    }

    @Test("확인 문구는 서버가 비교하는 문자열 그대로다")
    func usesExactConfirmationPhrases() {
        #expect(SOArmClient.teleopConfirmation == "START SOARM101")
        #expect(SOArmClient.recordConfirmation == "RECORD SOARM101")
    }

    // MARK: 오류

    @Test("HTTP 코드마다 다른 뜻으로 옮긴다")
    func mapsHTTPStatusCodes() {
        let detail = Data(#"{"detail":"Stop recording before teleoperation"}"#.utf8)
        #expect(SOArmClient.error(status: 400, body: detail) == .confirmationMismatch("Stop recording before teleoperation"))
        #expect(SOArmClient.error(status: 409, body: detail) == .blocked("Stop recording before teleoperation"))
        #expect(SOArmClient.error(status: 500, body: detail) == .serverFailure("Stop recording before teleoperation"))
        // 본문이 없으면 코드라도 남긴다.
        #expect(SOArmClient.error(status: 409, body: Data()) == .blocked("HTTP 409"))
    }

    /// 409는 잠깐 기다렸다 다시 부른다고 풀리지 않는다. 재시도 대상은 연결 실패뿐이다.
    @Test("상태 문제는 재시도 대상이 아니다")
    func doesNotRetryStateProblems() {
        #expect(!SOArmError.blocked("gate").isRetryable)
        #expect(!SOArmError.confirmationMismatch("").isRetryable)
        #expect(!SOArmError.serverFailure("").isRetryable)
        #expect(SOArmError.unreachable("연결 거부").isRetryable)
        #expect(SOArmError.tunnelFailed("키 없음").isRetryable)
    }

    @Test("500은 물리 전원 차단을 함께 안내한다")
    func namesThePhysicalCutoff() {
        let message = SOArmError.serverFailure("stop failed").errorDescription ?? ""
        #expect(message.contains("물리 전원"))
    }

    // MARK: preflight 문장

    @Test("막힌 이유를 아는 만큼 한국어로 옮긴다")
    func translatesPreflight() {
        #expect(SOArmPreflightText.korean("SOARM_ENABLE_MOTION=1 is not set").contains("motion gate"))
        #expect(SOArmPreflightText.korean("SOARM_CAMERA_ROLES_CONFIRMED=1 is not set").contains("카메라 역할"))
        #expect(SOArmPreflightText.korean("Missing leader port: /dev/serial/by-id/x").contains("리더"))
        #expect(SOArmPreflightText.korean("Invalid follower calibration: missing range").contains("팔로워"))
        // 모르는 문장은 삼키지 않는다. 서버가 게이트를 늘렸을 때 이유 없이 막힌 것처럼
        // 보이는 것이 가장 나쁘다.
        #expect(SOArmPreflightText.korean("Some new gate the app has never seen") == "Some new gate the app has never seen")
    }

    // MARK: MJPEG 파싱

    private static func multipart(_ payloads: [String]) -> Data {
        var data = Data()
        for payload in payloads {
            data.append(Data("--frame\r\nContent-Type: image/jpeg\r\n\r\n".utf8))
            data.append(Data(payload.utf8))
            data.append(Data("\r\n".utf8))
        }
        return data
    }

    @Test("경계 사이의 프레임을 꺼내고 마지막 조각은 버퍼에 남긴다")
    func extractsFrames() {
        var buffer = Self.multipart(["AAA", "BBBB", "CC"])
        let frames = MJPEGReader.extractFrames(from: &buffer)
        // 프레임의 끝은 다음 경계로 정하므로, 마지막 하나는 다음 프레임이 올 때까지 남는다.
        #expect(frames.map { String(decoding: $0, as: UTF8.self) } == ["AAA", "BBBB"])
        #expect(String(decoding: buffer, as: UTF8.self).contains("CC"))
    }

    @Test("프레임이 청크 중간에서 잘려 와도 이어 붙인다")
    func survivesSplitChunks() {
        let whole = Self.multipart(["HELLO", "WORLD", "!"])
        var buffer = Data()
        var frames: [Data] = []
        // 7바이트씩 나눠 넣는다. 경계와 헤더와 본문이 전부 조각난다.
        for start in stride(from: 0, to: whole.count, by: 7) {
            let end = min(start + 7, whole.count)
            buffer.append(whole[whole.startIndex.advanced(by: start)..<whole.startIndex.advanced(by: end)])
            frames.append(contentsOf: MJPEGReader.extractFrames(from: &buffer))
        }
        #expect(frames.map { String(decoding: $0, as: UTF8.self) } == ["HELLO", "WORLD"])
    }

    @Test("앞에 붙은 쓰레기를 건너뛴다")
    func skipsLeadingNoise() {
        var buffer = Data("garbage before the stream".utf8)
        buffer.append(Self.multipart(["ONE", "TWO"]))
        let frames = MJPEGReader.extractFrames(from: &buffer)
        #expect(frames.map { String(decoding: $0, as: UTF8.self) } == ["ONE"])
    }

    @Test("경계를 못 찾은 채 무한정 쌓지 않는다")
    func capsTheBuffer() {
        var buffer = Data(repeating: 0x41, count: MJPEGReader.bufferLimit + 1)
        _ = MJPEGReader.extractFrames(from: &buffer)
        #expect(buffer.isEmpty)
    }

    // MARK: 터널

    @Test("ssh 명령에 종료 보장과 포워딩이 들어 있다")
    func buildsTunnelCommand() {
        let server = SOArmServer(host: "192.168.0.20", user: "deploy", sshPort: 2222, localPort: 8088, remotePort: 8088)
        let arguments = SOArmTunnel.arguments(for: server, host: server.host)
        #expect(arguments.contains("-L"))
        #expect(arguments.contains("127.0.0.1:8088:127.0.0.1:8088"))
        #expect(arguments.contains("deploy@192.168.0.20"))
        #expect(arguments.contains("2222"))
        // 포워딩을 못 열면 붙어 있어 봐야 소용없다.
        #expect(arguments.contains("ExitOnForwardFailure=yes"))
        // 암호를 물으며 멈추는 대신 즉시 실패해야 한다. 창 없는 자식의 프롬프트는 보이지 않는다.
        #expect(arguments.contains("BatchMode=yes"))
        // `-N`이면 stdin을 읽지 않아 앱이 강제 종료돼도 ssh가 남는다.
        #expect(!arguments.contains("-N"))
        #expect(arguments.last?.contains("cat > /dev/null") == true)
        // 남은 터널을 다음 실행이 찾아 죽일 표식.
        #expect(arguments.last?.contains(SOArmTunnel.marker) == true)
        #expect(ActiveProcessRegistry.runnerMarkers.contains(SOArmTunnel.marker))
        // `~/.ssh`는 앱이 읽을 수 없다. 앱 폴더의 열쇠만 쓰고, 읽지도 못할 열쇠를 시도하지 않는다.
        #expect(arguments.contains("IdentitiesOnly=yes"))
        #expect(arguments.contains { $0.hasSuffix("soarm-tunnel-key") })
        #expect(arguments.contains { $0.hasPrefix("UserKnownHostsFile=") && $0.contains("soarm-known-hosts") })
        #expect(!arguments.contains { $0.contains("/.ssh/") })
    }

    @Test("ssh가 실패하면 무엇을 해야 하는지까지 말한다")
    func addsActionableSSHHints() {
        let server = SOArmServer(host: "192.168.0.20", user: "deploy")
        // 이 기능을 처음 켤 때 거의 반드시 만나는 상태. 원문만으로는 무엇을 고칠지 알 수 없다.
        let denied = SOArmTunnel.hint(for: "deploy@192.168.0.20: Permission denied (publickey,password).", server: server)
        #expect(denied.contains("Permission denied"))
        // 사용자의 평소 열쇠가 아니라 앱 전용 열쇠를 등록해야 한다.
        #expect(denied.contains("ssh-copy-id"))
        #expect(denied.contains("soarm-tunnel-key.pub"))
        #expect(denied.contains("deploy@192.168.0.20"))

        let hostKey = SOArmTunnel.hint(for: "Host key verification failed.", server: server)
        #expect(hostKey.contains("host key"))

        let unreachable = SOArmTunnel.hint(for: "ssh: connect to host 192.168.0.20 port 22: No route to host", server: server)
        #expect(unreachable.contains("로컬 네트워크"))
        // 주소가 하나뿐이면 두 번째 주소를 넣으라고 알려 준다. 집 밖에서 이 화면을 처음
        // 만났을 때 무엇을 해야 하는지가 여기 말고는 적혀 있지 않다.
        #expect(unreachable.contains("집 밖에서 쓸 주소"))
        var twoAddresses = server
        twoAddresses.alternateHost = "100.1.2.3"
        let both = SOArmTunnel.hint(for: "ssh: connect to host 192.168.0.20 port 22: No route to host", server: twoAddresses)
        #expect(both.contains("Tailscale"))
        #expect(!both.contains("집 밖에서 쓸 주소"))

        // 아는 것이 없으면 원문을 그대로 둔다. 지어낸 조언이 틀린 조언보다 낫지 않다.
        let unknown = "ssh: something nobody has seen before"
        #expect(SOArmTunnel.hint(for: unknown, server: server) == unknown)
    }

    @Test("앱 전용 열쇠를 스스로 만들고 소유자만 읽게 둔다")
    func createsItsOwnTunnelKey() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appending(path: "soarm-key-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let key = SOArmTunnelKey(directory: directory)
        #expect(!key.exists)
        #expect(try key.ensureExists())
        #expect(key.exists)
        #expect(key.publicKeyText.hasPrefix("ssh-ed25519 "))
        // 두 번째 호출은 이미 있는 열쇠를 그대로 둔다. 열쇠가 바뀌면 서버 등록이 무효가 된다.
        let before = key.publicKeyText
        #expect(try key.ensureExists() == false)
        #expect(key.publicKeyText == before)
        let permissions = try FileManager.default.attributesOfItem(atPath: key.privateKey.path)[.posixPermissions] as? NSNumber
        #expect(permissions?.int16Value == 0o600)
        #expect(key.authorizationCommand(for: SOArmServer(host: "box", user: "deploy")).contains("ssh-copy-id"))
        #expect(key.authorizationCommand(for: SOArmServer(host: "box", user: "deploy", sshPort: 2222)).contains("-p 2222"))
    }

    // MARK: 수집한 데이터셋

    @Test("데이터셋 목록과 에피소드를 서버가 준 모양대로 읽는다")
    func readsDatasets() throws {
        // 서버 `/api/datasets`와 `/api/datasets/{name}`이 실제로 내놓는 모양.
        let list = """
        [{"name": "selftest_fixture", "episodes": 3, "frames": 60, "fps": 10,
          "robot_type": "so101_follower", "codebase_version": "v3.0",
          "cameras": ["observation.images.scene", "observation.images.wrist"],
          "size_bytes": 92695, "recorded_at": 1788107876.799208}]
        """
        let summaries = try SOArmDatasetSummary.list(Data(list.utf8))
        #expect(summaries.count == 1)
        #expect(summaries[0].episodes == 3)
        #expect(summaries[0].seconds == 6)
        #expect(summaries[0].cameras.count == 2)
        #expect(summaries[0].recordedAt != nil)

        let detail = """
        {"name": "selftest_fixture", "episodes": 3, "frames": 60, "fps": 10,
         "cameras": ["observation.images.scene"],
         "episodes_detail": [
           {"index": 0, "task": "블록 집기", "frames": 20, "videos": {
             "observation.images.scene": {"chunk_index": 0, "file_index": 0,
               "from_seconds": 0.0, "to_seconds": 2.0,
               "url": "/api/datasets/selftest_fixture/video/observation.images.scene/0/0?from=0.000&to=2.000"}}},
           {"index": 1, "task": "블록 집기", "frames": 20, "videos": {}}
         ]}
        """
        let parsed = try SOArmDatasetDetail.parse(Data(detail.utf8))
        #expect(parsed.episodes.count == 2)
        #expect(parsed.episodes[0].seconds == 2)
        let video = try #require(parsed.episodes[0].videos["observation.images.scene"])
        // v3는 여러 에피소드를 한 파일에 이어 붙이므로 구간이 있어야 그 하나만 재생할 수 있다.
        #expect(video.fromSeconds == 0)
        #expect(video.toSeconds == 2)
        #expect(video.path.hasSuffix("?from=0.000&to=2.000"))
        // 영상이 없는 에피소드도 목록에서 빠지지 않는다.
        #expect(parsed.episodes[1].videos.isEmpty)
    }

    @Test("영상 주소는 loopback 아래로만 만든다")
    func buildsVideoURLsUnderTheTunnel() {
        let client = SOArmClient(baseURL: SOArmServer(host: "b", user: "d").baseURL)
        #expect(client.videoURL("/api/datasets/x/video/k/0/0").absoluteString
                == "http://127.0.0.1:8088/api/datasets/x/video/k/0/0")
        // 구간이 붙은 주소를 경로로 인코딩해 버리면 서버가 그런 파일은 없다고 답한다.
        #expect(client.videoURL("/api/datasets/x/video/k/0/0?from=2.000&to=4.000").absoluteString
                == "http://127.0.0.1:8088/api/datasets/x/video/k/0/0?from=2.000&to=4.000")
    }

    @Test("카메라 이름과 길이를 사람이 읽는 말로 바꾼다")
    func formatsForReading() {
        #expect(SOArmCameraName.display("observation.images.scene") == "작업공간")
        #expect(SOArmCameraName.display("observation.images.wrist") == "손목")
        // 모르는 키는 지어내지 않고 마지막 마디를 그대로 쓴다.
        #expect(SOArmCameraName.display("observation.images.overhead") == "overhead")
        #expect(SOArmFormat.duration(0) == "0초")
        #expect(SOArmFormat.duration(42) == "42초")
        #expect(SOArmFormat.duration(120) == "2분")
        #expect(SOArmFormat.duration(95) == "1분 35초")
    }

    @Test("주소는 언제나 loopback이다")
    func alwaysTargetsLoopback() {
        let server = SOArmServer(host: "192.168.0.20", user: "deploy", localPort: 18088)
        #expect(server.baseURL.absoluteString == "http://127.0.0.1:18088")
        #expect(SOArmClient(baseURL: server.baseURL).cameraURL("scene").absoluteString
                == "http://127.0.0.1:18088/api/cameras/scene.mjpg")
    }

    @Test("손으로 고쳐진 설정 파일을 걸러 낸다")
    func sanitisesSettings() {
        let server = SOArmServer(host: "  box  ", user: " deploy ", sshPort: 0, localPort: 70000, remotePort: -3).sanitised()
        #expect(server.host == "box")
        #expect(server.user == "deploy")
        #expect(server.sshPort == 1)
        #expect(server.localPort == 65535)
        #expect(server.remotePort == 1)
        #expect(server.isConfigured)
        #expect(!SOArmServer().isConfigured)
    }

    @Test("못 닿은 이유도 한국어로 말한다")
    func explainsNetworkFailuresInKorean() {
        // 화면의 나머지가 전부 한국어인데 실패 이유만 영어면, 그 한 줄이 정확히 읽혀야 할
        // 상황에서 가장 안 읽힌다.
        #expect(SOArmClient.reason(for: URLError(.cannotConnectToHost)).contains("응답하지 않습니다"))
        #expect(SOArmClient.reason(for: URLError(.timedOut)).contains("제한 시간"))
        #expect(SOArmClient.reason(for: URLError(.cannotFindHost)).contains("주소"))
        // 모르는 것은 지어내지 않고 원문을 남긴다.
        let unknown = SOArmError.badResponse("무언가")
        #expect(SOArmClient.reason(for: unknown) == unknown.localizedDescription)
    }

    @Test("파트 뒤에 붙은 줄바꿈을 떼어 낸다")
    func trimsPartTrailer() {
        // `URLSession`이 multipart를 스스로 풀어 줄 때 파트 본문에는 서버가 붙인 `\r\n`이
        // 남는다. 그대로 두면 JPEG이 아닌 바이트가 이미지 데이터에 섞여 넘어간다.
        #expect(MJPEGReader.trimmedPart(Data("JPEG\r\n".utf8)) == Data("JPEG".utf8))
        #expect(MJPEGReader.trimmedPart(Data("JPEG".utf8)) == Data("JPEG".utf8))
        #expect(MJPEGReader.trimmedPart(Data()) == Data())
    }

    @Test("설정은 이 기기 파일에만, 소유자만 읽게 저장한다")
    func savesSettingsPrivately() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appending(path: "soarm-settings-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SOArmServerStore(directory: directory)
        #expect(!store.load().isConfigured)
        try store.save(SOArmServer(host: "box", user: "deploy"))
        #expect(store.load().host == "box")
        let permissions = try FileManager.default.attributesOfItem(atPath: store.debugURL.path)[.posixPermissions] as? NSNumber
        #expect(permissions?.int16Value == 0o600)
    }

    // MARK: 카메라 화질·프레임

    @Test("고를 수 있는 화질은 서버가 장치에서 읽어 온 목록이다")
    func readsCameraModesFromTheDevice() throws {
        let status = try SOArmStatus.parse(Data(Self.statusJSON.utf8))
        let scene = status.sceneCamera
        #expect(scene.resolutions.map(\.text) == ["1920×1080", "1280×720", "640×480"])
        #expect(scene.deviceFrameRate(for: SOArmCameraResolution(width: 1280, height: 720)) == 30)
        // 장치가 모르는 해상도를 물으면 지금 걸린 값을 돌려준다. 목록에 없는 것을 고를 수
        // 있는 경로는 없지만, 그때 0fps를 만들어 서버에 보내는 일은 없어야 한다.
        #expect(scene.deviceFrameRate(for: SOArmCameraResolution(width: 999, height: 999)) == 15)
    }

    @Test("카드 비율은 고른 해상도를 따른다")
    func cardFollowsTheChosenResolution() {
        // 나눗셈 순서가 달라 마지막 자리가 어긋나는 것은 여기서 볼 일이 아니다.
        func isClose(_ value: CGFloat, _ expected: CGFloat) -> Bool { abs(value - expected) < 1e-9 }
        #expect(isClose(SOArmCameraResolution(width: 640, height: 480).aspectRatio, 4.0 / 3.0))
        #expect(isClose(SOArmCameraResolution(width: 1280, height: 720).aspectRatio, 16.0 / 9.0))
        // 높이가 0인 응답이 와도 카드가 무한한 높이로 자라지 않는다.
        #expect(isClose(SOArmCameraResolution(width: 640, height: 0).aspectRatio, 4.0 / 3.0))
    }

    @Test("카드는 창 폭을 나눠 갖고 높이는 거기서 나온다")
    func cardHeightFollowsTheWindow() {
        // 두 장이 간격 하나를 사이에 두고 줄을 나눠 갖는다. 폭이 늘면 높이도 같이 는다 —
        // 위쪽 한계는 없다.
        #expect(SOArmCameraLayout.viewportHeight(sharing: 872, aspectRatio: 4.0 / 3.0) == 321)
        #expect(SOArmCameraLayout.viewportHeight(sharing: 1480, aspectRatio: 4.0 / 3.0) == 549)
        // 16:9를 고르면 같은 폭에서 카드가 낮아진다.
        #expect(SOArmCameraLayout.viewportHeight(sharing: 872, aspectRatio: 16.0 / 9.0) == 241)
        // 폭을 아직 재지 못했을 때 카드가 납작해지지 않는다.
        #expect(SOArmCameraLayout.viewportHeight(sharing: 0, aspectRatio: 4.0 / 3.0)
                == SOArmCameraLayout.minimumViewportHeight)
    }

    @Test("실제로 나오는 값과 고른 값을 따로 적는다")
    func tellsRequestedFromActual() throws {
        let status = try SOArmStatus.parse(Data(Self.statusJSON.utf8))
        // 15fps를 걸어 두었지만 실제로 나가는 것은 9fps다. 화면이 15라고 적으면 안 된다.
        #expect(status.sceneCamera.requested.text == "1280×720 · 15fps")
        #expect(status.sceneCamera.actual?.text == "1280×720 · 9fps")
        // 서버가 아직 세지 못했을 때는 프레임 자리를 비운다.
        let counting = SOArmCameraProfile(width: 640, height: 480, fps: 0)
        #expect(counting.text == "640×480")
    }

    @Test("서버가 카메라 설정을 안 보내도 예전 응답을 읽는다")
    func toleratesAServerWithoutCameraSettings() throws {
        // 앱이 서버보다 먼저 갱신될 수 있다. 그때는 수집 프로필 기본값으로 서고, 화질 메뉴는
        // 고를 것이 없어 비활성으로 남는다.
        let json = """
        {"cameras": {"scene": {"active": false, "clients": 0, "error": null}}}
        """
        let status = try SOArmStatus.parse(Data(json.utf8))
        #expect(status.sceneCamera.requested == SOArmCameraProfile.recordingDefault)
        #expect(status.sceneCamera.modes.isEmpty)
        #expect(status.sceneCamera.resolutions.isEmpty)
        #expect(status.recordingProfile == SOArmCameraProfile.recordingDefault)
    }
}

/// 실제로 도는 콘솔에 붙어 클라이언트 계약을 끝까지 확인한다.
///
/// `SOARM_TEST_CONSOLE=http://127.0.0.1:8088 scripts/run-tests.sh`처럼 주소를 줄 때만
/// 돈다. 하드웨어가 없는 평소 실행에서는 건너뛴다. 서버를 실제로 움직이므로 로봇이 붙어
/// 있는 콘솔에는 절대 겨누지 말 것 — 이 스위트는 팔을 시작시킨다.
@Suite("SO-ARM 101 콘솔 · 실제 서버", .serialized,
       .enabled(if: ProcessInfo.processInfo.environment["SOARM_TEST_CONSOLE"] != nil))
struct SOArmLiveConsoleTests {
    private var client: SOArmClient {
        SOArmClient(baseURL: URL(string: ProcessInfo.processInfo.environment["SOARM_TEST_CONSOLE"]!)!)
    }

    @Test("시작·제어·중지가 서버가 아는 말로 오간다")
    func walksTheWholeFlow() async throws {
        _ = try? await client.stopActiveMode()

        // 확인 문구가 틀리면 시작하지 않는다.
        await #expect(throws: SOArmError.self) {
            try await client.startTeleoperation(confirmation: "start soarm101")
        }
        #expect(try await client.status().mode == .idle)

        try await client.startTeleoperation(confirmation: SOArmClient.teleopConfirmation)
        #expect(try await client.status().mode == .teleoperation)

        // 텔레옵이 도는 동안에는 수집도 진단도 막힌다. 장치 소유자는 하나뿐이다.
        await #expect(throws: SOArmError.self) {
            try await client.startRecording(
                confirmation: SOArmClient.recordConfirmation, task: "겹친 시작", episodes: 1, episodeSeconds: 5
            )
        }
        await #expect(throws: SOArmError.self) { _ = try await client.doctor() }

        try await client.stopTeleoperation()
        #expect(try await client.status().mode == .idle)

        try await client.startRecording(
            confirmation: SOArmClient.recordConfirmation,
            task: "블록을 집어 트레이에 놓기", episodes: 2, episodeSeconds: 10
        )
        let recording = try await client.status()
        #expect(recording.mode == .recording)
        #expect(recording.recordingRuntime?.task == "블록을 집어 트레이에 놓기")
        #expect(recording.recordingRuntime?.datasetName?.isEmpty == false)

        // 세 버튼 모두 서버가 받아야 한다. 여기서 409가 나면 화면 문구를 그대로 보낸 것이다.
        try await client.control(.success)
        try await client.control(.retry)
        #expect(try await client.status().recordingRuntime?.lastControl == "left")
        try await client.control(.stop)
        #expect(try await client.status().mode == .idle)

        // 비상 중지는 무엇이 돌고 있든 내린다.
        try await client.startTeleoperation(confirmation: SOArmClient.teleopConfirmation)
        try await client.stopActiveMode()
        #expect(try await client.status().mode == .idle)

        let doctor = try await client.doctor()
        #expect(doctor.arms.count == 2)
        #expect(try await client.status().doctor?.checkedAt == doctor.checkedAt)
    }
}
#endif

