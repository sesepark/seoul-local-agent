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

    var body: some View {
        WorkspaceScreen(title: AppSection.soarmData.title, subtitle: AppSection.soarmData.subtitle) {
            if let message = model.errorMessage {
                DismissibleError(message: message) { model.errorMessage = nil }
            }
            if model.datasets.isEmpty {
                empty
            } else {
                HStack(alignment: .top, spacing: Spacing.l) {
                    VStack(alignment: .leading, spacing: Spacing.s) {
                        Text("데이터셋 \(model.datasets.count)개")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        datasetList
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

    private var datasetList: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            ForEach(model.datasets) { dataset in
                Button {
                    model.selectedDataset = dataset.name
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(dataset.name)
                            .font(.callout.weight(.medium))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text("에피소드 \(dataset.episodes)개 · \(SOArmFormat.duration(dataset.seconds))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("\(SOArmFormat.size(dataset.sizeBytes))\(dataset.recordedAt.map { " · " + $0.formatted(date: .numeric, time: .shortened) } ?? "")")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Spacing.s)
                }
                .buttonStyle(.plain)
                .contentCard(selected: model.selectedDataset == dataset.name)
            }
        }
    }

    @ViewBuilder
    private var detail: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            if let detail = model.datasetDetail {
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
