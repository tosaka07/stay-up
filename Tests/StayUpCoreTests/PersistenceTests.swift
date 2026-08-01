import Foundation
import Testing

@testable import StayUpCore

/// テストごとに使い捨てのディレクトリを用意する。
private func withTempDirectory<T>(_ body: (URL) throws -> T) rethrows -> T {
    let url = URL(filePath: NSTemporaryDirectory())
        .appending(path: "stayup-tests-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: url) }
    return try body(url)
}

private final class FakeHistoryFileOperator: HistoryFileOperating, @unchecked Sendable {
    var appendResult = true
    var removeResult = true

    func append(_ data: Data, to url: URL) -> Bool {
        appendResult
    }

    func removeItem(at url: URL) -> Bool {
        removeResult
    }
}

@Suite("JSONL 履歴ストア")
struct HistoryStoreTests {
    @Test("追記したイベントを新しい順に読み戻せる")
    func appendAndRead() {
        withTempDirectory { dir in
            let store = HistoryStore(directory: dir)
            let lease = Lease(client: .external(name: "build", pid: 100), label: "test")

            #expect(store.append(.acquired(lease)))
            #expect(store.append(.released(lease, reason: .explicit)))

            let events = store.recentEvents(limit: 10)
            #expect(events.count == 2)
            // 新しい順
            #expect(events[0].event == .release)
            #expect(events[1].event == .acquire)
            #expect(events[1].client == "build")
        }
    }

    @Test("月次ファイルに分かれて書かれる")
    func monthlyRotation() {
        withTempDirectory { dir in
            let store = HistoryStore(directory: dir)
            let june = Date(timeIntervalSince1970: 1_750_000_000)  // 2025-06
            let july = Date(timeIntervalSince1970: 1_753_000_000)  // 2025-07

            #expect(store.append(HistoryEvent(ts: june, event: .suppressionStarted)))
            #expect(store.append(HistoryEvent(ts: july, event: .suppressionEnded)))

            let files = store.monthFilesNewestFirst()
            #expect(files.count == 2)
            // 新しい順に並ぶ
            #expect(files[0].lastPathComponent > files[1].lastPathComponent)
        }
    }

    @Test("途中で切れた行は読み飛ばし、それ以前の行は有効に読む")
    func skipsTornLine() throws {
        try withTempDirectory { dir in
            let store = HistoryStore(directory: dir)
            let lease = Lease(client: .interactive(trigger: .menuBar), label: "manual")
            #expect(store.append(.acquired(lease)))

            // 電源断で末尾が欠けた状況を再現する
            let file = store.fileURL(for: Date())
            let handle = try FileHandle(forWritingTo: file)
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(#"{"ts":"2026-07-2"#.utf8))
            try handle.close()

            let events = store.recentEvents(limit: 10)
            #expect(events.count == 1)
            #expect(events[0].event == .acquire)
        }
    }

    @Test("読み取れない月次項目と履歴以外のファイルは無視する")
    func skipsUnreadableAndUnrelatedEntries() throws {
        try withTempDirectory { dir in
            let store = HistoryStore(directory: dir)
            try Data("not history".utf8).write(to: dir.appending(path: "README.txt"))
            try FileManager.default.createDirectory(
                at: dir.appending(path: "9999-12.jsonl"),
                withIntermediateDirectories: false
            )

            #expect(store.monthFilesNewestFirst().map(\.lastPathComponent) == ["9999-12.jsonl"])
            #expect(store.recentEvents(limit: 10).isEmpty)
        }
    }

    @Test("指定件数に達したら読み取りを打ち切り、0件指定では何も返さない")
    func respectsReadLimit() {
        withTempDirectory { dir in
            let store = HistoryStore(directory: dir)
            #expect(store.append(HistoryEvent(event: .suppressionStarted)))
            #expect(store.append(HistoryEvent(event: .suppressionEnded)))

            #expect(store.recentEvents(limit: 1).count == 1)
            #expect(store.recentEvents(limit: 0).isEmpty)
        }
    }

    @Test("追記先を開けない場合とディレクトリを作れない場合は false")
    func appendFailures() throws {
        try withTempDirectory { dir in
            let blockedMonth = HistoryStore(directory: dir)
                .fileURL(for: Date())
            try FileManager.default.createDirectory(
                at: blockedMonth,
                withIntermediateDirectories: false
            )
            #expect(!HistoryStore(directory: dir).append(HistoryEvent(event: .helperError)))

            let fileInsteadOfDirectory = dir.appending(path: "plain-file")
            try Data().write(to: fileInsteadOfDirectory)
            #expect(!HistoryStore(directory: fileInsteadOfDirectory).append(
                HistoryEvent(event: .helperError)
            ))
        }
    }

    @Test("ファイルアダプタの追記失敗を呼び出し元へ返す")
    func propagatesAppendFailure() {
        withTempDirectory { dir in
            let fileOperator = FakeHistoryFileOperator()
            fileOperator.appendResult = false
            let store = HistoryStore(directory: dir, fileOperator: fileOperator)

            #expect(!store.append(HistoryEvent(event: .helperError)))
        }
    }

    @Test("存在しない履歴ディレクトリは空として扱う")
    func missingDirectoryIsEmpty() {
        withTempDirectory { dir in
            let missing = dir.appending(path: "missing")
            let store = HistoryStore(directory: missing)
            #expect(store.monthFilesNewestFirst().isEmpty)
            #expect(store.recentEvents(limit: 10).isEmpty)
        }
    }

    @Test("保持期限を過ぎた月次ファイルだけを削除する")
    func prunesOldFiles() {
        withTempDirectory { dir in
            let store = HistoryStore(directory: dir)
            let now = Date(timeIntervalSince1970: 1_753_000_000)  // 2025-07
            let old = Date(timeIntervalSince1970: 1_700_000_000)  // 2023-11

            #expect(store.append(HistoryEvent(ts: old, event: .suppressionStarted)))
            #expect(store.append(HistoryEvent(ts: now, event: .suppressionStarted)))
            #expect(store.monthFilesNewestFirst().count == 2)

            let removed = store.pruneOldFiles(retentionDays: 30, now: now)
            #expect(removed == 1)
            // 当月分は必ず残る
            #expect(store.monthFilesNewestFirst().count == 1)
        }
    }

    @Test("保持日数が0以下なら削除しない")
    func ignoresInvalidRetention() {
        withTempDirectory { dir in
            let store = HistoryStore(directory: dir)
            #expect(store.append(HistoryEvent(event: .suppressionStarted)))
            #expect(store.pruneOldFiles(retentionDays: 0) == 0)
            #expect(store.pruneOldFiles(retentionDays: -1) == 0)
            #expect(store.monthFilesNewestFirst().count == 1)
        }
    }

    @Test("古い履歴の削除に失敗した場合は削除件数へ含めない")
    func ignoresRemoveFailure() throws {
        try withTempDirectory { dir in
            let oldURL = dir.appending(path: "2000-01.jsonl")
            try Data().write(to: oldURL)
            let fileOperator = FakeHistoryFileOperator()
            fileOperator.removeResult = false
            let store = HistoryStore(directory: dir, fileOperator: fileOperator)

            #expect(store.pruneOldFiles(retentionDays: 1, now: Date()) == 0)
            #expect(FileManager.default.fileExists(atPath: oldURL.path()))
        }
    }

    @Test("renew は行を書かず、更新回数は release 行に集約される")
    func renewIsNotLogged() {
        withTempDirectory { dir in
            let store = HistoryStore(directory: dir)
            var lease = Lease(client: .external(name: "tool", pid: 1), label: "x")
            store.append(.acquired(lease))

            lease.renewCount = 14  // renew を 14 回受けたとする（行は書かれない）
            store.append(.released(lease, reason: .ttlExpired))

            let events = store.recentEvents(limit: 10)
            #expect(events.count == 2)
            #expect(events[0].renewCount == 14)
        }
    }
}

@Suite("state.json ストア")
struct StateStoreTests {
    @Test("保存した台帳を読み戻せる")
    func roundTrip() {
        withTempDirectory { dir in
            let store = StateStore(fileURL: dir.appending(path: "state.json"))
            let lease = Lease(client: .external(name: "build", pid: 42), label: "test")
            let state = PersistedState(leases: [lease], disableSleepSetAt: Date())

            #expect(store.save(state))
            let loaded = store.load()
            #expect(loaded?.leases.count == 1)
            #expect(loaded?.leases.first?.client == .external(name: "build", pid: 42))
        }
    }

    @Test("壊れたファイルは nil を返す（存在はする）")
    func corruptedFile() throws {
        try withTempDirectory { dir in
            let url = dir.appending(path: "state.json")
            try Data("{ not json".utf8).write(to: url)

            let store = StateStore(fileURL: url)
            #expect(store.fileExists)
            #expect(store.load() == nil)
        }
    }

    @Test("不在のファイルも nil を返す")
    func missingFile() {
        withTempDirectory { dir in
            let store = StateStore(fileURL: dir.appending(path: "nope.json"))
            #expect(!store.fileExists)
            #expect(store.load() == nil)
        }
    }

    @Test("保存先ディレクトリを作れない場合は false")
    func saveFailure() throws {
        try withTempDirectory { dir in
            let fileInsteadOfDirectory = dir.appending(path: "plain-file")
            try Data().write(to: fileInsteadOfDirectory)
            let store = StateStore(fileURL: fileInsteadOfDirectory.appending(path: "state.json"))

            #expect(!store.save(.empty))
        }
    }

    @Test("clear は空の状態を保存する")
    func clear() {
        withTempDirectory { dir in
            let store = StateStore(fileURL: dir.appending(path: "state.json"))
            let lease = Lease(client: .interactive(trigger: .window), label: "manual")
            #expect(store.save(PersistedState(leases: [lease], disableSleepSetAt: Date())))

            #expect(store.clear())
            #expect(store.load()?.leases.isEmpty == true)
            #expect(store.load()?.disableSleepSetAt == nil)
        }
    }
}

@Suite("Lease モデル")
struct LeaseTests {
    @Test("LeaseID は生成順に辞書順で並ぶ")
    func leaseIDOrdering() {
        let earlier = LeaseID.generate(now: Date(timeIntervalSince1970: 1_000_000))
        let later = LeaseID.generate(now: Date(timeIntervalSince1970: 2_000_000))
        #expect(earlier.rawValue < later.rawValue)
        #expect(earlier.rawValue.count == 26)
    }

    @Test("TTL の失効判定")
    func expiry() {
        let now = Date()
        var lease = Lease(client: .interactive(trigger: .menuBar), label: "x", acquiredAt: now)
        #expect(!lease.isExpired(at: now.addingTimeInterval(10_000)))  // 無期限

        lease.expiresAt = now.addingTimeInterval(60)
        #expect(!lease.isExpired(at: now))
        #expect(lease.isExpired(at: now.addingTimeInterval(61)))
        #expect(lease.remainingSeconds(at: now) == 60)
    }

    @Test("外部クライアントの TTL は上限で切り詰められる")
    func ttlClamping() {
        let settings = Settings(defaultClientLeaseTTLSeconds: 1800, maxClientLeaseTTLSeconds: 7200)

        // 無期限要求は既定値ではなく上限まで詰められる
        #expect(settings.clampedTTL(requested: nil, isInteractive: false) == 1800)
        #expect(settings.clampedTTL(requested: 999_999, isInteractive: false) == 7200)
        #expect(settings.clampedTTL(requested: 600, isInteractive: false) == 600)

        // 対話的リースは無期限を許される
        #expect(settings.clampedTTL(requested: nil, isInteractive: true) == nil)
    }
}
