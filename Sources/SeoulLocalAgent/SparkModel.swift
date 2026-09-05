import Foundation
import Combine
import SwiftUI

/// Spark 화면이 들고 있는 상태.
///
/// 이 모델이 하는 일은 세 가지뿐이다: 서버에 한 번씩 물어보고, 사람이 누른 것을 서버에
/// 전하고, 화면이 보이는 동안에만 그 반복을 유지하는 것. 순서를 정하거나 학습을 띄우는
/// 판단은 하나도 여기 없다 — 전부 서버의 큐가 한다. 그래야 앱을 꺼도 밤새 줄이 돈다.
@MainActor
final class SparkQueueModel: ObservableObject {
    @Published var server: SOArmServer { didSet { persist() } }

    @Published private(set) var machine = SparkMachine()
    @Published private(set) var snapshot = SparkSnapshot()
    @Published private(set) var kinds: [SparkJobKind] = []
    @Published private(set) var datasets: [SparkDataset] = []

    @Published private(set) var isLoading = false
    /// 처음 한 번은 화면 전체를 비워 두고 기다린다. 그 뒤로는 조용히 갱신한다 — 3초마다
    /// 화면이 깜빡이면 진행 막대를 읽을 수 없다.
    @Published private(set) var hasLoadedOnce = false
    @Published var errorMessage: String?

    /// 지금 서버에 보내 놓고 답을 기다리는 것들. 버튼을 두 번 눌러 같은 요청이 두 번
    /// 가지 않도록 잡아 둔다.
    @Published private(set) var busyJobID: String?
    @Published private(set) var isSubmitting = false
    @Published private(set) var isTogglingPause = false

    /// 로그를 펼쳐 둔 작업. 펼친 것만 서버에서 꼬리를 읽어 온다.
    @Published var expandedLogID: String?
    @Published private(set) var expandedLog: [String] = []

    private let store: SparkServerStore
    private var pollTask: Task<Void, Never>?
    private var isScreenVisible = false

    init(store: SparkServerStore = SparkServerStore()) {
        self.store = store
        server = store.load()
    }

    private var client: SparkQueueClient { SparkQueueClient(server: server) }

    var isConfigured: Bool { server.isConfigured }

    private func persist() { store.save(server) }

    // MARK: 화면 수명

    func screenAppeared() {
        isScreenVisible = true
        reload()
    }

    func screenDisappeared() {
        isScreenVisible = false
        pollTask?.cancel()
        pollTask = nil
        // 터널은 내리지 않는다. 이 화면은 오가며 자주 열리고, 그때마다 SSH를 다시 세우면
        // 매번 몇 초씩 빈 화면을 본다. 앱이 끝날 때는 `ActiveProcessRegistry`가 정리한다.
    }

    // MARK: 읽기

    func reload() {
        guard !isLoading else { return }
        guard isConfigured else {
            machine = SparkMachine()
            snapshot = SparkSnapshot()
            hasLoadedOnce = true
            return
        }
        isLoading = true
        Task { [client] in
            var next = SparkMachine()
            do {
                next = try await client.status()
            } catch {
                next.unreachable = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
            machine = next
            if next.isReachable {
                snapshot = (try? await client.snapshot()) ?? SparkSnapshot()
                // 종류와 데이터셋은 자주 바뀌지 않는다. 한 번 읽어 두고, 비어 있을 때만
                // 다시 읽는다 — 3초마다 같은 것을 네 번 물어볼 이유가 없다.
                if kinds.isEmpty { kinds = (try? await client.kinds()) ?? [] }
                datasets = (try? await client.datasets()) ?? []
                await refreshExpandedLog()
            } else {
                snapshot = SparkSnapshot()
            }
            isLoading = false
            hasLoadedOnce = true
            schedulePoll()
        }
    }

    /// 도는 것이 있으면 자주, 없으면 뜸하게. 화면이 보이지 않으면 아예 멈춘다.
    private func schedulePoll() {
        pollTask?.cancel()
        pollTask = nil
        guard isScreenVisible else { return }
        let seconds: Double = snapshot.running != nil ? 3 : 12
        pollTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.reload()
        }
    }

    private func refreshExpandedLog() async {
        guard let id = expandedLogID else {
            expandedLog = []
            return
        }
        expandedLog = (try? await client.log(id)) ?? []
    }

    func toggleLog(_ id: String) {
        if expandedLogID == id {
            expandedLogID = nil
            expandedLog = []
            return
        }
        expandedLogID = id
        expandedLog = []
        Task { await refreshExpandedLog() }
    }

    // MARK: 걸기와 세우기

    func enqueue(kind: String, parameters: [String: SparkParameter]) {
        guard !isSubmitting else { return }
        isSubmitting = true
        Task { [client] in
            do {
                _ = try await client.enqueue(kind: kind, parameters: parameters)
            } catch {
                errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
            isSubmitting = false
            reload()
        }
    }

    func cancel(_ id: String) {
        guard busyJobID == nil else { return }
        busyJobID = id
        Task { [client] in
            do {
                try await client.cancel(id)
            } catch {
                errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
            busyJobID = nil
            reload()
        }
    }

    func moveToTop(_ id: String) {
        guard busyJobID == nil else { return }
        busyJobID = id
        Task { [client] in
            do {
                try await client.moveToTop(id)
            } catch {
                errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
            busyJobID = nil
            reload()
        }
    }

    func setPaused(_ paused: Bool) {
        guard !isTogglingPause else { return }
        isTogglingPause = true
        Task { [client] in
            do {
                try await client.setPaused(paused)
            } catch {
                errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
            isTogglingPause = false
            reload()
        }
    }

    // MARK: 화면이 묻는 것들

    /// 이 칸에 채울 수 있는 값들. 데이터셋처럼 서버에서 오는 목록이면 그것을 쓴다.
    func choices(for field: SparkJobField) -> [String] {
        if field.type == .enum { return field.values }
        if field.source == "datasets" { return datasets.map(\.name) }
        return []
    }

    /// 걸기 창을 열 때 채워 둘 값. 서버가 정한 기본값이 먼저이고, 목록에서 오는 칸은
    /// 첫 번째 항목을 골라 둔다 — 빈 칸을 내밀고 사람이 채우기를 기다릴 이유가 없다.
    func initialParameters(for spec: SparkJobKind) -> [String: SparkParameter] {
        var values = spec.defaultParameters
        for field in spec.fields where values[field.name] == nil {
            if let first = choices(for: field).first { values[field.name] = .text(first) }
        }
        return values
    }

    /// 대기열이 다 돌려면 얼마나 걸리나 — 를 말하지 않는다.
    ///
    /// 남은 시간을 아는 것은 **도는 작업 하나뿐**이다. 대기 중인 학습이 몇 시간짜리인지는
    /// 돌려 보기 전에는 알 수 없고, 지어낸 총합은 자고 일어나 보면 늘 틀려 있다. 그래서
    /// 화면은 도는 것의 남은 시간만 말하고 줄의 길이는 개수로만 말한다.
    var runningETA: String? {
        guard let seconds = snapshot.running?.progress?.etaSeconds, seconds > 0 else { return nil }
        return SOArmFormat.duration(Double(seconds))
    }
}

/// `--spark-check` — 창을 열지 않고 학습 서버까지 가는 길을 끝까지 두드려 본다.
///
/// 화면을 띄우고 확인하는 것과 다른 점은 **어디서 끊겼는지**를 말한다는 것이다. 터널이
/// 안 열린 것과, 열렸는데 큐가 죽어 있는 것과, 큐는 사는데 데이터셋이 없는 것은 화면에서
/// 전부 `아직 없습니다`로 보이지만 고칠 자리는 전혀 다르다.
enum SparkConnectionCheck {
    static func run() async -> Bool {
        let server = SparkServerStore().load()
        guard server.isConfigured else {
            print("❌ 학습 서버가 설정되어 있지 않습니다. 설정 › 학습 서버에서 주소와 계정을 넣으세요.")
            return false
        }
        let addresses = server.candidateHosts.joined(separator: ", ")
        print("• 대상 \(server.user)@[\(addresses)] · 큐 \(server.baseURL.absoluteString) → 서버 \(server.remotePort)")

        let client = SparkQueueClient(server: server)
        let machine: SparkMachine
        do {
            machine = try await client.status()
        } catch {
            print("❌ \((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)")
            return false
        }
        defer { SOArmTunnel.spark.shutdownNow() }
        if let host = SOArmTunnel.spark.connectedHost {
            print("✅ SSH 터널을 열었습니다 · \(host)")
        } else {
            print("✅ 큐가 이미 이 포트에서 응답합니다 (터널을 새로 열지 않았습니다)")
        }
        print("✅ 기계 \(machine.host) · \(machine.gpuName)"
              + (machine.temperatureC.map { " · \($0)℃" } ?? "")
              + " · 디스크 \(SOArmFormat.size(Int(machine.diskFreeBytes))) 남음")

        var ok = true
        do {
            let kinds = try await client.kinds()
            if kinds.isEmpty {
                print("⚠️  걸 수 있는 작업 종류가 없습니다. 서버의 `~/sparkq/kinds/`를 확인하세요.")
                ok = false
            } else {
                for spec in kinds {
                    let fields = spec.fields.map(\.name).joined(separator: ", ")
                    print("✅ 작업 종류 \(spec.kind) · \(fields)")
                }
            }
        } catch {
            print("❌ 작업 종류를 읽지 못했습니다: \((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)")
            ok = false
        }

        do {
            let datasets = try await client.datasets()
            if datasets.isEmpty {
                // 실패가 아니다. 아직 아무것도 보내지 않았을 뿐이고, 그때 무엇을 해야
                // 하는지는 화면도 같은 문장으로 말한다.
                print("⚠️  학습 서버에 데이터셋이 없습니다. `수집 데이터` 화면에서 먼저 전송하세요.")
            } else {
                for dataset in datasets {
                    print("✅ 데이터셋 \(dataset.name) · 에피소드 \(dataset.episodes) · 프레임 \(dataset.frames)")
                }
            }
        } catch {
            print("❌ 데이터셋 목록을 읽지 못했습니다: \((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)")
            ok = false
        }

        do {
            let snapshot = try await client.snapshot()
            if let running = snapshot.running {
                let progress = running.progress
                let step = progress?.step.map(String.init) ?? "?"
                let steps = progress?.steps.map(String.init) ?? "?"
                print("✅ 도는 작업 \(running.title) · \(step)/\(steps)"
                      + (progress?.etaSeconds.map { " · 남은 시간 \(SOArmFormat.duration(Double($0)))" } ?? ""))
            } else if snapshot.paused {
                print("⚠️  큐가 일시정지 상태입니다. 대기 \(snapshot.queued.count)개.")
            } else if !snapshot.foreignApps.isEmpty {
                print("⚠️  큐 밖의 프로세스가 GPU를 쓰고 있어 기다리는 중입니다 (\(snapshot.foreignApps.count)개).")
            } else {
                print("✅ 도는 작업 없음 · 대기 \(snapshot.queued.count)개 · 끝난 것 \(snapshot.recent.count)개")
            }
            for job in snapshot.queued {
                print("   대기 \(job.id) · \(job.title)")
            }
        } catch {
            print("❌ 큐를 읽지 못했습니다: \((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)")
            ok = false
        }
        return ok
    }
}
