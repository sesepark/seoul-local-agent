import Foundation
import SwiftUI
import Combine

/// 서버 카메라에서 이 기기로 **얼마나 받을지**. 화질 설정이 아니라 데이터 설정이다.
///
/// 카메라 두 대의 MJPEG은 집 안에서는 공짜지만 밖에서는 아니다. 640×480 30fps 한 대가
/// 시간당 3GB 언저리이고, 이 앱은 두 대를 동시에 연다 — 테더링으로 팔을 한 번 들여다보는
/// 것이 하루치 데이터를 다 쓰는 일이 될 수 있다. 그래서 **끄는 자리가 반드시 있어야 하고,
/// 끈다는 것은 프레임을 버린다는 뜻이 아니라 연결 자체를 닫는다는 뜻이다.**
///
/// 절약과 보통은 서버의 `/api/cameras/{name}/settings`로 간다. 클라이언트에서 프레임을
/// 솎아 내는 것은 데이터를 한 바이트도 아끼지 못한다 — 바이트는 이미 도착한 뒤다. 서버가
/// 더 작게 찍고 덜 보내야 실제로 준다.
enum SOArmCameraDataMode: String, CaseIterable, Identifiable, Codable {
    /// 아예 받지 않는다. 스트림을 닫고 서버의 카메라도 놓는다.
    case off
    /// 밖에서 쓰는 값. 무엇이 어디 있는지는 보이고, 데이터는 거의 쓰지 않는다.
    case saver
    /// 집 밖이지만 Wi‑Fi인 경우.
    case medium
    /// 집 안. 서버가 낼 수 있는 만큼.
    case full

    var id: String { rawValue }

    var title: String {
        switch self {
        case .off: "끔"
        case .saver: "절약"
        case .medium: "보통"
        case .full: "최고"
        }
    }

    var symbol: String {
        switch self {
        case .off: "video.slash.fill"
        case .saver: "antenna.radiowaves.left.and.right.slash"
        case .medium: "video"
        case .full: "video.fill"
        }
    }

    /// 서버에 걸 값. `끔`에는 없다 — 끄는 것은 설정이 아니라 연결을 닫는 일이다.
    var profile: SOArmCameraProfile? {
        switch self {
        case .off: nil
        case .saver: SOArmCameraProfile(width: 320, height: 240, fps: 2)
        case .medium: SOArmCameraProfile(width: 640, height: 480, fps: 8)
        case .full: SOArmCameraProfile(width: 640, height: 480, fps: 30)
        }
    }

    /// 카메라 **한 대**가 한 시간에 쓰는 데이터의 어림값.
    ///
    /// 실제 값은 장면이 얼마나 복잡한지에 따라 달라지므로 정확할 수 없다. 그래도 어림값이
    /// 없는 것보다는 훨씬 낫다 — 3GB와 50MB 사이의 선택인데 화면이 아무 숫자도 말하지
    /// 않으면 사람은 고를 수가 없다. 서버가 JPEG 품질 82로 인코딩하므로 픽셀당 대략
    /// 0.1바이트로 잡는다.
    var hourlyBytesPerCamera: Int64? {
        guard let profile else { return nil }
        let perFrame = Double(profile.width * profile.height) * 0.1
        return Int64(perFrame * Double(profile.fps) * 3600)
    }

    var detail: String {
        guard let profile, let hourly = hourlyBytesPerCamera else {
            return "영상을 받지 않습니다. 스트림을 닫고 서버의 카메라도 놓습니다 — 데이터를 한 바이트도 쓰지 않습니다."
        }
        let perCamera = ByteCountFormatter.string(fromByteCount: hourly, countStyle: .file)
        let both = ByteCountFormatter.string(fromByteCount: hourly * 2, countStyle: .file)
        return "\(profile.text) · 카메라 한 대에 시간당 약 \(perCamera), 두 대면 약 \(both)"
    }
}

/// 고른 값 하나. 화면 여럿이 같은 것을 보고, 앱을 껐다 켜도 남는다.
///
/// 값만 들고 알림만 한다. 서버를 부르고 스트림을 여닫는 것은 그 스트림을 쥐고 있는
/// 모델의 일이라, 여기에 클라이언트를 두면 카메라의 주인이 둘이 된다.
@MainActor
final class SOArmCameraPolicy: ObservableObject {
    static let shared = SOArmCameraPolicy()

    private static let key = "soarmCameraDataMode"

    /// 기본값이 `보통`인 이유. **집 안에서만 쓴다고 가정하지 않는다.** 이 Mac은 밖으로
    /// 나가고, 밖에서 처음 이 화면을 여는 순간에 이미 최고 화질로 두 대가 열려 있으면
    /// 고를 기회 자체가 없다.
    @Published var mode: SOArmCameraDataMode {
        didSet {
            guard mode != oldValue else { return }
            UserDefaults.standard.set(mode.rawValue, forKey: Self.key)
        }
    }

    var isOff: Bool { mode == .off }

    private init() {
        mode = SOArmCameraDataMode(rawValue: UserDefaults.standard.string(forKey: Self.key) ?? "") ?? .medium
    }
}

/// 네 자리짜리 스위치 하나. 두 화면이 같은 것을 쓴다.
struct SOArmCameraDataControl: View {
    @ObservedObject var policy: SOArmCameraPolicy
    /// 지금 걸려 있는 값이 서버에서 거절당했으면 그 말. 없으면 아무것도 그리지 않는다.
    var note: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack(spacing: Spacing.s) {
                Label("영상 받기", systemImage: policy.mode.symbol)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(policy.isOff ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.snuBlueLabel))
                Picker("영상 받기", selection: $policy.mode) {
                    ForEach(SOArmCameraDataMode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 260)
                .help("밖에서 쓸 때 데이터를 얼마나 쓸지 정합니다. `끔`은 연결을 닫습니다.")
                Spacer(minLength: 0)
            }
            Text(policy.mode.detail)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let note {
                Text(note)
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(.appControl, value: policy.mode)
    }
}
