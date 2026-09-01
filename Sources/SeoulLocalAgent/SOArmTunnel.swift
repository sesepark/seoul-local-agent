import Foundation

/// 이 연결 전용 SSH 열쇠와 known_hosts.
///
/// 사용자의 `~/.ssh/id_ed25519`를 쓰지 않는 이유가 있다. macOS는 `~/.ssh`를 보호 폴더로
/// 다루므로, 전체 디스크 접근 권한이 없는 앱이 띄운 `ssh`는 그 열쇠 파일을 **읽지 못한다**.
/// 터미널에서는 열리는 접속이 앱에서만 `Permission denied (publickey)`로 끝나는 이유가
/// 이것이고, 코드를 아무리 봐도 보이지 않는다 — 같은 명령이 어디서 실행됐느냐로 갈린다.
///
/// 해결로 전체 디스크 접근을 요구할 수도 있었지만, 열쇠 파일 하나를 읽으려고 디스크 전체를
/// 내주는 것은 이 앱이 다른 곳에서 지켜 온 기준과 맞지 않는다. 대신 앱 자신의 폴더에 이
/// 연결에만 쓰는 열쇠를 두고 그것만 쓴다. 권한을 하나도 더 요구하지 않고, 서버에서 이 앱의
/// 접근만 따로 회수할 수 있다.
struct SOArmTunnelKey: Sendable {
    let directory: URL

    init(directory: URL? = nil) {
        self.directory = directory ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appending(path: "Library/Application Support/SeoulLocalAgent", directoryHint: .isDirectory)
    }

    var privateKey: URL { directory.appending(path: "soarm-tunnel-key") }
    var publicKey: URL { directory.appending(path: "soarm-tunnel-key.pub") }
    /// `~/.ssh/known_hosts`도 같은 이유로 읽을 수 없으므로 여기에 따로 쌓는다.
    var knownHosts: URL { directory.appending(path: "soarm-known-hosts") }

    var exists: Bool { FileManager.default.fileExists(atPath: privateKey.path) }

    var publicKeyText: String {
        (try? String(contentsOf: publicKey, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    /// 서버에 이 열쇠를 등록하는 명령. 사용자가 한 번 실행한다.
    func authorizationCommand(for server: SOArmServer) -> String {
        let port = server.sshPort == 22 ? "" : "-p \(server.sshPort) "
        return "ssh-copy-id \(port)-i '\(publicKey.path)' \(server.sshTarget)"
    }

    /// 없으면 만든다. 암호는 걸지 않는다 — 앱은 암호를 물을 창이 없고, 이 열쇠의 힘은
    /// 서버의 `authorized_keys`에서 언제든 지울 수 있다는 데 있다.
    @discardableResult
    func ensureExists() throws -> Bool {
        if exists { return false }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // 반쯤 만들어진 쌍이 남아 있으면 ssh-keygen이 덮어쓰기를 물어보다 멈춘다.
        try? FileManager.default.removeItem(at: publicKey)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
        process.arguments = [
            "-t", "ed25519", "-N", "", "-q",
            "-C", "seoul-local-agent-soarm",
            "-f", privateKey.path,
        ]
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw SOArmError.tunnelFailed("열쇠를 만들지 못했습니다: \(error.localizedDescription)")
        }
        let detail = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        guard process.terminationStatus == 0, exists else {
            throw SOArmError.tunnelFailed("열쇠를 만들지 못했습니다: \(detail.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        return true
    }
}

/// SO-ARM 콘솔로 가는 SSH 로컬 포워딩 하나를 소유한다.
///
/// 서버 API에는 인증이 없다. 그래서 콘솔은 `127.0.0.1`에만 bind되어 있고, 이 터널이 곧
/// 신뢰 경계다. 앱은 서버를 LAN에 여는 방법을 제공하지 않는다.
///
/// ## 이 프로세스는 반드시 죽는다
///
/// 이 앱의 다른 상주 헬퍼(`MattingDaemon`, `MediaDaemon`)와 같은 규칙을 따른다. 하나에
/// 기대지 않고 겹쳐 둔다.
///
/// 1. **stdin EOF.** `-N` 대신 원격에서 `cat > /dev/null`을 돌리고 stdin을 파이프로 물린다.
///    앱이 `SIGKILL`로 죽어도 커널이 쓰기 끝을 닫아 주므로 ssh가 EOF를 읽고 스스로 빠진다.
///    `-N`은 stdin을 아예 읽지 않아 이 보호가 없다.
/// 2. **명시적 종료.** 화면을 떠나거나(도는 모드가 없을 때) 앱이 끝날 때 `shutdownNow()`.
/// 3. **프로세스 트리 정리.** `ActiveProcessRegistry`에 등록해 두어 종료 시 함께 정리된다.
/// 4. **다음 실행의 청소.** 명령줄에 고정 마커를 심어, 앱이 강제 종료된 뒤 launchd에
///    입양된 터널을 다음 실행이 찾아 죽인다.
/// 5. **끊긴 링크의 자멸.** `ServerAliveInterval`/`ServerAliveCountMax`.
final class SOArmTunnel: @unchecked Sendable {
    static let shared = SOArmTunnel()

    /// 원격에서는 주석이고, 로컬 `ps` 출력에는 남는다. 남은 터널을 찾는 유일한 표식이다.
    static let marker = "seoul-local-agent-soarm-tunnel"

    private let lock = NSLock()
    private var process: Process?
    /// 쓰기 끝을 살려 둬야 원격 `cat`이 계속 돈다. 이걸 놓으면 즉시 EOF가 간다.
    private var input: Pipe?
    private var errorTail = ""
    /// 몇 번째 터널인가. 화면을 떠날 때 예약된 정리가, 그 사이에 새로 열린 터널을 대신
    /// 죽이는 일이 없도록 대상을 못 박는 데 쓴다.
    private var generation = 0
    /// 마지막으로 실제로 열린 주소. 다음 연결은 이것부터 시도한다.
    ///
    /// 앱이 도는 동안에만 기억한다. 파일에 남기지 않는 이유는, 집과 밖을 오갈 때마다
    /// 설정 파일이 조용히 고쳐지는 것이 사용자가 적어 둔 순서를 흐리기 때문이다.
    private var lastGoodHost: String?

    private init() {}

    /// 지금 열려 있는 터널을 가리키는 표. 나중에 이 표를 들고 와야만 그 터널을 내릴 수 있다.
    var token: Int {
        lock.lock()
        defer { lock.unlock() }
        return generation
    }

    var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return process?.isRunning == true
    }

    /// 마지막으로 ssh가 내놓은 오류. 인증 실패나 known_hosts 문제를 그대로 보여 준다.
    ///
    /// 처음 접속에서 host key를 받아 적었다는 알림은 오류가 아니므로 걸러 낸다. 실패 문구
    /// 맨 앞에 그 줄이 붙어 있으면 읽는 사람은 그것을 실패의 원인으로 읽는다.
    var lastError: String {
        lock.lock()
        defer { lock.unlock() }
        return errorTail
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.contains("Permanently added") }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 지금 붙어 있는 주소. 붙어 있지 않으면 `nil`.
    var connectedHost: String? {
        lock.lock()
        defer { lock.unlock() }
        return process?.isRunning == true ? lastGoodHost : nil
    }

    static func arguments(
        for server: SOArmServer, host: String, key: SOArmTunnelKey = SOArmTunnelKey()
    ) -> [String] {
        let server = server.sanitised()
        return [
            // 원격에 tty를 만들지 않는다. 명령 하나만 돌리면 되고, tty가 붙으면 종료 신호가
            // 셸에 먹힌다.
            "-T",
            // 열쇠가 준비돼 있지 않으면 암호를 물으며 멈추는 대신 즉시 실패한다. 창 없는
            // 자식 프로세스의 프롬프트는 아무도 볼 수 없다.
            "-o", "BatchMode=yes",
            // 주소가 여럿이면 짧게 끊는다. 집 주소는 밖에서 응답이 오지 않고 시간만
            // 쓰는데, 그 시간이 길면 다음 주소를 시도하기까지 화면이 그만큼 비어 있다.
            "-o", "ConnectTimeout=\(server.candidateHosts.count > 1 ? 4 : 8)",
            // 포워딩을 못 열면 붙어 있어 봐야 소용없다. 조용히 성공한 척하지 않는다.
            "-o", "ExitOnForwardFailure=yes",
            "-o", "ServerAliveInterval=15",
            "-o", "ServerAliveCountMax=3",
            // 이 앱의 열쇠만 쓴다. `~/.ssh`는 보호 폴더라 앱이 읽을 수 없고, 읽지도 못할
            // 열쇠를 시도하다 실패하는 것이 `Permission denied (publickey)`의 정체였다.
            "-i", key.privateKey.path,
            "-o", "IdentitiesOnly=yes",
            // known_hosts도 같은 이유로 앱 폴더에 둔다. 처음 본 서버는 받아 적고 그 뒤로는
            // 고정되므로, 중간에 host key가 바뀌면 그때는 멈춘다.
            "-o", "UserKnownHostsFile=\(key.knownHosts.path)",
            "-o", "StrictHostKeyChecking=accept-new",
            "-p", String(server.sshPort),
            "-L", "127.0.0.1:\(server.localPort):127.0.0.1:\(server.remotePort)",
            server.sshTarget(host: host),
            "cat > /dev/null # \(marker)",
        ]
    }

    /// 이미 열려 있으면 아무것도 하지 않는다.
    ///
    /// 먼저 로컬 포트를 찔러 보는 이유: 사용자가 터미널에서 직접 터널을 열어 둔 채 앱을 켰을
    /// 때 두 번째 ssh가 `ExitOnForwardFailure`로 실패하며 "연결 실패"라고 말하게 되는데,
    /// 정작 콘솔은 멀쩡히 닿는 상태다.
    func ensureConnected(server: SOArmServer, key: SOArmTunnelKey = SOArmTunnelKey()) async throws {
        if await Self.probe(server.baseURL) { return }
        guard server.isConfigured else { throw SOArmError.notConfigured }
        try key.ensureExists()

        // 살아는 있는데 닿지 않는 터널은 죽은 터널이다. 새로 연다.
        if isRunning { shutdownNow() }

        // 적어 둔 주소를 순서대로 시도한다. 지난번에 열린 주소가 있으면 그것부터 —
        // 집과 밖을 오갈 때 매번 닿지 않는 주소의 시간 초과를 먼저 기다릴 이유가 없다.
        var failures: [(host: String, reason: String)] = []
        for host in candidates(for: server) {
            try start(server: server, host: host, key: key)
            var opened = false
            // ssh가 포워딩을 세우는 데 걸리는 시간만큼 기다린다.
            for _ in 0..<40 {
                if await Self.probe(server.baseURL) { opened = true; break }
                if !isRunning { break }
                try? await Task.sleep(for: .milliseconds(250))
            }
            if opened {
                remember(host)
                return
            }
            let detail = lastError
            shutdownNow()
            failures.append((host, detail.isEmpty ? "응답이 없었습니다" : detail))
        }

        throw SOArmError.tunnelFailed(Self.failureText(failures, server: server, key: key))
    }

    /// `NSLock`은 비동기 문맥에서 직접 잡을 수 없다(중간에 다른 스레드로 넘어갈 수 있어서).
    /// 잠그고 곧바로 푸는 이런 자리는 동기 함수로 감싼다.
    private func remember(_ host: String) {
        lock.lock()
        lastGoodHost = host
        lock.unlock()
    }

    /// 시도할 순서. 지난번에 열린 주소가 맨 앞으로 온다.
    private func candidates(for server: SOArmServer) -> [String] {
        let hosts = server.sanitised().candidateHosts
        lock.lock()
        let remembered = lastGoodHost
        lock.unlock()
        guard let remembered, hosts.contains(remembered) else { return hosts }
        return [remembered] + hosts.filter { $0 != remembered }
    }

    /// 주소가 여럿이면 어느 쪽이 왜 안 됐는지를 각각 적는다. 하나로 뭉뚱그리면 집에서
    /// 안 되는 것인지 밖에서 안 되는 것인지 읽을 수 없다.
    static func failureText(
        _ failures: [(host: String, reason: String)], server: SOArmServer, key: SOArmTunnelKey
    ) -> String {
        guard let first = failures.first else { return "연결할 주소가 없습니다" }
        if failures.count == 1 {
            return hint(for: first.reason, server: server, key: key)
        }
        let lines = failures.map { "· \($0.host): \($0.reason.split(separator: "\n").last.map(String.init) ?? $0.reason)" }
        return "적어 둔 주소 어느 쪽으로도 닿지 못했습니다.\n"
            + lines.joined(separator: "\n")
            + "\n"
            + hint(for: first.reason, server: server, key: key)
    }

    private func start(server: SOArmServer, host: String, key: SOArmTunnelKey) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = Self.arguments(for: server, host: host, key: key)
        let input = Pipe()
        let errors = Pipe()
        process.standardInput = input
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errors
        errors.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty, let self else { return }
            self.lock.lock()
            self.errorTail = String(self.errorTail.suffix(400)) + String(decoding: chunk, as: UTF8.self)
            self.lock.unlock()
        }
        do {
            try process.run()
        } catch {
            throw SOArmError.tunnelFailed(error.localizedDescription)
        }
        ActiveProcessRegistry.shared.add(process)
        lock.lock()
        self.process = process
        self.input = input
        errorTail = ""
        generation += 1
        lock.unlock()
    }

    /// 닫기 → 종료 → 죽이기. 돌아왔을 때 프로세스가 없는 것이 보장되어야 하므로
    /// `applicationWillTerminate`에서 부를 수 있도록 동기다.
    ///
    /// `token`을 주면 그 표가 가리키는 터널일 때만 내린다. 표 없이 부르면 무엇이 열려 있든
    /// 내린다 — 앱을 끝낼 때는 그것이 맞는 답이다.
    func shutdownNow(token: Int? = nil) {
        lock.lock()
        if let token, token != generation {
            lock.unlock()
            return
        }
        let process = self.process
        let input = self.input
        self.process = nil
        self.input = nil
        lock.unlock()

        guard let process else { return }
        (process.standardError as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        // 1. stdin을 닫으면 원격 `cat`이 EOF를 보고 끝나고 세션이 정상적으로 내려간다.
        try? input?.fileHandleForWriting.close()
        if Self.wait(for: process, seconds: 1.5) {
            ActiveProcessRegistry.shared.remove(process)
            return
        }
        // 2. 그래도 남아 있으면 신호를 보낸다.
        if process.isRunning { process.terminate() }
        if Self.wait(for: process, seconds: 2) {
            ActiveProcessRegistry.shared.remove(process)
            return
        }
        // 3. 마지막. 여기까지 오면 ssh가 신호를 무시하고 있다는 뜻이다.
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        _ = Self.wait(for: process, seconds: 1)
        ActiveProcessRegistry.shared.remove(process)
    }

    private static func wait(for process: Process, seconds: Double) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while process.isRunning, Date() < deadline { usleep(50_000) }
        return !process.isRunning
    }

    /// ssh가 내놓은 원문에 무엇을 해야 하는지를 한 줄 덧붙인다.
    ///
    /// 원문을 지우지 않는 이유는 그것이 가장 정확하기 때문이고, 덧붙이는 이유는 원문만으로는
    /// 무엇을 고쳐야 하는지 알 수 없기 때문이다. 특히 `Permission denied (publickey)`는
    /// 이 기능을 처음 켤 때 거의 반드시 한 번 만나는 상태다 — 앱은 암호를 묻지 않으므로
    /// 공개키가 서버에 등록되어 있어야 한다.
    static func hint(for stderr: String, server: SOArmServer, key: SOArmTunnelKey = SOArmTunnelKey()) -> String {
        if stderr.contains("Permission denied") {
            // 사용자의 평소 열쇠가 아니라 **이 앱의 열쇠**를 등록해야 한다. 앱은 `~/.ssh`를
            // 읽을 수 없으므로 터미널에서 되는 접속이 여기서는 되지 않는다.
            return "\(stderr)\n이 앱 전용 공개키가 서버에 등록되어 있지 않습니다. 터미널에서 아래를 한 번 실행하세요 (설정 › 로봇에서 복사할 수 있습니다):\n\(key.authorizationCommand(for: server))"
        }
        if stderr.contains("Host key verification failed") {
            return "\(stderr)\n서버의 host key가 처음 본 것과 달라졌습니다. 서버를 다시 설치한 것이 맞다면 \(key.knownHosts.lastPathComponent) 파일에서 해당 줄을 지우고 다시 시도하세요."
        }
        if stderr.contains("Could not resolve hostname") {
            return "\(stderr)\n설정 › 로봇의 주소를 확인하세요."
        }
        if stderr.contains("No route to host") || stderr.contains("Operation timed out") {
            let common = "\(stderr)\n서버가 켜져 있고 같은 네트워크에 있는지 확인하세요. 처음이라면 macOS의 로컬 네트워크 접근 허용을 묻는 창이 떴는지도 보세요."
            if server.candidateHosts.count < 2 {
                return common + "\n집 밖에서도 쓰려면 설정 › 로봇의 `집 밖에서 쓸 주소`에 Tailscale 주소를 넣으세요."
            }
            return common + "\n집 밖이라면 Tailscale이 이 Mac과 서버 양쪽에서 돌고 있는지도 확인하세요."
        }
        if stderr.contains("Address already in use") || stderr.contains("bind") {
            return "\(stderr)\n이 Mac의 \(server.localPort) 포트를 이미 다른 것이 쓰고 있습니다. 설정 › 로봇에서 `이 Mac에서 열 포트`를 바꾸세요."
        }
        return stderr
    }

    /// 콘솔이 이 포트에서 실제로 대답하는가. 포트가 열려 있는지가 아니라 콘솔인지를 본다.
    static func probe(_ baseURL: URL) async -> Bool {
        var request = URLRequest(url: baseURL.appending(path: "api/status"))
        request.timeoutInterval = 2
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 2
        configuration.waitsForConnectivity = false
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return false }
        return (try? JSONSerialization.jsonObject(with: data)) is [String: Any]
    }
}
