import Foundation
import StayUpCore

/// バインド対象の生存確認（spec §7.3）。
///
/// PID は `kill(pid, 0)`、ファイルは存在確認、プロセス名は `pgrep` 相当で判定する。
public struct ProcessWatcher: Sendable {
    public init() {}

    /// バインド対象がまだ生きているか。
    public func isAlive(_ binding: LeaseBinding) -> Bool {
        switch binding {
        case .pid(let pid):
            isProcessAlive(pid)
        case .leaseFile(let path):
            FileManager.default.fileExists(atPath: path)
        case .processName(let name):
            !pids(forProcessNamed: name).isEmpty
        }
    }

    /// シグナル 0 は「送れるか確かめるだけ」。存在すれば成功、いなければ ESRCH。
    public func isProcessAlive(_ pid: pid_t) -> Bool {
        guard pid > 0 else { return false }
        if kill(pid, 0) == 0 { return true }
        // EPERM = 他ユーザーのプロセスだが、存在はしている
        return errno == EPERM
    }

    /// 名前でマッチするプロセスの PID 一覧。
    public func pids(forProcessNamed name: String) -> [pid_t] {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/pgrep")
        process.arguments = ["-x", name]
        process.environment = [:]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard let output = String(data: data, encoding: .utf8) else { return [] }
            return output.split(separator: "\n").compactMap { pid_t($0.trimmingCharacters(in: .whitespaces)) }
        } catch {
            return []
        }
    }
}

/// PID の終了を待って通知する。ポーリングせず `kqueue` の `NOTE_EXIT` で拾う。
public final class ProcessExitObserver: @unchecked Sendable {
    private let lock = NSLock()
    private var sources: [pid_t: DispatchSourceProcess] = [:]

    public init() {}

    /// 監視を始める。対象が既に死んでいれば false を返し、監視は登録しない。
    @discardableResult
    public func observe(pid: pid_t, onExit: @escaping @Sendable (pid_t) -> Void) -> Bool {
        guard ProcessWatcher().isProcessAlive(pid) else { return false }

        lock.lock()
        defer { lock.unlock() }
        guard sources[pid] == nil else { return true }

        let source = DispatchSource.makeProcessSource(
            identifier: pid,
            eventMask: .exit,
            queue: .global(qos: .utility)
        )
        source.setEventHandler { [weak self] in
            self?.cancel(pid: pid)
            onExit(pid)
        }
        source.resume()
        sources[pid] = source
        return true
    }

    public func cancel(pid: pid_t) {
        lock.lock()
        let source = sources.removeValue(forKey: pid)
        lock.unlock()
        source?.cancel()
    }

    public func cancelAll() {
        lock.lock()
        let all = sources.values
        sources.removeAll()
        lock.unlock()
        for source in all { source.cancel() }
    }
}
