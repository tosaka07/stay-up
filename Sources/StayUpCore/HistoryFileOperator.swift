import Foundation

/// 履歴ロジックから POSIX ファイル操作を分離する境界。
protocol HistoryFileOperating: Sendable {
    func append(_ data: Data, to url: URL) -> Bool
    func removeItem(at url: URL) -> Bool
}

final class POSIXHistoryFileOperator: HistoryFileOperating, @unchecked Sendable {
    func append(_ data: Data, to url: URL) -> Bool {
        let path = url.path(percentEncoded: false)
        let fd = open(path, O_WRONLY | O_APPEND | O_CREAT, 0o600)
        guard fd >= 0 else { return false }
        defer { close(fd) }

        return data.withUnsafeBytes { buffer -> Bool in
            guard let base = buffer.baseAddress else { return false }
            // O_APPEND への 1 回の write は追記位置がアトミックに決まる。
            let written = write(fd, base, buffer.count)
            return written == buffer.count
        }
    }

    func removeItem(at url: URL) -> Bool {
        do {
            try FileManager.default.removeItem(at: url)
            return true
        } catch {
            return false
        }
    }
}
