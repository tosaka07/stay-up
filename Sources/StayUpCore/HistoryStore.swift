import Foundation

/// 履歴に記録するイベント（spec §11.2）。
///
/// `renew` は高頻度なので**行を書かない**。更新回数は `release` 行に集約する。
public struct HistoryEvent: Sendable, Codable, Equatable {
    public enum Kind: String, Sendable, Codable {
        case acquire
        case release
        case suppressionStarted
        case suppressionEnded
        case globalStop
        case helperError
        case orphanDetected
    }

    public var ts: Date
    public var v: Int
    public var event: Kind
    public var id: LeaseID?
    public var client: String?
    /// `interactive` / `external`
    public var kind: String?
    public var pid: pid_t?
    public var label: String?
    public var ttl: Int?
    public var binding: String?
    public var reason: String?
    public var duration: Int?
    public var renewCount: Int?
    public var leaseCount: Int?
    public var detail: String?

    public init(
        ts: Date = Date(),
        event: Kind,
        id: LeaseID? = nil,
        client: String? = nil,
        kind: String? = nil,
        pid: pid_t? = nil,
        label: String? = nil,
        ttl: Int? = nil,
        binding: String? = nil,
        reason: String? = nil,
        duration: Int? = nil,
        renewCount: Int? = nil,
        leaseCount: Int? = nil,
        detail: String? = nil
    ) {
        self.ts = ts
        self.v = ControlProtocol.version
        self.event = event
        self.id = id
        self.client = client
        self.kind = kind
        self.pid = pid
        self.label = label
        self.ttl = ttl
        self.binding = binding
        self.reason = reason
        self.duration = duration
        self.renewCount = renewCount
        self.leaseCount = leaseCount
        self.detail = detail
    }

    public static func acquired(_ lease: Lease, at now: Date = Date()) -> HistoryEvent {
        HistoryEvent(
            ts: now,
            event: .acquire,
            id: lease.id,
            client: lease.client.name,
            kind: lease.client.isInteractive ? "interactive" : "external",
            pid: lease.client.pid,
            label: lease.label,
            ttl: lease.expiresAt.map { Int($0.timeIntervalSince(lease.acquiredAt).rounded()) },
            binding: lease.binding?.displayText
        )
    }

    public static func released(
        _ lease: Lease,
        reason: ReleaseReason,
        at now: Date = Date()
    ) -> HistoryEvent {
        HistoryEvent(
            ts: now,
            event: .release,
            id: lease.id,
            client: lease.client.name,
            reason: reason.rawValue,
            duration: lease.durationSeconds(at: now),
            renewCount: lease.renewCount
        )
    }
}

/// 追記専用の JSONL 履歴（spec §11.2 / §11.3）。
///
/// 書き手はアプリ本体のみなので、ロックを持たない。
/// 追記は `O_APPEND` で開いた fd への 1 回の `write(2)` にまとめ、
/// 読み取り側は壊れた行を読み飛ばす。
public final class HistoryStore: @unchecked Sendable {
    private let directory: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let fileOperator: any HistoryFileOperating
    private let lock = NSLock()

    public convenience init(directory: URL = StayUpPaths.historyDirectory) {
        self.init(directory: directory, fileOperator: POSIXHistoryFileOperator())
    }

    init(directory: URL, fileOperator: any HistoryFileOperating) {
        self.directory = directory
        self.encoder = ControlCoding.makeEncoder()
        self.decoder = ControlCoding.makeDecoder()
        self.fileOperator = fileOperator
    }

    /// `history/YYYY-MM.jsonl`
    public func fileURL(for date: Date) -> URL {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let year = calendar.component(.year, from: date)
        let month = calendar.component(.month, from: date)
        let name = String(format: "%04d-%02d.jsonl", year, month)
        return directory.appending(path: name)
    }

    /// 1 イベントを追記する。失敗しても呼び出し元を止めない（spec §10）。
    @discardableResult
    public func append(_ event: HistoryEvent) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            var line = try encoder.encode(event)
            // JSONEncoder は文字列内の改行をエスケープするため、JSON 自体に生改行は含まれない。
            line.append(0x0A)

            let url = fileURL(for: event.ts)
            return fileOperator.append(line, to: url)
        } catch {
            return false
        }
    }

    /// 新しい順にイベントを読む。壊れた行は読み飛ばす（spec §11.3）。
    public func recentEvents(limit: Int, now: Date = Date()) -> [HistoryEvent] {
        lock.lock()
        defer { lock.unlock() }

        guard limit > 0 else { return [] }
        var result: [HistoryEvent] = []
        for url in monthFilesNewestFirst() {
            guard let content = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let lines = content.split(separator: "\n", omittingEmptySubsequences: true)
            for line in lines.reversed() {
                guard let data = line.data(using: .utf8),
                      let event = try? decoder.decode(HistoryEvent.self, from: data)
                else {
                    continue // 途中で切れた行・未知の形式は無視する
                }
                result.append(event)
                if result.count >= limit { return result }
            }
        }
        return result
    }

    /// 新しい順の月次ファイル一覧。
    public func monthFilesNewestFirst() -> [URL] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )) ?? []
        return urls
            .filter { $0.pathExtension == "jsonl" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    /// 保持期限を過ぎた月次ファイルを削除する。ファイル単位なので安価（spec §11.4）。
    @discardableResult
    public func pruneOldFiles(retentionDays: Int, now: Date = Date()) -> Int {
        lock.lock()
        defer { lock.unlock() }

        guard retentionDays > 0 else { return 0 }
        let cutoff = now.addingTimeInterval(-Double(retentionDays) * 86400)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let cutoffYear = calendar.component(.year, from: cutoff)
        let cutoffMonth = calendar.component(.month, from: cutoff)
        let cutoffName = String(format: "%04d-%02d", cutoffYear, cutoffMonth)

        var removed = 0
        for url in monthFilesNewestFirst() {
            let stem = url.deletingPathExtension().lastPathComponent
            // 月境界より前のファイルだけを消す。当月分は必ず残る。
            if stem < cutoffName, fileOperator.removeItem(at: url) {
                removed += 1
            }
        }
        return removed
    }
}
