import SwiftUI
import AppKit
import WebKit

/// SO-ARM 101 화면.
///
/// 간추린 쪽이다. 서버의 웹 콘솔은 관찰·텔레옵·데이터의 세 화면에 상태를 빠짐없이 펼쳐
/// 놓지만, 평소 운용에 필요한 것은 카메라 두 장과 시작·중지, 그리고 무엇이 막혔는지다.
/// 나머지는 `전체화면`이 기존 콘솔을 그대로 띄워 준다.
struct SOArmView: View {
    @ObservedObject var controller: AutomationController

    var body: some View {
        SOArmWorkspace(model: controller.soarm)
    }
}

private struct SOArmWorkspace: View {
    @ObservedObject var model: SOArmConsoleModel
    @Environment(\.openSettings) private var openSettings
    @State private var pending: SOArmStartRequest?
    /// 카메라 두 장이 나눠 쓸 수 있는 가로 폭. 창을 줄이고 늘릴 때마다 다시 들어온다.
    @State private var cameraRowWidth: CGFloat = 0

    var body: some View {
        WorkspaceScreen(title: AppSection.soarm.title, subtitle: AppSection.soarm.subtitle) {
            problems
            if let message = model.errorMessage {
                DismissibleError(message: message) { model.errorMessage = nil }
                    .transition(.appCard)
            }
            diagnosis
            cameras
            recording
            logs
            safetyNote
        }
        .animation(.appContent, value: model.problems)
        .animation(.appContent, value: model.errorMessage)
        .animation(.appControl, value: model.mode)
        .animation(.appContent, value: model.showsDiagnosis)
        .toolbar { toolbar }
        // While the console covers the window there must be exactly one way out
        // of it. Leaving this toolbar up put a second 전체화면 button in the title
        // bar over a screen that was already full screen.
        .toolbar(model.isConsoleFullScreen ? .hidden : .visible, for: .windowToolbar)
        .sheet(item: $pending) { request in
            SOArmConfirmationSheet(request: request) {
                switch request {
                case .teleoperation: model.startTeleoperation()
                case .recording: model.startRecording()
                }
            }
        }
        .onAppear { model.screenAppeared() }
        .onDisappear { model.screenDisappeared() }
    }

    // MARK: 툴바

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem {
            // `fixedSize`가 없으면 창이 좁아졌을 때 툴바가 이 글자를 눌러 캡슐 안에서
            // 찌그러뜨린다. 상태는 줄여 쓸 수 없는 정보라 자리를 지키게 두고, 길게 설명할
            // 말은 툴팁으로 보낸다.
            Label(model.badge.text, systemImage: "circle.fill")
                .font(.caption)
                .labelStyle(.titleAndIcon)
                .imageScale(.small)
                .lineLimit(1)
                .fixedSize()
                .foregroundStyle(model.badge.isAlarming ? Color.orange : .secondary)
                .help(model.badgeHelp)
        }
        ToolbarItem {
            Button("환경 진단", systemImage: "stethoscope") { model.runDoctor() }
                .disabled(!model.connection.isConnected || model.isModeRunning || model.isBusy)
                .help(model.isModeRunning
                      ? "모드가 도는 동안에는 serial bus를 읽을 수 없습니다"
                      : "모터 ID·전압·토크 상태를 읽기만 합니다. 동작 명령은 보내지 않습니다")
        }
        ToolbarSpacer(.flexible)
        ToolbarItem {
            Button("모드 중지", systemImage: "stop.circle.fill") { model.stopActiveMode() }
                .tint(.red)
                .toolbarKeepsTitle()
                .disabled(!model.isModeRunning || model.isBusy)
                .help("도는 모드를 모두 내립니다. 물리 E-stop을 대신하지 않습니다")
        }
        ToolbarItem {
            Button("전체화면", systemImage: "arrow.up.left.and.arrow.down.right") {
                model.enterConsoleFullScreen()
            }
            .disabled(!model.connection.isConnected)
            .help("서버의 웹 콘솔을 창 전체에 띄웁니다")
        }
        ToolbarItem {
            if model.status?.teleop.running == true {
                Button("텔레옵 중지", systemImage: "stop.fill") { model.stopTeleoperation() }
                    .tint(.red)
                    .toolbarKeepsTitle()
                    .disabled(model.isBusy)
                    .help("리더 → 팔로워 전달을 멈춥니다")
            } else {
                Button("텔레옵 시작", systemImage: "dot.radiowaves.left.and.right") { pending = .teleoperation }
                    .buttonStyle(.glassProminent)
                    .tint(.snuBlue)
                    .toolbarKeepsTitle()
                    .disabled(model.status?.teleopReady != true || model.isModeRunning || model.isBusy)
                    .help("현장 확인과 확인 문구를 거쳐 리더 팔의 움직임을 팔로워에 전달합니다")
            }
        }
    }

    // MARK: 막힌 이유

    /// 정상일 때는 아무것도 그리지 않는다. 준비 상태를 늘 펼쳐 두면 읽히지 않는 카드가 되고,
    /// 정작 막혔을 때 그 사실이 다른 정상 표시들 사이에 묻힌다.
    @ViewBuilder
    private var problems: some View {
        if !model.problems.isEmpty {
            GroupBox {
                VStack(alignment: .leading, spacing: Spacing.s) {
                    ForEach(model.problems, id: \.self) { line in
                        Label(line, systemImage: "exclamationmark.triangle.fill")
                            .font(.callout)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if !model.server.isConfigured {
                        Button("설정에서 서버 넣기") {
                            openSettings()
                        }
                        .buttonStyle(.link)
                        .font(.caption)
                    } else if case .failed = model.connection {
                        Button("다시 연결") { Task { await model.connect() } }
                            .buttonStyle(.link)
                            .font(.caption)
                    }
                    Text("motion gate와 캘리브레이션, serial 경로는 서버 운영 절차로만 바꿉니다. 이 앱은 고치지 않습니다.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .transition(.appCard)
        }
    }

    // MARK: 진단 점검표

    /// 관절값을 늘어놓는 대신 항목별로 답한다. 진단을 누르는 순간 알고 싶은 것은 숫자가
    /// 아니라 *어디까지 정상인가*이고, 숫자는 그 답의 근거로만 뒤에 붙는다.
    @ViewBuilder
    private var diagnosis: some View {
        if model.showsDiagnosis {
            GroupBox {
                VStack(alignment: .leading, spacing: Spacing.s) {
                    HStack {
                        Text("진단 결과").font(.callout.weight(.medium))
                        if model.isBusy {
                            ProgressView().controlSize(.small)
                            Text("두 serial bus를 읽는 중입니다…").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button {
                            model.showsDiagnosis = false
                        } label: {
                            Image(systemName: "xmark").font(.caption2)
                        }
                        .buttonStyle(.borderless)
                        .help("점검표 닫기")
                    }
                    ForEach(model.diagnosisChecks) { check in
                        SOArmCheckRow(check: check)
                    }
                    Text("읽기만 합니다. 모터 ID·전압·토크 상태를 확인할 뿐 동작 명령은 보내지 않습니다.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .transition(.appCard)
        }
    }

    // MARK: 카메라

    private var cameras: some View {
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
                    isRecording: model.status?.recording.running ?? false,
                    stream: model.stream(role),
                    enabled: model.connection.isConnected && !(model.status?.recording.running ?? false),
                    start: { model.startPreview(role) },
                    stop: { model.stopPreview(role) },
                    apply: { model.setCameraProfile($0, for: role) }
                )
            }
        }
        // The cards stretch; only their height is computed. A 4:3 card has to
        // derive its height from its width, and `aspectRatio` cannot do it here
        // — the scroll view proposes an unbounded height, so the ratio would
        // have nothing to resolve against. Measuring the row instead keeps the
        // box a stated height, identical before and after the first frame,
        // while still following the window.
        //
        // The measured width must not depend on the cards, or the two chase
        // each other: a card wide enough to change the window's minimum width
        // changes the width being measured, and AppKit ends the argument by
        // throwing on the constraint pass. So the cards stay flexible in width
        // and only take the height from here.
        .frame(maxWidth: .infinity, alignment: .leading)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { cameraRowWidth = $0 }
    }

    // MARK: 데이터 수집

    private var recording: some View {
        GroupBox("데이터 수집") {
            VStack(alignment: .leading, spacing: Spacing.m) {
                if model.status?.recording.running == true {
                    runningRecording
                } else {
                    recordingSetup
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var recordingSetup: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            TextField("무엇을 시연하는지 한 문장으로", text: $model.recordTask, axis: .vertical)
                .lineLimit(1...3)
                .textFieldStyle(.roundedBorder)
            HStack(spacing: Spacing.l) {
                // 몇 번 찍을지는 묻지 않는다. 될 때까지 찍다가 `수집 종료`로 끝내는 일이고,
                // 시작 전에 정할 수 있는 숫자가 아니다.
                Stepper("한 회 최대 \(model.recordSeconds)초", value: $model.recordSeconds, in: 5...300, step: 5)
                Spacer()
                Button("수집 시작", systemImage: "record.circle") { pending = .recording }
                    .buttonStyle(.borderedProminent)
                    .tint(.snuBlue)
                    .disabled(
                        model.status?.recordReady != true
                        || model.isModeRunning
                        || model.isBusy
                        || model.recordTask.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    )
            }
            Text("`수집 종료`를 누를 때까지 계속 찍습니다. 한 회는 위 시간이 지나거나 `성공 저장`·`다시 찍기`를 누르면 끝납니다. 서버의 `data/`에 LeRobot 데이터셋으로 남고 Hub로 올라가지 않으며, 시작하면 카메라 프리뷰는 자동으로 내려갑니다.")
                .font(.caption)
                .foregroundStyle(.secondary)
            // 프리뷰 화질은 골라 두어도 수집에는 따라오지 않는다. 그 사실을 시작 버튼 옆에
            // 적어 두지 않으면, 1280×720으로 보다가 그대로 찍힌 줄 알기 딱 좋다.
            Label(
                "카메라는 두 대 모두 \(model.status?.recordingProfile.text ?? SOArmCameraProfile.recordingDefault.text)로 고정해 찍습니다. 프리뷰에서 고른 화질·프레임은 보기 위한 것이고 수집에는 쓰이지 않습니다 — VLA 학습용 데이터셋은 회차마다 카메라 설정이 달라지면 못 씁니다.",
                systemImage: "lock"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private var runningRecording: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            HStack(spacing: Spacing.s) {
                ProgressView().controlSize(.small)
                Text(model.status?.recordingRuntime?.phaseTitle ?? "수집 중")
                    .font(.headline)
                if let dataset = model.status?.recordingRuntime?.datasetName {
                    Text(dataset)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                Spacer()
            }
            if let task = model.status?.recordingRuntime?.task, !task.isEmpty {
                Text(task).font(.callout).foregroundStyle(.secondary)
            }
            HStack(spacing: Spacing.s) {
                // 성공이 가장 자주 눌리는 버튼이라 하나만 prominent다. 셋을 똑같이 그리면
                // 시연이 끝난 직후 어느 것을 눌러야 하는지 매번 읽어야 한다.
                Button(SOArmRecordControl.success.title, systemImage: SOArmRecordControl.success.symbol) {
                    model.send(.success)
                }
                .buttonStyle(.borderedProminent)
                .tint(.snuBlue)
                .disabled(model.isBusy)
                .help(SOArmRecordControl.success.help)

                Button(SOArmRecordControl.retry.title, systemImage: SOArmRecordControl.retry.symbol) {
                    model.send(.retry)
                }
                .buttonStyle(.bordered)
                .tint(.orange)
                .disabled(model.isBusy)
                .help(SOArmRecordControl.retry.help)

                Button(SOArmRecordControl.stop.title, systemImage: SOArmRecordControl.stop.symbol) {
                    model.send(.stop)
                }
                .buttonStyle(.bordered)
                .tint(.red)
                .disabled(model.isBusy)
                .help(SOArmRecordControl.stop.help)
            }
        }
    }

    // MARK: 로그

    @ViewBuilder
    private var logs: some View {
        let lines = model.status?.visibleLogs ?? []
        if !lines.isEmpty {
            VStack(alignment: .leading, spacing: Spacing.s) {
                Text("실행 로그").font(.callout).foregroundStyle(.secondary)
                ScrollView {
                    Text(lines.suffix(60).joined(separator: "\n"))
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 150)
            }
            .padding(Spacing.m)
            .glassPanel()
        }
    }

    private var safetyNote: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Text("`모드 중지`는 소프트웨어 중지입니다. 물리 E-stop이나 전원 차단을 대신하지 않으니, 팔이 움직이는 동안에는 현장에 사람이 있어야 합니다.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// `설정 › 연결 상태`의 줄과 같은 모양. 같은 질문에 답하는 화면은 같아 보여야 한다.
private struct SOArmCheckRow: View {
    let check: SOArmCheck

    private var tint: Color {
        switch check.state {
        case .checking: .secondary
        case .ok: .green
        case .warning: .orange
        case .failed: .red
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.m) {
            Image(systemName: check.state.symbol)
                .foregroundStyle(tint)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: Spacing.xs) {
                    Image(systemName: check.symbol).foregroundStyle(.secondary).font(.caption)
                    Text(check.title).font(.callout.weight(.medium))
                }
                Text(check.summary)
                    .font(.caption)
                    .foregroundStyle(check.state == .ok ? AnyShapeStyle(.secondary) : AnyShapeStyle(tint))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }
}


/// 카메라 카드의 크기 계산. 화면에서 떼어 둔 것은 창 폭에 따라 어떤 높이가 나오는지
/// 그림 없이 확인할 수 있어야 하기 때문이다.
enum SOArmCameraLayout {
    /// 영상 칸의 높이.
    ///
    /// 카드 두 장이 간격 하나를 사이에 두고 줄 전체를 나눠 가지므로, 한 장의 폭은 계산할 수
    /// 있다. 그 폭을 **고른 해상도**의 비율로 나눈 것이 높이다. 들어오는 프레임이 아니라
    /// 고른 값에서 읽는 이유는, 프리뷰가 꺼져 있어 볼 프레임이 없을 때도 카드가 같은 모양
    /// 이어야 하고, 해상도를 16:9로 바꾸는 순간 카드도 같이 16:9가 되어야 영상 양옆에 빈
    /// 띠가 생기지 않기 때문이다.
    ///
    /// 위쪽 한계는 두지 않는다. 창을 넓히면 카드도 같이 커지는 편이 낫다 — 이 화면에서 제일
    /// 오래 보는 것이 이 두 장이다. 아래쪽 값은 폭이 아직 측정되기 전(0)에 카드가 납작하게
    /// 붙는 것만 막는다.
    static let minimumViewportHeight: CGFloat = 180

    static func viewportHeight(sharing rowWidth: CGFloat, aspectRatio: CGFloat) -> CGFloat {
        let each = (rowWidth - Spacing.l) / CGFloat(SOArmCameraRole.allCases.count)
        guard each > 0, aspectRatio > 0 else { return minimumViewportHeight }
        return max((each / aspectRatio).rounded(), minimumViewportHeight)
    }
}

// MARK: - 카메라 카드

private struct SOArmCameraCard: View {
    let role: SOArmCameraRole
    let viewportHeight: CGFloat
    let camera: SOArmCamera
    let recordingProfile: SOArmCameraProfile
    let isRecording: Bool
    @ObservedObject var stream: MJPEGStream
    let enabled: Bool
    let start: () -> Void
    let stop: () -> Void
    let apply: (SOArmCameraProfile) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            HStack {
                VStack(alignment: .leading, spacing: 0) {
                    Text(role.subtitle).font(.caption2).foregroundStyle(.tertiary)
                    Text(role.title).font(.headline)
                }
                Spacer()
                settings
                if stream.isRunning {
                    Button("중지", systemImage: "stop.fill", action: stop)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                } else {
                    Button("프리뷰", systemImage: "play.fill", action: start)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(!enabled)
                }
            }
            reading
            ZStack {
                if let image = stream.image {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                } else {
                    EmptyResults(
                        symbol: stream.failure == nil ? "video.slash" : "exclamationmark.triangle",
                        message: stream.failure ?? (stream.isRunning ? "첫 프레임을 기다리는 중입니다" : "프리뷰를 켜면 서버 카메라를 잠시 점유합니다")
                    )
                }
            }
            // A fixed viewport, identical before and after the stream starts.
            // The box used to be sized by whatever was inside it, so the card was
            // one height while it said 프리뷰를 켜면… and another once frames
            // arrived — and it changed again with every frame whose pixel size
            // differed. A stated size rather than an aspect ratio because the
            // ratio would have to be resolved against a scroll view's unbounded
            // height proposal, which is exactly the ambiguity being removed here.
            .frame(maxWidth: .infinity, minHeight: viewportHeight, maxHeight: viewportHeight)
            .clipped()
            .contentCard()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }


    /// 지금 무엇으로 보고 있는지, 그리고 고른 값과 다르면 다르다고.
    @ViewBuilder
    private var reading: some View {
        if isRecording {
            Text("수집 중 · \(recordingProfile.text) 고정")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else if let actual = camera.actual, stream.isRunning {
            // 서버가 세어 준 전달 프레임이다. 640×480 30fps를 걸어 두어도 다시 인코딩해서
            // 터널로 보내는 값은 그보다 적게 나오므로, 고른 값만 적어 두면 화면이 실제와
            // 다른 말을 하게 된다.
            Text(actual.resolution == camera.requested.resolution
                 ? "실제 \(actual.text)"
                 : "실제 \(actual.text) · 요청 \(camera.requested.text)")
                .font(.caption)
                .foregroundStyle(actual.resolution == camera.requested.resolution ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.orange))
        } else {
            Text(camera.requested.text)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// 화질과 프레임. 고를 수 있는 해상도는 서버가 장치에 직접 물어 온 목록이고, 프레임은
    /// 그 해상도에서 장치가 내주는 최대치 이하만 보여 준다.
    @ViewBuilder
    private var settings: some View {
        Menu {
            Section("화질") {
                Picker("화질", selection: resolutionBinding) {
                    ForEach(camera.resolutions, id: \.self) { resolution in
                        Text(resolution.text).tag(resolution)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }
            Section("초당 프레임") {
                Picker("초당 프레임", selection: frameRateBinding) {
                    ForEach(frameRateChoices, id: \.self) { rate in
                        Text("\(rate)fps").tag(rate)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }
        } label: {
            Label("화질·프레임", systemImage: "slider.horizontal.3")
                .labelStyle(.iconOnly)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .controlSize(.small)
        .disabled(isRecording || camera.resolutions.isEmpty)
        .help(isRecording
              ? "수집 중에는 \(recordingProfile.text)로 고정됩니다"
              : "프리뷰 화질과 프레임. 수집은 언제나 \(recordingProfile.text)로 찍습니다")
    }

    private var resolutionBinding: Binding<SOArmCameraResolution> {
        Binding(
            get: { camera.requested.resolution },
            set: { resolution in
                // 새 해상도에서 장치가 못 내는 프레임을 그대로 들고 가면 서버가 거절한다.
                let rate = min(camera.requested.fps, camera.deviceFrameRate(for: resolution))
                apply(SOArmCameraProfile(width: resolution.width, height: resolution.height, fps: rate))
            }
        )
    }

    private var frameRateBinding: Binding<Int> {
        Binding(
            get: { camera.requested.fps },
            set: { rate in
                var profile = camera.requested
                profile.fps = rate
                apply(profile)
            }
        )
    }

    /// 30·15·10·5 가운데 이 해상도에서 장치가 낼 수 있는 것들. 지금 걸려 있는 값은 목록에
    /// 없더라도 반드시 넣는다 — 그러지 않으면 Picker가 고른 것이 없는 상태로 그려진다.
    private var frameRateChoices: [Int] {
        let maximum = camera.deviceFrameRate(for: camera.requested.resolution)
        var rates = [30, 15, 10, 5].filter { $0 <= maximum }
        if !rates.contains(camera.requested.fps) { rates.append(camera.requested.fps) }
        return rates.sorted(by: >)
    }
}


// MARK: - 시작 확인

/// 무엇을 시작하려는지. 확인 문구가 둘 다 다르고, 서버는 문구가 정확히 맞을 때만 시작한다.
private enum SOArmStartRequest: String, Identifiable {
    case teleoperation, recording

    var id: String { rawValue }

    var title: String {
        self == .teleoperation ? "텔레오퍼레이션 시작" : "데이터 수집 시작"
    }

    var copy: String {
        self == .teleoperation
            ? "두 팔을 서로 대응하는 비슷한 자세로 맞춘 뒤 시작하세요. 리더의 관절값이 팔로워로 전달되며, 프레임당 상대 목표는 서버가 제한합니다."
            : "카메라 프리뷰를 내리고 새 로컬 데이터셋 세션을 시작합니다. 수집 중에는 성공·재시도·종료만 조작할 수 있습니다."
    }

    var startTitle: String {
        self == .teleoperation ? "텔레옵 시작" : "수집 시작"
    }
}

private struct SOArmConfirmationSheet: View {
    let request: SOArmStartRequest
    let confirm: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.l) {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text("MOTION AUTHORITY").font(.caption2).foregroundStyle(.tertiary)
                Text(request.title).font(.title3).bold()
                Text(request.copy)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Label("현장에 사람·장애물·케이블이 없는지, 전원 차단 위치가 어디인지 확인하세요.", systemImage: "exclamationmark.triangle.fill")
                .font(.callout)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("취소") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(request.startTitle) {
                    confirm()
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .tint(.snuBlue)
                // 확인 문구를 손으로 옮겨 적게 하던 자리다. 서버는 여전히 정확한 문구를
                // 요구하고 앱이 그것을 보내지만, 사람에게 타자를 요구하지는 않는다.
                // Return 한 번으로 시작한다.
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(Spacing.xl)
        .frame(width: 460)
    }
}

// MARK: - 전체화면 웹 콘솔

/// 서버가 이미 갖고 있는 콘솔을 창 전체에 띄운다.
///
/// 창은 계속 하나만 쓴다(이 앱의 규칙). 그래서 새 창을 여는 대신 작업 화면 위를 덮고,
/// 동시에 창 자체를 macOS 전체화면으로 넘긴다.
struct SOArmFullScreenConsole: View {
    @ObservedObject var model: SOArmConsoleModel
    @State private var host: NSWindow?
    @State private var enteredFullScreen = false
    /// 전체화면에 들어가기 직전의 창 크기. 나올 때 AppKit이 알아서 되돌려 주리라 믿었더니
    /// 창이 내용의 최소 크기(940×620)로 쪼그라든 채 돌아왔다. 명시적으로 기억해 둔다.
    @State private var restoreFrame: NSRect?
    @State private var restorer = FullScreenFrameRestorer()

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: Spacing.s) {
                Text("SO-ARM 101 콘솔").font(.callout).bold()
                Text(model.consoleURL.absoluteString)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("닫기", systemImage: "xmark") { model.leaveConsoleFullScreen() }
                    .keyboardShortcut(.cancelAction)
                    .help("앱 화면으로 돌아갑니다 (Esc)")
            }
            .padding(.horizontal, Spacing.l)
            .padding(.vertical, Spacing.s)
            .background(.bar)
            Divider()
            SOArmConsoleWebView(url: model.consoleURL)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        // Deliberately *not* `ignoresSafeArea`: reaching into the title bar put
        // this bar underneath the window's own close/minimise/zoom buttons, so
        // the first thing the console showed was three circles sitting on top of
        // its title.
        .background(WindowReader { window in
            guard host !== window else { return }
            host = window
        })
        .onAppear { if let host { enterFullScreen(host) } }
        .onChange(of: host) { _, window in
            if let window { enterFullScreen(window) }
        }
        .onDisappear(perform: leaveFullScreen)
    }

    private func enterFullScreen(_ window: NSWindow) {
        guard !enteredFullScreen, !window.styleMask.contains(.fullScreen) else { return }
        // A background app cannot finish the transition. macOS builds the
        // full-screen space anyway and leaves the window at its old size with
        // display-width chrome floating over it — which is what "화면이 깨졌다"
        // looked like. When the reader presses the button the app is frontmost,
        // so this guard only bites on background launches and inspection runs.
        guard NSApp.isActive else { return }
        enteredFullScreen = true
        restoreFrame = window.frame
        window.toggleFullScreen(nil)
    }

    private func leaveFullScreen() {
        // 우리가 넣은 경우에만 되돌린다. 사용자가 이미 전체화면으로 쓰고 있었다면 건드리지 않는다.
        guard enteredFullScreen, let host, host.styleMask.contains(.fullScreen) else { return }
        enteredFullScreen = false
        // 크기 복원은 전환 애니메이션이 끝난 뒤라야 한다. 지금 바로 넣으면 전체화면 프레임에
        // 덮여 사라진다.
        if let frame = restoreFrame { restorer.arm(host, frame: frame) }
        host.toggleFullScreen(nil)
    }
}

/// 전체화면에서 빠져나온 **뒤에** 창 크기를 한 번 되돌린다.
///
/// 셀렉터로 관찰하는 이유는 `@Sendable` 클로저 안에서 관찰 토큰과 창을 함께 붙잡으면 Swift 6
/// 동시성 검사에 걸리기 때문이다. 창 알림은 메인에서 오므로 이 타입은 메인 액터에 둔다.
@MainActor
private final class FullScreenFrameRestorer: NSObject {
    private var frame: NSRect = .zero
    private weak var window: NSWindow?

    func arm(_ window: NSWindow, frame: NSRect) {
        NotificationCenter.default.removeObserver(self)
        self.window = window
        self.frame = frame
        NotificationCenter.default.addObserver(
            self, selector: #selector(didExitFullScreen),
            name: NSWindow.didExitFullScreenNotification, object: window
        )
    }

    @objc private func didExitFullScreen() {
        NotificationCenter.default.removeObserver(self)
        window?.setFrame(frame, display: true, animate: false)
        window = nil
    }
}

/// SwiftUI 안에서 이 뷰가 올라탄 `NSWindow`를 집는다.
///
/// 첫 판은 `updateNSView`마다 콜백을 불렀고, 그 콜백이 `@State`를 쓰면 다시 갱신이 돌아
/// 무한 재그리기가 됐다 — 화면이 깨진 것처럼 보인 이유의 절반이 이것이었다. 창은 뷰가
/// 붙을 때 한 번만 정해지므로 그때 한 번만 알린다.
private struct WindowReader: NSViewRepresentable {
    let found: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = TrackingView()
        view.found = found
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? TrackingView)?.found = found
    }

    final class TrackingView: NSView {
        var found: ((NSWindow) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            // 레이아웃 패스 안에서 SwiftUI 상태를 건드리지 않는다.
            DispatchQueue.main.async { [found] in found?(window) }
        }
    }
}

/// 로컬 콘솔 전용 `WKWebView`.
struct SOArmConsoleWebView: NSViewRepresentable {
    let url: URL

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        // 콘솔은 상태를 서버에 두므로 이 Mac에 쿠키나 캐시를 남길 이유가 없다.
        configuration.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.setValue(false, forKey: "drawsBackground")
        webView.load(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData))
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        if webView.url == nil {
            webView.load(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData))
        }
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        // 페이지가 물고 있던 MJPEG 연결을 여기서 끊는다. 그래야 서버의 카메라 worker가 풀린다.
        webView.stopLoading()
        webView.load(URLRequest(url: URL(string: "about:blank")!))
    }

    /// 콘솔은 믿지만, 앱 창 안에서 임의의 웹이 열리는 경로는 만들지 않는다.
    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
        ) {
            let host = navigationAction.request.url?.host
            decisionHandler(host == nil || host == "127.0.0.1" || host == "localhost" ? .allow : .cancel)
        }
    }
}

// MARK: - 창 전체를 덮는 콘솔

/// 작업 화면 위에 얹히는 껍데기. 자기 상태를 관찰해야 오버레이가 켜지고 꺼지므로,
/// `MainWorkspaceView`가 직접 조건을 쓰지 않고 이 뷰를 통과시킨다.
struct SOArmConsoleOverlay: View {
    @ObservedObject var model: SOArmConsoleModel

    var body: some View {
        if model.isConsoleFullScreen {
            SOArmFullScreenConsole(model: model)
                .transition(.opacity)
        }
    }
}

// MARK: - 개요 타일

/// 개요에 놓이는 한 칸.
///
/// 여기서 "연결 안 됨"이라고 말하지 않는 것이 중요하다. 이 앱은 SO-ARM 탭을 열었을 때만
/// 터널을 세우므로, 탭을 열지 않은 상태는 서버가 죽은 것이 아니라 **아직 물어보지 않은**
/// 것이다. 둘을 같은 말로 적으면 멀쩡한 서버를 고장 났다고 보고하게 된다.
struct SOArmOverviewTile: View {
    @ObservedObject var model: SOArmConsoleModel
    let open: () -> Void

    var body: some View {
        StatusTile(
            title: AppSection.soarm.title,
            value: value,
            detail: detail,
            symbol: AppSection.soarm.symbol,
            isBusy: model.isModeRunning,
            isAlarming: isAlarming,
            open: open
        )
    }

    private var value: String {
        switch model.connection {
        case .connected: model.mode.badge
        case .connecting: "연결 중"
        case .failed: "연결 실패"
        case .idle: model.server.isConfigured ? "연결 안 함" : "설정 필요"
        }
    }

    private var detail: String {
        if case .failed(let message) = model.connection { return message }
        guard model.server.isConfigured else { return "설정 › 로봇에서 서버 주소를 넣으세요" }
        if model.connection.isConnected {
            if let dataset = model.status?.recordingRuntime?.datasetName, model.mode == .recording {
                return dataset
            }
            return model.server.sshTarget
        }
        return "\(model.server.sshTarget) · 화면을 열면 연결합니다"
    }

    private var isAlarming: Bool {
        if case .failed = model.connection { return true }
        return false
    }
}

// MARK: - 설정 › 로봇

/// 서버 주소와 계정. 개인 정보라 소스가 아니라 이 기기의 파일에만 남는다.
struct SOArmSettingsTab: View {
    /// 조작 토큰을 클립보드에 넣는다. 넣은 값을 돌려준다.
    ///
    /// 화면에서 떼어 둔 이유는 이 한 줄에 판단이 하나 들어 있기 때문이다: **앞뒤 공백을
    /// 뗀다.** 서버에 넣을 때 줄바꿈이 따라 들어간 값을 그대로 복사해 폰에 붙이면, 서버는
    /// 그것을 다른 토큰으로 본다 — 그리고 화면에는 `조작 토큰이 다릅니다`만 뜬다.
    /// 눈으로는 구별되지 않는 실패라 시험으로 잡아 두는 편이 낫다.
    @discardableResult
    static func copyMotionToken(_ raw: String, to pasteboard: NSPasteboard = .general) -> String {
        let token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        pasteboard.clearContents()
        pasteboard.setString(token, forType: .string)
        return token
    }

    @ObservedObject var model: SOArmConsoleModel
    @State private var key = SOArmTunnelKey()
    @State private var publicKey = ""
    @State private var keyError = ""
    /// 토큰을 눈에 보이게 둘 것인가. 기본은 가려 둔다.
    @State private var showsToken = false
    /// 방금 복사했다는 표시. 잠깐 떴다 사라진다.
    @State private var copiedToken = false
    @StateObject private var tuning: SOArmTuningModel

    init(model: SOArmConsoleModel) {
        self.model = model
        _tuning = StateObject(wrappedValue: SOArmTuningModel(server: model.server))
    }

    var body: some View {
        Form {
            SOArmTuningSection(model: tuning)
            Section("서버") {
                TextField("집에서 쓸 주소", text: $model.server.host, prompt: Text("192.168.0.20"))
                TextField("집 밖에서 쓸 주소", text: $model.server.alternateHost, prompt: Text("100.x.y.z (Tailscale)"))
                Text("같은 서버로 가는 두 번째 길입니다. 이 Mac이 집 네트워크를 벗어나면 LAN 주소는 닿지 않지만, 서버가 Tailscale로 같은 tailnet에 있으면 그 주소로는 계속 닿습니다. 두 칸을 채워 두면 앱이 먼저 열리는 쪽을 쓰고, 한 번 열린 주소는 다음 연결에서 먼저 시도합니다. 하나로 합치지 않은 이유는 Tailscale이 꺼져 있을 때 집에서도 못 닿기 때문입니다 — 두 길은 서로의 대비책입니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("SSH 계정", text: $model.server.user, prompt: Text("deploy"))
                TextField("SSH 포트", value: $model.server.sshPort, format: .number.grouping(.never))
                Text("앱은 암호를 묻지 않고 즉시 실패합니다 — 창 없는 자식 프로세스의 암호 프롬프트는 아무도 볼 수 없기 때문입니다. 그래서 아래 `이 앱의 열쇠`를 서버에 한 번 등록해야 합니다. 평소 터미널에서 쓰는 열쇠는 앱이 읽을 수 없으므로, 터미널에서 접속이 된다고 해서 여기서도 되는 것은 아닙니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("포트") {
                TextField("이 Mac에서 열 포트", value: $model.server.localPort, format: .number.grouping(.never))
                TextField("서버 콘솔 포트", value: $model.server.remotePort, format: .number.grouping(.never))
                Text("서버 콘솔 포트는 `config/soarm.env`의 `SOARM_WEB_PORT`와 같아야 합니다. 이미 8088로 터널을 열어 두었다면 이 Mac 쪽 포트만 바꾸세요.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("조작 토큰") {
                // 가려 두는 것이 기본인 이유: 이 값이 있으면 팔을 움직일 수 있고, 화면
                // 캡처나 어깨너머로 새어 나가는 것이 곧 조작 권한이 새는 것이다.
                //
                // 그런데 `SecureField`만 두었더니 **복사가 되지 않았다.** macOS가 보안
                // 입력란에서 복사를 막기 때문이고, 그래서 이 값을 아이폰으로 옮기려면
                // 서버에 들어가 `grep`을 하거나 32글자를 손으로 옮겨 적어야 했다. 가리는
                // 것은 어깨너머를 막자는 것이지 주인이 자기 값을 못 쓰게 하자는 것이
                // 아니다. 눌러서 보고, 눌러서 복사한다.
                HStack(spacing: Spacing.s) {
                    Group {
                        if showsToken {
                            TextField("서버 config/soarm.env의 SOARM_MOTION_TOKEN", text: $model.server.motionToken)
                                .font(.system(.body, design: .monospaced))
                        } else {
                            SecureField("서버 config/soarm.env의 SOARM_MOTION_TOKEN", text: $model.server.motionToken)
                        }
                    }
                    Button {
                        showsToken.toggle()
                    } label: {
                        Image(systemName: showsToken ? "eye.slash" : "eye")
                    }
                    .help(showsToken ? "다시 가립니다" : "값을 화면에 보이게 합니다. 옆에 사람이 없을 때만 쓰세요")
                    Button("복사", systemImage: "doc.on.doc") {
                        SOArmSettingsTab.copyMotionToken(model.server.motionToken)
                        copiedToken = true
                        Task {
                            try? await Task.sleep(for: .seconds(4))
                            copiedToken = false
                        }
                    }
                    .disabled(model.server.motionToken.trimmingCharacters(in: .whitespaces).isEmpty)
                    .help("아이폰의 조작 화면 `권한` 탭에 붙여 넣으려고 만든 자리입니다")
                }
                if copiedToken {
                    Label("복사했습니다 — 아이폰 조작 화면의 `권한` 탭에 붙여 넣으세요", systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(Color.snuBlueLabel)
                }
                Text("관찰과 조작의 권한을 가르는 값입니다. 상태와 카메라를 보는 데는 필요 없고, 팔로워를 움직이는 요청에만 붙습니다. 아이폰이 같은 tailnet에서 붙게 되면서 생긴 구분이라, 서버에서 이 값을 갈아 끼우면 조작 권한만 끊깁니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("서버에서 확인: `grep SOARM_MOTION_TOKEN ~/Project/so-arm-101/config/soarm.env`")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Section("이 앱의 열쇠") {
                Text("앱은 `~/.ssh`를 읽을 수 없습니다 — macOS가 보호하는 폴더라, 전체 디스크 접근 권한이 없는 앱이 띄운 ssh는 평소 쓰는 열쇠를 찾지 못합니다. 그래서 이 연결에만 쓰는 열쇠를 앱 폴더에 따로 두고 씁니다. 서버에서 이 줄만 지우면 앱의 접근만 끊깁니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if keyError.isEmpty {
                    Text(publicKey.isEmpty ? "열쇠를 준비하는 중입니다…" : publicKey)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .lineLimit(3)
                    LabeledContent("서버에 등록") {
                        Button("명령 복사") {
                            let command = key.authorizationCommand(for: model.server)
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(command, forType: .string)
                        }
                        .disabled(!model.server.isConfigured || publicKey.isEmpty)
                    }
                    Text(model.server.isConfigured
                         ? key.authorizationCommand(for: model.server)
                         : "서버 주소를 먼저 넣으면 등록 명령을 만들어 드립니다.")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                } else {
                    Text(keyError).font(.caption).foregroundStyle(.red)
                }
            }
            Section("지금 상태") {
                LabeledContent("연결", value: connectionText)
                LabeledContent("붙어 있는 주소", value: SOArmTunnel.shared.connectedHost ?? "없음")
                HStack {
                    Button("지금 연결해 보기") { Task { await model.connect() } }
                    Button("연결 끊기") { model.disconnect() }
                        .disabled(!model.connection.isConnected)
                    Spacer()
                }
                Text("설정 파일: \(model.settingsFileURL.path)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Section("이 앱이 하지 않는 것") {
                Text("motion gate(`SOARM_ENABLE_MOTION`), serial 경로, 카메라 역할, calibration 파일은 서버 운영 절차로만 바꿉니다. 앱에 그 화면을 만들지 않은 것은 실수로 장치 역할과 calibration이 어긋나는 경로를 아예 없애기 위해서입니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("콘솔 API에는 인증이 없습니다. 그래서 서버는 `127.0.0.1`에만 bind되어 있고, 이 앱은 언제나 SSH 터널 너머로만 부릅니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task {
            do {
                try key.ensureExists()
                publicKey = key.publicKeyText
            } catch {
                keyError = SOArmConsoleModel.message(for: error)
            }
        }
        .onDisappear { model.saveServerNow() }
    }

    private var connectionText: String {
        switch model.connection {
        case .idle: "연결하지 않음"
        case .connecting: "연결 중…"
        case .connected: "연결됨 · \(model.mode.badge)"
        case .failed(let message): message
        }
    }
}
