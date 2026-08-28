import AVFoundation

@MainActor
final class AudioRecorder: NSObject, ObservableObject, @preconcurrency AVAudioRecorderDelegate {
    @Published private(set) var isRecording = false
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var errorMessage: String?
    private var recorder: AVAudioRecorder?
    private var timer: Timer?
    private var startedAt: Date?

    func start() async -> Bool {
        errorMessage = nil
        let granted = await AVAudioApplication.requestRecordPermission()
        guard granted else {
            errorMessage = "마이크 권한이 필요합니다. 시스템 설정 > 개인정보 보호 및 보안 > 마이크에서 이 앱을 허용해 주세요."
            return false
        }
        do {
            let directory = try Self.recordingsDirectory()
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "ko_KR")
            formatter.dateFormat = "yyyy-MM-dd HHmmss"
            let url = directory.appending(path: "녹음 \(formatter.string(from: Date())).m4a")
            let settings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 16_000, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 48_000, AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue]
            let recorder = try AVAudioRecorder(url: url, settings: settings)
            recorder.delegate = self
            guard recorder.record() else { throw AgentError.processFailed("마이크 녹음을 시작하지 못했습니다.") }
            self.recorder = recorder
            startedAt = Date()
            elapsed = 0
            isRecording = true
            let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, let startedAt = self.startedAt else { return }
                    self.elapsed = Date().timeIntervalSince(startedAt)
                }
            }
            // .common, not the default mode: the counter has to keep ticking while
            // the user scrolls or drags in the window.
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
            return true
        } catch { errorMessage = error.localizedDescription; return false }
    }

    /// The file still being written. Transcription reads a recording whole, so
    /// nothing may queue the take that is currently growing.
    var currentFileURL: URL? { isRecording ? recorder?.url : nil }

    func stop() -> URL? {
        guard let recorder else { return nil }
        recorder.stop()
        let url = recorder.url
        finish()
        return url
    }

    func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: (any Error)?) {
        errorMessage = error?.localizedDescription ?? "녹음 파일을 저장하지 못했습니다."
        finish()
    }

    private func finish() { timer?.invalidate(); timer = nil; recorder = nil; startedAt = nil; isRecording = false }

    nonisolated static func recordingsDirectory() throws -> URL {
        let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appending(path: "SeoulLocalAgent/Recordings", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
