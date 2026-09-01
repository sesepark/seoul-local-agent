import SwiftUI
import AppKit
import WebKit

/// 원격 텔레옵 화면 — 3D로 그린 팔을 만지면 집의 진짜 팔이 따라온다.
///
/// 3D는 서버가 서빙하는 웹 구현 하나를 `WKWebView`로 품는다. 폰의 조작 화면이 같은 파일을
/// 쓰기 때문이고, 구현이 둘이면 두 기기가 같은 팔에 대해 서로 다른 그림을 그리게 된다.
/// 그 바깥의 모든 것 — 관절 슬라이더, 부하 막대, 안전 상태, 정지 버튼, 카메라 —은
/// 네이티브다. 이 앱의 다른 화면과 같은 자리에 같은 모양으로 있어야 하기 때문이다.
struct SOArmTeleopView: View {
    @ObservedObject var controller: AutomationController

    var body: some View {
        SOArmTeleopWorkspace(model: controller.soarmTeleop)
    }
}

private struct SOArmTeleopWorkspace: View {
    @ObservedObject var model: SOArmTeleopModel
    @Environment(\.openSettings) private var openSettings
    @State private var gate: SOArmTeleopGate?
    @State private var stageWidth: CGFloat = 0

    /// 이 화면만 `WorkspaceScreen`의 스크롤 안에 전부 담지 않는다.
    ///
    /// 이유가 둘이다. 하나는 조작할 때 3D와 카메라가 **늘 보여야** 한다는 것이고 —
    /// 관절 슬라이더를 보려고 스크롤했더니 팔이 안 보이는 화면은 조작면이 아니다 —
    /// 다른 하나는 실제로 부딪힌 것이다: `WKWebView`를 세로 스크롤 안에 넣으면 웹 내용이
    /// 아예 그려지지 않았다. 3D도, 그 자리에 있던 로딩 문구도, 콘솔 페이지를 대신 넣어
    /// 봐도 검은 사각형만 남았다. 스크롤 밖으로 꺼내자 곧바로 그려졌다.
    var body: some View {
        VStack(spacing: 0) {
            stageRow
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.l) {
                    Text(AppSection.soarmTeleop.subtitle)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    problems
                    if let message = model.errorMessage {
                        DismissibleError(message: message) { model.errorMessage = nil }
                            .transition(.appCard)
                    }
                    banner
                    joints
                    authority
                    safetyNote
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Spacing.xl)
            }
            .background { CrestWatermark() }
        }
        .navigationTitle(AppSection.soarmTeleop.title)
        .animation(.appContent, value: model.problems)
        .animation(.appContent, value: model.errorMessage)
        .animation(.appControl, value: model.state)
        .animation(.appControl, value: model.holdsAuthority)
        .toolbar { toolbar }
        .sheet(item: $gate) { gate in
            // 멈춰 있는 이유를 게이트 안에서 보여 준다. 확인은 "현장을 봤다"와 "왜 멈췄는지
            // 읽었다"를 함께 뜻하고, 그래야 권한을 받는 그 한 번으로 다시 움직일 수 있다.
            SOArmPhraseGate(gate: gate, reason: gate == .arm ? model.stopReason : nil) { phrase in
                switch gate {
                case .arm: model.takeAuthority(confirmation: phrase)
                case .releaseTorque: model.releaseTorque(confirmation: phrase)
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
            Label(model.badge.text, systemImage: "circle.fill")
                .font(.caption)
                .labelStyle(.titleAndIcon)
                .imageScale(.small)
                .lineLimit(1)
                .fixedSize()
                .foregroundStyle(model.badge.isAlarming ? Color.orange : .secondary)
                .help(help)
        }
        ToolbarSpacer(.flexible)
        ToolbarItem {
            // 리스가 없어도, 토큰이 없어도 누를 수 있다. 멈추는 것은 권한을 빼앗는 것이
            // 아니고, 멈춰야 할 때 무언가를 먼저 입력해야 한다면 그것은 정지 버튼이 아니다.
            Button("정지", systemImage: "hand.raised.fill") { model.holdNow() }
                .tint(.red)
                .toolbarKeepsTitle()
                .disabled(!model.telemetry.running || model.isBusy)
                .help("팔을 지금 자세에서 세웁니다. 토크는 그대로 두므로 팔이 떨어지지 않습니다")
        }
        ToolbarItem {
            if model.holdsAuthority {
                Button("권한 반납", systemImage: "hand.wave") {
                    Task { await model.releaseAuthority() }
                }
                .toolbarKeepsTitle()
                .disabled(model.isBusy)
                .help("조작 권한을 놓습니다. 팔은 지금 자세를 유지합니다")
            } else {
                Button("조작 권한 받기", systemImage: "dot.radiowaves.left.and.right") { gate = .arm }
                    .buttonStyle(.glassProminent)
                    .tint(.snuBlue)
                    .toolbarKeepsTitle()
                    .disabled(!canTakeAuthority)
                    .help(takeHelp)
            }
        }
    }

    private var canTakeAuthority: Bool {
        model.status.available
            && model.problems.isEmpty
            && model.blockedByOtherMode == nil
            && !model.isBusy
            && !model.holdsAuthority
            && model.telemetry.lease == nil
    }

    private var takeHelp: String {
        if let blocked = model.blockedByOtherMode { return blocked }
        if let holder = model.telemetry.lease?.holder { return "\(holder)이(가) 조작 중입니다. 그쪽이 반납해야 받을 수 있습니다" }
        return "확인 문구를 옮겨 적고 토크를 건 뒤 조작 권한을 받습니다"
    }

    private var help: String {
        var lines = ["상태 \(model.state.korean)"]
        if model.telemetry.running {
            lines.append(String(format: "루프 %.1fms", model.telemetry.loopMilliseconds))
        }
        if let age = model.telemetry.commandAgeMs { lines.append("마지막 명령 \(age)ms 전") }
        return lines.joined(separator: " · ")
    }

    // MARK: 막힌 이유

    @ViewBuilder
    private var problems: some View {
        if !model.problems.isEmpty || model.blockedByOtherMode != nil {
            GroupBox {
                VStack(alignment: .leading, spacing: Spacing.s) {
                    ForEach(model.problems + [model.blockedByOtherMode].compactMap { $0 }, id: \.self) { line in
                        Label(line, systemImage: "exclamationmark.triangle.fill")
                            .font(.callout)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if model.server.motionToken.trimmingCharacters(in: .whitespaces).isEmpty {
                        Button("설정에서 조작 토큰 넣기") { openSettings() }
                            .buttonStyle(.link)
                            .font(.caption)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .transition(.appCard)
        }
    }

    /// 왜 멈췄는지. 이 줄이 화면의 가장 중요한 한 줄이다 — 팔이 스스로 섰을 때, 사람이
    /// 알고 싶은 것은 오직 이것이다.
    @ViewBuilder
    private var banner: some View {
        if let fault = model.telemetry.fault {
            GroupBox {
                HStack(alignment: .top, spacing: Spacing.m) {
                    Image(systemName: model.state == .retreating ? "arrow.uturn.backward" : "exclamationmark.octagon.fill")
                        .foregroundStyle(model.state == .fault ? .red : .orange)
                    VStack(alignment: .leading, spacing: Spacing.xs) {
                        Text(model.state == .retreating ? "걸려서 물러나는 중입니다" : "멈췄습니다")
                            .font(.callout.weight(.semibold))
                        Text(fault.message)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                        if let joint = jointLabel(fault.joint) {
                            Text("걸린 관절: \(joint)").font(.caption).foregroundStyle(.tertiary)
                        }
                    }
                    Spacer(minLength: 0)
                    if model.state.needsAcknowledgement {
                        Button("확인하고 계속") { model.resume() }
                            .buttonStyle(.borderedProminent)
                            .tint(.snuBlue)
                            .disabled(model.isBusy)
                            .help("이전 동작을 이어서 하지 않습니다. 지금 자세에서 다시 시작합니다")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .transition(.appCard)
        } else if let rejection = model.rejection {
            Label(rejection, systemImage: "hand.raised.slash")
                .font(.callout)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
                .transition(.appCard)
        }
    }

    private func jointLabel(_ name: String?) -> String? {
        guard let name, !name.isEmpty else { return nil }
        return model.status.spec.first { $0.name == name }?.label ?? name
    }

    // MARK: 3D와 카메라 (스크롤 위에 고정)

    /// 조작하면서 늘 보고 있어야 하는 것들. 넓은 쪽이 3D, 좁은 쪽이 카메라 두 장이다.
    ///
    /// 창을 넓히면 **둘 다** 커진다. 처음에는 카메라 칸을 240pt로 못 박아 두었는데, 창을
    /// 키워도 3D만 자라고 영상은 그대로였다 — 조작하면서 실제로 들여다보는 것은 카메라다.
    private var stageRow: some View {
        HStack(alignment: .top, spacing: Spacing.l) {
            stage
            cameras
                .frame(width: SOArmTeleopLayout.cameraColumnWidth(for: stageWidth))
        }
        .padding(Spacing.l)
        .frame(height: SOArmTeleopLayout.stageHeight(for: stageWidth))
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { stageWidth = $0 }
    }

    /// 3D 위에 적히는 한 줄. 루프가 돌지 않을 때 "보기 전용"이라고만 적으면, 화면은
    /// 지금 그리고 있는 자세가 실제 팔의 자세인 것처럼 말하게 된다.
    private var stageCaption: String {
        if !model.telemetry.running { return "관찰을 시작하기 전이라 3D는 실제 자세를 모릅니다" }
        if model.canCommand { return "끌어서 움직이세요 · 손을 떼면 그 자리에 섭니다" }
        return "보기 전용입니다 · 조작하려면 권한을 받으세요"
    }

    private var stage: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            HStack(spacing: Spacing.s) {
                Text("3D").font(.caption2).foregroundStyle(.tertiary)
                if let viewerError = model.viewerError {
                    Text(viewerError)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .lineLimit(2)
                        .textSelection(.enabled)
                } else if !model.isViewerReady {
                    // 3D가 아직 앱에 말을 걸지 않았다. 검은 사각형만 두면 사람은 팔이
                    // 고장 난 것으로 읽는다.
                    HStack(spacing: Spacing.xs) {
                        ProgressView().controlSize(.small)
                        Text("3D를 여는 중입니다…").font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    Text(stageCaption)
                        .font(.caption)
                        .foregroundStyle(model.telemetry.running ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.orange))
                }
                Spacer()
                if model.isCommanding {
                    Label("조작 중", systemImage: "hand.draw")
                        .font(.caption)
                        .foregroundStyle(Color.snuBlueLabel)
                }
            }
            SOArmViewerWebView(model: model)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: 카메라

    private var cameras: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            ForEach(SOArmCameraRole.allCases) { role in
                SOArmTeleopCameraTile(role: role, stream: model.stream(role))
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    // MARK: 관절

    private var joints: some View {
        GroupBox("관절") {
            VStack(alignment: .leading, spacing: Spacing.m) {
                if model.status.spec.isEmpty {
                    EmptyResults(symbol: "slider.horizontal.3", message: "서버가 아직 관절 계약을 내려주지 않았습니다")
                } else {
                    ForEach(Array(model.status.spec.enumerated()), id: \.element.id) { index, joint in
                        SOArmJointRow(model: model, joint: joint, index: index + 1)
                    }
                    Text("한계값은 서버가 팔로워 calibration에서 계산해 내려준 것입니다. 앱에 적어 둔 숫자가 아닙니다.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: 권한

    private var authority: some View {
        GroupBox("조작 권한") {
            VStack(alignment: .leading, spacing: Spacing.m) {
                if let lease = model.telemetry.lease {
                    HStack(spacing: Spacing.s) {
                        Image(systemName: model.holdsAuthority ? "hand.raised.fill" : "iphone.gen3")
                            .foregroundStyle(Color.snuBlueLabel)
                        Text(model.holdsAuthority
                             ? "이 Mac이 조작 중입니다. 화면을 떠나거나 앱을 끄면 권한을 돌려줍니다."
                             : "\(lease.holder)이(가) 조작 중입니다. 이 화면에서는 보기만 합니다 — 정지는 언제든 누를 수 있습니다.")
                            .font(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                } else {
                    Text("아직 아무도 조작하고 있지 않습니다. 권한을 받기 전에는 3D를 만져도 팔이 움직이지 않습니다.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: Spacing.s) {
                    if model.telemetry.running {
                        Button("가상 리더 중지", systemImage: "stop.circle") { model.stopVirtualLeader() }
                            .disabled(model.isBusy)
                            .help("팔로워 serial을 놓습니다. 토크가 걸려 있으면 서버가 거절합니다")
                    } else {
                        Button("관찰 시작", systemImage: "play.circle") { model.startObserving() }
                            .disabled(model.isBusy || !model.problems.isEmpty || model.blockedByOtherMode != nil)
                            .help("팔로워 serial을 잡고 관절값을 읽기 시작합니다. 토크는 걸지 않으므로 아무것도 움직이지 않습니다")
                    }
                    Spacer()
                    if model.telemetry.torqueEnabled && model.telemetry.torqueKnown {
                        Button("토크 해제…", systemImage: "bolt.slash") { gate = .releaseTorque }
                            .tint(.red)
                            .disabled(model.isBusy)
                            .help("팔이 떨어질 수 있습니다. 받쳐 줄 사람이 있을 때만 하세요")
                    }
                }
                statusLine
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var statusLine: some View {
        let items: [String] = [
            "상태 \(model.state.korean)",
            model.torqueText,
            model.telemetry.running ? String(format: "루프 %.1fms", model.telemetry.loopMilliseconds) : "루프 정지",
        ]
        return Text(items.joined(separator: " · "))
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    private var safetyNote: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Text("`정지`는 자세를 유지한 채 멈추는 것이고 토크를 끄지 않습니다 — 토크를 끄면 팔이 떨어집니다. 소프트웨어 중지는 물리 전원 차단을 대신하지 않으니, 팔이 움직이는 동안에는 현장에 사람이 있어야 합니다.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("안전 판정은 전부 서버가 합니다. 이 화면의 한계 표시는 무엇이 거절될지 미리 보여 주기 위한 사본입니다.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// 3D 칸의 크기 계산. 화면에서 떼어 둔 것은 창 폭에 따라 어떤 높이가 나오는지 그림 없이
/// 확인할 수 있어야 하기 때문이다 — 카메라 카드와 같은 이유다.
enum SOArmTeleopLayout {
    static let minimumStageHeight: CGFloat = 380

    /// 카메라가 내는 화면비. 두 카메라 모두 4:3 고정이라 화면에서 정할 것이 아니라
    /// 맞춰야 하는 값이다.
    static let cameraAspect: CGFloat = 4.0 / 3.0

    /// 카메라 타일에서 영상 위에 붙는 이름표 한 줄의 높이. 높이 계산이 실제 배치와
    /// 어긋나지 않도록 글꼴 크기에 맡기지 않고 이 값으로 못 박는다.
    static let cameraLabelHeight: CGFloat = 15

    /// 카메라 타일 하나가 차지하는 높이 — 4:3 영상 + 이름표.
    static func cameraTileHeight(forColumnWidth width: CGFloat) -> CGFloat {
        (width / cameraAspect) + cameraLabelHeight + Spacing.xs
    }

    /// 줄 높이는 **카메라가 정한다.**
    ///
    /// 예전에는 창 폭의 0.46으로 잡았는데, 그 높이는 4:3 두 장이 필요로 하는 높이와
    /// 아무 관계가 없다. 남으면 영상 위아래로, 모자라면 영상 양옆으로 빈 띠가 생겼다.
    /// 그래서 카메라 칸 폭에서 두 장이 정확히 들어가는 높이를 거꾸로 계산하고, 3D는
    /// 그렇게 정해진 높이를 함께 쓴다. 어차피 3D는 어떤 비율이든 그려낸다.
    static func stageHeight(for width: CGFloat) -> CGFloat {
        guard width > 0 else { return minimumStageHeight }
        let column = cameraColumnWidth(for: width)
        let needed = 2 * cameraTileHeight(forColumnWidth: column) + Spacing.s + 2 * Spacing.l
        return max(needed.rounded(), minimumStageHeight)
    }

    /// 카메라 두 장이 세로로 쌓이는 칸의 폭.
    ///
    /// 고정 폭이 아니라 줄 전체의 몫으로 계산한다. 창을 넓히면 3D와 함께 영상도 커져야
    /// 한다 — 실제로 손이 무엇을 하고 있는지는 3D가 아니라 카메라가 말해 준다. 아래쪽
    /// 한계는 카드가 알아볼 수 없을 만큼 작아지지 않게, 위쪽 한계는 카메라가 3D를
    /// 밀어내지 않게 둔다.
    static func cameraColumnWidth(for rowWidth: CGFloat) -> CGFloat {
        guard rowWidth > 0 else { return 260 }
        return min(maximumCameraColumnWidth, max((rowWidth * 0.30).rounded(), 240))
    }

    /// 위쪽 한계. 이 폭에서 줄 높이가 768pt가 되는데, 그보다 커지면 카메라가 창을 통째로
    /// 먹어 아래쪽 관절 슬라이더가 한 줄도 보이지 않는 채로 시작한다.
    static let maximumCameraColumnWidth: CGFloat = 460
}

// MARK: - 관절 한 줄

private struct SOArmJointRow: View {
    @ObservedObject var model: SOArmTeleopModel
    let joint: SOArmJointSpec
    let index: Int

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack(spacing: Spacing.s) {
                Text("\(index). \(joint.label)")
                    .font(.callout)
                    .frame(width: 110, alignment: .leading)
                Slider(
                    value: Binding(
                        get: { model.target[joint.name] ?? reading?.present ?? 0 },
                        set: { value in
                            model.setTarget(joint.name, value)
                            model.pushTargetToViewer(joint.name, value)
                        }
                    ),
                    in: joint.minimum...joint.maximum,
                    onEditingChanged: { editing in
                        guard !editing else { return }
                        // 데드맨. 슬라이더에서 손을 떼면 목표가 지금 자세로 붙는다.
                        model.endCommanding()
                        model.pushEndTargetToViewer()
                    }
                )
                .disabled(!model.canCommand)
                .tint(rateLimited ? .orange : .snuBlue)
                Text(valueText)
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(divergence == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.orange))
                    .frame(width: 116, alignment: .trailing)
            }
            HStack(spacing: Spacing.s) {
                loadBar
                readout
            }
        }
    }

    /// 모터가 지금 얼마나 힘들어하는지, 숫자로.
    ///
    /// 온도는 뜨거울 때만 나타났고 부하는 막대 하나가 전부였다 — 막대는 "많이 찼다"까지만
    /// 말하고, 얼마나 남았는지는 말하지 않는다. 값과 서버의 정지 문턱을 나란히 적으면 그
    /// 한 줄이 둘 다 말한다. 전류는 모터가 쓰는 단위 그대로다(문턱과 같은 자에 있으므로
    /// 서로 견줄 수 있다).
    @ViewBuilder
    private var readout: some View {
        if let reading {
            let policy = model.status.policy
            // 문턱을 분모로 적지 않는다. 실측에서 부하는 막혀도 130을 넘지 않고 전류는
            // 한 자리에 머무르는데, 서버의 문턱은 400과 108이다 — 그 분수는 "아직 한참
            // 남았다"는 틀린 안심을 준다. 실제로 팔을 세우는 것은 이 숫자들이 아니라
            // "목표를 400ms 넘게 따라가지 못함"이다. 숫자는 상태를 보여 주는 계기이고,
            // 어디서 서는지는 툴팁이 말한다.
            Text(
                "부하 \(Int(abs(reading.load)))"
                + " · 전류 \(Int(abs(reading.current)))"
                + String(format: " · %.0f°C", reading.temperature)
            )
            .font(.caption2.monospacedDigit())
            .foregroundStyle(readoutTint)
            .lineLimit(1)
            .fixedSize()
            .frame(width: 190, alignment: .trailing)
            .help("""
                부하: 모터가 목표를 향해 내고 있는 힘입니다. 서보 자신의 눈금(0~1000)이고 \
                단위가 없습니다. 실측으로 자유롭게 움직일 때 24~100, 무언가에 막히면 \
                48~130까지 올라갑니다.
                전류: 모터가 쓰는 전류입니다. 서보 눈금 한 칸이 약 6.5mA인데, 이 팔에서는 \
                버티고 있을 때도 0~3칸(0~20mA)에 머물러 거의 움직이지 않습니다.
                온도: 모터 온도입니다. \(Int(policy.temperatureWarnC))°C부터 주황, \
                \(Int(policy.temperatureTripC))°C에서 서버가 세웁니다.
                팔을 실제로 세우는 것은 부하·전류 문턱(\(Int(policy.loadTrip))·\(Int(policy.currentTrip)))이 \
                아니라 "목표를 \(policy.commandTimeoutMs + 100)ms 넘게 따라가지 못함"입니다 — \
                이 눈금들로는 막힌 팔과 그냥 무거운 팔이 잘 구분되지 않았습니다.
                """)
        }
    }

    /// 정상은 조용하게. 문턱에 다가가면 그때 색이 붙는다.
    private var readoutTint: AnyShapeStyle {
        guard let reading else { return AnyShapeStyle(.secondary) }
        let policy = model.status.policy
        if reading.temperature >= policy.temperatureTripC
            || abs(reading.load) >= policy.loadTrip
            || abs(reading.current) >= policy.currentTrip {
            return AnyShapeStyle(Color.red)
        }
        if model.mirror.isHot(reading) || loadFraction > 0.6
            || abs(reading.current) >= policy.currentTrip * 0.6 {
            return AnyShapeStyle(Color.orange)
        }
        return AnyShapeStyle(.secondary)
    }

    private var reading: SOArmJointReading? {
        model.telemetry.joints.first { $0.name == joint.name }
    }

    private var rateLimited: Bool { reading?.rateLimited ?? false }

    /// 목표와 실제가 벌어져 있으면 둘 다 적는다. 막혀서 선 팔에서는 그 차이가 곧 설명이다.
    private var divergence: Double? {
        guard let present = reading?.present, let goal = model.target[joint.name] else { return nil }
        return abs(present - goal) > 0.5 ? present : nil
    }

    private var valueText: String {
        let goal = model.target[joint.name] ?? reading?.present ?? 0
        guard let present = divergence else { return joint.text(goal) }
        return "\(joint.text(goal)) → \(joint.text(present))"
    }

    private var loadBar: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule()
                    .fill(loadTint)
                    .frame(width: proxy.size.width * loadFraction)
            }
        }
        .frame(height: 3)
        .help("모터 부하. 막대가 가득 차는 자리가 서버의 정지 문턱입니다")
    }

    private var loadFraction: CGFloat {
        guard let reading else { return 0 }
        return CGFloat(model.mirror.loadFraction(reading))
    }

    private var loadTint: Color {
        if model.telemetry.fault?.joint == joint.name { return .red }
        return loadFraction > 0.6 ? .orange : .green
    }
}

// MARK: - 카메라 타일

/// 텔레옵 화면의 카메라는 조작하면서 곁눈으로 보는 것이라, `SO-ARM 101` 화면의 카드처럼
/// 설정 메뉴를 달지 않는다. 화질은 그 화면에서 정하고 여기서는 보기만 한다.
private struct SOArmTeleopCameraTile: View {
    let role: SOArmCameraRole
    @ObservedObject var stream: MJPEGStream

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack(spacing: Spacing.xs) {
                Text(role.subtitle).font(.caption2).foregroundStyle(.tertiary)
                Text(role.title).font(.caption).foregroundStyle(.secondary)
                Spacer()
            }
            // 이름표 높이를 글꼴에 맡기지 않는다. 줄 높이를 여기서 되짚어 계산하므로,
            // 한 줄이 몇 pt인지 두 곳이 같은 숫자를 알고 있어야 영상에 빈 띠가 안 생긴다.
            .frame(height: SOArmTeleopLayout.cameraLabelHeight)
            ZStack {
                if let image = stream.image {
                    Image(nsImage: image).resizable().scaledToFit()
                } else {
                    EmptyResults(
                        symbol: stream.failure == nil ? "video.slash" : "exclamationmark.triangle",
                        message: stream.failure ?? "첫 프레임을 기다리는 중입니다"
                    )
                }
            }
            // 카메라가 내는 4:3 그대로. 비율을 맞춰 두지 않으면 영상 양옆에 빈 띠가 생긴다.
            .aspectRatio(SOArmTeleopLayout.cameraAspect, contentMode: .fit)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
            .contentCard()
        }
    }
}

// MARK: - 확인 문구

/// 손으로 옮겨 적어야 열리는 게이트.
///
/// 문구를 미리 채워 주지 않는다. 채워 두면 남는 것은 버튼 하나이고, 그 버튼은 잘못
/// 눌리는 것을 막지 못한다. 여기서 지키려는 것은 *팔이 움직이기 직전에 사람이 한 번
/// 멈춰 서는 것*이며, 옮겨 적는 시간이 그 멈춤이다.
enum SOArmTeleopGate: String, Identifiable {
    case arm
    case releaseTorque

    var id: String { rawValue }

    var phrase: String {
        switch self {
        case .arm: SOArmVirtualLeaderClient.armConfirmation
        case .releaseTorque: SOArmVirtualLeaderClient.releaseConfirmation
        }
    }

    var title: String {
        switch self {
        case .arm: "조작 권한 받기"
        case .releaseTorque: "토크 해제"
        }
    }

    var copy: String {
        switch self {
        case .arm:
            "토크를 걸고 조작 권한을 받습니다. 이 순간부터 팔은 스스로 자세를 버티고, 3D에서 만진 값을 따라옵니다. 3D는 지금 팔의 자세로 맞춰져 있으므로 첫 명령에 팔이 튀지 않습니다."
        case .releaseTorque:
            "토크를 풀면 팔은 자기 무게를 버티지 못하고 **떨어집니다**. 팔을 손으로 받치고 있는 사람이 있을 때만 하세요."
        }
    }

    var isDangerous: Bool { self == .releaseTorque }

    /// 문구를 손으로 옮겨 적게 할 것인가.
    ///
    /// 조작 권한은 한 세션에 여러 번 받는다 — 잠깐 반납했다가 다시 잡고, 멈췄다가 다시
    /// 시작한다. 그때마다 열세 글자를 치게 하면 게이트가 아니라 통행세가 되고, 통행세는
    /// 사람을 신중하게 만들지 않는다. 대신 **한 번의 분명한 행동**을 요구한다: 현장을
    /// 확인했다는 체크 하나와 버튼(또는 Return).
    ///
    /// 토크 해제는 그대로 남긴다. 그쪽은 자주 하는 일이 아니고, 잘못 눌리면 팔이 떨어진다.
    /// 손으로 옮겨 적는 몇 초가 값을 하는 자리는 여기다.
    var requiresTypedPhrase: Bool { self == .releaseTorque }

    /// 체크박스에 적히는 말. 무엇을 확인했다고 말하는 것인지가 분명해야 한다.
    var acknowledgement: String {
        switch self {
        case .arm: "현장에 사람·장애물·케이블이 없고, 전원 차단 위치를 알고 있습니다"
        case .releaseTorque: "팔을 받치고 있는 사람이 있습니다"
        }
    }
}

private struct SOArmPhraseGate: View {
    let gate: SOArmTeleopGate
    /// 지금 팔이 멈춰 서 있는 이유. 없으면 아무것도 그리지 않는다.
    var reason: String?
    let confirm: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var typed = ""
    @State private var acknowledged = false

    /// 서버는 어느 쪽이든 정확한 문구를 요구한다. 달라지는 것은 **사람이 무엇을 하느냐**뿐이다
    /// — 옮겨 적거나, 확인에 체크하거나.
    private var matches: Bool {
        gate.requiresTypedPhrase ? typed == gate.phrase : acknowledged
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.l) {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text("MOTION AUTHORITY").font(.caption2).foregroundStyle(.tertiary)
                Text(gate.title).font(.title3).bold()
                Text(gate.copy)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Label(
                gate.isDangerous
                    ? "받쳐 줄 사람이 없으면 하지 마세요."
                    : "현장에 사람·장애물·케이블이 없는지, 전원 차단 위치가 어디인지 확인하세요.",
                systemImage: "exclamationmark.triangle.fill"
            )
            .font(.callout)
            .foregroundStyle(gate.isDangerous ? .red : .orange)
            .fixedSize(horizontal: false, vertical: true)

            if let reason {
                // 멈춘 이유를 여기서 읽는다. 확인을 누르면 이 멈춤이 함께 풀린다 —
                // 전에는 이유를 지우는 버튼과 권한을 받는 버튼이 따로였고, 순서를 모르면
                // "권한 받기"가 아무 말 없이 거절당했다.
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text("지금 멈춰 있는 이유").font(.caption).foregroundStyle(.secondary)
                    Text(reason).font(.callout).fixedSize(horizontal: false, vertical: true)
                    Text("확인하면 이 멈춤을 풀고, 이전 동작을 이어서 하지 않고 지금 자세에서 다시 시작합니다.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(Spacing.m)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
            }

            if gate.requiresTypedPhrase {
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text("아래 문구를 손으로 옮겨 적으세요")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(gate.phrase)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.disabled)
                    TextField("", text: $typed)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                        .autocorrectionDisabled()
                }
            } else {
                Toggle(gate.acknowledgement, isOn: $acknowledged)
                    .toggleStyle(.checkbox)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("취소") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(gate.title) {
                    // 서버가 요구하는 문구는 그대로 간다. 화면에서 달라진 것은 사람이
                    // 그것을 옮겨 적느냐, 확인에 체크하느냐뿐이다.
                    confirm(gate.requiresTypedPhrase ? typed : gate.phrase)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .tint(gate.isDangerous ? .red : .snuBlue)
                .disabled(!matches)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(Spacing.xl)
        .frame(width: 480)
    }
}

// MARK: - 3D 뷰어

/// 서버가 서빙하는 3D 뷰어를 품는다.
///
/// `?host=native`로 연다. 그 모드에서 페이지는 자기 WebSocket을 열지 않고, 주변 UI도
/// 그리지 않는다 — 리스와 전송은 `SOArmTeleopModel`이 쥐고 페이지는 그리기와 집기만 한다.
/// 두 곳에서 같은 리스로 명령을 보내면 순번이 엉키고, 서버는 그중 하나를 중복으로
/// 거절하게 된다.
struct SOArmViewerWebView: NSViewRepresentable {
    @ObservedObject var model: SOArmTeleopModel

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        // 메시나 three.js를 매번 다시 받지 않도록 기본(캐시 있는) 저장소를 쓴다. 콘솔
        // 웹뷰와 달리 여기서 오가는 것은 개인 정보가 아니라 정적 자산이다.
        configuration.userContentController.add(context.coordinator, name: "soarm")
        // 크기를 0으로 만들지 않는다. `WKWebView`는 첫 레이아웃에서 뷰포트를 정하는데,
        // 0×0으로 시작해 SwiftUI가 뒤에 자리를 잡아 주면 페이지는 계속 0×0인 화면을
        // 그린다 — 스크립트는 멀쩡히 돌고 서버 로그에도 요청이 남지만 아무것도 보이지
        // 않는다. 그 상태를 한참 들여다봤다.
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 960, height: 540), configuration: configuration)
        webView.autoresizingMask = [.width, .height]
        webView.navigationDelegate = context.coordinator
        // 콘솔 웹뷰와 달리 배경을 그리게 둔다. 투명하게 두었더니 3D가 올라오기 전까지
        // 뒤의 워터마크가 그대로 비쳐, 화면이 비어 있는 것처럼 보였다. 이 페이지는 자기
        // 배경색을 갖고 있으므로 그것을 그대로 쓰는 편이 맞다.
        webView.underPageBackgroundColor = .black
        context.coordinator.attach(webView)
        // 캐시를 무시하고 다시 받는다. 서버의 뷰어가 바뀌었는데 앱이 예전 스크립트를
        // 그대로 쓰면, 같은 3D를 쓴다는 이 설계의 전제가 조용히 깨진다. 정적 자산은
        // ETag로 대부분 304로 끝나므로 값은 싸다.
        webView.load(URLRequest(url: model.viewerURL, cachePolicy: .reloadIgnoringLocalCacheData))
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.model = model
        if webView.url == nil {
            webView.load(URLRequest(url: model.viewerURL, cachePolicy: .reloadIgnoringLocalCacheData))
        }
    }

    /// 제안받은 자리를 그대로 채운다. 이것을 말해 주지 않으면 SwiftUI가 이 뷰에 얼마를
    /// 줘야 하는지 알지 못해 크기가 정해지지 않은 채로 남는다.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: WKWebView, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions(by: CGSize(width: 480, height: 320))
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        coordinator.detach(webView)
        webView.stopLoading()
        webView.load(URLRequest(url: URL(string: "about:blank")!))
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var model: SOArmTeleopModel
        private weak var webView: WKWebView?

        init(model: SOArmTeleopModel) {
            self.model = model
        }

        func attach(_ webView: WKWebView) {
            self.webView = webView
            model.evaluate = { [weak webView] script in
                webView?.evaluateJavaScript(script, completionHandler: nil)
            }
        }

        func detach(_ webView: WKWebView) {
            webView.configuration.userContentController.removeScriptMessageHandler(forName: "soarm")
            model.evaluate = nil
            model.viewerWentAway()
        }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let payload = message.body as? [String: Any] else { return }
            switch payload["type"] as? String {
            case "ready":
                model.viewerBecameReady()
                model.noteViewerRenderer(payload["renderer"] as? String)
            case "error":
                model.viewerFailed((payload["message"] as? String) ?? "3D를 열지 못했습니다")
            case "target":
                let raw = payload["joints"] as? [String: Any] ?? [:]
                let joints = raw.compactMapValues { ($0 as? NSNumber)?.doubleValue }
                model.setTargets(joints, commanding: (payload["commanding"] as? Bool) ?? false)
            case "hold":
                model.holdNow()
            case "grab":
                break
            default:
                break
            }
        }

        /// 앱 창 안에서 임의의 웹이 열리는 경로는 만들지 않는다. 콘솔 웹뷰와 같은 규칙이다.
        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
        ) {
            let host = navigationAction.request.url?.host
            decisionHandler(host == nil || host == "127.0.0.1" || host == "localhost" ? .allow : .cancel)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            // 페이지가 `ready`를 보내지 못하는 경우(3D 로딩 실패)에도 다리는 살아 있어야
            // 화면이 무엇이 잘못됐는지 말할 수 있다.
            model.evaluate = { [weak webView] script in
                webView?.evaluateJavaScript(script, completionHandler: nil)
            }
        }
    }
}

// MARK: - 개요 타일

/// 개요에 놓이는 한 칸. `SOArmOverviewTile`과 같은 이유로, 화면을 열지 않은 상태를
/// "연결 실패"라고 말하지 않는다 — 아직 물어보지 않은 것이다.
struct SOArmTeleopOverviewTile: View {
    @ObservedObject var model: SOArmTeleopModel
    let open: () -> Void

    var body: some View {
        StatusTile(
            title: AppSection.soarmTeleop.title,
            value: value,
            detail: detail,
            symbol: AppSection.soarmTeleop.symbol,
            isBusy: model.state == .active,
            isAlarming: model.state.needsAcknowledgement,
            open: open
        )
    }

    private var value: String {
        switch model.connection {
        case .streaming: model.state.korean
        case .connecting: "연결 중"
        case .failed: "연결 실패"
        case .idle: model.server.isConfigured ? "연결 안 함" : "설정 필요"
        }
    }

    private var detail: String {
        if let fault = model.telemetry.fault { return fault.message }
        if let holder = model.telemetry.lease?.holder { return "\(holder) 조작 중" }
        guard model.server.isConfigured else { return "설정 › 로봇에서 서버 주소를 넣으세요" }
        return "화면을 열면 연결합니다"
    }
}
