import SwiftUI
import AVKit

/// 수집 데이터 화면.
///
/// 시연 결과가 서버에만 남고 앱에서는 볼 수 없던 자리를 채운다. 영상은 내려받지 않는다 —
/// 서버가 Range 요청에 답하므로 고른 에피소드의 구간만 읽어 재생한다. 데이터셋 하나가
/// 수 기가바이트로 자라도 이 Mac에 사본이 쌓이지 않는다.
struct SOArmDatasetsView: View {
    @ObservedObject var controller: AutomationController

    var body: some View {
        SOArmDatasetsWorkspace(model: controller.soarm)
    }
}

private struct SOArmDatasetsWorkspace: View {
    @ObservedObject var model: SOArmConsoleModel

    @State private var pendingReplay: SOArmStartRequest?

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
                Button("새로고침", systemImage: "arrow.clockwise") { model.loadDatasets() }
                    .disabled(model.isLoadingDatasets)
                    .help("서버의 data/ 폴더를 다시 읽습니다")
            }
        }
        .onAppear { model.datasetsScreenAppeared() }
        .onDisappear { model.screenDisappeared() }
        .sheet(item: $pendingReplay) { request in
            SOArmConfirmationSheet(request: request) {
                guard let dataset = model.selectedDataset, let episode = model.selectedEpisode else { return }
                model.startReplay(dataset: dataset, episode: episode)
            }
        }
        .animation(.appControl, value: model.status?.replay ?? SOArmReplay())
    }

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
                        Label(error, systemImage: "exclamationmark.triangle.fill")
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
                message: "아직 수집한 데이터가 없습니다.\nSO-ARM 101 화면에서 데이터 수집을 시작하면 여기에 쌓입니다."
            )
        }
    }

    /// 과제 문장으로 묶은 세션들. 폴더 두 겹이고, 그 안의 에피소드는 오른쪽 상세에 있다.
    ///
    /// **과제가 위, 세션이 아래다.** 학습 데이터를 고르는 축이 세션이 아니라 과제이기
    /// 때문이다 — "이 과제 시연 전부"가 한 덩이이고, 세션 이름(`soarm101_20260905_072242`)
    /// 은 타임스탬프라 무엇을 찍은 것인지 한 글자도 말해 주지 않는다.
    private var groupedDatasets: [(task: String, sessions: [SOArmDatasetSummary])] {
        var buckets: [String: [SOArmDatasetSummary]] = [:]
        for dataset in model.datasets {
            buckets[model.datasetTasks[dataset.name] ?? Self.unknownTask, default: []].append(dataset)
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
            }
        }
        .padding(.leading, Spacing.m)
    }

    @ViewBuilder
    private var detail: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            if let detail = model.datasetDetail {
                transferRow(detail.summary)
                player
                cameraPicker(detail.summary.cameras)
                episodes(detail.episodes)
            } else {
                EmptyResults(symbol: "film", message: "데이터셋을 읽는 중입니다")
                    .frame(height: 260)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
                    .lineLimit(1)
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
                Text(summary.name)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(isOnSpark ? "학습 서버에 있습니다" : "아직 학습 서버에 없습니다")
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

    /// 학습 서버에 쌓인 체크포인트.
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
                            Text("\(SOArmFormat.duration(episode.seconds)) · \(episode.frames)프레임")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        Spacer()
                        if model.selectedEpisode == episode.index {
                            Image(systemName: "play.circle.fill").foregroundStyle(Color.snuBlueLabel)
                        }
                    }
                    .padding(.vertical, Spacing.s)
                    .padding(.horizontal, Spacing.s)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .background(model.selectedEpisode == episode.index ? Color.snuBlue.opacity(0.12) : .clear)
            }
        }
        .glassPanel()
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
        return rest == 0 ? "\(minutes)분" : "\(minutes)분 \(rest)초"
    }
}
