import Foundation
#if canImport(Testing)
import Testing
import PDFKit
@testable import SeoulLocalAgent

@Suite("프린트")
struct PrintingTests {

    // MARK: 서버가 하는 말 읽기

    /// 집 서버가 실제로 내놓은 출력. 손으로 다듬지 않고 그대로 둔다 — 이 시험이 지켜야 하는
    /// 것은 "우리가 상상한 형식"이 아니라 저 기계가 내놓는 형식이다.
    static let realPrinterOutput = """
    printer Samsung_C48x is idle.  enabled since Fri Sep  4 10:31:01 2026
    system default destination: Samsung_C48x
    """

    static let realOptionsOutput = """
    PageSize/Media Size: Letter Legal Executive Tabloid A3 A4 A5 B5 EnvISOB5 Env10 EnvC5 EnvDL EnvMonarch
    InputSlot/Media Source: *Default Upper Manual
    Duplex/2-Sided Printing: *None DuplexNoTumble DuplexTumble
    Option1/Duplexer: *False True
    """

    @Test("대기 중인 프린터와 기본 프린터를 읽는다")
    func readsIdlePrinter() throws {
        let printers = CUPSOutput.printers(Self.realPrinterOutput)
        #expect(printers.count == 1)
        let printer = try #require(printers.first)
        #expect(printer.name == "Samsung_C48x")
        #expect(printer.state == .idle)
        #expect(printer.isDefault)
        // 큐 이름의 밑줄은 사람이 읽는 자리에서만 사라진다.
        #expect(printer.displayName == "Samsung C48x")
    }

    @Test("멈춘 프린터는 멈춘 것으로, 이유와 함께 읽는다")
    func readsStoppedPrinter() throws {
        let text = """
        printer Samsung_C48x disabled since Fri Sep  4 11:00:00 2026 -
        \tMedia tray empty
        printer Office_MFP is idle.  enabled since Fri Sep  4 09:00:00 2026
        system default destination: Office_MFP
        """
        let printers = CUPSOutput.printers(text)
        #expect(printers.count == 2)
        #expect(printers[0].state == .stopped)
        // 이유가 없으면 사람은 프린터 앞까지 걸어가서야 종이가 없다는 것을 안다.
        #expect(printers[0].reason == "Media tray empty")
        #expect(printers[0].isDefault == false)
        #expect(printers[1].isDefault)
    }

    @Test("인쇄 중인 프린터를 대기 중으로 읽지 않는다")
    func readsPrintingState() throws {
        let printers = CUPSOutput.printers("printer Samsung_C48x now printing Samsung_C48x-7.  enabled since Fri Sep  4 10:31:01 2026")
        #expect(printers.first?.state == .printing)
    }

    @Test("PPD가 내주는 선택지를 그대로 읽는다")
    func readsCapabilities() throws {
        let capabilities = CUPSOutput.capabilities(Self.realOptionsOutput)
        #expect(capabilities.option("PageSize")?.choices.contains("A4") == true)
        #expect(capabilities.option("Duplex")?.current == "None")
        // 학생이 실제로 쓰는 용지가 앞으로 온다. 봉투가 첫 줄에 있으면 픽커가 쓸모없다.
        #expect(capabilities.pageSizes.first == "A4")
        #expect(capabilities.pageSizes.contains("EnvDL"))
        #expect(capabilities.defaultPageSize == "A4")
    }

    @Test("양면 장치가 없으면 양면을 걸 수 있다고 말하지 않는다")
    func duplexNeedsTheHardware() {
        // 이 집 프린터가 정확히 그 상태다. `Duplex` 항목은 PPD에 있지만 `Option1/Duplexer`가
        // `False`이므로 양면 장치가 달려 있지 않다. 스위치를 그려 놓으면 눌러도 아무 일도
        // 일어나지 않는 스위치가 된다.
        #expect(CUPSOutput.capabilities(Self.realOptionsOutput).supportsDuplex == false)

        let withDuplexer = """
        Duplex/2-Sided Printing: *None DuplexNoTumble DuplexTumble
        Option1/Duplexer: False *True
        """
        #expect(CUPSOutput.capabilities(withDuplexer).supportsDuplex)
    }

    @Test("컬러 항목이 없는 프린터는 컬러를 고를 수 없다고 말한다")
    func colourNeedsThePPDOption() {
        #expect(CUPSOutput.capabilities(Self.realOptionsOutput).supportsColorModel == false)
        let colour = "ColorModel/Color Mode: *RGB Gray"
        #expect(CUPSOutput.capabilities(colour).supportsColorModel)
    }

    @Test("큐 목록에서 작업만 골라 읽는다")
    func readsQueue() throws {
        let text = """
        Samsung_C48x-2          deploy            1024   Fri Sep  4 10:37:35 2026
        Samsung_C48x-3          deploy            8192   Fri Sep  4 10:37:35 2026
        """
        let queue = CUPSOutput.queue(text)
        #expect(queue.count == 2)
        #expect(queue[0].id == "Samsung_C48x-2")
        #expect(queue[1].bytes == 8192)
        // 큐가 비면 `lpstat -o`는 아무것도 내놓지 않는다.
        #expect(CUPSOutput.queue("").isEmpty)
        // 작업 줄이 아닌 것을 작업으로 세면 화면이 없는 대기열을 그린다.
        #expect(CUPSOutput.queue("lpstat: Transport endpoint is not connected").isEmpty)
    }

    @Test("lp가 돌려준 작업 번호를 읽는다")
    func readsJobID() {
        #expect(CUPSOutput.jobID("request id is Samsung_C48x-12 (1 file(s))") == "Samsung_C48x-12")
        // stdin으로 보내면 파일 수가 0이라고 적힌다. 그것은 실패가 아니다.
        #expect(CUPSOutput.jobID("request id is Samsung_C48x-4 (0 file(s))") == "Samsung_C48x-4")
        #expect(CUPSOutput.jobID("lp: Error - unknown destination") == nil)
    }

    // MARK: 보내는 명령

    @Test("따옴표와 공백이 든 이름이 셸에서 쪼개지지 않는다")
    func quotesAwkwardNames() {
        let quoted = PrintCommand.quote("전자기학 '중간' 요약.pdf")
        #expect(quoted.hasPrefix("'") && quoted.hasSuffix("'"))
        #expect(quoted.contains("'\\''"))
    }

    @Test("고른 설정이 IPP 이름으로 명령에 실린다")
    func buildsLPCommand() {
        var options = PrintOptions()
        options.copies = 3
        options.paper = "A4"
        options.numberUp = 2
        options.pageRange = "1-4,8"
        options.sides = .twoSidedLongEdge
        let command = PrintCommand.send(
            options: options, printer: "Samsung_C48x", title: "요약", grayscaleAvailable: false
        )
        // PPD마다 다른 이름(`Duplex`, `PageSize`)이 아니라 IPP 이름으로 적는다. 그래야
        // 프린터를 바꾼 날 조용히 무시되지 않는다.
        #expect(command.contains("'sides=two-sided-long-edge'"))
        #expect(command.contains("'media=A4'"))
        #expect(command.contains("'number-up=2'"))
        #expect(command.contains("'page-ranges=1-4,8'"))
        #expect(command.contains("'-n' '3'"))
        // 여러 부를 찍을 때 한 부씩 모이지 않으면 사람이 손으로 나눠야 한다.
        #expect(command.contains("'collate=true'"))
        // 흑백을 고르지 않았으면 변환도 없다.
        #expect(command.contains("gs ") == false)
    }

    @Test("흑백은 서버에 ghostscript가 있을 때만 파이프에 붙는다")
    func grayscaleNeedsGhostscript() {
        var options = PrintOptions()
        options.grayscale = true
        let withGS = PrintCommand.send(options: options, printer: "P", title: "t", grayscaleAvailable: true)
        #expect(withGS.contains("sColorConversionStrategy=Gray"))
        // 파이프 앞이 죽었는데 뒤가 성공하면 아무것도 안 찍히고 성공이라고 적힌다.
        #expect(withGS.contains("set -o pipefail"))

        let withoutGS = PrintCommand.send(options: options, printer: "P", title: "t", grayscaleAvailable: false)
        #expect(withoutGS.contains("gs ") == false)
        #expect(withoutGS.hasPrefix("'lp'"))
    }

    @Test("제목은 한 줄로 줄이고 길이를 자른다")
    func sanitisesTitle() {
        #expect(PrintCommand.title(for: "강의\n노트.pdf") == "강의 노트.pdf")
        #expect(PrintCommand.title(for: String(repeating: "가", count: 200)).count == 80)
        #expect(PrintCommand.title(for: "   ") == "SeoulLocalAgent")
    }

    @Test("상태·선택지·큐를 한 번의 왕복으로 묻는다")
    func inspectsInOneRoundTrip() {
        // 셋으로 나누면 집 밖에서 쓸 때 왕복 지연이 세 배가 된다.
        let command = PrintCommand.inspect(printer: "Samsung_C48x")
        #expect(command.contains("lpstat -p -d"))
        #expect(command.contains("lpoptions -p 'Samsung_C48x' -l"))
        #expect(command.contains("lpstat -o"))
        #expect(command.contains("command -v gs"))
    }

    // MARK: 쪽 범위와 종이 수

    @Test("쪽 범위는 CUPS가 받는 꼴만 통과시킨다")
    func validatesPageRanges() {
        #expect(PrintOptions.isValidRange(""))
        #expect(PrintOptions.isValidRange("1-4,8"))
        #expect(PrintOptions.isValidRange("2-"))
        #expect(PrintOptions.isValidRange("가나다") == false)
        #expect(PrintOptions.isValidRange("4-1") == false)
        #expect(PrintOptions.isValidRange("0") == false)
        #expect(PrintOptions.isValidRange("1,,2") == false)
    }

    @Test("종이 수는 모아찍기와 양면을 함께 센다")
    func countsSheetsNotPages() {
        var options = PrintOptions()
        #expect(options.sheets(forPages: 10) == 10)
        options.numberUp = 2
        #expect(options.sheets(forPages: 10) == 5)
        options.sides = .twoSidedLongEdge
        // 한 쪽에 2장씩, 그것을 앞뒤로 → 10쪽이 종이 3장.
        #expect(options.sheets(forPages: 10) == 3)
        options.copies = 2
        #expect(options.sheets(forPages: 10) == 6)
        #expect(options.sheets(forPages: 0) == 0)
    }

    // MARK: 보내기 전에 PDF로

    @Test("한글 텍스트가 여러 쪽 PDF로 앉는다")
    func rendersKoreanTextToPDF() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "print-text-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appending(path: "강의 정리.txt")
        let body = (1...400).map { "\($0)번째 줄 · 전자기학 정리 노트" }.joined(separator: "\n")
        try body.write(to: source, atomically: true, encoding: .utf8)

        let prepared = try await PrintPreparation.prepare(source, paper: "A4")
        #expect(prepared.pageCount > 1)
        #expect(prepared.isTemporary)
        let document = try #require(PDFDocument(url: prepared.pdf))
        #expect(document.pageCount == prepared.pageCount)
        // 서버 필터가 아니라 여기서 앉히는 이유가 이것이다: 글자가 글자로 남는다.
        #expect(document.page(at: 0)?.string?.contains("전자기학") == true)
        try? FileManager.default.removeItem(at: prepared.pdf)
    }

    @Test("사진은 고른 용지 한 쪽에 앉는다")
    func fitsPhotoOntoOnePage() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "print-image-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appending(path: "슬라이드.png")
        let context = try #require(CGContext(
            data: nil, width: 1600, height: 900, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 1600, height: 900))
        let image = try #require(context.makeImage())
        let destination = try #require(CGImageDestinationCreateWithURL(
            source as CFURL, "public.png" as CFString, 1, nil
        ))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))

        let prepared = try await PrintPreparation.prepare(source, paper: "A4")
        #expect(prepared.pageCount == 1)
        let pdf = try #require(PDFDocument(url: prepared.pdf))
        let bounds = try #require(pdf.page(at: 0)?.bounds(for: .mediaBox))
        // 픽셀 크기 그대로의 쪽을 만들면 무엇이 어떻게 잘릴지 드라이버가 정하게 된다.
        #expect(abs(bounds.width - PaperGeometry.size(for: "A4").width) < 1)
        #expect(abs(bounds.height - PaperGeometry.size(for: "A4").height) < 1)
        try? FileManager.default.removeItem(at: prepared.pdf)
    }

    @Test("PDF는 다시 만들지 않고 그대로 보낸다")
    func passesPDFThrough() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "print-pdf-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appending(path: "원본.pdf")
        var box = CGRect(x: 0, y: 0, width: 595, height: 842)
        let context = try #require(CGContext(source as CFURL, mediaBox: &box, nil))
        for _ in 0..<3 {
            context.beginPDFPage(nil)
            context.endPDFPage()
        }
        context.closePDF()

        let prepared = try await PrintPreparation.prepare(source, paper: "A4")
        #expect(prepared.pageCount == 3)
        // 원본을 다시 구우면 용량만 늘고 얻는 것이 없다. 그리고 원본은 지울 대상이 아니다.
        #expect(prepared.pdf == source)
        #expect(prepared.isTemporary == false)
    }

    @Test("보낼 수 없는 형식은 목록에 들어가기 전에 거절한다")
    func rejectsUnsupportedFiles() {
        #expect(PrintPreparation.accepts(URL(fileURLWithPath: "/tmp/보고서.pdf")))
        #expect(PrintPreparation.accepts(URL(fileURLWithPath: "/tmp/사진.HEIC")))
        #expect(PrintPreparation.accepts(URL(fileURLWithPath: "/tmp/과제.docx")))
        #expect(PrintPreparation.accepts(URL(fileURLWithPath: "/tmp/제출.hwp")))
        #expect(PrintPreparation.accepts(URL(fileURLWithPath: "/tmp/강의.mp4")) == false)
    }

    @Test("모르는 용지 이름에도 그릴 크기가 있다")
    func fallsBackToA4() {
        #expect(PaperGeometry.size(for: "A4") == PaperGeometry.size(for: "EnvMonarch"))
        #expect(PaperGeometry.size(for: "Letter").width == 612)
    }

    // MARK: 집에서도 밖에서도

    @Test("적어 둔 두 주소를 순서대로 시도한다")
    func triesBothAddresses() {
        // 이 맥은 집에도 있고 밖에도 있다. 주소가 하나뿐이면 나머지 한쪽에서는 아무것도
        // 되지 않고, 그것은 절반만 만든 기능이다.
        let server = SOArmServer(host: "192.168.0.20", alternateHost: "100.123.134.28", user: "deploy")
        #expect(server.candidateHosts == ["192.168.0.20", "100.123.134.28"])

        let arguments = PrinterLink.arguments(
            server: server, host: "100.123.134.28", key: SOArmTunnelKey(), command: "lpstat -p"
        )
        // 주소가 둘이면 닿지 않는 쪽에서 오래 기다리지 않는다. 그 시간만큼 화면이 비어 있다.
        #expect(arguments.contains("ConnectTimeout=4"))
        #expect(arguments.contains("deploy@100.123.134.28"))
        // 앱은 암호를 물을 창이 없다. 물으며 멈추는 대신 즉시 실패해야 한다.
        #expect(arguments.contains("BatchMode=yes"))
        // 강제 종료 뒤 남은 ssh를 다음 실행이 찾아 죽이기 위한 표식.
        #expect(arguments.last?.contains(PrinterLink.marker) == true)

        let homeOnly = SOArmServer(host: "192.168.0.20", user: "deploy")
        let single = PrinterLink.arguments(
            server: homeOnly, host: "192.168.0.20", key: SOArmTunnelKey(), command: "lpstat -p"
        )
        #expect(single.contains("ConnectTimeout=8"))
    }
}
#endif
