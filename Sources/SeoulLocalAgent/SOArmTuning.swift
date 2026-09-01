import SwiftUI

/// 서버의 안전·조작 값을 화면에서 만지는 자리.
///
/// 이 값들은 서버가 쥐고 있다 — 판정도 서버가 하고, 폰에서 붙어도 같은 값이 걸린다.
/// 그래서 앱은 **읽어서 보여 주고, 바꿔 달라고 부탁**할 뿐이다. 난간(허용 범위)도 서버가
/// 정한 것을 그대로 쓴다. 두 곳에 적어 두면 서버가 범위를 좁혔을 때 앱만 옛 난간을 그린다.
///
/// ## 숫자를 고르라고 하지 않는다
///
/// 화면의 첫 번째 선택지는 이름이 붙은 세 가지다. `lead_deg`가 12여야 하는지 15여야
/// 하는지는 이 팔을 만든 사람도 재 보기 전에는 모르고, 쓰는 사람에게 물을 일은 더더욱
/// 아니다. 게다가 속도·힘·민감도는 서로 짝이 맞아야 하는 값들이라 따로 고르면 어긋난다 —
/// 빠르게 움직이면서 예민하게 멈추면 정상 조작 중에 자꾸 선다. 숫자는 `고급`에 접어 둔다.
@MainActor
final class SOArmTuningModel: ObservableObject {
    @Published private(set) var values: [String: Double] = [:]
    @Published private(set) var ranges: [String: SOArmTunableRange] = [:]
    @Published private(set) var profiles: [SOArmFeelProfile] = []
    /// 지금 어느 조작감인가. 값을 하나라도 손으로 옮겨 두었으면 `nil`이다.
    @Published private(set) var profile: String?
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

    /// 화면이 한 줄로 말할 수 있는 지금 설정. 숫자가 무엇이 되는지 사람 말로 적는다.
    var summary: String {
        guard let speed = values["max_deg_per_s"], let lead = values["lead_deg"] else { return "" }
        return "최대 \(Int(speed))°/s · 막혔을 때 미는 거리 \(String(format: "%.0f", lead))°"
    }

    func load() async {
        guard server.isConfigured else { return }
        do {
            let answer = try await client.policy()
            adopt(answer)
            errorMessage = nil
        } catch {
            errorMessage = SOArmConsoleModel.message(for: error)
        }
    }

    private func adopt(_ answer: SOArmPolicyAnswer) {
        values = answer.values
        ranges = answer.ranges
        profiles = answer.profiles
        profile = answer.profile
        draft = answer.values.filter { ranges[$0.key] != nil }
    }

    /// 조작감 하나를 고른다. 속도·힘·민감도가 함께 옮겨 간다.
    func choose(_ name: String) async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            adopt(try await client.setFeel(name))
            savedAt = Date()
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
            // 값을 손으로 옮겼으면 더 이상 어느 조작감도 아니다. 서버가 그렇게 판단하므로
            // 다시 물어서 맞춘다 — 여기서 짐작하면 화면과 서버가 다른 말을 하게 된다.
            if let answer = try? await client.policy() { adopt(answer) }
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

    static let all: [SOArmTunable] = [
        SOArmTunable(
            name: "max_deg_per_s",
            title: "팔의 최대 속도",
            detail: "서보 자신이 지키는 값입니다. 서버가 STS3215의 `Goal_Velocity` 레지스터에 써 넣으면, 목표가 아무리 멀어도 서보는 이 속도로만 미끄러집니다. 그래서 명령을 얼마나 자주 보내는지와 무관하고, 밖에서 느린 회선으로 조작해도 팔이 느려지지 않습니다. 이 팔의 천장은 실측 150°/s입니다.",
            unit: "°/s",
            effect: { "가장 넓은 관절(±118°)을 끝에서 끝까지 \(String(format: "%.1f", 236 / max($0, 1)))초" }
        ),
        SOArmTunable(
            name: "max_percent_per_s",
            title: "집게의 최대 속도",
            detail: "집게에 적용되는 같은 값입니다. 단위가 퍼센트라 따로 둡니다 — 100%가 약 127°이므로 118%/s가 이 서보의 천장입니다.",
            unit: "%/s",
            effect: { "완전히 열고 닫는 데 \(String(format: "%.1f", 100 / max($0, 1)))초" }
        ),
        SOArmTunable(
            name: "lead_deg",
            title: "막혔을 때 미는 힘",
            detail: "목표가 팔의 실제 위치보다 앞설 수 있는 거리입니다. 서보는 위치 제어라 힘이 이 오차에 비례하므로, 이 값이 곧 **막혔을 때 내는 힘**입니다. 자유롭게 움직이는 동안에는 이만큼 벌어지지 않으므로 속도와는 무관합니다. 실측에서 오차 2°는 부하 100(어깨가 팔을 전혀 들지 못함), 5°는 236(들기 시작), 8°는 304였습니다.",
            unit: "°",
            effect: { _ in "이 거리 이상은 앞서지 않습니다" }
        ),
        SOArmTunable(
            name: "following_error_deg",
            title: "막힘 판정 거리",
            detail: "목표와 실제 자세가 이만큼 벌어진 채 팔이 서 있으면 무언가에 닿은 것으로 봅니다. 위의 `미는 힘`보다 작아야 합니다 — 막히면 벌어짐은 거기서 멈추므로, 더 크게 잡으면 영영 걸리지 않습니다.",
            unit: "°",
            effect: { _ in "아래 시간만큼 이어질 때만 멈춥니다" }
        ),
        SOArmTunable(
            name: "following_error_ms",
            title: "막힘 판정 시간",
            detail: "위 상태가 이만큼 이어져야 멈춥니다. 짧게 잡으면 팔이 정지 마찰을 이기고 움직이기 시작하는 순간에 걸립니다.",
            unit: "ms",
            effect: { "\(String(format: "%.1f", $0 / 1000))초" }
        ),
        SOArmTunable(
            name: "load_trip",
            title: "과부하 정지",
            detail: "부하가 이만큼 이어지면 멈춥니다. 서보 자신은 800(80%)에서 토크를 20%로 떨어뜨리므로 그보다 먼저 서는 자리입니다. 실측에서 정상 이동 중의 최대 부하는 424였습니다.",
            unit: "",
            effect: { _ in "서보 눈금(0~1000)입니다" }
        ),
        SOArmTunable(
            name: "stall_load",
            title: "막힘 판정 부하",
            detail: "밀고 있는데 제자리이고 부하가 이만큼이면 막힌 것으로 봅니다. 관절이 자기 가동 범위 끝에 닿아 선 것은 여기에 해당하지 않습니다 — 그때는 서버가 미는 것을 그만두고 화면에 `끝`이라고 적습니다.",
            unit: "",
            effect: { _ in "서보 눈금(0~1000)입니다" }
        ),
        SOArmTunable(
            name: "stall_load_ms",
            title: "막힘 판정 시간(부하)",
            detail: "위 조건이 이만큼 이어져야 멈춥니다. 짧게 잡으면 팔이 움직이기 시작하는 순간에 걸립니다 — 500ms에서 실제로 그랬습니다.",
            unit: "ms",
            effect: { "\(String(format: "%.1f", $0 / 1000))초" }
        ),
        SOArmTunable(
            name: "command_hold_ms",
            title: "명령이 끊겼을 때 확인을 요구하기까지",
            detail: "명령이 0.3초 끊기면 팔은 곧바로 그 자리에 섭니다. 그것은 확인을 요구하지 않고, 명령이 다시 오면 그대로 이어집니다. 침묵이 이만큼 이어져야 비로소 자세 유지(HOLD)가 되고, 그때는 사람이 `확인하고 계속`을 눌러야 합니다. 짧게 잡으면 무선이 한 번 흔들릴 때마다 버튼을 누르게 됩니다.",
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
            detail: "조작 권한을 막 받았을 때, 첫 명령이 팔의 현재 자세에서 이만큼까지 떨어져 있어도 받아 줍니다. 속도를 서보가 지키게 되면서 먼 첫 목표도 그저 정해진 속도로 미끄러질 뿐이라, 예전보다 넓게 두어도 됩니다.",
            unit: "°",
            effect: { _ in "권한을 받은 직후 한 번만 적용됩니다" }
        ),
    ]
}

/// 설정 › 로봇의 `움직임과 안전` 구역.
///
/// 세 칸 가운데 하나를 고르는 것이 이 화면의 전부다. 숫자는 `고급`에 접어 두었고, 접힌
/// 채로 두어도 팔은 잘 움직인다 — 그것이 이 화면을 이렇게 만든 이유다.
struct SOArmTuningSection: View {
    @ObservedObject var model: SOArmTuningModel
    @State private var showsAdvanced = false

    var body: some View {
        Section("움직임과 안전") {
            Text("팔이 얼마나 빠르게 움직이고, 무엇을 막힌 것으로 볼지 정합니다. 판정은 서버가 하므로 여기서 고른 것은 아이폰에서 조작할 때도 그대로 걸립니다. **팔이 움직이는 중에는 서버가 변경을 거절합니다.**")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if !model.isLoaded {
                HStack(spacing: Spacing.s) {
                    ProgressView().controlSize(.small)
                    Text("서버에서 지금 값을 읽는 중입니다").font(.caption).foregroundStyle(.secondary)
                }
            }

            if !model.profiles.isEmpty {
                Picker("조작감", selection: feelBinding) {
                    ForEach(model.profiles) { item in
                        Text(item.title).tag(item.name)
                    }
                    if model.profile == nil {
                        Text("직접 정함").tag("")
                    }
                }
                .pickerStyle(.segmented)
                .disabled(model.isBusy)

                Text(chosenDetail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if !model.summary.isEmpty {
                    Label(model.summary, systemImage: "speedometer")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(Color.snuBlueLabel)
                }
            }

            if model.isLoaded {
                DisclosureGroup("고급 — 값 하나씩", isExpanded: $showsAdvanced) {
                    VStack(alignment: .leading, spacing: Spacing.s) {
                        Text("여기서 값을 하나라도 옮기면 위의 조작감은 `직접 정함`이 됩니다. 되돌리려면 세 칸 중 하나를 다시 고르세요.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        ForEach(SOArmTunable.all) { item in
                            if let range = model.ranges[item.name] {
                                row(item, range)
                            }
                        }
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
                    .padding(.top, Spacing.xs)
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

    /// 고른 것을 바로 서버에 보낸다. `적용`을 따로 누르게 하지 않는 이유는, 이것이
    /// 값 하나가 아니라 **한 벌**이라 반쯤 적용된 상태가 존재하지 않기 때문이다.
    private var feelBinding: Binding<String> {
        Binding(
            get: { model.profile ?? "" },
            set: { name in
                guard !name.isEmpty, name != model.profile else { return }
                Task { await model.choose(name) }
            }
        )
    }

    private var chosenDetail: String {
        guard let name = model.profile,
              let item = model.profiles.first(where: { $0.name == name }) else {
            return "지금은 세 가지 가운데 어느 것도 아닙니다 — 아래 `고급`에서 값을 직접 바꿔 두었습니다."
        }
        return item.detail
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
