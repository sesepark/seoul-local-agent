import Foundation

/// Every local file this app owns holds personal data, so it is written with
/// owner-only permissions from the moment it is created rather than being
/// relaxed for the window between `write` and a later `chmod`. The write is
/// staged through a temporary file so a crash or a full disk can never leave a
/// truncated state file, preference file, or transcript archive behind.
enum LocalFileStorage {
    static func write(_ data: Data, to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw AgentError.processFailed("폴더를 만들지 못했습니다 [\(directory.path)]: \(error.localizedDescription)")
        }
        let temporary = directory.appending(path: ".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        guard FileManager.default.createFile(atPath: temporary.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw AgentError.processFailed("파일을 쓰지 못했습니다 [\(url.path)]")
        }
        do {
            if FileManager.default.fileExists(atPath: url.path) {
                _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
            } else {
                try FileManager.default.moveItem(at: temporary, to: url)
            }
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw AgentError.processFailed("파일을 교체하지 못했습니다 [\(url.path)]: \(error.localizedDescription)")
        }
        // `replaceItemAt` can carry the previous file's permissions forward.
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
