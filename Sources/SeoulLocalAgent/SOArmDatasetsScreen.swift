import SwiftUI
import AVKit
import Charts

/// 수집 데이터 화면.
///
/// 시연 결과가 서버에만 남고 앱에서는 볼 수 없던 자리를 채운다. 영상은 내려받지 않는다 —
/// 서버가 Range 요청에 답하므로 고른 에피소드의 구간만 읽어 재생한다. 데이터셋 하나가
/// 수 기가바이트로 자라도 이 Mac에 사본이 쌓이지 않는다.
///
/// 영상 옆에 **관절 곡선**을 함께 그린다. 영상은 멀쩡해 보이는데 관절값이 튄 회, 리더는
/// 움직였는데 팔로워가 따라가지 못한 회가 실제 문제이고, 그것은 곡선에서만 보인다.
struct SOArmDatasetsView: View {
    @ObservedObject var controller: AutomationController

    var body: some View {
        SOArmDatasetsWorkspace(model: controller.soarm)
    }
}

private struct SOArmDatasetsWorkspace: View {
    @ObservedObject var model: SOArmConsoleModel

    @State private var pendingReplay: SOArmStartRequest?
    @State private var pendingDelete: SOArmDeleteRequest?

    var body: some View {
        WorkspaceScreen(title: AppSection.soarmData.title, subtitle: AppSection.soarmData.subtitle) {
            if let message = model.errorMessage {
                DismissibleError(message: message) { model.errorMessage = nil }
            }
            replayPanel
            sparkPanel
            if model.datasets.isEmpty {
                empty
            } else {
                HStack(alignment: .top, spacing: Spacing.l) {
                    VStack(alignment: .leading, spacing: Spacing.s) {
                        Text("데이터셋 \(model.datasets.count)개")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        datasetList
                        checkpoints
                    }
                    .frame(width: 250)
                    detail
                }
            }
        }
        .animation(.appContent, value: model.datasets)
        .animation(.appContent, value: model.selectedDataset)
        .toolbar {
            // 개수 같은 정보는 툴바에 두지 않는다. 툴바 항목은 눌리는 것이어야 하고, 글자만
            // 있는 항목은 창이 좁아지면 캡슐 안에서 눌려 찌그러진다.
            ToolbarItem {
                Button("새로고침", systemImage: "arrow.clockwise") {
                    model.loadDatasets()
                    model.loadSpark()
                }
                .disabled(model.isLoadingDatasets)
                .help("서버의 data/ 폴더와 학습 서버를 다시 읽습니다")
            }
        }
        .onAppear { model.datasetsScreenAppeared() }
        .onDisappear { model.screenDisappeared() }
        .sheet(item: $pendingReplay) { request in
            SOArmConfirmationSheet(
                request: request, preview: model.replayPreview, isLoadingPreview: model.isLoadingReplayPreview
            ) {
                guard let dataset = model.selectedDataset, let episode = model.selectedEpisode else { return }
                model.startReplay(dataset: dataset, episode: episode)
            }
        }
        .sheet(item: $pendingDelete) { request in
            SOArmDeleteSheet(request: request) {
                switch request {
                case .dataset(let name): model.deleteDataset(name)
                case .episode(let index, _): model.deleteEpisode(index)
                }
            }
        }
        .animation(.appControl, value: model.status?.replay ?? SOArmReplay())
    }

    private var can: (SOArmCapability) -> Bool { { model.status?.can($0) ?? false } }

    // MARK: 팔로 재생

    private var replay: SOArmReplay { model.status?.replay ?? SOArmReplay() }

    /// 재생이 도는 동안에만 뜬다. **사람 손 없이 팔이 움직이는 유일한 경로**라, 지금 어느
    /// 단계이고 얼마나 왔는지, 그리고 정지가 화면 맨 위에 있어야 한다.
    @ViewBuilder
    private var replayPanel: some View {
        if replay.running || replay.phase == "error" {
            GroupBox {
                VStack(alignment: .leading, spacing: Spacing.s) {
                    HStack(spacing: Spacing.s) {
                        if replay.isMoving { ProgressView().controlSize(.small) }
                        Text(replay.phaseTitle).font(.headline)
                        if let dataset = replay.dataset, let episode = replay.episode {
                            Text("\(dataset) · \(episode + 1)번째")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("정지", systemImage: "stop.fill") { model.stopReplay() }
                            .buttonStyle(.borderedProminent)
                            .tint(.red)
                            .keyboardShortcut(".", modifiers: .command)
                            .disabled(!replay.running || model.isBusy)
                            .help("팔을 그 자리에 세웁니다. 토크는 걸린 채로 둡니다 — 팔이 든 것을 떨어뜨리지 않기 위해서입니다 (⌘.)")
                    }
                    if replay.phase == "aligning" {
                        // 이때 움직이는 것은 녹화된 동작이 아니라 출발점까지 가는 길이다.
                        Text("녹화 시작 자세까지 걸어가는 중입니다 · 약 \(String(format: "%.1f", replay.aligningSecondsLeft))초 남음")
                            .font(.caption).foregroundStyle(.secondary)
                        ProgressView().progressViewStyle(.linear).tint(.orange)
                    } else if replay.phase == "replaying" {
                        Text("\(replay.frame)/\(replay.totalFrames)프레임 · \(String(format: "%.2f", replay.speed))배속")
                            .font(.caption).foregroundStyle(.secondary)
                        ProgressView(value: replay.progress).tint(.snuBlue)
                    }
                    if let error = replay.error {
                        Label(SOArmServerText.korean(error), systemImage: "exclamationmark.triangle.fill")
                            .font(.caption).foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    /// 속도와 시작 버튼. 고른 회가 있어야 누를 수 있다.
    @ViewBuilder
    private var replayControls: some View {
        HStack(spacing: Spacing.s) {
            Picker("속도", selection: $model.replaySpeed) {
                ForEach(replay.speeds, id: \.self) { value in
                    Text("\(String(format: "%.2f", value))배").tag(value)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .disabled(replay.running)
            Button("팔로 재생", systemImage: "arrow.triangle.2.circlepath") {
                model.loadReplayPreview()
                pendingReplay = .replay
            }
            .buttonStyle(.bordered)
            .tint(.orange)
            .disabled(model.selectedEpisode == nil || replay.running || model.isModeRunning || model.isBusy)
            .help(model.isModeRunning
                  ? "다른 모드가 도는 동안에는 팔을 재생할 수 없습니다"
                  : "고른 회를 실제 팔에 다시 흘립니다. 먼저 시작 자세까지 천천히 걸어갑니다")
            Spacer()
        }
    }

    @ViewBuilder
    private var empty: some View {
        if model.isLoadingDatasets {
            EmptyResults(symbol: "film.stack", message: "서버에서 목록을 읽는 중입니다")
        } else if case .failed(let reason) = model.connection {
            EmptyResults(symbol: "exclamationmark.triangle", message: reason)
        } else {
            EmptyResults(
                symbol: "film.stack",
                message: "아직 수집한 데이터가 없습니다.\n`데이터 수집` 화면에서 시연을 찍으면 여기에 쌓입니다."
            )
        }
    }

    /// 과제 문장으로 묶은 데이터셋들. 폴더 두 겹이고, 그 안의 에피소드는 오른쪽 상세에 있다.
    ///
    /// **과제가 위, 데이터셋이 아래다.** 학습 데이터를 고르는 축이 세션이 아니라 과제이기
    /// 때문이다. 이어 찍기가 되는 서버에서는 과제 하나에 데이터셋 하나가 정상이고, 둘 이상
    /// 보이면 그것은 갈라진 것이다 — 학습은 그중 하나만 받는다.
    private var groupedDatasets: [(task: String, sessions: [SOArmDatasetSummary])] {
        var buckets: [String: [SOArmDatasetSummary]] = [:]
        for dataset in model.datasets {
            buckets[model.taskOf(dataset) ?? model.datasetTasks[dataset.name] ?? Self.unknownTask, default: []].append(dataset)
        }
        return buckets
            .map { (task: $0.key, sessions: $0.value.sorted { ($0.recordedAt ?? .distantPast) > ($1.recordedAt ?? .distantPast) }) }
            // 아직 과제를 못 읽은 묶음은 언제나 맨 아래. 잠깐 있다 사라지는 줄이 목록
            // 첫머리를 차지하면 그때마다 아래 줄들이 밀린다.
            .sorted { a, b in
                if (a.task == Self.unknownTask) != (b.task == Self.unknownTask) { return b.task == Self.unknownTask }
                return a.task < b.task
            }
    }

    private static let unknownTask = "과제를 읽는 중"

    private var datasetList: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            ForEach(groupedDatasets, id: \.task) { group in
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    HStack(spacing: Spacing.xs) {
                        Image(systemName: group.task == Self.unknownTask ? "folder.badge.questionmark" : "folder.fill")
                            .font(.caption)
                            .foregroundStyle(Color.snuBlueLabel)
                        Text(group.task)
                            .font(.callout.weight(.semibold))
                            .lineLimit(2)
                        Spacer(minLength: 0)
                        Text("\(group.sessions.reduce(0) { $0 + $1.episodes })회")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    if group.sessions.count > 1, group.task != Self.unknownTask {
                        // 같은 과제가 여러 데이터셋으로 갈라져 있다. 학습은 하나만 받는다.
                        Label("데이터셋 \(group.sessions.count)개로 갈라져 있습니다. 학습에는 하나만 들어가니, 다음부터는 `이어 찍기`로 모으세요.", systemImage: "exclamationmark.triangle")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    sessionRows(group.sessions)
                }
            }
        }
    }

    private func sessionRows(_ sessions: [SOArmDatasetSummary]) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            ForEach(sessions) { dataset in
                Button {
                    model.selectedDataset = dataset.name
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: Spacing.xs) {
                            // 세션의 이름표는 찍은 시각이다. `soarm101_20260905_072242`는
                            // 그 시각을 사람이 못 읽는 모양으로 적어 둔 것뿐이고, 전체
                            // 이름은 오른쪽 상세에 그대로 있다.
                            Text(dataset.recordedAt?.formatted(date: .abbreviated, time: .shortened) ?? dataset.name)
                                .font(.callout.weight(.medium))
                                .lineLimit(1)
                                .truncationMode(.middle)
                            if model.isOnSpark(dataset.name) {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.caption2)
                                    .foregroundStyle(Color.snuBlueLabel)
                                    .help("학습 서버에 있습니다")
                            }
                            if dataset.quality?.hasConcern == true {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .font(.caption2)
                                    .foregroundStyle(.orange)
                                    .help(dataset.quality?.text ?? "")
                            }
                        }
                        Text("에피소드 \(dataset.episodes)개 · \(SOArmFormat.duration(dataset.seconds)) · \(SOArmFormat.size(dataset.sizeBytes))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Spacing.s)
                }
                .buttonStyle(.plain)
                .contentCard(selected: model.selectedDataset == dataset.name)
                .contextMenu {
                    if can(.delete) {
                        Button("이 데이터셋 지우기…", systemImage: "trash", role: .destructive) {
                            pendingDelete = .dataset(dataset.name)
                        }
                    }
                }
            }
        }
        .padding(.leading, Spacing.m)
    }

    @ViewBuilder
    private var detail: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            if let detail = model.datasetDetail {
                header(detail.summary)
                transferRow(detail.summary)
                trainingRow(detail.summary)
                player
                cameraPicker(detail.summary.cameras)
                trajectoryChart
                episodes(detail.episodes)
            } else {
                EmptyResults(symbol: "film", message: "데이터셋을 읽는 중입니다")
                    .frame(height: 260)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 데이터셋 이름과 찍힐 때의 품질, 그리고 지우는 단추.
    private func header(_ summary: SOArmDatasetSummary) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.m) {
            VStack(alignment: .leading, spacing: 2) {
                Text(summary.name)
                    .font(.headline)
                    .textSelection(.enabled)
                if let quality = summary.quality {
                    // 파일만 봐서는 알 수 없는 것들이다. 루프가 30Hz를 지켰는지, 카메라가 같은
                    // 프레임을 얼마나 되돌려 줬는지는 찍힐 때의 로그에만 남는다.
                    Label(quality.text, systemImage: quality.hasConcern ? "exclamationmark.triangle.fill" : "checkmark.seal")
                        .font(.caption)
                        .foregroundStyle(quality.hasConcern ? Color.orange : Color.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let extras = summary.extrasText {
                    // 위치 말고 무엇이 함께 들어 있는가. 옛 데이터셋에는 이 줄이 없고, 그것이
                    // 두 데이터셋이 같은 학습에 섞이지 않는 이유가 된다.
                    Label("함께 저장된 열: \(extras)", systemImage: "waveform.path.ecg")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
            if can(.delete) {
                Button("지우기…", systemImage: "trash") { pendingDelete = .dataset(summary.name) }
                    .buttonStyle(.borderless)
                    .tint(.red)
                    .disabled(model.deletingDataset != nil || model.isModeRunning)
                    .help("데이터셋 폴더를 서버의 휴지통(data/.trash)으로 옮깁니다")
            }
        }
    }

    /// 학습 서버가 어떤 상태인지 한 줄.
    ///
    /// 못 붙어도 화면 전체를 막지 않는다. 이 화면의 본래 일은 녹화한 것을 보는 것이고,
    /// 학습 서버는 거기에 얹힌 다음 단계다. 그래서 실패는 이 칸 안에서만 말한다.
    @ViewBuilder
    private var sparkPanel: some View {
        let status = model.sparkStatus
        HStack(spacing: Spacing.m) {
            Image(systemName: (status?.isReachable ?? false) ? "cpu.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle((status?.isReachable ?? false) ? Color.snuBlueLabel : .secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text("학습 서버")
                    .font(.callout.weight(.medium))
                Text(sparkDetailLine(status))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()
            if model.isLoadingSpark {
                ProgressView().controlSize(.small)
            } else {
                Button("새로고침", systemImage: "arrow.clockwise") { model.loadSpark() }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .help("학습 서버 상태와 목록을 다시 읽습니다")
            }
        }
        .padding(Spacing.m)
        .glassPanel()
    }

    private func sparkDetailLine(_ status: SOArmSparkStatus?) -> String {
        guard let status else { return "상태를 읽는 중입니다" }
        guard status.isReachable else {
            return status.failure ?? "닿지 않습니다"
        }
        var parts: [String] = []
        if let gpu = status.gpuName { parts.append(gpu) }
        if let temperature = status.temperature { parts.append("\(temperature)°C") }
        if let watts = status.watts { parts.append(String(format: "%.0fW", watts)) }
        if status.diskFreeBytes > 0 { parts.append("여유 " + SOArmFormat.size(status.diskFreeBytes)) }
        if model.isAnyTraining { parts.append("학습 중") }
        return parts.isEmpty ? status.host : parts.joined(separator: " · ")
    }

    /// 고른 데이터셋을 학습 서버로 보내는 줄.
    ///
    /// 진행률 막대를 두지 않는다. 서버가 전송을 끝내고 한 번에 답하므로 보여 줄 숫자가 없고,
    /// 지어낸 막대는 멈춘 전송을 도는 것처럼 보이게 한다. 도는 동안 버튼을 잠그고 도는 중이라고만
    /// 말한다.
    private func transferRow(_ summary: SOArmDatasetSummary) -> some View {
        let isPushing = model.pushingDataset == summary.name
        let isOnSpark = model.isOnSpark(summary.name)
        let canPush = (model.sparkStatus?.isReachable ?? false) && model.pushingDataset == nil
        return HStack(spacing: Spacing.m) {
            VStack(alignment: .leading, spacing: 1) {
                Text(isOnSpark ? "학습 서버에 있습니다" : "아직 학습 서버에 없습니다")
                    .font(.callout.weight(.medium))
                Text(isOnSpark
                     ? "회를 더 찍었으면 `다시 전송`으로 바뀐 것만 보냅니다."
                     : "학습하려면 먼저 보내야 합니다. 콘솔 서버와 학습 서버 사이 LAN으로 흐르므로 이 Mac이 밖에 있어도 빠릅니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                model.pushToSpark(summary.name)
            } label: {
                if isPushing {
                    HStack(spacing: Spacing.xs) {
                        ProgressView().controlSize(.small)
                        Text("전송 중…")
                    }
                } else {
                    Label(isOnSpark ? "다시 전송" : "학습 서버로 전송", systemImage: "arrow.up.circle")
                }
            }
            .disabled(!canPush)
            .help(canPush ? "rsync로 보냅니다. 이미 있는 파일은 다시 보내지 않습니다" : "학습 서버에 닿지 않습니다")
        }
        .padding(Spacing.m)
        .contentCard()
    }

    /// 학습을 시작하는 줄. 서버가 `train`을 할 수 있을 때만 있다.
    ///
    /// 정책 두 가지 가운데 하나를 고를 뿐이다. 스텝·배치는 서버가 정한다 — 학습 서버의
    /// 실측이 그쪽에 있고, 처리량은 배치 8에서 이미 포화한다는 것을 아는 것도 그쪽이다.
    @ViewBuilder
    private func trainingRow(_ summary: SOArmDatasetSummary) -> some View {
        if can(.train) {
            let isOnSpark = model.isOnSpark(summary.name)
            let isStarting = model.startingTraining == summary.name
            let canStart = isOnSpark && (model.sparkStatus?.isReachable ?? false) && !model.isAnyTraining && model.startingTraining == nil
            VStack(alignment: .leading, spacing: Spacing.s) {
                HStack(spacing: Spacing.m) {
                    Picker("정책", selection: $model.trainingPolicy) {
                        ForEach(SOArmTrainingPolicy.allCases) { policy in
                            Text(policy.title).tag(policy)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    Spacer()
                    Button {
                        model.startTraining(summary.name)
                    } label: {
                        if isStarting {
                            HStack(spacing: Spacing.xs) {
                                ProgressView().controlSize(.small)
                                Text("띄우는 중…")
                            }
                        } else {
                            Label("학습 시작", systemImage: "play.fill")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.snuBlue)
                    .disabled(!canStart)
                    .help(trainingHelp(isOnSpark: isOnSpark))
                }
                Text(model.trainingPolicy.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("학습은 학습 서버의 tmux 안에서 돕니다. 이 앱을 닫아도 계속 돌고, 진행은 왼쪽 `학습된 정책`에 나타납니다. 끝난 체크포인트는 `회수`로 콘솔 서버에 내려옵니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(Spacing.m)
            .contentCard()
        }
    }

    private func trainingHelp(isOnSpark: Bool) -> String {
        if !isOnSpark { return "먼저 학습 서버로 전송하세요" }
        if model.isAnyTraining { return "학습이 이미 돌고 있습니다. 끝나거나 멈춘 뒤 시작할 수 있습니다" }
        if !(model.sparkStatus?.isReachable ?? false) { return "학습 서버에 닿지 않습니다" }
        return "학습 서버에서 \(model.trainingPolicy.title) 학습을 시작합니다"
    }

    /// 학습 서버에 쌓인 실행과 체크포인트.
    ///
    /// 회수하면 이 Mac이 아니라 콘솔 서버로 내려온다 — 추론은 팔이 붙어 있는 그 서버에서 돈다.
    @ViewBuilder
    private var checkpoints: some View {
        if !model.sparkRuns.isEmpty {
            VStack(alignment: .leading, spacing: Spacing.s) {
                Text("학습된 정책")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(model.sparkRuns) { run in
                    VStack(alignment: .leading, spacing: Spacing.xs) {
                        Text(run.name)
                            .font(.caption.weight(.medium))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(run.name)
                        if let training = run.training {
                            trainingProgress(run: run, training: training)
                        }
                        ForEach(run.checkpoints) { checkpoint in
                            HStack(spacing: Spacing.s) {
                                VStack(alignment: .leading, spacing: 0) {
                                    Text("step \(checkpoint.step)")
                                        .font(.caption2.monospacedDigit())
                                    Text(SOArmFormat.size(checkpoint.sizeBytes))
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                }
                                Spacer()
                                if model.pullingCheckpoint == "\(run.name)/\(checkpoint.step)" {
                                    ProgressView().controlSize(.small)
                                } else {
                                    Button("회수") {
                                        model.pullCheckpoint(run: run.name, step: checkpoint.step)
                                    }
                                    .buttonStyle(.borderless)
                                    .font(.caption2)
                                    .disabled(model.pullingCheckpoint != nil)
                                    .help("콘솔 서버로 내려받습니다")
                                }
                            }
                        }
                    }
                    .padding(Spacing.s)
                    .contentCard()
                }
            }
        }
    }

    /// 도는(또는 멈춘) 학습 한 줄. 진행 막대와 loss, 그리고 `중지`.
    private func trainingProgress(run: SOArmSparkRun, training: SOArmTrainingProgress) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: Spacing.xs) {
                if training.running { ProgressView().controlSize(.mini) }
                Text(training.text)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(training.running ? Color.snuBlueLabel : Color.secondary)
                    .lineLimit(2)
                Spacer(minLength: 0)
                if training.running {
                    if model.stoppingTraining == run.name {
                        ProgressView().controlSize(.mini)
                    } else {
                        Button("중지") { model.stopTraining(run.name) }
                            .buttonStyle(.borderless)
                            .font(.caption2)
                            .tint(.red)
                            .help("학습을 세웁니다. 지금까지 남긴 체크포인트는 그대로 남습니다")
                    }
                }
            }
            if training.steps > 0 {
                ProgressView(value: training.progress)
                    .tint(training.running ? .snuBlue : .secondary)
            }
            if let error = training.error {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .lineLimit(3)
                    .textSelection(.enabled)
            }
        }
    }

    @ViewBuilder
    private var player: some View {
        if let url = model.currentPlaybackURL {
            SOArmEpisodePlayer(url: url)
                .frame(maxWidth: .infinity, minHeight: 300, maxHeight: 300)
                .contentCard()
        } else {
            EmptyResults(symbol: "film", message: "에피소드를 고르면 그 구간만 재생합니다")
                .frame(maxWidth: .infinity, minHeight: 300, maxHeight: 300)
                .contentCard()
        }
    }

    @ViewBuilder
    private func cameraPicker(_ cameras: [String]) -> some View {
        if cameras.count > 1 {
            Picker("카메라", selection: Binding(
                get: { model.selectedCamera ?? cameras.first ?? "" },
                set: { model.selectedCamera = $0 }
            )) {
                ForEach(cameras, id: \.self) { key in
                    Text(SOArmCameraName.display(key)).tag(key)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
    }

    /// 고른 회의 관절 곡선 여섯 장. 실선이 팔로워가 실제로 있던 자리, 점선이 리더가 시킨 자리.
    @ViewBuilder
    private var trajectoryChart: some View {
        if let trajectory = model.trajectory, !trajectory.joints.isEmpty {
            SOArmTrajectoryGrid(trajectory: trajectory)
        } else if model.isLoadingTrajectory {
            HStack(spacing: Spacing.s) {
                ProgressView().controlSize(.small)
                Text("관절 곡선을 읽는 중입니다").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func episodes(_ list: [SOArmEpisode]) -> some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            episodeRows(list)
            replayControls
        }
    }

    private func episodeRows(_ list: [SOArmEpisode]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(list) { episode in
                if episode.index != list.first?.index { Divider() }
                Button {
                    model.selectedEpisode = episode.index
                } label: {
                    HStack(spacing: Spacing.m) {
                        Text("\(episode.index + 1)")
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 28, alignment: .trailing)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(episode.task.isEmpty ? "설명 없음" : episode.task)
                                .font(.callout)
                                .lineLimit(1)
                            Text("\(SOArmFormat.duration(episode.seconds)) · \(episode.frames)프레임"
                                 + (episode.seconds < 5 ? " · 짧습니다 — 찍다 만 회인지 확인하세요" : ""))
                                .font(.caption2)
                                .foregroundStyle(episode.seconds < 5 ? Color.orange : Color.secondary)
                        }
                        Spacer()
                        if model.deletingEpisode == episode.index {
                            ProgressView().controlSize(.small)
                        } else if model.selectedEpisode == episode.index {
                            // 고른 회에만 지우는 단추가 있다. 오른쪽 클릭 메뉴에만 두었더니
                            // 화면을 걸어 보는 사람이 찾을 길이 없었다 — 보이지 않는 기능은 없는 기능이다.
                            if can(.delete), let name = model.selectedDataset {
                                Button {
                                    pendingDelete = .episode(episode.index, dataset: name)
                                } label: {
                                    Image(systemName: "trash")
                                }
                                .buttonStyle(.borderless)
                                .tint(.red)
                                .disabled(model.deletingEpisode != nil || model.isModeRunning)
                                .help("이 회를 지웁니다. 원본은 서버의 휴지통에 남습니다")
                            }
                            Image(systemName: "play.circle.fill").foregroundStyle(Color.snuBlueLabel)
                        }
                    }
                    .padding(.vertical, Spacing.s)
                    .padding(.horizontal, Spacing.s)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .background(model.selectedEpisode == episode.index ? Color.snuBlue.opacity(0.12) : .clear)
                .contextMenu {
                    if can(.delete), let name = model.selectedDataset {
                        Button("이 회 지우기…", systemImage: "trash", role: .destructive) {
                            pendingDelete = .episode(episode.index, dataset: name)
                        }
                        .disabled(model.deletingEpisode != nil || model.isModeRunning)
                    }
                }
            }
        }
        .glassPanel()
    }
}

// MARK: - 관절 곡선

/// 여섯 관절을 두 줄로. 각 칸은 한 관절의 실제(실선)와 명령(점선)이다.
///
/// 회 하나가 900프레임쯤이라 여섯 관절 두 줄이면 만 점이 넘는다. 화면 폭이 그만큼 되지
/// 않으므로 폭에 맞춰 솎아 그린다 — 눈은 30장 가운데 한 장을 골라도 같은 곡선을 본다.
private struct SOArmTrajectoryGrid: View {
    let trajectory: SOArmTrajectory
    /// 어느 값을 그릴 것인가. 부하·속도 열은 서버가 함께 저장했을 때만 고를 수 있다.
    @State private var series: Series = .position

    enum Series: String, CaseIterable, Identifiable {
        case position, load, velocity

        var id: String { rawValue }

        var title: String {
            switch self {
            case .position: "위치"
            case .load: "부하"
            case .velocity: "속도"
            }
        }

        var caption: String {
            switch self {
            case .position:
                "실선이 팔로워가 실제로 있던 자리, 점선이 리더가 시킨 자리입니다. 두 줄이 벌어진 곳이 팔로워가 못 따라간 곳이고, 한 줄이 튄 곳이 시연이나 센서가 이상한 곳입니다. 영상만으로는 둘 다 보이지 않습니다."
            case .load:
                "서보가 내고 있는 힘의 대리 신호입니다(부호 포함, ±1000 눈금). 위치 P 제어라 자유롭게 움직일 때는 추종 오차를, 무언가에 닿아 제자리일 때는 접촉을 뜻합니다. 속도와 함께 봐야 둘이 갈립니다. 집게가 물체를 물고 평탄해지는 자리가 파지입니다."
            case .velocity:
                "서보가 읽은 속도입니다(raw 눈금/초). 부하가 높은데 속도가 0에 붙어 있으면 접촉이나 막힘입니다."
            }
        }
    }

    private var stride: Int { max(1, trajectory.frames / 240) }

    private var available: [Series] {
        var list: [Series] = [.position]
        if trajectory.hasLoad { list.append(.load) }
        if trajectory.hasVelocity { list.append(.velocity) }
        return list
    }

    /// 지난 프레임을 그대로 되돌려 준 자리들. 너무 많으면 앞의 300개만 긋는다 — 그때는
    /// 표시가 아니라 비율이 말해 준다.
    private var staleMarks: [Int] { Array(trajectory.staleFrames.prefix(300)) }

    var body: some View {
        let shown = available.contains(series) ? series : .position
        VStack(alignment: .leading, spacing: Spacing.s) {
            HStack(spacing: Spacing.m) {
                Text("관절 곡선").font(.callout.weight(.medium))
                if available.count > 1 {
                    Picker("값", selection: $series) {
                        ForEach(available) { item in Text(item.title).tag(item) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
                Text("\(trajectory.frames)프레임 \(SOArmFormat.duration(trajectory.seconds))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if trajectory.hasCameraFresh {
                    // 카메라가 같은 프레임을 두 번 준 자리. 곡선 위에 주황 세로선으로도 긋는다.
                    let count = trajectory.staleFrames.count
                    Text("중복 프레임 \(count)장 (" + String(format: "%.1f", trajectory.stalePercent) + "%)")
                        .font(.caption)
                        .foregroundStyle(trajectory.stalePercent > 5 ? Color.orange : Color.secondary)
                }
                if trajectory.hasSensorReadOk {
                    // 값이 틀린 행이 아니라 **새 판독이 아닌** 행이다. 부하로 접촉을 보는
                    // 분석에서는 빼야 하므로 몇 장인지 여기서 말한다.
                    let repeats = trajectory.repeatedSensorFrames.count
                    Text(repeats == 0 ? "서보 판독 전부 새 값" : "서보 판독 반복 \(repeats)장")
                        .font(.caption)
                        .foregroundStyle(repeats > 0 ? Color.orange : Color.secondary)
                        .help("블록 읽기가 실패해 직전 값을 그대로 다시 쓴 프레임입니다. 값을 고치지 않고 그 사실만 데이터셋에 남깁니다")
                }
                Spacer()
            }
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: Spacing.s) {
                ForEach(Array(trajectory.joints.enumerated()), id: \.offset) { index, joint in
                    jointChart(index: index, joint: joint, series: shown)
                }
            }
            Text(shown.caption)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Spacing.m)
        .glassPanel()
    }

    private func jointChart(index: Int, joint: String, series: Series) -> some View {
        let unit = joint == "gripper" ? "%" : "°"
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: Spacing.xs) {
                Text(SOArmTrajectory.label(joint)).font(.caption.weight(.medium))
                Spacer()
                headline(index: index, series: series, unit: unit)
            }
            chart(index: index, series: series)
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                        AxisGridLine()
                        AxisValueLabel().font(.caption2)
                    }
                }
                .chartYAxis {
                    AxisMarks(values: .automatic(desiredCount: 3)) { _ in
                        AxisGridLine()
                        AxisValueLabel().font(.caption2)
                    }
                }
                .frame(height: 96)
        }
    }

    @ViewBuilder
    private func headline(index: Int, series: Series, unit: String) -> some View {
        switch series {
        case .position:
            let gap = trajectory.largestGap(joint: index)
            Text("최대 차이 " + String(format: "%.1f", gap) + unit)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(gap > 15 ? Color.orange : Color.secondary)
        case .load:
            let peak = trajectory.load.reduce(0.0) { best, row in index < row.count ? max(best, abs(row[index])) : best }
            Text("최대 부하 " + String(format: "%.0f", peak))
                .font(.caption2.monospacedDigit())
                // 550은 서버 가상 리더의 정지 문턱, 800은 서보 자신이 토크를 떨어뜨리는 자리다.
                .foregroundStyle(peak >= 550 ? Color.orange : Color.secondary)
        case .velocity:
            let peak = trajectory.velocity.reduce(0.0) { best, row in index < row.count ? max(best, abs(row[index])) : best }
            Text("최대 " + String(format: "%.0f", peak) + "/s")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    private func chart(index: Int, series: Series) -> some View {
        let fps = Double(max(1, trajectory.fps))
        return Chart {
            switch series {
            case .position:
                ForEach(trajectory.points(joint: index, of: trajectory.action, stride: stride)) { point in
                    LineMark(x: .value("초", point.seconds), y: .value("명령", point.value), series: .value("줄", "명령"))
                        .foregroundStyle(Color.orange.opacity(0.8))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 2]))
                }
                ForEach(trajectory.points(joint: index, of: trajectory.state, stride: stride)) { point in
                    LineMark(x: .value("초", point.seconds), y: .value("실제", point.value), series: .value("줄", "실제"))
                        .foregroundStyle(Color.snuBlue)
                        .lineStyle(StrokeStyle(lineWidth: 1.5))
                }
            case .load:
                RuleMark(y: .value("0", 0)).foregroundStyle(.quaternary)
                ForEach(trajectory.points(joint: index, of: trajectory.load, stride: stride)) { point in
                    LineMark(x: .value("초", point.seconds), y: .value("부하", point.value), series: .value("줄", "부하"))
                        .foregroundStyle(Color.purple)
                        .lineStyle(StrokeStyle(lineWidth: 1.5))
                }
            case .velocity:
                RuleMark(y: .value("0", 0)).foregroundStyle(.quaternary)
                ForEach(trajectory.points(joint: index, of: trajectory.velocity, stride: stride)) { point in
                    LineMark(x: .value("초", point.seconds), y: .value("속도", point.value), series: .value("줄", "속도"))
                        .foregroundStyle(Color.teal)
                        .lineStyle(StrokeStyle(lineWidth: 1.5))
                }
            }
            // 카메라가 같은 프레임을 두 번 준 자리. 그 프레임의 영상은 직전 프레임과 같고
            // 관절값만 새 것이다 — 학습에서 빼거나 가중치를 줄 때 어디인지 알아야 한다.
            ForEach(staleMarks, id: \.self) { frame in
                RuleMark(x: .value("초", Double(frame) / fps))
                    .foregroundStyle(Color.orange.opacity(0.3))
                    .lineStyle(StrokeStyle(lineWidth: 1))
            }
        }
    }
}

// MARK: - 지우기 확인

/// 무엇을 지우는가. 확인은 체크 하나다 — 이 앱의 다른 게이트와 같다.
enum SOArmDeleteRequest: Identifiable, Equatable {
    case dataset(String)
    case episode(Int, dataset: String)

    var id: String {
        switch self {
        case .dataset(let name): "dataset:\(name)"
        case .episode(let index, let dataset): "episode:\(dataset):\(index)"
        }
    }

    var title: String {
        switch self {
        case .dataset: "데이터셋 지우기"
        case .episode: "회 지우기"
        }
    }

    var copy: String {
        switch self {
        case .dataset(let name):
            "`\(name)`을 통째로 지웁니다. 서버는 바로 지우지 않고 `data/.trash`로 옮기므로, 잘못 눌렀다면 서버에서 되돌릴 수 있습니다. 학습 서버에 보내 둔 사본은 그대로 남습니다."
        case .episode(let index, let dataset):
            "`\(dataset)`의 \(index + 1)번째 회를 지우고 나머지 회의 번호를 당겨 다시 씁니다. 영상을 다시 굽는 일이라 데이터셋이 크면 몇 분이 걸리고, 그동안 이 데이터셋은 만지지 마세요. 원본은 서버의 휴지통에 남습니다."
        }
    }

    var acknowledgement: String {
        switch self {
        case .dataset: "이 데이터셋을 지워도 된다는 것을 확인했습니다"
        case .episode: "이 회를 지워도 된다는 것을 확인했습니다"
        }
    }
}

private struct SOArmDeleteSheet: View {
    let request: SOArmDeleteRequest
    let confirm: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var acknowledged = false

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.l) {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text(request.title).font(.title3).bold()
                Text(request.copy)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Toggle(request.acknowledgement, isOn: $acknowledged)
                .toggleStyle(.checkbox)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("취소") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("지우기") {
                    confirm()
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .disabled(!acknowledged)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(Spacing.xl)
        .frame(width: 460)
    }
}

/// 한 에피소드를 재생한다.
///
/// 서버가 그 에피소드 구간만 잘라 H.264로 내주므로 여기서 할 일은 처음부터 트는 것뿐이다.
/// 원본은 AV1이라 이 Mac이 디코딩하지 못하고, 자르지 않으면 다음 에피소드까지 이어서
/// 재생된다 — 두 문제 모두 형식을 아는 서버 쪽에서 한 번에 해결된다.
private struct SOArmEpisodePlayer: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .inline
        view.videoGravity = .resizeAspect
        context.coordinator.attach(to: view, url: url)
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        context.coordinator.attach(to: view, url: url)
    }

    static func dismantleNSView(_ view: AVPlayerView, coordinator: Coordinator) {
        coordinator.stop()
        view.player = nil
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor
    final class Coordinator {
        private var player: AVPlayer?
        private var statusObserver: NSKeyValueObservation?
        private var loaded: URL?

        func attach(to view: AVPlayerView, url: URL) {
            guard loaded != url else { return }
            stop()
            loaded = url
            let item = AVPlayerItem(url: url)
            let player = AVPlayer(playerItem: item)
            // 로봇 녹화에는 소리가 없고, 있더라도 되돌려 보는 화면이 소리를 낼 이유는 없다.
            player.isMuted = true
            self.player = player
            view.player = player
            // 멈춰 있는 플레이어는 첫 프레임도 그리지 않는다. 고른 에피소드를 재생하는 것이
            // 이 화면이 하는 일이므로 준비되는 대로 튼다.
            statusObserver = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
                guard item.status == .readyToPlay else { return }
                Task { @MainActor [weak self] in self?.player?.play() }
            }
        }

        func stop() {
            statusObserver?.invalidate()
            statusObserver = nil
            player?.pause()
            player = nil
            loaded = nil
        }
    }
}

/// 사람이 읽는 크기와 길이.
enum SOArmFormat {
    static func size(_ bytes: Int) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useGB, .useKB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(bytes))
    }

    static func duration(_ seconds: Double) -> String {
        guard seconds > 0 else { return "0초" }
        let whole = Int(seconds.rounded())
        if whole < 60 { return "\(whole)초" }
        let minutes = whole / 60
        let rest = whole % 60
        if minutes >= 60 {
            let hours = minutes / 60
            let leftMinutes = minutes % 60
            return leftMinutes == 0 ? "\(hours)시간" : "\(hours)시간 \(leftMinutes)분"
        }
        return rest == 0 ? "\(minutes)분" : "\(minutes)분 \(rest)초"
    }
}
