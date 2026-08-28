import SwiftUI
import AppKit
import UniformTypeIdentifiers
import AVFoundation
import Combine

@main
struct SeoulLocalAgentApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var controller = AutomationController()

    init() {
        let shadow = CommandLine.arguments.contains("--briefing-shadow")
        let write = CommandLine.arguments.contains("--briefing-write")
        if shadow || write {
            Task {
                do {
                    let service = BriefingService()
                    let briefing = try await service.run(range: .day3, writeToNotion: write) { _, message, _ in
                        FileHandle.standardError.write(Data((message + "\n").utf8))
                    }
                    if shadow { FileHandle.standardOutput.write(Data(service.markdownPreview(briefing).utf8)) }
                    if write { FileHandle.standardOutput.write(Data((briefing.notionURL?.absoluteString ?? "") .utf8)) }
                    exit(EXIT_SUCCESS)
                } catch {
                    FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
                    exit(EXIT_FAILURE)
                }
            }
        }
    }

    var body: some Scene {
        MenuBarExtra {
            MenuContentView(controller: controller)
        } label: {
            Label("서울대 로컬 에이전트", systemImage: controller.dictation.isRecording ? "mic.circle.fill" : (controller.isRunning ? "graduationcap.circle.fill" : "graduationcap.circle"))
        }
        .menuBarExtraStyle(.window)
        WindowGroup("서울대 로컬 에이전트", id: "main") {
            MainWorkspaceView(controller: controller)
        }
        .defaultSize(width: 1080, height: 760)
        .windowResizability(.contentMinSize)
        Window("녹음 전사", id: "transcription") {
            TranscriptionWindowView(controller: controller)
        }
        .defaultSize(width: 900, height: 680)
        .windowResizability(.contentMinSize)
    }
}

private final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Process discovery performs blocking system I/O and must never hold
        // SwiftUI's main thread during launch.
        DispatchQueue.global(qos: .utility).async {
            ActiveProcessRegistry.shared.terminateOrphanedRunners()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // The 누끼 runner stays resident between photos, so it gets an explicit
        // close-then-terminate-then-kill pass that returns only once it is gone.
        // Everything else is a short-lived child that `terminateAll` covers.
        MattingDaemon.shared.shutdownNow()
        // Tree, not just the direct child: the 정밀 문서 인식 helper starts a
        // local service of its own that would otherwise be left behind.
        ActiveProcessRegistry.shared.terminateAllTrees()
    }
}

@MainActor
final class AutomationController: ObservableObject {
    @Published var phase: RunPhase = .idle
    @Published var detail = "명시적 실행을 기다리고 있습니다."
    @Published var selectedRange: CollectionRange {
        didSet { UserDefaults.standard.set(selectedRange.rawValue, forKey: "briefingRange") }
    }
    @Published var briefingQualityMode: BriefingQualityMode {
        didSet { UserDefaults.standard.set(briefingQualityMode.rawValue, forKey: "briefingQualityMode") }
    }
    @Published var briefingMaxActions: Int {
        didSet { UserDefaults.standard.set(briefingMaxActions, forKey: "briefingMaxActions") }
    }
    @Published var briefingMaxReferences: Int {
        didSet { UserDefaults.standard.set(briefingMaxReferences, forKey: "briefingMaxReferences") }
    }
    @Published var briefingETA: TimeInterval?
    @Published var briefingUserInstructions: String
    @Published var briefingIgnoredPatternsText: String
    @Published var briefingImportantPatternsText: String
    @Published var briefingPreferencesStatus = ""
    @Published var calendarAuthorizationStatus = CalendarIntegration.authorizationDescription
    @Published var lastBriefing: DailyBriefing?
    @Published var errorMessage: String?
    @Published var isRunning = false
    @Published var isTranscribing = false
    @Published var asrModel: ASRModelChoice {
        didSet { UserDefaults.standard.set(asrModel.rawValue, forKey: "asrModelChoice") }
    }
    @Published var diarization: DiarizationChoice {
        didSet { UserDefaults.standard.set(diarization.rawValue, forKey: "diarizationChoice") }
    }
    @Published var transcriptionTimestampMode: TranscriptionTimestampMode {
        didSet { UserDefaults.standard.set(transcriptionTimestampMode.rawValue, forKey: "transcriptionTimestampMode") }
    }
    @Published var transcriptionLanguage: TranscriptionLanguage {
        didSet { UserDefaults.standard.set(transcriptionLanguage.rawValue, forKey: "transcriptionLanguage") }
    }
    @Published var transcriptionDetail = "녹음 파일을 선택하면 설정한 음성 인식과 화자 구분을 시작합니다."
    @Published var transcriptionStep = 0
    @Published var transcriptionETA: TimeInterval?
    @Published var transcriptionText = ""
    @Published var transcriptionError: String?
    @Published var mostRecentRecording: URL?
    @Published var recordings: [RecordingItem] = []
    @Published var recordingLibraryStatus = "녹음 보관함을 불러오는 중"
    @Published var downloadingRecordingIDs: Set<RecordingItem.ID> = []
    @Published var selectedRecordingID: RecordingItem.ID?
    @Published var selectedTranscriptRunID: UUID?
    @Published var selectedOrganizationRunID: UUID?
    @Published var transcribingRecordingID: RecordingItem.ID?
    @Published var isPlayingRecording = false
    @Published var isOrganizingTranscript = false
    @Published var organizationDetail = ""
    @Published var organizationError: String?
    @Published var organizationETA: TimeInterval?
    @Published var automaticallyOrganizeTranscripts: Bool
    @Published var organizationKind: TranscriptOrganizationKind
    @Published var organizationDetailLevel: TranscriptOrganizationDetail
    @Published var lectureOrganizationPrompt: String
    @Published var meetingOrganizationPrompt: String
    @Published var generalOrganizationPrompt: String
    @Published var organizationPreferencesStatus = ""
    @Published private(set) var processingQueue: [ProcessingQueueItem] = []
    @Published private(set) var activeProcessingItemID: UUID?
    @Published var mediaURLText = ""
    @Published private(set) var isImportingMedia = false
    @Published private(set) var mediaImportStatus = ""
    @Published var mediaImportError: String?
    @Published private(set) var isRecognizingDocument = false
    @Published private(set) var recognizedText = ""
    @Published private(set) var recognizedSourceName = ""
    @Published private(set) var recognitionStatus = "이미지나 PDF를 드롭하거나 화면 영역을 캡처하세요."
    @Published var recognitionError: String?
    @Published private(set) var recognizedNoteText = ""
    /// Drives the save panel's file type and the hint under the result.
    @Published private(set) var recognizedTextIsMarkdown = false
    @Published var documentMode: DocumentRecognitionMode {
        didSet { UserDefaults.standard.set(documentMode.rawValue, forKey: "documentRecognitionMode") }
    }
    @Published var mattingModel: MattingModelChoice {
        didSet { UserDefaults.standard.set(mattingModel.rawValue, forKey: "mattingModel") }
    }
    @Published var cutoutBackground: CutoutBackground {
        didSet { UserDefaults.standard.set(cutoutBackground.rawValue, forKey: "cutoutBackground") }
    }
    @Published var cutoutCustomColor: Color {
        didSet { UserDefaults.standard.set(Self.hex(from: cutoutCustomColor), forKey: "cutoutCustomColor") }
    }
    @Published private(set) var cutoutItems: [CutoutItem] = []
    @Published private(set) var isRemovingBackground = false
    @Published private(set) var cutoutStatus = "사진을 드롭하면 배경을 지운 PNG를 만듭니다."
    @Published var cutoutError: String?
    let audioRecorder = AudioRecorder()
    let dictation = DictationController()
    private var task: Task<Void, Never>?
    private var transcriptionTask: Task<Void, Never>?
    private var organizationTask: Task<Void, Never>?
    private var processingQueueState = ProcessingQueueState()
    private var mediaImportTask: Task<Void, Never>?
    private var recognitionTask: Task<Void, Never>?
    private var cutoutTask: Task<Void, Never>?
    private var cancellables: Set<AnyCancellable> = []
    private let store = StateStore()
    private let briefingPreferencesStore = BriefingPreferencesStore()
    private let organizationPreferencesStore = TranscriptOrganizationPreferencesStore()
    private var transcriptArchive = TranscriptArchive.load()
    private var audioPlayer: AVAudioPlayer?
    private var briefingStartedAt: Date?
    private var transcriptionStartedAt: Date?
    private var organizationStartedAt: Date?

    var selectedRecording: RecordingItem? { recordings.first { $0.id == selectedRecordingID } }
    var selectedTranscriptRun: TranscriptRun? {
        guard let recording = selectedRecording else { return nil }
        let runs = transcriptRuns(for: recording)
        return runs.first(where: { $0.id == selectedTranscriptRunID }) ?? runs.first
    }
    var selectedTranscript: String { selectedTranscriptRun?.text ?? "" }
    var selectedOrganizationRun: TranscriptOrganizationRun? {
        guard let transcript = selectedTranscriptRun else { return nil }
        let runs = transcriptArchive.organizations(for: transcript.id)
        return runs.first(where: { $0.id == selectedOrganizationRunID }) ?? runs.first
    }

    var activeProcessingItem: ProcessingQueueItem? {
        guard let activeProcessingItemID else { return nil }
        return processingQueue.first { $0.id == activeProcessingItemID }
    }

    var waitingProcessingItems: [ProcessingQueueItem] {
        processingQueue.filter { $0.id != activeProcessingItemID }
    }

    var progressValue: Double {
        switch phase {
        case .idle, .failed, .cancelled: return 0
        case .collecting: return 0.15
        case .classifying: return 0.45
        case .writing: return 0.75
        case .completed: return 1
        }
    }

    init() {
        let briefingPreferences = BriefingPreferencesStore().load()
        briefingUserInstructions = briefingPreferences.userInstructions
        briefingIgnoredPatternsText = briefingPreferences.ignoredPatterns.joined(separator: "\n")
        briefingImportantPatternsText = briefingPreferences.importantPatterns.joined(separator: "\n")
        // Incremental by default: earlier items that are still open are carried
        // forward rather than collected and analysed again.
        selectedRange = CollectionRange(rawValue: UserDefaults.standard.string(forKey: "briefingRange") ?? "") ?? .sinceLastSuccess
        briefingQualityMode = BriefingQualityMode(rawValue: UserDefaults.standard.string(forKey: "briefingQualityMode") ?? "") ?? .thorough
        briefingMaxActions = max(3, UserDefaults.standard.integer(forKey: "briefingMaxActions").nonZero(or: 10))
        briefingMaxReferences = max(3, UserDefaults.standard.integer(forKey: "briefingMaxReferences").nonZero(or: 8))
        // Vision stays the default: it is instant and needs no download, and
        // most captures are plain text. 정밀 is opted into per document.
        documentMode = DocumentRecognitionMode(rawValue: UserDefaults.standard.string(forKey: "documentRecognitionMode") ?? "") ?? .vision
        // Quality is the point of the 누끼 tab, so the 2048 checkpoint is the
        // default even though it costs a one-time download.
        mattingModel = MattingModelChoice(rawValue: UserDefaults.standard.string(forKey: "mattingModel") ?? "") ?? .highResolution
        cutoutBackground = CutoutBackground(rawValue: UserDefaults.standard.string(forKey: "cutoutBackground") ?? "") ?? .transparent
        cutoutCustomColor = Self.color(fromHex: UserDefaults.standard.string(forKey: "cutoutCustomColor")) ?? .white
        let savedASR = UserDefaults.standard.string(forKey: "asrModelChoice")
        asrModel = savedASR.flatMap(ASRModelChoice.init(rawValue:)) ?? .qwen06B8Bit
        let savedDiarization = UserDefaults.standard.string(forKey: "diarizationChoice")
        diarization = savedDiarization.flatMap(DiarizationChoice.init(rawValue:)) ?? .disabled
        transcriptionTimestampMode = UserDefaults.standard.string(forKey: "transcriptionTimestampMode").flatMap(TranscriptionTimestampMode.init(rawValue:)) ?? .none
        transcriptionLanguage = UserDefaults.standard.string(forKey: "transcriptionLanguage").flatMap(TranscriptionLanguage.init(rawValue:)) ?? .korean
        let organizationPreferences = TranscriptOrganizationPreferencesStore().load()
        automaticallyOrganizeTranscripts = organizationPreferences.automaticallyOrganize
        organizationKind = organizationPreferences.defaultKind
        organizationDetailLevel = organizationPreferences.detail
        lectureOrganizationPrompt = organizationPreferences.lecturePrompt
        meetingOrganizationPrompt = organizationPreferences.meetingPrompt
        generalOrganizationPrompt = organizationPreferences.generalPrompt
        let state = store.load()
        if let url = state.lastNotionURL, let date = state.lastSuccessAt {
            lastBriefing = DailyBriefing(dateKey: BriefingService.dateKey(date), items: [], sourceCounts: [:], failures: [], notionURL: url, updatedAt: date)
        }
        refreshRecordings()
        dictation.isOtherWorkRunning = { [weak self] in
            guard let self else { return false }
            return self.isTranscribing || self.isOrganizingTranscript
        }
        dictation.activate()
        // Dictation is its own observable object; forward its changes so the menu
        // bar icon and overview reflect it without duplicating the state here.
        dictation.objectWillChange
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &cancellables)
        // Same for the recorder: without this the elapsed time published every
        // quarter second never reaches the views, so the counter sits at 0:00.
        audioRecorder.objectWillChange
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &cancellables)
    }

    func saveBriefingPreferences() {
        do {
            try briefingPreferencesStore.save(BriefingPreferences(
                userInstructions: briefingUserInstructions,
                ignoredPatterns: .preferenceLines(briefingIgnoredPatternsText),
                importantPatterns: .preferenceLines(briefingImportantPatternsText)
            ))
            briefingPreferencesStatus = "저장했습니다. 다음 실행부터 적용됩니다."
        } catch { briefingPreferencesStatus = error.localizedDescription }
    }

    func resetBriefingPreferences() {
        briefingUserInstructions = BriefingPreferences.defaultInstructions
        briefingIgnoredPatternsText = ""
        briefingImportantPatternsText = ""
        saveBriefingPreferences()
    }

    func requestCalendarReadAccess() {
        Task { [weak self] in
            do {
                try await CalendarIntegration.requestReadAccess()
                await MainActor.run {
                    self?.calendarAuthorizationStatus = CalendarIntegration.authorizationDescription
                    self?.briefingPreferencesStatus = "캘린더 읽기 권한을 허용했습니다. 다음 인박스 정리부터 앞으로 14일 일정을 함께 읽습니다."
                }
            } catch {
                await MainActor.run {
                    self?.calendarAuthorizationStatus = CalendarIntegration.authorizationDescription
                    self?.briefingPreferencesStatus = error.localizedDescription
                }
            }
        }
    }

    func saveOrganizationPreferences() {
        do {
            try organizationPreferencesStore.save(.init(
                automaticallyOrganize: automaticallyOrganizeTranscripts,
                defaultKind: organizationKind,
                detail: organizationDetailLevel,
                lecturePrompt: lectureOrganizationPrompt,
                meetingPrompt: meetingOrganizationPrompt,
                generalPrompt: generalOrganizationPrompt
            ))
            organizationPreferencesStatus = "저장했습니다. 다음 AI 정리부터 적용됩니다."
        } catch { organizationPreferencesStatus = error.localizedDescription }
    }

    func resetOrganizationPrompts() {
        lectureOrganizationPrompt = TranscriptOrganizationPreferences.defaultLecturePrompt
        meetingOrganizationPrompt = TranscriptOrganizationPreferences.defaultMeetingPrompt
        generalOrganizationPrompt = TranscriptOrganizationPreferences.defaultGeneralPrompt
        saveOrganizationPreferences()
    }

    func startBriefing() {
        guard !isRunning else { return }
        isRunning = true
        briefingStartedAt = Date()
        briefingETA = selectedRange.days.map { TimeInterval(max(300, $0 * 150)) } ?? 600
        phase = .collecting
        errorMessage = nil
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let briefing = try await BriefingService().run(range: selectedRange) { [weak self] phase, detail, pendingItemCount in
                    await MainActor.run {
                        self?.phase = phase
                        self?.detail = detail
                        self?.updateBriefingETA(phase: phase, detail: detail, pendingItemCount: pendingItemCount)
                    }
                }
                phase = .completed
                detail = "Notion 브리핑을 생성했고 모델을 언로드했습니다."
                lastBriefing = briefing
                briefingETA = 0
            } catch AgentError.cancelled {
                phase = .cancelled
                detail = "작업을 중지하고 로컬 모델을 해제했습니다."
            } catch {
                phase = .failed
                errorMessage = error.localizedDescription
                detail = "원본 서비스는 변경하지 않았습니다."
            }
            isRunning = false
            task = nil
        }
    }

    private func updateBriefingETA(phase: RunPhase, detail: String, pendingItemCount: Int?) {
        let elapsed = Date().timeIntervalSince(briefingStartedAt ?? Date())
        switch phase {
        case .collecting:
            // The service reports the real number of items it is about to classify,
            // so the estimate no longer depends on the wording of a progress line.
            if let count = pendingItemCount {
                let perItem = briefingQualityMode == .thorough ? 13.0 : 9.0
                briefingETA = count == 0 ? 30 : max(60, Double(count) * perItem - elapsed)
            }
        case .classifying:
            briefingETA = max(45, (briefingETA ?? 300) - 15)
        case .writing:
            briefingETA = detail.contains("4/4") ? 10 : 45
        case .completed: briefingETA = 0
        default: break
        }
    }

    var briefingETAString: String {
        guard let eta = briefingETA, isRunning else { return "" }
        let minutes = max(1, Int(ceil(eta / 60)))
        return "예상 남은 시간 약 \(minutes)분"
    }

    func stopBriefing() {
        guard isRunning else { return }
        detail = "중단 요청 중 · 로컬 모델을 안전하게 해제하고 있습니다."
        task?.cancel()
    }

    func stopTranscription() {
        guard isTranscribing else { return }
        transcriptionDetail = "전사 중단 요청 중 · 음성 인식 프로세스를 종료하고 있습니다."
        transcriptionTask?.cancel()
        ActiveProcessRegistry.shared.terminateProcesses(containing: "scripts/transcribe_runner.py")
    }

    func stopTranscriptOrganization() {
        guard isOrganizingTranscript else { return }
        organizationDetail = "AI 정리 중단 요청 중 · 로컬 모델을 안전하게 해제하고 있습니다."
        organizationTask?.cancel()
    }

    func stopAllWork() {
        stopBriefing()
        stopTranscription()
        stopTranscriptOrganization()
        stopMediaImport()
        stopDocumentRecognition()
        dictation.cancel()
    }

    func openLatestResult() {
        guard let url = lastBriefing?.notionURL else { return }
        NSWorkspace.shared.open(url)
    }

    func cancelProcessingItem(_ id: UUID) {
        if id == activeProcessingItemID {
            switch activeProcessingItem?.kind {
            case .transcription: stopTranscription()
            case .organization: stopTranscriptOrganization()
            case nil: break
            }
            return
        }
        processingQueueState.remove(id)
        processingQueue = processingQueueState.items
    }

    func clearWaitingProcessingItems() {
        let activeID = activeProcessingItemID
        processingQueueState.clearWaiting(activeID: activeID)
        processingQueue = processingQueueState.items
    }

    private func startNextProcessingItemIfNeeded() {
        // Only one local model job runs at a time. Anything queued while a job is
        // still finishing stays queued and is picked up by the next completion,
        // instead of being discarded to make room.
        guard !isTranscribing, !isOrganizingTranscript else { return }
        guard let work = processingQueueState.next(activeID: activeProcessingItemID) else { return }
        activeProcessingItemID = work.id
        switch work.payload {
        case .transcription(let payload): startTranscription(payload)
        case .organization(let payload): startOrganization(payload)
        }
    }

    private func finishActiveProcessingItem() {
        if let id = activeProcessingItemID {
            processingQueueState.remove(id)
            processingQueue = processingQueueState.items
            activeProcessingItemID = nil
        }
        startNextProcessingItemIfNeeded()
    }

    func transcribe(fileURL: URL) {
        // Capturing audio and running the ASR model are independent — the mic feeds
        // AVFoundation while the model runs in its own process — so the two overlap
        // freely. The one file that cannot be queued is the take still being written.
        guard fileURL.standardizedFileURL.path != audioRecorder.currentFileURL?.standardizedFileURL.path else {
            transcriptionError = "지금 녹음 중인 파일입니다. 녹음을 중지한 뒤 전사해 주세요."
            return
        }
        if MediaImporter.isVideo(fileURL) {
            importLocalVideo(fileURL)
            return
        }
        enqueueTranscription(ensureRecording(for: fileURL))
    }

    // MARK: - 영상 가져오기

    func importMediaFromURL() {
        let address = mediaURLText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !address.isEmpty, !isImportingMedia else { return }
        guard MediaImporter.looksLikeMediaURL(address) else {
            mediaImportError = "http 또는 https로 시작하는 영상 주소를 입력해 주세요."
            return
        }
        runMediaImport(startingWith: "1/3 · 영상 정보를 확인하고 있습니다.") { importer, progress in
            try await importer.importRemoteVideo(address, progress: progress)
        } onSuccess: { [weak self] in
            self?.mediaURLText = ""
        }
    }

    private func importLocalVideo(_ url: URL) {
        runMediaImport(startingWith: "영상에서 오디오를 추출하고 있습니다.") { importer, progress in
            try await importer.importLocalVideo(url, progress: progress)
        } onSuccess: { }
    }

    private func runMediaImport(
        startingWith status: String,
        operation: @escaping @Sendable (MediaImporter, @escaping @Sendable (String) async -> Void) async throws -> MediaImporter.ImportedMedia,
        onSuccess: @escaping @MainActor () -> Void
    ) {
        guard !isImportingMedia else { return }
        isImportingMedia = true
        mediaImportError = nil
        mediaImportStatus = status
        mediaImportTask = Task { [weak self] in
            guard let self else { return }
            do {
                let media = try await operation(MediaImporter()) { [weak self] detail in
                    await MainActor.run { self?.mediaImportStatus = detail }
                }
                onSuccess()
                self.registerImportedMedia(media)
            } catch is CancellationError {
                self.mediaImportStatus = "영상 가져오기를 중단했습니다."
            } catch {
                self.mediaImportError = error.localizedDescription
                self.mediaImportStatus = ""
            }
            self.isImportingMedia = false
            self.mediaImportTask = nil
        }
    }

    /// The extracted audio lands in the app's own recordings folder, so it becomes
    /// an ordinary library item rather than a separately tracked external file.
    private func registerImportedMedia(_ media: MediaImporter.ImportedMedia) {
        let item = RecordingItem(
            id: "app:\(media.url.path)", source: .app,
            title: media.url.deletingPathExtension().lastPathComponent, url: media.url,
            date: Date(), duration: (try? AVAudioPlayer(contentsOf: media.url).duration) ?? 0,
            isLocallyAvailable: true
        )
        recordings.removeAll { $0.id == item.id }
        recordings.insert(item, at: 0)
        selectedRecordingID = item.id
        mediaImportStatus = "‘\(item.title)’을 보관함에 추가하고 전사 대기열에 넣었습니다."
        enqueueTranscription(item)
        refreshRecordings()
    }

    func stopMediaImport() {
        guard isImportingMedia else { return }
        mediaImportStatus = "영상 가져오기를 중단하는 중"
        mediaImportTask?.cancel()
    }

    // MARK: - 문서 인식

    func recognizeDocument(fileURL: URL, removingSourceAfterwards removeSource: Bool = false) {
        guard !isRecognizingDocument else { return }
        guard DocumentRecognizer.isSupported(fileURL) else {
            recognitionError = "이미지 또는 PDF 파일만 인식할 수 있습니다."
            return
        }
        isRecognizingDocument = true
        recognitionError = nil
        recognizedNoteText = ""
        recognizedText = ""
        recognizedSourceName = fileURL.lastPathComponent
        let mode = documentMode
        recognizedTextIsMarkdown = mode.producesMarkdown
        recognitionStatus = mode == .precise ? "정밀 인식을 시작합니다." : "글자를 인식하고 있습니다."
        recognitionTask = Task { [weak self] in
            guard let self else { return }
            defer { if removeSource { try? FileManager.default.removeItem(at: fileURL) } }
            do {
                if mode == .precise {
                    let result = try await DocumentParsingService().parse(fileURL: fileURL) { detail in
                        await MainActor.run { self.recognitionStatus = detail }
                    }
                    self.recognizedText = result.markdown
                    self.recognitionStatus = "수식·표 정밀 인식 완료 · \(result.pageCount)쪽 · \(result.markdown.count)자"
                } else {
                    // Vision recognition is synchronous CPU work; keep it off the main actor.
                    let result = try await Task.detached(priority: .userInitiated) {
                        try await DocumentRecognizer().recognize(fileURL: fileURL) { detail in
                            await MainActor.run { self.recognitionStatus = detail }
                        }
                    }.value
                    self.recognizedText = result.text
                    let method = result.usedOpticalRecognition ? "글자 인식" : "PDF 내장 텍스트"
                    self.recognitionStatus = "\(method) 완료 · \(result.pageCount)쪽 · \(result.text.count)자"
                }
            } catch is CancellationError {
                self.recognitionStatus = "문서 인식을 중단했습니다."
            } catch {
                self.recognitionError = error.localizedDescription
                self.recognitionStatus = ""
            }
            self.isRecognizingDocument = false
            self.recognitionTask = nil
        }
    }

    func captureScreenAndRecognize() {
        guard !isRecognizingDocument else { return }
        recognitionError = nil
        recognitionStatus = "인식할 화면 영역을 드래그해 주세요."
        Task { [weak self] in
            guard let self else { return }
            do {
                guard let url = try await DocumentRecognizer.captureScreenRegion() else {
                    self.recognitionStatus = "화면 캡처를 취소했습니다."
                    return
                }
                self.recognizeDocument(fileURL: url, removingSourceAfterwards: true)
            } catch {
                self.recognitionError = "화면을 캡처하지 못했습니다: \(error.localizedDescription)"
                self.recognitionStatus = ""
            }
        }
    }

    func stopDocumentRecognition() {
        guard isRecognizingDocument else { return }
        recognitionTask?.cancel()
    }

    func copyRecognizedText() {
        guard !recognizedText.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(recognizedText, forType: .string)
        recognitionStatus = "인식한 텍스트를 복사했습니다."
    }

    func copyRecognizedNote() {
        guard !recognizedNoteText.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(recognizedNoteText, forType: .string)
    }

    func saveRecognizedText() {
        guard !recognizedText.isEmpty else { return }
        let panel = NSSavePanel()
        panel.title = "인식한 텍스트 저장"
        let stem = URL(fileURLWithPath: recognizedSourceName).deletingPathExtension().lastPathComponent
        panel.nameFieldStringValue = recognizedTextIsMarkdown ? "\(stem).md" : "\(stem).txt"
        panel.allowedContentTypes = recognizedTextIsMarkdown ? [.init(filenameExtension: "md") ?? .plainText] : [.plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try Data(recognizedText.utf8).write(to: url, options: .atomic)
            recognitionStatus = "저장했습니다: \(url.lastPathComponent)"
        } catch {
            recognitionError = "저장하지 못했습니다: \(error.localizedDescription)"
        }
    }

    // MARK: - 누끼 따기

    /// Photos are processed one after another rather than concurrently: a single
    /// resident model is the whole point, and running two 2048² passes at once
    /// would only make both slower.
    func removeBackground(fileURLs: [URL]) {
        guard !isRemovingBackground else { return }
        let sources = fileURLs.filter(BackgroundRemovalService.isSupported)
        guard !sources.isEmpty else {
            cutoutError = "이미지 파일만 누끼를 딸 수 있습니다."
            return
        }
        cutoutError = nil
        cutoutItems = sources.map { CutoutItem(source: $0) }
        isRemovingBackground = true
        let model = mattingModel
        cutoutStatus = sources.count == 1 ? "배경을 지우고 있습니다." : "\(sources.count)장을 순서대로 처리하고 있습니다."
        cutoutTask = Task { [weak self] in
            guard let self else { return }
            let service = BackgroundRemovalService()
            var succeeded = 0
            var cancelled = false
            for (index, source) in sources.enumerated() {
                if Task.isCancelled { cancelled = true; break }
                self.updateCutout(at: index) { $0.state = .working("준비 중") }
                let started = Date()
                do {
                    let output = try await service.removeBackground(from: source, model: model) { detail in
                        Task { @MainActor [weak self] in
                            self?.updateCutout(at: index) { $0.state = .working(detail) }
                        }
                    }
                    self.updateCutout(at: index) {
                        $0.output = output
                        $0.state = .done(milliseconds: Int(Date().timeIntervalSince(started) * 1000))
                    }
                    succeeded += 1
                } catch is CancellationError {
                    self.updateCutout(at: index) { $0.state = .failed("중단했습니다.") }
                    cancelled = true
                    break
                } catch {
                    self.updateCutout(at: index) { $0.state = .failed(error.localizedDescription) }
                }
            }
            if cancelled {
                self.cutoutStatus = "누끼 따기를 중단했습니다."
            } else if succeeded == sources.count {
                self.cutoutStatus = "\(succeeded)장 완료했습니다."
            } else {
                self.cutoutStatus = "\(succeeded)/\(sources.count)장 완료했습니다."
            }
            self.isRemovingBackground = false
            self.cutoutTask = nil
        }
    }

    func stopBackgroundRemoval() {
        guard isRemovingBackground else { return }
        cutoutStatus = "누끼 따기를 중단하는 중"
        cutoutTask?.cancel()
    }

    private func updateCutout(at index: Int, _ change: (inout CutoutItem) -> Void) {
        guard cutoutItems.indices.contains(index) else { return }
        change(&cutoutItems[index])
    }

    /// The background colour is applied here, not in the runner, so switching
    /// between 투명/흰색/직접 선택 is instant and never re-runs the model.
    func cutoutPNG(_ item: CutoutItem) -> Data? {
        guard let output = item.output, let image = CutoutComposer.load(output) else { return nil }
        return CutoutComposer.pngData(from: image, background: cutoutBackgroundColor)
    }

    var cutoutBackgroundColor: CGColor? {
        cutoutBackground.color(custom: cutoutCustomColorComponents)
    }

    /// Plain values rather than a `CGColor`, so a background thread can build
    /// the colour itself instead of having one handed across.
    var cutoutCustomColorComponents: CutoutBackground.Color? {
        Self.components(of: cutoutCustomColor)
    }

    func copyCutout(_ item: CutoutItem) {
        guard let data = cutoutPNG(item) else {
            cutoutError = "결과 이미지를 읽지 못했습니다."
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setData(data, forType: .png)
        cutoutStatus = "클립보드에 복사했습니다: \(item.source.lastPathComponent)"
    }

    func saveCutout(_ item: CutoutItem) {
        guard let data = cutoutPNG(item) else {
            cutoutError = "결과 이미지를 읽지 못했습니다."
            return
        }
        let panel = NSSavePanel()
        panel.title = "누끼 이미지 저장"
        panel.nameFieldStringValue = Self.cutoutFileName(for: item)
        panel.allowedContentTypes = [.png]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try data.write(to: url, options: .atomic)
            cutoutStatus = "저장했습니다: \(url.lastPathComponent)"
        } catch {
            cutoutError = "저장하지 못했습니다: \(error.localizedDescription)"
        }
    }

    func saveAllCutouts() {
        let finished = cutoutItems.filter(\.isFinished)
        guard !finished.isEmpty else { return }
        let panel = NSOpenPanel()
        panel.title = "누끼 이미지를 저장할 폴더 선택"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "저장"
        guard panel.runModal() == .OK, let directory = panel.url else { return }
        var saved = 0
        for item in finished {
            guard let data = cutoutPNG(item) else { continue }
            let target = directory.appending(path: Self.cutoutFileName(for: item))
            do {
                try data.write(to: target, options: .atomic)
                saved += 1
            } catch {
                cutoutError = "저장하지 못했습니다: \(error.localizedDescription)"
            }
        }
        cutoutStatus = "\(saved)장을 저장했습니다: \(directory.lastPathComponent)"
    }

    private static func cutoutFileName(for item: CutoutItem) -> String {
        "\(item.source.deletingPathExtension().lastPathComponent)-누끼.png"
    }

    // MARK: 색 저장

    private static func components(of color: Color) -> CutoutBackground.Color? {
        guard let srgb = NSColor(color).usingColorSpace(.sRGB) else { return nil }
        return CutoutBackground.Color(red: srgb.redComponent, green: srgb.greenComponent, blue: srgb.blueComponent)
    }

    fileprivate static func hex(from color: Color) -> String {
        guard let parts = components(of: color) else { return "#FFFFFF" }
        return String(format: "#%02X%02X%02X", Int(parts.red * 255), Int(parts.green * 255), Int(parts.blue * 255))
    }

    fileprivate static func color(fromHex hex: String?) -> Color? {
        guard var value = hex?.trimmingCharacters(in: .whitespaces), value.hasPrefix("#") else { return nil }
        value.removeFirst()
        guard value.count == 6, let number = UInt32(value, radix: 16) else { return nil }
        return Color(
            red: Double((number >> 16) & 0xFF) / 255,
            green: Double((number >> 8) & 0xFF) / 255,
            blue: Double(number & 0xFF) / 255
        )
    }

    /// Reuses the same one-at-a-time queue and Korean note prompts the transcript
    /// organiser uses, so recognised slides become notes in the same house style.
    func organizeRecognizedText() {
        guard !recognizedText.isEmpty, !isRecognizingDocument else { return }
        let run = TranscriptRun(
            id: UUID(), recordingID: "ocr:\(UUID().uuidString)", createdAt: .now, completedAt: .now,
            duration: 0, settings: .init(), backend: nil, text: recognizedText, segments: [],
            engineVersion: "vision-ocr", isLegacy: false
        )
        recognizedNoteText = ""
        enqueueOrganization(run, titleOverride: recognizedSourceName.isEmpty ? "인식한 문서" : recognizedSourceName)
    }

    private func enqueueTranscription(_ recording: RecordingItem) {
        let item = ProcessingQueueItem(
            id: UUID(),
            kind: .transcription,
            title: recording.title,
            detail: "\(asrModel.title) · \(transcriptionLanguage.title)",
            enqueuedAt: Date()
        )
        let payload = TranscriptionQueuePayload(
            recording: recording,
            asrModel: asrModel,
            diarization: diarization,
            timestampMode: transcriptionTimestampMode,
            language: transcriptionLanguage
        )
        processingQueueState.enqueue(.init(item: item, payload: .transcription(payload)))
        processingQueue = processingQueueState.items
        startNextProcessingItemIfNeeded()
    }

    private func startTranscription(_ payload: TranscriptionQueuePayload) {
        guard !isTranscribing, !isOrganizingTranscript else {
            // Leave the work queued; the running job's completion restarts it.
            activeProcessingItemID = nil
            return
        }
        let recording = payload.recording
        let fileURL = recording.url
        isTranscribing = true
        transcriptionError = nil
        transcriptionText = ""
        transcriptionStep = 1
        transcriptionStartedAt = Date()
        transcriptionETA = nil
        transcribingRecordingID = recording.id
        transcriptionTask = Task { [weak self] in
            guard let self else { return }
            do {
                let startedAt = Date()
                let settings = TranscriptionSettingsSnapshot(asrModel: payload.asrModel, diarization: payload.diarization, timestampMode: payload.timestampMode, language: payload.language)
                let result = try await TranscriptionService().transcribe(fileURL, asrModel: payload.asrModel, diarization: payload.diarization, timestampMode: payload.timestampMode, language: payload.language) { [weak self] detail in
                    await MainActor.run {
                        self?.transcriptionDetail = detail
                        if let prefix = detail.split(separator: " ").first, let step = Int(prefix.split(separator: "/").first ?? "") {
                            self?.transcriptionStep = max(self?.transcriptionStep ?? 0, step)
                            self?.updateETA(recordingDuration: recording.duration, asrModel: payload.asrModel, diarization: payload.diarization)
                        }
                    }
                }
                let completedAt = Date()
                let run = TranscriptRun(
                    id: UUID(), recordingID: recording.id, createdAt: startedAt, completedAt: completedAt,
                    duration: completedAt.timeIntervalSince(startedAt), settings: settings, backend: result.backend,
                    text: result.text, segments: result.segments, engineVersion: "mlx-qwen3-asr-v2", isLegacy: false
                )
                transcriptArchive.runsByRecording[recording.id, default: []].append(run)
                // A save failure here would silently lose a transcript that took minutes.
                if let failure = transcriptArchive.saveReportingFailure() {
                    transcriptionError = failure
                }
                selectedTranscriptRunID = run.id
                transcriptionText = run.text
                if automaticallyOrganizeTranscripts { enqueueOrganization(run) }
                transcriptionStep = 4
                transcriptionDetail = "전사 완료. 모델 프로세스가 종료되어 메모리를 반환했습니다."
            } catch is CancellationError {
                transcriptionError = nil
                transcriptionDetail = "전사를 중단했고 음성 인식 프로세스를 종료했습니다. 기존 전사 결과는 유지됩니다."
            } catch {
                transcriptionError = error.localizedDescription
                transcriptionDetail = "전사에 실패했습니다. 파일과 화자 분리 설정을 확인해 주세요."
            }
            isTranscribing = false
            transcribingRecordingID = nil
                transcriptionETA = nil
                transcriptionTask = nil
                finishActiveProcessingItem()
            }
        }

    private func updateETA(recordingDuration duration: TimeInterval, asrModel: ASRModelChoice, diarization: DiarizationChoice) {
        guard let startedAt = transcriptionStartedAt, transcriptionStep >= 2, duration > 0 else { return }
        let elapsed = Date().timeIntervalSince(startedAt)
        // Conservative local-MLX estimate, refined as each stage finishes.
        let asrFactor: Double = switch asrModel {
        case .qwen06B8Bit: 0.05
        case .qwen06B: 0.10
        case .qwen17B: 0.30
        case .qwen17BSpeculative: 0.50
        }
        let expected = duration * (asrFactor + (diarization.isEnabled ? 0.25 : 0)) + 8
        transcriptionETA = max(0, expected - elapsed)
    }

    func transcribe(recording: RecordingItem) {
        selectedRecordingID = recording.id
        selectLatestTranscript(for: recording)
        guard recording.isLocallyAvailable else {
            transcriptionError = "이 녹음은 iCloud에만 있습니다. 음성 메모 앱에서 먼저 재생해 원본을 다운로드한 뒤 새로고침해 주세요."
            return
        }
        transcribe(fileURL: recording.url)
    }

    func selectedTranscriptFor(_ recording: RecordingItem) -> String? {
        if let current = transcriptArchive.runs(for: recording.id).first { return current.text }
        let legacyID = "voice:file:\(recording.url.path)"
        guard let legacy = transcriptArchive.runs(for: legacyID).first else { return nil }
        var migrated = legacy
        migrated.recordingID = recording.id
        transcriptArchive.runsByRecording[recording.id, default: []].append(migrated)
        transcriptArchive.save()
        return migrated.text
    }

    func transcriptRuns(for recording: RecordingItem) -> [TranscriptRun] {
        _ = selectedTranscriptFor(recording)
        return transcriptArchive.runs(for: recording.id)
    }

    func selectRecording(_ recording: RecordingItem) {
        selectedRecordingID = recording.id
        selectLatestTranscript(for: recording)
    }

    func selectTranscript(_ id: UUID) {
        selectedTranscriptRunID = id
        selectedOrganizationRunID = nil
        transcriptionText = selectedTranscriptRun?.text ?? ""
    }

    private func selectLatestTranscript(for recording: RecordingItem) {
        let run = transcriptRuns(for: recording).first
        selectedTranscriptRunID = run?.id
        selectedOrganizationRunID = nil
        transcriptionText = run?.text ?? ""
    }

    func organizationRuns(for transcript: TranscriptRun) -> [TranscriptOrganizationRun] {
        transcriptArchive.organizations(for: transcript.id)
    }

    func organizationPrompt(for kind: TranscriptOrganizationKind) -> String {
        switch kind {
        case .lecture: lectureOrganizationPrompt
        case .meeting: meetingOrganizationPrompt
        case .general: generalOrganizationPrompt
        }
    }

    func organizeSelectedTranscript() {
        guard let run = selectedTranscriptRun else { return }
        enqueueOrganization(run)
    }

    private func enqueueOrganization(_ run: TranscriptRun, titleOverride: String? = nil) {
        let recordingTitle = titleOverride ?? recordings.first { $0.id == run.recordingID }?.title ?? "저장된 전사"
        let item = ProcessingQueueItem(
            id: UUID(),
            kind: .organization,
            title: recordingTitle,
            detail: "\(organizationKind.title) · \(organizationDetailLevel.title)",
            enqueuedAt: Date()
        )
        let payload = OrganizationQueuePayload(
            transcript: run,
            recordingTitle: recordingTitle,
            kind: organizationKind,
            detail: organizationDetailLevel,
            prompt: organizationPrompt(for: organizationKind)
        )
        processingQueueState.enqueue(.init(item: item, payload: .organization(payload)))
        processingQueue = processingQueueState.items
        startNextProcessingItemIfNeeded()
    }

    private func startOrganization(_ payload: OrganizationQueuePayload) {
        guard !isTranscribing, !isOrganizingTranscript else {
            activeProcessingItemID = nil
            return
        }
        organizationTask = Task { [weak self] in
            await self?.organizeTranscript(payload)
            self?.finishActiveProcessingItem()
        }
    }

    private func organizeTranscript(_ payload: OrganizationQueuePayload) async {
        let run = payload.transcript
        isOrganizingTranscript = true
        organizationError = nil
        organizationStartedAt = Date()
        organizationETA = TranscriptOrganizer.estimatedDuration(for: run)
        let kind = payload.kind
        let detailLevel = payload.detail
        let prompt = payload.prompt
        let organizer = TranscriptOrganizer()
        defer {
            isOrganizingTranscript = false
            organizationETA = nil
        }
        do {
            let startedAt = Date()
            let text = try await organizer.organize(transcript: run, detail: detailLevel, prompt: prompt) { [weak self] detail in
                await MainActor.run {
                    self?.organizationDetail = detail
                    if let started = self?.organizationStartedAt, let eta = self?.organizationETA {
                        self?.organizationETA = max(10, eta - Date().timeIntervalSince(started))
                        self?.organizationStartedAt = Date()
                    }
                }
            }
            let completedAt = Date()
            let organization = TranscriptOrganizationRun(
                id: UUID(), transcriptRunID: run.id, createdAt: startedAt, completedAt: completedAt,
                duration: completedAt.timeIntervalSince(startedAt), kind: kind, detail: detailLevel,
                model: AppConfig.model, promptSnapshot: prompt, text: text
            )
            if run.recordingID.hasPrefix("ocr:") {
                // Recognised text is not a recording, so it gets no archive entry;
                // the result belongs to the document panel that asked for it.
                recognizedNoteText = text
            } else {
                transcriptArchive.organizationsByTranscript[run.id.uuidString, default: []].append(organization)
                if let failure = transcriptArchive.saveReportingFailure() { organizationError = failure }
                selectedOrganizationRunID = organization.id
            }
            organizationDetail = "AI 정리 완료. 로컬 모델을 언로드하고 있습니다."
        } catch is CancellationError {
            organizationError = nil
            organizationDetail = "AI 정리를 중단했고 로컬 모델을 해제했습니다. 전사 원문과 기존 정리는 유지됩니다."
        } catch {
            organizationError = error.localizedDescription
            organizationDetail = "AI 정리에 실패했습니다. 전사 원문은 그대로 보존되어 있습니다."
        }
        await organizer.unload()
        organizationTask = nil
    }

    func copyTranscription() {
        guard !selectedTranscript.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(selectedTranscript, forType: .string)
    }

    func copySelectedOrganization() {
        guard let text = selectedOrganizationRun?.text, !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func togglePlayback() {
        guard let recording = selectedRecording else { return }
        guard recording.isLocallyAvailable else {
            transcriptionError = "이 녹음은 iCloud에만 있습니다. 음성 메모 앱에서 먼저 재생해 다운로드해 주세요."
            return
        }
        if let audioPlayer, audioPlayer.isPlaying {
            audioPlayer.stop()
            isPlayingRecording = false
            return
        }
        do {
            let player = try AVAudioPlayer(contentsOf: recording.url)
            player.play()
            audioPlayer = player
            isPlayingRecording = true
        } catch { transcriptionError = "녹음을 재생하지 못했습니다: \(error.localizedDescription)" }
    }

    func toggleRecording() {
        if audioRecorder.isRecording {
            mostRecentRecording = audioRecorder.stop()
            refreshRecordings(selecting: mostRecentRecording)
            reportRecordingStatus(mostRecentRecording == nil ? "녹음을 저장하지 못했습니다." : "녹음이 저장되었습니다. 전사 버튼으로 바로 전사할 수 있습니다.")
            return
        }
        Task {
            if await audioRecorder.start() {
                reportRecordingStatus("녹음 중입니다. 중지하면 전사할 수 있습니다.")
            }
        }
    }

    /// `transcriptionDetail` doubles as the running job's progress line, so a
    /// recording started mid-transcription must not overwrite it.
    private func reportRecordingStatus(_ status: String) {
        guard !isTranscribing else { return }
        transcriptionDetail = status
    }

    /// Scanning the Voice Memos database and probing durations is file I/O, so it
    /// runs off the main actor; blocking here froze app launch and every rename,
    /// delete, or refresh once the library grew.
    func refreshRecordings(selecting url: URL? = nil) {
        recordingLibraryStatus = "녹음 보관함을 불러오는 중"
        Task { [weak self] in
            let library = await Task.detached(priority: .utility) { RecordingLibrary.load() }.value
            guard let self else { return }
            let external = self.transcriptArchive.externalRecordings.values.compactMap(\.item)
            // A take still being written has no finalised MPEG-4 container, so it
            // would sit in the library as a recording that can only fail.
            let inProgress = self.audioRecorder.currentFileURL?.standardizedFileURL.path
            self.recordings = Dictionary((library + external).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
                .values.filter { $0.url.standardizedFileURL.path != inProgress }
                .sorted { $0.date > $1.date }
            self.recordingLibraryStatus = self.recordings.isEmpty
                ? "녹음 파일을 찾지 못했습니다. Voice Memos 접근 권한을 확인해 주세요."
                : "\(self.recordings.count)개 녹음"
            if let url, let match = self.recordings.first(where: { $0.url.standardizedFileURL == url.standardizedFileURL }) {
                self.selectedRecordingID = match.id
            }
        }
    }

    private func ensureRecording(for url: URL) -> RecordingItem {
        if let existing = recordings.first(where: { $0.url.standardizedFileURL == url.standardizedFileURL }) { return existing }
        let standardized = url.standardizedFileURL
        let id = "file:\(standardized.path)"
        let date = (try? standardized.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .now
        let duration = (try? AVAudioPlayer(contentsOf: standardized).duration) ?? 0
        let metadata = ArchivedRecordingMetadata(
            id: id, title: standardized.deletingPathExtension().lastPathComponent,
            path: standardized.path, date: date, duration: duration
        )
        transcriptArchive.externalRecordings[id] = metadata
        transcriptArchive.save()
        let item = metadata.item ?? RecordingItem(id: id, source: .file, title: metadata.title, url: standardized, date: date, duration: duration, isLocallyAvailable: true)
        recordings.append(item)
        recordings.sort { $0.date > $1.date }
        selectedRecordingID = id
        return item
    }

    func requestVoiceMemoDownload(_ recording: RecordingItem) {
        guard recording.source == .voiceMemos, !recording.isLocallyAvailable,
              !downloadingRecordingIDs.contains(recording.id) else { return }
        downloadingRecordingIDs.insert(recording.id)
        selectedRecordingID = recording.id
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(recording.title, forType: .string)
        recordingLibraryStatus = "음성 메모에서 ‘\(recording.title)’을 눌러 주세요 · 완료는 자동 확인합니다"
        let applicationURL = URL(fileURLWithPath: "/System/Applications/VoiceMemos.app")
        NSWorkspace.shared.openApplication(at: applicationURL, configuration: .init()) { _, error in
            if let error {
                Task { @MainActor in
                    self.downloadingRecordingIDs.remove(recording.id)
                    self.transcriptionError = "음성 메모 앱을 열지 못했습니다: \(error.localizedDescription)"
                }
            }
        }

        Task { [weak self] in
            guard let self else { return }
            for _ in 0..<90 {
                try? await Task.sleep(for: .seconds(2))
                let size = (try? recording.url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                if size > 0 {
                    self.refreshRecordings()
                    self.downloadingRecordingIDs.remove(recording.id)
                    self.recordingLibraryStatus = "다운로드 완료 · \(self.recordings.count)개 녹음"
                    return
                }
            }
            self.downloadingRecordingIDs.remove(recording.id)
            self.recordingLibraryStatus = "다운로드 대기 시간이 지났습니다 · 음성 메모에서 항목 상태를 확인해 주세요"
        }
    }

    func rename(_ recording: RecordingItem, to proposedName: String) {
        guard recording.source == .app else { return }
        let name = proposedName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        let safeName = name.replacingOccurrences(of: "/", with: "-")
        let destination = recording.url.deletingLastPathComponent().appendingPathComponent(safeName).appendingPathExtension(recording.url.pathExtension)
        do {
            try FileManager.default.moveItem(at: recording.url, to: destination)
            if let runs = transcriptArchive.runsByRecording.removeValue(forKey: recording.id) {
                let destinationID = "app:\(destination.path)"
                transcriptArchive.runsByRecording[destinationID] = runs.map {
                    var value = $0; value.recordingID = destinationID; return value
                }
                if let failure = transcriptArchive.saveReportingFailure() { transcriptionError = failure }
            }
            refreshRecordings(selecting: destination)
        } catch { transcriptionError = "이름을 변경하지 못했습니다: \(error.localizedDescription)" }
    }

    func delete(_ recording: RecordingItem) {
        guard recording.source == .app else { return }
        do {
            try FileManager.default.trashItem(at: recording.url, resultingItemURL: nil)
            transcriptArchive.runsByRecording.removeValue(forKey: recording.id)
            transcriptArchive.save()
            if selectedRecordingID == recording.id { selectedRecordingID = nil; transcriptionText = "" }
            refreshRecordings()
        } catch { transcriptionError = "녹음을 휴지통으로 옮기지 못했습니다: \(error.localizedDescription)" }
    }

    func chooseVoiceMemosFolder() {
        let panel = NSOpenPanel()
        panel.title = "Voice Memos의 Recordings 폴더 선택"
        panel.message = "Voice Memos 녹음을 읽기 전용으로 표시하기 위해 Recordings 폴더를 선택하세요."
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = RecordingLibrary.voiceMemosDirectory()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        RecordingLibrary.saveVoiceMemosDirectory(url)
        refreshRecordings()
    }

}

struct MenuContentView: View {
    @ObservedObject var controller: AutomationController
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: controller.isRunning ? "arrow.triangle.2.circlepath.circle.fill" : "graduationcap.circle.fill")
                    .font(.title2).foregroundStyle(Color.snuBlue)
                VStack(alignment: .leading) {
                    Text("서울대 로컬 에이전트").font(.headline)
                    Text(controller.phase.rawValue).font(.caption).foregroundStyle(.secondary)
                }
            }
            Divider()
            ProgressView(value: controller.progressValue)
                .tint(.snuBlue)
            VStack(alignment: .leading, spacing: 5) {
                ProgressStep(title: "새 항목 수집", isCurrent: controller.phase == .collecting, isDone: controller.phase == .classifying || controller.phase == .writing || controller.phase == .completed)
                ProgressStep(title: "로컬 모델 로드 · 분류", isCurrent: controller.phase == .classifying, isDone: controller.phase == .writing || controller.phase == .completed)
                ProgressStep(title: "Notion 브리핑 작성", isCurrent: controller.phase == .writing, isDone: controller.phase == .completed)
                ProgressStep(title: "모델 언로드", isCurrent: controller.phase == .completed, isDone: controller.phase == .completed)
            }
            Text(controller.detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let error = controller.errorMessage { Text(error).font(.caption).foregroundStyle(.red).lineLimit(3) }
            Divider()
            HStack(spacing: 10) {
                Image(systemName: controller.dictation.isRecording ? "mic.fill" : "mic")
                    .foregroundStyle(controller.dictation.isRecording ? Color.red : Color.snuBlue)
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 2) {
                    Text("받아쓰기").font(.subheadline)
                    Text(controller.dictation.status)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer()
                if controller.dictation.isTranscribing {
                    ProgressView().controlSize(.small)
                } else {
                    Button(controller.dictation.isRecording ? "중지" : "시작") { controller.dictation.toggle() }
                        .buttonStyle(.bordered)
                }
            }
            if let error = controller.dictation.errorMessage {
                Text(error).font(.caption2).foregroundStyle(.red).lineLimit(2)
            }
            Divider()
            Button("앱 열기", systemImage: "macwindow") {
                dismiss()
                DispatchQueue.main.async {
                    openWindow(id: "main")
                }
            }
                .buttonStyle(.borderedProminent)
                .tint(.snuBlue)
            Text("브리핑, 녹음·전사, 설정은 통합 앱에서 관리합니다.")
                .font(.caption).foregroundStyle(.secondary)
            Divider()
            Button("종료", role: .destructive) { NSApplication.shared.terminate(nil) }
        }
        .padding(16)
        .frame(width: 360)
    }
}

private struct MainWorkspaceView: View {
    @ObservedObject var controller: AutomationController
    @State private var section: AppSection? = .overview
    var body: some View {
        NavigationSplitView {
            List(AppSection.allCases, selection: $section) { item in
                Label(item.title, systemImage: item.symbol).tag(item)
            }
            .navigationTitle("서울대 로컬 에이전트")
        } detail: {
            switch section ?? .overview {
            case .overview: OverviewView(controller: controller)
            case .transcription: TranscriptionWindowView(controller: controller, compact: false)
            case .documents: DocumentRecognitionView(controller: controller)
            case .cutout: CutoutView(controller: controller)
            case .briefing: BriefingStatusWorkspaceView(controller: controller)
            case .settings: TranscriptionSettingsPanel(controller: controller)
            }
        }
        .navigationSplitViewStyle(.balanced)
    }
}

private struct OverviewView: View {
    @ObservedObject var controller: AutomationController
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("오늘의 로컬 에이전트").font(.largeTitle.weight(.semibold))
            Text("녹음 전사와 개인 브리핑은 모두 이 Mac에서 처리됩니다.").foregroundStyle(.secondary)
            HStack(spacing: 14) {
                StatusTile(title: "녹음 보관함", value: "\(controller.recordings.count)개", symbol: "waveform")
                StatusTile(title: "자동 브리핑", value: controller.phase.rawValue, symbol: "tray.full")
                StatusTile(
                    title: "받아쓰기 단축키",
                    value: controller.dictation.shortcut == .disabled ? "꺼짐" : controller.dictation.shortcut.title,
                    symbol: "mic"
                )
            }
            Text(controller.dictation.status).font(.caption).foregroundStyle(.secondary)
            Spacer()
        }.padding(32)
    }
}

private struct StatusTile: View {
    let title: String; let value: String; let symbol: String
    var body: some View { VStack(alignment: .leading, spacing: 10) { Image(systemName: symbol).font(.title2).foregroundStyle(Color.snuBlue); Text(title).font(.caption).foregroundStyle(.secondary); Text(value).font(.title3.weight(.semibold)) }.frame(width: 180, alignment: .leading).padding(18).background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous)) }
}

private struct BriefingStatusWorkspaceView: View {
    @ObservedObject var controller: AutomationController
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack {
                VStack(alignment: .leading) { Text("자동 브리핑").font(.largeTitle.weight(.semibold)); Text("수집부터 결과 작성까지의 상태를 확인합니다.").foregroundStyle(.secondary) }
                Spacer()
                Button(controller.isRunning ? "중지" : "인박스 정리 시작", systemImage: controller.isRunning ? "stop.fill" : "tray.full.fill") { controller.isRunning ? controller.stopBriefing() : controller.startBriefing() }.buttonStyle(.borderedProminent).tint(controller.isRunning ? .red : .snuBlue)
            }
 HStack {
 Label(controller.selectedRange.rawValue, systemImage: "calendar.badge.clock")
 Text("· \(controller.briefingQualityMode.title)").foregroundStyle(.secondary)
 Spacer()
 Text("설정에서 변경").font(.caption).foregroundStyle(.secondary)
 }
            VStack(alignment: .leading, spacing: 12) {
                HStack { Label(controller.phase.rawValue, systemImage: controller.isRunning ? "arrow.triangle.2.circlepath" : "checkmark.circle").font(.headline).foregroundStyle(Color.snuBlue); Spacer(); Text(controller.isRunning ? "실행 중" : "대기").font(.caption.weight(.medium)).foregroundStyle(.secondary) }
 ProgressView(value: controller.progressValue).tint(.snuBlue)
 if !controller.briefingETAString.isEmpty {
 Label(controller.briefingETAString, systemImage: "clock.arrow.circlepath")
 .font(.callout.weight(.medium)).foregroundStyle(.secondary).monospacedDigit()
 }
                BriefingStatusRow(title: "새 항목 수집", active: controller.phase == .collecting, done: controller.phase == .classifying || controller.phase == .writing || controller.phase == .completed)
                BriefingStatusRow(title: "로컬 모델 분류", active: controller.phase == .classifying, done: controller.phase == .writing || controller.phase == .completed)
                BriefingStatusRow(title: "Notion 브리핑 작성", active: controller.phase == .writing, done: controller.phase == .completed)
                BriefingStatusRow(title: "모델 언로드", active: controller.phase == .completed, done: controller.phase == .completed)
                Text(controller.detail).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if let error = controller.errorMessage { Text(error).font(.caption).foregroundStyle(.red) }
            }.padding(20).background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            if controller.lastBriefing?.notionURL != nil { Button("최근 브리핑 보기", systemImage: "doc.text.magnifyingglass", action: controller.openLatestResult).buttonStyle(.bordered) }
            Spacer()
        }.padding(32)
    }
}

private struct BriefingStatusRow: View {
    let title: String; let active: Bool; let done: Bool
    var body: some View { HStack(spacing: 9) { Image(systemName: done ? "checkmark.circle.fill" : (active ? "circle.inset.filled" : "circle")).foregroundStyle(done ? .green : (active ? Color.snuBlue : .secondary)); Text(title).foregroundStyle(active ? .primary : .secondary); Spacer() } }
}

private struct TranscriptionSettingsPanel: View {
    @ObservedObject var controller: AutomationController
    @AppStorage("slackMentionUserID") private var slackMentionUserID = ""
    @State private var diarizationToken = ""
    @State private var diarizationTokenStatus = ""
    var body: some View {
        Form {
            Section("자동 브리핑") {
                Picker("수집 범위", selection: $controller.selectedRange) {
                    ForEach(CollectionRange.allCases) { Text($0.rawValue).tag($0) }
                }
                Picker("분석 품질", selection: $controller.briefingQualityMode) {
                    ForEach(BriefingQualityMode.allCases) { Text($0.title).tag($0) }
                }
                Text(controller.briefingQualityMode.explanation).foregroundStyle(.secondary)
                Stepper("TODO 최대 \(controller.briefingMaxActions)개", value: $controller.briefingMaxActions, in: 3...20)
                Stepper("확인 항목 최대 \(controller.briefingMaxReferences)개", value: $controller.briefingMaxReferences, in: 3...20)
                TextField("내 Slack Member ID (채널 멘션용)", text: $slackMentionUserID)
                Text("Slack DM은 Member ID 없이 수집하며, 채널은 이 ID의 멘션만 수집합니다. 기본 수집 범위는 최근 7일입니다.")
                    .foregroundStyle(.secondary)
            }
            Section("수집 연동") {
                IntegrationStatusRow(symbol: "envelope", title: "Gmail", detail: "두 계정 · 읽기 전용", status: "읽기 전용")
                IntegrationStatusRow(symbol: "bubble.left.and.bubble.right", title: "Slack", detail: "DM 및 내 멘션 · 읽기 전용", status: "읽기 전용")
                IntegrationStatusRow(symbol: "message", title: "메시지", detail: "iMessage · SMS · RCS · 읽기 전용", status: "Full Disk Access 필요")
                IntegrationStatusRow(symbol: "calendar", title: "캘린더", detail: "앞으로 14일 일정 · 읽기 전용", status: controller.calendarAuthorizationStatus) {
                    Button("권한 허용") { controller.requestCalendarReadAccess() }
                        .buttonStyle(.bordered)
                        .disabled(controller.calendarAuthorizationStatus == "읽기 허용됨")
                }
                Text("캘린더 일정은 인박스 정리에 일정 맥락으로 포함됩니다. 이 버전은 어떤 원본도 생성·수정·삭제하지 않습니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("분류 기준 · 직접 확인하고 수정") {
                Text("아래 내용만 개인 맞춤 분류에 사용합니다. 앱 내부에 숨은 중요/무시 발신자 목록을 두지 않습니다.")
                    .foregroundStyle(.secondary)
                TextEditor(text: $controller.briefingUserInstructions)
                    .font(.body.monospaced()).frame(minHeight: 150)
                LabeledContent("항상 중요") {
                    TextEditor(text: $controller.briefingImportantPatternsText)
                        .font(.body.monospaced()).frame(minHeight: 90)
                }
                Text("발신자·도메인·제목·본문에 포함될 문자열을 한 줄에 하나씩 입력합니다. 중요 규칙은 무시 규칙보다 우선합니다.")
                    .foregroundStyle(.secondary)
                LabeledContent("항상 무시") {
                    TextEditor(text: $controller.briefingIgnoredPatternsText)
                        .font(.body.monospaced()).frame(minHeight: 90)
                }
                Text("무시 규칙과 일치한 항목은 본문 요약과 모델 분석에서 제외되고 건수만 기록됩니다.")
                    .foregroundStyle(.secondary)
                HStack {
                    Button("분류 설정 저장", action: controller.saveBriefingPreferences).buttonStyle(.borderedProminent)
                    Button("기본값 복원", action: controller.resetBriefingPreferences)
                    if !controller.briefingPreferencesStatus.isEmpty {
                        Text(controller.briefingPreferencesStatus).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Section("기본 전사 설정") {
                Picker("언어", selection: $controller.transcriptionLanguage) { ForEach(TranscriptionLanguage.allCases) { Text($0.title).tag($0) } }
                Picker("인식 모델", selection: $controller.asrModel) { ForEach(ASRModelChoice.allCases) { Text($0.title).tag($0) } }
                Text(controller.asrModel.explanation).foregroundStyle(.secondary)
                Picker("시간 표시", selection: $controller.transcriptionTimestampMode) { ForEach(TranscriptionTimestampMode.allCases) { Text($0.title).tag($0) } }
            }
            Section("문서 인식") {
                Picker("인식 방식", selection: $controller.documentMode) { ForEach(DocumentRecognitionMode.allCases) { Text($0.title).tag($0) } }
                Text(controller.documentMode.detail).foregroundStyle(.secondary)
            }
            Section("누끼 따기") {
                Picker("누끼 모델", selection: $controller.mattingModel) { ForEach(MattingModelChoice.allCases) { Text($0.title).tag($0) } }
                Text(controller.mattingModel.detail).foregroundStyle(.secondary)
                Text("모델은 마지막 사진 이후 5분이 지나면 스스로 메모리에서 내려가고, 앱을 끄면 함께 종료됩니다.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("화자 구분") {
                Picker("분리 모델", selection: $controller.diarization) { ForEach(DiarizationChoice.allCases) { Text($0.title).tag($0) } }
                Text(controller.diarization.explanation).foregroundStyle(.secondary)
                Text("음성 인식 뒤에 별도 pyannote 모델로 실행됩니다.").foregroundStyle(.secondary)
                SecureField("Hugging Face pyannote 토큰 (hf_…)", text: $diarizationToken)
                HStack {
                    Button("화자 분리 토큰을 Keychain에 저장") {
                        do {
                            try TranscriptionService.saveDiarizationToken(diarizationToken)
                            diarizationToken = ""
                            diarizationTokenStatus = "Keychain에 저장했습니다."
                        } catch {
                            diarizationTokenStatus = error.localizedDescription
                        }
                    }
                    .disabled(diarizationToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if !diarizationTokenStatus.isEmpty {
                        Text(diarizationTokenStatus).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Text("Community-1 또는 Legacy 3.1을 쓰려면 해당 Hugging Face 모델 약관을 승인한 토큰이 필요합니다. 토큰은 저장소가 아닌 macOS Keychain에만 저장됩니다.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            DictationSettingsSection(dictation: controller.dictation)
            Section("전사 AI 정리") {
                Toggle("전사 완료 후 자동으로 AI 정리", isOn: $controller.automaticallyOrganizeTranscripts)
                Picker("기본 정리 유형", selection: $controller.organizationKind) {
                    ForEach(TranscriptOrganizationKind.allCases) { Text($0.title).tag($0) }
                }
                Picker("상세도", selection: $controller.organizationDetailLevel) {
                    ForEach(TranscriptOrganizationDetail.allCases) { Text($0.title).tag($0) }
                }
                Text("브리핑과 같은 로컬 모델을 사용합니다. 긴 전사는 구간별로 정리한 뒤 원문 순서대로 통합합니다.")
                    .font(.caption).foregroundStyle(.secondary)
                DisclosureGroup("수업 정리 프롬프트") {
                    TextEditor(text: $controller.lectureOrganizationPrompt).font(.body.monospaced()).frame(minHeight: 150)
                }
                DisclosureGroup("회의 정리 프롬프트") {
                    TextEditor(text: $controller.meetingOrganizationPrompt).font(.body.monospaced()).frame(minHeight: 150)
                }
                DisclosureGroup("일반 정리 프롬프트") {
                    TextEditor(text: $controller.generalOrganizationPrompt).font(.body.monospaced()).frame(minHeight: 150)
                }
                HStack {
                    Button("AI 정리 설정 저장") { controller.saveOrganizationPreferences() }.buttonStyle(.borderedProminent)
                    Button("기본 프롬프트로 복원") { controller.resetOrganizationPrompts() }
                    if !controller.organizationPreferencesStatus.isEmpty {
                        Text(controller.organizationPreferencesStatus).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }.formStyle(.grouped).padding(24).navigationTitle("설정")
    }
}

private struct IntegrationStatusRow<Trailing: View>: View {
    let symbol: String
    let title: String
    let detail: String
    let status: String
    @ViewBuilder let trailing: () -> Trailing

    init(symbol: String, title: String, detail: String, status: String, @ViewBuilder trailing: @escaping () -> Trailing) {
        self.symbol = symbol
        self.title = title
        self.detail = detail
        self.status = status
        self.trailing = trailing
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .foregroundStyle(Color.snuBlue)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(status == "읽기 허용됨" || status == "읽기 전용" ? .green : .secondary)
                trailing()
            }
        }
    }
}

private extension IntegrationStatusRow where Trailing == EmptyView {
    init(symbol: String, title: String, detail: String, status: String) {
        self.init(symbol: symbol, title: title, detail: detail, status: status) { EmptyView() }
    }
}

private struct TranscriptionWindowView: View {
    @ObservedObject var controller: AutomationController
    var compact = true
    @State private var isDropTarget = false

    var body: some View {
        ScrollView {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Label("녹음 전사", systemImage: "waveform")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(Color.snuBlue)
                Spacer()
                if controller.isTranscribing { ProgressView().controlSize(.small) }
            }
                Text("앱에서 바로 녹음하거나 파일을 드롭해 한국어 전사를 만듭니다. 여러 전사와 AI 자동요약은 대기열에 추가한 순서대로 하나씩 처리됩니다.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if !controller.processingQueue.isEmpty {
                    ProcessingQueueCard(controller: controller)
                }
                MediaImportCard(controller: controller)
        if controller.audioRecorder.isRecording {
            VStack(spacing: 12) {
                HStack(spacing: 8) { Circle().fill(.red).frame(width: 9, height: 9); Text("녹음 중").font(.headline).foregroundStyle(.red) }
                Image(systemName: "waveform").font(.system(size: 34, weight: .medium)).symbolEffect(.variableColor.iterative, options: .repeating).foregroundStyle(.red)
                Text(Self.durationString(controller.audioRecorder.elapsed)).font(.system(size: 38, weight: .semibold, design: .rounded)).monospacedDigit()
            }
            .frame(maxWidth: .infinity).padding(20)
            .background(.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        HStack {
            Button(controller.audioRecorder.isRecording ? "녹음 중지" : "녹음 시작", systemImage: controller.audioRecorder.isRecording ? "stop.circle.fill" : "record.circle") {
                controller.toggleRecording()
            }
            .tint(controller.audioRecorder.isRecording ? .red : .snuBlue)
            .buttonStyle(.borderedProminent)

            if controller.audioRecorder.isRecording {
                Text(Self.durationString(controller.audioRecorder.elapsed)).monospacedDigit().foregroundStyle(.red)
            } else if let recording = controller.mostRecentRecording {
                Text(recording.lastPathComponent).lineLimit(1).foregroundStyle(.secondary)
                    Button("방금 녹음 전사 대기열 추가", systemImage: "text.badge.plus") { controller.transcribe(fileURL: recording) }
            }
        }
        if let error = controller.audioRecorder.errorMessage {
            Text(error).font(.caption).foregroundStyle(.red)
        }
        HStack {
            Text("녹음 보관함").font(.headline)
            Text(controller.recordingLibraryStatus).font(.caption).foregroundStyle(.secondary)
            Spacer()
            Button("Voice Memos 폴더 연결", systemImage: "folder.badge.plus") { controller.chooseVoiceMemosFolder() }
                .buttonStyle(.borderless)
            Button("새로 고침", systemImage: "arrow.clockwise") { controller.refreshRecordings() }
                .buttonStyle(.borderless)
        }
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 10)], spacing: 10) {
                ForEach(controller.recordings) { recording in
                    Button {
                        controller.selectRecording(recording)
                    } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            HStack {
                                Image(systemName: recording.source == .app ? "mic.fill" : "waveform")
                                    .foregroundStyle(recording.source == .app ? Color.snuBlue : .secondary)
                        Text(recording.source.rawValue).font(.caption.weight(.medium)).foregroundStyle(.secondary)
                        if !recording.isLocallyAvailable {
                            Label(controller.downloadingRecordingIDs.contains(recording.id) ? "다운로드 확인 중" : "iCloud 필요", systemImage: "icloud.and.arrow.down")
                                .font(.caption2)
                                .foregroundStyle(.orange)
                        }
                                Spacer()
                                if controller.transcribingRecordingID == recording.id {
                                    ProgressView().controlSize(.small).tint(.snuBlue)
                                }
                                let runCount = controller.transcriptRuns(for: recording).count
                                if runCount > 0 {
                                    Label("\(runCount)", systemImage: "doc.on.doc.fill").font(.caption).foregroundStyle(.green)
                                }
                            }
                            Text(recording.title).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                            HStack(spacing: 5) {
                                Image(systemName: "calendar").imageScale(.small)
                                Text(recording.date.formatted(date: .abbreviated, time: .shortened))
                                Spacer()
                                Image(systemName: "clock").imageScale(.small)
                                Text(Self.durationString(recording.duration))
                            }
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, minHeight: 88, alignment: .leading)
                        .background(controller.selectedRecordingID == recording.id ? Color.snuBlue.opacity(0.16) : Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                    }
                    .buttonStyle(.plain)
                .contextMenu {
                    if !recording.isLocallyAvailable {
                        Button("iCloud 녹음 받기", systemImage: "icloud.and.arrow.down") { controller.requestVoiceMemoDownload(recording) }
                            .disabled(controller.downloadingRecordingIDs.contains(recording.id))
                        Divider()
                    }
                            Button("전사 대기열 추가", systemImage: "text.badge.plus") { controller.transcribe(recording: recording) }
                        .disabled(!recording.isLocallyAvailable)
                        if recording.source == .app {
                            Button("이름 변경…", systemImage: "pencil") { RenameRecordingPanel.present(recording: recording, controller: controller) }
                            Divider()
                            Button("휴지통으로 이동", systemImage: "trash", role: .destructive) { controller.delete(recording) }
                        }
                    }
                }
            }
        }
        .frame(minHeight: 190, maxHeight: 260)
            if let recording = controller.selectedRecording {
                HStack {
                    Text("선택: \(recording.title)").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if !recording.isLocallyAvailable {
                        Button(controller.downloadingRecordingIDs.contains(recording.id) ? "다운로드 확인 중" : "iCloud 녹음 받기", systemImage: "icloud.and.arrow.down") {
                            controller.requestVoiceMemoDownload(recording)
                        }
                        .disabled(controller.downloadingRecordingIDs.contains(recording.id))
                    }
                    Button(controller.isPlayingRecording ? "재생 중지" : "재생", systemImage: controller.isPlayingRecording ? "stop.fill" : "play.fill") { controller.togglePlayback() }
                    .disabled(!recording.isLocallyAvailable)
                    .buttonStyle(.bordered)
                Button("전사 대기열 추가", systemImage: "text.badge.plus") { controller.transcribe(recording: recording) }
                    .buttonStyle(.borderedProminent)
                    .disabled(!recording.isLocallyAvailable)
            }
        }
        if compact {
            Picker("음성 인식", selection: $controller.asrModel) {
                ForEach(ASRModelChoice.allCases) { model in
                    Text(model.title).tag(model)
                }
            }
            .pickerStyle(.segmented)
            .disabled(controller.isTranscribing)

            Text(controller.asrModel.explanation)
                .font(.caption)
                .foregroundStyle(.secondary)

            Picker("화자 구분", selection: $controller.diarization) {
                ForEach(DiarizationChoice.allCases) { choice in
                    Text(choice.title).tag(choice)
                }
            }
            .disabled(controller.isTranscribing)

            Text(controller.diarization.explanation)
                .font(.caption)
                .foregroundStyle(.secondary)
        Picker("시간 표시", selection: $controller.transcriptionTimestampMode) {
            ForEach(TranscriptionTimestampMode.allCases) { mode in
                Text(mode.title).tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .disabled(controller.isTranscribing)
        Picker("언어", selection: $controller.transcriptionLanguage) {
            ForEach(TranscriptionLanguage.allCases) { language in Text(language.title).tag(language) }
        }
        .pickerStyle(.segmented)
        .disabled(controller.isTranscribing)
        }

        if controller.isTranscribing {
            HStack {
                Spacer()
                Button("전사 중단", systemImage: "stop.fill") { controller.stopTranscription() }
                    .buttonStyle(.borderedProminent).tint(.red)
            }
            TranscriptionProgressCard(step: controller.transcriptionStep, detail: controller.transcriptionDetail, timestamps: controller.transcriptionTimestampMode.includesTimestamps, diarizing: controller.diarization.isEnabled, eta: controller.transcriptionETA)
        }
        // Kept visible during a recording too: dropping a file only adds to the
        // queue, which now runs alongside the mic.
        Text("오디오 또는 영상 파일을 드롭하세요\n영상은 오디오만 추출해 전사합니다")
                .font(.headline)
                .frame(maxWidth: .infinity, minHeight: 140)
                .multilineTextAlignment(.center)
                .padding()
                .background(isDropTarget ? Color.snuBlue.opacity(0.16) : Color.secondary.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
                .onDrop(of: [UTType.fileURL], isTargeted: $isDropTarget) { providers in
                    guard let provider = providers.first else { return false }
                    provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                        guard let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                        Task { @MainActor in controller.transcribe(fileURL: url) }
                    }
            return true
        }
            if let error = controller.transcriptionError {
                Text(error).font(.callout).foregroundStyle(.red)
            }
        if controller.selectedTranscript.isEmpty {
                Spacer()
            } else {
                if let transcript = controller.selectedTranscriptRun, let recording = controller.selectedRecording {
                    HStack {
                        Picker("전사 버전", selection: Binding(
                            get: { controller.selectedTranscriptRunID ?? transcript.id },
                            set: { controller.selectTranscript($0) }
                        )) {
                            ForEach(controller.transcriptRuns(for: recording)) { run in
                                Text(Self.transcriptVersionLabel(run)).tag(run.id)
                            }
                        }
                        .frame(maxWidth: 520)
                        Spacer()
                        Text(transcript.settings.displayName).font(.caption).foregroundStyle(.secondary)
                    }
                GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 10) {
                        Label("\(controller.organizationKind.title) · \(controller.organizationDetailLevel.title)", systemImage: "slider.horizontal.3")
                            .font(.caption).foregroundStyle(.secondary)
                        Text("설정에서 변경").font(.caption2).foregroundStyle(.tertiary)
                        Spacer()
                        Button("AI 자동요약 대기열 추가", systemImage: "sparkles") {
                            controller.organizeSelectedTranscript()
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.accentColor)
                        if controller.isOrganizingTranscript { ProgressView().controlSize(.small) }
                        if let eta = controller.organizationETA {
                            Text("약 \(Self.durationString(eta)) 남음").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if controller.isOrganizingTranscript || !controller.organizationDetail.isEmpty {
                        Text(controller.organizationDetail).font(.caption).foregroundStyle(.secondary)
                    }
                    if let error = controller.organizationError { Text(error).font(.caption).foregroundStyle(.red) }
                }
                } label: {
                    Label("AI 정리", systemImage: "sparkles")
                        .font(.headline).foregroundStyle(Color.snuBlue)
                }
                if let selected = controller.selectedOrganizationRun {
                    GroupBox {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                        Picker("정리 버전", selection: Binding(
                                get: { controller.selectedOrganizationRunID ?? selected.id },
                                set: { controller.selectedOrganizationRunID = $0 }
                            )) {
                                ForEach(controller.organizationRuns(for: transcript)) { run in
                                    Text("\(run.kind.title) · \(run.completedAt.formatted(date: .abbreviated, time: .shortened))").tag(run.id)
                                }
                        }.labelsHidden().frame(maxWidth: 320)
                        Spacer()
                        Button("복사", systemImage: "doc.on.doc", action: controller.copySelectedOrganization)
                            .buttonStyle(.bordered)
                        }
                        Text(controller.selectedOrganizationRun?.text ?? "")
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 4)
                    }
                    } label: {
                        Label("AI 정리 결과", systemImage: "text.document.fill").font(.headline)
                    }
                }
            }
            GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                Text("선택한 전사 버전").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("복사", systemImage: "doc.on.doc", action: controller.copyTranscription).buttonStyle(.bordered)
                }
                Text(controller.selectedTranscript)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
            }
            } label: {
                Label("전사 원문", systemImage: "quote.bubble").font(.headline)
            }
        }
        }
        .padding(24)
        }
        .frame(minWidth: 760, minHeight: 560)
    }

    private static func durationString(_ seconds: TimeInterval) -> String {
        String(format: "%02d:%02d", Int(seconds) / 60, Int(seconds) % 60)
    }

    private static func transcriptVersionLabel(_ run: TranscriptRun) -> String {
        if run.isLegacy { return "이전 전사 · 조건 미상" }
        return "\(run.completedAt.formatted(date: .abbreviated, time: .shortened)) · \(run.settings.asrModel?.title ?? "모델 미상") · \(Int(run.duration))초"
    }
}

private enum RenameRecordingPanel {
    @MainActor
    static func present(recording: RecordingItem, controller: AutomationController) {
        let alert = NSAlert()
        alert.messageText = "녹음 이름 변경"
        alert.informativeText = "이 앱에서 만든 녹음 파일의 이름을 변경합니다."
        let field = NSTextField(string: recording.title)
        field.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "변경")
        alert.addButton(withTitle: "취소")
        if alert.runModal() == .alertFirstButtonReturn { controller.rename(recording, to: field.stringValue) }
    }
}

private struct ProcessingQueueCard: View {
    @ObservedObject var controller: AutomationController

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Label("작업 대기열", systemImage: "tray.full.fill")
                    .font(.headline)
                Spacer()
                Text("\(controller.processingQueue.count)개")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.snuBlue)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.snuBlue.opacity(0.12), in: Capsule())
                if !controller.waitingProcessingItems.isEmpty {
                    Button("대기 항목 지우기") { controller.clearWaitingProcessingItems() }
                        .buttonStyle(.plain)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let active = controller.activeProcessingItem {
                ProcessingQueueRow(item: active, status: "처리 중", isActive: true) {
                    controller.cancelProcessingItem(active.id)
                }
            }

            ForEach(Array(controller.waitingProcessingItems.enumerated()), id: \.element.id) { index, item in
                ProcessingQueueRow(item: item, status: "대기 \(index + 1)번", isActive: false) {
                    controller.cancelProcessingItem(item.id)
                }
            }
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.snuBlue.opacity(0.16))
        }
    }
}

private struct ProcessingQueueRow: View {
    let item: ProcessingQueueItem
    let status: String
    let isActive: Bool
    let cancel: () -> Void

    var body: some View {
        HStack(spacing: 11) {
            ZStack {
                Circle().fill(isActive ? Color.snuBlue.opacity(0.16) : Color.secondary.opacity(0.10))
                if isActive {
                    ProgressView().controlSize(.small).tint(.snuBlue)
                } else {
                    Image(systemName: item.kind.symbol).foregroundStyle(.secondary)
                }
            }
            .frame(width: 34, height: 34)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(item.title).font(.callout.weight(.medium)).lineLimit(1)
                    Text(item.kind.title)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(item.kind == .transcription ? Color.snuBlue : Color.purple)
                }
                Text(item.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            Text(status)
                .font(.caption.weight(isActive ? .semibold : .regular))
                .foregroundStyle(isActive ? Color.snuBlue : .secondary)
            Button(action: cancel) {
                Image(systemName: isActive ? "stop.circle.fill" : "xmark.circle.fill")
                    .foregroundStyle(isActive ? Color.red : Color.secondary)
            }
            .buttonStyle(.plain)
            .help(isActive ? "현재 작업 중단" : "대기열에서 제거")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(isActive ? Color.snuBlue.opacity(0.07) : Color.clear, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

private struct TranscriptionProgressCard: View {
    let step: Int
    let detail: String
    let timestamps: Bool
    let diarizing: Bool
    let eta: TimeInterval?
    init(step: Int, detail: String, timestamps: Bool, diarizing: Bool, eta: TimeInterval?) {
        self.step = step
        self.detail = detail
        self.timestamps = timestamps
        self.diarizing = diarizing
        self.eta = eta
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("전사 진행 중", systemImage: "waveform.badge.magnifyingglass").font(.headline).foregroundStyle(Color.snuBlue)
                Spacer()
                Text("\(min(step, 4)) / 4").font(.caption.weight(.medium)).foregroundStyle(.secondary)
            }
            if let eta, step >= 2 {
                Label("약 \(Self.etaString(eta)) 남음", systemImage: "clock").font(.caption.weight(.medium)).foregroundStyle(.secondary)
            } else if step == 1 {
                Text("예상 시간 계산 중").font(.caption).foregroundStyle(.secondary)
            }
            ProgressView(value: Double(step), total: 4).tint(.snuBlue)
            HStack(spacing: 8) {
                ProgressPill(title: "준비", isActive: step == 1, isDone: step > 1)
                ProgressPill(title: timestamps ? "음성·시간" : "음성 인식", isActive: step == 2, isDone: step > 2)
                ProgressPill(title: diarizing ? "화자 분리" : "화자 건너뜀", isActive: step == 3, isDone: step > 3)
                ProgressPill(title: "결과", isActive: step == 4, isDone: false)
            }
            Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
        }
        .padding(16)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Color.snuBlue.opacity(0.15)))
    }

    private static func etaString(_ seconds: TimeInterval) -> String {
        let rounded = max(0, Int(seconds.rounded()))
        return rounded >= 60 ? "\(rounded / 60)분 \(rounded % 60)초" : "\(rounded)초"
    }
}

private struct ProgressPill: View {
    let title: String
    let isActive: Bool
    let isDone: Bool
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: isDone ? "checkmark" : (isActive ? "circle.inset.filled" : "circle")).imageScale(.small)
            Text(title).lineLimit(1)
        }
        .font(.caption2.weight(isActive ? .semibold : .regular))
        .foregroundStyle(isDone ? .green : (isActive ? Color.snuBlue : .secondary))
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        .background(isActive ? Color.snuBlue.opacity(0.12) : .clear, in: Capsule())
    }
}

private struct ProgressStep: View {
    let title: String
    let isCurrent: Bool
    let isDone: Bool

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: isDone ? "checkmark.circle.fill" : (isCurrent ? "circle.inset.filled" : "circle"))
                .foregroundStyle(isDone ? Color.green : (isCurrent ? Color.snuBlue : Color.secondary))
            Text(title).font(.caption).foregroundStyle(isCurrent ? .primary : .secondary)
        }
    }
}

private struct MediaImportCard: View {
    @ObservedObject var controller: AutomationController

    private var toolsMissing: Bool { MediaImporter.ytDLPPath == nil || MediaImporter.ffmpegPath == nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("영상에서 가져오기", systemImage: "play.rectangle.on.rectangle")
                .font(.headline)
            Text("강의 영상 주소를 붙여넣으면 오디오만 이 Mac으로 내려받아 전사 대기열에 넣습니다. 영상 파일을 드롭해도 같습니다.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                TextField("https://…", text: $controller.mediaURLText)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { controller.importMediaFromURL() }
                    .disabled(controller.isImportingMedia || toolsMissing)
                if controller.isImportingMedia {
                    Button("중단", systemImage: "stop.fill") { controller.stopMediaImport() }
                        .buttonStyle(.bordered)
                        .tint(.red)
                } else {
                    Button("가져오기", systemImage: "arrow.down.circle") { controller.importMediaFromURL() }
                        .buttonStyle(.borderedProminent)
                        .tint(.snuBlue)
                        .disabled(toolsMissing || controller.mediaURLText.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            if controller.isImportingMedia || !controller.mediaImportStatus.isEmpty {
                HStack(spacing: 8) {
                    if controller.isImportingMedia { ProgressView().controlSize(.small) }
                    Text(controller.mediaImportStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if let error = controller.mediaImportError {
                Text(error).font(.caption).foregroundStyle(.red).lineLimit(3)
            }
            if toolsMissing {
                Text("yt-dlp와 ffmpeg가 필요합니다 · 터미널에서 `brew install yt-dlp ffmpeg`")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

private struct DocumentRecognitionView: View {
    @ObservedObject var controller: AutomationController
    @State private var isDropTarget = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Label("문서 인식", systemImage: "text.viewfinder")
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(Color.snuBlue)
                    Spacer()
                    if controller.isRecognizingDocument { ProgressView().controlSize(.small) }
                }
                Text("강의 슬라이드 사진, 스캔한 유인물 PDF, 화면의 일부를 텍스트로 바꿉니다. 어느 쪽을 고르든 이미지가 이 Mac을 벗어나지 않습니다.")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 6) {
                    Picker("인식 방식", selection: $controller.documentMode) {
                        ForEach(DocumentRecognitionMode.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 360)
                    .disabled(controller.isRecognizingDocument)
                    Text(controller.documentMode.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 10) {
                    Button("화면 영역 캡처", systemImage: "camera.viewfinder") { controller.captureScreenAndRecognize() }
                        .buttonStyle(.borderedProminent)
                        .tint(.snuBlue)
                        .disabled(controller.isRecognizingDocument)
                    Button("파일 선택…", systemImage: "doc.badge.plus") { chooseFile() }
                        .buttonStyle(.bordered)
                        .disabled(controller.isRecognizingDocument)
                    if controller.isRecognizingDocument {
                        Button("중단", systemImage: "stop.fill") { controller.stopDocumentRecognition() }
                            .buttonStyle(.bordered)
                            .tint(.red)
                    }
                    Spacer()
                }

                Text("여기로 이미지 또는 PDF를 드롭하세요")
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 120)
                    .multilineTextAlignment(.center)
                    .padding()
                    .background(
                        isDropTarget ? Color.snuBlue.opacity(0.16) : Color.secondary.opacity(0.10),
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                    )
                    .onDrop(of: [UTType.fileURL], isTargeted: $isDropTarget) { providers in
                        guard let provider = providers.first else { return false }
                        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                            guard let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                            Task { @MainActor in controller.recognizeDocument(fileURL: url) }
                        }
                        return true
                    }

                HStack(spacing: 8) {
                    if !controller.recognizedSourceName.isEmpty {
                        Text(controller.recognizedSourceName).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Text(controller.recognitionStatus).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                }
                if let error = controller.recognitionError {
                    Text(error).font(.callout).foregroundStyle(.red)
                }

                if !controller.recognizedText.isEmpty {
                    GroupBox {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack(spacing: 10) {
                                Button("AI로 정리 대기열 추가", systemImage: "sparkles") { controller.organizeRecognizedText() }
                                    .buttonStyle(.borderedProminent)
                                    .tint(.accentColor)
                                    .disabled(controller.isOrganizingTranscript)
                                Button("복사", systemImage: "doc.on.doc", action: controller.copyRecognizedText)
                                    .buttonStyle(.bordered)
                                Button("텍스트로 저장…", systemImage: "square.and.arrow.down", action: controller.saveRecognizedText)
                                    .buttonStyle(.bordered)
                                Spacer()
                                if controller.isOrganizingTranscript { ProgressView().controlSize(.small) }
                            }
                            if controller.isOrganizingTranscript || !controller.organizationDetail.isEmpty {
                                Text(controller.organizationDetail).font(.caption).foregroundStyle(.secondary)
                            }
                            Text(controller.recognizedText)
                                .font(controller.recognizedTextIsMarkdown ? .body.monospaced() : .body)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 4)
                        }
                    } label: {
                        Label(
                            controller.recognizedTextIsMarkdown ? "인식한 Markdown (수식은 LaTeX)" : "인식한 텍스트",
                            systemImage: controller.recognizedTextIsMarkdown ? "function" : "doc.plaintext"
                        ).font(.headline)
                    }
                }

                if !controller.recognizedNoteText.isEmpty {
                    GroupBox {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Spacer()
                                Button("복사", systemImage: "doc.on.doc", action: controller.copyRecognizedNote)
                                    .buttonStyle(.bordered)
                            }
                            Text(controller.recognizedNoteText)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 4)
                        }
                    } label: {
                        Label("AI 정리 결과", systemImage: "sparkles").font(.headline).foregroundStyle(Color.snuBlue)
                    }
                }
            }
            .padding(32)
        }
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.title = "인식할 이미지 또는 PDF 선택"
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.pdf, .image]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        controller.recognizeDocument(fileURL: url)
    }
}

// MARK: - 누끼 따기

/// Deliberately built from the same pieces as `DocumentRecognitionView`: the
/// `snuBlue` title label, one prominent action, a highlighted drop well and a
/// caption-sized status line. Only the preview grid and the background picker
/// are new.
private struct CutoutView: View {
    @ObservedObject var controller: AutomationController
    @State private var isDropTarget = false

    private let columns = [GridItem(.adaptive(minimum: 220), spacing: 16)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Label("누끼 따기", systemImage: "person.and.background.dotted")
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(Color.snuBlue)
                    Spacer()
                    if controller.isRemovingBackground { ProgressView().controlSize(.small) }
                }
                Text("사진을 드롭하면 배경을 지운 투명 PNG를 만듭니다. 모델은 이 Mac에서만 실행되고 사진은 기기를 벗어나지 않습니다.")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                HStack(spacing: 10) {
                    Button("사진 선택…", systemImage: "photo.badge.plus") { choosePhotos() }
                        .buttonStyle(.borderedProminent)
                        .tint(.snuBlue)
                        .disabled(controller.isRemovingBackground)
                    if controller.isRemovingBackground {
                        Button("중단", systemImage: "stop.fill") { controller.stopBackgroundRemoval() }
                            .buttonStyle(.bordered)
                            .tint(.red)
                    }
                    if controller.cutoutItems.contains(where: \.isFinished) {
                        Button("모두 저장…", systemImage: "square.and.arrow.down.on.square") { controller.saveAllCutouts() }
                            .buttonStyle(.bordered)
                    }
                    Spacer()
                }

                Text("여기로 사진을 드롭하세요 · 여러 장도 됩니다")
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 120)
                    .multilineTextAlignment(.center)
                    .padding()
                    .background(
                        isDropTarget ? Color.snuBlue.opacity(0.16) : Color.secondary.opacity(0.10),
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                    )
                    .onDrop(of: [UTType.fileURL], isTargeted: $isDropTarget) { providers in
                        load(providers)
                        return true
                    }

                backgroundPicker

                HStack(spacing: 8) {
                    Text(controller.cutoutStatus).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Text(controller.mattingModel.title).font(.caption).foregroundStyle(.secondary)
                }
                if let error = controller.cutoutError {
                    Text(error).font(.callout).foregroundStyle(.red)
                }

                if !controller.cutoutItems.isEmpty {
                    LazyVGrid(columns: columns, spacing: 16) {
                        ForEach(controller.cutoutItems) { item in
                            CutoutCard(controller: controller, item: item)
                        }
                    }
                }
            }
            .padding(32)
        }
    }

    private var backgroundPicker: some View {
        HStack(spacing: 12) {
            Picker("배경", selection: $controller.cutoutBackground) {
                ForEach(CutoutBackground.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 360)
            if controller.cutoutBackground == .custom {
                ColorPicker("배경색", selection: $controller.cutoutCustomColor, supportsOpacity: false)
                    .labelsHidden()
            }
            Spacer()
        }
    }

    private func choosePhotos() {
        let panel = NSOpenPanel()
        panel.title = "누끼를 딸 사진 선택"
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.image]
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        controller.removeBackground(fileURLs: panel.urls)
    }

    /// Every provider is collected before starting, so a multi-photo drop runs
    /// as one batch through the warm model instead of several rejected calls.
    private func load(_ providers: [NSItemProvider]) {
        let group = DispatchGroup()
        let collected = DroppedURLs()
        for provider in providers {
            group.enter()
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                defer { group.leave() }
                guard let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                collected.append(url)
            }
        }
        group.notify(queue: .main) {
            let urls = collected.all
            guard !urls.isEmpty else { return }
            Task { @MainActor in controller.removeBackground(fileURLs: urls) }
        }
    }
}

/// Each provider reports back on its own queue, so the collected list needs a
/// lock rather than a plain captured array.
private final class DroppedURLs: @unchecked Sendable {
    private let lock = NSLock()
    private var urls: [URL] = []

    func append(_ url: URL) {
        lock.lock()
        urls.append(url)
        lock.unlock()
    }

    var all: [URL] {
        lock.lock()
        defer { lock.unlock() }
        return urls
    }
}

private struct CutoutCard: View {
    @ObservedObject var controller: AutomationController
    let item: CutoutItem
    @State private var preview: CGImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                CheckerboardBackground()
                if let image = preview {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .scaledToFit()
                        .padding(6)
                } else if case .failed = item.state {
                    Image(systemName: "exclamationmark.triangle").font(.title).foregroundStyle(.red)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .frame(height: 170)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

            Text(item.source.lastPathComponent).font(.caption).lineLimit(1).truncationMode(.middle)
            Text(item.statusText)
                .font(.caption2)
                .foregroundStyle(isFailed ? Color.red : .secondary)
                .lineLimit(2)
            if item.isFinished {
                HStack(spacing: 8) {
                    Button("복사", systemImage: "doc.on.doc") { controller.copyCutout(item) }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    Button("저장…", systemImage: "square.and.arrow.down") { controller.saveCutout(item) }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            }
        }
        .padding(10)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .task(id: previewKey) { await loadPreview() }
    }

    private var isFailed: Bool { if case .failed = item.state { true } else { false } }

    /// Rebuilt only when the cutout or the chosen background actually changes,
    /// and always off the main thread: a phone photo is big enough that doing
    /// this per redraw would stutter the whole tab.
    private var previewKey: String {
        let colour = controller.cutoutBackground == .custom
            ? AutomationController.hex(from: controller.cutoutCustomColor)
            : ""
        return "\(item.output?.path ?? "")|\(controller.cutoutBackground.rawValue)|\(colour)"
    }

    private func loadPreview() async {
        guard let output = item.output else {
            preview = nil
            return
        }
        let choice = controller.cutoutBackground
        let custom = controller.cutoutCustomColorComponents
        preview = await Task.detached(priority: .userInitiated) {
            CutoutComposer.preview(of: output, maxPixel: 640, background: choice.color(custom: custom))
        }.value
    }
}

/// The usual light/dark grey squares, so transparent regions read as
/// transparent rather than as white.
private struct CheckerboardBackground: View {
    var body: some View {
        Canvas { context, size in
            let square = 10.0
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.white.opacity(0.9)))
            for row in 0 ... Int(size.height / square) {
                for column in 0 ... Int(size.width / square) where (row + column).isMultiple(of: 2) {
                    let rect = CGRect(x: Double(column) * square, y: Double(row) * square, width: square, height: square)
                    context.fill(Path(rect), with: .color(.gray.opacity(0.30)))
                }
            }
        }
    }
}

private struct DictationSettingsSection: View {
    @ObservedObject var dictation: DictationController

    var body: some View {
        Section("전역 받아쓰기") {
            Picker("단축키", selection: $dictation.shortcut) {
                ForEach(DictationShortcut.allCases) { Text($0.title).tag($0) }
            }
            Text(dictation.status)
                .font(.caption)
                .foregroundStyle(dictation.shortcutRegistered || dictation.shortcut == .disabled ? Color.secondary : Color.red)
            Picker("인식 모델", selection: $dictation.asrModel) {
                ForEach(ASRModelChoice.allCases) { Text($0.title).tag($0) }
            }
            Text("받아쓰기는 짧은 문장을 즉시 처리해야 하므로 가장 빠른 모델을 권장합니다.")
                .font(.caption).foregroundStyle(.secondary)
            Picker("언어", selection: $dictation.language) {
                ForEach(TranscriptionLanguage.allCases) { Text($0.title).tag($0) }
            }
            Toggle("변환 후 커서 위치에 자동으로 붙여넣기", isOn: $dictation.pastesAutomatically)
            if dictation.pastesAutomatically && !dictation.accessibilityGranted {
                HStack {
                    Text("자동 붙여넣기에는 손쉬운 사용 권한이 필요합니다. 허용 후 앱을 다시 실행해 주세요.")
                        .font(.caption).foregroundStyle(.orange)
                    Button("설정 열기") { dictation.openAccessibilitySettings() }
                        .buttonStyle(.bordered)
                }
            }
            Text("단축키를 한 번 누르면 녹음, 다시 누르면 변환합니다. 결과는 항상 클립보드에 복사되며 녹음 파일은 변환 직후 삭제됩니다.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

extension Color {
    static let snuBlue = Color(red: 0.05, green: 0.24, blue: 0.54)
}
