import Foundation
import AppKit
import Combine

/// 서버 카메라의 MJPEG 스트림 한 개를 받아 최신 프레임만 들고 있는다.
///
/// `multipart/x-mixed-replace`는 `URLSession`이 알아서 풀어 주지 않는다. 응답이 끝나지 않는
/// 하나의 긴 바디이므로 델리게이트로 바이트를 받아 직접 경계를 찾아야 한다.
///
/// 취소가 곧 서버 쪽 해제다. 콘솔의 `CameraWorker`는 스트림을 여는 클라이언트 수를 세고
/// 0이 되면 카메라를 놓는다. 그래서 화면을 벗어날 때와 녹화를 시작하기 전에 반드시 멈춰야
/// 한다 — 카메라를 쥔 채로는 녹화가 시작되지 않는다.
@MainActor
final class MJPEGStream: ObservableObject {
    @Published private(set) var image: NSImage?
    @Published private(set) var isRunning = false
    @Published private(set) var failure: String?

    private var reader: MJPEGReader?

    var hasImage: Bool { image != nil }

    func start(_ url: URL) {
        stop()
        isRunning = true
        let reader = MJPEGReader(url: url)
        reader.onFrame = { [weak self] frame in
            Task { @MainActor in self?.image = frame }
        }
        reader.onFailure = { [weak self] message in
            Task { @MainActor in
                guard let self, self.isRunning else { return }
                self.failure = message
                self.isRunning = false
                self.reader = nil
            }
        }
        self.reader = reader
        reader.start()
    }

    func stop() {
        reader?.cancel()
        reader = nil
        isRunning = false
        image = nil
        failure = nil
    }
}

/// 프레임을 꺼내는 쪽. 델리게이트 큐(직렬)에서만 만져지므로 메인 액터와 분리해 둔다.
///
/// ## 경계는 두 곳에서 온다
///
/// `URLSession`은 `multipart/x-mixed-replace`를 스스로 풀어 준다. 파트마다
/// `didReceive response`를 한 번씩 다시 부르고, `didReceive data`로는 그 파트의 본문만
/// 넘긴다 — 즉 `--frame` 경계 바이트는 이쪽까지 오지 않는다. 그래서 **다음 파트의 응답이
/// 곧 앞 파트의 끝**이다.
///
/// 그렇더라도 경계를 직접 찾는 코드를 남겨 둔다. 이 분해는 우리가 고른 동작이 아니라
/// 플랫폼이 해 주는 동작이고, 스트림이 통짜 바이트로 넘어오는 경우(프록시를 한 번 거치거나
/// 미래의 `URLSession`이 손을 떼는 경우)에도 화면이 그냥 비어 버리면 안 되기 때문이다.
final class MJPEGReader: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    /// 서버가 쓰는 경계 문자열. `app.py`가 `--frame`으로 고정해 두었다.
    static let boundary = Data("--frame".utf8)
    static let headerTerminator = Data("\r\n\r\n".utf8)
    /// 경계도 파트 구분도 없이 이만큼 쌓이면 스트림이 우리가 아는 형식이 아니다.
    static let bufferLimit = 8 * 1024 * 1024

    var onFrame: (@Sendable (NSImage) -> Void)?
    var onFailure: (@Sendable (String) -> Void)?

    private let url: URL
    /// 30fps를 전부 디코드할 이유가 없다. 카메라 두 대면 초당 60장의 JPEG 디코딩인데,
    /// 화면에서는 그 차이가 보이지 않는다.
    private let minimumInterval: TimeInterval
    private var buffer = Data()
    private var lastDelivered = Date.distantPast
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var cancelled = false
    /// 몇 번째 응답인가. 첫 번째는 HTTP 응답이고, 그 뒤부터가 파트 머리다.
    private var responses = 0

    init(url: URL, framesPerSecond: Double = 15) {
        self.url = url
        minimumInterval = framesPerSecond > 0 ? 1 / framesPerSecond : 0
        super.init()
    }

    func start() {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        // 프레임 사이의 정적은 정상이다. 응답 자체는 끝나지 않으므로 리소스 타임아웃을 두지 않고,
        // 프레임이 끊긴 것은 요청 타임아웃으로만 잡는다.
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = .infinity
        configuration.waitsForConnectivity = false
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
        self.session = session
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let task = session.dataTask(with: request)
        self.task = task
        task.resume()
    }

    func cancel() {
        cancelled = true
        task?.cancel()
        session?.invalidateAndCancel()
        session = nil
        task = nil
    }

    // MARK: URLSessionDataDelegate

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        // HTTP 상태는 첫 응답에만 뜻이 있다. 그 뒤의 응답은 파트 머리이고, 서버가 이미
        // 200으로 스트림을 열어 준 상태다.
        if responses == 0 {
            guard let http = response as? HTTPURLResponse else {
                completionHandler(.cancel)
                report("카메라 응답이 HTTP가 아닙니다")
                return
            }
            guard http.statusCode == 200 else {
                completionHandler(.cancel)
                // 503은 카메라가 서버에 꽂혀 있지 않다는 뜻이다.
                report(http.statusCode == 503
                       ? "카메라가 서버에 연결되어 있지 않습니다"
                       : "카메라를 열지 못했습니다 (HTTP \(http.statusCode))")
                return
            }
        } else {
            flushPart()
        }
        responses += 1
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        buffer.append(data)
        // 경계가 그대로 넘어오는 경우. 넘어오지 않으면 아무것도 찾지 못하고 지나간다.
        if let latest = Self.extractFrames(from: &buffer).last {
            deliver(latest)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard !cancelled else { return }
        // 마지막 파트는 뒤에 오는 응답이 없으므로 여기서 내보낸다.
        flushPart()
        if let error, (error as NSError).code != NSURLErrorCancelled {
            report(SOArmClient.reason(for: error))
        } else if error == nil {
            report("카메라 스트림이 끊겼습니다")
        }
    }

    /// 지금까지 모인 한 파트를 프레임으로 내보낸다.
    private func flushPart() {
        guard !buffer.isEmpty else { return }
        let payload = Self.trimmedPart(buffer)
        buffer.removeAll(keepingCapacity: true)
        guard !payload.isEmpty else { return }
        deliver(payload)
    }

    private func deliver(_ jpeg: Data) {
        let now = Date()
        guard now.timeIntervalSince(lastDelivered) >= minimumInterval else { return }
        guard let image = NSImage(data: jpeg) else { return }
        lastDelivered = now
        onFrame?(image)
    }

    private func report(_ message: String) {
        guard !cancelled else { return }
        onFailure?(message)
    }

    // MARK: 파싱

    /// 서버는 프레임 뒤에 `\r\n`을 붙여 보낸다. 파트를 그대로 디코딩해도 대개 통과하지만,
    /// 남겨 두면 JPEG이 아닌 바이트가 이미지 데이터에 섞인 채로 넘어간다.
    static func trimmedPart(_ part: Data) -> Data {
        guard part.count >= 2, part.suffix(2).elementsEqual([0x0D, 0x0A]) else { return part }
        return part.dropLast(2)
    }

    /// 버퍼에서 완성된 프레임을 꺼내고, 꺼낸 만큼 버퍼를 줄인다.
    ///
    /// 프레임의 끝은 **다음 경계**로 정한다. 파트 헤더에 `Content-Length`가 없어서 길이를
    /// 미리 알 수 없고, JPEG 안에서 EOI 바이트를 찾는 방법은 프로토콜이 아니라 추측이기
    /// 때문이다. 그래서 마지막 프레임 하나는 다음 프레임이 오기 전까지 버퍼에 남는다.
    static func extractFrames(from buffer: inout Data) -> [Data] {
        var frames: [Data] = []
        while true {
            guard let start = buffer.range(of: boundary) else { break }
            guard let headerEnd = buffer.range(of: headerTerminator, in: start.upperBound..<buffer.endIndex) else { break }
            guard let next = buffer.range(of: boundary, in: headerEnd.upperBound..<buffer.endIndex) else { break }
            let payload = trimmedPart(Data(buffer[headerEnd.upperBound..<next.lowerBound]))
            if !payload.isEmpty { frames.append(payload) }
            buffer.removeSubrange(buffer.startIndex..<next.lowerBound)
        }
        // 경계도 파트 구분도 없이 계속 쌓이기만 한다면 우리가 아는 스트림이 아니다.
        // 한 프레임은 이 상한 근처에도 오지 않으므로 정상적인 파트를 버릴 위험은 없다.
        if buffer.count > bufferLimit { buffer.removeAll(keepingCapacity: false) }
        return frames
    }
}
