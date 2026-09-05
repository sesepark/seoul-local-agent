import SwiftUI

/// 학습 서버 화면.
///
/// 이 화면이 답해야 하는 질문은 셋이다 — **지금 뭐가 돌고 있나, 뭐가 기다리고 있나,
/// 밤새 돌린 것은 어떻게 됐나.** 그래서 세 덩이로만 나뉘고, 그 밖의 것(기계 상태)은
/// 맨 아래 한 줄로 내려간다.
///
/// 순서를 정하는 것은 서버의 큐다. 이 화면에서 `맨 앞으로`를 눌러도 **도는 작업을
/// 밀어내지 않는다** — 학습은 몇 시간짜리이고 중간에 뺏으면 처음부터 다시 해야 한다.
/// 바뀌는 것은 아직 시작하지 않은 줄의 순서뿐이다.
struct SparkView: View {
    @ObservedObject var controller: AutomationController

    var body: some View {
        SparkWorkspace(model: controller.spark)
    }
}

private struct SparkWorkspace: View {
    @ObservedObject var model: SparkQueueModel
    @State private var pendingKind: SparkJobKind?

    var body: some View {
        WorkspaceScreen(title: AppSection.spark.title, subtitle: AppSection.spark.subtitle) {
            if let message = model.errorMessage {
                DismissibleError(message: message) { model.errorMessage = nil }
            }
            if !model.isConfigured {
                notConfigured
            } else if !model.machine.isReachable && model.hasLoadedOnce {
                unreachable
            } else {
                runningPanel
                queuePanel
                recentPanel
                machinePanel
            }
        }
        .animation(.appContent, value: model.snapshot)
        .animation(.appContent, value: model.machine)
        .toolbar {
            ToolbarItem {
                Menu("작업 걸기", systemImage: "plus") {
                    ForEach(model.kinds) { spec in
                        Button(spec.label, systemImage: spec.icon) { pendingKind = spec }
                    }
                }
                .disabled(model.kinds.isEmpty || !model.machine.isReachable)
                .help(model.kinds.isEmpty ? "학습 서버에 닿으면 걸 수 있는 작업이 나옵니다" : "줄 맨 뒤에 세웁니다")
            }
            ToolbarItem {
                Button("새로고침", systemImage: "arrow.clockwise") { model.reload() }
                    .disabled(model.isLoading)
                    .help("학습 서버의 큐를 다시 읽습니다")
            }
        }
        .onAppear { model.screenAppeared() }
        .onDisappear { model.screenDisappeared() }
        .sheet(item: $pendingKind) { spec in
            SparkEnqueueSheet(model: model, spec: spec)
        }
    }

    // MARK: 지금 도는 것

    @ViewBuilder
    private var runningPanel: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            HStack {
                Text("지금 도는 것")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                pauseToggle
            }
            if let job = model.snapshot.running {
                SparkRunningCard(model: model, job: job)
            } else {
                idleCard
            }
        }
    }

    /// 일시정지는 체크박스 하나다. 되돌리는 것도 같은 한 번이고, 위험한 동작이 아니다.
    private var pauseToggle: some View {
        Toggle(isOn: Binding(
            get: { model.snapshot.paused },
            set: { model.setPaused($0) }
        )) {
            Text("다음 작업 꺼내지 않기")
                .font(.caption)
        }
        .toggleStyle(.checkbox)
        .disabled(model.isTogglingPause || !model.machine.isReachable)
        .help("켜 두면 도는 작업이 끝나도 다음 것을 시작하지 않습니다. 도는 작업은 그대로 둡니다")
    }

    /// 도는 것이 없을 때. **왜** 없는지를 말하는 것이 이 칸의 요점이다.
    private var idleCard: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Label(idleHeadline, systemImage: idleSymbol)
                .font(.callout.weight(.medium))
            Text(idleDetail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(model.snapshot.foreignApps) { app in
                Text("pid \(app.pid) · \(app.shortName) · \(app.memoryMiB) MiB")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Spacing.m)
        .contentCard()
    }

    private var idleHeadline: String {
        if model.snapshot.paused { return "일시정지됨" }
        if !model.snapshot.foreignApps.isEmpty { return "큐 밖의 작업이 GPU를 쓰고 있습니다" }
        if model.snapshot.queued.isEmpty { return "쉬고 있습니다" }
        return "곧 시작합니다"
    }

    private var idleSymbol: String {
        if model.snapshot.paused { return "pause.circle" }
        if !model.snapshot.foreignApps.isEmpty { return "exclamationmark.triangle" }
        return "moon.zzz"
    }

    private var idleDetail: String {
        if model.snapshot.paused {
            return "체크를 풀면 줄에서 다음 것을 꺼냅니다. 대기 중 \(model.snapshot.queued.count)개."
        }
        if !model.snapshot.foreignApps.isEmpty {
            // 터미널에서 손으로 띄운 학습이 있으면 큐는 그 위에 올라타지 않는다. 이 기계의
            // GPU는 하나이고, 겹치면 둘 다 느려지기 때문이다.
            return "터미널에서 직접 띄운 학습이 있으면 큐는 그 위에 올라타지 않습니다. 그것이 끝나면 다음 작업이 시작됩니다."
        }
        if model.snapshot.queued.isEmpty {
            return "줄이 비어 있습니다. 오른쪽 위 `작업 걸기`로 세워 두면 순서대로 하나씩 돕니다."
        }
        return "잠시 뒤에 줄 맨 앞의 작업이 시작됩니다."
    }

    // MARK: 대기열

    @ViewBuilder
    private var queuePanel: some View {
        if !model.snapshot.queued.isEmpty {
            VStack(alignment: .leading, spacing: Spacing.s) {
                Text("대기 \(model.snapshot.queued.count)개")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(Array(model.snapshot.queued.enumerated()), id: \.element.id) { index, job in
                    SparkQueuedRow(model: model, job: job, position: index + 1)
                }
            }
        }
    }

    // MARK: 끝난 것

    @ViewBuilder
    private var recentPanel: some View {
        if !model.snapshot.recent.isEmpty {
            VStack(alignment: .leading, spacing: Spacing.s) {
                Text("끝난 작업")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(model.snapshot.recent) { job in
                    SparkFinishedRow(model: model, job: job)
                }
            }
        } else if model.hasLoadedOnce && model.snapshot.running == nil && model.snapshot.queued.isEmpty {
            EmptyResults(symbol: "square.stack.3d.up.slash", message: "아직 이 큐로 돌린 작업이 없습니다")
        }
    }

    // MARK: 기계

    private var machinePanel: some View {
        let m = model.machine
        return VStack(alignment: .leading, spacing: Spacing.m) {
            // 사용률 셋을 나란히. 통합메모리라 RAM 사용률이 곧 이 기계가 얼마나 찼는지다.
            HStack(spacing: Spacing.l) {
                meter("GPU", m.gpuUtilizationPercent.map { Double($0) / 100 },
                      caption: m.gpuUtilizationPercent.map { "\($0)%" } ?? "-",
                      symbol: "cpu")
                meter("CPU", m.cpuPercent.map { $0 / 100 },
                      caption: m.cpuPercent.map { String(format: "%.0f%%", $0) } ?? "-",
                      symbol: "cpu.fill")
                meter("메모리", m.ramFraction,
                      caption: ramCaption(m), symbol: "memorychip")
            }
            Divider()
            HStack(spacing: Spacing.l) {
                machineItem("기계", m.host.isEmpty ? "-" : m.host, "server.rack")
                if !m.gpuName.isEmpty { machineItem("GPU", m.gpuName, "cpu") }
                if let temperature = m.temperatureC {
                    machineItem("온도", "\(temperature)℃", "thermometer.medium")
                }
                if let power = m.powerW {
                    machineItem("전력", String(format: "%.0f W", power), "bolt")
                }
                machineItem("디스크", SOArmFormat.size(Int(m.diskFreeBytes)) + " 남음", "internaldrive")
                Spacer(minLength: 0)
            }
        }
        .padding(Spacing.m)
        .contentCard()
    }

    /// 사용률 미터 하나. 값이 없으면(서버가 못 읽었으면) 막대를 비워 두고 `-`만 적는다 —
    /// GB10의 GPU 전용 메모리처럼 없는 값을 0%로 그리면 "안 쓰는 중"으로 잘못 읽힌다.
    private func meter(_ label: String, _ fraction: Double?, caption: String, symbol: String) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack(spacing: Spacing.xs) {
                Label(label, systemImage: symbol)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Text(caption)
                    .font(.caption.monospacedDigit().weight(.medium))
            }
            ProgressView(value: fraction ?? 0)
                .tint(meterTint(fraction))
                .opacity(fraction == nil ? 0.3 : 1)
        }
        .frame(maxWidth: .infinity)
    }

    /// 높을수록 눈에 띈다. 90%가 넘으면 빨강 — 자는 동안 무언가 꽉 찼다는 신호다.
    private func meterTint(_ fraction: Double?) -> Color {
        guard let fraction else { return .secondary }
        if fraction >= 0.9 { return .red }
        if fraction >= 0.7 { return .orange }
        return .snuBlue
    }

    private func ramCaption(_ m: SparkMachine) -> String {
        guard let used = m.ramUsedBytes, let total = m.ramTotalBytes, total > 0 else { return "-" }
        return "\(SOArmFormat.size(Int(used))) / \(SOArmFormat.size(Int(total)))"
    }

    private func machineItem(_ label: String, _ value: String, _ symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Label(label, systemImage: symbol)
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Text(value)
                .font(.caption.monospacedDigit())
                .lineLimit(1)
        }
    }

    // MARK: 아직 못 붙었을 때

    private var notConfigured: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            Label("학습 서버 주소가 아직 없습니다", systemImage: "gearshape")
                .font(.callout.weight(.medium))
            Text("설정 › 학습 서버에서 주소와 계정을 넣고, 이 앱 전용 공개키를 서버에 한 번 등록하면 됩니다. 팔이 붙은 콘솔 서버와는 다른 기계이므로 열쇠도 따로 씁니다 — 한쪽 접근만 끊을 수 있어야 하기 때문입니다.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            SettingsLink { Text("설정 열기") }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Spacing.m)
        .contentCard()
    }

    private var unreachable: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            Label("학습 서버에 닿지 못했습니다", systemImage: "wifi.exclamationmark")
                .font(.callout.weight(.medium))
            Text(model.machine.unreachable)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Text("도는 학습은 이 화면과 무관하게 서버에서 계속 돕니다. 여기서 보이지 않는 것은 길이 끊긴 것이지 학습이 멈춘 것이 아닙니다.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Spacing.m)
        .contentCard()
    }
}

// MARK: - 도는 작업 한 장

private struct SparkRunningCard: View {
    @ObservedObject var model: SparkQueueModel
    let job: SparkJob

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.s) {
                ProgressView().controlSize(.small)
                VStack(alignment: .leading, spacing: 2) {
                    Text(job.title)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    let summary = job.summary(using: model.kinds)
                    if !summary.isEmpty {
                        Text(summary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: Spacing.s)
                if model.busyJobID == job.id {
                    ProgressView().controlSize(.small)
                } else {
                    Button("중지") { model.cancel(job.id) }
                        .buttonStyle(.borderless)
                        .tint(.red)
                        .help("학습을 세웁니다. 지금까지 남긴 체크포인트는 그대로 남습니다")
                }
            }
            progress
            if !(job.progress?.logTail.isEmpty ?? true) {
                logTail
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Spacing.m)
        .contentCard()
    }

    @ViewBuilder
    private var progress: some View {
        let detail = job.progress ?? SparkProgress()
        VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack(spacing: Spacing.s) {
                Text(stepText(detail))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(Color.snuBlueLabel)
                if let loss = detail.loss {
                    Text(String(format: "loss %.4f", loss))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                if let reward = detail.reward {
                    Text(String(format: "reward %.2f", reward))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if let eta = model.runningETA {
                    Text("남은 시간 \(eta)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            // 총량을 모르면 막대 대신 도는 표시를 쓴다. 0%에 붙어 있는 막대는 "진행이
            // 없다"로 읽히는데, 실제로는 아직 몇 스텝인지 로그가 말하지 않은 것뿐이다.
            if let fraction = detail.fraction {
                ProgressView(value: fraction).tint(.snuBlue)
            } else {
                ProgressView().progressViewStyle(.linear).tint(.snuBlue)
            }
        }
    }

    private func stepText(_ detail: SparkProgress) -> String {
        guard let step = detail.step else { return "시작하는 중" }
        guard let steps = detail.steps else { return "\(step)" }
        return "\(step) / \(steps)"
    }

    private var logTail: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(Array((job.progress?.logTail ?? []).enumerated()), id: \.offset) { _, line in
                Text(line)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }
}

// MARK: - 대기 한 줄

private struct SparkQueuedRow: View {
    @ObservedObject var model: SparkQueueModel
    let job: SparkJob
    let position: Int

    var body: some View {
        HStack(spacing: Spacing.s) {
            Text("\(position)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.tertiary)
                .frame(width: 18, alignment: .trailing)
            VStack(alignment: .leading, spacing: 2) {
                Text(job.title)
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.middle)
                let summary = job.summary(using: model.kinds)
                if !summary.isEmpty {
                    Text(summary)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: Spacing.s)
            if model.busyJobID == job.id {
                ProgressView().controlSize(.small)
            } else {
                if position > 1 {
                    Button("맨 앞으로") { model.moveToTop(job.id) }
                        .buttonStyle(.borderless)
                        .font(.caption)
                        .help("아직 시작하지 않은 줄의 순서만 바꿉니다. 도는 작업은 밀어내지 않습니다")
                }
                Button("취소") { model.cancel(job.id) }
                    .buttonStyle(.borderless)
                    .font(.caption)
                    .tint(.red)
                    .help("줄에서 뺍니다")
            }
        }
        .padding(Spacing.s)
        .contentCard()
    }
}

// MARK: - 끝난 것 한 줄

private struct SparkFinishedRow: View {
    @ObservedObject var model: SparkQueueModel
    let job: SparkJob

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack(spacing: Spacing.s) {
                Image(systemName: job.state.symbol)
                    .foregroundStyle(tint)
                    .font(.caption)
                VStack(alignment: .leading, spacing: 2) {
                    Text(job.title)
                        .font(.callout)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(footnote)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: Spacing.s)
                Button(model.expandedLogID == job.id ? "로그 접기" : "로그") { model.toggleLog(job.id) }
                    .buttonStyle(.borderless)
                    .font(.caption)
                    .help("서버에 남은 로그의 끝부분을 봅니다")
            }
            if model.expandedLogID == job.id {
                log
            }
        }
        .padding(Spacing.s)
        .contentCard()
    }

    private var tint: Color {
        switch job.state {
        case .done: .green
        case .failed: .red
        case .interrupted: .orange
        default: .secondary
        }
    }

    /// 실패했을 때 무엇을 봐야 하는지까지 한 줄에 넣는다. 상태만 적어 두면 로그를 열기
    /// 전에는 원인을 짐작할 방법이 없다.
    private var footnote: String {
        var pieces = [job.state.badge]
        if let finished = job.finishedAt {
            pieces.append(Self.clock.string(from: Date(timeIntervalSince1970: finished)))
        }
        if let started = job.startedAt, let finished = job.finishedAt, finished > started {
            pieces.append(SOArmFormat.duration(finished - started))
        }
        if job.state == .failed, let code = job.exitCode {
            pieces.append("종료 코드 \(code)")
        }
        if let error = job.error, !error.isEmpty {
            pieces.append(error)
        }
        return pieces.joined(separator: " · ")
    }

    @ViewBuilder
    private var log: some View {
        if model.expandedLog.isEmpty {
            Text("로그를 읽는 중입니다…")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(Array(model.expandedLog.suffix(120).enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .textSelection(.enabled)
            }
            .frame(maxHeight: 220)
            .padding(Spacing.s)
            .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: Radius.small))
        }
    }

    private static let clock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "M월 d일 HH:mm"
        return formatter
    }()
}

// MARK: - 걸기 창

/// 칸을 서버가 준 명세대로 그린다.
///
/// 종류마다 창을 따로 만들지 않는 이유는 늘리기 위해서다. 서버에 `kinds/*.json`을 하나
/// 더 놓으면 이 창이 그 칸들을 그대로 그린다 — 앱을 고치지 않아도 새 실험을 걸 수 있다.
private struct SparkEnqueueSheet: View {
    @ObservedObject var model: SparkQueueModel
    let spec: SparkJobKind
    @Environment(\.dismiss) private var dismiss
    @State private var parameters: [String: SparkParameter] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.l) {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Label(spec.label, systemImage: spec.icon)
                    .font(.headline)
                if !spec.detail.isEmpty {
                    Text(spec.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Form {
                ForEach(spec.fields) { field in
                    fieldRow(field)
                }
            }
            .formStyle(.grouped)
            Text("줄 맨 뒤에 세웁니다. 앞의 작업이 끝나면 자동으로 시작하므로, 걸어 두고 화면을 닫아도 됩니다.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("취소") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("줄에 세우기") {
                    model.enqueue(kind: spec.kind, parameters: parameters)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!isComplete || model.isSubmitting)
            }
        }
        .padding(Spacing.xl)
        .frame(width: 460)
        .onAppear { parameters = model.initialParameters(for: spec) }
    }

    /// 채워야 하는 칸이 하나라도 비어 있으면 세울 수 없다. 서버도 같은 것을 거절하지만,
    /// 거절당한 뒤에 알게 되는 것보다 버튼이 꺼져 있는 편이 낫다.
    private var isComplete: Bool {
        spec.fields.allSatisfy { !(parameters[$0.name]?.text ?? "").isEmpty }
    }

    @ViewBuilder
    private func fieldRow(_ field: SparkJobField) -> some View {
        let choices = model.choices(for: field)
        if field.type == .int {
            let binding = Binding(
                get: { parameters[field.name]?.number ?? field.minimum },
                set: { parameters[field.name] = .number(min(max($0, field.minimum), field.maximum)) }
            )
            TextField(field.label, value: binding, format: .number.grouping(.never))
            if !field.help.isEmpty { caption(field.help) }
        } else if choices.isEmpty {
            // 고를 것이 없다. 학습 서버에 데이터셋이 아직 올라가 있지 않은 경우가 대부분이라,
            // 빈 목록만 내미는 대신 어디로 가야 하는지를 적는다.
            caption("고를 수 있는 것이 없습니다. `수집 데이터` 화면에서 학습 서버로 먼저 전송하세요.")
        } else {
            Picker(field.label, selection: Binding(
                get: { parameters[field.name]?.text ?? choices.first ?? "" },
                set: { parameters[field.name] = .text($0) }
            )) {
                ForEach(choices, id: \.self) { value in
                    Text(field.caption(for: value)).tag(value)
                }
            }
            if !field.help.isEmpty { caption(field.help) }
        }
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - 설정

/// 설정 › 학습 서버.
///
/// 콘솔 서버 설정과 모양이 같지만 값은 따로 산다. 두 기계이고, 열쇠도 따로다 — 한쪽의
/// 접근만 회수할 수 있어야 하기 때문이다.
struct SparkSettingsTab: View {
    @ObservedObject var model: SparkQueueModel
    @State private var key = SOArmTunnelKey(name: "spark")
    @State private var publicKey = ""
    @State private var keyError = ""
    @State private var copied = false

    var body: some View {
        Form {
            Section("서버") {
                TextField("집에서 쓸 주소", text: $model.server.host, prompt: Text("192.168.0.x"))
                TextField("집 밖에서 쓸 주소", text: $model.server.alternateHost, prompt: Text("100.x.y.z (Tailscale)"))
                Text("학습 서버는 대체로 tailnet 주소 하나로 충분합니다. `.local` 이름은 같은 LAN에서만 풀리고 밖에서는 조용히 시간만 끕니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("SSH 계정", text: $model.server.user, prompt: Text("sehwan_spark"))
                TextField("SSH 포트", value: $model.server.sshPort, format: .number.grouping(.never))
            }
            Section("포트") {
                TextField("이 Mac에서 열 포트", value: $model.server.localPort, format: .number.grouping(.never))
                TextField("서버 큐 포트", value: $model.server.remotePort, format: .number.grouping(.never))
                Text("서버 큐 포트는 `sparkq`의 `SPARKQ_PORT`와 같아야 합니다(기본 8092). 콘솔 서버 터널이 이미 8088을 쓰고 있으므로 이 Mac 쪽 포트도 겹치지 않아야 합니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("이 앱의 열쇠") {
                Text("앱은 암호를 묻지 않습니다 — 창 없는 자식 프로세스의 암호 프롬프트는 아무도 볼 수 없기 때문입니다. 아래 명령을 터미널에서 한 번 실행해 이 앱 전용 공개키를 학습 서버에 등록하세요. 평소 터미널에서 쓰는 열쇠는 앱이 읽을 수 없으므로, 터미널에서 접속이 된다고 해서 여기서도 되는 것은 아닙니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !keyError.isEmpty {
                    Text(keyError).font(.caption).foregroundStyle(.red)
                }
                HStack {
                    Text(command)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .lineLimit(2)
                        .truncationMode(.middle)
                    Spacer()
                    Button(copied ? "복사됨" : "복사") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(command, forType: .string)
                        copied = true
                    }
                    .buttonStyle(.borderless)
                }
            }
            Section("큐") {
                Text("학습을 실제로 띄우고 순서를 정하는 것은 서버의 `sparkq`입니다. 이 앱을 꺼도, 이 Mac이 잠들어도 줄은 계속 돕니다. 서버에서 `systemctl --user status sparkq`로 확인할 수 있습니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: prepareKey)
        .onChange(of: model.server) { _, _ in copied = false }
    }

    private var command: String {
        publicKey.isEmpty ? "열쇠를 준비하는 중입니다…" : key.authorizationCommand(for: model.server)
    }

    private func prepareKey() {
        do {
            try key.ensureExists()
            publicKey = key.publicKeyText
            keyError = ""
        } catch {
            keyError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}
