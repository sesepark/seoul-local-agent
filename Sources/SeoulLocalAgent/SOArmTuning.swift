import SwiftUI

/// 서버의 안전·조작 값을 화면에서 만지는 자리.
///
/// 이 값들은 서버가 쥐고 있다 — 판정도 서버가 하고, 폰에서 붙어도 같은 값이 걸린다.
/// 그래서 앱은 **읽어서 보여 주고, 바꿔 달라고 부탁**할 뿐이다. 난간(허용 범위)도 서버가
/// 정한 것을 그대로 쓴다. 두 곳에 적어 두면 서버가 범위를 좁혔을 때 앱만 옛 난간을 그린다.
@MainActor
final class SOArmTuningModel: ObservableObject {
    @Published private(set) var values: [String: Double] = [:]
    @Published private(set) var ranges: [String: SOArmTunableRange] = [:]
    /// 사람이 만지는 중인 값. 적용하기 전까지 서버 값과 따로 논다.
    @Published var draft: [String: Double] = [:]
    @Published private(set) var isBusy = false
    @Published var errorMessage: String?
    @Published private(set) var savedAt: Date?

    private let server: SOArmServer

    init(server: SOArmServer) {
        self.server = server
    }

    private var client: SOArmVirtualLeaderClient {
        SOArmVirtualLeaderClient(baseURL: server.baseURL, motionToken: server.motionToken)
    }

    var isLoaded: Bool { !ranges.isEmpty }

    /// 바꾼 것이 있는가. 없으면 `적용`은 눌러도 할 일이 없다.
    var changed: [String: Double] {
        draft.filter { name, value in
            guard let current = values[name] else { return false }
            return abs(current - value) > 0.0001
        }
    }

    func load() async {
        guard server.isConfigured else { return }
        do {
            let answer = try await client.policy()
            values = answer.values
            ranges = answer.ranges
            draft = answer.values.filter { ranges[$0.key] != nil }
            errorMessage = nil
        } catch {
            errorMessage = SOArmConsoleModel.message(for: error)
        }
    }

    func apply() async {
        let pending = changed
        guard !pending.isEmpty, !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            let updated = try await client.setPolicy(pending)
            values = updated
            draft = updated.filter { ranges[$0.key] != nil }
            savedAt = Date()
            errorMessage = nil
        } catch {
            errorMessage = SOArmConsoleModel.message(for: error)
        }
    }

    func revert() {
        draft = values.filter { ranges[$0.key] != nil }
    }

    func binding(_ name: String) -> Binding<Double> {
        Binding(
            get: { self.draft[name] ?? self.values[name] ?? 0 },
            set: { self.draft[name] = $0 }
        )
    }
}

/// 화면에 적는 말. 이름·설명·단위는 앱이 정하고, 값과 범위는 서버가 정한다.
struct SOArmTunable: Identifiable, @unchecked Sendable {
    let name: String
    let title: String
    let detail: String
    /// 값 옆에 붙는 단위.
    let unit: String
    /// 그 값이 실제로 무엇이 되는지 한 줄로. 예: 8° → "최대 240°/s".
    let effect: (Double) -> String

    var id: String { name }

    nonisolated(unsafe) static let all: [SOArmTunable] = [
        SOArmTunable(
            name: "step_deg",
            title: "팔의 속도와 힘",
            detail: "한 번에 목표가 팔의 실제 위치보다 앞설 수 있는 각도입니다. 이 값 하나가 최대 속도와 서보가 내는 힘을 **함께** 정합니다 — 서보는 위치 제어라 힘이 이 오차에 비례하기 때문입니다. 낮으면 무거운 자세를 들지 못하고(2°에서는 어깨가 팔을 전혀 들지 못했습니다), 높으면 부딪힐 때 충격이 커집니다.",
            unit: "°",
            effect: { "최대 \(Int($0 * 30))°/s · 서보 무부하 속도는 252°/s입니다" }
        ),
        SOArmTunable(
            name: "step_percent",
            title: "집게의 속도와 힘",
            detail: "집게에 적용되는 같은 값입니다. 집게는 LeRobot이 서보 자체의 토크를 50%로 묶어 두므로 팔 관절보다 안전합니다.",
            unit: "%",
            effect: { "최대 \(Int($0 * 30))%/s" }
        ),
        SOArmTunable(
            name: "following_error_deg",
            title: "막힘 판정 거리",
            detail: "사람이 요청한 값과 실제 자세가 이만큼 벌어진 채 팔이 서 있으면 무언가에 닿은 것으로 봅니다. 낮추면 예민해져 정상 조작 중에도 멈추고, 올리면 더 오래 밀어붙입니다.",
            unit: "°",
            effect: { _ in "0.4초 넘게 이어질 때만 멈춥니다" }
        ),
        SOArmTunable(
            name: "stall_load",
            title: "막힘 판정 부하",
            detail: "밀고 있는데 제자리이고 부하가 이만큼이면 막힌 것으로 봅니다. 실측에서 자유롭게 움직일 때 24~144, 막혔을 때 100~144라 부하만으로는 가를 수 없고, 가르는 것은 아래의 시간입니다.",
            unit: "",
            effect: { _ in "서보 눈금(0~1000)입니다" }
        ),
        SOArmTunable(
            name: "stall_load_ms",
            title: "막힘 판정 시간",
            detail: "위 조건이 이만큼 이어져야 멈춥니다. 짧게 잡으면 팔이 정지 마찰을 이기고 **움직이기 시작하는 순간**에 걸립니다 — 500ms에서 실제로 그랬습니다.",
            unit: "ms",
            effect: { "\(String(format: "%.1f", $0 / 1000))초" }
        ),
        SOArmTunable(
            name: "retreat_deg",
            title: "물러나는 거리",
            detail: "걸렸을 때 그 관절만 반대 방향으로 이만큼 물러난 뒤 섭니다. 1.5초 안에 빠져나오지 못하면 그 자리에 그대로 섭니다.",
            unit: "°",
            effect: { _ in "걸린 관절 하나만 움직입니다" }
        ),
        SOArmTunable(
            name: "sync_tolerance_deg",
            title: "권한을 받을 때 허용 오차",
            detail: "조작 권한을 막 받았을 때, 첫 명령이 팔의 현재 자세에서 이만큼까지 떨어져 있어도 받아 줍니다. 팔이 갑자기 튀지 않게 하는 값이라 크게 잡을 이유가 없습니다.",
            unit: "°",
            effect: { _ in "권한을 받은 직후 한 번만 적용됩니다" }
        ),
    ]
}

/// 설정 › 로봇의 `움직임과 안전` 구역.
struct SOArmTuningSection: View {
    @ObservedObject var model: SOArmTuningModel

    var body: some View {
        Section("움직임과 안전") {
            Text("팔이 얼마나 세게·빠르게 움직이는지, 무엇을 막힌 것으로 볼지 정합니다. 판정은 서버가 하므로 여기서 바꾼 값은 아이폰에서 조작할 때도 그대로 걸립니다. **팔이 움직이는 중에는 서버가 변경을 거절합니다** — 상한이 커지는 순간 목표가 한 번에 멀어져 팔이 튀기 때문입니다.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if !model.isLoaded {
                HStack(spacing: Spacing.s) {
                    ProgressView().controlSize(.small)
                    Text("서버에서 지금 값을 읽는 중입니다").font(.caption).foregroundStyle(.secondary)
                }
            }

            ForEach(SOArmTunable.all) { item in
                if let range = model.ranges[item.name] {
                    row(item, range)
                }
            }

            if model.isLoaded {
                HStack(spacing: Spacing.s) {
                    Button("적용") { Task { await model.apply() } }
                        .buttonStyle(.borderedProminent)
                        .tint(.snuBlue)
                        .disabled(model.changed.isEmpty || model.isBusy)
                    Button("되돌리기") { model.revert() }
                        .disabled(model.changed.isEmpty || model.isBusy)
                    if model.isBusy { ProgressView().controlSize(.small) }
                    Spacer()
                    if let savedAt = model.savedAt, model.changed.isEmpty {
                        Text("저장됨 · \(savedAt.formatted(date: .omitted, time: .shortened))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if let message = model.errorMessage {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .task { await model.load() }
    }

    @ViewBuilder
    private func row(_ item: SOArmTunable, _ range: SOArmTunableRange) -> some View {
        let value = model.draft[item.name] ?? model.values[item.name] ?? range.minimum
        VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack(spacing: Spacing.s) {
                Text(item.title).font(.callout)
                Spacer()
                Text(display(value, item, range))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(model.changed[item.name] == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.snuBlueLabel))
            }
            Slider(
                value: model.binding(item.name),
                in: range.minimum...range.maximum,
                step: range.isInteger ? 1 : 0.5
            )
            .tint(.snuBlue)
            Text("\(item.effect(value)) · \(item.detail)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, Spacing.xs)
    }

    private func display(_ value: Double, _ item: SOArmTunable, _ range: SOArmTunableRange) -> String {
        let number = range.isInteger
            ? String(Int(value.rounded()))
            : String(format: value == value.rounded() ? "%.0f" : "%.1f", value)
        return item.unit.isEmpty ? number : number + item.unit
    }
}
