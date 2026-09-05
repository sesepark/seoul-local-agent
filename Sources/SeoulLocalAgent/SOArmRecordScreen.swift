import SwiftUI

/// 시연을 찍어 LeRobot 데이터셋을 만드는 화면.
///
/// `SO-ARM 101`에서 떼어 냈다. 두 일이 한 화면에 있는 동안에는 찍는 사람이 조작용 손잡이
/// (화질 고르기, 물리 리더 텔레옵 시작, 토크 풀기) 사이에서 찍기용 손잡이를 찾아야 했고,
/// 정작 찍는 동안 알아야 하는 것 — 몇 초 남았는지, 지금 몇 번째인지, 어느 키를 누르면
/// 되는지 — 은 어디에도 없었다.
///
/// **이 화면에는 고르는 자리가 없다.** 카메라는 서버가 못 박은 하나의 프로필로 찍고,
/// 노출과 색온도도 서버가 정한다. VLA 학습용 데이터셋은 회차마다 카메라 설정이 달라지면
/// 못 쓰기 때문이고, 고를 수 있게 두면 언젠가 다르게 찍힌다. 대신 무엇으로 찍히는지를
/// 화면에 그대로 적는다 — 고정이라는 말은 숨긴다는 뜻이 아니다.
struct SOArmRecordView: View {
    @ObservedObject var controller: AutomationController
    var body: some View { SOArmRecordScreen(model: controller.soarm) }
}

struct SOArmRecordScreen: View {
    @ObservedObject var model: SOArmConsoleModel
    @ObservedObject private var cameraPolicy = SOArmCameraPolicy.shared
    @State private var pending: SOArmStartRequest?
    @State private var cameraRowWidth: CGFloat = 0
    /// 이 화면에 들어온 뒤로 수집이 한 번이라도 돌았는가.
    ///
    /// 서버의 `recording.logs`는 지난 실행의 것을 계속 들고 있다. 그것을 그대로 그리면,
    /// 앱을 막 켠 화면에 몇 시간 전 인코더 출력이 가득 차 있어 뭔가 돌고 있는 것처럼
    /// 보인다. 실제로 그 화면을 봤다.
    @State private var ranThisVisit = false

    var body: some View {
        WorkspaceScreen(title: AppSection.soarmRecord.title, subtitle: AppSection.soarmRecord.subtitle) {
            if let message = model.errorMessage {
                DismissibleError(message: message) { model.errorMessage = nil }
                    .transition(.appCard)
            }
            if isRecording { running } else { setup }
            cameras
            logs
        }
        .animation(.appContent, value: model.errorMessage)
        .animation(.appControl, value: isRecording)
        .toolbar { toolbar }
        .sheet(item: $pending) { request in
            SOArmConfirmationSheet(request: request) { model.startRecording() }
        }
        .onChange(of: isRecording) { _, running in if running { ranThisVisit = true } }
        .onAppear { model.recordScreenAppeared() }
        .onDisappear {
            ranThisVisit = false
            model.screenDisappeared()
        }
    }

    private var isRecording: Bool { model.status?.recording.running ?? false }
    private var runtime: SOArmRecordingRuntime? { model.status?.recordingRuntime }

    // MARK: 툴바

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem {
            if isRecording {
                Button("수집 종료", systemImage: "stop.fill") { model.send(.stop) }
                    .tint(.red)
                    .toolbarKeepsTitle()
                    .disabled(model.isBusy)
                    .help(SOArmRecordControl.stop.help)
            }
        }
    }

    // MARK: 찍기 전

    private var setup: some View {
        GroupBox("무엇을 시연할 것인가") {
            VStack(alignment: .leading, spacing: Spacing.m) {
                // 과제 문장은 데이터셋에 그대로 들어가 정책이 읽는 지시문이 된다. 나중에
                // 고칠 수 있는 이름표가 아니라 학습 입력이므로, 시작 전에 한 번 제대로
                // 적는 것 말고 다른 길이 없다.
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    HStack(spacing: Spacing.s) {
                        TextField("무엇을 시연하는지 한 문장으로", text: $model.recordTask, axis: .vertical)
                            .lineLimit(1...3)
                            .textFieldStyle(.roundedBorder)
                        previousTasks
                    }
                    Text("이 문장이 데이터셋의 지시문으로 들어갑니다. 정책이 읽을 문장이므로 `집게로 빨간 블록을 집어 트레이에 넣는다`처럼 한 동작을 끝까지 적습니다.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if !model.knownTasks.isEmpty {
                        Text("같은 과제를 더 찍는 것이라면 **반드시 쓰던 문장을 그대로 고르세요.** 한 글자만 달라도 `수집 데이터`에서 다른 묶음이 되고, 학습할 때 한 과제로 모이지 않습니다.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Divider()

                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Stepper("한 회 최대 \(model.recordSeconds)초", value: $model.recordSeconds, in: 5...300, step: 5)
                    // 사용자가 "30초로 해 두고 빨리 끝났을 때"라고 말한 자리다. 그 기능은
                    // 이미 있었지만 이름이 `성공 저장`이라 시간과 관계있다는 것을 알 길이
                    // 없었다. 최대치라는 말과 함께 여기서 미리 알려 준다.
                    Text("**최대**입니다. 시연이 일찍 끝나면 `지금 저장`을 눌러 남은 시간을 기다리지 않고 다음 회로 넘어갑니다 — 회마다 시간을 다시 정할 필요가 없습니다.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Divider()

                HStack(spacing: Spacing.l) {
                    Button("수집 시작", systemImage: "record.circle") { pending = .recording }
                        .buttonStyle(.borderedProminent)
                        .tint(.snuBlue)
                        .disabled(!canStart)
                        .help(model.status?.followerHeldElsewhere
                              ?? "현장 확인과 확인 문구를 거쳐 시연을 LeRobot 데이터셋으로 찍습니다")
                    Spacer()
                }
                if let held = model.status?.followerHeldElsewhere {
                    Label(held, systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !model.problems.isEmpty {
                    ForEach(model.problems, id: \.self) { line in
                        Label(line, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                lockedProfile
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// 지금까지 쓴 과제 문장 중에서 고르기.
    ///
    /// 과제 문장은 데이터셋을 묶는 열쇠인데, 매번 손으로 치면 `빨간 블록 집기`와
    /// `빨간 블록을 집는다`가 서로 다른 묶음이 된다. 고를 수 있게 두는 것이 문자열을
    /// 같게 유지하는 유일한 길이다 — 나중에 합치는 기능을 만드는 것보다, 애초에 갈라지지
    /// 않게 하는 편이 낫다.
    @ViewBuilder
    private var previousTasks: some View {
        if !model.knownTasks.isEmpty {
            Menu {
                ForEach(model.knownTasks, id: \.self) { task in
                    Button(task) { model.recordTask = task }
                }
            } label: {
                Label("쓰던 과제", systemImage: "chevron.down")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("지금까지 찍은 과제 문장 중에서 고릅니다. 같은 과제는 문장이 글자까지 같아야 한 묶음이 됩니다")
        }
    }

    private var canStart: Bool {
        model.status?.recordReady == true
        && !model.isModeRunning
        && !model.isBusy
        && !model.recordTask.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 무엇으로 찍히는지. 고를 수 없다는 것과 무엇인지 모른다는 것은 다른 일이다.
    ///
    /// 카메라 값은 **서버가 장치에서 되읽은 것**을 적는다. 넣으려 한 값을 적으면, 카메라를
    /// 바꿔 그 컨트롤이 없어진 날 화면만 예전 말을 계속하게 된다.
    private var lockedProfile: some View {
        let profile = model.status?.recordingProfile ?? .recordingDefault
        return Label {
            VStack(alignment: .leading, spacing: 2) {
                Text("카메라 두 대 모두 **\(profile.text) 고정** · \(cameraControlText)")
                Text("고르는 자리를 두지 않습니다. 회차마다 카메라 설정이 달라지면 VLA 학습에 쓸 수 없습니다. 노출만 자동인 것은 이 카메라에 게인 손잡이가 없어 수동으로 얼리면 화면이 절반으로 어두워지기 때문이고, 자동은 이미 최단 노출(5.0ms)에 붙어 있어 흔들림으로 잃는 것이 없습니다.")
                    .foregroundStyle(.secondary)
            }
            .font(.caption)
        } icon: {
            Image(systemName: "lock")
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    /// 서버가 카메라에서 되읽은 수집 컨트롤 한 줄. 아직 한 번도 수집을 시작하지 않았으면
    /// 되읽은 값이 없으므로, 무엇이 될 것인지를 적는다.
    private var cameraControlText: String {
        let scene = model.camera(.scene)
        guard !scene.recordingControls.isEmpty else {
            return "색온도 4600 고정 · 노출 자동 (수집을 시작할 때 걸립니다)"
        }
        var parts: [String] = []
        if let wb = scene.recordingControls["white_balance_temperature"],
           scene.recordingControls["white_balance_automatic"] == 0 {
            parts.append("색온도 \(wb) 고정")
        }
        parts.append(scene.recordingControls["auto_exposure"] == 3 ? "노출 자동" : "노출 고정")
        if scene.recordingControls["exposure_dynamic_framerate"] == 0 {
            parts.append("프레임률 고정")
        }
        if scene.recordingControls["power_line_frequency"] == 2 { parts.append("60Hz") }
        if !scene.recordingControlFailures.isEmpty {
            parts.append("장치가 받지 않은 값: \(scene.recordingControlFailures.joined(separator: ", "))")
        }
        return parts.joined(separator: " · ")
    }

    // MARK: 찍는 동안

    private var running: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: Spacing.m) {
                HStack(spacing: Spacing.s) {
                    ProgressView().controlSize(.small)
                    Text(runtime?.phaseTitle ?? "수집 중").font(.headline)
                    if let dataset = runtime?.datasetName {
                        Text(dataset)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    Spacer()
                }
                if let task = runtime?.task, !task.isEmpty {
                    Text(task).font(.callout).foregroundStyle(.secondary)
                }
                SOArmEpisodeClock(runtime: runtime, fallbackSeconds: model.recordSeconds)
                loopRate
                Divider()
                episodeControls
                shortcutLegend
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// 루프가 실제로 도는 속도.
    ///
    /// 데이터셋은 언제나 30fps로 적힌다 — `timestamp`가 `frame_index / fps`로 계산된
    /// 값이라, 루프가 느렸어도 파일에는 흔적이 남지 않는다. **데이터가 조용히 나빠지는
    /// 유일한 경로가 이것이고**, 그 사실을 알려 주는 것은 이 숫자뿐이다.
    @ViewBuilder
    private var loopRate: some View {
        if let warnings = model.status?.recording.slowLoopWarnings, warnings > 0 {
            Label(
                "이번 수집에서 루프가 목표를 못 따라간 경고가 \(warnings)번 있었습니다. 그만큼 같은 사진이 겹쳐 들어갑니다.",
                systemImage: "exclamationmark.triangle.fill"
            )
            .font(.caption)
            .foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)
        }
        cameraFreshness
        if let hz = runtime?.loopHz, hz > 0 {
            let target = Double(model.status?.recordingProfile.fps ?? 30)
            let slow = hz < target - 2
            Label(
                slow
                ? "루프 \(String(format: "%.1f", hz))Hz · 목표 \(Int(target))Hz를 못 따라가고 있습니다. 이대로 저장되면 파일은 \(Int(target))fps라고 적히지만 실제 시간축은 늘어난 것입니다."
                : "루프 \(String(format: "%.1f", hz))Hz",
                systemImage: slow ? "exclamationmark.triangle.fill" : "metronome"
            )
            .font(.caption)
            .foregroundStyle(slow ? Color.orange : Color.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// 카메라가 실제로 새 프레임을 몇 장 주고 있는가.
    ///
    /// 루프가 30Hz를 지켜도 카메라가 못 따라오면 같은 사진이 겹쳐 들어간다. 그 둘은 다른
    /// 고장이고 화면도 따로 말해야 한다 — 루프가 느린 것은 CPU 문제이고, 카메라가 느린
    /// 것은 조명이나 USB 문제다.
    @ViewBuilder
    private var cameraFreshness: some View {
        let fresh = runtime?.cameraFreshHz ?? [:]
        if !fresh.isEmpty {
            let target = Double(model.status?.recordingProfile.fps ?? 30)
            let worst = fresh.values.min() ?? target
            let slow = worst < target - 3
            Label {
                Text(fresh.keys.sorted().map { name in
                    "\(SOArmCameraName.display(name)) \(String(format: "%.1f", fresh[name] ?? 0))장/초"
                }.joined(separator: " · ")
                + (slow ? " — 카메라가 루프를 못 따라옵니다. 같은 사진이 겹쳐 들어갑니다." : ""))
            } icon: {
                Image(systemName: slow ? "exclamationmark.triangle.fill" : "camera")
            }
            .font(.caption)
            .foregroundStyle(slow ? Color.orange : Color.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// 세 버튼과 그 단축키. 시연을 끝낸 손은 마우스에 있지 않다.
    private var episodeControls: some View {
        HStack(spacing: Spacing.s) {
            // 가장 자주 눌리는 것 하나만 prominent다. 셋을 똑같이 그리면 시연이 끝난
            // 직후에 어느 것인지 매번 읽어야 한다.
            Button("지금 저장", systemImage: SOArmRecordControl.success.symbol) { model.send(.success) }
                .buttonStyle(.borderedProminent)
                .tint(.snuBlue)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(model.isBusy)
                .help("이번 시연을 데이터셋에 저장하고 남은 시간을 기다리지 않고 다음 회로 넘어갑니다 (⌘⏎)")

            Button(SOArmRecordControl.retry.title, systemImage: SOArmRecordControl.retry.symbol) { model.send(.retry) }
                .buttonStyle(.bordered)
                .tint(.orange)
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(model.isBusy)
                .help("이번 시연을 버리고 같은 회를 다시 찍습니다 (⇧⌘R)")

            Spacer()

            Button(SOArmRecordControl.stop.title, systemImage: SOArmRecordControl.stop.symbol) { model.send(.stop) }
                .buttonStyle(.bordered)
                .tint(.red)
                .keyboardShortcut(".", modifiers: .command)
                .disabled(model.isBusy)
                .help("남은 회를 포기하고 수집을 끝냅니다 (⌘.)")
        }
    }

    private var shortcutLegend: some View {
        HStack(spacing: Spacing.l) {
            SOArmShortcutHint(keys: "⌘⏎", label: "지금 저장하고 다음 회")
            SOArmShortcutHint(keys: "⇧⌘R", label: "버리고 다시")
            SOArmShortcutHint(keys: "⌘.", label: "수집 끝내기")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    // MARK: 카메라

    /// 구도를 잡으라고 있는 것이지 고르라고 있는 것이 아니다. 수집이 도는 동안에는 서버가
    /// 카메라를 가져가므로 프리뷰가 열리지 않고, 그 사실도 카드가 스스로 적는다.
    private var cameras: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            HStack(alignment: .top, spacing: Spacing.l) {
                ForEach(SOArmCameraRole.allCases) { role in
                    SOArmCameraCard(
                        role: role,
                        viewportHeight: SOArmCameraLayout.viewportHeight(
                            sharing: cameraRowWidth,
                            aspectRatio: model.camera(role).requested.resolution.aspectRatio
                        ),
                        camera: model.camera(role),
                        recordingProfile: model.status?.recordingProfile ?? .recordingDefault,
                        isRecording: isRecording,
                        showsSettings: false,
                        stream: model.stream(role),
                        enabled: model.connection.isConnected && !isRecording && !cameraPolicy.isOff,
                        isDataOff: cameraPolicy.isOff,
                        start: { model.startPreview(role) },
                        stop: { model.stopPreview(role) },
                        apply: { _ in }
                    )
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { cameraRowWidth = $0 }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: 로그

    /// 지금 돌고 있거나, 이 화면에서 한 번 돌렸거나, 오류로 끝났을 때만 보여 준다.
    /// 오류를 남기는 이유는 그때 로그가 유일한 단서이기 때문이다 — 화면에 들어오기 전에
    /// 실패했더라도 읽을 수 있어야 한다.
    @ViewBuilder
    private var logs: some View {
        let lines = model.status?.recording.logs ?? []
        if (isRecording || ranThisVisit || runtime?.phase == "error") && !lines.isEmpty {
            GroupBox("수집 로그") {
                ScrollView {
                    Text(lines.suffix(40).joined(separator: "\n"))
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 180)
            }
        }
    }
}

// MARK: - 단축키 한 칸

private struct SOArmShortcutHint: View {
    let keys: String
    let label: String

    var body: some View {
        HStack(spacing: Spacing.xs) {
            Text(keys)
                .font(.system(.caption, design: .monospaced))
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
            Text(label)
        }
    }
}

// MARK: - 남은 시간

/// 이번 회가 몇 초 남았는가.
///
/// **서버가 회의 시작 시각을 알려 줄 때만 센다.** 앱이 스스로 세는 길도 있었다 — 시작을
/// 누른 시각에 한 회 길이를 더해 가며 LeRobot의 루프를 흉내 내는 것이다. 그렇게 하면
/// 처음 몇 회는 맞다가 조용히 어긋난다. 회 사이의 정리 시간(`reset_time_s`)은 앱이 모르고,
/// 시간이 다 되어 끝난 회와 `지금 저장`으로 끝난 회의 경계도 앱에서는 구별되지 않기
/// 때문이다. 시계가 어긋나기 시작하면 남은 시간을 보고 손을 떼는 사람이 틀리게 된다.
///
/// 그래서 서버가 값을 주지 않는 동안에는 남은 시간을 적지 않고, 왜 못 적는지를 적는다.
struct SOArmEpisodeClock: View {
    let runtime: SOArmRecordingRuntime?
    /// 서버가 회 길이를 알려 주지 않을 때 화면에 적을 값. 앱이 시작할 때 보낸 값이다.
    let fallbackSeconds: Int
    @State private var now = Date()

    private let tick = Timer.publish(every: 0.25, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            if let started = runtime?.episodeStartedAt, let total = runtime?.episodeSeconds, total > 0 {
                let elapsed = max(0, now.timeIntervalSince(started))
                let left = max(0, Double(total) - elapsed)
                HStack(alignment: .firstTextBaseline, spacing: Spacing.s) {
                    Text("남은 \(Int(left.rounded(.up)))초")
                        .font(.title2.monospacedDigit())
                        .foregroundStyle(left <= 5 ? Color.orange : Color.primary)
                    Text("최대 \(total)초")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    episodeCounter
                }
                ProgressView(value: min(elapsed, Double(total)), total: Double(total))
                    .tint(left <= 5 ? .orange : .snuBlue)
            } else {
                HStack(alignment: .firstTextBaseline, spacing: Spacing.s) {
                    Text("한 회 최대 \(runtime?.episodeSeconds ?? fallbackSeconds)초")
                        .font(.callout)
                    Spacer()
                    episodeCounter
                }
                // 회 사이 정리 구간에서는 시작 시각이 없는 것이 정상이다. 그때까지
                // "서버가 알려 주지 않아서 못 센다"고 적으면, 정상 동작을 한계처럼
                // 읽게 된다 — 실제로 수집을 돌려 보다가 이 문구가 걸렸다.
                Text(runtime?.phase == "resetting"
                     ? "다음 회를 준비하는 동안입니다. 팔을 시작 자세로 되돌려 두세요 — 준비가 끝나면 다시 셉니다."
                     : "남은 시간은 서버가 회의 시작 시각을 알려 줄 때 셉니다. 앱이 혼자 세면 회 사이 정리 시간만큼 조용히 어긋나고, 그 시계를 보고 손을 떼면 틀립니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onReceive(tick) { now = $0 }
    }

    @ViewBuilder
    private var episodeCounter: some View {
        if let index = runtime?.episodeIndex {
            Text("\(index + 1)번째 시연")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }
}
