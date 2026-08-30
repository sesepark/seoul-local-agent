import Foundation
import AppKit
import AVFoundation
import CoreGraphics
import ImageIO
import PDFKit
import UniformTypeIdentifiers

// MARK: - 무엇을 무엇으로

/// The four kinds of conversion, which is how people actually think about this:
/// "이 사진들 PNG로", "이 영상 소리만", "이 발표자료 PDF로". Picking the family
/// first keeps each format list short enough to read.
enum ConversionFamily: String, CaseIterable, Identifiable, Sendable {
    case image
    case audio
    case video
    case document

    var id: String { rawValue }

    var title: String {
        switch self {
        case .image: "사진"
        case .audio: "오디오"
        case .video: "영상"
        case .document: "문서"
        }
    }

    var symbol: String {
        switch self {
        case .image: "photo"
        case .audio: "waveform"
        case .video: "film"
        case .document: "doc.richtext"
        }
    }

    var targets: [ConversionTarget] { ConversionTarget.allCases.filter { $0.family == self } }

    /// Which family a dropped file belongs to, so the screen can follow what was
    /// put in rather than making the user set the picker first.
    static func of(_ url: URL) -> ConversionFamily? {
        let ext = url.pathExtension.lowercased()
        if CompressionKind.imageExtensions.contains(ext) { return .image }
        if MediaImporter.videoExtensions.contains(ext) { return .video }
        if MediaImporter.audioExtensions.contains(ext) { return .audio }
        if ConversionTarget.documentInputs.contains(ext) { return .document }
        return nil
    }
}

enum ConversionTarget: String, CaseIterable, Identifiable, Sendable {
    case jpeg, png, heic, tiff, webp, imageToPDF
    case m4a, mp3, wav, aiff, flac
    case mp4, mov, gif, extractAudio
    case officeToPDF, pdfToText, pdfToImages

    var id: String { rawValue }

    var family: ConversionFamily {
        switch self {
        case .jpeg, .png, .heic, .tiff, .webp, .imageToPDF: .image
        case .m4a, .mp3, .wav, .aiff, .flac: .audio
        case .mp4, .mov, .gif, .extractAudio: .video
        case .officeToPDF, .pdfToText, .pdfToImages: .document
        }
    }

    var title: String {
        switch self {
        case .jpeg: "JPEG"
        case .png: "PNG"
        case .heic: "HEIC"
        case .tiff: "TIFF"
        case .webp: "WebP"
        case .imageToPDF: "PDF (사진 한 장에 한 쪽)"
        case .m4a: "M4A (AAC)"
        case .mp3: "MP3"
        case .wav: "WAV"
        case .aiff: "AIFF"
        case .flac: "FLAC"
        case .mp4: "MP4 (H.264)"
        case .mov: "MOV"
        case .gif: "GIF"
        case .extractAudio: "소리만 빼기 (M4A)"
        case .officeToPDF: "PDF로"
        case .pdfToText: "텍스트로"
        case .pdfToImages: "쪽마다 PNG로"
        }
    }

    var fileExtension: String {
        switch self {
        case .jpeg: "jpg"
        case .png: "png"
        case .heic: "heic"
        case .tiff: "tiff"
        case .webp: "webp"
        case .imageToPDF, .officeToPDF: "pdf"
        case .m4a, .extractAudio: "m4a"
        case .mp3: "mp3"
        case .wav: "wav"
        case .aiff: "aiff"
        case .flac: "flac"
        case .mp4: "mp4"
        case .mov: "mov"
        case .gif: "gif"
        case .pdfToText: "txt"
        // A folder of pages rather than one file, so it has no extension at all.
        case .pdfToImages: ""
        }
    }

    static let documentInputs: Set<String> = [
        "pdf", "docx", "doc", "pptx", "ppt", "xlsx", "xls",
        "odt", "odp", "ods", "rtf", "hwp", "hwpx", "txt", "md", "csv",
    ]

    static let officeInputs: Set<String> = [
        "docx", "doc", "pptx", "ppt", "xlsx", "xls",
        "odt", "odp", "ods", "rtf", "hwp", "hwpx", "txt", "md", "csv",
    ]

    /// What this particular conversion will accept, which is narrower than the
    /// family: `텍스트로` only makes sense for a PDF.
    var accepts: Set<String> {
        switch self {
        case .jpeg, .png, .heic, .tiff, .webp, .imageToPDF: CompressionKind.imageExtensions
        case .m4a, .mp3, .wav, .aiff, .flac: MediaImporter.audioExtensions.union(MediaImporter.videoExtensions)
        case .mp4, .mov, .gif, .extractAudio: MediaImporter.videoExtensions
        case .officeToPDF: Self.officeInputs
        case .pdfToText, .pdfToImages: ["pdf"]
        }
    }

    /// `nil` when nothing extra is needed. Anything else is a Homebrew or
    /// LibreOffice dependency the screen has to warn about before the user
    /// queues fifty files against it.
    var missingDependency: String? {
        switch self {
        case .webp where ImageOutputFormat.cwebpPath == nil:
            "WebP로 저장하려면 터미널에서 `brew install webp`를 실행해 주세요."
        case .mp3 where MediaImporter.ffmpegPath == nil,
             .mp4 where MediaImporter.ffmpegPath == nil,
             .mov where MediaImporter.ffmpegPath == nil,
             .gif where MediaImporter.ffmpegPath == nil:
            "이 변환에는 `brew install ffmpeg`가 필요합니다."
        case .officeToPDF where FileConverter.sofficePath == nil:
            "문서를 PDF로 바꾸려면 LibreOffice가 필요합니다. `brew install --cask libreoffice` 후 다시 시도해 주세요."
        default:
            nil
        }
    }

    var detail: String {
        switch self {
        case .imageToPDF: "고른 사진을 한 장씩 PDF로 만듭니다. 여러 장을 한 PDF로 묶으려면 PDF 편집에서 합치세요."
        case .extractAudio: "영상에서 소리만 꺼내 M4A로 저장합니다. ffmpeg 없이 동작합니다."
        case .gif: "12fps · 긴 변 640px으로 줄여 만듭니다. 긴 영상은 GIF로 만들면 용량이 오히려 커집니다."
        case .officeToPDF: "LibreOffice가 그대로 열어 PDF로 인쇄합니다. HWP는 서식이 흐트러질 수 있습니다."
        case .pdfToImages: "쪽마다 PNG를 만들어 폴더 하나로 돌려줍니다. 150dpi입니다."
        case .pdfToText: "PDF에 들어 있는 글자를 그대로 꺼냅니다. 스캔본은 글자가 없으므로 문서 인식을 쓰세요."
        case .flac: "무손실 압축입니다. WAV의 절반쯤 되는 용량으로 원음을 그대로 담습니다."
        default: ""
        }
    }
}

struct ConversionRequest: Sendable {
    var target: ConversionTarget = .jpeg
    var quality: Double = 0.9
}

// MARK: - 작업자

struct FileConverter: BatchToolWorker {
    let request: ConversionRequest

    var accepts: Set<String> { request.target.accepts }

    /// LibreOffice keeps one user profile and refuses to run twice against it,
    /// and there is only one hardware video encoder. Everything else scales.
    var concurrency: Int {
        switch request.target {
        case .officeToPDF, .mp4, .mov, .gif: 1
        default: 3
        }
    }

    var saveSuffix: String { "변환" }

    func outputExtension(for source: URL) -> String { request.target.fileExtension }

    static var sofficePath: String? {
        [
            "/Applications/LibreOffice.app/Contents/MacOS/soffice",
            "/opt/homebrew/bin/soffice",
            "/usr/local/bin/soffice",
        ].first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    func inspect(_ source: URL) async throws -> ToolJobInfo {
        if let missing = request.target.missingDependency { throw AgentError.processFailed(missing) }
        switch request.target.family {
        case .image:
            guard let size = UpscaleWorker.pixelSize(of: source) else {
                throw AgentError.processFailed("사진을 읽지 못했습니다: \(source.lastPathComponent)")
            }
            let megapixels = Double(size.width * size.height) / 1_000_000
            return ToolJobInfo(detail: "\(size.width)×\(size.height)", estimatedSeconds: megapixels / 40 + 0.05)
        case .audio, .video:
            let duration = try await AVURLAsset(url: source).load(.duration).seconds
            guard duration.isFinite, duration > 0 else {
                throw AgentError.processFailed("길이를 읽지 못했습니다: \(source.lastPathComponent)")
            }
            let rate: Double = switch request.target {
            case .mp4, .mov: 10
            case .gif: 4
            default: 60
            }
            return ToolJobInfo(detail: CompressionFormat.duration(duration), estimatedSeconds: duration / rate + 0.5)
        case .document:
            if request.target == .officeToPDF {
                return ToolJobInfo(detail: source.pathExtension.uppercased(), estimatedSeconds: 4)
            }
            guard let document = PDFDocument(url: source) else {
                throw AgentError.processFailed("PDF를 열지 못했습니다: \(source.lastPathComponent)")
            }
            let pages = document.pageCount
            let perPage = request.target == .pdfToImages ? 0.25 : 0.01
            return ToolJobInfo(detail: "\(pages)쪽", estimatedSeconds: Double(pages) * perPage + 0.2)
        }
    }

    func run(
        _ source: URL,
        to destination: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> ToolOutcome {
        if let missing = request.target.missingDependency { throw AgentError.processFailed(missing) }
        let before = CompressionWorkspace.fileSize(of: source)
        progress(0.05)
        var detail = ""
        var note: String?

        switch request.target {
        case .jpeg, .png, .heic, .tiff, .webp:
            detail = try Self.convertImage(source, to: destination, target: request.target, quality: request.quality)
        case .imageToPDF:
            detail = try Self.imageToPDF(source, to: destination)
        case .m4a, .wav, .aiff, .flac, .extractAudio:
            detail = try await Self.convertAudio(source, to: destination, target: request.target, progress: progress)
        case .mp3:
            detail = try await Self.runFFmpeg(source, to: destination, arguments: { input, output in
                ["-hide_banner", "-loglevel", "error", "-y", "-i", input, "-vn",
                 "-c:a", "libmp3lame", "-q:a", "2", "-progress", "pipe:1", "-nostats", output]
            }, progress: progress)
        case .mp4:
            detail = try await Self.runFFmpeg(source, to: destination, arguments: { input, output in
                ["-hide_banner", "-loglevel", "error", "-y", "-i", input,
                 "-c:v", "h264_videotoolbox", "-q:v", "55", "-c:a", "aac", "-b:a", "128k",
                 "-movflags", "+faststart", "-progress", "pipe:1", "-nostats", output]
            }, progress: progress)
        case .mov:
            detail = try await Self.runFFmpeg(source, to: destination, arguments: { input, output in
                ["-hide_banner", "-loglevel", "error", "-y", "-i", input,
                 "-c:v", "h264_videotoolbox", "-q:v", "55", "-c:a", "aac", "-b:a", "128k",
                 "-progress", "pipe:1", "-nostats", output]
            }, progress: progress)
        case .gif:
            // One pass: `split` feeds the same frames to the palette generator and
            // to the encoder, so there is no temporary palette file to clean up.
            detail = try await Self.runFFmpeg(source, to: destination, arguments: { input, output in
                ["-hide_banner", "-loglevel", "error", "-y", "-i", input,
                 "-filter_complex",
                 "fps=12,scale=640:-1:flags=lanczos,split[a][b];[a]palettegen=stats_mode=diff[p];[b][p]paletteuse=dither=bayer",
                 "-loop", "0", "-progress", "pipe:1", "-nostats", output]
            }, progress: progress)
            note = "GIF는 색이 256개뿐이라 원본보다 커질 수 있습니다."
        case .officeToPDF:
            detail = try await Self.officeToPDF(source, to: destination, progress: progress)
            if ["hwp", "hwpx"].contains(source.pathExtension.lowercased()) {
                note = "HWP는 LibreOffice가 근사치로 읽습니다. 서식을 확인해 주세요."
            }
        case .pdfToText:
            detail = try Self.pdfToText(source, to: destination)
        case .pdfToImages:
            detail = try Self.pdfToImages(source, to: destination, progress: progress)
        }

        progress(1)
        guard FileManager.default.fileExists(atPath: destination.path) else {
            throw AgentError.processFailed("변환 결과를 만들지 못했습니다.")
        }
        let after = Self.size(of: destination)
        return ToolOutcome(
            output: destination,
            detail: detail,
            headline: "\(CompressionFormat.bytes(before)) → \(CompressionFormat.bytes(after))",
            note: note
        )
    }

    /// A folder result has to be added up rather than stat-ed.
    static func size(of url: URL) -> Int {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return 0 }
        guard isDirectory.boolValue else { return CompressionWorkspace.fileSize(of: url) }
        let children = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? []
        return children.reduce(0) { $0 + CompressionWorkspace.fileSize(of: $1) }
    }

    // MARK: 사진

    static func convertImage(_ source: URL, to destination: URL, target: ConversionTarget, quality: Double) throws -> String {
        guard let size = UpscaleWorker.pixelSize(of: source) else {
            throw AgentError.processFailed("사진을 읽지 못했습니다: \(source.lastPathComponent)")
        }
        if target == .webp {
            guard let cwebp = ImageOutputFormat.cwebpPath else {
                throw AgentError.processFailed("WebP로 저장하려면 `brew install webp`가 필요합니다.")
            }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: cwebp)
            process.arguments = ["-quiet", "-q", "\(Int(quality * 100))", source.path, "-o", destination.path]
            process.environment = ProcessRunner.childEnvironment()
            try process.run()
            ActiveProcessRegistry.shared.add(process)
            process.waitUntilExit()
            ActiveProcessRegistry.shared.remove(process)
            guard process.terminationStatus == 0 else {
                throw AgentError.processFailed("WebP로 바꾸지 못했습니다: \(source.lastPathComponent)")
            }
            return "\(size.width)×\(size.height) · WebP"
        }

        guard let imageSource = CGImageSourceCreateWithURL(source as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(imageSource, 0, nil)
        else { throw AgentError.processFailed("사진을 읽지 못했습니다: \(source.lastPathComponent)") }
        let type: UTType = switch target {
        case .png: .png
        case .heic: .heic
        case .tiff: .tiff
        default: .jpeg
        }
        guard let sink = CGImageDestinationCreateWithURL(destination as CFURL, type.identifier as CFString, 1, nil) else {
            throw AgentError.processFailed("결과 파일을 만들지 못했습니다.")
        }
        // The original metadata travels with the picture: a photo that loses its
        // shot date on a format change is a photo that falls out of order in the
        // Photos library.
        var properties = (CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any]) ?? [:]
        properties[kCGImageDestinationLossyCompressionQuality] = quality
        CGImageDestinationAddImage(sink, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(sink) else {
            throw AgentError.processFailed("결과 파일을 저장하지 못했습니다.")
        }
        return "\(size.width)×\(size.height) · \(target.title)"
    }

    static func imageToPDF(_ source: URL, to destination: URL) throws -> String {
        guard let imageSource = CGImageSourceCreateWithURL(source as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(imageSource, 0, nil)
        else { throw AgentError.processFailed("사진을 읽지 못했습니다: \(source.lastPathComponent)") }
        try ScanCorrectionWorker.write(image, to: destination, format: .pdf)
        return "\(image.width)×\(image.height) · 1쪽"
    }

    // MARK: 오디오

    static func convertAudio(
        _ source: URL, to destination: URL, target: ConversionTarget,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> String {
        let reader = try await AudioStreamReader(url: source)
        let settings = try audioSettings(target: target, sampleRate: reader.sampleRate, channels: reader.channelCount)
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: reader.sampleRate,
            channels: AVAudioChannelCount(reader.channelCount), interleaved: true
        ) else { throw AgentError.processFailed("소리 형식을 만들지 못했습니다.") }
        let file = try AVAudioFile(forWriting: destination, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: true)

        var written = 0
        while let block = try reader.next() {
            try Task.checkCancellation()
            let frames = block.count / reader.channelCount
            guard frames > 0,
                  let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
                  let destinationPointer = buffer.floatChannelData?[0]
            else { continue }
            buffer.frameLength = AVAudioFrameCount(frames)
            block.withUnsafeBufferPointer { destinationPointer.update(from: $0.baseAddress!, count: frames * reader.channelCount) }
            try file.write(from: buffer)
            written += frames
            if let expected = reader.frameCount, expected > 0 {
                progress(min(0.95, 0.05 + 0.9 * Double(written) / Double(expected)))
            }
        }
        let channels = reader.channelCount == 1 ? "모노" : "스테레오"
        return "\(Int(reader.sampleRate / 1000)) kHz \(channels) · \(CompressionFormat.duration(reader.duration))"
    }

    static func audioSettings(target: ConversionTarget, sampleRate: Double, channels: Int) throws -> [String: Any] {
        var settings: [String: Any] = [AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: channels]
        switch target {
        case .m4a, .extractAudio:
            settings[AVFormatIDKey] = kAudioFormatMPEG4AAC
            // See `AudioStreamWriter`: below 32 kHz the encoder rejects a named
            // bitrate outright, so it picks its own.
            if sampleRate >= 32_000 { settings[AVEncoderBitRateKey] = 128_000 * max(1, channels) }
        case .wav:
            settings[AVFormatIDKey] = kAudioFormatLinearPCM
            settings[AVLinearPCMBitDepthKey] = 16
            settings[AVLinearPCMIsFloatKey] = false
            settings[AVLinearPCMIsBigEndianKey] = false
            settings[AVLinearPCMIsNonInterleaved] = false
        case .aiff:
            settings[AVFormatIDKey] = kAudioFormatLinearPCM
            settings[AVLinearPCMBitDepthKey] = 16
            settings[AVLinearPCMIsFloatKey] = false
            // AIFF is the big-endian one; writing little-endian samples into it
            // produces a file that plays as loud static.
            settings[AVLinearPCMIsBigEndianKey] = true
            settings[AVLinearPCMIsNonInterleaved] = false
        case .flac:
            settings[AVFormatIDKey] = kAudioFormatFLAC
        default:
            throw AgentError.processFailed("이 형식은 여기서 처리하지 않습니다.")
        }
        return settings
    }

    // MARK: 영상

    static func runFFmpeg(
        _ source: URL, to destination: URL,
        arguments: (String, String) -> [String],
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> String {
        guard let ffmpeg = MediaImporter.ffmpegPath else {
            throw AgentError.processFailed("이 변환에는 `brew install ffmpeg`가 필요합니다.")
        }
        let asset = AVURLAsset(url: source)
        let duration = try await asset.load(.duration).seconds
        try await VideoCompressor.run(
            ffmpeg, arguments(source.path, destination.path), duration: duration
        ) { fraction, _ in
            progress(0.05 + 0.9 * fraction)
        }
        return CompressionFormat.duration(duration)
    }

    // MARK: 문서

    /// LibreOffice writes `<stem>.pdf` into an output directory of its own
    /// choosing, so the conversion runs in a scratch folder and the result is
    /// moved into place afterwards.
    static func officeToPDF(_ source: URL, to destination: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> String {
        guard let soffice = sofficePath else {
            throw AgentError.processFailed("문서를 PDF로 바꾸려면 LibreOffice가 필요합니다. `brew install --cask libreoffice` 후 다시 시도해 주세요.")
        }
        let scratch = try ToolWorkspace.directory("Convert").appending(path: "office-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        progress(0.2)

        // A private user profile per run: LibreOffice refuses to start a second
        // time against a profile that is already open, which is exactly what a
        // batch would do.
        let profile = scratch.appending(path: "profile")
        _ = try await ProcessRunner().run(soffice, [
            "--headless", "--norestore", "--invisible",
            "-env:UserInstallation=file://\(profile.path)",
            "--convert-to", "pdf", "--outdir", scratch.path, source.path,
        ], expectsStandardOutput: false)

        let stem = source.deletingPathExtension().lastPathComponent
        let produced = scratch.appending(path: "\(stem).pdf")
        guard FileManager.default.fileExists(atPath: produced.path) else {
            throw AgentError.processFailed("LibreOffice가 이 문서를 PDF로 바꾸지 못했습니다: \(source.lastPathComponent)")
        }
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: produced, to: destination)
        let pages = PDFDocument(url: destination)?.pageCount ?? 0
        return pages > 0 ? "\(pages)쪽" : "PDF"
    }

    static func pdfToText(_ source: URL, to destination: URL) throws -> String {
        guard let document = PDFDocument(url: source) else {
            throw AgentError.processFailed("PDF를 열지 못했습니다: \(source.lastPathComponent)")
        }
        let text = document.string ?? ""
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AgentError.processFailed("글자가 들어 있지 않은 PDF입니다. 스캔본이라면 문서 인식을 쓰세요.")
        }
        try text.write(to: destination, atomically: true, encoding: .utf8)
        return "\(document.pageCount)쪽 · \(text.count)자"
    }

    /// 150 dpi, which is what a PDF page has to be rendered at before the text
    /// in a lecture slide stops looking soft.
    static func pdfToImages(_ source: URL, to destination: URL, progress: @escaping @Sendable (Double) -> Void) throws -> String {
        guard let document = PDFDocument(url: source), document.pageCount > 0 else {
            throw AgentError.processFailed("PDF를 열지 못했습니다: \(source.lastPathComponent)")
        }
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let scale = 150.0 / 72.0
        var written = 0
        for index in 0 ..< document.pageCount {
            try Task.checkCancellation()
            guard let page = document.page(at: index) else { continue }
            let bounds = page.bounds(for: .mediaBox)
            let width = max(1, Int(bounds.width * scale))
            let height = max(1, Int(bounds.height * scale))
            guard let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            ) else { continue }
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.scaleBy(x: scale, y: scale)
            context.translateBy(x: -bounds.minX, y: -bounds.minY)
            page.draw(with: .mediaBox, to: context)
            guard let image = context.makeImage() else { continue }
            let target = destination.appending(path: String(format: "%03d.png", index + 1))
            try UpscaleWorker.write(image, to: target, format: .png)
            written += 1
            progress(0.05 + 0.9 * Double(index + 1) / Double(document.pageCount))
        }
        guard written > 0 else { throw AgentError.processFailed("쪽을 그리지 못했습니다.") }
        return "\(written)개 PNG"
    }
}
