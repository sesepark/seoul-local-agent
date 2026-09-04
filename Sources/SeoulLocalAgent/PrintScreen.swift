import SwiftUI
import AppKit
import Combine

// MARK: - 모델

/// 프린트 탭이 들고 있는 상태 전부.
///
/// 서버가 진실의 원본이다. 프린터가 대기 중인지, 어떤 용지를 물릴 수 있는지, 큐에 무엇이
/// 남아 있는지는 전부 방금 `lpstat`이 말해 준 것이고, 이 타입은 그것을 되비춘다. 로봇
/// 화면과 같은 규칙이다.
@MainActor
final class PrintModel: ObservableObject {
    struct Document: Identifiable, Sendable {
        enum State: Equatable, Sendable {
            case preparing
            case ready
            case sending(Double)
            case sent(String)
            case failed(String)
        }

        let id = UUID()
        let source: URL
        var state: State = .preparing
        var pageCount = 0
        var bytes = 0
        var note = ""
        var pdf: URL?
        var isTemporary = false

        var isReady: Bool { state == .ready }
        var isSent: Bool { if case .sent = state { true } else { false } }

        var statusText: String {
            switch state {
            case .preparing: "준비 중…"
            case .ready: note
            case .sending(let fraction): fraction > 0 ? "보내는 중 \(Int(fraction * 100))%" : "보내는 중"
            case .sent(let job): "큐에 넣었습니다 · \(job)"
            case .failed(let message): message
            }
        }
    }

    enum Status: Equatable {
        case idle
        case checking
        case ready
        case failed(String)
    }

    @Published private(set) var documents: [Document] = []
    @Published private(set) var printers: [RemotePrinter] = []
    @Published private(set) var capabilities = PrinterCapabilities()
    @Published private(set) var queue: [PrintQueueEntry] = []
    @Published private(set) var status: Status = .idle
    @Published private(set) var isSending = false
    /// 마지막으로 실제로 대답한 주소. 집 안인지 밖인지를 화면이 말할 수 있게 한다.
    @Published private(set) var lastHost = ""
    @Published private(set) var lastCheckedAt: Date?
    /// 서버에 ghostscript가 있는가. 없으면 흑백 스위치를 걸지 않는다 — 이 프린터의 PPD에는
    /// 컬러 항목이 없어서, 흑백은 문서 자체를 바꾸는 방법으로만 가능하다.
    @Published private(set) var grayscaleAvailable = false
    @Published var errorMessage: String?

    @Published var selectedPrinter: String {
        didSet {
            guard selectedPrinter != oldValue else { return }
            UserDefaults.standard.set(selectedPrinter, forKey: Self.printerKey)
            // 서버의 대답을 받아 적는 중에 고른 값이 바뀐 것이라면 다시 물어볼 것이 없다.
            // 그 왕복은 집 밖에서 그대로 데이터 요금이 된다.
            guard !isApplying else { return }
            Task { await refresh() }
        }
    }

    @Published var options: PrintOptions {
        didSet {
            guard options != oldValue else { return }
            saveOptions()
            // 용지를 바꾸면 이미 만들어 둔 쪽의 크기가 어긋난다. 사진과 글은 고른 종이에
            // 맞춰 앉힌 것이므로, 종이가 바뀌면 다시 앉혀야 화면이 말한 대로 나온다.
            guard !isApplying, options.paper != oldValue.paper else { return }
            reprepareConvertedDocuments()
        }
    }

    /// 서버의 대답을 받아 적는 동안 참. 그때의 값 변경은 사람이 고른 것이 아니다.
    private var isApplying = false

    private static let printerKey = "printSelectedPrinter"
    private static let optionsKey = "printOptions"

    private let store: SOArmServerStore
    private var server: SOArmServer
    private var refreshTask: Task<Void, Never>?
    private var sendTask: Task<Void, Never>?
    private var prepareTask: Task<Void, Never>?
    /// `applicationWillTerminate`에서 닿기 위한 참조. 만들어 둔 임시 PDF를 치운다.
    private(set) static weak var current: PrintModel?

    init(store: SOArmServerStore = SOArmServerStore()) {
        self.store = store
        server = store.load()
        selectedPrinter = UserDefaults.standard.string(forKey: Self.printerKey) ?? ""
        if let data = UserDefaults.standard.data(forKey: Self.optionsKey),
           let saved = try? JSONDecoder().decode(PrintOptions.self, from: data) {
            options = saved
        } else {
            options = PrintOptions()
        }
        Self.current = self
    }

    private func saveOptions() {
        guard let data = try? JSONEncoder().encode(options) else { return }
        UserDefaults.standard.set(data, forKey: Self.optionsKey)
    }

    // MARK: 서버

    var isConfigured: Bool { server.sanitised().isConfigured }

    /// 지금 어느 길로 붙어 있는가. 이 맥은 집에도 있고 밖에도 있으므로, 붙었다는 사실만으로는
    /// 부족하다 — 밖에서 붙어 있다면 지금 보내는 것이 모바일 데이터일 수 있다.
    var routeText: String {
        guard !lastHost.isEmpty else { return "" }
        let server = server.sanitised()
        if lastHost == server.host { return "집 주소 · \(lastHost)" }
        if lastHost == server.alternateHost { return "집 밖에서 쓰는 주소 · \(lastHost)" }
        return lastHost
    }

    var isOutsideHome: Bool {
        let server = server.sanitised()
        return !lastHost.isEmpty && lastHost == server.alternateHost && lastHost != server.host
    }

    var printer: RemotePrinter? {
        printers.first { $0.name == selectedPrinter } ?? printers.first { $0.isDefault } ?? printers.first
    }

    private var link: PrinterLink { PrinterLink(server: server) }

    /// 화면이 열릴 때와 새로고침 버튼에서만 부른다. 저절로 도는 폴링은 두지 않는다 —
    /// 밖에서 쓸 때 배경에서 계속 서버를 두드리는 것은 데이터를 쓰는 일이다.
    func refresh() async {
        refreshTask?.cancel()
        server = store.load()
        guard isConfigured else {
            status = .failed("집 서버 주소가 설정되어 있지 않습니다.")
            return
        }
        status = .checking
        let target = selectedPrinter
        let link = link
        let task = Task { [weak self] in
            do {
                let reply = try await link.run(PrintCommand.inspect(printer: target), timeout: 25)
                guard !Task.isCancelled else { return }
                self?.apply(reply)
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                self?.failed(error)
            }
        }
        refreshTask = task
        await task.value
    }

    private func apply(_ reply: PrinterLink.Reply) {
        isApplying = true
        defer { isApplying = false }
        lastHost = reply.host
        lastCheckedAt = Date()
        let sections = Self.split(reply.output)
        printers = CUPSOutput.printers(sections["PRINTERS"] ?? "")
        capabilities = CUPSOutput.capabilities(sections["OPTIONS"] ?? "")
        queue = CUPSOutput.queue(sections["QUEUE"] ?? "")
        grayscaleAvailable = !(sections["GS"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if selectedPrinter.isEmpty || !printers.contains(where: { $0.name == selectedPrinter }) {
            selectedPrinter = printer?.name ?? ""
        }
        // 프린터가 물릴 수 없는 용지가 설정에 남아 있으면 조용히 실패한다. 지금 고를 수 있는
        // 것으로 되돌린다.
        if !capabilities.pageSizes.contains(options.paper) {
            options.paper = capabilities.defaultPageSize
        }
        if !capabilities.supportsDuplex, options.sides != .oneSided {
            options.sides = .oneSided
        }
        if !grayscaleAvailable, options.grayscale {
            options.grayscale = false
        }
        status = printers.isEmpty ? .failed(PrintError.noPrinter.localizedDescription) : .ready
    }

    private func failed(_ error: Error) {
        status = .failed(error.localizedDescription)
    }

    private static func split(_ output: String) -> [String: String] {
        var sections: [String: String] = [:]
        var key = ""
        var lines: [String] = []
        for line in output.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("@@"), line.hasSuffix("@@") {
                if !key.isEmpty { sections[key] = lines.joined(separator: "\n") }
                key = String(line.dropFirst(2).dropLast(2))
                lines = []
            } else {
                lines.append(String(line))
            }
        }
        if !key.isEmpty { sections[key] = lines.joined(separator: "\n") }
        return sections
    }

    // MARK: 문서

    func add(_ urls: [URL]) {
        let (files, truncated) = ToolWorkspace.expand(urls, accepting: PrintPreparation.acceptedExtensions)
        guard !files.isEmpty else {
            errorMessage = "보낼 수 있는 파일이 없습니다. \(PrintPreparation.dropHint)"
            return
        }
        if truncated { errorMessage = "한 번에 500개까지만 받습니다. 나머지는 다시 넣어 주세요." }
        let added = files.map { Document(source: $0) }
        documents.append(contentsOf: added)
        prepare(added.map(\.id))
    }

    private func prepare(_ ids: [UUID]) {
        let paper = options.paper
        prepareTask = Task { [weak self] in
            guard let model = self else { return }
            for id in ids {
                guard !Task.isCancelled else { return }
                guard let source = model.source(of: id) else { continue }
                do {
                    let prepared = try await PrintPreparation.prepare(source, paper: paper)
                    model.finishPreparing(id, with: prepared)
                } catch {
                    model.failPreparing(id, message: error.localizedDescription)
                }
            }
        }
    }

    /// 용지가 바뀌었다. 우리가 만든 PDF만 다시 만든다 — 원본 PDF는 손댈 것이 없다.
    private func reprepareConvertedDocuments() {
        let ids = documents.filter(\.isTemporary).map(\.id)
        guard !ids.isEmpty else { return }
        for id in ids {
            guard let index = documents.firstIndex(where: { $0.id == id }) else { continue }
            if let pdf = documents[index].pdf { try? FileManager.default.removeItem(at: pdf) }
            documents[index].pdf = nil
            documents[index].state = .preparing
        }
        prepare(ids)
    }

    private func source(of id: UUID) -> URL? {
        documents.first { $0.id == id }?.source
    }

    private func finishPreparing(_ id: UUID, with prepared: PreparedPrintDocument) {
        guard let index = documents.firstIndex(where: { $0.id == id }) else { return }
        documents[index].pdf = prepared.pdf
        documents[index].pageCount = prepared.pageCount
        documents[index].bytes = prepared.bytes
        documents[index].note = prepared.note
        documents[index].isTemporary = prepared.isTemporary
        documents[index].state = .ready
    }

    private func failPreparing(_ id: UUID, message: String) {
        guard let index = documents.firstIndex(where: { $0.id == id }) else { return }
        documents[index].state = .failed(message)
    }

    func remove(_ document: Document) {
        if document.isTemporary, let pdf = document.pdf { try? FileManager.default.removeItem(at: pdf) }
        documents.removeAll { $0.id == document.id }
    }

    func clear() {
        for document in documents where document.isTemporary {
            if let pdf = document.pdf { try? FileManager.default.removeItem(at: pdf) }
        }
        documents.removeAll()
    }

    /// 앱이 끝날 때. 만들어 둔 임시 PDF를 남기지 않는다.
    nonisolated static func cleanUpOnQuit() {
        guard let directory = try? ToolWorkspace.directory("Print") else { return }
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: 보내기

    var readyDocuments: [Document] { documents.filter(\.isReady) }

    var totalPages: Int { readyDocuments.reduce(0) { $0 + $1.pageCount } }

    var totalBytes: Int { readyDocuments.reduce(0) { $0 + $1.bytes } }

    var totalSheets: Int { readyDocuments.reduce(0) { $0 + options.sheets(forPages: $1.pageCount) } }

    var canPrint: Bool {
        !isSending && !readyDocuments.isEmpty && status == .ready
            && PrintOptions.isValidRange(options.pageRange)
    }

    func printAll() {
        guard canPrint else { return }
        let documents = readyDocuments
        let options = options
        let printerName = selectedPrinter
        let grayscale = grayscaleAvailable
        let link = link
        isSending = true
        sendTask = Task { [weak self] in
            guard let model = self else { return }
            for document in documents {
                guard !Task.isCancelled else { break }
                let id = document.id
                model.mark(id, .sending(0))
                do {
                    guard let pdf = document.pdf else { throw AgentError.processFailed("보낼 PDF가 없습니다.") }
                    let command = PrintCommand.send(
                        options: options, printer: printerName,
                        title: PrintCommand.title(for: document.source.lastPathComponent),
                        grayscaleAvailable: grayscale
                    )
                    let reply = try await link.run(command, sending: pdf, timeout: 300) { [weak model] fraction in
                        Task { @MainActor in model?.mark(id, .sending(fraction)) }
                    }
                    let job = CUPSOutput.jobID(reply.output) ?? "접수됨"
                    model.mark(id, .sent(job), host: reply.host)
                } catch is CancellationError {
                    model.mark(id, .failed("중단했습니다."))
                } catch {
                    model.mark(id, .failed(error.localizedDescription))
                }
            }
            await model.finishSending()
        }
    }

    func stop() {
        sendTask?.cancel()
    }

    private func mark(_ id: UUID, _ state: Document.State, host: String = "") {
        guard let index = documents.firstIndex(where: { $0.id == id }) else { return }
        documents[index].state = state
        if !host.isEmpty { lastHost = host }
    }

    private func finishSending() async {
        isSending = false
        await refresh()
    }

    func cancel(_ entry: PrintQueueEntry) {
        let link = link
        Task { [weak self] in
            do {
                _ = try await link.run(PrintCommand.cancel(entry.id), timeout: 20)
            } catch {
                await MainActor.run { self?.errorMessage = error.localizedDescription }
            }
            await self?.refresh()
        }
    }

    /// 종이 한 장으로 길이 열려 있는지 확인한다. 버튼 한 번이 곧 실행이다.
    func printTestPage() {
        guard !isSending else { return }
        let options = options
        let printerName = selectedPrinter
        let grayscale = grayscaleAvailable
        let link = link
        isSending = true
        sendTask = Task { [weak self] in
            do {
                let page = try PrintPreparation.testPage(paper: options.paper)
                var single = PrintOptions()
                single.paper = options.paper
                let command = PrintCommand.send(
                    options: single, printer: printerName, title: "테스트 페이지",
                    grayscaleAvailable: grayscale
                )
                let reply = try await link.run(command, sending: page, timeout: 120)
                try? FileManager.default.removeItem(at: page)
                await MainActor.run {
                    self?.lastHost = reply.host
                    self?.errorMessage = "테스트 페이지를 큐에 넣었습니다 · \(CUPSOutput.jobID(reply.output) ?? "접수됨")"
                }
            } catch {
                await MainActor.run { self?.errorMessage = error.localizedDescription }
            }
            await self?.finishSending()
        }
    }

    // MARK: 개요 타일

    var overviewValue: String {
        switch status {
        case .idle: "확인 전"
        case .checking: "확인 중…"
        case .ready: printer?.state.title ?? "대기 중"
        case .failed: "닿지 않음"
        }
    }

    var overviewDetail: String {
        switch status {
        case .idle: return "열면 서버에 한 번 물어봅니다"
        case .checking: return routeText.isEmpty ? "집 서버를 부르는 중" : routeText
        case .ready:
            let name = printer?.displayName ?? "프린터"
            let waiting = queue.isEmpty ? "" : " · 큐 \(queue.count)건"
            return "\(name)\(waiting)"
        case .failed(let message): return message
        }
    }
}

// MARK: - 다른 화면에서 넘기기

/// 결과 하나를 프린터로 넘기는 길.
///
/// 환경 값인 이유: 결과 카드(`ToolResultCard`)는 자기 도구의 모델만 알고 컨트롤러를 모른다.
/// 프린트 하나 때문에 다섯 도구의 뷰에 컨트롤러를 끌어들이면, 그 다섯 자리가 모두 프린트를
/// 아는 코드가 된다. 환경으로 내려 주면 아는 곳은 창의 뿌리 한 군데뿐이다.
private struct SendToPrinterKey: EnvironmentKey {
    static let defaultValue: @MainActor @Sendable ([URL]) -> Void = { _ in }
}

extension EnvironmentValues {
    var sendToPrinter: @MainActor @Sendable ([URL]) -> Void {
        get { self[SendToPrinterKey.self] }
        set { self[SendToPrinterKey.self] = newValue }
    }
}

// MARK: - 화면

struct PrintView: View {
    @ObservedObject var controller: AutomationController
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        PrintWorkspace(model: controller.printing, openSettings: { openSettings() }) { directory in
            controller.chooseFilesToPrint(startingAt: directory)
        }
    }
}

private struct PrintWorkspace: View {
    @ObservedObject var model: PrintModel
    let openSettings: () -> Void
    let choose: (URL?) -> Void

    var body: some View {
        WorkspaceScreen(title: AppSection.print.title, subtitle: AppSection.print.subtitle) {
            ToolDropWell(
                symbol: "printer",
                hint: PrintPreparation.dropHint,
                busyHint: "보내는 중입니다 · 끝나거나 중단한 뒤에 넣어 주세요",
                isBusy: model.isSending,
                onURLs: { model.add($0) }
            )
            QuickFolderBar(disabled: model.isSending, choose: choose)
            PrinterStatusPanel(model: model, openSettings: openSettings)
            if model.status == .ready { PrintOptionsPanel(model: model) }
            PrintDocumentList(model: model)
            PrintQueuePanel(model: model)
        }
        .task { if model.status == .idle { await model.refresh() } }
        .alert("프린트", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("확인") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
        .toolbar {
            ToolbarItem {
                Button("새로고침", systemImage: "arrow.clockwise") { Task { await model.refresh() } }
                    .disabled(model.status == .checking)
                    .help("프린터 상태와 큐를 서버에 다시 물어봅니다")
            }
            ToolbarItem {
                Menu("목록", systemImage: "ellipsis") {
                    Button("목록 비우기", systemImage: "trash", role: .destructive) { model.clear() }
                        .disabled(model.documents.isEmpty || model.isSending)
                }
                .help("보낼 목록을 정리합니다")
            }
            ToolbarSpacer(.flexible)
            ToolbarItem {
                Button("파일 선택…", systemImage: "folder") { choose(nil) }
                    .disabled(model.isSending)
                    .help("인쇄할 파일이나 폴더를 고릅니다")
            }
            ToolbarItem {
                if model.isSending {
                    Button("중단", systemImage: "stop.fill") { model.stop() }
                        .tint(.red)
                        .toolbarKeepsTitle()
                        .help("남은 문서 보내기를 중단합니다")
                } else {
                    Button("인쇄", systemImage: "printer.fill") { model.printAll() }
                        .buttonStyle(.glassProminent)
                        .tint(.snuBlue)
                        .disabled(!model.canPrint)
                        .toolbarKeepsTitle()
                        .help("목록의 문서를 집 서버의 프린터로 보냅니다")
                }
            }
        }
        .animation(.appContent, value: model.documents.map(\.id))
        .animation(.appControl, value: model.status)
    }
}

/// 프린터가 지금 어떤 상태이고, 어느 길로 닿았는가.
private struct PrinterStatusPanel: View {
    @ObservedObject var model: PrintModel
    let openSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.m) {
                Image(systemName: symbol)
                    .font(.title2)
                    .foregroundStyle(tint)
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text(headline).font(.headline)
                    if !detail.isEmpty {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer()
                if model.status == .checking { ProgressView().controlSize(.small) }
                if !model.isConfigured {
                    Button("설정 열기") { openSettings() }
                        .buttonStyle(.glass)
                }
            }
            if model.printers.count > 1 {
                Picker("프린터", selection: $model.selectedPrinter) {
                    ForEach(model.printers) { printer in
                        Text(printer.displayName).tag(printer.name)
                    }
                }
                .frame(maxWidth: 320)
            }
            if !model.routeText.isEmpty {
                Label(model.routeText, systemImage: model.isOutsideHome ? "antenna.radiowaves.left.and.right" : "house")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Spacing.l)
        .glassPanel()
    }

    private var symbol: String {
        switch model.status {
        case .ready: model.printer?.state.symbol ?? "printer"
        case .failed: "exclamationmark.triangle.fill"
        default: "printer"
        }
    }

    private var tint: Color {
        switch model.status {
        case .failed: .orange
        case .ready: model.printer?.state == .stopped ? .orange : .snuBlueLabel
        default: .secondary
        }
    }

    private var headline: String {
        switch model.status {
        case .idle: return "아직 확인하지 않았습니다"
        case .checking: return "집 서버에 물어보는 중…"
        case .ready:
            guard let printer = model.printer else { return "프린터가 없습니다" }
            return "\(printer.displayName) · \(printer.state.title)"
        case .failed: return "프린터에 닿지 못했습니다"
        }
    }

    private var detail: String {
        switch model.status {
        case .idle: return "새로고침을 누르면 프린터 상태와 큐를 읽어 옵니다."
        case .checking: return "적어 둔 주소를 순서대로 시도합니다 — 집 주소가 먼저, 안 되면 밖에서 쓰는 주소."
        case .ready:
            var lines: [String] = []
            if let reason = model.printer?.reason, !reason.isEmpty { lines.append(reason) }
            if model.isOutsideHome {
                lines.append("집 밖에서 붙어 있습니다. 보내는 만큼 모바일 데이터를 씁니다.")
            }
            if !model.grayscaleAvailable, !model.capabilities.supportsColorModel {
                lines.append("이 프린터는 컬러/흑백을 고를 수 없습니다.")
            }
            return lines.joined(separator: " ")
        case .failed(let message): return message
        }
    }
}

private struct PrintOptionsPanel: View {
    @ObservedObject var model: PrintModel

    private var rangeIsValid: Bool { PrintOptions.isValidRange(model.options.pageRange) }

    var body: some View {
        ToolSettingsPanel(explanation: explanation) {
            HStack(spacing: Spacing.l) {
                LabeledContent("매수") {
                    Stepper(value: $model.options.copies, in: 1...99) {
                        Text("\(model.options.copies)부").monospacedDigit()
                    }
                    .fixedSize()
                }
                .fixedSize()

                Picker("용지", selection: $model.options.paper) {
                    ForEach(model.capabilities.pageSizes, id: \.self) { size in
                        Text(PaperGeometry.title(for: size)).tag(size)
                    }
                }
                .frame(maxWidth: 220)

                Picker("모아찍기", selection: $model.options.numberUp) {
                    Text("한 쪽에 1장").tag(1)
                    Text("2장").tag(2)
                    Text("4장").tag(4)
                    Text("6장").tag(6)
                    Text("9장").tag(9)
                }
                .frame(maxWidth: 200)
                Spacer()
            }

            HStack(spacing: Spacing.l) {
                Picker("인쇄 면", selection: $model.options.sides) {
                    ForEach(PrintOptions.Sides.allCases) { Text($0.title).tag($0) }
                }
                .frame(maxWidth: 300)
                .disabled(!model.capabilities.supportsDuplex)
                .opacity(model.capabilities.supportsDuplex ? 1 : 0.4)
                .help(model.capabilities.supportsDuplex ? "" : "이 프린터에는 양면 장치가 달려 있지 않습니다")

                Toggle("흑백으로 보내기", isOn: $model.options.grayscale)
                    .disabled(!model.grayscaleAvailable)
                    .help("서버에서 회색조 PDF로 바꿔 보냅니다. 컬러 토너를 쓰지 않습니다")
                Toggle("용지에 맞추기", isOn: $model.options.fitToPage)
                Spacer()
            }

            HStack(spacing: Spacing.s) {
                Text("쪽 범위").font(.callout)
                TextField("전체", text: $model.options.pageRange)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 160)
                if !rangeIsValid {
                    Label("1-4, 8 처럼 적어 주세요", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                Spacer()
            }
        }
        .disabled(model.isSending)
    }

    private var explanation: String {
        var lines: [String] = []
        if model.totalPages > 0 {
            lines.append("문서 \(model.readyDocuments.count)개 · \(model.totalPages)쪽 → **종이 \(model.totalSheets)장** · 보낼 용량 \(PrintPreparation.byteText(model.totalBytes))")
        }
        if model.totalSheets > 30 {
            lines.append("종이가 \(model.totalSheets)장 나갑니다. 트레이에 그만큼 들어 있는지 보고 누르세요.")
        }
        if model.isOutsideHome, model.totalBytes > 20 * 1024 * 1024 {
            lines.append("집 밖에서 \(PrintPreparation.byteText(model.totalBytes))를 올려 보냅니다.")
        }
        if !model.capabilities.supportsDuplex {
            lines.append("양면 장치가 없어 단면으로만 나갑니다.")
        }
        return lines.joined(separator: " ")
    }
}

private struct PrintDocumentList: View {
    @ObservedObject var model: PrintModel

    var body: some View {
        if model.documents.isEmpty {
            EmptyResults(
                symbol: "printer",
                message: "아직 보낼 문서가 없습니다.\n위에 파일을 드롭하거나 툴바에서 파일을 고르세요."
            )
        } else {
            VStack(spacing: Spacing.s) {
                ForEach(model.documents) { document in
                    PrintDocumentRow(model: model, document: document)
                }
            }
        }
    }
}

private struct PrintDocumentRow: View {
    @ObservedObject var model: PrintModel
    let document: PrintModel.Document

    var body: some View {
        HStack(spacing: Spacing.m) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(colour)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(document.source.lastPathComponent)
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(document.statusText)
                    .font(.caption)
                    .foregroundStyle(colour == .red ? Color.red : .secondary)
                    .lineLimit(2)
            }
            Spacer()
            if case .sending(let fraction) = document.state {
                ProgressView(value: fraction)
                    .tint(.snuBlue)
                    .frame(width: 90)
            } else if document.isReady, document.pageCount > 0 {
                Text("종이 \(model.options.sheets(forPages: document.pageCount))장")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Button("빼기", systemImage: "xmark.circle.fill") { model.remove(document) }
                .buttonStyle(.borderless)
                .labelStyle(.iconOnly)
                .foregroundStyle(.tertiary)
                .disabled(model.isSending)
                .help("이 문서를 목록에서 뺍니다")
        }
        .padding(Spacing.m)
        .contentCard()
    }

    private var symbol: String {
        switch document.state {
        case .preparing: "hourglass"
        case .ready: "doc"
        case .sending: "arrow.up.doc"
        case .sent: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        }
    }

    private var colour: Color {
        switch document.state {
        case .failed: .red
        case .sent: .snuBlueLabel
        default: .secondary
        }
    }
}

private struct PrintQueuePanel: View {
    @ObservedObject var model: PrintModel

    var body: some View {
        if !model.queue.isEmpty {
            VStack(alignment: .leading, spacing: Spacing.s) {
                Text("서버 큐 \(model.queue.count)건").font(.headline)
                ForEach(model.queue) { entry in
                    HStack(spacing: Spacing.m) {
                        Image(systemName: "doc.text").foregroundStyle(.secondary)
                        Text(entry.id).font(.callout).monospaced()
                        Text(PrintPreparation.byteText(entry.bytes))
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Text(entry.submitted).font(.caption).foregroundStyle(.tertiary).lineLimit(1)
                        Button("취소") { model.cancel(entry) }
                            .buttonStyle(.borderless)
                            .font(.caption)
                            .help("이 작업을 서버 큐에서 지웁니다")
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Spacing.l)
            .glassPanel()
        }
    }
}

// MARK: - 개요 타일

struct PrintOverviewTile: View {
    @ObservedObject var model: PrintModel
    let open: () -> Void

    var body: some View {
        StatusTile(
            title: AppSection.print.title,
            value: model.overviewValue,
            detail: model.overviewDetail,
            symbol: AppSection.print.symbol,
            isBusy: model.isSending || model.status == .checking,
            isAlarming: model.printer?.state == .stopped,
            open: open
        )
    }
}

// MARK: - 설정 › 프린터

struct PrintSettingsTab: View {
    @ObservedObject var model: PrintModel

    var body: some View {
        Form {
            Section("프린터") {
                if model.printers.isEmpty {
                    Text("아직 프린터를 읽지 못했습니다. 프린트 탭에서 새로고침을 눌러 주세요.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Picker("기본 프린터", selection: $model.selectedPrinter) {
                        ForEach(model.printers) { printer in
                            Text(printer.displayName).tag(printer.name)
                        }
                    }
                }
                Picker("기본 용지", selection: $model.options.paper) {
                    ForEach(model.capabilities.pageSizes, id: \.self) { size in
                        Text(PaperGeometry.title(for: size)).tag(size)
                    }
                }
                Button("테스트 페이지 인쇄") { model.printTestPage() }
                    .disabled(model.isSending || model.status != .ready)
                Text("종이 한 장이 나옵니다. 이 Mac에서 집 서버의 프린터까지 길이 열려 있는지 확인하는 용도입니다.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("서버") {
                LabeledContent("지금 붙은 주소", value: model.routeText.isEmpty ? "아직 붙지 않았습니다" : model.routeText)
                Text("프린터는 집 서버에 USB로 붙어 있고, 이 앱은 SSH로 명령만 보냅니다. 주소는 **설정 › 로봇**에 적어 둔 것과 같은 것을 씁니다 — 같은 서버이므로 두 벌을 두지 않습니다. 집 주소와 집 밖에서 쓸 주소를 모두 적어 두면 어디에 있든 같은 화면이 그대로 뜹니다.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task { if model.status == .idle { await model.refresh() } }
    }
}
