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
///
/// **시작에 확인 시트가 없다.** 물리 리더로 찍는 동안 팔로워는 사람이 리더를 움직이는
/// 만큼만 움직인다 — 사람의 손이 곧 게이트다. 무인으로 팔이 움직이는 재생에만 시트가 남았다.
struct SOArmRecordView: View {
    @ObservedObject var controller: AutomationController
    var body: some View {
        SOArmRecordScreen(model: controller.soarm) { controller.section = .soarmData }
    }
}

struct SOArmRecordScreen: View {
    @ObservedObject var model: SOArmConsoleModel
    /// 끝난 뒤 요약 카드에서 `수집 데이터`로 건너가는 길.
    var openDatasets: () -> Void = {}
    @ObservedObject private var cameraPolicy = SOArmCameraPolicy.shared
    @State private var cameraRowWidth: CGFloat = 0
    /// 어느 팔의 토크를 풀 것인가. 시트가 열려 있는 동안만 값이 있다.
    @State private var torqueGate: SOArmTorqueGate?
    /// 이 화면에 들어온 뒤로 수집이 한 번이라도 돌았는가.
    ///
    /// 서버의 `recording.logs`는 지난 실행의 것을 계속 들고 있다. 그것을 그대로 그리면,
    /// 앱을 막 켠 화면에 몇 시간 전 인코더 출력이 가득 차 있어 뭔가 돌고 있는 것처럼
    /// 보인다. 실제로 그 화면을 봤다.
    @State private var ranThisVisit = false

    init(model: SOArmConsoleModel, openDatasets: @escaping () -> Void = {}) {
        self.model = model
        self.openDatasets = openDatasets
    }

    var body: some View {
        WorkspaceScreen(title: AppSection.soarmRecord.title, subtitle: AppSection.soarmRecord.subtitle) {
            if let message = model.errorMessage {
                DismissibleError(message: message) { model.errorMessage = nil }
                    .transition(.appCard)
            }
            if isRecording {
                running
            } else {
                summary
                setup
                armStatus
            }
            cameras
            logs
        }
        .animation(.appContent, value: model.errorMessage)
        .animation(.appControl, value: isRecording)
        .animation(.appContent, value: model.lastRun)
        .animation(.appContent, value: model.showsDiagnosis)
        .sheet(item: $torqueGate) { gate in
            SOArmTorqueReleaseSheet(gate: gate) { model.releaseTorque(arm: gate.arm) }
        }
        .toolbar { toolbar }
        .onChange(of: isRecording) { _, running in if running { ranThisVisit = true } }
        .onAppear { model.recordScreenAppeared() }
        .onDisappear {
            ranThisVisit = false
            model.screenDisappeared()
        }
    }

    private var isRecording: Bool { model.status?.recording.running ?? false }
    private var runtime: SOArmRecordingRuntime? { model.status?.recordingRuntime }
    private var can: (SOArmCapability) -> Bool { { model.status?.can($0) ?? false } }

    // MARK: 툴바

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem {
            if isRecording {
                Button("끝내기", systemImage: "stop.fill") { model.stopRecording() }
                    .tint(.red)
                    .toolbarKeepsTitle()
                    .help(stopHelp)
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
                        TextField("What to demonstrate, in one sentence", text: $model.recordTask, axis: .vertical)
                            .lineLimit(1...3)
                            .textFieldStyle(.roundedBorder)
                        previousTasks
                    }
                    // 영어를 권하는 이유는 정책 쪽에 있다. ACT는 문장을 쓰지 않지만 SmolVLA·π0
                    // 같은 언어 조건 정책은 이 문장을 입력으로 받고, 그 모델들이 사전학습에서
                    // 본 지시문은 영어다. 한국어로 적어도 저장은 되지만 그 정책들에게는 낯선
                    // 입력이 된다.
                    Text("이 문장이 데이터셋의 지시문으로 들어갑니다. 언어 조건 정책(SmolVLA 등)이 그대로 읽으므로 **영어로, 한 동작을 끝까지** 적는 것을 권합니다 — `Pick up the red block and put it in the tray`. ACT는 문장을 쓰지 않습니다.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if !model.knownTasks.isEmpty {
                        Text("같은 과제를 더 찍는 것이라면 **반드시 쓰던 문장을 그대로 고르세요.** 한 글자만 달라도 다른 데이터셋이 됩니다.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Divider()

                destination

                Divider()

                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Stepper("한 회 최대 \(model.recordSeconds)초", value: $model.recordSeconds, in: 5...300, step: 5)
                    // 사용자가 "30초로 해 두고 빨리 끝났을 때"라고 말한 자리다. 그 기능은
                    // 이미 있었지만 이름이 `성공 저장`이라 시간과 관계있다는 것을 알 길이
                    // 없었다. 최대치라는 말과 함께 여기서 미리 알려 준다.
                    Text("**최대**입니다. 시연이 일찍 끝나면 `지금 저장`(⌘⏎)을 눌러 남은 시간을 기다리지 않고 다음 회로 넘어갑니다 — 회마다 시간을 다시 정할 필요가 없습니다.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Divider()

                HStack(spacing: Spacing.l) {
                    // 시트 없이 한 번이다. 리더를 쥔 사람의 손이 게이트이고, 확인할 것은
                    // 아래 한 줄에 늘 적혀 있다.
                    Button("수집 시작", systemImage: "record.circle") { model.startRecording() }
                        .buttonStyle(.borderedProminent)
                        .tint(.snuBlue)
                        .disabled(!canStart)
                        .help(model.status?.followerHeldElsewhere
                              ?? "시연을 LeRobot 데이터셋으로 찍습니다. 팔로워는 리더가 움직이는 만큼만 움직입니다")
                    Spacer()
                }
                Label(startCaption, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
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

    /// 시작 단추 옆의 한 줄. 서버가 부드러운 시작을 할 수 있으면 팔로워가 리더 자세까지
    /// 걸어간다고 적고, 못 하면 두 팔을 먼저 맞추라고 적는다 — 그때는 첫 틱에 팔로워가
    /// 리더 자세로 한 번에 따라붙기 때문이다.
    private var startCaption: String {
        let common = "현장에 사람·장애물·케이블이 없는지, 전원 차단 위치가 어디인지 확인하고 시작하세요. "
        if can(.softStart) {
            return common + "시작하면 팔로워가 리더 자세까지 천천히 걸어간 뒤 따라옵니다."
        }
        return common + "시작하는 순간 팔로워가 리더 자세로 **한 번에** 따라붙으므로, 두 팔을 비슷한 자세로 맞춘 뒤 시작하세요."
    }

    /// 어느 데이터셋에 들어가는가.
    ///
    /// 과제 하나가 데이터셋 하나여야 학습 단위가 된다. 같은 과제의 데이터셋이 있으면
    /// 거기에 이어 붙이는 것이 기본이고, 새로 만드는 것은 사람이 골랐을 때만이다.
    @ViewBuilder
    private var destination: some View {
        if let existing = model.resumableDataset {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Picker("저장할 곳", selection: $model.resumeExisting) {
                    Text("이어 찍기 · \(existing.name) (\(existing.episodes)회)").tag(true)
                    Text("새 데이터셋").tag(false)
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
                Text(model.resumeExisting
                     ? "같은 과제의 데이터셋에 회를 이어 붙입니다. 학습은 데이터셋 하나만 받으므로, 이렇게 모아 두어야 지금까지 찍은 회가 모두 학습에 들어갑니다. 마지막으로 찍은 때: \(existing.recordedAt?.formatted(date: .abbreviated, time: .shortened) ?? "모름")."
                     : "새 데이터셋을 만듭니다. 같은 과제가 두 데이터셋으로 갈리므로, 학습할 때 하나로 합치거나 하나만 골라야 합니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else if let old = model.incompatibleSameTaskDataset {
            // 서버가 센서 열을 저장하기 전에 찍힌 데이터셋. 열이 다르면 LeRobot이 이어 붙이기를
            // 거절하므로 새 데이터셋으로 간다. 같은 과제가 둘로 갈리지만, 두 데이터셋은 형태가
            // 달라 어차피 한 학습에 섞을 수 없다.
            Text("같은 과제의 데이터셋 `\(old.name)`(\(old.episodes)회)이 있지만 센서 열 없이 찍혀 이어 붙일 수 없습니다. 새 데이터셋을 만듭니다 — 이번부터는 부하·속도 등이 함께 저장됩니다.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } else if can(.resume) {
            Text(model.recordTask.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                 ? "과제 문장을 적으면 같은 과제의 데이터셋이 있는지 찾아 이어 찍을 수 있게 합니다."
                 : "이 과제로 찍은 데이터셋이 아직 없어 새로 만듭니다. 다음부터는 같은 문장을 고르면 여기에 이어 붙습니다.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            Text("서버가 매번 새 데이터셋을 만듭니다. 서버를 올리면 같은 과제에 이어 찍을 수 있습니다.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
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
                if can(.sensorExtras) {
                    // 나중에 무엇을 할지 모르니 서보가 내주는 것은 전부 남긴다. 다만 별도 열이다 —
                    // `observation.state`가 그대로여야 지금 학습과 사전학습 정규화가 깨지지 않는다.
                    Text("서보의 **부하·속도·온도·전압·상태·전류**와 프레임 시각, 카메라 새 프레임 여부도 별도 열로 함께 저장됩니다. `observation.state`는 위치 여섯 개 그대로라 지금 학습에는 영향이 없고, 나중에 부하를 정책 입력에 넣는 실험을 할 수 있습니다.")
                        .foregroundStyle(.secondary)
                }
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

    // MARK: 팔 상태

    /// 진단과 토크 해제. 찍는 사람이 머무는 화면이라 여기 있어야 한다 — 시작이 진단에서
    /// 막혔을 때 다른 화면으로 건너가 이유를 찾게 하면 안 된다.
    ///
    /// 토크는 더 이상 시작 조건이 아니다(서버가 `soft_start`를 할 수 있을 때). 걸려 있으면
    /// 팔이 자세를 버티고 있는 것이고, 그것은 지난 세션이 팔을 떨어뜨리지 않고 끝난 결과다.
    /// 그래서 `토크 해제`는 시작 절차가 아니라 **팔을 쉬게 하는 단추**로 여기 있다 — 모터가
    /// 중력을 버티며 뜨거워지므로, 온도를 보고 접힌 자세에서 풀어 준다.
    private var armStatus: some View {
        GroupBox("팔 상태") {
            VStack(alignment: .leading, spacing: Spacing.s) {
                HStack(spacing: Spacing.s) {
                    Button("환경 진단", systemImage: "stethoscope") { model.runDoctor() }
                        .disabled(!model.connection.isConnected || model.isModeRunning || model.isBusy)
                        .help("두 팔의 모터 ID·전압·토크·온도를 읽기만 합니다. 동작 명령은 보내지 않습니다")
                    if model.isBusy, model.showsDiagnosis {
                        ProgressView().controlSize(.small)
                        Text("두 serial bus를 읽는 중입니다…").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let arm = model.armsHoldingTorque.first {
                        Button("토크 해제…", systemImage: "bolt.slash") { torqueGate = SOArmTorqueGate(arm: arm) }
                            .tint(.red)
                            .disabled(model.isBusy || model.isModeRunning)
                            .help(can(.softStart)
                                  ? "팔이 힘을 놓습니다. 시작 조건이 아니라 팔을 쉬게 하는 단추입니다 — 접힌 자세에서, 받쳐 줄 수 있을 때 하세요"
                                  : "이전 세션이 남긴 토크를 풉니다. 이 서버는 토크가 걸려 있으면 시작을 거절합니다")
                    }
                    if model.showsDiagnosis {
                        Button {
                            model.showsDiagnosis = false
                        } label: {
                            Image(systemName: "xmark").font(.caption2)
                        }
                        .buttonStyle(.borderless)
                        .help("점검표 접기")
                    }
                }
                if model.showsDiagnosis {
                    ForEach(model.diagnosisChecks) { check in
                        SOArmCheckRow(check: check)
                    }
                } else if let doctor = model.doctor {
                    Label {
                        Text(doctor.arms.map(\.summary).joined(separator: " · "))
                            .fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: doctor.arms.contains(where: \.isHot) ? "thermometer.high" : "checkmark.seal")
                    }
                    .font(.caption)
                    .foregroundStyle(doctor.arms.contains(where: \.isHot) ? Color.orange : Color.secondary)
                } else {
                    Text(can(.softStart)
                         ? "아직 진단하지 않았습니다. `수집 시작`은 스스로 진단을 거치므로 미리 누를 필요는 없고, 토크가 걸려 있어도 시작합니다. 팔이 얼마나 뜨거운지 보거나 쉬게 하려면 여기서 봅니다."
                         : "아직 진단하지 않았습니다. 이 서버는 토크가 걸려 있으면 시작을 거절하므로, 지난 세션 뒤에는 여기서 진단하고 `토크 해제`를 누른 뒤 시작합니다.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: 끝난 뒤

    /// 방금 끝난 수집의 요약. 끝나는 순간 처음 화면으로 돌아가 버리면 몇 회를 찍었는지,
    /// 어디에 들어갔는지, 데이터가 괜찮았는지를 알 길이 없다.
    @ViewBuilder
    private var summary: some View {
        if let run = model.lastRun {
            GroupBox {
                VStack(alignment: .leading, spacing: Spacing.s) {
                    HStack(spacing: Spacing.s) {
                        Image(systemName: run.phase == "error" ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                            .foregroundStyle(run.phase == "error" ? Color.orange : Color.snuBlueLabel)
                        Text(run.phase == "error" ? "수집이 오류로 끝났습니다" : "수집이 끝났습니다")
                            .font(.callout.weight(.semibold))
                        Spacer()
                        Button {
                            model.dismissLastRun()
                        } label: {
                            Image(systemName: "xmark").font(.caption2)
                        }
                        .buttonStyle(.borderless)
                        .help("요약 닫기")
                    }
                    Text(summaryLine(run))
                        .font(.callout)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    if let concern = summaryConcern(run) {
                        Label(concern, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    HStack(spacing: Spacing.s) {
                        Button("수집 데이터에서 보기", systemImage: "film.stack") { openDatasets() }
                            .buttonStyle(.bordered)
                        if run.phase == "error" {
                            Text("아래 로그가 그때의 유일한 단서입니다.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .transition(.appCard)
        }
    }

    private func summaryLine(_ run: SOArmRecordingRuntime) -> String {
        var parts: [String] = []
        if let name = run.datasetName { parts.append(name + (run.resumed ? " (이어 찍음)" : "")) }
        if let saved = run.episodesSaved {
            parts.append("저장된 회 \(saved)개")
        } else if let index = run.episodeIndex {
            // 옛 서버는 저장된 회 수를 적어 주지 않는다. 마지막으로 시작한 회 번호로 어림한다.
            parts.append("마지막 회 \(index + 1)번째")
        }
        if !run.cameraStalePct.isEmpty {
            let cameras = run.cameraStalePct.keys.sorted().map { key in
                "\(SOArmCameraName.display(key)) " + String(format: "%.1f", run.cameraStalePct[key] ?? 0) + "%"
            }
            parts.append("중복 프레임 " + cameras.joined(separator: " / "))
        }
        if run.emptyEpisodesSkipped > 0 {
            parts.append("빈 회 \(run.emptyEpisodesSkipped)개 건너뜀")
        }
        if let warnings = model.status?.recording.slowLoopWarnings, warnings > 0 {
            parts.append("느린 루프 경고 \(warnings)번")
        }
        return parts.isEmpty ? "서버가 남긴 요약이 없습니다." : parts.joined(separator: " · ")
    }

    private func summaryConcern(_ run: SOArmRecordingRuntime) -> String? {
        if run.phase == "error" {
            let logs = model.status?.recording.logs ?? []
            if logs.contains(where: { $0.contains("You must add one or several frames") }) {
                // 실제로 난 사고다. 회 사이 저장 중에 들어온 키가 다음 회를 0프레임에서
                // 끝냈고, LeRobot이 빈 회를 저장하려다 죽었다. 앞 회들은 저장되어 있다.
                return "회 하나가 프레임 0장으로 끝나 LeRobot이 저장하다 죽었습니다. 회 사이 저장 중에 누른 키가 다음 회의 첫 틱에서 읽힌 것입니다. 그 전까지 저장된 회는 남아 있습니다. 서버를 올리면 저장 중의 키는 버려지고 빈 회는 건너뜁니다."
            }
            if let line = logs.last(where: { $0.contains("Error") || $0.contains("error") }) {
                return line
            }
        }
        if let warnings = model.status?.recording.slowLoopWarnings, warnings > 0 {
            return "루프가 30Hz를 못 지킨 구간이 있었습니다. 그 회들은 파일에는 30fps로 적히지만 실제 시간축이 늘어난 것이라, 학습 전에 `수집 데이터`의 관절 곡선으로 확인하세요."
        }
        if let worst = run.cameraStalePct.values.max(), worst > 5 {
            return "카메라가 같은 프레임을 \(String(format: "%.0f", worst))% 되돌려 줬습니다. 조명이 어둡거나 USB가 밀리는지 확인하세요."
        }
        return nil
    }

    // MARK: 찍는 동안

    private var running: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: Spacing.m) {
                HStack(spacing: Spacing.s) {
                    phaseIndicator
                    Text(runtime?.phaseTitle ?? "수집 중").font(.headline)
                    if let dataset = runtime?.datasetName {
                        Text(dataset + (runtime?.resumed == true ? " · 이어 찍는 중" : ""))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    Spacer()
                    if model.pendingControls > 0 {
                        Label("보내는 중", systemImage: "arrow.up.circle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                if let task = runtime?.task, !task.isEmpty {
                    Text(task).font(.callout).foregroundStyle(.secondary)
                }
                SOArmEpisodeClock(runtime: runtime, fallbackSeconds: model.recordSeconds)
                if runtime?.isSaving == true {
                    // 인코딩하는 동안 LeRobot의 루프는 서 있다. 리더를 움직여도 팔로워는
                    // 따라오지 않고, 다음 회가 시작되는 순간 그 자리로 한 번에 따라붙는다.
                    // 이때 누른 키는 서버가 버린다 — 루프가 없는 동안 걸어 둔 키는 다음 회
                    // 첫 틱에서 읽혀 그 회를 0프레임으로 끝냈다. 실제로 그렇게 한 회가 죽었다.
                    Label(savingText, systemImage: "hourglass")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let skipped = runtime?.emptyEpisodesSkipped, skipped > 0 {
                    Label("프레임 0장으로 끝난 회 \(skipped)개를 저장하지 않고 건너뛰었습니다. 회 번호는 그대로 이어집니다.", systemImage: "forward.end")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let key = runtime?.recentlyIgnoredControl() {
                    Label("방금 누른 \(SOArmRecordControl(rawValue: key)?.title ?? key)은(는) 루프가 서 있는 동안 들어와 서버가 버렸습니다. 다음 회가 시작되면 다시 누르세요.", systemImage: "hand.raised")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
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

    /// 저장 중에 적는 말. 서버가 직전 저장에 걸린 초를 알려 주면 그 숫자를 쓴다.
    ///
    /// 스트리밍 인코딩이 켜진 서버에서는 1초 안쪽이라 이 문구를 거의 볼 일이 없다. 길게
    /// 걸리는 서버(옛 방식, 회가 끝난 뒤 한꺼번에 굽는)에서만 왜 기다리는지를 말한다.
    private var savingText: String {
        let estimate = runtime?.savingSecondsEstimate ?? 0
        let wait = estimate >= 1 ? "약 \(Int(estimate.rounded()))초 걸립니다. " : ""
        return "방금 찍은 회의 영상을 굽는 중입니다. " + wait
            + "이 동안 키는 서버가 버리고 팔로워도 리더를 따라오지 않습니다 — 리더를 그대로 두세요."
            + (estimate >= 3 ? " 카메라 두 대의 프레임을 AV1로 압축하는 CPU 작업이라 회 길이에 비례해 걸립니다. 서버가 스트리밍 인코딩을 켜면 이 대기는 1초 안쪽이 됩니다." : "")
    }

    /// 단계마다 다른 표시. 늘 도는 스피너 하나를 두었더니 저장 중에도, 찍는 중에도 같은
    /// 것이 돌아 "뭐가 계속 돈다"로 읽혔다. 찍는 중은 빨간 점, 기다리는 단계에만 스피너.
    @ViewBuilder
    private var phaseIndicator: some View {
        if runtime?.isRecordingEpisode == true {
            Image(systemName: "record.circle.fill").foregroundStyle(.red)
        } else if runtime?.isResetting == true {
            Image(systemName: "arrow.counterclockwise.circle").foregroundStyle(.secondary)
        } else {
            ProgressView().controlSize(.small)
        }
    }

    /// 지금 단계에서 `끝내기`가 하는 일.
    private var stopHelp: String {
        switch model.stopControl {
        case .abort: "지금 찍는 회는 버리고 수집을 끝냅니다. 저장하려면 먼저 ⏎ (esc)"
        default:
            runtime?.isRecordingEpisode == true
                ? "지금 회를 저장하고 수집을 끝냅니다. 찍다 만 회도 저장됩니다 — 서버가 옛 버전이라 버릴 수 없습니다 (esc)"
                : "앞 회는 이미 저장됐습니다. 수집을 끝냅니다 (esc)"
        }
    }

    /// ⌘⏎·⇧⌘R을 받아 줄 단계인가. **찍는 중과 회 사이에서만** 듣는다.
    ///
    /// 그 밖의 단계 — 모터·카메라를 여는 중, 리더 자세까지 걸어가는 중, 방금 찍은 회를
    /// 굽는 중 — 에 눌린 것은 LeRobot의 `events`에 그대로 남아 **다음 회의 첫 틱에서 읽힌다.**
    /// `exit_early`가 남아 있으면 막 시작한 회가 곧바로 끝나고, 빈 회를 저장하려다 죽는다.
    /// 서버가 단계를 말해 주지 않는 동안(옛 서버, 시작 직후의 낡은 상태 파일)도 잠근다.
    private var controlsListen: Bool {
        runtime?.isRecordingEpisode == true || runtime?.isResetting == true
    }

    /// 단추들과 그 단축키. 시연을 끝낸 손은 마우스에 있지 않다.
    ///
    /// 단계마다 뜻이 다르다. 찍는 중의 ⌘⏎는 "이 회를 저장하고 다음으로", 회 사이의 ⌘⏎는
    /// "정리 시간을 기다리지 않고 바로 다음 회". 같은 키가 같은 자리에 있되 이름이 그때의
    /// 일을 말한다.
    /// 키는 **꾸밈 없는 한 개**다. 시연을 끝낸 손은 마우스에도, 수식 키에도 있지 않다.
    /// 사용자가 실제로 ⌘⏎을 몰라 ⏎만 눌렀고 아무 일도 없었다. 그래서 ⏎ · R · esc 가 본 키이고,
    /// LeRobot 자신의 키(→ · ← · esc)와 예전 ⌘ 조합은 같은 일을 하는 그림자 단추로 남긴다.
    /// 이 화면이 떠 있는 동안에는 글자를 받는 칸이 없으므로 맨 키가 안전하다.
    private var episodeControls: some View {
        let resetting = runtime?.isResetting == true
        let saving = !controlsListen
        return HStack(spacing: Spacing.s) {
            Button(resetting ? "다음 회 시작" : "지금 저장", systemImage: resetting ? "forward.fill" : SOArmRecordControl.success.symbol) {
                model.send(.success)
            }
            .buttonStyle(.borderedProminent)
            .tint(.snuBlue)
            .keyboardShortcut(.return, modifiers: [])
            .disabled(saving)
            .help(resetting
                  ? "정리 시간을 기다리지 않고 바로 다음 회를 시작합니다 (⏎ 또는 →)"
                  : "이번 시연을 데이터셋에 저장하고 남은 시간을 기다리지 않고 다음 회로 넘어갑니다 (⏎ 또는 →)")
            SOArmShadowShortcut(key: .rightArrow, modifiers: [], enabled: !saving) { model.send(.success) }
            SOArmShadowShortcut(key: .return, modifiers: .command, enabled: !saving) { model.send(.success) }

            Button(resetting ? "앞 회 다시 찍기" : "다시 찍기", systemImage: SOArmRecordControl.retry.symbol) {
                model.send(.retry)
            }
            .buttonStyle(.bordered)
            .tint(.orange)
            .keyboardShortcut("r", modifiers: [])
            .disabled(saving)
            .help(resetting
                  ? "방금 찍은 회를 버리고 같은 회를 다시 찍습니다 (R 또는 ←)"
                  : "이번 시연을 버리고 같은 회를 다시 찍습니다 (R 또는 ←)")
            SOArmShadowShortcut(key: .leftArrow, modifiers: [], enabled: !saving) { model.send(.retry) }
            SOArmShadowShortcut(key: "r", modifiers: [.command, .shift], enabled: !saving) { model.send(.retry) }

            Spacer()

            Button(model.stopControl == .abort ? "버리고 끝내기" : "끝내기", systemImage: SOArmRecordControl.stop.symbol) {
                model.stopRecording()
            }
            .buttonStyle(.bordered)
            .tint(.red)
            .keyboardShortcut(.escape, modifiers: [])
            .help(stopHelp)
            SOArmShadowShortcut(key: ".", modifiers: .command, enabled: true) { model.stopRecording() }
        }
    }

    private var shortcutLegend: some View {
        let resetting = runtime?.isResetting == true
        return HStack(spacing: Spacing.l) {
            SOArmShortcutHint(keys: "⏎", label: resetting ? "바로 다음 회" : "지금 저장하고 다음 회")
            SOArmShortcutHint(keys: "R", label: "버리고 다시")
            SOArmShortcutHint(keys: "esc", label: model.stopControl == .abort ? "이 회 버리고 끝내기" : "끝내기")
            Text("화살표 → ← 와 ⌘ 조합도 같은 일을 합니다")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    // MARK: 카메라

    /// 구도를 잡으라고 있는 것이지 고르라고 있는 것이 아니다. 수집이 도는 동안에는 서버가
    /// 카메라를 가져가므로 MJPEG 프리뷰는 열리지 않고, 대신 기록 루프가 남기는 스냅숏을
    /// 그린다(서버가 할 수 있을 때).
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
                        snapshot: model.recordingSnapshots[role],
                        snapshotsAvailable: can(.preview),
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

// MARK: - 그림자 단축키

/// 보이지 않는 단추 하나. 같은 일을 하는 키를 하나 더 받기 위해서만 있다.
///
/// SwiftUI는 단추 하나에 단축키 하나만 붙인다. ⏎ 이 본 키가 되면서 LeRobot 자신의 화살표 키와
/// 예전 ⌘ 조합을 버릴 이유는 없었다 — 손에 익은 사람은 그대로 누르면 된다.
private struct SOArmShadowShortcut: View {
    let key: KeyEquivalent
    let modifiers: EventModifiers
    let enabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) { EmptyView() }
            .keyboardShortcut(key, modifiers: modifiers)
            .disabled(!enabled)
            .frame(width: 0, height: 0)
            .opacity(0)
            .accessibilityHidden(true)
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

/// 이번 회가 몇 초 남았는가, 회 사이라면 다음 회까지 몇 초인가.
///
/// **서버가 시작 시각을 알려 줄 때만 센다.** 앱이 스스로 세는 길도 있었다 — 시작을
/// 누른 시각에 한 회 길이를 더해 가며 LeRobot의 루프를 흉내 내는 것이다. 그렇게 하면
/// 처음 몇 회는 맞다가 조용히 어긋난다. 회 사이의 정리 시간은 앱이 모르고, 시간이 다
/// 되어 끝난 회와 `지금 저장`으로 끝난 회의 경계도 앱에서는 구별되지 않기 때문이다.
/// 시계가 어긋나기 시작하면 남은 시간을 보고 손을 떼는 사람이 틀리게 된다.
///
/// 그래서 서버가 값을 주지 않는 동안에는 남은 시간을 적지 않고, 왜 못 적는지를 적는다.
struct SOArmEpisodeClock: View {
    let runtime: SOArmRecordingRuntime?
    /// 서버가 회 길이를 알려 주지 않을 때 화면에 적을 값. 앱이 시작할 때 보낸 값이다.
    let fallbackSeconds: Int

    /// 0.25초마다 다시 그리는 일정을 **SwiftUI가 쥔다.**
    ///
    /// 예전에는 `Timer.publish(...)`를 이 뷰의 프로퍼티로 두었다. 뷰는 구조체라 부모가 다시
    /// 그릴 때마다 새로 만들어지고, 그때마다 타이머도 새로 만들어져 **처음부터 0.25초를 다시
    /// 센다.** 수집 중에는 카메라 스냅숏이 초당 열 번 모델을 갱신하므로 이 뷰가 0.25초보다
    /// 자주 다시 만들어졌고, 타이머는 한 번도 발화하지 못했다. 그래서 `now`가 첫 렌더의
    /// 시각에 얼어붙고 경과가 0에 멈췄다 — 사용자가 본 "시간이 0초에서 멈추는" 화면이다.
    /// `TimelineView`의 일정은 뷰가 다시 만들어져도 이어지므로 같은 방식으로 깨지지 않는다.
    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.25)) { context in
            clock(now: context.date)
        }
    }

    /// 남은 초. 뷰에서 떼어 둔 것은 서버 시계가 앞서거나 값이 낡았을 때 무엇을 그리는지
    /// 화면 없이 확인하기 위해서다.
    static func remaining(now: Date, started: Date, total: Int) -> Double {
        max(0, Double(total) - max(0, now.timeIntervalSince(started)))
    }

    private func clock(now: Date) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            if let started = runtime?.episodeStartedAt, let total = runtime?.episodeSeconds, total > 0 {
                let elapsed = max(0, now.timeIntervalSince(started))
                let left = Self.remaining(now: now, started: started, total: total)
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
            } else if runtime?.isResetting == true, let started = runtime?.resetStartedAt, let total = runtime?.resetSeconds, total > 0 {
                // 회 사이 정리 구간. 서버가 시작 시각을 주므로 여기서는 센다. 그리고 이 시간은
                // **기다려야 하는 시간이 아니다** — LeRobot의 reset 루프도 `exit_early`를 듣는다.
                let elapsed = max(0, now.timeIntervalSince(started))
                let left = Self.remaining(now: now, started: started, total: total)
                HStack(alignment: .firstTextBaseline, spacing: Spacing.s) {
                    Text("다음 회까지 \(Int(left.rounded(.up)))초")
                        .font(.title2.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Spacer()
                    episodeCounter
                }
                ProgressView(value: min(elapsed, Double(total)), total: Double(total))
                    .tint(.secondary)
                Text("팔을 시작 자세로 되돌려 두세요. 준비가 끝났으면 기다리지 말고 ⏎로 바로 다음 회를 시작합니다 — 텔레옵은 이 동안에도 계속 따라옵니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                HStack(alignment: .firstTextBaseline, spacing: Spacing.s) {
                    Text("한 회 최대 \(runtime?.episodeSeconds ?? fallbackSeconds)초")
                        .font(.callout)
                    Spacer()
                    episodeCounter
                }
                Text(idleExplanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// 시계가 없는 동안 무슨 상황인지. 정상 동작을 한계처럼 읽히게 하지 않는다 — 실제로
    /// 수집을 돌려 보다가 "서버가 알려 주지 않아서 못 센다"는 문구가 정리 구간에 걸렸다.
    ///
    /// 이 문구가 보이는 시간은 서버가 다음 구간의 시작 시각을 적고 앱이 그것을 **읽어 올
    /// 때까지**다. 수집 중에는 0.4초마다 물으므로 눈에 띄지 않아야 한다 — 2초마다 물던
    /// 때에는 회가 시작하고 1~2초가 지나서야 시계가 나타나 그만큼 건너뛴 것처럼 보였다.
    private var idleExplanation: String {
        switch runtime?.phase {
        case "starting":
            "모터와 카메라를 여는 중입니다. 몇 초 걸립니다."
        case "aligning":
            "팔로워가 리더 자세까지 천천히 걸어가는 중입니다. 리더를 그대로 두세요."
        case "resetting":
            "다음 회를 준비하는 동안입니다. 팔을 시작 자세로 되돌려 두세요 — 준비가 끝났으면 ⏎로 바로 다음 회를 시작할 수 있습니다."
        case "saving":
            "방금 찍은 회를 저장하는 중입니다. 끝나면 다음 회가 시작됩니다."
        case "recording":
            // 서버가 방금 이 구간으로 넘어왔고 시작 시각이 아직 안 실렸다. 다음 폴링이면 온다.
            "시계를 맞추는 중입니다…"
        default:
            "남은 시간은 서버가 회의 시작 시각을 알려 줄 때 셉니다. 앱이 혼자 세면 회 사이 정리 시간만큼 조용히 어긋나고, 그 시계를 보고 손을 떼면 틀립니다."
        }
    }

    @ViewBuilder
    private var episodeCounter: some View {
        if let index = runtime?.episodeIndex {
            Text("\(index + 1)번째 시연" + (runtime?.episodesSaved.map { " · 저장 \($0)회" } ?? ""))
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }
}
