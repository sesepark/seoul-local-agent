import AVFoundation
import AudioToolbox

@MainActor
final class AudioRecorder: NSObject, ObservableObject, @preconcurrency AVAudioRecorderDelegate {
    /// One description of what a take is made of, because `RecordingRepair` has to
    /// decode a cut-off recording with exactly the format that wrote it. Two copies
    /// of these numbers would eventually disagree, and a rebuilt file would come out
    /// at the wrong speed or the wrong channel count with nothing to flag it.
    enum Format {
        static let sampleRate = 16_000.0
        static let channels: UInt32 = 1
        static let bitRate: UInt32 = 48_000
        static let framesPerPacket: UInt32 = 1_024

        static var settings: [String: Any] {
            [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: Int(channels),
             AVEncoderBitRateKey: Int(bitRate), AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue]
        }

        static var streamDescription: AudioStreamBasicDescription {
            AudioStreamBasicDescription(mSampleRate: sampleRate, mFormatID: kAudioFormatMPEG4AAC, mFormatFlags: 0, mBytesPerPacket: 0,
                                        mFramesPerPacket: framesPerPacket, mBytesPerFrame: 0, mChannelsPerFrame: channels, mBitsPerChannel: 0, mReserved: 0)
        }

        /// What the encoder would have been fed, which is what an encoder has to be
        /// built from before it will hand over the decoder configuration.
        static var pcmStreamDescription: AudioStreamBasicDescription {
            AudioStreamBasicDescription(mSampleRate: sampleRate, mFormatID: kAudioFormatLinearPCM,
                                        mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
                                        mBytesPerPacket: 2 * channels, mFramesPerPacket: 1, mBytesPerFrame: 2 * channels,
                                        mChannelsPerFrame: channels, mBitsPerChannel: 16, mReserved: 0)
        }
    }

    /// `applicationWillTerminate` is outside the view tree, and a take that is not
    /// closed there is a file no player can open. Same reason as
    /// `MusicPlayerModel.current`.
    private(set) static weak var current: AudioRecorder?

    @Published private(set) var isRecording = false
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var errorMessage: String?

    /// The banner is dismissible, so the view needs a way to clear a message it
    /// has finished showing without the setter becoming public.
    func dismissError() { errorMessage = nil }
    private var recorder: AVAudioRecorder?
    private var timer: Timer?
    private var startedAt: Date?

    override init() {
        super.init()
        Self.current = self
    }

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
            let recorder = try AVAudioRecorder(url: url, settings: Format.settings)
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

    /// Closes the take that is running, synchronously, so quitting mid-recording
    /// leaves a file that plays instead of one that no player will open.
    ///
    /// `AVAudioRecorder` writes its index only on `stop()`. Nothing used to call
    /// it at quit, so a ⌘Q during a lecture left the whole recording behind an
    /// OSStatus error — the audio was on disk, but unreachable.
    func stopNow() {
        guard isRecording else { return }
        recorder?.stop()
        finish()
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
